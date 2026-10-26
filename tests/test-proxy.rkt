#lang racket
(require rackunit "../src/proxy-config.rkt" "../src/production-crawler.rkt" "../src/config-manager.rkt")
;; TEST-101 / TEST-102 / TEST-105 / TEST-106 in SPEC-001-proxy-support.
(define env (hash "PROXY_SERVER" "http://env.test:80" "PROXY_USER" "env-user" "PROXY_PASS" "env-pass"))
(define (resolve config [cli (hash)])
  (resolve-proxy-config config cli (lambda (key) (hash-ref env key #f))))
(module+ test
  (test-case "TEST-101 precedence and explicit disable"
    (check-equal? (hash-ref (resolve (hash)) 'server) "http://env.test:80")
    (check-false (resolve (hash 'enabled #f)))
    (check-equal? (hash-ref (resolve (hash 'enabled #f) (hash 'server "http://cli.test:81")) 'server) "http://cli.test:81")
    (check-equal? (hash-ref (resolve (hash 'server "http://cfg.test:82") (hash 'username "cli")) 'username) "cli")
    (check-equal? (hash-ref (resolve (hash 'pool '("http://pool.test:83"))) 'pool) '("http://pool.test:83"))
    (check-equal? (hash-ref (resolve (hash 'pool '("http://pool.test:83")) (hash 'server "http://cli.test:81")) 'pool) '("http://cli.test:81")))
  (test-case "TEST-101 credentials and URL recognition"
    (define p (recognize-proxy "socks5://a%40b:p%3Ass@localhost:1080"))
    (check-equal? (hash-ref p 'username) "a@b")
    (check-equal? (hash-ref p 'password) "p:ss")
    (check-equal? (hash-ref p 'server) "socks5://localhost:1080")
    (for ([bad '("ftp://localhost:80" "http://localhost" "http://localhost:0" "http://localhost:65536" "http://localhost:80/path" "http://localhost:80?q=1" "http://localhost:80#x" "http://u%ZZ:p@host:80" "http://a%3Ab:p@host:80" "http://a..b:80" "http://[:::]:80" "http://-bad.test:80" "http://u:p@host:80\n")])
      (check-exn exn:fail? (lambda () (recognize-proxy bad)) bad)))
  (test-case "TEST-105 full config recognition"
    (for ([bad (list (hash 'enabled "yes") (hash 'enabled #t) (hash 'pool '()) (hash 'pool '("http://good:80" "bad")) (hash 'server "http://host:80" 'rotation "random") (hash 'server "http://host:80" 'username "u") (hash 'server "http://host:80" 'bypass '("*.test")) (hash 'surprise #t))])
      (check-exn exn:fail? (lambda () (resolve-proxy-config bad (hash) (lambda (_) #f))))))
  (test-case "TEST-101 independent credential fields"
    (define p (resolve-proxy-config (hash 'server "http://host:80" 'username "u")
                                    (hash 'password "p") (lambda (_) #f)))
    (check-equal? (hash-ref ((make-proxy-selector p)) 'password) "p"))
  (test-case "TEST-101 individual embedded credential overrides"
    (for ([override (list (hash 'username "new") (hash 'password "new"))]
          [key '(username password)])
      (define p (resolve-proxy-config (hash 'server "http://old:old@host:80") override (lambda (_) #f)))
      (check-equal? (hash-ref ((make-proxy-selector p)) key) "new"))
    (check-exn exn:fail?
               (lambda () (resolve-proxy-config
                            (hash 'pool '("http://u:p@a:80" "http://b:80"))
                            (hash 'username "new") (lambda (_) #f)))))
  (test-case "TEST-105 service scope and browser auth rejection"
    (define p (resolve-proxy-config (hash 'server "http://host:80") (hash) (lambda (_) #f)))
    (check-exn exn:fail? (lambda () (attach-proxy-config (hash) p '(firecrawl))))
    (check-equal? (attach-proxy-config (hash 'firecrawl (hash 'use_proxy #f)) p '(firecrawl))
                  (hash 'firecrawl (hash 'use_proxy #f)))
    (define socks (resolve-proxy-config (hash 'server "socks5://u:p@host:80") (hash) (lambda (_) #f)))
    (check-exn exn:fail? (lambda () (attach-proxy-config (hash) socks '(playwright)))))
  (test-case "TEST-102 rotation and isolation"
    (define cfg (resolve-proxy-config (hash 'pool '("http://a:80" "http://b:81")) (hash) (lambda (_) #f)))
    (define pool (make-proxy-selector cfg))
    (check-equal? (for/list ([i (in-range 5)]) (hash-ref (pool) 'server)) '("http://a:80" "http://b:81" "http://a:80" "http://b:81" "http://a:80"))
    (define sticky (make-proxy-selector (hash-set cfg 'rotation "sticky")))
    (check-equal? (sticky) (sticky))
    (check-equal? (hash-ref ((make-proxy-selector cfg)) 'server) "http://a:80")
    (define concurrent (make-proxy-selector cfg))
    (define ch (make-channel))
    (for ([i (in-range 40)]) (thread (lambda () (channel-put ch (hash-ref (concurrent) 'server)))))
    (define results (for/list ([i (in-range 40)]) (channel-get ch)))
    (check-equal? (count (lambda (x) (equal? x "http://a:80")) results) 20))
  (test-case "TEST-102 reusable config creates independent crawler pools"
    (define proxy (resolve-proxy-config (hash 'pool '("http://a:80" "http://b:80")) (hash) (lambda (_) #f)))
    (define cfg (make-production-crawler-config #:services '(direct) #:enable-monitoring #f
                   #:service-configs (attach-proxy-config (hash) proxy '(direct))))
    (define a (create-production-crawler cfg))
    (define b (create-production-crawler cfg))
    (check-equal? (hash-ref (crawler-proxy-for-robots a) 'server) "http://a:80")
    (check-equal? (hash-ref (crawler-proxy-for-robots b) 'server) "http://a:80"))
  (test-case "TEST-101 config loading permits later credential completion"
    (define cfg (hash-set (default-config) 'proxy (hash 'server "http://host:80" 'username "u")))
    (check-true (validate-config cfg)))
  (test-case "TEST-101 grammar property and malformed-input corpus"
    (for ([i (in-range 1 200)])
      (define endpoint (format "http://host-~a.example:~a" i i))
      (define parsed (recognize-proxy endpoint))
      (check-equal? (recognize-proxy (hash-ref parsed 'server)) parsed)
      (for ([bad (list (string-append endpoint "/bad") (string-append endpoint "?q=1")
                       (string-append endpoint "#x") (string-append endpoint "\n"))])
        (check-exn exn:fail? (lambda () (recognize-proxy bad))))))
  (test-case "TEST-106 secrets are not echoed"
    (with-handlers ([exn:fail? (lambda (e) (check-false (string-contains? (exn-message e) "secret")))])
      (recognize-proxy "http://secret:secret@host:80/bad")))
)
