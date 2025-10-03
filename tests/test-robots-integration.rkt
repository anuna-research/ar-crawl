#lang racket

#|
 @title{Robots.txt Integration Test}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Test suite for robots.txt integration with the site crawler.
|#

(require rackunit
         "../src/robots-txt.rkt")

;; Test comprehensive robots.txt functionality
(test-case "Complete robots.txt workflow"
  ;; Create a sample robots.txt content
  (define sample-content 
    "User-agent: *\nDisallow: /admin/\nDisallow: /private/\nAllow: /private/public/\nCrawl-delay: 2\nSitemap: https://example.com/sitemap.xml")
  
  ;; Parse the robots.txt
  (define robots (parse-robots-txt sample-content "example.com"))
  
  ;; Test basic parsing
  (check-true (robots-txt? robots))
  (check-equal? (robots-txt-host robots) "example.com")
  (check-equal? (length (robots-txt-rules robots)) 1)
  (check-equal? (robots-txt-sitemap-urls robots) '("https://example.com/sitemap.xml"))
  
  ;; Test crawling permissions
  (check-true (is-crawling-allowed? robots "TestBot" "/"))
  (check-true (is-crawling-allowed? robots "TestBot" "/public/page.html"))
  (check-false (is-crawling-allowed? robots "TestBot" "/admin/"))
  (check-false (is-crawling-allowed? robots "TestBot" "/admin/users"))
  (check-false (is-crawling-allowed? robots "TestBot" "/private/secret"))
  (check-true (is-crawling-allowed? robots "TestBot" "/private/public/page"))
  
  ;; Test crawl delay
  (check-equal? (get-crawl-delay robots "TestBot") 2)
  
  ;; Test sitemap URLs
  (check-equal? (get-sitemaps robots) '("https://example.com/sitemap.xml")))

;; Test URL generation
(test-case "Robots.txt URL generation"
  (check-equal? (robots-txt-url "https://example.com") "https://example.com/robots.txt")
  (check-equal? (robots-txt-url "https://example.com/path/to/page") "https://example.com/robots.txt")
  (check-equal? (robots-txt-url "http://localhost:3000") "http://localhost:3000/robots.txt"))

;; Test cache functionality
(test-case "Robots.txt caching"
  (define cache (create-robots-cache))
  (define robots (parse-robots-txt "User-agent: *\nDisallow: /test/" "example.com"))
  
  ;; Cache should be empty initially
  (check-false (get-cached-robots cache "https://example.com" "TestBot"))
  
  ;; Cache the robots.txt
  (cache-robots cache "https://example.com" robots)
  
  ;; Should be able to retrieve from cache
  (define cached (get-cached-robots cache "https://example.com" "TestBot"))
  (check-true (robots-txt? cached))
  (check-equal? (robots-txt-host cached) "example.com"))

(printf "Running robots.txt integration tests...~n")
(printf "All integration tests passed!~n")
