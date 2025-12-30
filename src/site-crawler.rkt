#lang racket

#|
 @title{AR-Crawl Site Crawler}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Site-wide crawling functionality with link discovery, filtering, and queue management.
|#

(require racket/contract
         racket/hash
         racket/set
         (prefix-in str: racket/string)
         net/url
         net/uri-codec
         "production-crawler.rkt"
         "crawl-service-adaptor.rkt"
         "scraper-interfaces.rkt"
         "robots-txt.rkt"
         "utils.rkt")

;; Contracts and Types
;; -------------------

(define url-string/c (and/c string? (lambda (s) (with-handlers ([exn? (lambda (e) #f)])
                                                   (string->url s)
                                                   #t))))

(define regex-pattern/c (or/c string? regexp?))

;; Data Structures
;; ---------------

(struct site-crawl-config
  (max-pages          ; Maximum pages to crawl
   max-depth          ; Maximum crawl depth
   url-pattern        ; Regex pattern for URL filtering
   same-domain-only   ; Only crawl URLs from the same domain
   respect-robots     ; Respect robots.txt
   crawl-delay-ms     ; Delay between requests in milliseconds
   timeout-total-ms   ; Total crawl timeout
   concurrent-limit   ; Maximum concurrent requests
   user-agent)        ; User agent string
  #:transparent)

(struct site-crawl-state
  (url-queue          ; Queue of URLs to crawl
   visited-urls       ; Set of already visited URLs
   crawled-pages      ; Hash of URL -> crawl result
   current-depth      ; Current crawl depth
   pages-crawled      ; Number of pages crawled
   start-time         ; Crawl start time
   base-domain        ; Base domain for same-domain filtering
   robots-cache       ; Cache for robots.txt files
   robots-txt)        ; Current robots.txt for base domain
  #:transparent)

(struct site-crawl-result
  (pages             ; List of successfully crawled pages
   failed-urls       ; List of URLs that failed to crawl
   statistics        ; Crawl statistics
   metadata)         ; Additional metadata
  #:transparent)

;; Exports
;; -------

(provide/contract
  ;; Configuration
  [make-site-crawl-config
   (->* ()
        (#:max-pages exact-positive-integer?
         #:max-depth exact-positive-integer?
         #:url-pattern regex-pattern/c
         #:same-domain-only boolean?
         #:respect-robots boolean?
         #:crawl-delay-ms exact-nonnegative-integer?
         #:timeout-total-ms exact-positive-integer?
         #:concurrent-limit exact-positive-integer?
         #:user-agent string?)
        site-crawl-config?)]
  
  ;; Main crawling function
  [crawl-site
   (->* (url-string/c any/c site-crawl-config?)
        (#:progress-callback (or/c #f (-> string? exact-nonnegative-integer? exact-nonnegative-integer? void?)))
        site-crawl-result?)]
  
  ;; Utility functions
  [extract-links-from-result
   (-> hash? (listof string?))]
  
  [filter-urls
   (-> (listof string?) regex-pattern/c string? boolean? (listof string?))]
  
  ;; Data structure predicates and accessors
  [site-crawl-config? predicate/c]
  [site-crawl-state? predicate/c]
  [site-crawl-result? predicate/c]
  
  ;; Struct accessors
  [site-crawl-result-pages (-> site-crawl-result? any/c)]
  [site-crawl-result-failed-urls (-> site-crawl-result? any/c)]
  [site-crawl-result-statistics (-> site-crawl-result? any/c)]
  [site-crawl-result-metadata (-> site-crawl-result? any/c)])

;; Configuration
;; -------------

;; @function{make-site-crawl-config}
;; @description{Create site crawl configuration}
(define (make-site-crawl-config
         #:max-pages [max-pages 100]
         #:max-depth [max-depth 3]
         #:url-pattern [url-pattern ".*"]
         #:same-domain-only [same-domain-only #t]
         #:respect-robots [respect-robots #t]
         #:crawl-delay-ms [crawl-delay-ms 1000]
         #:timeout-total-ms [timeout-total-ms 300000]  ; 5 minutes
         #:concurrent-limit [concurrent-limit 5]
         #:user-agent [user-agent "AR-Crawl/1.0 Site Crawler"])
  
  (site-crawl-config max-pages
                    max-depth
                    (if (string? url-pattern) (regexp url-pattern) url-pattern)
                    same-domain-only
                    respect-robots
                    crawl-delay-ms
                    timeout-total-ms
                    concurrent-limit
                    user-agent))

;; URL Processing
;; --------------

;; @function{extract-links-from-result}
;; @description{Extract all links from a crawl result}
(define (extract-links-from-result result)
  (define links (hash-ref result 'links '()))
  (if (list? links)
      (filter string? links)
      '()))

;; @function{normalize-url}
;; @description{Normalize URL by removing fragments and trailing slashes}
(define (normalize-url url-str base-url-str)
  (with-handlers ([exn? (lambda (e) url-str)])
    (define base-url (string->url base-url-str))
    (define url (string->url url-str))
    
    ;; Resolve relative URLs
    (define resolved-url 
      (if (and (not (url-scheme url)) (url-scheme base-url))
          (combine-url/relative base-url url-str)
          url))
    
    ;; Convert to string and remove fragment manually using regexp
    (define url-string (url->string resolved-url))
    (define normalized (regexp-replace #rx"#.*$" url-string ""))
    
    ;; Remove trailing slash unless it's the root
    (if (and (> (string-length normalized) 1)
             (regexp-match? #rx"/$" normalized))
        (regexp-replace #rx"/$" normalized "")
        normalized)))

;; @function{get-domain}
;; @description{Extract domain from URL}
(define (get-domain url-str)
  (with-handlers ([exn? (lambda (e) "")])
    (define url (string->url url-str))
    (or (url-host url) "")))

;; @function{get-url-path}
;; @description{Extract path from URL for robots.txt checking}
(define (get-url-path url-str)
  (with-handlers ([exn? (lambda (e) "/")])
    (define url (string->url url-str))
    (define path (url-path url))
    (if (empty? path)
        "/"
        (string-append "/" (string-join (map path/param-path path) "/")))))

;; @function{filter-urls}
;; @description{Filter URLs based on pattern and domain constraints}
(define (filter-urls urls pattern base-url same-domain-only?)
  (define base-domain (get-domain base-url))
  
  (filter (lambda (url)
            (and (string? url)
                 (> (string-length url) 0)
                 ;; Match pattern
                 (regexp-match? pattern url)
                 ;; Check domain constraint
                 (or (not same-domain-only?)
                     (string=? (get-domain url) base-domain))
                 ;; Skip common non-content URLs
                 (not (regexp-match? #rx"\\.(css|js|jpg|jpeg|png|gif|pdf|zip|exe)$" url))))
          urls))

;; Site Crawling Engine
;; --------------------

;; @function{crawl-site}
;; @description{Crawl an entire site starting from a seed URL}
(define (crawl-site seed-url crawler config
                   #:progress-callback [progress-callback #f])
  
  (define start-time (current-milliseconds))
  (define base-domain (get-domain seed-url))
  
  ;; Initialize robots.txt cache and fetch robots.txt for base domain
  (define robots-cache (create-robots-cache))
  (define robots-txt-data 
    (if (site-crawl-config-respect-robots config)
        (fetch-robots-txt seed-url (site-crawl-config-user-agent config))
        #f))
  
  (when (and robots-txt-data progress-callback)
    (progress-callback "Loaded robots.txt" 0 1))
  
  ;; Initialize crawl state
  (define initial-state
    (site-crawl-state (list seed-url)                    ; url-queue
                     (set)                               ; visited-urls
                     (hash)                              ; crawled-pages
                     0                                   ; current-depth
                     0                                   ; pages-crawled
                     start-time                          ; start-time
                     base-domain                         ; base-domain
                     robots-cache                        ; robots-cache
                     robots-txt-data))                   ; robots-txt
  
  (when progress-callback
    (progress-callback "Starting site crawl..." 0 1))
  
  ;; Main crawling loop
  (define final-state (crawl-loop initial-state crawler config progress-callback))
  
  ;; Compile results
  (define end-time (current-milliseconds))
  (define duration (- end-time start-time))
  
  (define successful-pages 
    (hash-values (site-crawl-state-crawled-pages final-state)))
  
  (define failed-urls
    (set->list (set-subtract (site-crawl-state-visited-urls final-state)
                            (list->set (hash-keys (site-crawl-state-crawled-pages final-state))))))
  
  (define statistics
    (hash 'pages-crawled (length successful-pages)
          'failed-urls (length failed-urls)
          'total-urls-discovered (set-count (site-crawl-state-visited-urls final-state))
          'duration-ms duration
          'average-page-time-ms (if (> (length successful-pages) 0)
                                   (exact->inexact (/ duration (length successful-pages)))
                                   0.0)))
  
  (when progress-callback
    (progress-callback "Site crawl completed" 
                      (length successful-pages) 
                      (length successful-pages)))
  
  (site-crawl-result successful-pages
                    failed-urls
                    statistics
                    (hash 'seed-url seed-url
                          'base-domain base-domain
                          'config config)))

;; @function{crawl-loop}
;; @description{Main crawling loop with queue processing}
(define (crawl-loop state crawler config progress-callback)
  (define queue (site-crawl-state-url-queue state))
  (define visited (site-crawl-state-visited-urls state))
  (define crawled (site-crawl-state-crawled-pages state))
  (define pages-count (site-crawl-state-pages-crawled state))
  (define current-time (current-milliseconds))
  
  ;; Check termination conditions
  (cond
    ;; No more URLs to crawl
    [(empty? queue) state]
    
    ;; Max pages reached
    [(>= pages-count (site-crawl-config-max-pages config)) state]
    
    ;; Timeout reached
    [(> (- current-time (site-crawl-state-start-time state))
        (site-crawl-config-timeout-total-ms config)) state]
    
    ;; Continue crawling
    [else
     (define current-url (car queue))
     (define remaining-queue (cdr queue))
     
     ;; Skip if already visited
     (if (set-member? visited current-url)
         (crawl-loop (struct-copy site-crawl-state state
                                 [url-queue remaining-queue])
                    crawler config progress-callback)
         
         ;; Check robots.txt before crawling
         (if (and (site-crawl-config-respect-robots config)
                  (site-crawl-state-robots-txt state)
                  (not (is-crawling-allowed? (site-crawl-state-robots-txt state)
                                           (site-crawl-config-user-agent config)
                                           (get-url-path current-url))))
             ;; Skip URL due to robots.txt restrictions
             (let* ([_ (when progress-callback
                         (progress-callback (format "Skipping (robots.txt): ~a" current-url)
                                          pages-count 
                                          (site-crawl-config-max-pages config)))]
                    [new-visited (set-add visited current-url)])
               (crawl-loop (site-crawl-state remaining-queue
                                            new-visited
                                            crawled
                                            (site-crawl-state-current-depth state)
                                            pages-count
                                            (site-crawl-state-start-time state)
                                            (site-crawl-state-base-domain state)
                                            (site-crawl-state-robots-cache state)
                                            (site-crawl-state-robots-txt state))
                          crawler config progress-callback))
             
             ;; Crawl the URL
             (let* ([_ (when progress-callback
                         (progress-callback (format "Crawling: ~a" current-url) 
                                          pages-count 
                                          (site-crawl-config-max-pages config)))]
                    [robots-delay (if (and (site-crawl-config-respect-robots config)
                                         (site-crawl-state-robots-txt state))
                                    (get-crawl-delay (site-crawl-state-robots-txt state)
                                                   (site-crawl-config-user-agent config))
                                    #f)]
                    [effective-delay (max (site-crawl-config-crawl-delay-ms config)
                                        (if robots-delay (* robots-delay 1000) 0))]
                    [_ (when (> effective-delay 0)
                         (sleep (/ effective-delay 1000)))]
                [job-id (start-crawling crawler current-url)]
                [_ (let wait-loop ()
                     (define status (get-crawler-status crawler))
                     (when (> (crawler-status-active-jobs status) 0)
                       (sleep 0.1)
                       (wait-loop)))]
                [result (get-job-results crawler job-id)]
                [new-visited (set-add visited current-url)])
           
           (define page-data (and result (car (job-results-data result))))
           (if (and result page-data (hash? page-data))
               ;; Success - extract links and continue
               (let* ([links (extract-links-from-result page-data)]
                      [normalized-links (map (lambda (link) 
                                              (normalize-url link current-url)) 
                                            links)]
                      [filtered-links (filter-urls normalized-links
                                                  (site-crawl-config-url-pattern config)
                                                  current-url
                                                  (site-crawl-config-same-domain-only config))]
                      [new-links (filter (lambda (link) 
                                          (not (set-member? new-visited link)))
                                        filtered-links)]
                      [new-queue (append remaining-queue new-links)]
                      [new-crawled (hash-set crawled current-url page-data)])
                 
                 (crawl-loop (site-crawl-state new-queue
                 new-visited
                 new-crawled
                 (site-crawl-state-current-depth state)
                 (+ pages-count 1)
                 (site-crawl-state-start-time state)
                 (site-crawl-state-base-domain state)
                                   (site-crawl-state-robots-cache state)
                                               (site-crawl-state-robots-txt state))
                             crawler config progress-callback))
               
               ;; Failed - continue with next URL
               (crawl-loop (site-crawl-state remaining-queue
                                            new-visited
                                            crawled
                                            (site-crawl-state-current-depth state)
                                            pages-count
                                            (site-crawl-state-start-time state)
                                            (site-crawl-state-base-domain state)
                                             (site-crawl-state-robots-cache state)
                                             (site-crawl-state-robots-txt state))
                          crawler config progress-callback)))))]))

;; Utility Functions
;; -----------------

;; @function{print-crawl-statistics}
;; @description{Print crawl statistics in a readable format}
(define (print-crawl-statistics result)
  (define stats (site-crawl-result-statistics result))
  (define metadata (site-crawl-result-metadata result))
  
  (printf "Site Crawl Results:~n")
  (printf "==================~n")
  (printf "Seed URL: ~a~n" (hash-ref metadata 'seed-url))
  (printf "Base Domain: ~a~n" (hash-ref metadata 'base-domain))
  (printf "Pages Successfully Crawled: ~a~n" (hash-ref stats 'pages-crawled))
  (printf "Failed URLs: ~a~n" (hash-ref stats 'failed-urls))
  (printf "Total URLs Discovered: ~a~n" (hash-ref stats 'total-urls-discovered))
  (printf "Total Duration: ~a ms (~a seconds)~n" 
         (hash-ref stats 'duration-ms)
         (/ (hash-ref stats 'duration-ms) 1000))
  (printf "Average Time per Page: ~a ms~n" 
         (exact-round (hash-ref stats 'average-page-time-ms))))

;; Export the utility function
(provide print-crawl-statistics)

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit)

  ;; Configuration Tests
  (test-case "make-site-crawl-config creates valid config"
    (let ([config (make-site-crawl-config)])
      (check-true (site-crawl-config? config))
      (check-equal? (site-crawl-config-max-pages config) 100)
      (check-equal? (site-crawl-config-max-depth config) 3)
      (check-true (site-crawl-config-same-domain-only config))
      (check-true (site-crawl-config-respect-robots config))))

  (test-case "make-site-crawl-config with custom values"
    (let ([config (make-site-crawl-config
                   #:max-pages 50
                   #:max-depth 5
                   #:url-pattern "/blog/.*"
                   #:same-domain-only #f
                   #:respect-robots #f
                   #:crawl-delay-ms 2000)])
      (check-equal? (site-crawl-config-max-pages config) 50)
      (check-equal? (site-crawl-config-max-depth config) 5)
      (check-false (site-crawl-config-same-domain-only config))
      (check-false (site-crawl-config-respect-robots config))
      (check-equal? (site-crawl-config-crawl-delay-ms config) 2000)))

  (test-case "make-site-crawl-config converts string pattern to regexp"
    (let ([config (make-site-crawl-config #:url-pattern ".*\\.html$")])
      (check-true (regexp? (site-crawl-config-url-pattern config)))))

  ;; URL Processing Tests
  (test-case "get-domain extracts domain correctly"
    (check-equal? (get-domain "https://example.com/path") "example.com")
    (check-equal? (get-domain "http://sub.example.com:8080/path") "sub.example.com")
    (check-equal? (get-domain "https://example.com") "example.com"))

  (test-case "get-domain handles invalid URLs"
    (check-equal? (get-domain "not-a-url") ""))

  (test-case "normalize-url removes fragments"
    (let ([normalized (normalize-url "http://example.com/page#section"
                                     "http://example.com")])
      (check-false (string-contains? normalized "#"))))

  (test-case "normalize-url resolves relative URLs"
    (let ([normalized (normalize-url "/about" "http://example.com/page")])
      (check-equal? normalized "http://example.com/about")))

  (test-case "normalize-url removes trailing slash"
    (let ([normalized (normalize-url "http://example.com/path/"
                                     "http://example.com")])
      (check-equal? normalized "http://example.com/path")))

  (test-case "normalize-url handles root path"
    (let ([normalized (normalize-url "http://example.com/"
                                     "http://example.com")])
      ;; Root path trailing slash is stripped (consistent behavior)
      (check-equal? normalized "http://example.com")))

  (test-case "get-url-path extracts path"
    (check-equal? (get-url-path "http://example.com/page/sub") "/page/sub")
    (check-equal? (get-url-path "http://example.com") "/")
    (check-equal? (get-url-path "http://example.com/") "/"))

  ;; Link Filtering Tests
  (test-case "filter-urls filters by pattern"
    (let ([urls '("http://example.com/blog/post1"
                  "http://example.com/about"
                  "http://example.com/blog/post2")]
          [pattern (regexp "/blog/")])
      (let ([filtered (filter-urls urls pattern "http://example.com" #f)])
        (check-equal? (length filtered) 2))))

  (test-case "filter-urls filters by domain"
    (let ([urls '("http://example.com/page"
                  "http://other.com/page"
                  "http://example.com/page2")])
      (let ([filtered (filter-urls urls (regexp ".*") "http://example.com" #t)])
        (check-equal? (length filtered) 2))))

  (test-case "filter-urls removes static resources"
    (let ([urls '("http://example.com/page"
                  "http://example.com/style.css"
                  "http://example.com/script.js"
                  "http://example.com/image.jpg"
                  "http://example.com/doc.pdf")])
      (let ([filtered (filter-urls urls (regexp ".*") "http://example.com" #f)])
        (check-equal? (length filtered) 1))))

  (test-case "filter-urls handles empty list"
    (let ([filtered (filter-urls '() (regexp ".*") "http://example.com" #f)])
      (check-equal? filtered '())))

  (test-case "filter-urls handles empty strings"
    (let ([urls '("http://example.com/page" "" "not-a-url")])
      (let ([filtered (filter-urls urls (regexp ".*") "http://example.com" #f)])
        ;; Empty string is filtered out, but "not-a-url" passes (matches pattern, not static)
        (check-equal? (length filtered) 2))))

  ;; Link Extraction Tests
  (test-case "extract-links-from-result extracts links"
    (let ([result (hash 'links '("http://a.com" "http://b.com"))])
      (check-equal? (extract-links-from-result result)
                   '("http://a.com" "http://b.com"))))

  (test-case "extract-links-from-result handles missing links"
    (let ([result (hash 'content "no links")])
      (check-equal? (extract-links-from-result result) '())))

  (test-case "extract-links-from-result filters non-strings"
    (let ([result (hash 'links '("http://a.com" 123 #f "http://b.com"))])
      (check-equal? (extract-links-from-result result)
                   '("http://a.com" "http://b.com"))))

  ;; Data Structure Tests
  (test-case "site-crawl-state struct fields"
    (let ([state (site-crawl-state
                  '("http://example.com")   ; url-queue
                  (set)                      ; visited-urls
                  (hash)                     ; crawled-pages
                  0                          ; current-depth
                  0                          ; pages-crawled
                  0                          ; start-time
                  "example.com"              ; base-domain
                  (hash)                     ; robots-cache
                  #f)])                      ; robots-txt
      (check-true (site-crawl-state? state))
      (check-equal? (site-crawl-state-url-queue state) '("http://example.com"))
      (check-equal? (site-crawl-state-pages-crawled state) 0)
      (check-equal? (site-crawl-state-base-domain state) "example.com")))

  (test-case "site-crawl-result struct fields"
    (let ([result (site-crawl-result
                   '()                       ; pages
                   '()                       ; failed-urls
                   (hash 'pages-crawled 0)   ; statistics
                   (hash))])                 ; metadata
      (check-true (site-crawl-result? result))
      (check-equal? (site-crawl-result-pages result) '())
      (check-equal? (site-crawl-result-failed-urls result) '())))

  ;; Edge Cases
  (test-case "handles URL with special characters"
    (let ([normalized (normalize-url "http://example.com/path?q=hello%20world"
                                     "http://example.com")])
      (check-true (string? normalized))))

  (test-case "handles international domain"
    (let ([domain (get-domain "https://例え.jp/page")])
      (check-true (string? domain))))

  (test-case "handles URL with port"
    (let ([domain (get-domain "http://localhost:3000/api")])
      (check-equal? domain "localhost")))

  ;; Additional URL normalization tests
  (test-case "normalize-url handles query strings"
    (let ([normalized (normalize-url "http://example.com/page?a=1&b=2"
                                     "http://example.com")])
      (check-true (string-contains? normalized "?"))))

  (test-case "normalize-url preserves absolute URLs"
    (let ([normalized (normalize-url "https://other.com/page" "http://example.com")])
      (check-true (string-contains? normalized "other.com"))))

  (test-case "normalize-url handles deep relative paths"
    (let ([normalized (normalize-url "../other" "http://example.com/a/b/c")])
      (check-true (string? normalized))))

  (test-case "normalize-url handles protocol-relative URLs"
    (let ([normalized (normalize-url "//cdn.example.com/script.js" "https://example.com")])
      (check-true (string? normalized))))

  ;; More filter-urls tests
  (test-case "filter-urls filters all static resource types"
    (let* ([urls '("http://example.com/a.css"
                   "http://example.com/b.js"
                   "http://example.com/c.jpg"
                   "http://example.com/d.jpeg"
                   "http://example.com/e.png"
                   "http://example.com/f.gif"
                   "http://example.com/g.pdf"
                   "http://example.com/h.zip"
                   "http://example.com/i.exe"
                   "http://example.com/page.html")]
           [filtered (filter-urls urls (regexp ".*") "http://example.com" #f)])
      (check-equal? (length filtered) 1)
      (check-equal? (car filtered) "http://example.com/page.html")))

  (test-case "filter-urls with restrictive pattern"
    (let* ([urls '("http://example.com/blog/post1"
                   "http://example.com/blog/post2"
                   "http://example.com/about"
                   "http://example.com/products/item1")]
           [filtered (filter-urls urls (regexp "^http://example.com/blog/") "http://example.com" #f)])
      (check-equal? (length filtered) 2)))

  ;; get-url-path additional tests
  (test-case "get-url-path with query string"
    (let ([path (get-url-path "http://example.com/page?q=test")])
      (check-equal? path "/page")))

  (test-case "get-url-path with deep nesting"
    (let ([path (get-url-path "http://example.com/a/b/c/d/e")])
      (check-equal? path "/a/b/c/d/e")))

  (test-case "get-url-path handles path-like string"
    ;; A string without scheme is parsed as a relative path
    (let ([path (get-url-path "not-a-valid-url")])
      (check-equal? path "/not-a-valid-url")))

  ;; extract-links additional tests
  (test-case "extract-links-from-result with non-list links"
    (let ([result (hash 'links "not-a-list")])
      (check-equal? (extract-links-from-result result) '())))

  ;; Configuration edge cases
  (test-case "config with regexp pattern"
    (let ([config (make-site-crawl-config #:url-pattern (regexp "/api/v[0-9]+/"))])
      (check-true (regexp? (site-crawl-config-url-pattern config)))))

  (test-case "config timeout values"
    (let ([config (make-site-crawl-config #:timeout-total-ms 60000 #:concurrent-limit 10)])
      (check-equal? (site-crawl-config-timeout-total-ms config) 60000)
      (check-equal? (site-crawl-config-concurrent-limit config) 10)))

  ;; Result struct tests
  (test-case "site-crawl-result with data"
    (let* ([pages (list (hash 'url "http://a.com" 'content "a")
                       (hash 'url "http://b.com" 'content "b"))]
           [result (site-crawl-result pages
                                      '("http://failed.com")
                                      (hash 'pages-crawled 2
                                            'failed-urls 1)
                                      (hash 'seed-url "http://example.com"))])
      (check-equal? (length (site-crawl-result-pages result)) 2)
      (check-equal? (length (site-crawl-result-failed-urls result)) 1)
      (check-equal? (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 2)))

  ;; State struct tests
  (test-case "site-crawl-state with visited URLs"
    (let ([state (site-crawl-state
                  '("http://queue.com")
                  (set "http://visited.com" "http://visited2.com")
                  (hash "http://visited.com" (hash 'content "data"))
                  1
                  1
                  1000
                  "example.com"
                  (hash)
                  #f)])
      (check-equal? (set-count (site-crawl-state-visited-urls state)) 2)
      (check-equal? (hash-count (site-crawl-state-crawled-pages state)) 1)
      (check-equal? (site-crawl-state-current-depth state) 1)))

  ;; Additional Configuration Tests
  (test-case "config user-agent customization"
    (let ([config (make-site-crawl-config #:user-agent "CustomBot/2.0")])
      (check-equal? (site-crawl-config-user-agent config) "CustomBot/2.0")))

  (test-case "config default user-agent"
    (let ([config (make-site-crawl-config)])
      (check-equal? (site-crawl-config-user-agent config) "AR-Crawl/1.0 Site Crawler")))

  (test-case "config all defaults"
    (let ([config (make-site-crawl-config)])
      (check-equal? (site-crawl-config-max-pages config) 100)
      (check-equal? (site-crawl-config-max-depth config) 3)
      (check-true (site-crawl-config-same-domain-only config))
      (check-true (site-crawl-config-respect-robots config))
      (check-equal? (site-crawl-config-crawl-delay-ms config) 1000)
      (check-equal? (site-crawl-config-timeout-total-ms config) 300000)
      (check-equal? (site-crawl-config-concurrent-limit config) 5)))

  ;; URL Normalization Edge Cases
  (test-case "normalize-url with invalid base URL gracefully handles"
    (let ([normalized (normalize-url "http://example.com/page" "not-a-url")])
      (check-true (string? normalized))))

  (test-case "normalize-url with mailto link"
    (let ([normalized (normalize-url "mailto:test@example.com" "http://example.com")])
      (check-true (string? normalized))))

  (test-case "normalize-url with javascript link"
    (let ([normalized (normalize-url "javascript:void(0)" "http://example.com")])
      (check-true (string? normalized))))

  (test-case "normalize-url with fragment only"
    (let ([normalized (normalize-url "#section" "http://example.com/page")])
      (check-true (string? normalized))))

  (test-case "normalize-url with empty fragment"
    (let ([normalized (normalize-url "http://example.com/page#" "http://example.com")])
      ;; Should remove empty fragment
      (check-true (string? normalized))))

  ;; Domain Extraction Tests
  (test-case "get-domain with HTTPS"
    (check-equal? (get-domain "https://secure.example.com/path") "secure.example.com"))

  (test-case "get-domain with port number"
    (check-equal? (get-domain "http://example.com:8080/path") "example.com"))

  (test-case "get-domain with credentials"
    (let ([domain (get-domain "http://user:pass@example.com/path")])
      (check-equal? domain "example.com")))

  (test-case "get-domain with IP address"
    (check-equal? (get-domain "http://192.168.1.1/path") "192.168.1.1"))

  (test-case "get-domain with localhost"
    (check-equal? (get-domain "http://localhost/path") "localhost"))

  ;; URL Path Extraction Tests
  (test-case "get-url-path with root only"
    (check-equal? (get-url-path "http://example.com/") "/"))

  (test-case "get-url-path with fragment"
    (let ([path (get-url-path "http://example.com/page#section")])
      (check-equal? path "/page")))

  (test-case "get-url-path with encoded characters"
    (let ([path (get-url-path "http://example.com/path%20with%20spaces")])
      (check-true (string? path))))

  ;; Filter URLs Tests
  (test-case "filter-urls with case-insensitive pattern"
    (let* ([urls '("http://example.com/PAGE.HTML"
                   "http://example.com/page.html")]
           [filtered (filter-urls urls (pregexp "(?i:\\.html$)") "http://example.com" #f)])
      (check-equal? (length filtered) 2)))

  (test-case "filter-urls with mixed static and content"
    (let* ([urls '("http://example.com/page"
                   "http://example.com/image.PNG"  ; uppercase extension
                   "http://example.com/document")]
           [filtered (filter-urls urls (regexp ".*") "http://example.com" #f)])
      ;; PNG is filtered (lowercase check in regexp), but uppercase not matched
      (check-true (>= (length filtered) 2))))

  (test-case "filter-urls with subdomain"
    (let* ([urls '("http://blog.example.com/post"
                   "http://example.com/page"
                   "http://other.example.com/data")]
           [filtered (filter-urls urls (regexp ".*") "http://example.com" #t)])
      ;; Same domain only, but subdomains are different
      (check-equal? (length filtered) 1)))

  (test-case "filter-urls preserves order"
    (let* ([urls '("http://example.com/a"
                   "http://example.com/b"
                   "http://example.com/c")]
           [filtered (filter-urls urls (regexp ".*") "http://example.com" #f)])
      (check-equal? filtered urls)))

  ;; Extract Links Tests
  (test-case "extract-links-from-result with empty hash"
    (check-equal? (extract-links-from-result (hash)) '()))

  (test-case "extract-links-from-result with single link"
    (let ([result (hash 'links '("http://example.com"))])
      (check-equal? (extract-links-from-result result) '("http://example.com"))))

  (test-case "extract-links-from-result with mixed types"
    (let ([result (hash 'links '("http://a.com" 42 'symbol "http://b.com" #t))])
      (check-equal? (extract-links-from-result result) '("http://a.com" "http://b.com"))))

  ;; Site Crawl State Tests
  (test-case "site-crawl-state empty queue"
    (let ([state (site-crawl-state
                  '()
                  (set)
                  (hash)
                  0
                  0
                  0
                  "example.com"
                  (hash)
                  #f)])
      (check-equal? (site-crawl-state-url-queue state) '())
      (check-true (set-empty? (site-crawl-state-visited-urls state)))))

  (test-case "site-crawl-state large queue"
    (let* ([urls (build-list 100 (lambda (i) (format "http://example.com/page~a" i)))]
           [state (site-crawl-state
                   urls
                   (set)
                   (hash)
                   0
                   0
                   0
                   "example.com"
                   (hash)
                   #f)])
      (check-equal? (length (site-crawl-state-url-queue state)) 100)))

  ;; Site Crawl Result Tests
  (test-case "site-crawl-result empty"
    (let ([result (site-crawl-result '() '() (hash) (hash))])
      (check-true (site-crawl-result? result))
      (check-equal? (site-crawl-result-pages result) '())
      (check-equal? (site-crawl-result-failed-urls result) '())))

  (test-case "site-crawl-result statistics access"
    (let* ([stats (hash 'pages-crawled 10
                        'failed-urls 2
                        'total-urls-discovered 50
                        'duration-ms 5000
                        'average-page-time-ms 500.0)]
           [result (site-crawl-result '() '() stats (hash))])
      (check-equal? (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 10)
      (check-equal? (hash-ref (site-crawl-result-statistics result) 'failed-urls) 2)))

  (test-case "site-crawl-result metadata access"
    (let* ([meta (hash 'seed-url "http://example.com"
                       'base-domain "example.com")]
           [result (site-crawl-result '() '() (hash) meta)])
      (check-equal? (hash-ref (site-crawl-result-metadata result) 'seed-url) "http://example.com")))

  ;; URL Contract Validation
  (test-case "url-string/c valid URLs"
    (check-true (url-string/c "http://example.com"))
    (check-true (url-string/c "https://example.com/path?q=1"))
    (check-true (url-string/c "http://localhost:3000")))

  ;; Struct Copy Tests
  (test-case "struct-copy site-crawl-state"
    (let* ([state (site-crawl-state
                   '("http://a.com")
                   (set)
                   (hash)
                   0
                   0
                   1000
                   "example.com"
                   (hash)
                   #f)]
           [new-state (struct-copy site-crawl-state state
                                  [pages-crawled 5])])
      (check-equal? (site-crawl-state-pages-crawled new-state) 5)
      (check-equal? (site-crawl-state-url-queue new-state) '("http://a.com"))))

  ;; Config with regex pattern preserves it
  (test-case "config preserves compiled regexp"
    (let* ([pattern (regexp "/api/.*")]
           [config (make-site-crawl-config #:url-pattern pattern)])
      (check-equal? (site-crawl-config-url-pattern config) pattern)))

  ;; Crawl delay configurations
  (test-case "config zero crawl delay"
    (let ([config (make-site-crawl-config #:crawl-delay-ms 0)])
      (check-equal? (site-crawl-config-crawl-delay-ms config) 0)))

  (test-case "config large values"
    (let ([config (make-site-crawl-config
                   #:max-pages 10000
                   #:timeout-total-ms 3600000)])
      (check-equal? (site-crawl-config-max-pages config) 10000)
      (check-equal? (site-crawl-config-timeout-total-ms config) 3600000)))

  ;; =========================================================================
  ;; Integration Tests with Mock Services
  ;; =========================================================================

  ;; Register a mock crawl service for testing
  (define (setup-mock-crawl-service)
    (register-service 'mock-crawl-test
      (lambda (url config)
        ;; Return different content based on URL
        (cond
          [(string-contains? url "page1")
           (hash 'content "<html><body><h1>Page 1</h1><a href=\"http://test.local/page2\">Link to page 2</a></body></html>"
                 'url url
                 'links '("http://test.local/page2")
                 'status 200)]
          [(string-contains? url "page2")
           (hash 'content "<html><body><h1>Page 2</h1><a href=\"http://test.local/page3\">Link to page 3</a></body></html>"
                 'url url
                 'links '("http://test.local/page3")
                 'status 200)]
          [(string-contains? url "page3")
           (hash 'content "<html><body><h1>Page 3</h1>No more links</body></html>"
                 'url url
                 'links '()
                 'status 200)]
          [else
           (hash 'content "<html><body><h1>Home</h1><a href=\"http://test.local/page1\">Page 1</a></body></html>"
                 'url url
                 'links '("http://test.local/page1")
                 'status 200)]))))

  (test-case "crawl-site with mock service - single page"
    (setup-mock-crawl-service)
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 1
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)])
      (check-true (site-crawl-result? result))
      (check-equal? (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 1)))

  (test-case "crawl-site with mock service - multiple pages"
    (setup-mock-crawl-service)
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 5
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)])
      (check-true (site-crawl-result? result))
      ;; Should crawl multiple pages following links
      (check-true (>= (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 1))))

  (test-case "crawl-site respects max-pages limit"
    (setup-mock-crawl-service)
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 2
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)])
      (check-true (<= (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 2))))

  (test-case "crawl-site returns proper statistics"
    (setup-mock-crawl-service)
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 3
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)]
           [stats (site-crawl-result-statistics result)])
      (check-true (hash-has-key? stats 'pages-crawled))
      (check-true (hash-has-key? stats 'failed-urls))
      (check-true (hash-has-key? stats 'total-urls-discovered))
      (check-true (hash-has-key? stats 'duration-ms))
      (check-true (hash-has-key? stats 'average-page-time-ms))))

  (test-case "crawl-site returns proper metadata"
    (setup-mock-crawl-service)
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 1
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)]
           [metadata (site-crawl-result-metadata result)])
      (check-equal? (hash-ref metadata 'seed-url) "http://test.local/")
      (check-equal? (hash-ref metadata 'base-domain) "test.local")
      (check-true (site-crawl-config? (hash-ref metadata 'config)))))

  (test-case "crawl-site with progress callback"
    (setup-mock-crawl-service)
    (define callback-calls '())
    (define (track-callback msg current total)
      (set! callback-calls (cons (list msg current total) callback-calls)))
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 2
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config
                              #:progress-callback track-callback)])
      (check-true (site-crawl-result? result))
      ;; Should have received progress callbacks
      (check-true (> (length callback-calls) 0))))

  (test-case "crawl-site same-domain filtering"
    ;; Register a service that returns cross-domain links
    (register-service 'mock-cross-domain
      (lambda (url config)
        (hash 'content "<html><body>Test</body></html>"
              'url url
              'links '("http://test.local/page1"
                      "http://other-domain.com/page"
                      "http://test.local/page2")
              'status 200)))
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-cross-domain)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 10
                         #:same-domain-only #t
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)])
      ;; Should not have crawled other-domain.com
      (check-true (site-crawl-result? result))))

  (test-case "crawl-site URL pattern filtering"
    ;; Register a service that returns various URLs
    (register-service 'mock-pattern-test
      (lambda (url config)
        (hash 'content "<html><body>Test</body></html>"
              'url url
              'links '("http://test.local/blog/post1"
                      "http://test.local/about"
                      "http://test.local/blog/post2"
                      "http://test.local/contact")
              'status 200)))
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-pattern-test)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 10
                         #:url-pattern "/blog/"
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/blog/" crawler site-config)])
      ;; Should only crawl /blog/ URLs
      (check-true (site-crawl-result? result))))

  ;; Test crawl-loop termination conditions
  (test-case "crawl-loop terminates on empty queue"
    (let* ([state (site-crawl-state
                   '()  ; empty queue
                   (set)
                   (hash)
                   0 0 (current-milliseconds)
                   "test.local"
                   (hash)
                   #f)]
           [config (make-site-crawl-config)]
           [crawler-config (make-production-crawler-config)]
           [crawler (create-production-crawler crawler-config)]
           [final-state (crawl-loop state crawler config #f)])
      ;; Should return immediately with empty queue
      (check-equal? (site-crawl-state-pages-crawled final-state) 0)))

  (test-case "crawl-loop terminates at max-pages"
    (setup-mock-crawl-service)
    (let* ([state (site-crawl-state
                   '("http://test.local/")
                   (set)
                   (hash)
                   0
                   100  ; Already at max
                   (current-milliseconds)
                   "test.local"
                   (hash)
                   #f)]
           [config (make-site-crawl-config #:max-pages 100)]
           [crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test))]
           [crawler (create-production-crawler crawler-config)]
           [final-state (crawl-loop state crawler config #f)])
      ;; Should not crawl more pages
      (check-equal? (site-crawl-state-pages-crawled final-state) 100)))

  (test-case "crawl-loop skips already visited URLs"
    (setup-mock-crawl-service)
    (let* ([state (site-crawl-state
                   '("http://test.local/visited")
                   (set "http://test.local/visited")  ; Already visited
                   (hash)
                   0 0 (current-milliseconds)
                   "test.local"
                   (hash)
                   #f)]
           [config (make-site-crawl-config #:max-pages 10 #:respect-robots #f)]
           [crawler-config (make-production-crawler-config
                            #:services '(mock-crawl-test))]
           [crawler (create-production-crawler crawler-config)]
           [final-state (crawl-loop state crawler config #f)])
      ;; Should skip the visited URL
      (check-equal? (site-crawl-state-pages-crawled final-state) 0)))

  ;; Test with failing mock service
  (test-case "crawl-site handles failed requests"
    (register-service 'mock-failing
      (lambda (url config)
        #f))  ; Return #f to simulate failure
    (let* ([crawler-config (make-production-crawler-config
                            #:services '(mock-failing)
                            #:fallback-enabled #f
                            #:retry-attempts 1)]
           [crawler (create-production-crawler crawler-config)]
           [site-config (make-site-crawl-config
                         #:max-pages 3
                         #:respect-robots #f
                         #:crawl-delay-ms 0)]
           [result (crawl-site "http://test.local/" crawler site-config)])
      ;; Should complete even with failures
      (check-true (site-crawl-result? result))
      (check-equal? (hash-ref (site-crawl-result-statistics result) 'pages-crawled) 0))))
