#lang racket
(require json "../src/proxy-input.rkt")
(module+ main
  (define examples (read-json))
  (write-json
   (for/list ([example examples])
     (with-handlers ([exn:fail? (lambda (_) (hash 'accepted #f))])
       (define entry (string->symbol (hash-ref example 'entry)))
       (define ast (parse-proxy-input entry (hash-ref example 'input)))
       (hash 'accepted #t 'value
             (if (memq entry '(endpoint wire-endpoint)) (proxy-input-endpoint ast)
                 (proxy-input-text ast)))))))
