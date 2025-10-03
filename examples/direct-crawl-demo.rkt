#lang racket

;; Simple demo of using AR-Crawl with direct HTTP (no API keys required)

(require "../src/crawl-service-adaptor.rkt")

(printf "AR-Crawl Direct Service Demo~n")
(printf "============================~n~n")

(printf "Testing direct HTTP service (no API keys required)...~n")

;; Test the direct service
(define result (direct-http-adaptor "https://httpbin.org/html"))

(if result
    (begin
      (printf "✓ SUCCESS: Direct crawling works!~n~n")
      (printf "URL: ~a~n" (hash-ref result 'url))
      (printf "Title: ~a~n" (hash-ref result 'title "No title"))
      (printf "Content length: ~a chars~n" 
             (string-length (hash-ref result 'content "")))
      (printf "Links found: ~a~n" (length (hash-ref result 'links '())))
      (printf "Method: ~a~n" 
             (hash-ref (hash-ref result 'metadata (hash)) 'method "unknown"))
      (printf "Timestamp: ~a~n" (hash-ref result 'timestamp "unknown")))
    (printf "✗ FAILED: Could not crawl with direct service~n"))

(printf "~nAvailable services:~n")
(for ([service (get-available-services)])
  (printf "  • ~a~n" service))

(printf "~nTo use without any API keys, just use 'direct' as your service!~n")
