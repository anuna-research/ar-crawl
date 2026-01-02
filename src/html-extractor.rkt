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
         sxml/sxpath
         "error-handler.rkt")

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
                               (let ([details (xpath-error-details e xpath-expr)])
                                 (report-error 'xpath-error
                                             (format "Invalid XPath: ~a" xpath-expr)
                                             details)
                                 (lambda (x) '())))])
    (let ([result (sxpath xpath-expr)])
      ;; sxpath returns #f for invalid xpath instead of throwing
      (if result
          result
          (lambda (x) '())))))

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
                               (let ([details (xpath-error-details e xpath-expr)])
                                 (report-error 'xpath-error
                                             "XPath extraction error"
                                             details)
                                 '()))])
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
          ;; Use sxpath on the parent node directly (without *TOP* wrapper)
          ;; This allows both current node queries (./@href, ./text()) and
          ;; descendant queries (.//tag) to work correctly
          (let* ([xpath-fn (make-xpath rel-xpath)]
                 [nodes (xpath-fn parent)]
                 [value (if (empty? nodes)
                            #f
                            (let ([first-node (car nodes)])
                              (cond
                                ;; Handle text strings directly
                                [(string? first-node) first-node]
                                ;; Handle attribute nodes: (attr-name "value")
                                ;; Attributes have exactly 2 elements and no @ attribute list
                                [(and (list? first-node)
                                      (= (length first-node) 2)
                                      (symbol? (car first-node))
                                      (string? (cadr first-node))
                                      (not (eq? (car first-node) '@)))
                                 (cadr first-node)]
                                ;; Handle element nodes
                                [else (sxml->text first-node)])))])
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

  ;; HTML Parsing Tests
  (test-case "html->sxml parses valid HTML"
    (let ([sxml (html->sxml "<html><body><p>test</p></body></html>")])
      (check-true (list? sxml))
      (check-not-equal? sxml '(*TOP*))))

  (test-case "html->sxml handles empty HTML"
    (let ([sxml (html->sxml "")])
      (check-true (list? sxml))))

  (test-case "html->sxml handles malformed HTML gracefully"
    (let ([sxml (html->sxml "<html><body><p>unclosed")])
      (check-true (list? sxml))))

  ;; make-xpath Tests
  (test-case "make-xpath creates valid xpath function"
    (let ([xpath-fn (make-xpath "//p")])
      (check-true (procedure? xpath-fn))))

  (test-case "make-xpath handles invalid xpath gracefully"
    ;; Invalid xpath returns a lambda that returns empty list
    (let ([xpath-fn (make-xpath "[[[invalid")])
      (check-true (procedure? xpath-fn))
      (check-equal? (xpath-fn '(*TOP*)) '())))

  ;; extract-by-xpath Tests
  (test-case "extract-by-xpath returns nodes"
    (let ([results (extract-by-xpath test-html "//h2")])
      (check-equal? (length results) 2)))

  (test-case "extract-by-xpath returns empty list for no matches"
    (let ([results (extract-by-xpath test-html "//nonexistent")])
      (check-equal? results '())))

  (test-case "extract-by-xpath handles complex xpath"
    (let ([results (extract-by-xpath test-html "//div[@class='product']/h2")])
      (check-equal? (length results) 2)))

  ;; extract-text Tests
  (test-case "extract-text gets first match"
    (let ([text (extract-text test-html "//h2[@class='name']")])
      (check-equal? text "Test Product")))

  (test-case "extract-text returns #f for no matches"
    (let ([text (extract-text test-html "//nonexistent")])
      (check-false text)))

  (test-case "extract-text normalizes whitespace"
    (let ([text (extract-text "<p>  hello   world  </p>" "//p")])
      (check-equal? text "hello world")))

  ;; extract-text-all Tests
  (test-case "extract-text-all gets all matches"
    (let ([texts (extract-text-all test-html "//span[@class='price']")])
      (check-equal? texts '("$19.99" "$29.99"))))

  (test-case "extract-text-all returns empty list for no matches"
    (let ([texts (extract-text-all test-html "//nonexistent")])
      (check-equal? texts '())))

  ;; extract-attr Tests
  (test-case "extract-attr gets attribute"
    (let ([href (extract-attr test-html "//a" 'href)])
      (check-equal? href "/product/123")))

  (test-case "extract-attr returns #f for missing attribute"
    (let ([attr (extract-attr test-html "//div" 'nonexistent)])
      (check-false attr)))

  (test-case "extract-attr returns #f for no matching element"
    (let ([attr (extract-attr test-html "//nonexistent" 'href)])
      (check-false attr)))

  ;; extract-attr-all Tests
  (test-case "extract-attr-all gets all attributes"
    (let ([hrefs (extract-attr-all test-html "//a" 'href)])
      (check-equal? hrefs '("/product/123" "/product/456"))))

  (test-case "extract-attr-all returns empty list for no matches"
    (let ([attrs (extract-attr-all test-html "//nonexistent" 'href)])
      (check-equal? attrs '())))

  ;; extract-by-xpaths Tests
  (test-case "extract-by-xpaths returns hash"
    (let ([result (extract-by-xpaths test-html
                                     (hash 'name "//h2[@class='name']"
                                           'price "//span[@class='price']"))])
      (check-true (hash? result))
      ;; Multiple matches returns a list
      (check-equal? (hash-ref result 'name) '("Test Product" "Another Product"))
      (check-equal? (hash-ref result 'price) '("$19.99" "$29.99"))))

  (test-case "extract-by-xpaths single result returns string not list"
    (let ([result (extract-by-xpaths "<title>Page Title</title>"
                                     (hash 'title "//title"))])
      (check-equal? (hash-ref result 'title) "Page Title")))

  (test-case "extract-by-xpaths returns #f for missing fields"
    (let ([result (extract-by-xpaths test-html
                                     (hash 'missing "//nonexistent"))])
      (check-false (hash-ref result 'missing))))

  ;; extract-items Tests
  (test-case "extract-items returns list of hashes"
    (let ([items (extract-items test-html
                                "//div[@class='product']"
                                (hash 'name ".//h2"
                                      'price ".//span[@class='price']"
                                      'link ".//a/@href"))])
      (check-equal? (length items) 2)
      (check-equal? (hash-ref (car items) 'name) "Test Product")
      (check-equal? (hash-ref (car items) 'price) "$19.99")))

  (test-case "extract-items returns empty list for no parent matches"
    (let ([items (extract-items test-html
                                "//div[@class='nonexistent']"
                                (hash 'name ".//h2"))])
      (check-equal? items '())))

  ;; extract-table Tests
  (test-case "extract-table returns rows"
    (let ([table (extract-table test-html)])
      (check-equal? (length table) 2)
      (check-equal? (car (car table)) "Name")))

  (test-case "extract-table with custom xpath"
    (let ([table (extract-table test-html "//table")])
      (check-equal? (length table) 2)))

  (test-case "extract-table returns empty for no table"
    (let ([table (extract-table "<p>no table</p>")])
      (check-equal? table '())))

  ;; sxml->text Tests
  (test-case "sxml->text extracts text from element"
    (let ([text (sxml->text '(p "Hello " (b "World")))])
      (check-equal? text "Hello World")))

  (test-case "sxml->text skips script and style"
    (let ([text (sxml->text '(div (script "var x = 1;") "visible" (style ".x{}")))])
      (check-equal? text "visible")))

  (test-case "sxml->text handles attributes"
    (let ([text (sxml->text '(p (@ (class "test")) "content"))])
      (check-equal? text "content")))

  ;; sxml-attr Tests
  (test-case "sxml-attr extracts attribute"
    (let ([attr (sxml-attr '(a (@ (href "/link")) "text") 'href)])
      (check-equal? attr "/link")))

  (test-case "sxml-attr returns #f for missing attribute"
    (let ([attr (sxml-attr '(a (@ (href "/link")) "text") 'class)])
      (check-false attr)))

  (test-case "sxml-attr handles element without attributes"
    (let ([attr (sxml-attr '(a "text") 'href)])
      (check-false attr)))

  ;; sxml-attrs Tests
  (test-case "sxml-attrs extracts multiple attributes"
    (let ([attrs (sxml-attrs '(a (@ (href "/link") (class "btn")) "text")
                             '(href class))])
      (check-equal? (hash-ref attrs 'href) "/link")
      (check-equal? (hash-ref attrs 'class) "btn")))

  ;; string-normalize-spaces Tests
  (test-case "string-normalize-spaces collapses whitespace"
    (check-equal? (string-normalize-spaces "  hello   world  ") "hello world"))

  (test-case "string-normalize-spaces handles tabs and newlines"
    (check-equal? (string-normalize-spaces "hello\n\t  world") "hello world"))

  (test-case "string-normalize-spaces handles empty string"
    (check-equal? (string-normalize-spaces "") ""))

  ;; Edge Cases
  (test-case "handles HTML with special characters"
    (let ([text (extract-text "<p>&amp; &lt; &gt;</p>" "//p")])
      (check-true (string? text))))

  (test-case "handles nested elements"
    (let ([text (extract-text "<div><p><span>deep</span></p></div>" "//span")])
      (check-equal? text "deep")))

  (test-case "handles unicode content"
    (let ([text (extract-text "<p>日本語テスト</p>" "//p")])
      (check-equal? text "日本語テスト")))

  ;; File-based extraction tests
  (test-case "extract-from-crawl-results handles hash input"
    (let* ([test-data (hash 'data (list (hash 'content "<html><p class='test'>content</p></html>"
                                              'url "http://example.com"
                                              'title "Test Page")))]
           [xpath-map (hash 'text "//p[@class='test']")]
           [results (extract-from-crawl-results test-data xpath-map)])
      (check-equal? (length results) 1)
      (check-equal? (hash-ref (car results) 'text) "content")
      (check-equal? (hash-ref (car results) 'source_url) "http://example.com")
      (check-equal? (hash-ref (car results) 'source_title) "Test Page")))

  (test-case "extract-from-crawl-results handles empty data"
    (let ([results (extract-from-crawl-results (hash 'data '()) (hash 'x "//p"))])
      (check-equal? results '())))

  (test-case "extract-from-crawl-results skips items without content"
    (let* ([test-data (hash 'data (list (hash 'url "http://example.com")))]
           [results (extract-from-crawl-results test-data (hash 'x "//p"))])
      (check-equal? results '())))

  (test-case "extract-from-crawl-results handles multiple items"
    (let* ([test-data (hash 'data (list
                                   (hash 'content "<html><h1>Page 1</h1></html>"
                                         'url "http://example.com/1"
                                         'title "Page 1")
                                   (hash 'content "<html><h1>Page 2</h1></html>"
                                         'url "http://example.com/2"
                                         'title "Page 2")))]
           [xpath-map (hash 'heading "//h1")]
           [results (extract-from-crawl-results test-data xpath-map)])
      (check-equal? (length results) 2)
      (check-equal? (hash-ref (first results) 'heading) "Page 1")
      (check-equal? (hash-ref (second results) 'heading) "Page 2")))

  ;; sxml->text additional edge cases
  (test-case "sxml->text handles plain string"
    (check-equal? (sxml->text "plain text") "plain text"))

  (test-case "sxml->text handles symbol"
    (check-equal? (sxml->text 'symbol) ""))

  (test-case "sxml->text handles *TOP* wrapper"
    (let ([text (sxml->text '(*TOP* (p "content")))])
      (check-equal? text "content")))

  (test-case "sxml->text handles deeply nested"
    (let ([text (sxml->text '(div (p (span (b (i "deep"))))))])
      (check-equal? text "deep")))

  (test-case "sxml->text handles multiple children"
    (let ([text (sxml->text '(div (p "first") " " (p "second")))])
      (check-equal? text "first second")))

  ;; sxml->text-list additional tests
  (test-case "sxml->text-list handles mixed list"
    (let ([result (sxml->text-list (list "plain" '(p "element")))])
      (check-equal? result '("plain" "element"))))

  ;; More attribute extraction edge cases
  (test-case "sxml-attr handles short attribute list"
    (let ([attr (sxml-attr '(a (@ (href)) "text") 'href)])
      (check-false attr)))

  ;; Additional extract-by-xpath edge cases
  (test-case "extract-by-xpath with class selector"
    (let ([results (extract-by-xpath test-html "//div[@class='product']")])
      (check-equal? (length results) 2)))

  ;; extract-items with missing fields
  (test-case "extract-items handles missing child elements"
    (let ([items (extract-items "<div class='item'><p>text</p></div>"
                                "//div[@class='item']"
                                (hash 'text ".//p"
                                      'missing ".//nonexistent"))])
      (check-equal? (length items) 1)
      (check-false (hash-ref (car items) 'missing))))

  ;; extract-items with string nodes
  (test-case "extract-items handles attribute values"
    (let ([items (extract-items test-html
                                "//a"
                                (hash 'href "./@href"))])
      (check-equal? (length items) 2))))
