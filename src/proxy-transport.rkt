#lang racket
(require racket/system net/url)
(provide proxy-fetch)

;; CON-102: curl owns HTTP/CONNECT/SOCKS; no shell invocation or secret argv.
(define (curl-quoted value)
  (define escaped
    (for/fold ([text value]) ([pair (in-list '(("\\" . "\\\\") ("\"" . "\\\"")
                                              ("\n" . "\\n") ("\r" . "\\r") ("\t" . "\\t") ("\v" . "\\v")))])
      (string-replace text (car pair) (cdr pair))))
  (string-append "\"" escaped "\""))
(define (proxy-fetch target proxy #:timeout [timeout 30000]
                     #:user-agent [agent "AR-Crawl/1.0"] #:follow-redirects [follow? #t])
  (define target-url (string->url target))
  (unless (and (member (url-scheme target-url) '("http" "https")) (url-host target-url))
    (error 'proxy-fetch "Expected an HTTP or HTTPS target"))
  (define curl (find-executable-path "curl"))
  (unless curl (error 'proxy-fetch "Proxy routing requires curl on PATH"))
  (define custodian (make-custodian))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-custodian custodian] [current-subprocess-custodian-mode 'kill])
       (define-values (proc stdout stdin stderr)
         (subprocess #f #f #f curl "--disable" "--config" "-"))
       ;; Never inherit curlrc, NO_PROXY, or implicit proxy routing. Secrets use stdin.
       (define options
         (append
          (list (cons "url" target) (cons "proxy" (regexp-replace #rx"^socks5://" (hash-ref proxy 'server) "socks5h://"))
                (cons "noproxy" (string-join (hash-ref proxy 'bypass '()) ","))
                (cons "user-agent" agent) (cons "proto" "=http,https")
                (cons "proto-redir" "=http,https")
                (cons "max-time" (number->string (/ timeout 1000.0)))
                (cons "max-redirs" "5"))
          (if (hash-has-key? proxy 'username)
              (list (cons "proxy-user" (string-append (hash-ref proxy 'username) ":" (hash-ref proxy 'password)))) '())))
       (for ([option options])
         (fprintf stdin "~a = ~a\n" (car option) (curl-quoted (cdr option))))
       (display "silent\ngloboff\nfail\n" stdin)
       (when follow? (display "location\n" stdin))
       (close-output-port stdin)
       ;; Drain stderr concurrently so a child cannot block on a full error pipe.
       (define drain (thread (lambda () (copy-port stderr (open-output-nowhere)))))
       (define content (port->string stdout))
       (subprocess-wait proc)
       (thread-wait drain)
       (close-input-port stdout)
       (close-input-port stderr)
       (unless (zero? (subprocess-status proc))
         (error 'proxy-fetch "Proxy request failed"))
       content))
   (lambda () (custodian-shutdown-all custodian))))
