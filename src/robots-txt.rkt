#lang racket

#|
 @title{Robots.txt Parser and Checker}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Module for fetching, parsing, and checking robots.txt files to respect
 web crawling etiquette as defined in the Robots Exclusion Protocol.
|#

(require racket/contract
         racket/string
         racket/list
         racket/hash
         net/url
         net/http-client)

;; Data Structures
;; ---------------

(struct robots-rule
  (user-agent          ; User agent this rule applies to
   disallowed-paths    ; List of disallowed paths/patterns
   allowed-paths       ; List of explicitly allowed paths
   crawl-delay)        ; Crawl delay in seconds (optional)
  #:transparent)

(struct robots-txt
  (rules               ; List of robots-rule structs
   sitemap-urls        ; List of sitemap URLs
   host               ; Host this robots.txt applies to
   cache-time         ; When this was cached
   raw-content)       ; Original robots.txt content
  #:transparent)

;; Contracts
;; ---------

(define user-agent-string/c string?)
(define url-path/c string?)
(define robots-cache/c hash?)

;; Exports
;; -------

(provide/contract
  ;; Main functions
  [fetch-robots-txt
   (-> string? string? (or/c robots-txt? #f))]
  
  [parse-robots-txt
   (-> string? string? robots-txt?)]
  
  [is-crawling-allowed?
   (-> robots-txt? string? url-path/c boolean?)]
  
  [get-crawl-delay
   (-> robots-txt? string? (or/c #f exact-nonnegative-integer?))]
  
  [get-sitemaps
   (-> robots-txt? (listof string?))]
  
  ;; Cache management
  [create-robots-cache
   (-> robots-cache/c)]
  
  [get-cached-robots
   (-> robots-cache/c string? string? (or/c robots-txt? #f))]
  
  [cache-robots
   (-> robots-cache/c string? robots-txt? void?)]
  
  ;; Utility functions
  [robots-txt-url
   (-> string? string?)]
  
  [normalize-path
   (-> string? string?)]
  
  ;; Data structure predicates and accessors
  [robots-rule? predicate/c]
  [robots-txt? predicate/c]
  [robots-txt-rules (-> robots-txt? list?)]
  [robots-txt-sitemap-urls (-> robots-txt? list?)]
  [robots-txt-host (-> robots-txt? string?)])

;; Configuration
;; -------------

(define DEFAULT-USER-AGENT "AR-Crawl/1.0")
(define ROBOTS-TXT-TIMEOUT-MS 5000)
(define CACHE-EXPIRY-MS (* 24 60 60 1000))  ; 24 hours

;; Main Functions
;; --------------

;; @function{fetch-robots-txt}
;; @description{Fetch and parse robots.txt from a given URL}
(define (fetch-robots-txt base-url user-agent)
  (define robots-url (robots-txt-url base-url))
  
  (with-handlers ([exn? (lambda (e)
                         (log-warning "Failed to fetch robots.txt from ~a: ~a" 
                                    robots-url (exn-message e))
                         #f)])
    (define-values (status headers in)
      (http-sendrecv (url-host (string->url robots-url))
                     (url-path (string->url robots-url))
                     #:ssl? (string=? (url-scheme (string->url robots-url)) "https")
                     #:port (or (url-port (string->url robots-url))
                               (if (string=? (url-scheme (string->url robots-url)) "https")
                                   443
                                   80))
                     #:headers (list (format "User-Agent: ~a" user-agent))))
    
    (if (string=? status "200")
        (let ([content (port->string in)])
          (close-input-port in)
          (parse-robots-txt content (get-host-from-url base-url)))
        (begin
          (close-input-port in)
          (log-info "robots.txt returned status ~a for ~a" status robots-url)
          #f))))

;; @function{parse-robots-txt}
;; @description{Parse robots.txt content into structured data}
(define (parse-robots-txt content host)
  (define lines (filter-map (lambda (line)
                              (define trimmed (string-trim line))
                              (if (string=? trimmed "") #f trimmed))
                           (string-split content "\n")))
  
  (define rules '())
  (define sitemaps '())
  (define current-user-agent #f)
  (define current-disallowed '())
  (define current-allowed '())
  (define current-crawl-delay #f)
  
  (define (finalize-current-rule)
    (when current-user-agent
      (set! rules (cons (robots-rule current-user-agent
                                    (reverse current-disallowed)
                                    (reverse current-allowed)
                                    current-crawl-delay)
                       rules))
      (set! current-disallowed '())
      (set! current-allowed '())
      (set! current-crawl-delay #f)))
  
  (for ([line lines])
    (cond
      ;; Skip comments and empty lines
      [(or (string=? line "")
           (string-prefix? line "#"))
       (void)]
      
      ;; User-agent directive
      [(string-prefix? (string-downcase line) "user-agent:")
       (finalize-current-rule)
       (set! current-user-agent 
             (string-trim (substring line 11)))]
      
      ;; Disallow directive
      [(string-prefix? (string-downcase line) "disallow:")
       (when current-user-agent
         (define path (string-trim (substring line 9)))
         (unless (string=? path "")
           (set! current-disallowed 
                 (cons (normalize-path path) current-disallowed))))]
      
      ;; Allow directive
      [(string-prefix? (string-downcase line) "allow:")
       (when current-user-agent
         (define path (string-trim (substring line 6)))
         (unless (string=? path "")
           (set! current-allowed 
                 (cons (normalize-path path) current-allowed))))]
      
      ;; Crawl-delay directive
      [(string-prefix? (string-downcase line) "crawl-delay:")
       (when current-user-agent
         (with-handlers ([exn? (lambda (e) #f)])
           (define delay-str (string-trim (substring line 12)))
           (define delay (string->number delay-str))
           (when (and delay (>= delay 0))
             (set! current-crawl-delay (exact-round delay)))))]
      
      ;; Sitemap directive
      [(string-prefix? (string-downcase line) "sitemap:")
       (define sitemap-url (string-trim (substring line 8)))
       (unless (string=? sitemap-url "")
         (set! sitemaps (cons sitemap-url sitemaps)))]))
  
  ;; Finalize the last rule
  (finalize-current-rule)
  
  (robots-txt (reverse rules)
             (reverse sitemaps)
             host
             (current-milliseconds)
             content))

;; @function{is-crawling-allowed?}
;; @description{Check if crawling is allowed for a given user-agent and path}
(define (is-crawling-allowed? robots user-agent path)
  (define normalized-path (normalize-path path))
  (define applicable-rules (get-applicable-rules robots user-agent))
  
  ;; If no applicable rules, crawling is allowed
  (if (empty? applicable-rules)
      #t
      (let ([result (check-rules applicable-rules normalized-path)])
        result)))

;; @function{get-crawl-delay}
;; @description{Get the crawl delay for a given user-agent}
(define (get-crawl-delay robots user-agent)
  (define applicable-rules (get-applicable-rules robots user-agent))
  
  (for/or ([rule applicable-rules])
    (robots-rule-crawl-delay rule)))

;; @function{get-sitemaps}
;; @description{Get list of sitemap URLs from robots.txt}
(define (get-sitemaps robots)
  (robots-txt-sitemap-urls robots))

;; Helper Functions
;; ----------------

;; @function{get-applicable-rules}
;; @description{Get rules that apply to the given user-agent}
(define (get-applicable-rules robots user-agent)
  (define all-rules (robots-txt-rules robots))
  (define user-agent-lower (string-downcase user-agent))
  
  ;; Find rules that match the user-agent or wildcard
  (define matching-rules
    (filter (lambda (rule)
              (define rule-agent (string-downcase (robots-rule-user-agent rule)))
              (or (string=? rule-agent "*")
                  (string=? rule-agent user-agent-lower)
                  (string-contains? user-agent-lower rule-agent)))
            all-rules))
  
  ;; Prioritize specific user-agent rules over wildcards
  (define specific-rules
    (filter (lambda (rule)
              (not (string=? (string-downcase (robots-rule-user-agent rule)) "*")))
            matching-rules))
  
  (define wildcard-rules
    (filter (lambda (rule)
              (string=? (string-downcase (robots-rule-user-agent rule)) "*"))
            matching-rules))
  
  ;; Return specific rules first, then wildcards
  (append specific-rules wildcard-rules))

;; @function{check-rules}
;; @description{Check if path is allowed based on rules}
(define (check-rules rules path)
  (define (path-matches? pattern path)
    (cond
      [(string=? pattern "/") #t]  ; Root matches everything
      [(string-suffix? pattern "*")
       (string-prefix? path (substring pattern 0 (- (string-length pattern) 1)))]
      [else
       (string-prefix? path pattern)]))
  
  ;; Check disallowed paths first
  (define disallowed?
    (for/or ([rule rules])
      (for/or ([disallowed-path (robots-rule-disallowed-paths rule)])
        (path-matches? disallowed-path path))))
  
  ;; Check allowed paths (can override disallowed)
  (define explicitly-allowed?
    (for/or ([rule rules])
      (for/or ([allowed-path (robots-rule-allowed-paths rule)])
        (path-matches? allowed-path path))))
  
  ;; Allow if explicitly allowed, or not disallowed
  (or explicitly-allowed? (not disallowed?)))

;; @function{robots-txt-url}
;; @description{Generate robots.txt URL from base URL}
(define (robots-txt-url base-url)
  (define parsed-url (string->url base-url))
  (define scheme (url-scheme parsed-url))
  (define host (url-host parsed-url))
  (define port (url-port parsed-url))
  
  (string-append 
    (if (symbol? scheme) (symbol->string scheme) scheme) "://" 
    host
    (if port (format ":~a" port) "")
    "/robots.txt"))

;; @function{normalize-path}
;; @description{Normalize URL path for consistent matching}
(define (normalize-path path)
  (cond
    [(string=? path "") "/"]
    [(not (string-prefix? path "/")) (string-append "/" path)]
    [else path]))

;; @function{get-host-from-url}
;; @description{Extract host from URL}
(define (get-host-from-url url-str)
  (with-handlers ([exn? (lambda (e) url-str)])
    (url-host (string->url url-str))))

;; Cache Management
;; ----------------

;; @function{create-robots-cache}
;; @description{Create a new robots.txt cache}
(define (create-robots-cache)
  (make-hash))

;; @function{get-cached-robots}
;; @description{Get cached robots.txt if still valid}
(define (get-cached-robots cache base-url user-agent)
  (define cache-key (format "~a:~a" base-url user-agent))
  (define cached-entry (hash-ref cache cache-key #f))
  
  (if cached-entry
      (let ([robots (car cached-entry)]
            [cache-time (cdr cached-entry)])
        (if (< (- (current-milliseconds) cache-time) CACHE-EXPIRY-MS)
            robots
            (begin
              (hash-remove! cache cache-key)
              #f)))
      #f))

;; @function{cache-robots}
;; @description{Cache robots.txt data}
(define (cache-robots cache base-url robots)
  (define cache-key (format "~a:~a" base-url (robots-txt-host robots)))
  (hash-set! cache cache-key 
             (cons robots (current-milliseconds))))

;; Utility Functions
;; -----------------

;; @function{string-trim}
;; @description{Trim whitespace from string}
(define (string-trim str)
  (define trimmed-left (regexp-replace #rx"^\\s+" str ""))
  (regexp-replace #rx"\\s+$" trimmed-left ""))

;; @function{string-prefix?}
;; @description{Check if string has prefix}
(define (string-prefix? str prefix)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

;; @function{string-suffix?}
;; @description{Check if string has suffix}
(define (string-suffix? str suffix)
  (and (>= (string-length str) (string-length suffix))
       (string=? (substring str (- (string-length str) (string-length suffix))) suffix)))

;; @function{string-contains?}
;; @description{Check if string contains substring}
(define (string-contains? str substr)
  (regexp-match? (regexp-quote substr) str))

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "robots.txt URL generation"
    (check-equal? (robots-txt-url "https://example.com/path")
                  "https://example.com/robots.txt")
    (check-equal? (robots-txt-url "http://example.com:8080")
                  "http://example.com:8080/robots.txt"))
  
  (test-case "Path normalization"
    (check-equal? (normalize-path "") "/")
    (check-equal? (normalize-path "path") "/path")
    (check-equal? (normalize-path "/path") "/path"))
  
  (test-case "robots.txt parsing"
    (define sample-content
      "User-agent: *\nDisallow: /private/\nAllow: /public/\nCrawl-delay: 1\nSitemap: https://example.com/sitemap.xml")
    
    (define robots (parse-robots-txt sample-content "example.com"))
    (check-true (robots-txt? robots))
    (check-equal? (length (robots-txt-rules robots)) 1)
    (check-equal? (robots-txt-sitemap-urls robots) '("https://example.com/sitemap.xml")))
  
  (test-case "Crawling permission checks"
    (define sample-robots
      (parse-robots-txt "User-agent: *\nDisallow: /private/\nAllow: /private/public/" "example.com"))
    
    (check-true (is-crawling-allowed? sample-robots "TestBot" "/"))
    (check-false (is-crawling-allowed? sample-robots "TestBot" "/private/secret"))
    (check-true (is-crawling-allowed? sample-robots "TestBot" "/private/public/page"))))
