#lang racket

#|
 @title{SQLite Output Demo}
 @author{Anuna Research}
 @date{2025-01-10}
 
 Demonstrates SQLite database output capabilities of AR-Crawl.
 Shows how crawl data is stored in a queryable database format.
|#

(require "../src/cli.rkt"
         "../src/sqlite-formatter.rkt"
         db)

;; Demo: Crawl a site and save to SQLite
(define (demo-sqlite-crawl)
  (printf "AR-Crawl SQLite Output Demo~n")
  (printf "==========================~n~n")
  
  ;; Example crawl command with SQLite output
  (printf "1. Crawling site and saving to SQLite database...~n")
  (printf "Command: racket src/cli.rkt --output output/demo.db --format sqlite crawl-site https://example.com --max-pages 5~n~n")
  
  ;; Simulate the crawl result for demo
  (define demo-db-path "output/demo-crawl.db")
  
  ;; Create sample crawl data
  (define sample-pages
    (list
     (hash 'url "https://example.com"
           'title "Example Domain"
           'content "<html><body><h1>Example Domain</h1><p>This domain is for use in illustrative examples.</p></body></html>"
           'timestamp "2025-01-10T15:30:45Z"
           'metadata (hash 'content-length 1256
                           'method "direct-http"
                           'user-agent "AR-Crawl/1.0")
           'links (list "https://example.com/about" "https://example.com/contact"))
     
     (hash 'url "https://example.com/about" 
           'title "About - Example"
           'content "<html><body><h1>About</h1><p>About this example domain.</p></body></html>"
           'timestamp "2025-01-10T15:30:50Z"
           'metadata (hash 'content-length 890
                           'method "direct-http"
                           'user-agent "AR-Crawl/1.0")
           'links (list "https://example.com/"))))
  
  (define sample-metadata
    (hash 'seed-url "https://example.com"
          'base-domain "example.com"
          'pages sample-pages
          'statistics (hash 'pages-crawled 2
                           'duration-ms 5200
                           'total-urls-discovered 3
                           'average-page-time-ms 2600.0)
          'failed-urls '()))
  
  ;; Save to SQLite database
  (make-directory* "output")
  (format-data-sqlite sample-pages demo-db-path sample-metadata)
  
  (printf "✓ Crawl data saved to SQLite database: ~a~n~n" demo-db-path)
  
  ;; Demo: Query the database
  (printf "2. Querying the SQLite database...~n")
  (demo-sqlite-queries demo-db-path)
  
  (printf "~n3. Exporting back to JSON...~n")
  (define json-export-path "output/demo-export.json")
  (export-sqlite-to-json demo-db-path json-export-path)
  (printf "✓ Data exported to JSON: ~a~n" json-export-path))

;; Demo: Show various SQL queries
(define (demo-sqlite-queries db-path)
  (define db (sqlite3-connect #:database db-path))
  
  ;; Query 1: List all crawl sessions
  (printf "   Query: All crawl sessions~n")
  (define sessions (query-rows db "SELECT crawl_id, seed_url, pages_crawled, duration_ms FROM crawl_sessions"))
  (for ([session sessions])
    (printf "   - Session ~a: ~a (~a pages, ~a ms)~n" 
            (vector-ref session 0)
            (vector-ref session 1) 
            (vector-ref session 2)
            (vector-ref session 3)))
  
  ;; Query 2: List all crawled pages
  (printf "~n   Query: All crawled pages~n")
  (define pages (query-rows db "SELECT url, title, content_length FROM crawled_pages"))
  (for ([page pages])
    (printf "   - ~a: \"~a\" (~a bytes)~n" 
            (vector-ref page 0)
            (vector-ref page 1)
            (vector-ref page 2)))
  
  ;; Query 3: Link analysis
  (printf "~n   Query: Link analysis~n")
  (define link-count (query-value db "SELECT COUNT(*) FROM discovered_links"))
  (printf "   - Total links discovered: ~a~n" link-count)
  
  ;; Query 4: Page sizes
  (printf "~n   Query: Average page size~n")
  (define avg-size (query-value db "SELECT AVG(content_length) FROM crawled_pages"))
  (printf "   - Average page size: ~a bytes~n" (if avg-size (round avg-size) 0))
  
  (disconnect db))

;; CLI integration example
(define (demo-cli-usage)
  (printf "~n4. CLI Usage Examples~n")
  (printf "=====================~n")
  (printf "# Crawl single URL to SQLite:~n")
  (printf "racket src/cli.rkt --output results.db --format sqlite crawl https://example.com~n~n")
  
  (printf "# Crawl entire site to SQLite:~n")
  (printf "racket src/cli.rkt --output site-data.db --format sqlite crawl-site https://example.com --max-pages 50~n~n")
  
  (printf "# Query the database with standard SQL tools:~n")
  (printf "sqlite3 results.db \"SELECT url, title FROM crawled_pages WHERE content_length > 1000\"~n~n")
  
  (printf "# Benefits of SQLite output:~n")
  (printf "- Compact binary format (smaller than JSON)~n")
  (printf "- Queryable with standard SQL~n")
  (printf "- Indexed for fast searches~n")
  (printf "- Structured schema with relationships~n")
  (printf "- Can be imported into data analysis tools~n"))

;; Main demo runner
(define (main)
  (demo-sqlite-crawl)
  (demo-cli-usage)
  (printf "~nDemo complete! Check the output/ directory for generated files.~n"))

;; Run demo if called directly
(module+ main
  (main))
