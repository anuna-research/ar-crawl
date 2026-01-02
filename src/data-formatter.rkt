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

(require "scraper-interfaces.rkt"
         "sqlite-formatter.rkt")

(provide
 (contract-out
  ;; Format data based on format type
  [format-data
   (-> (listof hash?) 
       (or/c 'json 'csv 'ndjson 'sqlite) 
       path-string?
       boolean?)]
  
  ;; SQLite formatting with metadata
  [format-data-with-metadata
   (-> (listof hash?)
       (or/c 'json 'csv 'ndjson 'sqlite)
       path-string?
       hash?
       boolean?)]

  ;; Query helpers for SQLite
  [load-crawled-pages
   (-> path-string? (listof hash?))]

  [analyze-crawl-stats
   (-> path-string? hash?)]
  
  ;; Stream formatter for large datasets
  [create-streaming-formatter
   (-> (or/c 'json 'csv 'ndjson 'sqlite)
       path-string?
       (or/c formatter? sqlite-formatter?))]
  
  ;; Formatter operations
  [write-item (-> (or/c formatter? sqlite-formatter?) hash? void?)]
  [close-formatter (-> (or/c formatter? sqlite-formatter?) void?)]
  
  ;; SQLite-specific operations
  [write-item-sqlite (-> sqlite-formatter? hash? void?)]
  [close-sqlite-formatter (-> sqlite-formatter? void?)]))

