#lang racket

#|
 @title{Data Formatter}
 @author{Anuna Research}
 @date{2024-06-11}
 
 This module formats extracted data into various output formats.
|#

(require racket/contract
         racket/match
         json
         csv-writing
         racket/port)

(require "scraper-interfaces.rkt")

(provide
 (contract-out
  ;; Format data based on format type
  [format-data
   (-> (listof hash?) 
       (or/c 'json 'csv 'ndjson) 
       path-string?
       boolean?)]
  
  ;; Stream formatter for large datasets
  [create-streaming-formatter
   (-> (or/c 'json 'csv 'ndjson)
       path-string?
       formatter?)]
  
  ;; Formatter operations
  [write-item (-> formatter? hash? void?)]
  [close-formatter (-> formatter? void?)]))

;; @function{format-data}
;; @description{Format and save data to file in specified format}
;; @param[data]{listof hash?} Data to format
;; @param[format]{(or/c 'json 'csv 'ndjson)} Output format
;; @param[output-path]{path-string?} Output file path
;; @returns{boolean?} Success status
(define (format-data data format output-path)
  (with-handlers ([exn:fail? 
                   (lambda (exn)
                     (raise (exn:scraper:parse
                             (format "Failed to format data: ~a" 
                                     (exn-message exn))
                             (current-continuation-marks))))])
    
    ;; Ensure output directory exists
    (let ([dir (path-only output-path)])
      (when dir
        (make-directory* dir)))
    
    (match format
      ['json (save-as-json data output-path)]
      ['csv (save-as-csv data output-path)]
      ['ndjson (save-as-ndjson data output-path)]
      [else (error 'format-data "Unknown format: ~a" format)])
    
    #t))

;; @function{save-as-json}
;; @description{Save data as JSON array}
;; @param[data]{listof hash?} Data to save
;; @param[output-path]{path-string?} Output file path
;; @returns{void?}
(define (save-as-json data output-path)
  (call-with-output-file output-path
    (lambda (out)
      (write-json data out))
    #:exists 'replace))

;; @function{save-as-csv}
;; @description{Save data as CSV}
;; @param[data]{listof hash?} Data to save
;; @param[output-path]{path-string?} Output file path
;; @returns{void?}
(define (save-as-csv data output-path)
  (when (empty? data)
    (call-with-output-file output-path
      (lambda (out) (void))
      #:exists 'replace))
  
  (let* ([headers (extract-headers data)]
         [rows (map (lambda (item) (hash->row item headers)) data)])
    
    (call-with-output-file output-path
      (lambda (out)
        (display-table (cons headers rows) out))
      #:exists 'replace)))

;; @function{save-as-ndjson}
;; @description{Save data as newline-delimited JSON}
;; @param[data]{listof hash?} Data to save
;; @param[output-path]{path-string?} Output file path
;; @returns{void?}
(define (save-as-ndjson data output-path)
  (call-with-output-file output-path
    (lambda (out)
      (for ([item data])
        (write-json item out)
        (newline out)))
    #:exists 'replace))

;; @function{extract-headers}
;; @description{Extract all unique headers from data}
;; @param[data]{listof hash?} Data items
;; @returns{listof string?} List of headers
(define (extract-headers data)
  (let ([all-keys (apply set-union 
                         (map (lambda (item) 
                                (list->set (hash-keys item))) 
                              data))])
    (sort (set->list all-keys) symbol<?)))

;; @function{hash->row}
;; @description{Convert hash to CSV row based on headers}
;; @param[item]{hash?} Data item
;; @param[headers]{listof symbol?} Headers
;; @returns{listof string?} Row values
(define (hash->row item headers)
  (map (lambda (header)
         (let ([value (hash-ref item header "")])
           (cond
             [(string? value) value]
             [(number? value) (number->string value)]
             [(boolean? value) (if value "true" "false")]
             [else (format "~a" value)])))
       headers))

;; @function{create-streaming-formatter}
;; @description{Create a streaming formatter for large datasets}
;; @param[format]{(or/c 'json 'csv 'ndjson)} Output format
;; @param[output-path]{path-string?} Output file path
;; @returns{formatter?} Formatter instance
(define (create-streaming-formatter format output-path)
  (let* ([dir (path-only output-path)]
         [_ (when dir (make-directory* dir))]
         [out (open-output-file output-path #:exists 'replace)])
    
    (match format
      ['json 
       (begin
         (write-string "[" out)
         (formatter 'json out #f))]
      
      ['csv 
       (formatter 'csv out #f)]
      
      ['ndjson 
       (formatter 'ndjson out #t)]
      
      [else 
       (begin
         (close-output-port out)
         (error 'create-streaming-formatter 
                "Unknown format: ~a" format))])))

;; @function{write-item}
;; @description{Write a single item to the formatter}
;; @param[fmt]{formatter?} Formatter instance
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-item fmt item)
  (match (formatter-type fmt)
    ['json (write-json-item fmt item)]
    ['csv (write-csv-item fmt item)]
    ['ndjson (write-ndjson-item fmt item)]))

;; @function{write-json-item}
;; @description{Write item in JSON format}
;; @param[fmt]{formatter?} Formatter
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-json-item fmt item)
  (let ([out (formatter-output-port fmt)])
    (when (formatter-header-written? fmt)
      (write-string "," out)
      (newline out))
    (write-json item out)
    (set-formatter-header-written?! fmt #t)))

;; @function{write-csv-item}
;; @description{Write item in CSV format}
;; @param[fmt]{formatter?} Formatter
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-csv-item fmt item)
  (let ([out (formatter-output-port fmt)]
        [headers (sort (hash-keys item) symbol<?)])
    
    ;; Write header if first item
    (unless (formatter-header-written? fmt)
      (display-table (list (map symbol->string headers)) out)
      (set-formatter-header-written?! fmt #t))
    
    ;; Write data row
    (let ([row (hash->row item headers)])
      (display-table (list row) out))))

;; @function{write-ndjson-item}
;; @description{Write item in NDJSON format}
;; @param[fmt]{formatter?} Formatter
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-ndjson-item fmt item)
  (let ([out (formatter-output-port fmt)])
    (write-json item out)
    (newline out)))

;; @function{close-formatter}
;; @description{Close the formatter and finalize output}
;; @param[fmt]{formatter?} Formatter to close
;; @returns{void?}
(define (close-formatter fmt)
  (let ([out (formatter-output-port fmt)])
    (match (formatter-type fmt)
      ['json 
       (begin
         (write-string "]" out)
         (newline out))]
      [_ (void)])
    
    (close-output-port out)))

;; @function{display-table}
;; @description{Display data as CSV table}
;; @param[rows]{listof (listof string?)} Table rows
;; @param[out]{output-port?} Output port
;; @returns{void?}
(define (display-table rows out)
  (for ([row rows])
    (write-csv-line row out)))

;; @function{write-csv-line}
;; @description{Write a single CSV line}
;; @param[fields]{listof string?} Field values
;; @param[out]{output-port?} Output port
;; @returns{void?}
(define (write-csv-line fields out)
  (let ([escaped-fields (map escape-csv-field fields)])
    (display (string-join escaped-fields ",") out)
    (newline out)))

;; @function{escape-csv-field}
;; @description{Escape a CSV field value}
;; @param[field]{string?} Field value
;; @returns{string?} Escaped field
(define (escape-csv-field field)
  (if (or (string-contains? field ",")
          (string-contains? field "\"")
          (string-contains? field "\n"))
      (format "\"~a\"" 
              (string-replace field "\"" "\"\""))
      field))
