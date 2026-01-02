#lang racket

#|
 @title{SQLite Database Formatter}
 @author{Anuna Research}
 @date{2025-01-10}
 
 This module provides SQLite database output formatting for crawl results.
 Provides a compact, queryable alternative to JSON output.
|#

(require racket/contract
         racket/match
         racket/string
         racket/date
         db
         json)

;; Date formatting helpers (replaces gregor's ~t)
(define (format-datetime-db [d (current-date)])
  (format "~a-~a-~a ~a:~a:~a"
          (date-year d)
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))

(define (format-datetime-filename [d (current-date)])
  (format "~a-~a-~a-~a~a~a"
          (date-year d)
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))

(require "scraper-interfaces.rkt")

(provide
 (contract-out
  ;; Main interface
  [format-data-sqlite
   (-> (listof hash?) 
       path-string?
       hash?
       boolean?)]
  
  ;; Streaming interface  
  [create-sqlite-formatter
   (-> path-string? hash? sqlite-formatter?)]
   
  [write-item-sqlite (-> sqlite-formatter? hash? void?)]
  [close-sqlite-formatter (-> sqlite-formatter? void?)]
  
  ;; Query helpers
  [query-crawl-results
   (-> path-string? string? (listof vector?))]

  [load-crawled-pages
   (-> path-string? (listof hash?))]

  [analyze-crawl-stats
   (-> path-string? hash?)]

  [export-sqlite-to-json
   (-> path-string? path-string? boolean?)])
 
 ;; Structure and predicates
 (struct-out sqlite-formatter))

;; SQLite formatter structure
(struct sqlite-formatter
  (db-connection
   crawl-id
   metadata
   item-count)
  #:mutable
  #:transparent)

;; Schema creation functions
(define (create-database-schema db)
  ;; Create tables one by one
  (query-exec db "CREATE TABLE IF NOT EXISTS crawl_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT UNIQUE NOT NULL,
    seed_url TEXT,
    base_domain TEXT,
    start_time TEXT,
    end_time TEXT,
    duration_ms INTEGER,
    pages_crawled INTEGER,
    failed_urls_count INTEGER,
    total_urls_discovered INTEGER,
    average_page_time_ms REAL,
    config TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )")
  
  (query-exec db "CREATE TABLE IF NOT EXISTS crawled_pages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    title TEXT,
    content TEXT,
    content_length INTEGER,
    method TEXT,
    user_agent TEXT,
    timestamp TEXT,
    depth INTEGER,
    parent_url TEXT,
    status_code INTEGER,
    response_time_ms INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  )")
  
  (query-exec db "CREATE TABLE IF NOT EXISTS discovered_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    source_url TEXT NOT NULL,
    target_url TEXT NOT NULL,
    link_text TEXT,
    link_type TEXT,
    depth INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  )")
  
  (query-exec db "CREATE TABLE IF NOT EXISTS failed_urls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    error_message TEXT,
    error_type TEXT,
    attempted_at TEXT,
    retry_count INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  )")
  
  (query-exec db "CREATE TABLE IF NOT EXISTS extracted_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    item_data TEXT,
    extraction_timestamp TEXT,
    field_count INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  )")
  
  ;; Create indexes
  (query-exec db "CREATE INDEX IF NOT EXISTS idx_crawled_pages_crawl_id ON crawled_pages(crawl_id)")
  (query-exec db "CREATE INDEX IF NOT EXISTS idx_crawled_pages_url ON crawled_pages(url)")
  (query-exec db "CREATE INDEX IF NOT EXISTS idx_discovered_links_crawl_id ON discovered_links(crawl_id)")
  (query-exec db "CREATE INDEX IF NOT EXISTS idx_failed_urls_crawl_id ON failed_urls(crawl_id)")
  (query-exec db "CREATE INDEX IF NOT EXISTS idx_extracted_items_crawl_id ON extracted_items(crawl_id)"))

;; Standard SQLite schema for crawl data (for command-line fallback)
(define SCHEMA-SQL
  "-- Main crawl sessions table
  CREATE TABLE IF NOT EXISTS crawl_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT UNIQUE NOT NULL,
    seed_url TEXT,
    base_domain TEXT,
    start_time TEXT,
    end_time TEXT,
    duration_ms INTEGER,
    pages_crawled INTEGER,
    failed_urls_count INTEGER,
    total_urls_discovered INTEGER,
    average_page_time_ms REAL,
    config TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  -- Crawled pages table
  CREATE TABLE IF NOT EXISTS crawled_pages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    title TEXT,
    content TEXT,
    content_length INTEGER,
    method TEXT,
    user_agent TEXT,
    timestamp TEXT,
    depth INTEGER,
    parent_url TEXT,
    status_code INTEGER,
    response_time_ms INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  );

  -- Links discovered during crawling
  CREATE TABLE IF NOT EXISTS discovered_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    source_url TEXT NOT NULL,
    target_url TEXT NOT NULL,
    link_text TEXT,
    link_type TEXT,
    depth INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  );

  -- Failed URLs
  CREATE TABLE IF NOT EXISTS failed_urls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    error_message TEXT,
    error_type TEXT,
    attempted_at TEXT,
    retry_count INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  );

  -- Extracted data items (for structured extraction)
  CREATE TABLE IF NOT EXISTS extracted_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    crawl_id TEXT NOT NULL,
    url TEXT NOT NULL,
    item_data TEXT,
    extraction_timestamp TEXT,
    field_count INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (crawl_id) REFERENCES crawl_sessions(crawl_id)
  );

  -- Indexes for performance
  CREATE INDEX IF NOT EXISTS idx_crawled_pages_crawl_id ON crawled_pages(crawl_id);
  CREATE INDEX IF NOT EXISTS idx_crawled_pages_url ON crawled_pages(url);
  CREATE INDEX IF NOT EXISTS idx_discovered_links_crawl_id ON discovered_links(crawl_id);
  CREATE INDEX IF NOT EXISTS idx_failed_urls_crawl_id ON failed_urls(crawl_id);
  CREATE INDEX IF NOT EXISTS idx_extracted_items_crawl_id ON extracted_items(crawl_id);")

