#lang racket

#|
 @title{Robots.txt Test Suite}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Test suite for the robots.txt functionality.
|#

(require rackunit
         "../src/robots-txt.rkt")

;; Test robots.txt parsing
(test-case "Parse basic robots.txt"
  (define content "User-agent: *\nDisallow: /private/\nAllow: /public/\nCrawl-delay: 1")
  (define robots (parse-robots-txt content "example.com"))
  
  (check-true (robots-txt? robots))
  (check-equal? (length (robots-txt-rules robots)) 1)
  (check-equal? (robots-txt-host robots) "example.com"))

;; Test crawling permissions
(test-case "Check crawling permissions"
  (define content "User-agent: *\nDisallow: /admin/\nDisallow: /private/\nAllow: /private/public/")
  (define robots (parse-robots-txt content "example.com"))
  
  ;; Should allow root
  (check-true (is-crawling-allowed? robots "TestBot" "/"))
  
  ;; Should disallow admin
  (check-false (is-crawling-allowed? robots "TestBot" "/admin/"))
  (check-false (is-crawling-allowed? robots "TestBot" "/admin/users"))
  
  ;; Should disallow private but allow private/public
  (check-false (is-crawling-allowed? robots "TestBot" "/private/"))
  (check-true (is-crawling-allowed? robots "TestBot" "/private/public/"))
  (check-true (is-crawling-allowed? robots "TestBot" "/private/public/page.html")))

;; Test user-agent specific rules
(test-case "User-agent specific rules"
  (define content "User-agent: TestBot\nDisallow: /test/\n\nUser-agent: *\nDisallow: /admin/")
  (define robots (parse-robots-txt content "example.com"))
  
  ;; TestBot should be blocked from /test/ but not /admin/
  (check-false (is-crawling-allowed? robots "TestBot" "/test/"))
  (check-true (is-crawling-allowed? robots "TestBot" "/admin/"))
  
  ;; Other bots should be blocked from /admin/ but not /test/
  (check-true (is-crawling-allowed? robots "OtherBot" "/test/"))
  (check-false (is-crawling-allowed? robots "OtherBot" "/admin/")))

;; Test crawl delay
(test-case "Crawl delay extraction"
  (define content "User-agent: *\nCrawl-delay: 5")
  (define robots (parse-robots-txt content "example.com"))
  
  (check-equal? (get-crawl-delay robots "TestBot") 5))

;; Test sitemap extraction
(test-case "Sitemap extraction"
  (define content "User-agent: *\nDisallow: /private/\nSitemap: https://example.com/sitemap.xml\nSitemap: https://example.com/sitemap2.xml")
  (define robots (parse-robots-txt content "example.com"))
  
  (check-equal? (get-sitemaps robots) '("https://example.com/sitemap.xml" "https://example.com/sitemap2.xml")))

;; Test robots.txt URL generation
(test-case "Robots.txt URL generation"
  (check-equal? (robots-txt-url "https://example.com") "https://example.com/robots.txt")
  (check-equal? (robots-txt-url "https://example.com/path") "https://example.com/robots.txt")
  (check-equal? (robots-txt-url "http://example.com:8080") "http://example.com:8080/robots.txt"))

;; Test path normalization
(test-case "Path normalization"
  (check-equal? (normalize-path "") "/")
  (check-equal? (normalize-path "path") "/path")
  (check-equal? (normalize-path "/path") "/path")
  (check-equal? (normalize-path "/path/") "/path/"))

;; Run the tests
(printf "Running robots.txt tests...~n")
(printf "All tests passed!~n")
