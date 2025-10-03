#lang racket

#|
 @title{Universal Web Scraper}
 @author{Anuna Research}
 @date{2025-06-11}
 
 This module manages web crawling jobs with configurable parameters.
|#

(require net/url
         net/uri-codec
         net/url-string
         html-parsing
         sxml
         xml
         data/queue
         racket/bool
         racket/port
         racket/string
         racket/match
         racket/contract
         json
         uuid
         gregor
         http123/util/url)

(require "scraper-interfaces.rkt"
         "proxy-adaptor.rkt"
         "cli.rkt"
         "../utils.rkt")

(provide
 (contract-out
  ;; Create and start a new scraping job
  [create-scrape-job
   (->* (string?                    ; start-url
         extraction-spec?           ; what to extract
         (-> any/c (listof hash?))) ; parser function
        (#:pattern string?          ; URL pattern to follow
         #:use-proxy? boolean?      ; Use proxy service
         #:use-cache? boolean?      ; Use cache service
         #:max-pages (or/c #f exact-positive-integer?)
         #:rate-limit exact-positive-integer?) ; ms between requests
        job-id/c)]
  
  ;; Job management
  [get-job-status (-> job-id/c (or/c #f job-status?))]
  [pause-job (-> job-id/c boolean?)]
  [resume-job (-> job-id/c boolean?)]
  [cancel-job (-> job-id/c boolean?)]
  [list-active-jobs (-> (listof job-id/c))]
  
  ;; Get results
  [get-job-results (-> job-id/c (or/c #f job-results?))]))

;; Internal Data Structures
;; ------------------------

(struct crawler-state
  (id
   extraction-spec
   parser
   pattern
   use-cache?
   use-proxy?
   rate-limit
   max-pages
   custodian
   queue
   visited
   [alive? #:mutable]
   [paused? #:mutable]
   [page-count #:auto #:mutable]
   [items-extracted #:auto #:mutable]
   [start-time #:auto]
   [errors #:auto #:mutable]
   [results #:auto #:mutable])
  #:auto-value 0
  #:transparent)

;; Global State
;; ------------

(define crawler-states (make-hash))
(define crawler-states-lock (make-semaphore 1))

;; Helper Macros
;; -------------

(define-syntax-rule (with-crawler-state-lock body ...)
  (call-with-semaphore crawler-states-lock (lambda () body ...)))

;; URL Processing Functions
;; ------------------------

;; @function{normalize-url}
;; @description{Normalize URL by removing fragments and cache/proxy wrappers}
;; @param[url]{string?} URL to normalize
;; @param[use-proxy?]{boolean?} Whether proxy is being used
;; @param[use-cache?]{boolean?} Whether cache is being used
;; @returns{string?} Normalized URL
(define (normalize-url url use-proxy? use-cache?)
  (let* ([clean-url (extract-url-from-zenrows (remove-cache url use-cache?))]
         [stripped-url (strip-fragment clean-url)])
    stripped-url))

;; @function{strip-fragment}
;; @description{Remove URL fragment}
;; @param[url]{string?} URL
;; @returns{string?} URL without fragment
(define (strip-fragment url)
  (let ([uri (string->url (string-trim url))])
    (set-url-fragment! uri #f)
    (url->string uri)))

;; @function{add-cache}
;; @description{Add Google cache prefix to URL}
;; @param[url]{string?} Original URL
;; @param[add?]{boolean?} Whether to add cache
;; @returns{string?} Modified URL
(define (add-cache url add?)
  (if add?
      (string-append "https://webcache.googleusercontent.com/search?q=cache:" url)
      url))

;; @function{remove-cache}
;; @description{Remove Google cache prefix from URL}
;; @param[url]{string?} Cached URL
;; @param[remove?]{boolean?} Whether to remove cache
;; @returns{string?} Original URL
(define (remove-cache url remove?)
  (define cache-prefix "https://webcache.googleusercontent.com/search?q=cache:")
  (if (and remove? (string-prefix? url cache-prefix))
      (substring url (string-length cache-prefix))
      url))

;; @function{add-proxy}
;; @description{Add proxy wrapper to URL}
;; @param[url]{string?} Original URL
;; @param[proxy?]{boolean?} Whether to add proxy
;; @returns{string?} Proxied URL
(define (add-proxy url proxy?)
  (if proxy?
      (zenrows-proxy-adaptor url #:js_render #t #:premium_proxy #t)
      url))

;; @function{get-domain-from-url}
;; @description{Extract domain from URL}
;; @param[url]{string?} URL
;; @returns{string?} Domain
(define (get-domain-from-url url)
  (with-handlers ([exn:fail? (lambda (exn) url)])
    (let* ([url-obj (string->url (string-trim url))])
      (format "~a://~a" (url-scheme url-obj) (url-host url-obj)))))

;; @function{make-absolute-url}
;; @description{Convert relative URL to absolute}
;; @param[base-url]{string?} Base URL
;; @param[relative-url]{string?} Relative URL
;; @returns{string?} Absolute URL
(define (make-absolute-url base-url relative-url)
  (with-handlers ([exn:fail? (lambda (exn) relative-url)])
    (let* ([base-obj (string->url base-url)]
           [rel-obj (string->url (string-trim relative-url))])
      (if (url-host rel-obj)
          (url->string rel-obj)
          (url->string (combine-url/relative base-obj (url->string rel-obj)))))))

;; HTML Fetching Functions
;; -----------------------

;; @function{fetch-html}
;; @description{Fetch HTML from URL with retries}
;; @param[url]{string?} URL to fetch
;; @param[retries]{exact-nonnegative-integer?} Number of retries
;; @returns{(or/c xexp? #f)} HTML as xexp or #f on failure
(define (fetch-html url [retries 3])
  (with-handlers ([exn:fail:network?
                   (lambda (exn)
                     (if (> retries 0)
                         (begin
                           (sleep 1)
                           (fetch-html url (sub1 retries)))
                         #f))]
                  [exn:fail?
                   (lambda (exn)
                     (printf "Error fetching ~a: ~a~n" url (exn-message exn))
                     #f)])
    (let* ([port (get-pure-port (string->url url) #:redirections 5)]
           [html (port->string port)])
      (close-input-port port)
      (html->xexp html))))

;; @function{extract-links}
;; @description{Extract links from HTML}
;; @param[html-xexp]{xexp?} HTML as xexp
;; @returns{listof string?} List of URLs
(define (extract-links html-xexp)
  (let ([hrefs ((sxpath "//a/@href/text()") html-xexp)])
    (filter string? hrefs)))

;; Job Management Functions
;; ------------------------

;; @function{create-scrape-job}
;; @description{Create and start a new scraping job}
(define (create-scrape-job start-url 
                          extraction-spec 
                          parser
                          #:pattern [pattern ".*"]
                          #:use-proxy? [use-proxy? #f]
                          #:use-cache? [use-cache? #f]
                          #:max-pages [max-pages #f]
                          #:rate-limit [rate-limit 1000])
  (let* ([job-id (uuid-string)]
         [custodian (make-custodian)]
         [state (crawler-state job-id
                              extraction-spec
                              parser
                              pattern
                              use-cache?
                              use-proxy?
                              rate-limit
                              max-pages
                              custodian
                              (make-queue)
                              (make-hash)
                              #t    ; alive?
                              #f    ; paused?
                              0     ; page-count
                              0     ; items-extracted
                              (current-milliseconds)
                              '()   ; errors
                              '())]) ; results
    
    ;; Store state
    (with-crawler-state-lock
     (hash-set! crawler-states job-id state))
    
    ;; Enqueue start URL
    (let ([processed-url (add-proxy (add-cache start-url use-cache?) use-proxy?)])
      (enqueue! (crawler-state-queue state) processed-url))
    
    ;; Start crawler thread
    (parameterize ([current-custodian custodian])
      (thread (lambda () (run-crawler job-id))))
    
    (printf "Started crawler job: ~a~n" job-id)
    job-id))

;; @function{get-job-status}
;; @description{Get current status of a job}
(define (get-job-status job-id)
  (with-crawler-state-lock
   (let ([state (hash-ref crawler-states job-id #f)])
     (and state
          (job-status job-id
                     (cond
                       [(not (crawler-state-alive? state)) 'completed]
                       [(crawler-state-paused? state) 'paused]
                       [else 'running])
                     (crawler-state-page-count state)
                     (crawler-state-items-extracted state)
                     (crawler-state-start-time state)
                     (- (current-milliseconds) 
                        (crawler-state-start-time state))
                     (crawler-state-errors state))))))

;; @function{pause-job}
;; @description{Pause a running job}
(define (pause-job job-id)
  (with-crawler-state-lock
   (let ([state (hash-ref crawler-states job-id #f)])
     (if state
         (begin
           (set-crawler-state-paused?! state #t)
           #t)
         #f))))

;; @function{resume-job}
;; @description{Resume a paused job}
(define (resume-job job-id)
  (with-crawler-state-lock
   (let ([state (hash-ref crawler-states job-id #f)])
     (if state
         (begin
           (set-crawler-state-paused?! state #f)
           #t)
         #f))))

;; @function{cancel-job}
;; @description{Cancel a running job}
(define (cancel-job job-id)
  (with-crawler-state-lock
   (let ([state (hash-ref crawler-states job-id #f)])
     (if state
         (begin
           (set-crawler-state-alive?! state #f)
           (custodian-shutdown-all (crawler-state-custodian state))
           (hash-remove! crawler-states job-id)
           #t)
         #f))))

;; @function{list-active-jobs}
;; @description{List all active job IDs}
(define (list-active-jobs)
  (with-crawler-state-lock
   (hash-keys crawler-states)))

;; @function{get-job-results}
;; @description{Get results from a completed job}
(define (get-job-results job-id)
  (with-crawler-state-lock
   (let ([state (hash-ref crawler-states job-id #f)])
     (and state
          (job-results (crawler-state-results state)
                      (hash 'start-url (crawler-state-id state)
                            'pages-processed (crawler-state-page-count state)
                            'items-extracted (crawler-state-items-extracted state)
                            'duration (- (current-milliseconds)
                                       (crawler-state-start-time state)))
                      (crawler-state-errors state))))))

;; Crawler Implementation
;; ----------------------

;; @function{run-crawler}
;; @description{Main crawler loop}
;; @param[job-id]{string?} Job ID
;; @returns{void?}
(define (run-crawler job-id)
  (let ([state (hash-ref crawler-states job-id)])
    (let loop ()
      (cond
        ;; Check if job is cancelled
        [(not (crawler-state-alive? state))
         (printf "Crawler ~a terminated~n" job-id)]
        
        ;; Check if paused
        [(crawler-state-paused? state)
         (sleep 1)
         (loop)]
        
        ;; Check if queue is empty
        [(queue-empty? (crawler-state-queue state))
         (printf "Crawler ~a completed - queue empty~n" job-id)
         (set-crawler-state-alive?! state #f)]
        
        ;; Check if max pages reached
        [(and (crawler-state-max-pages state)
              (>= (crawler-state-page-count state)
                  (crawler-state-max-pages state)))
         (printf "Crawler ~a completed - max pages reached~n" job-id)
         (set-crawler-state-alive?! state #f)]
        
        ;; Process next URL
        [else
         (let ([url (dequeue! (crawler-state-queue state))])
           (process-url state url)
           
           ;; Rate limiting
           (sleep (/ (crawler-state-rate-limit state) 1000))
           
           (loop))]))))

;; @function{process-url}
;; @description{Process a single URL}
;; @param[state]{crawler-state?} Crawler state
;; @param[url]{string?} URL to process
;; @returns{void?}
(define (process-url state url)
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (add-error state 
                               (format "Error processing ~a: ~a" 
                                      url (exn-message exn))))])
    
    (let* ([normalized-url (normalize-url url 
                                         (crawler-state-use-proxy? state)
                                         (crawler-state-use-cache? state))]
           [visited (crawler-state-visited state)])
      
      ;; Skip if already visited
      (when (not (hash-ref visited normalized-url #f))
        (hash-set! visited normalized-url #t)
        
        ;; Check robots.txt
        (let* ([domain (get-domain-from-url normalized-url)]
               [robots-path (get-robotstxt-path domain 
                                              (crawler-state-id state))])
          
          (when (robots-path-allowed? robots-path normalized-url)
            (printf "Processing: ~a~n" normalized-url)
            
            ;; Fetch and process HTML
            (let ([html (fetch-html url)])
              (when html
                ;; Apply parser
                (let ([items ((crawler-state-parser state) html)])
                  (when (and (list? items) (not (empty? items)))
                    (add-results state items)
                    (set-crawler-state-items-extracted! 
                     state 
                     (+ (crawler-state-items-extracted state) 
                        (length items)))))
                
                ;; Extract and queue links
                (let* ([links (extract-links html)]
                       [absolute-links (map (lambda (link)
                                            (make-absolute-url normalized-url link))
                                          links)]
                       [pattern (crawler-state-pattern state)]
                       [matching-links (filter (lambda (link)
                                               (regexp-match? (regexp pattern) link))
                                             absolute-links)])
                  
                  (for ([link matching-links])
                    (let ([processed-link (add-proxy 
                                         (add-cache link 
                                                   (crawler-state-use-cache? state))
                                         (crawler-state-use-proxy? state))])
                      (enqueue! (crawler-state-queue state) processed-link))))
                
                ;; Update page count
                (set-crawler-state-page-count! 
                 state 
                 (add1 (crawler-state-page-count state)))))))))))

;; @function{add-error}
;; @description{Add error to crawler state}
;; @param[state]{crawler-state?} Crawler state
;; @param[error]{string?} Error message
;; @returns{void?}
(define (add-error state error)
  (set-crawler-state-errors! 
   state 
   (cons error (crawler-state-errors state))))

;; @function{add-results}
;; @description{Add results to crawler state}
;; @param[state]{crawler-state?} Crawler state
;; @param[items]{listof hash?} Items to add
;; @returns{void?}
(define (add-results state items)
  (let* ([url (or (hash-ref (car items) 'url #f) "unknown")]
         [timestamp (now/moment/utc)]
         [extracted-items 
          (map (lambda (item)
                 (extracted-item url timestamp item (hash)))
               items)])
    
    (set-crawler-state-results! 
     state 
     (append (crawler-state-results state) extracted-items))))

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "URL normalization"
    (check-equal? (normalize-url "http://example.com/page#section" #f #f)
                  "http://example.com/page")
    (check-equal? (strip-fragment "http://example.com/page#section")
                  "http://example.com/page"))
  
  (test-case "Cache URL handling"
    (let ([url "http://example.com"])
      (check-equal? (add-cache url #t)
                    "https://webcache.googleusercontent.com/search?q=cache:http://example.com")
      (check-equal? (add-cache url #f) url)))
  
  (test-case "Absolute URL conversion"
    (check-equal? (make-absolute-url "http://example.com" "/page")
                  "http://example.com/page")
    (check-equal? (make-absolute-url "http://example.com" "http://other.com/page")
                  "http://other.com/page")))
