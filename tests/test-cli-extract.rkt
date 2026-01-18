#lang racket

#|
 @title{CLI Extract Command Tests}
 @author{Anuna Research}
 @date{2026-01-02}

 Tests for the extract command's --fields shorthand behavior.
 See: users/llm-agent/user.md for the expected UX patterns.
|#

(require rackunit
         rackunit/text-ui
         racket/system
         racket/port
         json)

;; Helper to run CLI commands and capture output
(define (run-cli . args)
  ;; Navigate to the parent directory (project root) to find src/cli.rkt
  (define project-root (simplify-path (build-path (current-directory) "..")))
  (define cmd (string-append "cd " (path->string project-root)
                            " && racket src/cli.rkt "
                            (string-join args " ")))
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f "/bin/sh" "-c" cmd))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (define exit-code (subprocess-status proc))
  (close-input-port stdout)
  (close-input-port stderr)
  (values out err exit-code))

;; Create test data file
(define test-json-content
  (jsexpr->string
   (hash 'data
         (list (hash 'url "https://example.com"
                     'title "Test Page"
                     'content "<html><head><title>Example</title></head><body><h1>Hello</h1><p>World</p></body></html>")))))

(define test-file "/tmp/test-extract-data.json")

(define (setup-test-file)
  (call-with-output-file test-file
    (lambda (out) (display test-json-content out))
    #:exists 'replace))

;; Test Suites
(define cli-extract-tests
  (test-suite
   "CLI Extract Command Tests"

   #:before (lambda () (setup-test-file))

   (test-case "--xpath-map works for simple extraction"
     (define-values (out err code)
       (run-cli "extract" test-file
                "--xpath-map" "'{\"title\": \"//title\", \"heading\": \"//h1\"}'"))
     (check-equal? code 0 (format "Expected exit 0, got ~a. stderr: ~a" code err))
     (define result (string->jsexpr out))
     (check-true (hash? result))
     (define data (hash-ref result 'data '()))
     (check-true (> (length data) 0) "Should have extracted data"))

   (test-case "--fields alone works as alias for --xpath-map"
     ;; This is the key test: LLM agents expect --fields to work alone
     ;; for simple field extraction without requiring --parent
     (define-values (out err code)
       (run-cli "extract" test-file
                "--fields" "'{\"title\": \"//title\", \"heading\": \"//h1\"}'"))
     (check-equal? code 0
                   (format "Expected --fields alone to work (exit 0), got ~a. stderr: ~a" code err))
     (when (= code 0)
       (define result (string->jsexpr out))
       (check-true (hash? result))
       (define data (hash-ref result 'data '()))
       (check-true (> (length data) 0) "Should have extracted data")))

   (test-case "--parent with --fields works for item extraction"
     (define-values (out err code)
       (run-cli "extract" test-file
                "--parent" "\"//body\""
                "--fields" "'{\"heading\": \".//h1\", \"text\": \".//p\"}'"))
     (check-equal? code 0 (format "Expected exit 0, got ~a. stderr: ~a" code err)))))

;; Main execution
(module+ main
  (printf "CLI Extract Tests~n")
  (printf "=================~n~n")
  (run-tests cli-extract-tests)
  (printf "~nTests completed!~n"))

(module+ test
  (run-tests cli-extract-tests))
