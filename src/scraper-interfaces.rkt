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
