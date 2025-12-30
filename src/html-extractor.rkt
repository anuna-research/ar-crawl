#lang racket

#|
 @title{HTML Extractor}
 @author{Anuna Research}
 @date{2025-12-30}

 Powerful HTML content extraction using sxml and sxpath libraries.
 Leverages the full power of sxpath for XPath queries on HTML.
|#

(require racket/contract
         racket/string
         racket/match
         racket/list
         json
         html-parsing
         sxml
         sxml/sxpath)

(provide
 (contract-out
  ;; Core extraction functions
  [extract-by-xpath (-> string? string? (listof any/c))]
  [extract-by-xpaths (-> string? (hash/c symbol? string?) (hash/c symbol? any/c))]
  [extract-items (-> string? string? (hash/c symbol? string?) (listof hash?))]

  ;; Text extraction from SXML
  [sxml->text (-> any/c string?)]
  [sxml->text-list (-> (listof any/c) (listof string?))]

  ;; Attribute extraction
  [sxml-attr (-> any/c symbol? (or/c string? #f))]
  [sxml-attrs (-> any/c (listof symbol?) hash?)]

  ;; Convenience extractors using sxpath
  [extract-text (-> string? string? (or/c string? #f))]
  [extract-text-all (-> string? string? (listof string?))]
  [extract-attr (-> string? string? symbol? (or/c string? #f))]
  [extract-attr-all (-> string? string? symbol? (listof string?))]

  ;; Table extraction
  [extract-table (-> string? (or/c string? #f) (listof (listof string?)))]

  ;; Batch extraction from crawl results
  [extract-from-crawl-results (-> (or/c path-string? hash?) (hash/c symbol? string?) (listof hash?))]
  [extract-from-json-file (-> path-string? (hash/c symbol? string?) (listof hash?))]

  ;; HTML parsing
  [html->sxml (-> string? any/c)]
  [make-xpath (-> string? procedure?)]))

;; ============================================================================
;; HTML Parsing
;; ============================================================================

;; @function{html->sxml}
;; @description{Parse HTML string to SXML representation}
(define (html->sxml html-str)
  (with-handlers ([exn:fail? (lambda (e) '(*TOP*))])
    (html->xexp html-str)))

;; @function{make-xpath}
;; @description{Create an sxpath function from xpath string}
(define (make-xpath xpath-expr)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "Invalid XPath (~a): ~a~n" xpath-expr (exn-message e))
                               (lambda (x) '()))])
    (sxpath xpath-expr)))

;; ============================================================================
;; Core Extraction Functions
;; ============================================================================

;; @function{extract-by-xpath}
;; @description{Extract nodes matching XPath expression from HTML}
;; @param[html-str]{string?} HTML content
;; @param[xpath-expr]{string?} XPath expression
;; @returns{listof any/c} Matching SXML nodes
(define (extract-by-xpath html-str xpath-expr)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "XPath extraction error: ~a~n" (exn-message e))
                               '())])
    (let* ([sxml (html->sxml html-str)]
           [xpath-fn (make-xpath xpath-expr)])
      (xpath-fn sxml))))

;; @function{extract-by-xpaths}
;; @description{Extract multiple fields using hash of field->xpath mappings}
;; @param[html-str]{string?} HTML content
;; @param[xpath-map]{hash?} Hash of field-name -> xpath expression
;; @returns{hash?} Hash of field-name -> extracted value(s)
(define (extract-by-xpaths html-str xpath-map)
  (let ([sxml (html->sxml html-str)])
    (for/hash ([(field xpath-expr) (in-hash xpath-map)])
      (let* ([xpath-fn (make-xpath xpath-expr)]
             [nodes (xpath-fn sxml)]
             [texts (sxml->text-list nodes)])
        (values field
                (cond
                  [(empty? texts) #f]
                  [(= 1 (length texts)) (car texts)]
                  [else texts]))))))

;; @function{extract-items}
;; @description{Extract repeated items (e.g., products) using parent + child xpaths}
;; @param[html-str]{string?} HTML content
;; @param[parent-xpath]{string?} XPath to parent containers
;; @param[field-xpaths]{hash?} Hash of field-name -> relative xpath for children
;; @returns{listof hash?} List of extracted item hashes
(define (extract-items html-str parent-xpath field-xpaths)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "Item extraction error: ~a~n" (exn-message e))
                               '())])
    (let* ([sxml (html->sxml html-str)]
           [parent-fn (make-xpath parent-xpath)]
           [parents (parent-fn sxml)])
      (for/list ([parent parents])
        (for/hash ([(field rel-xpath) (in-hash field-xpaths)])
          ;; Use sxpath on the parent node directly
          (let* ([xpath-fn (make-xpath rel-xpath)]
                 [nodes (xpath-fn (list '*TOP* parent))]
                 [value (if (empty? nodes)
                            #f
                            (let ([first-node (car nodes)])
                              (if (string? first-node)
                                  first-node
                                  (sxml->text first-node))))])
            (values field value)))))))

;; ============================================================================
;; Text Extraction from SXML
;; ============================================================================

;; @function{sxml->text}
;; @description{Extract all text content from an SXML node}
(define (sxml->text node)
  (string-normalize-spaces (sxml->text-raw node)))

;; @function{sxml->text-raw}
;; @description{Recursively extract text without normalization}
(define (sxml->text-raw node)
  (cond
    [(string? node) node]
    [(symbol? node) ""]
    [(and (pair? node) (eq? '@ (car node)))
     ;; Skip attribute lists
     ""]
    [(and (pair? node) (symbol? (car node)))
     ;; Skip script and style content, but process *TOP* and other elements
     (if (member (car node) '(script style))
         ""
         (apply string-append (map sxml->text-raw (cdr node))))]
    [(list? node) (apply string-append (map sxml->text-raw node))]
    [else ""]))

;; @function{sxml->text-list}
;; @description{Convert list of SXML nodes to list of text strings}
(define (sxml->text-list nodes)
  (for/list ([node nodes])
    (if (string? node)
        (string-normalize-spaces node)
        (sxml->text node))))

;; @function{string-normalize-spaces}
;; @description{Normalize whitespace - collapse multiple spaces, trim}
(define (string-normalize-spaces str)
  (string-trim (regexp-replace* #px"\\s+" str " ")))

;; ============================================================================
;; Attribute Extraction
;; ============================================================================

;; @function{sxml-attr}
;; @description{Extract attribute value from SXML element}
(define (sxml-attr node attr-name)
  (match node
    [(list tag (list '@ attrs ...) rest ...)
     (let ([attr (assoc attr-name attrs)])
       (and attr (>= (length attr) 2) (cadr attr)))]
    [(list tag rest ...)
     #f]
    [_ #f]))

;; @function{sxml-attrs}
;; @description{Extract multiple attributes from SXML element}
(define (sxml-attrs node attr-names)
  (for/hash ([name attr-names])
    (values name (sxml-attr node name))))

;; ============================================================================
;; Convenience Extractors
;; ============================================================================

;; @function{extract-text}
;; @description{Extract text content of first matching element}
(define (extract-text html-str xpath-expr)
  (let ([nodes (extract-by-xpath html-str xpath-expr)])
    (and (not (empty? nodes))
         (sxml->text (car nodes)))))

;; @function{extract-text-all}
;; @description{Extract text content of all matching elements}
(define (extract-text-all html-str xpath-expr)
  (sxml->text-list (extract-by-xpath html-str xpath-expr)))

;; @function{extract-attr}
;; @description{Extract attribute from first matching element}
(define (extract-attr html-str xpath-expr attr-name)
  (let ([nodes (extract-by-xpath html-str xpath-expr)])
    (and (not (empty? nodes))
         (sxml-attr (car nodes) attr-name))))

;; @function{extract-attr-all}
;; @description{Extract attribute from all matching elements}
(define (extract-attr-all html-str xpath-expr attr-name)
  (let ([nodes (extract-by-xpath html-str xpath-expr)])
    (filter-map (lambda (node) (sxml-attr node attr-name)) nodes)))

;; ============================================================================
;; Table Extraction
;; ============================================================================

;; @function{extract-table}
;; @description{Extract table data as list of rows using sxpath}
(define (extract-table html-str [table-xpath #f])
  (let* ([xpath (or table-xpath "//table")]
         [sxml (html->sxml html-str)]
         [table-fn (make-xpath xpath)]
         [tables (table-fn sxml)])
    (if (empty? tables)
        '()
        (let* ([table (car tables)]
               [row-fn (make-xpath ".//tr")]
               [rows (row-fn (list '*TOP* table))])
          (for/list ([row rows])
            (let* ([cell-fn (make-xpath ".//td|.//th")]
                   [cells (cell-fn (list '*TOP* row))])
              (sxml->text-list cells)))))))

;; ============================================================================
;; Batch Extraction from Crawl Results
;; ============================================================================

;; @function{extract-from-crawl-results}
;; @description{Extract fields from crawl results (JSON hash or file path)}
(define (extract-from-crawl-results source xpath-map)
  (let ([data (if (hash? source)
                  source
                  (load-json-file source))])
    (if (not data)
        '()
        (let ([items (hash-ref data 'data '())])
          (for/list ([item items]
                     #:when (and (hash? item) (hash-ref item 'content #f)))
            (let* ([content (hash-ref item 'content "")]
                   [url (hash-ref item 'url "")]
                   [title (hash-ref item 'title "")]
                   [extracted (extract-by-xpaths content xpath-map)])
              (hash-set (hash-set extracted
                                  'source_url url)
                        'source_title title)))))))

;; @function{extract-from-json-file}
;; @description{Alias for extract-from-crawl-results with file path}
(define (extract-from-json-file file-path xpath-map)
  (extract-from-crawl-results file-path xpath-map))

;; @function{load-json-file}
;; @description{Load and parse JSON file}
(define (load-json-file path)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "Error loading JSON: ~a~n" (exn-message e))
                               #f)])
    (call-with-input-file path
      (lambda (port)
        (string->jsexpr (port->string port))))))

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (define test-html
    "<html><body>
       <div class='product'>
         <h2 class='name'>Test Product</h2>
         <span class='price'>$19.99</span>
         <a href='/product/123'>Details</a>
       </div>
       <div class='product'>
         <h2 class='name'>Another Product</h2>
         <span class='price'>$29.99</span>
         <a href='/product/456'>Details</a>
       </div>
       <table>
         <tr><th>Name</th><th>Price</th></tr>
         <tr><td>Item 1</td><td>$10</td></tr>
       </table>
     </body></html>")

  (test-case "extract-by-xpath returns nodes"
    (let ([results (extract-by-xpath test-html "//h2")])
      (check-equal? (length results) 2)))

  (test-case "extract-text gets first match"
    (let ([text (extract-text test-html "//h2[@class='name']")])
      (check-equal? text "Test Product")))

  (test-case "extract-text-all gets all matches"
    (let ([texts (extract-text-all test-html "//span[@class='price']")])
      (check-equal? texts '("$19.99" "$29.99"))))

  (test-case "extract-attr gets attribute"
    (let ([href (extract-attr test-html "//a" 'href)])
      (check-equal? href "/product/123")))

  (test-case "extract-by-xpaths returns hash"
    (let ([result (extract-by-xpaths test-html
                                     (hash 'name "//h2[@class='name']"
                                           'price "//span[@class='price']"))])
      (check-true (hash? result))
      ;; Multiple matches returns a list
      (check-equal? (hash-ref result 'name) '("Test Product" "Another Product"))
      (check-equal? (hash-ref result 'price) '("$19.99" "$29.99"))))

  (test-case "extract-items returns list of hashes"
    (let ([items (extract-items test-html
                                "//div[@class='product']"
                                (hash 'name ".//h2"
                                      'price ".//span[@class='price']"
                                      'link ".//a/@href"))])
      (check-equal? (length items) 2)
      (check-equal? (hash-ref (car items) 'name) "Test Product")))

  (test-case "extract-table returns rows"
    (let ([table (extract-table test-html)])
      (check-equal? (length table) 2)
      (check-equal? (car (car table)) "Name"))))
