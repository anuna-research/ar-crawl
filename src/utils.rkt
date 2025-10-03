#lang racket

#|
 @title{Utility Functions}
@author{Anuna Research}
 @date{2024-06-11}
 
 This module provides common utility functions used throughout the scraper system.
|#

(require racket/contract
         racket/string
         racket/match
         net/url
         net/uri-codec
         json
         gregor
         xml)

(provide
 (contract-out
  ;; URL validation and manipulation
  [ok-http-url? (-> any/c boolean?)]
  [valid-url? (-> any/c boolean?)]
  [url-encode-path (-> string? string?)]
  [url-decode-safe (-> string? string?)]
  [extract-domain (-> string? (or/c string? #f))]
  [normalize-protocol (-> string? string?)]
  
  ;; String manipulation
  [string-normalize-spaces (-> string? string?)]
  [string-truncate (-> string? exact-nonnegative-integer? string?)]
  [string-clean (-> string? string?)]
  [string-contains-any? (-> string? (listof string?) boolean?)]
  [substring-after-target (-> string? string? (or/c string? #f))]
  
  ;; JSON utilities
  [safe-string->jsexpr (-> string? (or/c jsexpr? #f))]
  [pretty-print-json (-> jsexpr? string?)]
  [extract-json-from-string (-> string? (or/c string? #f))]
  
  ;; HTML/XML utilities
  [html->text (-> string? string?)]
  [remove-html-tags (-> string? string?)]
  [escape-html (-> string? string?)]
  
  ;; Data conversion
  [utils:moment->iso8601 (-> moment? string?)]
  [utils:iso8601->moment (-> string? moment?)]
  [safe-string->number (-> string? (or/c number? #f))]
  [bytes->string-safe (-> bytes? string?)]
  
  ;; List utilities
  [list-slice (-> list? exact-nonnegative-integer? 
                  (or/c exact-nonnegative-integer? #f) list?)]
  [remove-duplicates-by (-> list? procedure? list?)]
  [group-by-key (-> list? procedure? (listof list?))]
  
  ;; Hash utilities
  [deep-merge-hash (-> hash? hash? hash?)]
  [hash-filter (-> hash? procedure? hash?)]
  [hash-map-values (-> hash? procedure? hash?)]
  
  ;; File system utilities
  [ensure-directory (-> path-string? void?)]
  [safe-file-name (-> string? string?)]
  [path-append (-> path-string? path-string? ... path-string?)]
  
  ;; Error handling
  [with-retry (-> procedure? exact-nonnegative-integer? any)]
  [safe-execute (-> procedure? any/c any)]
  
  ;; LLM prompt messages
  [xpath-guesser-message hash?]
  [xpath-reguesser-message hash?]
  
  ;; Misc utilities
  [generate-timestamp (-> string?)]
  [generate-unique-id (-> string? string?)]))

;; URL Validation and Manipulation
;; --------------------------------

;; @function{ok-http-url?}
;; @description{Check if value is a valid HTTP/HTTPS URL}
;; @param[url]{any/c} Value to check
;; @returns{boolean?} True if valid HTTP/HTTPS URL
(define (ok-http-url? url)
  (and (string? url)
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (let ([parsed (string->url url)])
           (and parsed
                (url-scheme parsed)
                (member (url-scheme parsed) '("http" "https"))
                (url-host parsed)
                #t)))))

;; @function{valid-url?}
;; @description{Alias for ok-http-url? for compatibility}
;; @param[url]{any/c} Value to check
;; @returns{boolean?} True if valid URL
(define valid-url? ok-http-url?)

;; @function{url-encode-path}
;; @description{URL encode a path component}
;; @param[path]{string?} Path to encode
;; @returns{string?} Encoded path
(define (url-encode-path path)
  (uri-encode path))

;; @function{url-decode-safe}
;; @description{Safely decode a URL-encoded string}
;; @param[encoded]{string?} Encoded string
;; @returns{string?} Decoded string
(define (url-decode-safe encoded)
  (with-handlers ([exn:fail? (lambda (e) encoded)])
    (uri-decode encoded)))

;; @function{extract-domain}
;; @description{Extract domain from URL}
;; @param[url-str]{string?} URL string
;; @returns{(or/c string? #f)} Domain or #f on failure
(define (extract-domain url-str)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (let ([parsed (string->url url-str)])
      (and parsed
           (url-host parsed)
           (format "~a://~a" 
                   (or (url-scheme parsed) "http")
                   (url-host parsed))))))

;; @function{normalize-protocol}
;; @description{Ensure URL has a protocol}
;; @param[url]{string?} URL string
;; @returns{string?} URL with protocol
(define (normalize-protocol url)
  (if (regexp-match? #rx"^https?://" url)
      url
      (string-append "http://" url)))

;; String Manipulation
;; -------------------

;; @function{string-normalize-spaces}
;; @description{Normalize whitespace in string}
;; @param[str]{string?} Input string
;; @returns{string?} String with normalized spaces
(define (string-normalize-spaces str)
  (regexp-replace* #px"\\s+" (string-trim str) " "))

;; @function{string-truncate}
;; @description{Truncate string to maximum length}
;; @param[str]{string?} String to truncate
;; @param[max-len]{exact-nonnegative-integer?} Maximum length
;; @returns{string?} Truncated string
(define (string-truncate str max-len)
  (if (<= (string-length str) max-len)
      str
      (substring str 0 max-len)))

;; @function{string-clean}
;; @description{Clean string by removing control characters}
;; @param[str]{string?} String to clean
;; @returns{string?} Cleaned string
(define (string-clean str)
  (regexp-replace* #px"[\x00-\x1F\x7F]" str ""))

;; @function{string-contains-any?}
;; @description{Check if string contains any of the substrings}
;; @param[str]{string?} String to check
;; @param[substrs]{listof string?} Substrings to look for
;; @returns{boolean?} True if contains any substring
(define (string-contains-any? str substrs)
  (ormap (lambda (substr) (string-contains? str substr)) substrs))

;; @function{substring-after-target}
;; @description{Get substring after target string}
;; @param[str]{string?} Source string
;; @param[target]{string?} Target string
;; @returns{(or/c string? #f)} Substring or #f if not found
(define (substring-after-target str target)
  (let ([index (string-contains? str target)])
    (and index
         (substring str (+ index (string-length target))))))

;; JSON Utilities
;; --------------

;; @function{safe-string->jsexpr}
;; @description{Safely parse JSON string}
;; @param[json-str]{string?} JSON string
;; @returns{(or/c jsexpr? #f)} Parsed JSON or #f on error
(define (safe-string->jsexpr json-str)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (string->jsexpr json-str)))

;; @function{pretty-print-json}
;; @description{Pretty print JSON expression}
;; @param[jsexpr]{jsexpr?} JSON expression
;; @returns{string?} Pretty printed JSON
(define (pretty-print-json jsexpr)
  (with-output-to-string
    (lambda ()
      (write-json jsexpr #:indent 2))))

;; @function{extract-json-from-string}
;; @description{Extract JSON object from larger string}
;; @param[str]{string?} String containing JSON
;; @returns{(or/c string? #f)} Extracted JSON or #f
(define (extract-json-from-string str)
  (match (regexp-match #rx"\\{[^{}]*\\}" str)
    [(list json-str) json-str]
    [_ #f]))

;; HTML/XML Utilities
;; ------------------

;; @function{html->text}
;; @description{Convert HTML to plain text}
;; @param[html]{string?} HTML string
;; @returns{string?} Plain text
(define (html->text html)
  (remove-html-tags html))

;; @function{remove-html-tags}
;; @description{Remove HTML tags from string}
;; @param[html]{string?} HTML string
;; @returns{string?} String without tags
(define (remove-html-tags html)
  (regexp-replace* #px"<[^>]+>" html ""))

;; @function{escape-html}
;; @description{Escape HTML special characters}
;; @param[str]{string?} String to escape
;; @returns{string?} Escaped string
(define (escape-html str)
  (let* ([str (regexp-replace* #rx"&" str "&amp;")]
         [str (regexp-replace* #rx"<" str "&lt;")]
         [str (regexp-replace* #rx">" str "&gt;")]
         [str (regexp-replace* #rx"\"" str "&quot;")]
         [str (regexp-replace* #rx"'" str "&#39;")])
    str))

;; Data Conversion
;; ---------------

;; @function{utils:moment->iso8601}
;; @description{Convert moment to ISO8601 string}
;; @param[m]{moment?} Moment
;; @returns{string?} ISO8601 string
(define (utils:moment->iso8601 m)
  (~t m "yyyy-MM-dd'T'HH:mm:ss'Z'"))

;; @function{utils:iso8601->moment}
;; @description{Parse ISO8601 string to moment}
;; @param[str]{string?} ISO8601 string
;; @returns{moment?} Parsed moment
(define (utils:iso8601->moment str)
  (parse-moment str "yyyy-MM-dd'T'HH:mm:ss"))

;; @function{safe-string->number}
;; @description{Safely convert string to number}
;; @param[str]{string?} String to convert
;; @returns{(or/c number? #f)} Number or #f
(define (safe-string->number str)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (string->number str)))

;; @function{bytes->string-safe}
;; @description{Safely convert bytes to string}
;; @param[b]{bytes?} Bytes to convert
;; @returns{string?} String (with replacement for invalid chars)
(define (bytes->string-safe b)
  (bytes->string/utf-8 b #\?))

;; List Utilities
;; --------------

;; @function{list-slice}
;; @description{Get slice of list}
;; @param[lst]{list?} List to slice
;; @param[start]{exact-nonnegative-integer?} Start index
;; @param[end]{(or/c exact-nonnegative-integer? #f)} End index or #f for end
;; @returns{list?} Sliced list
(define (list-slice lst start [end #f])
  (let ([len (length lst)])
    (cond
      [(>= start len) '()]
      [(not end) (drop lst start)]
      [else (take (drop lst start) (- (min end len) start))])))

;; @function{remove-duplicates-by}
;; @description{Remove duplicates using key function}
;; @param[lst]{list?} List
;; @param[key-fn]{procedure?} Key extraction function
;; @returns{list?} List without duplicates
(define (remove-duplicates-by lst key-fn)
  (let ([seen (make-hash)])
    (filter (lambda (item)
              (let ([key (key-fn item)])
                (if (hash-ref seen key #f)
                    #f
                    (begin (hash-set! seen key #t) #t))))
            lst)))

;; @function{group-by-key}
;; @description{Group list items by key function}
;; @param[lst]{list?} List to group
;; @param[key-fn]{procedure?} Key extraction function
;; @returns{listof list?} Grouped lists
(define (group-by-key lst key-fn)
  (let ([groups (make-hash)])
    (for ([item lst])
      (let ([key (key-fn item)])
        (hash-update! groups key (lambda (items) (cons item items)) '())))
    (hash-values groups)))

;; Hash Utilities
;; --------------

;; @function{deep-merge-hash}
;; @description{Deep merge two hashes}
;; @param[h1]{hash?} First hash
;; @param[h2]{hash?} Second hash
;; @returns{hash?} Merged hash
(define (deep-merge-hash h1 h2)
  (for/fold ([result h1])
            ([(k v) (in-hash h2)])
    (hash-set result k
              (cond
                [(and (hash? (hash-ref result k #f)) (hash? v))
                 (deep-merge-hash (hash-ref result k) v)]
                [else v]))))

;; @function{hash-filter}
;; @description{Filter hash by predicate}
;; @param[h]{hash?} Hash to filter
;; @param[pred]{procedure?} Predicate (key value -> boolean)
;; @returns{hash?} Filtered hash
(define (hash-filter h pred)
  (for/hash ([(k v) (in-hash h)]
             #:when (pred k v))
    (values k v)))

;; @function{hash-map-values}
;; @description{Map function over hash values}
;; @param[h]{hash?} Hash
;; @param[fn]{procedure?} Function to apply to values
;; @returns{hash?} New hash with mapped values
(define (hash-map-values h fn)
  (for/hash ([(k v) (in-hash h)])
    (values k (fn v))))

;; File System Utilities
;; ---------------------

;; @function{ensure-directory}
;; @description{Ensure directory exists}
;; @param[path]{path-string?} Directory path
;; @returns{void?}
(define (ensure-directory path)
  (unless (directory-exists? path)
    (make-directory* path)))

;; @function{safe-file-name}
;; @description{Convert string to safe filename}
;; @param[name]{string?} Original name
;; @returns{string?} Safe filename
(define (safe-file-name name)
  (regexp-replace* #rx"[^a-zA-Z0-9._-]" name "-"))

;; @function{path-append}
;; @description{Append path components}
;; @param[base]{path-string?} Base path
;; @param[parts]{path-string?} Path parts to append
;; @returns{path-string?} Combined path
(define (path-append base . parts)
  (apply build-path base parts))

;; Error Handling
;; --------------

;; @function{with-retry}
;; @description{Execute function with retries}
;; @param[fn]{procedure?} Function to execute
;; @param[retries]{exact-nonnegative-integer?} Number of retries
;; @returns{any} Function result
(define (with-retry fn retries)
  (let loop ([attempts-left retries])
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (if (> attempts-left 0)
                           (begin
                             (sleep 1)
                             (loop (sub1 attempts-left)))
                           (raise e)))])
      (fn))))

;; @function{safe-execute}
;; @description{Execute function safely with default on error}
;; @param[fn]{procedure?} Function to execute
;; @param[default]{any/c} Default value on error
;; @returns{any} Function result or default
(define (safe-execute fn default)
  (with-handlers ([exn:fail? (lambda (e) default)])
    (fn)))

;; LLM Prompt Messages
;; -------------------

(define xpath-guesser-message
  (hash 'role "system"
        'content "You are an expert at analyzing HTML structure and generating XPath expressions for web scraping. 
Given a description of data to extract and sample HTML, generate precise XPath expressions.

Return your response as a JSON object with this structure:
{
  \"parent_xpath\": \"xpath_to_parent_container\",
  \"child_xpaths\": [
    {\"field_name\": \"xpath_expression\"},
    ...
  ]
}

Guidelines:
- Use specific, robust XPath expressions
- Prefer class and id attributes when available
- Account for common HTML variations
- Test that child XPaths are relative to parent"))

(define xpath-reguesser-message
  (hash 'role "system"
        'content "You are an expert at refining XPath expressions for web scraping.
Given the original XPaths that failed and the HTML structure, provide improved XPath expressions.

Return your response as a JSON object with this structure:
{
  \"parent_xpath\": \"refined_parent_xpath\",
  \"child_xpaths\": [
    {\"field_name\": \"refined_xpath_expression\"},
    ...
  ]
}

Focus on:
- Fixing the specific fields that failed
- Using more flexible selectors
- Handling edge cases in the HTML structure"))

;; Miscellaneous Utilities
;; -----------------------

;; @function{generate-timestamp}
;; @description{Generate timestamp string}
;; @returns{string?} Timestamp string
(define (generate-timestamp)
  (utils:moment->iso8601 (now/moment/utc)))

;; @function{generate-unique-id}
;; @description{Generate unique ID with prefix}
;; @param[prefix]{string?} ID prefix
;; @returns{string?} Unique ID
(define (generate-unique-id prefix)
  (format "~a-~a-~a" 
          prefix 
          (current-milliseconds)
          (random 10000)))

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "URL validation"
    (check-true (ok-http-url? "http://example.com"))
    (check-true (ok-http-url? "https://example.com/path"))
    (check-false (ok-http-url? "ftp://example.com"))
    (check-false (ok-http-url? "not a url")))
  
  (test-case "String manipulation"
    (check-equal? (string-normalize-spaces "  hello   world  ")
                  "hello world")
    (check-equal? (string-truncate "hello world" 5) "hello")
    (check-equal? (string-truncate "hi" 5) "hi"))
  
  (test-case "List utilities"
    (check-equal? (list-slice '(1 2 3 4 5) 1 3) '(2 3))
    (check-equal? (list-slice '(1 2 3) 2) '(3))
    (check-equal? (list-slice '(1 2 3) 5) '()))
  
  (test-case "Safe file names"
    (check-equal? (safe-file-name "hello world.txt") "hello-world.txt")
    (check-equal? (safe-file-name "file/with\\path") "file-with-path")))
