#lang racket

(require parser-tools/cfg-parser parser-tools/lex
         (for-syntax racket/base racket/list racket/path json compiler/cm-accomplice))
(provide parse-proxy-input proxy-input-text proxy-input-node proxy-input-nodes
         proxy-input-endpoint clean-proxy-string?)

;; This adapter expands the shared BNF data into parser-tools productions.
;; Language rules live exclusively in proxy-grammar.json.
(define-syntax (define-input-parsers stx)
  (define path (simplify-path (build-path (path-only (syntax-source stx))
                                         "../playwright-service/proxy-grammar.json")))
  (register-external-file path)
  (define source (call-with-input-file path read-json))
  (define (terminal c) (string->symbol (format "C~a" (char->integer c))))
  (define classes
    (for/list ([(name chars) (in-hash (hash-ref source 'classes))])
      (cons name (for/list ([c (in-string chars)]) (list (hash 'literal (string c)))))))
  (define productions
    (for/list ([entry (append (hash->list (hash-ref source 'rules)) classes)])
      (define name (car entry))
      (cons name
            (for/list ([alternative (cdr entry)])
              (define symbols
                (append-map (lambda (item)
                              (if (string? item) (list (string->symbol item))
                                  (map terminal (string->list (hash-ref item 'literal)))))
                            alternative))
              (list symbols `(list ,(symbol->string name)
                                   ,@(for/list ([i (in-range 1 (add1 (length symbols)))])
                                       (string->symbol (format "$~a" i)))))))))
  (datum->syntax
   stx
   `(begin
      (define-tokens characters ,(for/list ([i (in-range 128)]) (terminal (integer->char i))))
      (define character-constructors
        (vector ,@(for/list ([i (in-range 128)]) (string->symbol (format "token-C~a" i)))))
      (define input-limits ',(hash-ref source 'maxLengths))
      (define authority-tail-limit ,(hash-ref source 'authorityTailLimit))
      (define-empty-tokens endings (EOF))
      ,@(for/list ([entry (hash-ref source 'entries)])
          `(define ,(string->symbol (string-append entry "-parser"))
             (cfg-parser (start ,(string->symbol entry)) (end EOF) (tokens characters endings)
                         (error (lambda args (error 'proxy-input "Invalid proxy input")))
                         (grammar ,@productions)))))))
(define-input-parsers)

(define (proxy-input-text tree)
  (if (string? tree) tree (apply string-append (map proxy-input-text (cdr tree)))))
(define (proxy-input-nodes tree name)
  (cond [(string? tree) '()]
        [(equal? (car tree) name) (list tree)]
        [else (append-map (lambda (child) (proxy-input-nodes child name)) (cdr tree))]))
(define (proxy-input-node tree name)
  (define nodes (proxy-input-nodes tree name))
  (and (pair? nodes) (car nodes)))
(define (clean-proxy-string? value)
  (and (string? value)
       (for/and ([c (in-string value)])
         (and (>= (char->integer c) 32) (not (= (char->integer c) 127))))))

(define (parse-proxy-input entry value)
  (unless (and (string? value) (hash-has-key? input-limits entry)
               (<= (string-length value) (hash-ref input-limits entry)))
    (error 'proxy-input "Invalid proxy input"))
  ;; Negative lexical bounds only: no fields are interpreted here.
  ;; The grammar permits a literal @ only as the credential terminator.
  (define credential-end
    (and (eq? entry 'endpoint)
         (for/first ([c (in-string value)] [i (in-naturals)] #:when (char=? c #\@)) i)))
  (define selected-entry (if (and (eq? entry 'endpoint) (not credential-end)) 'wire-endpoint entry))
  (unless (and (<= (string-length value) (hash-ref input-limits selected-entry))
               (or (not credential-end)
                   (<= (- (string-length value) credential-end 1) authority-tail-limit)))
    (error 'proxy-input "Invalid proxy input"))
  (with-handlers ([exn:fail? (lambda (_) (error 'proxy-input "Invalid proxy input"))])
    ;; SIMPLIFY: the CFG backend can take seconds for near-4096-character credential-bearing inputs.
    ;; NFR-006 / ADR-102 bound this CLI-only case; replace the backend if such pools become routine.
    (define input (open-input-string value))
    (define parser
      (case selected-entry [(endpoint) endpoint-parser] [(wire-endpoint) wire-endpoint-parser]
        [(bypass-host) bypass-host-parser] [(bypass-list) bypass-list-parser]))
    (define ast
      (parser (lambda ()
                (define c (read-char input))
                (if (eof-object? c) 'EOF
                    ((vector-ref character-constructors (char->integer c)) (string c))))))
    (for ([label (in-list (proxy-input-nodes ast "dns-label"))])
      (unless (<= (string-length (proxy-input-text label)) 63)
        (error 'proxy-input "Invalid proxy label")))
    (for ([domain (in-list (proxy-input-nodes ast "dns-name"))])
      (unless (<= (string-length (proxy-input-text domain)) 253)
        (error 'proxy-input "Invalid proxy host")))
    (for ([port (in-list (proxy-input-nodes ast "port"))])
      (unless (<= 1 (string->number (proxy-input-text port)) 65535)
        (error 'proxy-input "Invalid proxy port")))
    ast))

(define (decoded-credential ast)
  (define out (open-output-bytes))
  (let walk ([node ast])
    (cond [(string? node) (write-bytes (string->bytes/utf-8 node) out)]
          [(equal? (car node) "pct-encoded")
           (write-byte (string->number (apply string-append (map proxy-input-text (cddr node))) 16) out)]
          [else (for-each walk (cdr node))]))
  ;; Fail on malformed UTF-8 instead of replacing bytes in credentials.
  (bytes->string/utf-8 (get-output-bytes out) #f))

(define (proxy-input-endpoint ast)
  (define (field name) (proxy-input-text (proxy-input-node ast name)))
  (define base (hash 'server (string-append (field "scheme") "://" (field "host") ":" (field "port"))))
  (cond
    [(proxy-input-node ast "credentials")
     (define username (decoded-credential (proxy-input-node ast "username")))
     (define password (decoded-credential (proxy-input-node ast "password")))
     (unless (and (clean-proxy-string? username) (clean-proxy-string? password)
                  (not (string-contains? username ":")))
       (error 'proxy-input "Invalid proxy credentials"))
     (hash-set* base 'username username 'password password)]
    [else base]))
