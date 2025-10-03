#lang racket

#|
 @title{Crawl Service Adapter Module}
 @author{Anuna Research}
 @date{2025-01-10}
 
 This module provides adapters for various web crawling services like FireCrawl, 
 ScrapingBee, Browserless, and others with automatic fallback mechanisms.
|#

(require racket/contract
         net/url
         net/uri-codec
         json
         gregor
         html-parsing
         sxml
         http123/util/url)

(provide
 (contract-out
  ;; Service interfaces
  [firecrawl-adaptor (->* (string?) 
                         (#:api-key string?
                          #:formats (listof symbol?)
                          #:include-tags (listof string?)
                          #:exclude-tags (listof string?)
                          #:only-main-content boolean?
                          #:wait-for string?
                          #:timeout exact-positive-integer?)
                         (or/c hash? #f))]
  
  [scrapingbee-adaptor (->* (string?)
                           (#:api-key string?
                            #:render-js boolean?
                            #:premium-proxy boolean?
                            #:country-code string?
                            #:device string?
                            #:wait exact-positive-integer?
                            #:wait-for string?
                            #:block-ads boolean?
                            #:block-resources boolean?
                            #:screenshot boolean?)
                           (or/c hash? #f))]
  
  [browserless-adaptor (->* (string?)
                           (#:api-key string?
                            #:block-ads boolean?
                            #:wait-for string?
                            #:viewport hash?
                            #:stealth boolean?)
                           (or/c hash? #f))]
  
  [scraperapi-adaptor (->* (string?)
                          (#:api-key string?
                           #:render boolean?
                           #:country-code string?
                           #:device-type string?
                           #:premium boolean?)
                          (or/c hash? #f))]
  
  ;; Fallback system
  [fetch-with-fallback (->* (string? (listof symbol?))
                           (#:config hash?
                            #:max-retries exact-nonnegative-integer?)
                           (or/c hash? #f))]
  
  ;; Service management
  [register-service (-> symbol? procedure? void?)]
  [get-available-services (-> (listof symbol?))]
  [test-service-health (-> symbol? boolean?)]
  
  ;; Utility functions
  [normalize-response (-> any/c hash?)]
  [extract-content (-> hash? string?)]
  [extract-links (-> hash? (listof string?))]
  [extract-metadata (-> hash? hash?)]
  [call-service (-> symbol? string? hash? (or/c hash? #f))]
  
  ;; Built-in direct service
  [direct-http-adaptor (->* (string?) 
                           (#:timeout exact-positive-integer?
                            #:user-agent string?
                            #:follow-redirects boolean?)
                           (or/c hash? #f))]))

;; Environment Variables
;; ---------------------

(define FIRECRAWL_API_KEY (or (getenv "FIRECRAWL_API_KEY") ""))
(define SCRAPINGBEE_API_KEY (or (getenv "SCRAPINGBEE_API_KEY") ""))
(define BROWSERLESS_API_KEY (or (getenv "BROWSERLESS_API_KEY") ""))
(define SCRAPERAPI_API_KEY (or (getenv "SCRAPERAPI_API_KEY") ""))

;; Service Registry
;; ----------------

(define service-registry (make-hash))

;; @function{register-service}
;; @description{Register a new crawling service}
(define (register-service name service-fn)
  (hash-set! service-registry name service-fn))

;; @function{get-available-services}
;; @description{Get list of registered services}
(define (get-available-services)
  (hash-keys service-registry))

;; FireCrawl Adapter
;; -----------------

;; @function{firecrawl-adaptor}
;; @description{Fetch content using FireCrawl service}
(define (firecrawl-adaptor url
                          #:api-key [api-key FIRECRAWL_API_KEY]
                          #:formats [formats '(markdown html)]
                          #:include-tags [include-tags '()]
                          #:exclude-tags [exclude-tags '("nav" "footer" "header")]
                          #:only-main-content [only-main-content #t]
                          #:wait-for [wait-for ""]
                          #:timeout [timeout 30000])
  
  (define endpoint "https://api.firecrawl.dev/v0/scrape")
  
  (define payload
    (hash 'url url
          'formats (map (lambda (f) 
                         (if (string? f) f (symbol->string f)))
                       formats)
          'includeTags include-tags
          'excludeTags exclude-tags
          'onlyMainContent only-main-content
          'waitFor wait-for
          'timeout timeout))
  
  (with-handlers ([exn:fail? (lambda (e) 
                              (printf "FireCrawl error: ~a~n" (exn-message e))
                              #f)])
    (let* ([json-payload (jsexpr->string payload)]
           [headers (list (cons "Authorization" (string-append "Bearer " api-key))
                         (cons "Content-Type" "application/json"))]
           [response (http-post endpoint json-payload headers)])
      (and response
           (normalize-response response)))))

;; ScrapingBee Adapter
;; -------------------

;; @function{scrapingbee-adaptor}
;; @description{Fetch content using ScrapingBee service}
(define (scrapingbee-adaptor url
                            #:api-key [api-key SCRAPINGBEE_API_KEY]
                            #:render-js [render-js #t]
                            #:premium-proxy [premium-proxy #f]
                            #:country-code [country-code ""]
                            #:device [device "desktop"]
                            #:wait [wait 0]
                            #:wait-for [wait-for ""]
                            #:block-ads [block-ads #t]
                            #:block-resources [block-resources #f]
                            #:screenshot [screenshot #f])
  
  (define base-url "https://app.scrapingbee.com/api/v1/")
  
  (define params
    (filter (lambda (p) (cdr p))
            `((api_key . ,api-key)
              (url . ,url)
              (render_js . ,(if render-js "true" "false"))
              (premium_proxy . ,(if premium-proxy "true" "false"))
              (country_code . ,country-code)
              (device . ,device)
              (wait . ,(if (> wait 0) (number->string wait) ""))
              (wait_for . ,wait-for)
              (block_ads . ,(if block-ads "true" "false"))
              (block_resources . ,(if block-resources "true" "false"))
              (screenshot . ,(if screenshot "true" "false")))))
  
  (define query-string
    (string-join
     (map (lambda (p) 
            (string-append (uri-encode (symbol->string (car p)))
                          "="
                          (uri-encode (cdr p))))
          params)
     "&"))
  
  (define full-url (string-append base-url "?" query-string))
  
  (with-handlers ([exn:fail? (lambda (e)
                              (printf "ScrapingBee error: ~a~n" (exn-message e))
                              #f)])
    (let ([response (http-get full-url)])
      (and response
           (normalize-response response)))))

;; Browserless Adapter
;; -------------------

;; @function{browserless-adaptor}
;; @description{Fetch content using Browserless service}
(define (browserless-adaptor url
                            #:api-key [api-key BROWSERLESS_API_KEY]
                            #:block-ads [block-ads #t]
                            #:wait-for [wait-for "networkidle0"]
                            #:viewport [viewport (hash 'width 1920 'height 1080)]
                            #:stealth [stealth #t])
  
  (define endpoint (string-append "https://chrome.browserless.io/content?token=" api-key))
  
  (define payload
    (hash 'url url
          'options (hash 'blockAds block-ads
                        'waitUntil wait-for
                        'viewport viewport
                        'addScriptTag (if stealth
                                        (list (hash 'url "https://unpkg.com/puppeteer-extra-plugin-stealth@2.11.2/stealth.min.js"))
                                        '()))))
  
  (with-handlers ([exn:fail? (lambda (e)
                              (printf "Browserless error: ~a~n" (exn-message e))
                              #f)])
    (let* ([json-payload (jsexpr->string payload)]
           [headers (list (cons "Content-Type" "application/json"))]
           [response (http-post endpoint json-payload headers)])
      (and response
           (normalize-response response)))))

;; ScraperAPI Adapter
;; ------------------

;; @function{scraperapi-adaptor}
;; @description{Fetch content using ScraperAPI service}
(define (scraperapi-adaptor url
                           #:api-key [api-key SCRAPERAPI_API_KEY]
                           #:render [render #t]
                           #:country-code [country-code "us"]
                           #:device-type [device-type "desktop"]
                           #:premium [premium #f])
  
  (define base-url "http://api.scraperapi.com")
  
  (define params
    (filter (lambda (p) (cdr p))
            `((api_key . ,api-key)
              (url . ,url)
              (render . ,(if render "true" "false"))
              (country_code . ,country-code)
              (device_type . ,device-type)
              (premium . ,(if premium "true" "false")))))
  
  (define query-string
    (string-join
     (map (lambda (p)
            (string-append (uri-encode (symbol->string (car p)))
                          "="
                          (uri-encode (cdr p))))
          params)
     "&"))
  
  (define full-url (string-append base-url "?" query-string))
  
  (with-handlers ([exn:fail? (lambda (e)
                              (printf "ScraperAPI error: ~a~n" (exn-message e))
                              #f)])
    (let ([response (http-get full-url)])
      (and response
           (normalize-response response)))))

;; Fallback System
;; ---------------

;; @function{fetch-with-fallback}
;; @description{Fetch URL with automatic fallback between services}
(define (fetch-with-fallback url services
                            #:config [config (hash)]
                            #:max-retries [max-retries 2])
  
  (define (try-service service retry-count)
    (cond
      [(> retry-count max-retries) #f]
      [else
       (printf "Trying service: ~a (attempt ~a)~n" service (add1 retry-count))
       (let* ([service-config (hash-ref config service (hash))]
              [result (call-service service url service-config)])
         (if result
             result
             (try-service service (add1 retry-count))))]))
  
  (define (try-services service-list)
    (cond
      [(empty? service-list) #f]
      [else
       (let ([result (try-service (car service-list) 0)])
         (if result
             result
             (try-services (cdr service-list))))]))
  
  (try-services services))

;; @function{call-service}
;; @description{Call specific service with config}
(define (call-service service url config)
  (case service
    [(direct)
     (direct-http-adaptor url
                         #:timeout (hash-ref config 'timeout 30000)
                         #:user-agent (hash-ref config 'user-agent "AR-Crawl/1.0")
                         #:follow-redirects (hash-ref config 'follow-redirects #t))]
    
    [(firecrawl)
     (firecrawl-adaptor url
                       #:api-key (hash-ref config 'firecrawl-api-key FIRECRAWL_API_KEY)
                       #:formats (hash-ref config 'formats '(markdown html))
                       #:only-main-content (hash-ref config 'only-main-content #t))]
    
    [(scrapingbee)
     (scrapingbee-adaptor url
                         #:api-key (hash-ref config 'scrapingbee-api-key SCRAPINGBEE_API_KEY)
                         #:render-js (hash-ref config 'render-js #t)
                         #:premium-proxy (hash-ref config 'premium-proxy #f))]
    
    [(browserless)
     (browserless-adaptor url
                         #:api-key (hash-ref config 'browserless-api-key BROWSERLESS_API_KEY)
                         #:block-ads (hash-ref config 'block-ads #t)
                         #:stealth (hash-ref config 'stealth #t))]
    
    [(scraperapi)
     (scraperapi-adaptor url
                        #:api-key (hash-ref config 'scraperapi-api-key SCRAPERAPI_API_KEY)
                        #:render (hash-ref config 'render #t)
                        #:premium (hash-ref config 'premium #f))]
    
    [else 
     (let ([custom-service (hash-ref service-registry service #f)])
       (if custom-service
           (custom-service url config)
           #f))]))

;; Health Check System
;; -------------------

;; @function{test-service-health}
;; @description{Test if a service is healthy}
(define (test-service-health service)
  (define test-url "https://httpbin.org/html")
  
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (let ([result (call-service service test-url (hash))])
      (and result
           (hash-ref result 'content #f)
           #t))))

;; Response Normalization
;; ----------------------

;; @function{normalize-response}
;; @description{Normalize response from different services}
(define (normalize-response response)
  (cond
    [(hash? response)
     (hash 'content (hash-ref response 'content "")
           'url (hash-ref response 'url "")
           'title (hash-ref response 'title "")
           'links (hash-ref response 'links '())
           'metadata (hash-ref response 'metadata (hash))
           'timestamp (generate-timestamp))]
    
    [(string? response)
     (hash 'content response
           'url ""
           'title ""
           'links '()
           'metadata (hash)
           'timestamp (generate-timestamp))]
    
    [else
     (hash 'content ""
           'url ""
           'title ""
           'links '()
           'metadata (hash)
           'timestamp (generate-timestamp))]))

;; @function{extract-content}
;; @description{Extract main content from normalized response}
(define (extract-content response)
  (hash-ref response 'content ""))

;; @function{extract-links}
;; @description{Extract links from normalized response}
(define (extract-links response)
  (hash-ref response 'links '()))

;; @function{extract-metadata}
;; @description{Extract metadata from normalized response}
(define (extract-metadata response)
  (hash-ref response 'metadata (hash)))

;; HTTP Helper Functions
;; ---------------------

;; @function{http-get}
;; @description{Simple HTTP GET request}
(define (http-get url [headers '()])
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (let* ([port (get-pure-port (string->url url) headers #:redirections 5)]
           [content (port->string port)])
      (close-input-port port)
      content)))

;; @function{http-post}
;; @description{Simple HTTP POST request}
(define (http-post url data [headers '()])
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (let* ([url-obj (string->url url)]
           [post-data (string->bytes/utf-8 data)]
           [port (post-pure-port url-obj post-data headers #:redirections 5)]
           [content (port->string port)])
      (close-input-port port)
      content)))

;; @function{generate-timestamp}
;; @description{Generate ISO timestamp}
(define (generate-timestamp)
  (~t (now/moment/utc) "yyyy-MM-dd'T'HH:mm:ss'Z'"))

;; Direct HTTP Adapter (No API Key Required)
;; ------------------------------------------

;; @function{direct-http-adaptor}
;; @description{Fetch content using direct HTTP requests}
(define (direct-http-adaptor url
                            #:timeout [timeout 30000]
                            #:user-agent [user-agent "AR-Crawl/1.0 (+https://github.com/anuna-research/ar-crawl)"]
                            #:follow-redirects [follow-redirects #t])
  
  (with-handlers ([exn:fail? (lambda (e)
                              (printf "Direct HTTP error: ~a~n" (exn-message e))
                              #f)])
    (let* ([headers (list (format "User-Agent: ~a" user-agent))]
           [max-redirects (if follow-redirects 5 0)]
           [port (get-pure-port (string->url url) headers #:redirections max-redirects)]
           [content (port->string port)])
      (close-input-port port)
      
      ;; Parse HTML and extract basic information
      (let* ([html-content (with-handlers ([exn:fail? (lambda (e) content)])
                             (html->xexp content))]
             [title (extract-title html-content)]
             [links (extract-page-links html-content url)])
        
        (hash 'content content
              'url url
              'title title
              'links links
              'metadata (hash 'method "direct-http"
                             'user-agent user-agent
                             'content-length (string-length content))
              'timestamp (generate-direct-timestamp))))))

;; @function{extract-title}
;; @description{Extract page title from HTML}
(define (extract-title html-xexp)
  (with-handlers ([exn:fail? (lambda (e) "")])
    (let ([titles ((sxpath "//title/text()") html-xexp)])
      (if (empty? titles) "" (car titles)))))

;; @function{extract-page-links}
;; @description{Extract and normalize links from HTML}
(define (extract-page-links html-xexp base-url)
  (with-handlers ([exn:fail? (lambda (e) '())])
    (let* ([hrefs ((sxpath "//a/@href/text()") html-xexp)]
           [absolute-links (map (lambda (href)
                                 (normalize-link href base-url))
                               (filter string? hrefs))])
      (remove-duplicates (filter valid-http-url? absolute-links)))))

;; @function{normalize-link}
;; @description{Convert relative links to absolute}
(define (normalize-link href base-url)
  (with-handlers ([exn:fail? (lambda (e) href)])
    (cond
      [(string-prefix? href "http://") href]
      [(string-prefix? href "https://") href]
      [(string-prefix? href "//") (string-append "https:" href)]
      [(string-prefix? href "/") 
       (let* ([base-parts (string-split base-url "/")]
              [scheme (car base-parts)]
              [host (if (> (length base-parts) 2) (caddr base-parts) "")])
         (string-append scheme "//" host href))]
      [else 
       (let* ([base-parts (string-split base-url "/")]
              [base-path (string-join (take base-parts (- (length base-parts) 1)) "/")])
         (string-append base-path "/" href))])))

;; @function{valid-http-url?}
;; @description{Check if URL is valid HTTP/HTTPS}
(define (valid-http-url? url)
  (and (string? url)
       (or (string-prefix? url "http://")
           (string-prefix? url "https://"))
       (> (string-length url) 10)))

;; @function{generate-direct-timestamp}
;; @description{Generate timestamp for direct service}
(define (generate-direct-timestamp)
  (~t (now/moment/utc) "yyyy-MM-dd'T'HH:mm:ss'Z'"))

;; Initialize default services
(register-service 'direct direct-http-adaptor)
(register-service 'firecrawl firecrawl-adaptor)
(register-service 'scrapingbee scrapingbee-adaptor)
(register-service 'browserless browserless-adaptor)
(register-service 'scraperapi scraperapi-adaptor)

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "Service registration"
    (register-service 'test-service (lambda (url config) "test"))
    (check-true (member 'test-service (get-available-services))))
  
  (test-case "Response normalization"
    (define response (normalize-response "test content"))
    (check-equal? (hash-ref response 'content) "test content")
    (check-true (hash-has-key? response 'timestamp)))
  
  (test-case "Content extraction"
    (define response (hash 'content "hello world" 'links '("http://test.com")))
    (check-equal? (extract-content response) "hello world")
    (check-equal? (extract-links response) '("http://test.com"))))
