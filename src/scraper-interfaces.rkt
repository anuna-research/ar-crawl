#lang racket

#|
 @title{Scraper Interfaces}
 @author{Anuna Research}
 @date{2025-06-11}
 
 This module provides contract definitions and data structures for the universal scraper system.
|#

(require racket/contract
         gregor)

(provide
 ;; Data structures
 (struct-out extraction-spec)
 (struct-out xpath-target)
 (struct-out job-status)
 (struct-out job-results)
 (struct-out extracted-item)
 (struct-out scraper-config)
 (struct-out parser-metrics)
 (struct-out formatter)
 
 ;; Exception types
 (struct-out exn:scraper)
 (struct-out exn:scraper:network)
 (struct-out exn:scraper:parse)
 (struct-out exn:scraper:xpath)
 (struct-out exn:scraper:llm)
 
 ;; Contracts
 extraction-spec/c
 xpath-target/c
 job-status/c
 job-results/c
 extracted-item/c
 scraper-config/c
 parser/c
 parser-metrics/c
 formatter/c
 llm-provider/c
 proxy-adapter/c
 job-id/c)

;; Data Structures
;; ---------------

(struct extraction-spec
  (parent-description   ; Natural language description of parent container
   field-descriptions   ; List of field descriptions
   constraints)         ; Additional constraints or filters
  #:transparent)

(struct xpath-target
  (parent-xpath        ; XPath to parent container
   child-xpaths)       ; Hash of field-name -> xpath
  #:transparent)

(struct job-status
  (id
   state              ; 'running | 'paused | 'completed | 'failed
   pages-processed
   items-extracted
   start-time
   elapsed-time
   errors)
  #:transparent)

(struct job-results
  (data              ; List of extracted items
   metadata          ; Job metadata
   errors)           ; Any errors encountered
  #:transparent)

(struct extracted-item
  (url           ; Source URL
   timestamp     ; Extraction timestamp
   data          ; Extracted fields
   metadata)     ; Additional metadata
  #:transparent)

(struct scraper-config
  (start-url
   extraction-spec
   url-pattern
   output-dir
   output-format
   use-proxy?
   use-cache?
   model
   rate-limit
   max-pages
   currency)
  #:transparent)

(struct parser-metrics
  (success-rate      ; Percentage of non-empty extractions
   field-coverage     ; Which fields were successfully extracted
   error-count)       ; Number of extraction errors
  #:transparent)

(struct formatter
  (type              ; 'json | 'csv | 'ndjson
   output-port       ; Output port for writing
   header-written?)  ; For CSV, whether header has been written
  #:mutable
  #:transparent)

;; Exception Types
;; ---------------

(struct exn:scraper exn:fail () #:transparent)
(struct exn:scraper:network exn:scraper () #:transparent)
(struct exn:scraper:parse exn:scraper () #:transparent)
(struct exn:scraper:xpath exn:scraper () #:transparent)
(struct exn:scraper:llm exn:scraper () #:transparent)

;; Contracts
;; ---------

(define extraction-spec/c
  (struct/c extraction-spec string? (listof string?) (or/c #f hash?)))

(define xpath-target/c
  (struct/c xpath-target string? (hash/c symbol? string?)))

(define job-status/c
  (struct/c job-status
            string?
            (or/c 'running 'paused 'completed 'failed)
            exact-nonnegative-integer?
            exact-nonnegative-integer?
            exact-integer?
            real?
            (listof string?)))

(define job-results/c
  (struct/c job-results
            (listof extracted-item?)
            hash?
            (listof any/c)))

(define extracted-item/c
  (struct/c extracted-item
            string?
            moment?
            hash?
            (hash/c symbol? any/c)))

(define scraper-config/c
  (struct/c scraper-config
            string?
            extraction-spec?
            (or/c #f string?)
            path-string?
            symbol?
            boolean?
            boolean?
            symbol?
            exact-positive-integer?
            (or/c #f exact-positive-integer?)
            string?))

(define parser/c 
  (-> any/c (listof hash?)))

(define parser-metrics/c
  (struct/c parser-metrics
            (real-in 0 1)
            (listof symbol?)
            exact-nonnegative-integer?))

(define formatter/c
  (struct/c formatter
            (or/c 'json 'csv 'ndjson)
            output-port?
            boolean?))

(define job-id/c string?)

(define llm-provider/c
  (object/c
   [generate-xpaths (-> string? string? (or/c #f xpath-target?))]
   [refine-xpaths (-> string? xpath-target? (listof string?) xpath-target?)]))

(define proxy-adapter/c
  (-> string?              ; original URL
      #:js-render boolean?
      #:country string?
      string?))            ; proxied URL

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit)

  ;; extraction-spec Tests
  (test-case "extraction-spec struct creation"
    (let ([spec (extraction-spec "product cards" '("name" "price") #f)])
      (check-true (extraction-spec? spec))
      (check-equal? (extraction-spec-parent-description spec) "product cards")
      (check-equal? (extraction-spec-field-descriptions spec) '("name" "price"))
      (check-false (extraction-spec-constraints spec))))

  (test-case "extraction-spec with constraints"
    (let ([spec (extraction-spec "items" '("title") (hash 'min-length 10))])
      (check-true (hash? (extraction-spec-constraints spec)))
      (check-equal? (hash-ref (extraction-spec-constraints spec) 'min-length) 10)))

  ;; xpath-target Tests
  (test-case "xpath-target struct creation"
    (let ([target (xpath-target "//div[@class='product']"
                                (hash 'name ".//h2" 'price ".//span"))])
      (check-true (xpath-target? target))
      (check-equal? (xpath-target-parent-xpath target) "//div[@class='product']")
      (check-equal? (hash-ref (xpath-target-child-xpaths target) 'name) ".//h2")))

  (test-case "xpath-target with empty child-xpaths"
    (let ([target (xpath-target "//div" (hash))])
      (check-equal? (hash-count (xpath-target-child-xpaths target)) 0)))

  ;; job-status Tests
  (test-case "job-status struct creation"
    (let ([status (job-status "job-123" 'running 10 50 1000 5000 '())])
      (check-true (job-status? status))
      (check-equal? (job-status-id status) "job-123")
      (check-equal? (job-status-state status) 'running)
      (check-equal? (job-status-pages-processed status) 10)
      (check-equal? (job-status-items-extracted status) 50)))

  (test-case "job-status with errors"
    (let ([status (job-status "job-123" 'failed 5 20 1000 3000
                              '("Network error" "Parse error"))])
      (check-equal? (job-status-state status) 'failed)
      (check-equal? (length (job-status-errors status)) 2)))

  (test-case "job-status states"
    (check-equal? (job-status-state (job-status "j" 'running 0 0 0 0 '())) 'running)
    (check-equal? (job-status-state (job-status "j" 'paused 0 0 0 0 '())) 'paused)
    (check-equal? (job-status-state (job-status "j" 'completed 0 0 0 0 '())) 'completed)
    (check-equal? (job-status-state (job-status "j" 'failed 0 0 0 0 '())) 'failed))

  ;; job-results Tests
  (test-case "job-results struct creation"
    (let ([results (job-results '() (hash 'url "http://test.com") '())])
      (check-true (job-results? results))
      (check-equal? (job-results-data results) '())
      (check-true (hash? (job-results-metadata results)))))

  (test-case "job-results with data and errors"
    (let ([results (job-results
                    (list (extracted-item "url" (now/moment) (hash) (hash)))
                    (hash)
                    '("error1"))])
      (check-equal? (length (job-results-data results)) 1)
      (check-equal? (length (job-results-errors results)) 1)))

  ;; extracted-item Tests
  (test-case "extracted-item struct creation"
    (let* ([ts (now/moment)]
           [item (extracted-item "http://example.com" ts
                                 (hash 'name "Test") (hash 'source 'crawler))])
      (check-true (extracted-item? item))
      (check-equal? (extracted-item-url item) "http://example.com")
      (check-equal? (hash-ref (extracted-item-data item) 'name) "Test")))

  ;; scraper-config Tests
  (test-case "scraper-config struct creation"
    (let* ([spec (extraction-spec "items" '("name") #f)]
           [config (scraper-config
                    "http://example.com" spec ".*"
                    "/output" 'json #f #t 'gpt-4 1000 100 "USD")])
      (check-true (scraper-config? config))
      (check-equal? (scraper-config-start-url config) "http://example.com")
      (check-equal? (scraper-config-output-format config) 'json)
      (check-true (scraper-config-use-cache? config))))

  ;; parser-metrics Tests
  (test-case "parser-metrics struct creation"
    (let ([metrics (parser-metrics 0.85 '(name price) 5)])
      (check-true (parser-metrics? metrics))
      (check-equal? (parser-metrics-success-rate metrics) 0.85)
      (check-equal? (parser-metrics-field-coverage metrics) '(name price))
      (check-equal? (parser-metrics-error-count metrics) 5)))

  ;; formatter Tests
  (test-case "formatter struct creation"
    (let ([fmt (formatter 'json (current-output-port) #f)])
      (check-true (formatter? fmt))
      (check-equal? (formatter-type fmt) 'json)
      (check-false (formatter-header-written? fmt))))

  (test-case "formatter mutable fields"
    (let ([fmt (formatter 'csv (current-output-port) #f)])
      (set-formatter-header-written?! fmt #t)
      (check-true (formatter-header-written? fmt))))

  ;; Exception Types Tests
  (test-case "exn:scraper exception"
    (check-true
     (exn:scraper?
      (exn:scraper "Test error" (current-continuation-marks)))))

  (test-case "exn:scraper:network exception"
    (let ([ex (exn:scraper:network "Network failed" (current-continuation-marks))])
      (check-true (exn:scraper:network? ex))
      (check-true (exn:scraper? ex))))

  (test-case "exn:scraper:parse exception"
    (let ([ex (exn:scraper:parse "Parse error" (current-continuation-marks))])
      (check-true (exn:scraper:parse? ex))
      (check-true (exn:scraper? ex))))

  (test-case "exn:scraper:xpath exception"
    (let ([ex (exn:scraper:xpath "Invalid XPath" (current-continuation-marks))])
      (check-true (exn:scraper:xpath? ex))
      (check-true (exn:scraper? ex))))

  (test-case "exn:scraper:llm exception"
    (let ([ex (exn:scraper:llm "LLM failed" (current-continuation-marks))])
      (check-true (exn:scraper:llm? ex))
      (check-true (exn:scraper? ex))))

  ;; Contract Tests
  (test-case "job-id/c is string?"
    (check-true (string? "job-123")))

  (test-case "parser/c signature"
    (let ([parser (lambda (x) '())])
      (check-true (procedure? parser))
      (check-equal? (parser "input") '()))))
