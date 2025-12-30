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
         sxml/sxpath
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
  [filter-content-by-xpath (-> string? string? string?)]
   [apply-xpath-to-response (-> hash? (or/c string? #f) hash?)]
  
  ;; Built-in direct service
  [direct-http-adaptor (->* (string?)
                           (#:timeout exact-positive-integer?
                            #:user-agent string?
                            #:follow-redirects boolean?)
                           (or/c hash? #f))]

  ;; Playwright local browser service
  [playwright-adaptor (->* (string?)
                          (#:service-url string?
                           #:timeout exact-positive-integer?
                           #:wait-for string?
                           #:viewport hash?
                           #:user-agent string?
                           #:block-resources (listof string?)
                           #:extract-links boolean?)
                          (or/c hash? #f))]))

;; Environment Variables
;; ---------------------

(define FIRECRAWL_API_KEY (or (getenv "FIRECRAWL_API_KEY") ""))
(define SCRAPINGBEE_API_KEY (or (getenv "SCRAPINGBEE_API_KEY") ""))
(define BROWSERLESS_API_KEY (or (getenv "BROWSERLESS_API_KEY") ""))
(define SCRAPERAPI_API_KEY (or (getenv "SCRAPERAPI_API_KEY") ""))
(define PLAYWRIGHT_SERVICE_URL (or (getenv "PLAYWRIGHT_SERVICE_URL") "http://localhost:3033"))

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

;; Playwright Adapter (Local Browser Service)
;; ------------------------------------------

;; @function{playwright-adaptor}
;; @description{Fetch content using local Playwright browser service}
(define (playwright-adaptor url
                           #:service-url [service-url PLAYWRIGHT_SERVICE_URL]
                           #:timeout [timeout 30000]
                           #:wait-for [wait-for "load"]
                           #:delay [delay 5000]  ;; 5s delay for SPA rendering
                           #:scroll [scroll #f]  ;; Scroll to bottom
                           #:scroll-count [scroll-count 0]  ;; Scroll iterations for infinite scroll
                           #:scroll-delay [scroll-delay 1000]  ;; Delay between scrolls (ms)
                           #:click-selector [click-selector #f]  ;; CSS selector to click
                           #:click-count [click-count 1]  ;; Number of clicks
                           #:viewport [viewport (hash 'width 1920 'height 1080)]
                           #:user-agent [user-agent "AR-Crawl/1.0 Playwright (+https://github.com/anuna-research/ar-crawl)"]
                           #:block-resources [block-resources '()]
                           #:extract-links [extract-links #t])

  (define endpoint (string-append service-url "/fetch"))

  (define payload
    (hash 'url url
          'timeout timeout
          'waitFor wait-for
          'delay delay
          'scroll scroll
          'scrollCount scroll-count
          'scrollDelay scroll-delay
          'clickSelector click-selector
          'clickCount click-count
          'viewport viewport
          'userAgent user-agent
          'blockResources block-resources
          'extractLinks extract-links))

  (with-handlers ([exn:fail? (lambda (e)
                              (printf "Playwright service error: ~a~n" (exn-message e))
                              #f)])
    (let* ([json-payload (jsexpr->string payload)]
           [headers (list "Content-Type: application/json")]
           [url-obj (string->url endpoint)]
           [post-data (string->bytes/utf-8 json-payload)]
           [port (post-pure-port url-obj post-data headers)]
           [response (port->string port)]
           [_ (close-input-port port)])
      (if response
          (let ([parsed (with-handlers ([exn:fail? (lambda (e) #f)])
                          (string->jsexpr response))])
            (if (and parsed (hash? parsed) (not (hash-ref parsed 'error #f)))
                (hash 'content (hash-ref parsed 'content "")
                      'url (hash-ref parsed 'url url)
                      'title (hash-ref parsed 'title "")
                      'links (hash-ref parsed 'links '())
                      'metadata (hash-ref parsed 'metadata (hash))
                      'timestamp (generate-timestamp))
                #f))
          #f))))

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

    [(playwright)
     (playwright-adaptor url
                        #:service-url (hash-ref config 'playwright-service-url PLAYWRIGHT_SERVICE_URL)
                        #:timeout (hash-ref config 'timeout 30000)
                        #:wait-for (hash-ref config 'wait-for "load")
                        #:delay (hash-ref config 'delay 5000)
                        #:scroll (hash-ref config 'scroll #f)
                        #:scroll-count (hash-ref config 'scroll-count 0)
                        #:scroll-delay (hash-ref config 'scroll-delay 1000)
                        #:click-selector (hash-ref config 'click-selector #f)
                        #:click-count (hash-ref config 'click-count 1)
                        #:viewport (hash-ref config 'viewport (hash 'width 1920 'height 1080))
                        #:user-agent (hash-ref config 'user-agent "AR-Crawl/1.0 Playwright")
                        #:block-resources (hash-ref config 'block-resources '())
                        #:extract-links (hash-ref config 'extract-links #t))]

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

;; @function{filter-content-by-xpath}
;; @description{Filter HTML content using XPath expression}
(define (filter-content-by-xpath html-content xpath-expr)
  (with-handlers ([exn:fail? (lambda (e) 
                              (printf "XPath filtering error: ~a~n" (exn-message e))
                              html-content)])
    (if (or (not xpath-expr) (string=? xpath-expr ""))
        html-content
        (let* ([html-xexp (html->xexp html-content)]
               [filtered-nodes ((sxpath xpath-expr) html-xexp)])
          (if (empty? filtered-nodes)
              ""
              (string-join 
               (map (lambda (node)
                      (cond
                        [(string? node) node]
                        [(list? node) (extract-text-from-sxml node)]
                        [else (format "~a" node)]))
                    filtered-nodes)
               "\n"))))))

;; @function{extract-text-from-sxml}
;; @description{Extract text content from SXML node}
(define (extract-text-from-sxml node)
  (cond
    [(string? node) node]
    [(list? node)
     (string-join 
      (filter string?
              (flatten 
               (map extract-text-from-sxml (cdr node))))
      " ")]
    [else ""]))

;; @function{apply-xpath-to-response}
;; @description{Apply XPath filter to a normalized response}
(define (apply-xpath-to-response response xpath)
  (if (or (not xpath) (string=? xpath ""))
      response
      (hash-set response 'content 
                (filter-content-by-xpath (hash-ref response 'content "") xpath))))

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
(register-service 'playwright playwright-adaptor)

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)

  ;; Service Registration Tests
  (test-case "Service registration"
    (register-service 'test-service (lambda (url config) "test"))
    (check-not-false (member 'test-service (get-available-services))))

  (test-case "Get available services includes defaults"
    (define services (get-available-services))
    (check-not-false (member 'direct services))
    (check-not-false (member 'firecrawl services)))

  ;; Response Normalization Tests
  (test-case "Response normalization - string input"
    (define response (normalize-response "test content"))
    (check-equal? (hash-ref response 'content) "test content")
    (check-equal? (hash-ref response 'url) "")
    (check-equal? (hash-ref response 'title) "")
    (check-equal? (hash-ref response 'links) '())
    (check-true (hash-has-key? response 'timestamp)))

  (test-case "Response normalization - hash input"
    (define input (hash 'content "html" 'url "http://test.com" 'title "Test"))
    (define response (normalize-response input))
    (check-equal? (hash-ref response 'content) "html")
    (check-equal? (hash-ref response 'url) "http://test.com")
    (check-equal? (hash-ref response 'title) "Test"))

  (test-case "Response normalization - hash with all fields"
    (define input (hash 'content "<html>"
                        'url "http://example.com"
                        'title "Example"
                        'links '("http://a.com" "http://b.com")
                        'metadata (hash 'key "value")))
    (define response (normalize-response input))
    (check-equal? (hash-ref response 'links) '("http://a.com" "http://b.com"))
    (check-equal? (hash-ref (hash-ref response 'metadata) 'key) "value"))

  (test-case "Response normalization - non-standard input"
    (define response (normalize-response 123))
    (check-equal? (hash-ref response 'content) "")
    (check-true (hash? response)))

  (test-case "Response normalization - null/false input"
    (define response (normalize-response #f))
    (check-equal? (hash-ref response 'content) ""))

  ;; Content Extraction Tests
  (test-case "Content extraction"
    (define response (hash 'content "hello world" 'links '("http://test.com")))
    (check-equal? (extract-content response) "hello world")
    (check-equal? (extract-links response) '("http://test.com")))

  (test-case "Extract content - missing key"
    (check-equal? (extract-content (hash)) ""))

  (test-case "Extract links - missing key"
    (check-equal? (extract-links (hash 'content "test")) '()))

  (test-case "Extract metadata"
    (define response (hash 'metadata (hash 'method "GET" 'status 200)))
    (define meta (extract-metadata response))
    (check-equal? (hash-ref meta 'method) "GET")
    (check-equal? (hash-ref meta 'status) 200))

  (test-case "Extract metadata - missing"
    (check-equal? (extract-metadata (hash)) (hash)))

  ;; XPath Filtering Tests
  (test-case "filter-content-by-xpath basic"
    (define html "<html><body><p>Hello</p><p>World</p></body></html>")
    (define result (filter-content-by-xpath html "//p"))
    (check-true (string-contains? result "Hello"))
    (check-true (string-contains? result "World")))

  (test-case "filter-content-by-xpath - empty xpath"
    (define html "<html><body>test</body></html>")
    (check-equal? (filter-content-by-xpath html "") html)
    (check-equal? (filter-content-by-xpath html #f) html))

  (test-case "filter-content-by-xpath - no matches"
    (define html "<html><body><p>test</p></body></html>")
    (define result (filter-content-by-xpath html "//div"))
    (check-equal? result ""))

  (test-case "filter-content-by-xpath - nested content"
    (define html "<html><body><div><span>nested</span></div></body></html>")
    (define result (filter-content-by-xpath html "//div"))
    (check-true (string-contains? result "nested")))

  ;; extract-text-from-sxml Tests
  (test-case "extract-text-from-sxml - string"
    (check-equal? (extract-text-from-sxml "hello") "hello"))

  (test-case "extract-text-from-sxml - simple element"
    (define sxml '(p "hello" " " "world"))
    (check-true (string-contains? (extract-text-from-sxml sxml) "hello"))
    (check-true (string-contains? (extract-text-from-sxml sxml) "world")))

  (test-case "extract-text-from-sxml - nested"
    (define sxml '(div (p "text") (span "more")))
    (define result (extract-text-from-sxml sxml))
    (check-true (string-contains? result "text"))
    (check-true (string-contains? result "more")))

  (test-case "extract-text-from-sxml - non-string"
    (check-equal? (extract-text-from-sxml 123) ""))

  ;; apply-xpath-to-response Tests
  (test-case "apply-xpath-to-response"
    (define response (hash 'content "<html><p>filtered</p></html>" 'url "http://test.com"))
    (define result (apply-xpath-to-response response "//p"))
    (check-true (string-contains? (hash-ref result 'content) "filtered"))
    (check-equal? (hash-ref result 'url) "http://test.com"))

  (test-case "apply-xpath-to-response - empty xpath"
    (define response (hash 'content "original"))
    (check-equal? (apply-xpath-to-response response "") response)
    (check-equal? (apply-xpath-to-response response #f) response))

  ;; Link Normalization Tests
  (test-case "normalize-link - absolute http"
    (check-equal? (normalize-link "http://example.com/page" "http://base.com")
                  "http://example.com/page"))

  (test-case "normalize-link - absolute https"
    (check-equal? (normalize-link "https://example.com/page" "http://base.com")
                  "https://example.com/page"))

  (test-case "normalize-link - protocol relative"
    (define result (normalize-link "//cdn.example.com/script.js" "https://base.com"))
    (check-true (string-contains? result "cdn.example.com")))

  ;; valid-http-url? Tests
  (test-case "valid-http-url? - valid http"
    (check-true (valid-http-url? "http://example.com")))

  (test-case "valid-http-url? - valid https"
    (check-true (valid-http-url? "https://example.com/path")))

  (test-case "valid-http-url? - invalid"
    (check-false (valid-http-url? "not-a-url"))
    (check-false (valid-http-url? "ftp://example.com"))
    (check-false (valid-http-url? "")))

  ;; extract-title Tests
  (test-case "extract-title - with title"
    (define html '(*TOP* (html (head (title "Page Title")))))
    (check-equal? (extract-title html) "Page Title"))

  (test-case "extract-title - no title"
    (define html '(*TOP* (html (body "content"))))
    (check-equal? (extract-title html) ""))

  ;; extract-page-links Tests
  (test-case "extract-page-links - basic"
    (define html '(*TOP* (html (body (a (@ (href "http://a.com")) "A")
                                     (a (@ (href "http://b.com")) "B")))))
    (define links (extract-page-links html "http://base.com"))
    (check-equal? (length links) 2))

  (test-case "extract-page-links - filters duplicates"
    (define html '(*TOP* (html (body (a (@ (href "http://a.com")) "A1")
                                     (a (@ (href "http://a.com")) "A2")))))
    (define links (extract-page-links html "http://base.com"))
    (check-equal? (length links) 1))

  (test-case "extract-page-links - empty"
    (define html '(*TOP* (html (body "no links"))))
    (check-equal? (extract-page-links html "http://base.com") '()))

  ;; Timestamp Tests
  (test-case "generate-timestamp format"
    (define ts (generate-timestamp))
    (check-true (string? ts))
    (check-true (regexp-match? #px"\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z" ts)))

  (test-case "generate-direct-timestamp format"
    (define ts (generate-direct-timestamp))
    (check-true (string? ts))
    (check-true (regexp-match? #px"\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z" ts)))

  ;; call-service Tests (with registered test service)
  (test-case "call-service with mock service"
    (register-service 'mock-service
                      (lambda (url config)
                        (hash 'content (format "mocked: ~a" url)
                              'url url)))
    (define result (call-service 'mock-service "http://test.com" (hash)))
    (check-true (hash? result))
    (check-true (string-contains? (hash-ref result 'content "") "mocked")))

  (test-case "call-service - unregistered service"
    (define result (call-service 'nonexistent-service "http://test.com" (hash)))
    (check-false result)))
