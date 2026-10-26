#lang racket

(require net/url racket/hash)
(provide resolve-proxy-config recognize-proxy make-proxy-selector
         read-proxy-list attach-proxy-config check-proxy-fields instantiate-proxy-selectors)

;; CON-101 (SPEC-001-proxy-support): recognise complete inputs before I/O.
(define (invalid field) (error 'proxy-config "Invalid proxy ~a" field))
(define (clean-string? x)
  (and (string? x) (not (regexp-match? #px"[\u0000-\u001f\u007f]" x))))
(define dns-pattern #px"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
(define bypass-pattern #px"^\\.?(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
;; IPv6's hexadecimal-only grammar, recognised as a complete regular language.
(define h "[0-9A-Fa-f]{1,4}")
(define ipv6-pattern
  (pregexp (string-append "^(?:" "(?:" h ":){7}" h
                          "|(?:" h ":){1,7}:"
                          (apply string-append
                                 (for/list ([left (in-range 1 7)])
                                   (format "|(?:~a:){1,~a}(?::~a){1,~a}" h left h (- 7 left))))
                          "|:(?:(?::" h "){1,7}|:))$")))
(define endpoint-pattern
  #px"^(?:http|socks5)://(?:(?:[A-Za-z0-9._~!$&'()*+,;=-]|%(?!3[aA])[0-9A-Fa-f]{2})*:[A-Za-z0-9._~!$&'()*+,;=:%-]*@)?(?:[A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+\\]):[0-9]+/?$")
(define (recognize-proxy endpoint)
  (unless (and (clean-string? endpoint) (regexp-match? endpoint-pattern endpoint)
               (not (regexp-match? #px"%(?![0-9A-Fa-f]{2})" endpoint)))
    (invalid 'server))
  (with-handlers ([exn:fail? (lambda (_) (invalid 'server))])
    (define u (string->url endpoint))
    (unless (and (url-host u) (if (string-contains? (url-host u) ":")
                     (regexp-match? ipv6-pattern (url-host u))
                     (regexp-match? dns-pattern (url-host u)))
                 (exact-integer? (url-port u)) (<= 1 (url-port u) 65535))
      (invalid 'server))
    (define server (url->string (struct-copy url u [user #f] [path '()] [path-absolute? #f])))
    (define base (hash 'server server))
    (cond
      [(url-user u)
       (define parts (string-split (url-user u) ":" #:trim? #f))
       (unless (>= (length parts) 2) (invalid 'credentials))
       (define user (car parts))
       (define pass (string-join (cdr parts) ":"))
       (unless (and (clean-string? user) (clean-string? pass) (not (string-contains? user ":")))
         (invalid 'credentials))
       (hash-set* base 'username user 'password pass)]
      [else base])))

(define check-proxy-fields
  (lambda (cfg) (check-fields cfg)))

(define (check-fields cfg)
  (unless (hash? cfg) (invalid 'section))
  (for ([(key value) (in-hash cfg)])
    (case key
      [(enabled) (unless (boolean? value) (invalid key))]
      [(server) (recognize-proxy value)]
      [(username password) (unless (clean-string? value) (invalid key))]
      [(rotation) (unless (member value '("per-request" "sticky" "round-robin")) (invalid key))]
      [(pool) (unless (and (list? value) (pair? value)) (invalid key))
              (for-each recognize-proxy value)]
      [(bypass) (unless (and (list? value)
                            (andmap (lambda (v) (and (clean-string? v) (regexp-match? bypass-pattern v))) value))
                  (invalid key))]
      [else (invalid 'field)])))

(define (resolve-proxy-config config [cli (hash)] [env getenv])
  (check-fields config)
  (check-fields cli)
  (when (and (hash-has-key? cli 'server) (hash-has-key? cli 'pool))
    (invalid 'endpoint-conflict))
  (define env-cfg
    (for/fold ([cfg (hash)]) ([entry (in-list (list (cons 'server (or (env "PROXY_URL") (env "PROXY_SERVER")))
                                                  (cons 'username (env "PROXY_USER"))
                                                  (cons 'password (env "PROXY_PASS"))))])
      (if (cdr entry) (hash-set cfg (car entry) (cdr entry)) cfg)))
  ;; Lower-priority endpoint sources are discarded, not combined into a pool.
  (define merged
    (for/fold ([cfg env-cfg]) ([layer (in-list (list config cli))])
      (define cleared (if (or (hash-has-key? layer 'server) (hash-has-key? layer 'pool))
                          (hash-remove (hash-remove cfg 'server) 'pool) cfg))
      (hash-union cleared layer #:combine (lambda (_ new) new))))
  (define enabled (if (or (hash-has-key? cli 'server) (hash-has-key? cli 'pool)) #t
                      (hash-ref merged 'enabled (or (hash-has-key? merged 'server) (hash-has-key? merged 'pool)))))
  (cond
    [(not enabled) #f]
    [else
     (check-fields merged)
     (define entries (hash-ref merged 'pool (lambda () (if (hash-has-key? merged 'server) (list (hash-ref merged 'server)) '()))))
     (unless (pair? entries) (invalid 'pool))
     (define parsed
       (for/list ([entry entries])
         (define effective
           (for/fold ([p (recognize-proxy entry)])
                     ([key '(username password)] #:when (hash-has-key? merged key))
             (hash-set p key (hash-ref merged key))))
         (when (xor (hash-has-key? effective 'username) (hash-has-key? effective 'password))
           (invalid 'credentials))
         effective))
     (when (and (hash-has-key? merged 'username) (string-contains? (hash-ref merged 'username) ":"))
       (invalid 'username))
     (hash-set* merged 'pool entries 'parsed-pool parsed
                'rotation (hash-ref merged 'rotation "per-request")
                'bypass (hash-ref merged 'bypass '()))]))

(define (make-proxy-selector config)
  (define index 0)
  (define lock (make-semaphore 1))
  ;; Closure deliberately prints no configuration or credentials (REQ-105).
  (lambda ()
    (and config
         (call-with-semaphore
          lock
          (lambda ()
            (define entries (hash-ref config 'parsed-pool))
            (define selected (list-ref entries index))
            (unless (equal? (hash-ref config 'rotation) "sticky")
              (set! index (modulo (add1 index) (length entries))))
            (for/fold ([p (hash-set selected 'bypass (hash-ref config 'bypass))])
                      ([key '(username password)] #:when (hash-has-key? config key))
              (hash-set p key (hash-ref config key))))))))

(define (read-proxy-list path)
  (with-handlers ([exn:fail? (lambda (_) (invalid 'list-file))])
    (define entries (filter (lambda (line) (and (not (equal? line "")) (not (string-prefix? line "#"))))
                            (file->lines path)))
    (unless (pair? entries) (invalid 'pool))
    (for-each recognize-proxy entries)
    entries))

(define (attach-proxy-config services proxy-config service-names)
  (for/fold ([result services]) ([name (in-list service-names)])
    (define cfg (hash-ref services name (hash)))
    (define enabled (hash-ref cfg 'use_proxy #t))
    (unless (boolean? enabled) (invalid 'use_proxy))
    (when (and proxy-config enabled (not (memq name '(direct playwright))))
      (error 'proxy-config "Selected service does not support proxy routing; set use_proxy to false to opt out"))
    (when (and proxy-config enabled (eq? name 'playwright))
      (for ([entry (in-list (hash-ref proxy-config 'parsed-pool))])
        (when (and (string-prefix? (hash-ref entry 'server) "socks5://")
                   (or (hash-has-key? entry 'username) (hash-has-key? proxy-config 'username)))
          (error 'proxy-config "Playwright does not support authenticated SOCKS5; use the direct HTTP adaptor"))))
    (hash-set result name (if (and proxy-config enabled) (hash-set cfg 'proxy-settings proxy-config) cfg))))

;; One shared pool per crawler, freshly created even when its config is reused.
(define (instantiate-proxy-selectors services)
  (define settings
    (for/or ([cfg (in-hash-values services)]) (hash-ref cfg 'proxy-settings #f)))
  (define select (make-proxy-selector settings))
  (for/hash ([(name cfg) (in-hash services)])
    (values name (if (hash-ref cfg 'proxy-settings #f)
                     (hash-set (hash-remove cfg 'proxy-settings) 'proxy-selector select)
                     cfg))))
