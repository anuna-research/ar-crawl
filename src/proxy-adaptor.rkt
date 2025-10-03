#lang racket

#|
 @title{Proxy Adapter Module}
 @author{Anuna Research}
 @date{2025-06-11}
 
 This module provides adapters for various proxy services used in web scraping.
 Supports ZenRows, Scrape.do, and ScrapingFish proxy services.
|#

(require racket/contract
         net/uri-codec
         net/url)

(provide
 (contract-out
  ;; ZenRows proxy adapter
  [zenrows-proxy-adaptor 
   (->* (string?)
        (#:apikey string?
         #:js_render boolean?
         #:custom_headers boolean?
         #:premium_proxy boolean?
         #:proxy_country string?
         #:session_id string?
         #:device string?
         #:original_status boolean?
         #:allowed_status_codes string?
         #:wait_for string?
         #:wait (or/c #f exact-nonnegative-integer?)
         #:block_resources string?
         #:json_response boolean?
         #:css_extractor string?
         #:autoparse boolean?
         #:markdown_response boolean?
         #:screenshot boolean?
         #:screenshot_fullpage boolean?
         #:screenshot_selector string?)
        string?)]
  
  ;; Scrape.do proxy adapter
  [scrape-do-proxy-adaptor
   (->* (string?)
        (#:token string?
         #:super boolean?
         #:geoCode string?
         #:regionalGeoCode string?
         #:sessionId string?
         #:customHeaders string?
         #:extraHeaders string?
         #:forwardHeaders string?
         #:setCookies string?
         #:disableRedirection boolean?
         #:callback string?
         #:timeout (or/c #f exact-nonnegative-integer?)
         #:retryTimeout (or/c #f exact-nonnegative-integer?)
         #:disableRetry boolean?
         #:device string?
         #:render boolean?
         #:waitUntil string?
         #:customWait (or/c #f exact-nonnegative-integer?)
         #:waitSelector string?
         #:width (or/c #f exact-nonnegative-integer?)
         #:height (or/c #f exact-nonnegative-integer?)
         #:blockResources boolean?
         #:screenShot boolean?
         #:fullScreenShot boolean?
         #:particularScreenShot string?
         #:playWithBrowser string?
         #:transparentResponse boolean?
         #:returnJSON boolean?)
        string?)]
  
  ;; ScrapingFish proxy adapter
  [scraping-fish-proxy-adaptor
   (->* (string?)
        (#:api-key string?
         #:render-js boolean?
         #:custom-headers string?)
        string?)]
  
  ;; Utility functions
  [extract-url-from-proxy (-> string? string?)]
  [is-proxied-url? (-> string? boolean?)]
  [get-proxy-service (-> string? (or/c 'zenrows 'scrape-do 'scraping-fish #f))]))

;; Environment Variables
;; ---------------------

(define ZENROWS_API_KEY 
  (or (getenv "ZENROWS_API_KEY") ""))

(define SCRAPING_FISH_API_KEY 
  (or (getenv "SCRAPING_FISH_API_KEY") ""))

(define SCRAPE_DO_API_KEY 
  (or (getenv "SCRAPE_DO_API_KEY") ""))

;; Helper Functions
;; ----------------

;; @function{bool->string}
;; @description{Convert boolean to string representation}
;; @param[b]{boolean?} Boolean value
;; @returns{string?} "true" or "false"
(define (bool->string b)
  (if b "true" "false"))

;; @function{param->string}
;; @description{Convert parameter value to string}
;; @param[param]{symbol?} Parameter name
;; @param[value]{any/c} Parameter value
;; @returns{(or/c pair? #f)} Parameter pair or #f
(define (param->string param value)
  (cond
    [(boolean? value) (cons param (bool->string value))]
    [(number? value) (cons param (number->string value))]
    [(string? value) (cons param value)]
    [else #f]))

;; @function{build-query-string}
;; @description{Build URL query string from parameters}
;; @param[params]{listof pair?} List of parameter pairs
;; @returns{string?} Query string
(define (build-query-string params)
  (string-join
   (map (lambda (pair)
          (string-append (uri-encode (symbol->string (car pair)))
                         "="
                         (uri-encode (cdr pair))))
        params)
   "&"))

;; Scrape.do Proxy Adapter
;; -----------------------

;; @function{scrape-do-proxy-adaptor}
;; @description{Create proxy URL for Scrape.do service}
;; @param[base-url]{string?} URL to proxy
;; @returns{string?} Proxied URL
(define (scrape-do-proxy-adaptor base-url
                                 #:token [token SCRAPE_DO_API_KEY]
                                 #:super [super #f]
                                 #:geoCode [geoCode #f]
                                 #:regionalGeoCode [regionalGeoCode #f]
                                 #:sessionId [sessionId #f]
                                 #:customHeaders [customHeaders #f]
                                 #:extraHeaders [extraHeaders #f]
                                 #:forwardHeaders [forwardHeaders #f]
                                 #:setCookies [setCookies #f]
                                 #:disableRedirection [disableRedirection #f]
                                 #:callback [callback #f]
                                 #:timeout [timeout #f]
                                 #:retryTimeout [retryTimeout #f]
                                 #:disableRetry [disableRetry #f]
                                 #:device [device #f]
                                 #:render [render #f]
                                 #:waitUntil [waitUntil #f]
                                 #:customWait [customWait #f]
                                 #:waitSelector [waitSelector #f]
                                 #:width [width #f]
                                 #:height [height #f]
                                 #:blockResources [blockResources #f]
                                 #:screenShot [screenShot #f]
                                 #:fullScreenShot [fullScreenShot #f]
                                 #:particularScreenShot [particularScreenShot #f]
                                 #:playWithBrowser [playWithBrowser #f]
                                 #:transparentResponse [transparentResponse #f]
                                 #:returnJSON [returnJSON #f])
  
  (define base-params
    `((token . ,token)
      (url . ,base-url)))
  
  (define optional-params
    (filter values  ; Remove #f values
            (map (lambda (param-value)
                   (and (cadr param-value)
                        (param->string (car param-value) (cadr param-value))))
                 `((super ,super)
                   (geoCode ,geoCode)
                   (regionalGeoCode ,regionalGeoCode)
                   (sessionId ,sessionId)
                   (customHeaders ,customHeaders)
                   (extraHeaders ,extraHeaders)
                   (forwardHeaders ,forwardHeaders)
                   (setCookies ,setCookies)
                   (disableRedirection ,disableRedirection)
                   (callback ,callback)
                   (timeout ,timeout)
                   (retryTimeout ,retryTimeout)
                   (disableRetry ,disableRetry)
                   (device ,device)
                   (render ,render)
                   (waitUntil ,waitUntil)
                   (customWait ,customWait)
                   (waitSelector ,waitSelector)
                   (width ,width)
                   (height ,height)
                   (blockResources ,blockResources)
                   (screenShot ,screenShot)
                   (fullScreenShot ,fullScreenShot)
                   (particularScreenShot ,particularScreenShot)
                   (playWithBrowser ,playWithBrowser)
                   (transparentResponse ,transparentResponse)
                   (returnJSON ,returnJSON)))))
  
  (define all-params (append base-params optional-params))
  (define query-string (build-query-string all-params))
  
  (string-append "https://api.scrape.do?" query-string))

;; ZenRows Proxy Adapter
;; ---------------------

;; @function{zenrows-proxy-adaptor}
;; @description{Create proxy URL for ZenRows service}
;; @param[base-url]{string?} URL to proxy
;; @returns{string?} Proxied URL
(define (zenrows-proxy-adaptor base-url 
                              #:apikey [apikey ZENROWS_API_KEY]
                              #:js_render [js_render #f]
                              #:custom_headers [custom_headers #f]
                              #:premium_proxy [premium_proxy #f]
                              #:proxy_country [proxy_country ""]
                              #:session_id [session_id ""]
                              #:device [device "desktop"]
                              #:original_status [original_status #f]
                              #:allowed_status_codes [allowed_status_codes ""]
                              #:wait_for [wait_for ""]
                              #:wait [wait #f]
                              #:block_resources [block_resources ""]
                              #:json_response [json_response #f]
                              #:css_extractor [css_extractor ""]
                              #:autoparse [autoparse #f]
                              #:markdown_response [markdown_response #f]
                              #:screenshot [screenshot #f]
                              #:screenshot_fullpage [screenshot_fullpage #f]
                              #:screenshot_selector [screenshot_selector ""])
  
  (define base-params
    `((apikey . ,apikey)
      (url . ,base-url)))
  
  (define optional-params
    (filter (lambda (pair) (and (cdr pair) (not (equal? (cdr pair) ""))))
            `((js_render . ,(if js_render "true" #f))
              (custom_headers . ,(if custom_headers "true" #f))
              (premium_proxy . ,(if premium_proxy "true" #f))
              (proxy_country . ,proxy_country)
              (session_id . ,session_id)
              (device . ,device)
              (original_status . ,(if original_status "true" #f))
              (allowed_status_codes . ,allowed_status_codes)
              (wait_for . ,wait_for)
              (wait . ,(if wait (number->string wait) #f))
              (block_resources . ,block_resources)
              (json_response . ,(if json_response "true" #f))
              (css_extractor . ,css_extractor)
              (autoparse . ,(if autoparse "true" #f))
              (markdown_response . ,(if markdown_response "true" #f))
              (screenshot . ,(if screenshot "true" #f))
              (screenshot_fullpage . ,(if screenshot_fullpage "true" #f))
              (screenshot_selector . ,screenshot_selector))))
  
  (define all-params (append base-params optional-params))
  (define query-string (build-query-string all-params))
  
  (string-append "https://api.zenrows.com/v1/?" query-string))

;; ScrapingFish Proxy Adapter
;; --------------------------

;; @function{scraping-fish-proxy-adaptor}
;; @description{Create proxy URL for ScrapingFish service}
;; @param[url]{string?} URL to proxy
;; @returns{string?} Proxied URL
(define (scraping-fish-proxy-adaptor url
                                    #:api-key [api-key SCRAPING_FISH_API_KEY]
                                    #:render-js [render-js #t]
                                    #:custom-headers [custom-headers #f])
  
  (define base-url "https://scraping.narf.ai/api/v1/")
  
  (define base-params
    `((api_key . ,api-key)
      (url . ,url)
      (render_js . ,(if render-js "true" "false"))))
  
  (define optional-params
    (if custom-headers
        `((custom_headers . ,custom-headers))
        '()))
  
  (define all-params (append base-params optional-params))
  (define query-string (build-query-string all-params))
  
  (string-append base-url "?" query-string))

;; Utility Functions
;; -----------------

;; @function{extract-url-from-zenrows}
;; @description{Extract original URL from ZenRows proxy URL}
;; @param[zenrows-url]{string?} ZenRows proxy URL
;; @returns{string?} Original URL
(define (extract-url-from-zenrows zenrows-url)
  (with-handlers ([exn:fail? (lambda (e) zenrows-url)])
    (let* ([url-obj (string->url zenrows-url)]
           [query (url-query url-obj)]
           [url-param (findf (lambda (param) (equal? (car param) 'url)) query)])
      (if url-param
          (uri-decode (cdr url-param))
          zenrows-url))))

;; @function{extract-url-from-scrape-do}
;; @description{Extract original URL from Scrape.do proxy URL}
;; @param[scrape-do-url]{string?} Scrape.do proxy URL
;; @returns{string?} Original URL
(define (extract-url-from-scrape-do scrape-do-url)
  (with-handlers ([exn:fail? (lambda (e) scrape-do-url)])
    (let* ([url-obj (string->url scrape-do-url)]
           [query (url-query url-obj)]
           [url-param (findf (lambda (param) (equal? (car param) 'url)) query)])
      (if url-param
          (uri-decode (cdr url-param))
          scrape-do-url))))

;; @function{extract-url-from-scraping-fish}
;; @description{Extract original URL from ScrapingFish proxy URL}
;; @param[sf-url]{string?} ScrapingFish proxy URL
;; @returns{string?} Original URL
(define (extract-url-from-scraping-fish sf-url)
  (with-handlers ([exn:fail? (lambda (e) sf-url)])
    (let* ([url-obj (string->url sf-url)]
           [query (url-query url-obj)]
           [url-param (findf (lambda (param) (equal? (car param) 'url)) query)])
      (if url-param
          (uri-decode (cdr url-param))
          sf-url))))

;; @function{extract-url-from-proxy}
;; @description{Extract original URL from any supported proxy URL}
;; @param[proxy-url]{string?} Proxy URL
;; @returns{string?} Original URL
(define (extract-url-from-proxy proxy-url)
  (let ([service (get-proxy-service proxy-url)])
    (case service
      [(zenrows) (extract-url-from-zenrows proxy-url)]
      [(scrape-do) (extract-url-from-scrape-do proxy-url)]
      [(scraping-fish) (extract-url-from-scraping-fish proxy-url)]
      [else proxy-url])))

;; @function{is-proxied-url?}
;; @description{Check if URL is a proxy URL}
;; @param[url]{string?} URL to check
;; @returns{boolean?} True if proxied
(define (is-proxied-url? url)
  (not (eq? #f (get-proxy-service url))))

;; @function{get-proxy-service}
;; @description{Identify which proxy service a URL is from}
;; @param[url]{string?} URL to check
;; @returns{(or/c symbol? #f)} Proxy service name or #f
(define (get-proxy-service url)
  (cond
    [(string-contains? url "api.zenrows.com") 'zenrows]
    [(string-contains? url "api.scrape.do") 'scrape-do]
    [(string-contains? url "scraping.narf.ai") 'scraping-fish]
    [else #f]))

;; Example Usage Comments
;; ----------------------

;; Example 1: Basic ZenRows usage
;; (zenrows-proxy-adaptor "https://example.com" #:js_render #t)

;; Example 2: ZenRows with premium proxy in Australia
;; (zenrows-proxy-adaptor "https://example.com" 
;;                        #:js_render #t 
;;                        #:premium_proxy #t 
;;                        #:proxy_country "au")

;; Example 3: Scrape.do with geolocation
;; (scrape-do-proxy-adaptor "https://example.com" 
;;                         #:geoCode "au" 
;;                         #:render #t)

;; Example 4: ScrapingFish with custom headers
;; (scraping-fish-proxy-adaptor "https://example.com"
;;                             #:render-js #t
;;                             #:custom-headers "{\"User-Agent\": \"Custom\"}")

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "URL extraction from proxy URLs"
    (define zenrows-url 
      "https://api.zenrows.com/v1/?apikey=KEY&url=https%3A%2F%2Fexample.com")
    (check-equal? (extract-url-from-zenrows zenrows-url) 
                  "https://example.com"))
  
  (test-case "Proxy service identification"
    (check-eq? (get-proxy-service "https://api.zenrows.com/v1/?url=test") 
               'zenrows)
    (check-eq? (get-proxy-service "https://api.scrape.do?url=test") 
               'scrape-do)
    (check-eq? (get-proxy-service "https://example.com") 
               #f))
  
  (test-case "Boolean to string conversion"
    (check-equal? (bool->string #t) "true")
    (check-equal? (bool->string #f) "false")))