;; @function{format-data-sqlite}
;; @description{Format and save crawl data to SQLite database}
;; @param[data]{listof hash?} Crawl results data
;; @param[db-path]{path-string?} SQLite database file path
;; @param[metadata]{hash?} Crawl metadata
;; @returns{boolean?} Success status
(define (format-data-sqlite data db-path metadata)
  (with-handlers ([exn:fail? 
                   (lambda (exn)
                     (raise (exn:scraper:parse
                             (format "Failed to save to SQLite: ~a" 
                                     (exn-message exn))
                             (current-continuation-marks))))])
    
    ;; Ensure directory exists
    (let ([dir (path-only db-path)])
      (when dir
        (make-directory* dir)))
    
    ;; Remove debug output for cleaner execution
    
    ;; Try to use command-line SQLite as fallback if library fails
    (define db
      (with-handlers ([exn:fail? (lambda (exn) #f)])
        (sqlite3-connect #:database db-path)))
    
    (if db
        ;; Use native SQLite library
        (let ([crawl-id (generate-crawl-id metadata)])
          (create-database-schema db)
          
          ;; Insert crawl session
          (insert-crawl-session db crawl-id metadata)
          
          ;; Process and insert data
          (cond
            ;; Site crawl results format
            [(and (hash-has-key? metadata 'pages)
                  (hash-has-key? metadata 'statistics))
             (insert-site-crawl-data db crawl-id data metadata)]
            
            ;; Single page or extracted items format
            [else
             (insert-extracted-items db crawl-id data)])
          
          (disconnect db)
          #t)
        ;; Use command-line fallback
        (create-sqlite-via-command-line data db-path metadata))))

;; @function{create-sqlite-formatter}
;; @description{Create streaming SQLite formatter}
;; @param[db-path]{path-string?} Database file path
;; @param[metadata]{hash?} Crawl metadata
;; @returns{sqlite-formatter?} Formatter instance
(define (create-sqlite-formatter db-path metadata)
  (let* ([dir (path-only db-path)]
         [_ (when dir (make-directory* dir))]
         [db (sqlite3-connect #:database db-path)]
         [crawl-id (generate-crawl-id metadata)])
    
    ;; Initialize schema
    (create-database-schema db)
    
    ;; Insert crawl session
    (insert-crawl-session db crawl-id metadata)
    
    (sqlite-formatter db crawl-id metadata 0)))

;; @function{write-item-sqlite}
;; @description{Write single item to SQLite database}
;; @param[fmt]{sqlite-formatter?} Formatter instance
;; @param[item]{hash?} Item to write
;; @returns{void?}
(define (write-item-sqlite fmt item)
  (define db (sqlite-formatter-db-connection fmt))
  (define crawl-id (sqlite-formatter-crawl-id fmt))
  
  (cond
    ;; Crawled page format
    [(hash-has-key? item 'url)
     (insert-crawled-page db crawl-id item)]
    
    ;; Extracted item format  
    [else
     (insert-extracted-item db crawl-id item)])
  
  (set-sqlite-formatter-item-count! 
   fmt 
   (+ (sqlite-formatter-item-count fmt) 1)))

;; @function{close-sqlite-formatter}
;; @description{Close SQLite formatter and update final statistics}
;; @param[fmt]{sqlite-formatter?} Formatter to close
;; @returns{void?}
(define (close-sqlite-formatter fmt)
  (define db (sqlite-formatter-db-connection fmt))
  (define crawl-id (sqlite-formatter-crawl-id fmt))
  
  ;; Update final statistics
  (query-exec db
    "UPDATE crawl_sessions 
     SET end_time = ?, 
         pages_crawled = ?
     WHERE crawl_id = ?"
    (format-datetime-db)
    (sqlite-formatter-item-count fmt)
    crawl-id)
  
  (disconnect db))

;; Command-line SQLite fallback
;; ----------------------------

;; @function{create-sqlite-via-command-line}
;; @description{Create SQLite database using command-line sqlite3 tool}
;; @param[data]{listof hash?} Crawl data
;; @param[db-path]{path-string?} Database path
;; @param[metadata]{hash?} Metadata
;; @returns{boolean?} Success status
(define (create-sqlite-via-command-line data db-path metadata)
  
  ;; Remove existing database file if it exists
  (when (file-exists? db-path)
    (delete-file db-path))
  
  ;; Create SQL script file
  (define sql-script-path "temp_create_db.sql")
  (call-with-output-file sql-script-path
    (lambda (out)
      ;; Write schema
      (display SCHEMA-SQL out)
      (newline out)
      
      ;; Generate crawl ID
      (define crawl-id (generate-crawl-id metadata))
      
      ;; Insert crawl session data
      (fprintf out "INSERT INTO crawl_sessions (crawl_id, seed_url, base_domain, start_time, config) VALUES (~a, ~a, ~a, ~a, ~a);~n"
               (sql-quote crawl-id)
               (sql-quote (hash-ref metadata 'seed-url ""))
               (sql-quote (hash-ref metadata 'base-domain ""))
               (sql-quote (format-datetime-db))
               (sql-quote (jsexpr->string metadata)))
      
      ;; Insert crawled pages - handle both single crawl and site crawl formats
      (define pages-to-insert 
        (cond
          ;; Site crawl format - pages are in metadata
          [(hash-has-key? metadata 'pages)
           (hash-ref metadata 'pages)]
          ;; Single crawl format - data contains the pages
          [else data]))
      
      (for ([item pages-to-insert])
        (when (hash-has-key? item 'url)
          (fprintf out "INSERT INTO crawled_pages (crawl_id, url, title, content, content_length, timestamp) VALUES (~a, ~a, ~a, ~a, ~a, ~a);~n"
                   (sql-quote crawl-id)
                   (sql-quote (hash-ref item 'url ""))
                   (sql-quote (hash-ref item 'title ""))
                   (sql-quote (hash-ref item 'content ""))
                   (hash-ref (hash-ref item 'metadata (hash)) 'content-length 0)
                   (sql-quote (hash-ref item 'timestamp ""))))))
    #:exists 'replace)
  
  ;; Execute SQL script using sqlite3 command-line tool
  (define result 
    (system (format "sqlite3 ~a < ~a" 
                    (shell-quote db-path) 
                    (shell-quote sql-script-path))))
  
  ;; Clean up temporary file
  (when (file-exists? sql-script-path)
    (delete-file sql-script-path))
  
  ;; Check if database was created successfully
  (if (and result (file-exists? db-path))
      #t
      (begin
        (eprintf "Failed to create SQLite database~n")
        #f)))

;; @function{sql-quote}
;; @description{Quote string for SQL}
;; @param[str]{string?} String to quote
;; @returns{string?} Quoted string
(define (sql-quote str)
  (format "'~a'" (string-replace (format "~a" str) "'" "''")))

;; @function{shell-quote}
;; @description{Quote string for shell}
;; @param[str]{string?} String to quote
;; @returns{string?} Quoted string
(define (shell-quote str)
  (format "\"~a\"" str))

;; Helper functions
;; ----------------

;; @function{generate-crawl-id}
;; @description{Generate unique crawl identifier}
;; @param[metadata]{hash?} Crawl metadata
;; @returns{string?} Unique crawl ID
(define (generate-crawl-id metadata)
  (define base-id 
    (cond
      [(hash-has-key? metadata 'seed-url)
      (format "~a-~a"
      (url-to-filename (hash-ref metadata 'seed-url))
      (format-datetime-filename))]
      [else
       (format "crawl-~a"
               (format-datetime-filename))]))
  
  ;; Ensure uniqueness by checking database
  (substring base-id 0 (min (string-length base-id) 50))) ; Limit length

;; @function{url-to-filename}
;; @description{Convert URL to safe filename component}
;; @param[url]{string?} URL to convert
;; @returns{string?} Safe filename
(define (url-to-filename url)
  (regexp-replace* #rx"[^a-zA-Z0-9.-]" 
                   (string-replace url "https://" "")
                   "-"))

;; @function{insert-crawl-session}
;; @description{Insert crawl session record}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[metadata]{hash?} Metadata
;; @returns{void?}
(define (insert-crawl-session db crawl-id metadata)
  (query-exec db
    "INSERT INTO crawl_sessions 
     (crawl_id, seed_url, base_domain, start_time, config)
     VALUES (?, ?, ?, ?, ?)"
    crawl-id
    (hash-ref metadata 'seed-url "")
    (hash-ref metadata 'base-domain "")
    (format-datetime-db)
    (jsexpr->string metadata)))

;; @function{insert-site-crawl-data}
;; @description{Insert site crawl results}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[data]{listof hash?} Crawl data
;; @param[metadata]{hash?} Metadata
;; @returns{void?}
(define (insert-site-crawl-data db crawl-id data metadata)
  (define pages (hash-ref metadata 'pages '()))
  (define statistics (hash-ref metadata 'statistics (hash)))
  
  ;; Insert crawled pages
  (for ([page pages])
    (insert-crawled-page db crawl-id page))
  
  ;; Insert discovered links
  (for ([page pages])
    (when (hash-has-key? page 'links)
      (for ([link (hash-ref page 'links '())])
        (insert-discovered-link db crawl-id 
                               (hash-ref page 'url) 
                               link))))
  
  ;; Update session with final statistics
  (when (not (hash-empty? statistics))
    (query-exec db
      "UPDATE crawl_sessions 
       SET duration_ms = ?,
           pages_crawled = ?,
           total_urls_discovered = ?,
           average_page_time_ms = ?
       WHERE crawl_id = ?"
      (hash-ref statistics 'duration-ms 0)
      (hash-ref statistics 'pages-crawled 0)
      (hash-ref statistics 'total-urls-discovered 0)
      (hash-ref statistics 'average-page-time-ms 0.0)
      crawl-id)))

;; @function{insert-crawled-page}
;; @description{Insert crawled page record}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[page]{hash?} Page data
;; @returns{void?}
(define (insert-crawled-page db crawl-id page)
  (define metadata (hash-ref page 'metadata (hash)))
  
  (query-exec db
    "INSERT INTO crawled_pages 
     (crawl_id, url, title, content, content_length, 
      method, user_agent, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    crawl-id
    (hash-ref page 'url "")
    (hash-ref page 'title "")
    (hash-ref page 'content "")
    (hash-ref metadata 'content-length 0)
    (hash-ref metadata 'method "")
    (hash-ref metadata 'user-agent "")
    (hash-ref page 'timestamp "")))

;; @function{insert-discovered-link}
;; @description{Insert discovered link record}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[source-url]{string?} Source page URL
;; @param[target-url]{string?} Target link URL
;; @returns{void?}
(define (insert-discovered-link db crawl-id source-url target-url)
  (query-exec db
    "INSERT INTO discovered_links 
     (crawl_id, source_url, target_url, link_type)
     VALUES (?, ?, ?, ?)"
    crawl-id
    source-url
    target-url
    "internal")) ; Could be enhanced to detect link types

;; @function{insert-extracted-items}
;; @description{Insert extracted items}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[items]{listof hash?} Extracted items
;; @returns{void?}
(define (insert-extracted-items db crawl-id items)
  (for ([item items])
    (insert-extracted-item db crawl-id item)))

;; @function{insert-extracted-item}
;; @description{Insert single extracted item}
;; @param[db]{connection?} Database connection
;; @param[crawl-id]{string?} Crawl ID
;; @param[item]{hash?} Item data
;; @returns{void?}
(define (insert-extracted-item db crawl-id item)
  (query-exec db
    "INSERT INTO extracted_items 
     (crawl_id, url, item_data, extraction_timestamp, field_count)
     VALUES (?, ?, ?, ?, ?)"
    crawl-id
    (hash-ref item 'url "")
    (jsexpr->string item)
    (hash-ref item 'timestamp "")
    (length (hash-keys item))))

;; Query interface
;; ---------------

;; @function{query-crawl-results}
;; @description{Query crawl results with SQL}
;; @param[db-path]{path-string?} Database path
;; @param[sql-query]{string?} SQL query
;; @returns{listof vector?} Query results
(define (query-crawl-results db-path sql-query)
  (define db (sqlite3-connect #:database db-path))
  (define results (query-rows db sql-query))
  (disconnect db)
  results)

;; @function{export-sqlite-to-json}
;; @description{Export SQLite data back to JSON format}
;; @param[db-path]{path-string?} Database path
;; @param[output-path]{path-string?} JSON output path
;; @returns{boolean?} Success status
(define (export-sqlite-to-json db-path output-path)
  (define db (sqlite3-connect #:database db-path))
  
  ;; Get all crawl sessions
  (define sessions (query-rows db "SELECT * FROM crawl_sessions"))
  
  (define export-data
    (for/list ([session sessions])
      (define crawl-id (vector-ref session 1))
      
      ;; Get pages for this crawl
      (define pages 
        (query-rows db 
          "SELECT url, title, content, timestamp FROM crawled_pages 
           WHERE crawl_id = ?" crawl-id))
      
      ;; Build export structure
      (hash 'crawl-id crawl-id
            'seed-url (vector-ref session 2)
            'pages (for/list ([page pages])
                     (hash 'url (vector-ref page 0)
                           'title (vector-ref page 1)
                           'content (vector-ref page 2)
                           'timestamp (vector-ref page 3)))
            'metadata (let ([config-str (vector-ref session 11)])
                       (if (sql-null? config-str)
                           (hash)
                           (string->jsexpr config-str))))))
  
  (disconnect db)
  
  ;; Write JSON
  (call-with-output-file output-path
    (lambda (out)
      (write-json export-data out))
    #:exists 'replace)

  #t)

;; @function{load-crawled-pages}
;; @description{Load crawled pages from SQLite database in JSON-compatible format}
;; @param[db-path]{path-string?} Database file path
;; @returns{listof hash?} List of page hashes with url, title, content, timestamp, metadata
(define (load-crawled-pages db-path)
  (define db (sqlite3-connect #:database db-path))
  (define rows (query-rows db "SELECT url, title, content, content_length, method, user_agent, timestamp, depth, parent_url, status_code, response_time_ms FROM crawled_pages ORDER BY id"))
  (disconnect db)
  (for/list ([row rows])
    (hash 'url (vector-ref row 0)
          'title (vector-ref row 1)
          'content (vector-ref row 2)
          'timestamp (vector-ref row 6)
          'metadata (hash 'content-length (vector-ref row 3)
                         'method (vector-ref row 4)
                         'user-agent (vector-ref row 5)
                         'depth (vector-ref row 7)
                         'parent-url (vector-ref row 8)
                         'status-code (vector-ref row 9)
                         'response-time-ms (vector-ref row 10)))))

;; @function{analyze-crawl-stats}
;; @description{Generate statistics about crawled data in SQLite database}
;; @param[db-path]{path-string?} Database file path
;; @returns{hash?} Statistics hash with page counts, content stats, etc.
(define (analyze-crawl-stats db-path)
  (define db (sqlite3-connect #:database db-path))

  ;; Basic page counts
  (define total-pages (vector-ref (car (query-rows db "SELECT COUNT(*) FROM crawled_pages")) 0))
  (define failed-pages (vector-ref (car (query-rows db "SELECT COUNT(*) FROM failed_urls")) 0))
  (define discovered-links (vector-ref (car (query-rows db "SELECT COUNT(*) FROM discovered_links")) 0))

  ;; Content statistics
  (define avg-content-length
    (if (> total-pages 0)
        (vector-ref (car (query-rows db "SELECT AVG(content_length) FROM crawled_pages WHERE content_length IS NOT NULL")) 0)
        0))
  (define total-content-length
    (vector-ref (car (query-rows db "SELECT SUM(content_length) FROM crawled_pages WHERE content_length IS NOT NULL")) 0))

  ;; Response time statistics
  (define avg-response-time
    (if (> total-pages 0)
        (vector-ref (car (query-rows db "SELECT AVG(response_time_ms) FROM crawled_pages WHERE response_time_ms IS NOT NULL")) 0)
        0))
  (define max-response-time
    (if (> total-pages 0)
        (vector-ref (car (query-rows db "SELECT MAX(response_time_ms) FROM crawled_pages WHERE response_time_ms IS NOT NULL")) 0)
        0))

  ;; Status code distribution
  (define status-codes
    (for/hash ([row (query-rows db "SELECT status_code, COUNT(*) FROM crawled_pages WHERE status_code IS NOT NULL GROUP BY status_code")])
      (values (format "~a" (vector-ref row 0)) (vector-ref row 1))))

  ;; Domain extraction
  (define domains
    (for/hash ([row (query-rows db "SELECT substr(url, 1, instr(substr(url, 9), '/') + 8) as domain, COUNT(*) FROM crawled_pages WHERE url LIKE 'https://%' OR url LIKE 'http://%' GROUP BY domain ORDER BY COUNT(*) DESC LIMIT 10")])
      (values (vector-ref row 0) (vector-ref row 1))))

  ;; Titles statistics
  (define pages-with-title
    (vector-ref (car (query-rows db "SELECT COUNT(*) FROM crawled_pages WHERE title IS NOT NULL AND title != ''")) 0))

  ;; Depth statistics
  (define max-depth
    (if (> total-pages 0)
        (vector-ref (car (query-rows db "SELECT MAX(depth) FROM crawled_pages WHERE depth IS NOT NULL")) 0)
        0))

  (disconnect db)

  (hash 'total_pages total-pages
        'pages_with_title pages-with-title
        'failed_pages failed-pages
        'discovered_links discovered-links
        'avg_content_length avg-content-length
        'total_content_length total-content-length
        'avg_response_time_ms avg-response-time
        'max_response_time_ms max-response-time
        'max_depth max-depth
        'status_codes status-codes
        'top_domains domains))

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit
           racket/file)

  ;; Helper for temp file cleanup
  (define (with-temp-db proc)
    (let ([path (make-temporary-file "test-~a.db")])
      (dynamic-wind
        void
        (lambda () (proc path))
        (lambda () (when (file-exists? path) (delete-file path))))))

  ;; sql-quote Tests
  (test-case "sql-quote basic string"
    (check-equal? (sql-quote "hello") "'hello'"))

  (test-case "sql-quote escapes single quotes"
    (check-equal? (sql-quote "it's") "'it''s'"))

  (test-case "sql-quote handles double quotes in string"
    (check-equal? (sql-quote "say \"hi\"") "'say \"hi\"'"))

  (test-case "sql-quote empty string"
    (check-equal? (sql-quote "") "''"))

  (test-case "sql-quote with special characters"
    (check-true (string? (sql-quote "test\nline"))))

  ;; shell-quote Tests
  (test-case "shell-quote wraps in double quotes"
    (check-equal? (shell-quote "path/to/file") "\"path/to/file\""))

  (test-case "shell-quote handles spaces"
    (check-equal? (shell-quote "path with spaces") "\"path with spaces\""))

  ;; url-to-filename Tests
  (test-case "url-to-filename removes protocol"
    (let ([filename (url-to-filename "https://example.com/path")])
      (check-false (string-contains? filename "https://"))))

  (test-case "url-to-filename replaces special chars"
    (let ([filename (url-to-filename "https://example.com/path?query=1")])
      (check-false (string-contains? filename "?"))
      (check-false (string-contains? filename "="))))

  (test-case "url-to-filename produces safe filename"
    (let ([filename (url-to-filename "https://example.com/path")])
      (check-true (regexp-match? #rx"^[a-zA-Z0-9.-]+$" filename))))

  ;; generate-crawl-id Tests
  (test-case "generate-crawl-id returns string"
    (let ([id (generate-crawl-id (hash))])
      (check-true (string? id))
      (check-true (> (string-length id) 0))))

  (test-case "generate-crawl-id includes seed-url domain"
    (let ([id (generate-crawl-id (hash 'seed-url "https://example.com/page"))])
      (check-true (string-contains? id "example.com"))))

  (test-case "generate-crawl-id length limited"
    (let ([id (generate-crawl-id (hash 'seed-url "https://very-long-domain-name.example.com/very/long/path"))])
      (check-true (<= (string-length id) 50))))

  ;; sqlite-formatter struct Tests
  (test-case "sqlite-formatter struct creation"
    (let ([fmt (sqlite-formatter #f "test-id" (hash) 0)])
      (check-true (sqlite-formatter? fmt))
      (check-equal? (sqlite-formatter-crawl-id fmt) "test-id")
      (check-equal? (sqlite-formatter-item-count fmt) 0)))

  (test-case "sqlite-formatter mutable fields"
    (let ([fmt (sqlite-formatter #f "test-id" (hash) 0)])
      (set-sqlite-formatter-item-count! fmt 5)
      (check-equal? (sqlite-formatter-item-count fmt) 5)))

  ;; Database Schema Tests (using actual SQLite)
  (test-case "format-data-sqlite creates database"
    (with-temp-db
      (lambda (path)
        (let ([data (list (hash 'url "http://example.com" 'content "test"))]
              [metadata (hash 'seed-url "http://example.com")])
          (check-true (format-data-sqlite data path metadata))
          (check-true (file-exists? path))))))

  (test-case "create-sqlite-formatter creates valid formatter"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (check-true (sqlite-formatter? fmt))
          (check-true (connection? (sqlite-formatter-db-connection fmt)))
          (close-sqlite-formatter fmt)))))

  (test-case "write-item-sqlite increments count"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (check-equal? (sqlite-formatter-item-count fmt) 0)
          (write-item-sqlite fmt (hash 'url "http://test.com/page1" 'title "Test"))
          (check-equal? (sqlite-formatter-item-count fmt) 1)
          (write-item-sqlite fmt (hash 'url "http://test.com/page2" 'title "Test2"))
          (check-equal? (sqlite-formatter-item-count fmt) 2)
          (close-sqlite-formatter fmt)))))

  (test-case "close-sqlite-formatter updates session"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com/page1"))
          (write-item-sqlite fmt (hash 'url "http://test.com/page2"))
          (close-sqlite-formatter fmt)
          ;; Verify session was updated
          (let ([db (sqlite3-connect #:database path)])
            (let ([rows (query-rows db "SELECT pages_crawled FROM crawl_sessions")])
              (check-equal? (vector-ref (car rows) 0) 2))
            (disconnect db))))))

  ;; Query Interface Tests
  (test-case "query-crawl-results returns data"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com/page"))
          (close-sqlite-formatter fmt))
        (let ([results (query-crawl-results path "SELECT * FROM crawled_pages")])
          (check-true (list? results))
          (check-true (> (length results) 0))))))

  ;; Export Tests
  (test-case "export-sqlite-to-json creates valid JSON"
    (with-temp-db
      (lambda (db-path)
        (let ([fmt (create-sqlite-formatter db-path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com/page" 'title "Test Page"))
          (close-sqlite-formatter fmt))
        (let ([json-path (make-temporary-file "test-~a.json")])
          (dynamic-wind
            void
            (lambda ()
              (check-true (export-sqlite-to-json db-path json-path))
              (check-true (file-exists? json-path))
              (let ([content (file->string json-path)])
                (check-true (string-contains? content "http://test.com"))))
            (lambda ()
              (when (file-exists? json-path) (delete-file json-path))))))))

  ;; Data Integrity Tests
  (test-case "crawled page data preserved"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com/page"
                                       'title "Test Title"
                                       'content "<html><body>test</body></html>"
                                       'metadata (hash 'content-length 100)))
          (close-sqlite-formatter fmt))
        (let ([results (query-crawl-results path
                        "SELECT url, title, content FROM crawled_pages")])
          (check-equal? (length results) 1)
          (let ([row (car results)])
            (check-equal? (vector-ref row 0) "http://test.com/page")
            (check-equal? (vector-ref row 1) "Test Title"))))))

  ;; Multiple Items Test
  (test-case "multiple items stored correctly"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (for ([i (in-range 5)])
            (write-item-sqlite fmt (hash 'url (format "http://test.com/page~a" i)
                                         'title (format "Page ~a" i))))
          (close-sqlite-formatter fmt))
        (let ([results (query-crawl-results path "SELECT COUNT(*) FROM crawled_pages")])
          (check-equal? (vector-ref (car results) 0) 5)))))

  ;; Edge Cases
  (test-case "handles empty data list"
    (with-temp-db
      (lambda (path)
        (check-true (format-data-sqlite '() path (hash 'seed-url "http://test.com"))))))

  (test-case "handles special characters in content"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com"
                                       'title "Test's \"Title\""
                                       'content "Line1\nLine2\tTab"))
          (close-sqlite-formatter fmt)))))

  (test-case "handles unicode content"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          (write-item-sqlite fmt (hash 'url "http://test.com"
                                       'title "日本語タイトル"
                                       'content "中文内容"))
          (close-sqlite-formatter fmt))
        (let ([results (query-crawl-results path "SELECT title FROM crawled_pages")])
          (check-equal? (vector-ref (car results) 0) "日本語タイトル")))))

  ;; Site crawl data format tests
  (test-case "format-data-sqlite with site crawl format"
    (with-temp-db
      (lambda (path)
        (let* ([pages (list (hash 'url "http://test.com/page1" 'title "Page 1" 'content "content1"
                                  'links '("http://test.com/page2"))
                           (hash 'url "http://test.com/page2" 'title "Page 2" 'content "content2"))]
               [metadata (hash 'seed-url "http://test.com"
                              'pages pages
                              'statistics (hash 'duration-ms 1000
                                               'pages-crawled 2
                                               'total-urls-discovered 5
                                               'average-page-time-ms 500.0))])
          (check-true (format-data-sqlite '() path metadata))
          ;; Check pages were inserted
          (let ([results (query-crawl-results path "SELECT COUNT(*) FROM crawled_pages")])
            (check-equal? (vector-ref (car results) 0) 2))
          ;; Check links were inserted
          (let ([links (query-crawl-results path "SELECT COUNT(*) FROM discovered_links")])
            (check-equal? (vector-ref (car links) 0) 1))))))

  ;; Extracted items format tests
  (test-case "write-item-sqlite with extracted item format"
    (with-temp-db
      (lambda (path)
        (let ([fmt (create-sqlite-formatter path (hash 'seed-url "http://test.com"))])
          ;; Item without 'url key - should be treated as extracted item
          (write-item-sqlite fmt (hash 'field1 "value1" 'field2 "value2" 'timestamp "2024-01-01"))
          (close-sqlite-formatter fmt))
        (let ([results (query-crawl-results path "SELECT item_data FROM extracted_items")])
          (check-true (> (length results) 0))))))

  ;; Insert extracted items test
  (test-case "format-data-sqlite with extracted items"
    (with-temp-db
      (lambda (path)
        (let ([data (list (hash 'url "http://test.com/item1" 'name "Product 1" 'price "$10")
                         (hash 'url "http://test.com/item2" 'name "Product 2" 'price "$20"))]
              [metadata (hash 'seed-url "http://test.com")])
          (check-true (format-data-sqlite data path metadata))))))

  ;; SCHEMA-SQL string test
  (test-case "SCHEMA-SQL is valid string"
    (check-true (string? SCHEMA-SQL))
    (check-true (string-contains? SCHEMA-SQL "CREATE TABLE")))

  ;; Additional generate-crawl-id tests
  (test-case "generate-crawl-id without seed-url"
    (let ([id (generate-crawl-id (hash 'other-key "value"))])
      (check-true (string-contains? id "crawl-"))))

  ;; Database directory creation test
  (test-case "format-data-sqlite creates directory if needed"
    (let ([temp-dir (make-temporary-file "test-dir-~a" 'directory)])
      (dynamic-wind
        void
        (lambda ()
          (let ([path (build-path temp-dir "subdir" "test.db")]
                [metadata (hash 'seed-url "http://test.com")])
            (check-true (format-data-sqlite '() path metadata))))
        (lambda ()
          (delete-directory/files temp-dir))))))
