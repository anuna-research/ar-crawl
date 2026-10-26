#lang racket
(require rackunit json racket/runtime-path "../src/proxy-config.rkt" "../src/proxy-input.rkt")
(define-runtime-path corpus-path "proxy-grammar-corpus.json")
(module+ test
  ;; TEST-107 and TEST-108, SPEC-002-proxy-input-grammar.
  (for ([example (call-with-input-file corpus-path read-json)])
    (test-case (format "~a ~s" (hash-ref example 'entry) (hash-ref example 'input))
      (define entry (string->symbol (hash-ref example 'entry)))
      (define (recognise)
        (if (eq? entry 'endpoint)
            (recognize-proxy (hash-ref example 'input))
            (parse-proxy-input entry (hash-ref example 'input))))
      (if (hash-ref example 'valid)
          (check-not-exn recognise)
          (check-exn exn:fail? recognise)))))

(module+ test
  (test-case "TEST-108 input size bounds reject before parser invocation"
    (for ([entry '(endpoint wire-endpoint bypass-host bypass-list)])
      (check-exn exn:fail? (lambda () (parse-proxy-input entry (make-string 20000 #\a)))))))
