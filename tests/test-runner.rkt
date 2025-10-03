#lang racket

#|
 @title{Test Runner}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Comprehensive test suite for AR-Crawl components.
|#

(require rackunit
         rackunit/text-ui
         "../src/crawl-service-adaptor.rkt"
         "../src/config-manager.rkt"
         "../src/production-crawler.rkt"
         "../src/utils.rkt")

;; Test Suites
;; -----------

(define crawl-service-tests
  (test-suite
   "Crawl Service Adaptor Tests"
   
   (test-case "Service registration"
     (register-service 'test-service (lambda (url config) "test-result"))
     (check-true (member 'test-service (get-available-services)))
     (check-equal? (call-service 'test-service "http://test.com" (hash))
                   "test-result"))
   
   (test-case "Response normalization"
     (define response (normalize-response "test content"))
     (check-true (hash? response))
     (check-equal? (hash-ref response 'content) "test content")
     (check-true (hash-has-key? response 'timestamp)))
   
   (test-case "Content extraction"
     (define response (hash 'content "hello world" 
                           'links '("http://test.com")
                           'metadata (hash 'title "Test")))
     (check-equal? (extract-content response) "hello world")
     (check-equal? (extract-links response) '("http://test.com"))
     (check-equal? (hash-ref (extract-metadata response) 'title) "Test"))
   
   (test-case "Fallback system"
     ; Mock failing services
     (register-service 'failing-service (lambda (url config) #f))
     (register-service 'working-service (lambda (url config) "success"))
     
     (define result (fetch-with-fallback "http://test.com" 
                                        '(failing-service working-service)))
     (check-equal? result "success"))))

(define config-manager-tests
  (test-suite
   "Configuration Manager Tests"
   
   (test-case "Environment variable substitution"
     (putenv "TEST_CONFIG_VAR" "test_value")
     (define config (hash 'test_key "${TEST_CONFIG_VAR}"))
     (define result (substitute-env-vars config))
     (check-equal? (hash-ref result 'test_key) "test_value"))
   
   (test-case "Nested configuration access"
     (define config (hash 'level1 (hash 'level2 (hash 'level3 "deep_value"))))
     (check-equal? (get-config-value config '(level1 level2 level3)) "deep_value")
     (check-equal? (get-config-value config '(nonexistent) "default") "default"))
   
   (test-case "Configuration validation"
     (define valid-config (default-config))
     (check-true (validate-config valid-config))
     
     (define invalid-config (hash 'invalid "structure"))
     (check-false (validate-config invalid-config)))
   
   (test-case "Configuration merging"
     (define base (hash 'a 1 'b (hash 'c 2 'd 3)))
     (define override (hash 'b (hash 'c 99) 'e 4))
     (define merged (merge-configs base override))
     
     (check-equal? (hash-ref merged 'a) 1)
     (check-equal? (hash-ref (hash-ref merged 'b) 'c) 99)
     (check-equal? (hash-ref (hash-ref merged 'b) 'd) 3)
     (check-equal? (hash-ref merged 'e) 4)))

(define production-crawler-tests
  (test-suite
   "Production Crawler Tests"
   
   (test-case "Crawler configuration creation"
     (define config (production-crawler-config 
                    #:services '(test-service)
                    #:max-concurrent-jobs 5
                    #:rate-limit-ms 500))
     
     (check-true (production-crawler-config? config))
     (check-equal? (production-crawler-config-services config) '(test-service))
     (check-equal? (production-crawler-config-max-concurrent-jobs config) 5)
     (check-equal? (production-crawler-config-rate-limit-ms config) 500))
   
   (test-case "Crawler creation"
     (define config (production-crawler-config #:services '(test-service)))
     (define crawler (create-production-crawler config))
     
     (check-true (production-crawler? crawler))
     (check-equal? (production-crawler-job-counter crawler) 0)
     (check-true (hash-empty? (production-crawler-active-jobs crawler))))
   
   (test-case "Health check structure"
     (define config (production-crawler-config))
     (define crawler (create-production-crawler config))
     (define health (health-check crawler))
     
     (check-true (health-status? health))
     (check-true (member (health-status-status health) '(healthy degraded unhealthy)))
     (check-true (hash? (health-status-services health)))
     (check-true (>= (health-status-uptime health) 0))))

(define utils-tests
  (test-suite
   "Utility Functions Tests"
   
   (test-case "URL validation"
     (check-true (ok-http-url? "http://example.com"))
     (check-true (ok-http-url? "https://example.com/path?query=value"))
     (check-false (ok-http-url? "ftp://example.com"))
     (check-false (ok-http-url? "not-a-url"))
     (check-false (ok-http-url? ""))
     (check-false (ok-http-url? 123)))
   
   (test-case "String manipulation"
     (check-equal? (string-normalize-spaces "  hello   world  \n\t") "hello world")
     (check-equal? (string-truncate "hello world" 5) "hello")
     (check-equal? (string-truncate "hi" 10) "hi")
     (check-equal? (string-clean "hello\x01world\x7f") "helloworld"))
   
   (test-case "JSON utilities"
     (define json-str "{\"key\": \"value\", \"number\": 42}")
     (define parsed (safe-string->jsexpr json-str))
     (check-true (hash? parsed))
     (check-equal? (hash-ref parsed 'key) "value")
     (check-equal? (hash-ref parsed 'number) 42)
     
     ; Test invalid JSON
     (check-false (safe-string->jsexpr "invalid json")))
   
   (test-case "List utilities"
     (check-equal? (list-slice '(1 2 3 4 5) 1 3) '(2 3))
     (check-equal? (list-slice '(1 2 3 4 5) 2) '(3 4 5))
     (check-equal? (list-slice '(1 2 3) 5) '())
     
     (define lst '((a . 1) (b . 2) (a . 3) (c . 4)))
     (define unique (remove-duplicates-by lst car))
     (check-equal? (length unique) 3))
   
   (test-case "Hash utilities"
     (define h1 (hash 'a 1 'b (hash 'x 10)))
     (define h2 (hash 'b (hash 'y 20) 'c 3))
     (define merged (deep-merge-hash h1 h2))
     
     (check-equal? (hash-ref merged 'a) 1)
     (check-equal? (hash-ref merged 'c) 3)
     (check-true (hash-has-key? (hash-ref merged 'b) 'x))
     (check-true (hash-has-key? (hash-ref merged 'b) 'y)))
   
   (test-case "Safe execution"
     (check-equal? (safe-execute (lambda () (/ 1 0)) "default") "default")
     (check-equal? (safe-execute (lambda () (+ 1 2)) "default") 3)))

(define integration-tests
  (test-suite
   "Integration Tests"
   
   (test-case "Full configuration loading and validation"
     ; Create a temporary config
     (define temp-config 
       (hash 'crawler (hash 'services '(test-service)
                           'rate_limit_ms 1000
                           'timeout_ms 30000)
             'services (hash 'test-service (hash 'api_key "test"))))
     
     (check-true (validate-config temp-config))
     
     ; Test environment variable substitution
     (putenv "TEST_API_KEY" "real_key")
     (define config-with-env 
       (hash 'services (hash 'test-service (hash 'api_key "${TEST_API_KEY}"))))
     (define substituted (substitute-env-vars config-with-env))
     (check-equal? (get-config-value substituted '(services test-service api_key)) 
                   "real_key"))
   
   (test-case "Service fallback integration"
     ; Register multiple test services
     (register-service 'unreliable-service 
                      (lambda (url config) 
                        (if (string-contains? url "fail") #f "success")))
     (register-service 'reliable-service 
                      (lambda (url config) "backup-success"))
     
     ; Test successful fallback
     (define result1 (fetch-with-fallback "http://fail.com" 
                                         '(unreliable-service reliable-service)))
     (check-equal? result1 "backup-success")
     
     ; Test no fallback needed
     (define result2 (fetch-with-fallback "http://success.com" 
                                         '(unreliable-service reliable-service)))
     (check-equal? result2 "success"))))

;; Main Test Suite
;; ---------------

(define all-tests
  (test-suite
   "AR-Crawl Test Suite"
   crawl-service-tests
   config-manager-tests
   production-crawler-tests
   utils-tests
   integration-tests))

;; Test Runner Function
;; --------------------

(define (run-tests [suite all-tests] [verbose? #f])
  (if verbose?
      (run-tests suite)
      (run-tests suite)))

;; Performance Tests
;; -----------------

(define (run-performance-tests)
  (printf "Running performance tests...~n")
  
  ; Test URL validation performance
  (define urls (for/list ([i 1000]) "https://example.com/page"))
  (define start-time (current-milliseconds))
  (for ([url urls]) (ok-http-url? url))
  (define end-time (current-milliseconds))
  (printf "URL validation: ~a URLs in ~a ms~n" 
         (length urls) (- end-time start-time))
  
  ; Test configuration parsing performance
  (define large-config 
    (hash 'services 
          (for/hash ([i 100]) 
            (values (string->symbol (format "service~a" i))
                   (hash 'api_key (format "key~a" i))))))
  (define start-time2 (current-milliseconds))
  (for ([i 100]) (validate-config large-config))
  (define end-time2 (current-milliseconds))
  (printf "Config validation: 100 iterations in ~a ms~n" 
         (- end-time2 start-time2)))

;; Mock Service for Testing
;; ------------------------

(define (create-mock-service name behavior)
  "Create a mock service for testing purposes"
  (register-service name
    (lambda (url config)
      (case behavior
        [(success) (hash 'content "mock content" 'url url)]
        [(failure) #f]
        [(slow) (begin (sleep 1) (hash 'content "slow content" 'url url)))
        [(random) (if (> (random) 0.5) 
                     (hash 'content "random content" 'url url) 
                     #f)]
        [else #f]))))

;; Initialize mock services for testing
(create-mock-service 'mock-success 'success)
(create-mock-service 'mock-failure 'failure)
(create-mock-service 'mock-slow 'slow)
(create-mock-service 'mock-random 'random)

;; Main execution
;; --------------

(module+ main
  (printf "AR-Crawl Test Suite~n")
  (printf "==================~n~n")
  
  ; Run main tests
  (run-tests all-tests)
  
  ; Run performance tests
  (printf "~n")
  (run-performance-tests)
  
  (printf "~nAll tests completed!~n"))

;; Test helper for CLI
(module+ test
  (provide run-tests all-tests))
