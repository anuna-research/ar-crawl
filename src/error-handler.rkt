#lang racket

;; Error Handler Module
;; Provides user-friendly error messages with actionable suggestions

(require racket/string
         racket/path
         racket/file
         json)

(provide
 report-error
 report-error-and-exit
 classify-error
 file-error-details
 url-error-details
 json-parse-error-details
 xpath-error-details
 current-output-format)

;; ============================================================================
;; Output Format Parameter
;; ============================================================================

;; @parameter{current-output-format}
;; @description{Current output format (json or other)}
(define current-output-format (make-parameter #f))

;; ============================================================================
;; Error Classification
;; ============================================================================

;; @function{classify-error}
;; @description{Classify an exception into a specific error type}
;; @param[exn]{exn:fail?} The exception to classify
;; @returns{symbol?} The error type
(define (classify-error exn)
  (let ([msg (exn-message exn)])
    (cond
      [(regexp-match? #rx"No such file or directory" msg) 'file-not-found]
      [(regexp-match? #rx"Permission denied" msg) 'permission-denied]
      [(regexp-match? #rx"read:|expected|unexpected|Invalid port" msg) 'invalid-json]
      [(regexp-match? #rx"XPath|sxml" msg) 'xpath-error]
      [else 'unknown])))

;; ============================================================================
;; Context Builders
;; ============================================================================

;; @function{file-error-details}
;; @description{Build detailed context for file errors}
;; @param[exn]{exn:fail?} The exception
;; @param[filepath]{path-string?} The file path that failed
;; @returns{hash?} Error details with suggestions
(define (file-error-details exn filepath)
  (let* ([error-type (classify-error exn)]
         [abs-path (if (complete-path? filepath)
                       filepath
                       (build-path (current-directory) filepath))]
         [filename (if (path? filepath)
                       (file-name-from-path filepath)
                       (file-name-from-path (string->path filepath)))]
         [dir (path-only abs-path)]
         [similar-files (if (and dir (directory-exists? dir))
                            (find-similar-files dir filename)
                            '())])
    (hash 'error_type error-type
          'file (if (path? filepath) (path->string filepath) filepath)
          'absolute_path (path->string abs-path)
          'exists? (file-exists? filepath)
          'suggestions (suggest-file-fixes filepath)
          'similar_files similar-files)))

;; @function{find-similar-files}
;; @description{Find files with similar names in a directory}
;; @param[dir]{path?} Directory to search
;; @param[target-filename]{path?} Target filename to match
;; @returns{(listof string?)} List of similar filenames
(define (find-similar-files dir target-filename)
  (with-handlers ([exn:fail? (lambda (e) '())])
    (let* ([target-str (if (path? target-filename)
                          (path->string target-filename)
                          (file-name-from-path target-filename))]
           [target-ext (path-get-extension target-str)]
           [files (directory-list dir)]
           [similar (filter (lambda (f)
                             (and (file-exists? (build-path dir f))
                                  (not (equal? f target-filename))
                                  (or (string-contains? (path->string f)
                                                       (path-replace-extension target-str ""))
                                      (equal? (path-get-extension (path->string f)) target-ext))))
                           files)])
      (take (map path->string similar) (min 5 (length similar))))))

;; @function{url-error-details}
;; @description{Build detailed context for URL errors}
;; @param[url-str]{string?} The URL that failed
;; @param[error-type]{symbol?} The specific error type
;; @returns{hash?} Error details with suggestions
(define (url-error-details url-str error-type)
  (hash 'error_type error-type
        'url url-str
        'message (format "Invalid URL '~a'" url-str)
        'suggestions (suggest-url-fixes url-str error-type)))

;; @function{json-parse-error-details}
;; @description{Build detailed context for JSON parsing errors}
;; @param[exn]{exn:fail?} The exception
;; @param[json-str]{string?} The JSON string that failed to parse
;; @returns{hash?} Error details with suggestions
(define (json-parse-error-details exn json-str)
  (let* ([msg (exn-message exn)]
         [suggestions (suggest-json-fixes json-str msg)])
    (hash 'error_type 'json-parse-error
          'json_input json-str
          'raw_error msg
          'suggestions suggestions
          'examples (list "--xpath-map '{\"title\": \"//h1\", \"body\": \"//p\"}'"
                         "--fields '{\"name\": \"//div[@class=\\\"name\\\"]\"}')"))))

;; @function{xpath-error-details}
;; @description{Build detailed context for XPath errors}
;; @param[exn]{exn:fail?} The exception
;; @param[xpath-expr]{string?} The XPath expression that failed
;; @returns{hash?} Error details with suggestions
(define (xpath-error-details exn xpath-expr)
  (hash 'error_type 'xpath-error
        'xpath_expression xpath-expr
        'raw_error (exn-message exn)
        'suggestions (suggest-xpath-fixes xpath-expr)))

;; ============================================================================
;; Suggestion Generators
;; ============================================================================

;; @function{suggest-file-fixes}
;; @description{Generate suggestions for file errors}
;; @param[filepath]{path-string?} The file path that failed
;; @returns{(listof string?)} List of suggestions
(define (suggest-file-fixes filepath)
  (let* ([filepath-str (if (path? filepath) (path->string filepath) filepath)]
         [is-json? (string-suffix? filepath-str ".json")]
         [is-db? (string-suffix? filepath-str ".db")])
    (cond
      [is-json?
       (list (format "Create it first with: ar-crawl crawl <url> -o ~a" filepath-str)
             "Check the path is correct"
             "Use an existing crawl result file")]
      [is-db?
       (list (format "Create it first with: ar-crawl crawl-site <url> -o ~a --format sqlite" filepath-str)
             "Check the path is correct"
             "Ensure the database file exists")]
      [else
       (list "Check the path is correct"
             "Ensure the file exists")])))

;; @function{suggest-url-fixes}
;; @description{Generate suggestions for URL errors}
;; @param[url-str]{string?} The URL that failed
;; @param[error-type]{symbol?} The specific error type
;; @returns{(listof string?)} List of suggestions
(define (suggest-url-fixes url-str error-type)
  (cond
    [(eq? error-type 'missing-protocol)
     (let ([fixed-url (string-append "https://" url-str)])
       (list (format "Did you mean: ~a?" fixed-url)
             "URLs must include the protocol (http:// or https://)"))]
    [(eq? error-type 'looks-like-flag)
     (list "URLs must not start with '-'"
           "Check your command syntax"
           "Ensure you're passing a URL, not a flag")]
    [else
     (list "Ensure URL includes protocol (http:// or https://)"
           "Check URL format"
           "Example: https://example.com")]))

;; @function{suggest-json-fixes}
;; @description{Generate suggestions for JSON parsing errors}
;; @param[json-str]{string?} The JSON string that failed
;; @param[error-msg]{string?} The error message
;; @returns{(listof string?)} List of suggestions
(define (suggest-json-fixes json-str error-msg)
  (let ([suggestions '()])
    ;; Check for single quotes
    (when (string-contains? json-str "'")
      (set! suggestions (cons "JSON requires double quotes, not single quotes" suggestions)))

    ;; Check for unquoted keys
    (when (regexp-match? #rx"\\{[^\"']*:" json-str)
      (set! suggestions (cons "All keys must be quoted with double quotes" suggestions)))

    ;; Check for trailing comma
    (when (regexp-match? #rx",\\s*[}\\]]" json-str)
      (set! suggestions (cons "Remove trailing commas" suggestions)))

    ;; Add general tips if no specific issues found
    (when (empty? suggestions)
      (set! suggestions (list "Ensure proper JSON format: {\"key\": \"value\"}"
                             "Check for missing quotes or commas")))

    ;; Always add shell quoting tip
    (append suggestions
            (list "Use single quotes around JSON in shell: --xpath-map '{\"key\": \"value\"}'"))))

;; @function{suggest-xpath-fixes}
;; @description{Generate suggestions for XPath errors}
;; @param[xpath-expr]{string?} The XPath expression that failed
;; @returns{(listof string?)} List of suggestions
(define (suggest-xpath-fixes xpath-expr)
  (list "Check XPath syntax"
        "Common patterns: //tag, //tag[@attr='value'], //tag/text()"
        "Use relative paths with parent: .//tag instead of //tag"
        "Test XPath in browser DevTools console: $x('//h1')"))

;; ============================================================================
;; Format-Aware Output
;; ============================================================================

;; @function{should-output-json?}
;; @description{Check if output should be in JSON format}
;; @returns{boolean?} True if JSON output is requested
(define (should-output-json?)
  (eq? (current-output-format) 'json))

;; @function{output-human-error}
;; @description{Output error in human-readable format}
;; @param[error-type]{symbol?} The error type
;; @param[message]{string?} The error message
;; @param[context]{hash?} Additional context and suggestions
(define (output-human-error error-type message context)
  (printf "~n")
  (printf "Error: ~a~n" message)

  ;; Show context-specific information
  (when (hash-has-key? context 'file)
    (printf "~nFile: ~a~n" (hash-ref context 'file)))

  (when (hash-has-key? context 'url)
    (printf "~nURL: ~a~n" (hash-ref context 'url)))

  (when (hash-has-key? context 'absolute_path)
    (printf "Location: ~a~n" (hash-ref context 'absolute_path)))

  (when (hash-has-key? context 'json_input)
    (printf "~nInput: ~a~n" (hash-ref context 'json_input)))

  (when (hash-has-key? context 'xpath_expression)
    (printf "~nXPath: ~a~n" (hash-ref context 'xpath_expression)))

  ;; Show raw error for debugging if available
  (when (and (hash-has-key? context 'raw_error)
             (not (equal? error-type 'file-not-found))) ; Skip raw error for file not found
    (printf "~nDetails: ~a~n" (hash-ref context 'raw_error)))

  ;; Show suggestions
  (when (hash-has-key? context 'suggestions)
    (let ([suggestions (hash-ref context 'suggestions)])
      (when (not (empty? suggestions))
        (printf "~n")
        (cond
          [(= 1 (length suggestions))
           (printf "Tip: ~a~n" (car suggestions))]
          [else
           (printf "Did you mean to:~n")
           (for ([suggestion suggestions])
             (printf "  • ~a~n" suggestion))]))))

  ;; Show examples if available
  (when (hash-has-key? context 'examples)
    (let ([examples (hash-ref context 'examples)])
      (when (not (empty? examples))
        (printf "~nCorrect format:~n")
        (for ([example examples])
          (printf "  ~a~n" example)))))

  ;; Show similar files if available
  (when (and (hash-has-key? context 'similar_files)
             (not (empty? (hash-ref context 'similar_files))))
    (printf "~nSimilar files in directory:~n")
    (for ([file (hash-ref context 'similar_files)])
      (printf "  • ~a~n" file)))

  (printf "~n"))

;; @function{output-json-error}
;; @description{Output error in JSON format}
;; @param[error-type]{symbol?} The error type
;; @param[message]{string?} The error message
;; @param[context]{hash?} Additional context and suggestions
(define (output-json-error error-type message context)
  ;; Convert symbols to strings for JSON compatibility
  (define (symbol->string-in-hash h)
    (for/hash ([(k v) (in-hash h)])
      (values k (cond
                  [(symbol? v) (symbol->string v)]
                  [(list? v) (map (lambda (x) (if (symbol? x) (symbol->string x) x)) v)]
                  [else v]))))
  (let ([json-context (symbol->string-in-hash context)]
        [error-type-str (symbol->string error-type)])
    (let ([error-obj (hash 'error (hash-set* json-context
                                             'type error-type-str
                                             'message message))])
      (displayln (jsexpr->string error-obj #:encode 'control)))))

;; ============================================================================
;; Main Error Reporting Functions
;; ============================================================================

;; @function{report-error}
;; @description{Report an error with format-aware output (non-fatal)}
;; @param[error-type]{symbol?} The error type
;; @param[message]{string?} The error message
;; @param[context]{hash?} Additional context and suggestions
(define (report-error error-type message context)
  (if (should-output-json?)
      (output-json-error error-type message context)
      (output-human-error error-type message context)))

;; @function{report-error-and-exit}
;; @description{Report an error and exit with code 1}
;; @param[error-type]{symbol?} The error type
;; @param[message]{string?} The error message
;; @param[context]{hash?} Additional context and suggestions
(define (report-error-and-exit error-type message context)
  (report-error error-type message context)
  (exit 1))