;; @function{format-data}
;; @description{Format and save data to file in specified format}
;; @param[data]{listof hash?} Data to format
;; @param[format]{(or/c 'json 'csv 'ndjson)} Output format
;; @param[output-path]{path-string?} Output file path
;; @returns{boolean?} Success status
(define (format-data data output-format output-path)
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

    (match output-format
      ['json (save-as-json data output-path)]
      ['csv (save-as-csv data output-path)]
      ['ndjson (save-as-ndjson data output-path)]
      ['sqlite (format-data-sqlite data output-path (hash))]
      [else (error 'format-data "Unknown format: ~a" output-format)])

    #t))

;; @function{format-data-with-metadata}
;; @description{Format and save data with metadata (required for SQLite)}
;; @param[data]{listof hash?} Data to format
;; @param[output-format]{(or/c 'json 'csv 'ndjson 'sqlite)} Output format
;; @param[output-path]{path-string?} Output file path
;; @param[metadata]{hash?} Crawl metadata
;; @returns{boolean?} Success status
(define (format-data-with-metadata data output-format output-path metadata)
  (match output-format
    ['sqlite (format-data-sqlite data output-path metadata)]
    [else (format-data data output-format output-path)]))

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

  (unless (empty? data)
    (let* ([headers (extract-headers data)]
           [header-strings (map symbol->string headers)]
           [rows (map (lambda (item) (hash->row item headers)) data)])

      (call-with-output-file output-path
        (lambda (out)
          (display-table (cons header-strings rows) out))
        #:exists 'replace))))

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
  (if (empty? data)
      '()
      (let ([all-keys (apply set-union
                             (map (lambda (item)
                                    (list->set (hash-keys item)))
                                  data))])
        (sort (set->list all-keys) symbol<?))))

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
      
      ['sqlite
       (begin
         (close-output-port out)
         (create-sqlite-formatter output-path (hash)))]
      
      [else 
       (begin
         (close-output-port out)
         (error 'create-streaming-formatter 
                "Unknown format: ~a" format))])))

;; @function{write-item}
;; @description{Write a single item to the formatter}
;; @param[fmt]{(or/c formatter? sqlite-formatter?)} Formatter instance
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-item fmt item)
  (cond
    [(formatter? fmt)
     (match (formatter-type fmt)
       ['json (write-json-item fmt item)]
       ['csv (write-csv-item fmt item)]
       ['ndjson (write-ndjson-item fmt item)])]
    [(sqlite-formatter? fmt)
     (write-item-sqlite fmt item)]))

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
;; @param[fmt]{(or/c formatter? sqlite-formatter?)} Formatter to close
;; @returns{void?}
(define (close-formatter fmt)
  (cond
    [(formatter? fmt)
     (let ([out (formatter-output-port fmt)])
       (match (formatter-type fmt)
         ['json 
          (begin
            (write-string "]" out)
            (newline out))]
         [_ (void)])
       
       (close-output-port out))]
    [(sqlite-formatter? fmt)
     (close-sqlite-formatter fmt)]))

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

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit
           racket/file
           racket/runtime-path)

  ;; Test data
  (define test-data
    (list (hash 'name "Product A" 'price 19.99 'active #t)
          (hash 'name "Product B" 'price 29.99 'active #f)))

  (define test-data-with-extras
    (list (hash 'name "Item" 'price 10 'category "Books")
          (hash 'name "Other" 'price 20 'tags "a,b,c")))

  ;; Helper to create temp files
  (define (with-temp-file ext proc)
    (let ([path (make-temporary-file (format "test-~~a.~a" ext))])
      (dynamic-wind
        void
        (lambda () (proc path))
        (lambda () (when (file-exists? path) (delete-file path))))))

  ;; escape-csv-field Tests
  (test-case "escape-csv-field simple string"
    (check-equal? (escape-csv-field "hello") "hello"))

  (test-case "escape-csv-field with comma"
    (check-equal? (escape-csv-field "hello, world") "\"hello, world\""))

  (test-case "escape-csv-field with quote"
    (check-equal? (escape-csv-field "say \"hello\"") "\"say \"\"hello\"\"\""))

  (test-case "escape-csv-field with newline"
    (check-equal? (escape-csv-field "line1\nline2") "\"line1\nline2\""))

  (test-case "escape-csv-field empty string"
    (check-equal? (escape-csv-field "") ""))

  ;; extract-headers Tests
  (test-case "extract-headers gets all keys"
    (let ([headers (extract-headers test-data)])
      (check-true (list? headers))
      (check-equal? (length headers) 3)
      (check-not-false (member 'name headers))
      (check-not-false (member 'price headers))
      (check-not-false (member 'active headers))))

  (test-case "extract-headers handles different keys"
    (let ([headers (extract-headers test-data-with-extras)])
      (check-not-false (member 'category headers))
      (check-not-false (member 'tags headers))))

  (test-case "extract-headers returns sorted list"
    (let ([headers (extract-headers test-data)])
      (check-equal? headers (sort headers symbol<?))))

  ;; hash->row Tests
  (test-case "hash->row converts values correctly"
    (let* ([headers '(active name price)]
           [row (hash->row (car test-data) headers)])
      (check-equal? (length row) 3)
      (check-equal? (list-ref row 0) "true")
      (check-equal? (list-ref row 1) "Product A")
      (check-equal? (list-ref row 2) "19.99")))

  (test-case "hash->row handles missing keys"
    (let* ([headers '(name nonexistent)]
           [row (hash->row (hash 'name "test") headers)])
      (check-equal? (list-ref row 0) "test")
      (check-equal? (list-ref row 1) "")))

  (test-case "hash->row handles boolean values"
    (let ([row (hash->row (hash 'flag #t) '(flag))])
      (check-equal? (car row) "true"))
    (let ([row (hash->row (hash 'flag #f) '(flag))])
      (check-equal? (car row) "false")))

  ;; format-data Tests (JSON)
  (test-case "format-data writes JSON"
    (with-temp-file "json"
      (lambda (path)
        (check-true (format-data test-data 'json path))
        (check-true (file-exists? path))
        (let ([content (file->string path)])
          (check-true (string-contains? content "Product A"))
          (check-true (string-contains? content "19.99"))))))

  (test-case "format-data writes empty JSON"
    (with-temp-file "json"
      (lambda (path)
        (check-true (format-data '() 'json path))
        (let ([content (file->string path)])
          (check-equal? (string-trim content) "[]")))))

  ;; format-data Tests (CSV)
  (test-case "format-data writes CSV"
    (with-temp-file "csv"
      (lambda (path)
        (check-true (format-data test-data 'csv path))
        (check-true (file-exists? path))
        (let ([content (file->string path)])
          (check-true (string-contains? content "name"))
          (check-true (string-contains? content "Product A"))))))

  (test-case "format-data writes empty CSV"
    (with-temp-file "csv"
      (lambda (path)
        (check-true (format-data '() 'csv path))
        (check-true (file-exists? path)))))

  ;; format-data Tests (NDJSON)
  (test-case "format-data writes NDJSON"
    (with-temp-file "ndjson"
      (lambda (path)
        (check-true (format-data test-data 'ndjson path))
        (check-true (file-exists? path))
        (let* ([content (file->string path)]
               [lines (string-split content "\n")])
          ;; Should have one JSON object per line
          (check-true (>= (length lines) 2))))))

  ;; Streaming Formatter Tests
  (test-case "create-streaming-formatter json"
    (with-temp-file "json"
      (lambda (path)
        (let ([fmt (create-streaming-formatter 'json path)])
          (check-true (formatter? fmt))
          (check-equal? (formatter-type fmt) 'json)
          (close-formatter fmt)))))

  (test-case "create-streaming-formatter ndjson"
    (with-temp-file "ndjson"
      (lambda (path)
        (let ([fmt (create-streaming-formatter 'ndjson path)])
          (check-true (formatter? fmt))
          (check-equal? (formatter-type fmt) 'ndjson)
          (close-formatter fmt)))))

  (test-case "write-item with formatter"
    (with-temp-file "ndjson"
      (lambda (path)
        (let ([fmt (create-streaming-formatter 'ndjson path)])
          (write-item fmt (hash 'name "test"))
          (write-item fmt (hash 'name "test2"))
          (close-formatter fmt))
        (let* ([content (file->string path)]
               [lines (filter (lambda (s) (> (string-length s) 0))
                             (string-split content "\n"))])
          (check-equal? (length lines) 2)))))

  ;; JSON streaming formatter Tests
  (test-case "streaming json produces valid json array"
    (with-temp-file "json"
      (lambda (path)
        (let ([fmt (create-streaming-formatter 'json path)])
          (write-item fmt (hash 'a 1))
          (write-item fmt (hash 'b 2))
          (close-formatter fmt))
        (let ([content (file->string path)])
          (check-true (string-prefix? (string-trim content) "["))
          (check-true (string-suffix? (string-trim content) "]"))))))

  ;; CSV streaming formatter Tests
  (test-case "streaming csv writes header and rows"
    (with-temp-file "csv"
      (lambda (path)
        (let ([fmt (create-streaming-formatter 'csv path)])
          (write-item fmt (hash 'name "test" 'value 1))
          (write-item fmt (hash 'name "test2" 'value 2))
          (close-formatter fmt))
        (let* ([content (file->string path)]
               [lines (filter (lambda (s) (> (string-length s) 0))
                             (string-split content "\n"))])
          ;; Should have header + 2 data rows
          (check-true (>= (length lines) 2))))))

  ;; Directory Creation Tests
  (test-case "format-data creates output directory"
    (let ([dir (make-temporary-file "testdir-~a" 'directory)])
      (dynamic-wind
        void
        (lambda ()
          (let ([path (build-path dir "subdir" "output.json")])
            (check-true (format-data test-data 'json path))
            (check-true (file-exists? path))))
        (lambda ()
          (delete-directory/files dir)))))

  ;; Edge Cases
  (test-case "format-data handles special characters in strings"
    (with-temp-file "json"
      (lambda (path)
        (let ([data (list (hash 'text "line1\nline2\ttab"))])
          (check-true (format-data data 'json path))))))

  (test-case "format-data handles unicode"
    (with-temp-file "json"
      (lambda (path)
        (let ([data (list (hash 'text "日本語テスト"))])
          (check-true (format-data data 'json path))
          (let ([content (file->string path)])
            (check-true (string-contains? content "日本語テスト")))))))

  (test-case "hash->row handles various types"
    (let* ([item (hash 'str "text" 'num 42 'bool #t 'list '(1 2 3))]
           [row (hash->row item '(str num bool list))])
      (check-equal? (list-ref row 0) "text")
      (check-equal? (list-ref row 1) "42")
      (check-equal? (list-ref row 2) "true")
      (check-true (string? (list-ref row 3))))))
