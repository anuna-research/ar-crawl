#lang racket
(require json "../src/proxy-config.rkt" "../src/crawl-service-adaptor.rkt" "../src/robots-txt.rkt")
;; Local integration harness for TEST-103/104/105/106.
(module+ main
(define args (current-command-line-arguments))
(define command (vector-ref args 0))
(define target (vector-ref args 1))
(define cfg (resolve-proxy-config (string->jsexpr (vector-ref args 2)) (hash) (lambda (_) #f)))
(define proxy ((make-proxy-selector cfg)))
(cond
  [(equal? command "robots")
   (define result (fetch-robots-txt target "ProxyTest" #:proxy proxy))
   (write-json (hash 'success (and result #t)))]
  [else
   (define result
     (if (equal? command "playwright")
         (call-service 'playwright target
                       (hash 'playwright-service-url (vector-ref args 3) 'delay 1
                             'proxy-selector (make-proxy-selector cfg)))
         (direct-http-adaptor target #:proxy proxy #:timeout 3000)))
   (write-json (hash 'success (and result #t) 'content (if result (hash-ref result 'content) "")))])
)
