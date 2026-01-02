#lang racket

#|
@title{AR-Crawl CLI Tool}
@author{Anuna Research}
@date{2025-01-10}

Command-line interface for the production web crawler with service fallbacks.
|#

(require racket/cmdline
         racket/file
         racket/pretty
         racket/system
         racket/port
         racket/hash
         json
         net/url
         "production-crawler.rkt"
         "config-manager.rkt"
         "crawl-service-adaptor.rkt"
         "scraper-interfaces.rkt"
         "site-crawler.rkt"
         "data-formatter.rkt"
         "html-extractor.rkt"
         "utils.rkt")

(module+ main)

;; Global state
(define current-crawler #f)
(define global-config #f)

;; Playwright Service Management
;; -----------------------------

(define playwright-process #f)
(define playwright-stdout #f)
(define playwright-stderr #f)
(define PLAYWRIGHT_SERVICE_PORT (or (getenv "PLAYWRIGHT_SERVICE_PORT") "3033"))

;; @function{get-playwright-service-dir}
;; @description{Get the playwright-service directory path}
(define (get-playwright-service-dir)
  ;; Check environment variable first
  (define env-dir (getenv "PLAYWRIGHT_SERVICE_DIR"))
  (cond
    [(and env-dir (directory-exists? env-dir)) env-dir]
    [else
     ;; Try relative to executable
     (define script-dir (path-only (path->complete-path (find-system-path 'run-file))))
     (define candidates
       (list
        ;; For installed binary at ~/.local/bin: check ~/.local/lib/ar-crawl/playwright-service
        (simplify-path (build-path script-dir ".." "lib" "ar-crawl" "playwright-service"))
        ;; For dist/ar-crawl-dist/bin/ar-crawl: check ../lib/playwright-service
        (simplify-path (build-path script-dir ".." "lib" "playwright-service"))
        ;; For dist/ar-crawl binary: go up twice to reach repo root
        (simplify-path (build-path script-dir ".." ".." "playwright-service"))
        ;; For racket src/cli.rkt: go up once
        (simplify-path (build-path script-dir ".." "playwright-service"))
        ;; Current working directory
        (simplify-path (build-path (current-directory) "playwright-service"))))
     (or (findf directory-exists? candidates)
         ;; Default to first candidate (will fail with helpful error)
         (car candidates))]))

;; @function{playwright-service-installed?}
;; @description{Check if playwright service dependencies are installed}
(define (playwright-service-installed?)
  (define service-dir (get-playwright-service-dir))
  (and (directory-exists? service-dir)
       (file-exists? (build-path service-dir "node_modules" ".package-lock.json"))))

;; @function{install-playwright-service}
;; @description{Install playwright service dependencies}
(define (install-playwright-service)
  (define service-dir (get-playwright-service-dir))
  (printf "Installing Playwright service dependencies...~n")
  (parameterize ([current-directory service-dir])
    (define success (system "npm install"))
    (unless success
      (error "Failed to install Playwright dependencies. Please run 'npm install' in playwright-service/ directory."))))

;; @function{playwright-service-running?}
;; @description{Check if playwright service is already running}
(define (playwright-service-running?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define health-url (format "http://localhost:~a/health" PLAYWRIGHT_SERVICE_PORT))
    (define port (get-pure-port (string->url health-url)))
    (define response (port->string port))
    (close-input-port port)
    (and response (string-contains? response "ok"))))

;; @function{start-playwright-service}
;; @description{Start the playwright service subprocess}
(define (start-playwright-service #:verbose [verbose #f])
  (cond
    ;; Already running externally
    [(playwright-service-running?)
     (when verbose
       (printf "Playwright service already running on port ~a~n" PLAYWRIGHT_SERVICE_PORT))
     #t]

    ;; Already started by us
    [playwright-process
     (when verbose
       (printf "Playwright service process already started~n"))
     #t]

    [else
     ;; Check if dependencies installed
     (unless (playwright-service-installed?)
       (install-playwright-service))

     (define service-dir (get-playwright-service-dir))
     (define server-js (build-path service-dir "server.js"))

     (unless (file-exists? server-js)
       (error "Playwright service not found. Expected at: ~a" server-js))

     (when verbose
       (printf "Starting Playwright service on port ~a...~n" PLAYWRIGHT_SERVICE_PORT))

     ;; Start the node process
     (define-values (proc stdout stdin stderr)
       (subprocess #f #f #f
                   (find-executable-path "node")
                   (path->string server-js)))

     (set! playwright-process proc)
     (set! playwright-stdout stdout)
     (set! playwright-stderr stderr)
     (close-output-port stdin)

     ;; Wait for service to be ready (up to 10 seconds)
     (define (wait-for-ready attempts)
       (cond
         [(= attempts 0)
          (stop-playwright-service)
          (error "Playwright service failed to start within timeout")]
         [(playwright-service-running?)
          (when verbose
            (printf "Playwright service ready~n"))
          #t]
         [else
          (sleep 0.5)
          (wait-for-ready (sub1 attempts))]))

     (wait-for-ready 20)]))

;; @function{stop-playwright-service}
;; @description{Stop the playwright service subprocess}
(define (stop-playwright-service)
  (when playwright-process
    (subprocess-kill playwright-process #t)
    (when playwright-stdout (close-input-port playwright-stdout))
    (when playwright-stderr (close-input-port playwright-stderr))
    (set! playwright-process #f)
    (set! playwright-stdout #f)
    (set! playwright-stderr #f)))

;; @function{ensure-playwright-if-needed}
;; @description{Start playwright service if it's in the services list}
(define (ensure-playwright-if-needed services #:verbose [verbose #f])
  (when (member 'playwright services)
    (start-playwright-service #:verbose verbose)))

;; @function{with-playwright-cleanup}
;; @description{Run a thunk and ensure playwright is cleaned up}
(define-syntax-rule (with-playwright-cleanup body ...)
  (dynamic-wind
    void
    (lambda () body ...)
    stop-playwright-service))

;; CLI Commands
;; ------------

;; @function{detect-format-from-extension}
;; @description{Detect output format from file extension}
(define (detect-format-from-extension file)
  (define ext (filename-extension file))
  (cond
    [(not ext) #f]
    [(bytes=? ext #"json") 'json]
    [(bytes=? ext #"csv") 'csv]
    [(bytes=? ext #"md") 'markdown]
    [(bytes=? ext #"markdown") 'markdown]
    [(bytes=? ext #"db") 'sqlite]
    [(bytes=? ext #"sqlite") 'sqlite]
    [else #f]))

;; @function{cmd-crawl}
;; @description{Crawl a single URL}
(define (cmd-crawl url
                  #:config [config-file #f]
                  #:output [output-file #f]
                  #:format [format 'json]
                  #:services [services '()]
                  #:verbose [verbose #f]
                  #:wait [wait #f]
                  #:xpath [xpath #f]
                  #:scroll [scroll #f]
                  #:scroll-count [scroll-count 0]
                  #:scroll-delay [scroll-delay 1000]
                  #:click-selector [click-selector #f]
                  #:click-count [click-count 1]
                  #:pw-delay [delay 5000])

  (setup-crawler config-file verbose)

  ;; Override services if specified
  (when (not (empty? services))
    (set! global-config
          (hash-set global-config 'crawler
                   (hash-set (hash-ref global-config 'crawler)
                            'services services))))

  ;; Merge playwright options into service config
  (define pw-config
    (hash 'delay delay
          'scroll scroll
          'scroll-count scroll-count
          'scroll-delay scroll-delay
          'click-selector click-selector
          'click-count click-count))

  ;; Update services config with playwright options
  (define current-services (hash-ref global-config 'services (hash)))
  (define updated-pw-config
    (hash-union (hash-ref current-services 'playwright (hash)) pw-config))
  (set! global-config
        (hash-set global-config 'services
                 (hash-set current-services 'playwright updated-pw-config)))

  ;; Start playwright service if needed
  (define config-services (get-config-value global-config '(crawler services) '("direct")))
  (define effective-services
    (map (lambda (s) (if (symbol? s) s (string->symbol s))) config-services))
  (ensure-playwright-if-needed effective-services #:verbose verbose)

  (define crawler (create-crawler-from-config))

  ;; Resolve format
  (define effective-format
    (or format
        (and output-file (detect-format-from-extension output-file))
        'json))

  (if verbose
      (begin
        (printf "Crawling URL: ~a~n" url)
        (printf "Using services: ~a~n"
               (get-config-value global-config '(crawler services))))
      (eprintf "Crawling URL: ~a...~n" url))

  (define job-id (start-crawling crawler url))
  
  ;; Wait for completion
  (let loop ()
    (define status (get-crawler-status crawler))
    (when (> (crawler-status-active-jobs status) 0)
      (when verbose
        (printf "Jobs active: ~a~n" (crawler-status-active-jobs status)))
      (sleep 1)
      (loop)))
  
  ;; Get results
  (define results (get-job-results crawler job-id))
  
  (if results
      (let* ([filtered-results
              (if xpath
                  (apply-xpath-filter-to-job-results results xpath)
                  results)])
        (if verbose
            (printf "Crawl completed successfully~n")
            (eprintf "Done.~n"))
        (output-results filtered-results output-file effective-format verbose))
      (eprintf "Crawl failed~n")))

;; @function{cmd-crawl-site}
;; @description{Crawl an entire site with link following}
(define (cmd-crawl-site url
                       #:config [config-file #f]
                       #:output [output-file #f]
                       #:format [format 'json]
                       #:services [services '()]
                       #:verbose [verbose #f]
                       #:max-pages [max-pages 50]
                       #:max-depth [max-depth 3]
                       #:url-pattern [url-pattern ".*"]
                       #:same-domain [same-domain #t]
                       #:crawl-delay [crawl-delay 1000]
                       #:xpath [xpath #f])

  (setup-crawler config-file verbose)

  ;; Override services if specified
  (when (not (empty? services))
    (set! global-config
          (hash-set global-config 'crawler
                   (hash-set (hash-ref global-config 'crawler)
                            'services services))))

  ;; Start playwright service if needed
  (define config-services (get-config-value global-config '(crawler services) '("direct")))
  (define effective-services
    (map (lambda (s) (if (symbol? s) s (string->symbol s))) config-services))
  (ensure-playwright-if-needed effective-services #:verbose verbose)

  (define crawler (create-crawler-from-config))

  ;; Resolve format
  (define effective-format
    (or format
        (and output-file (detect-format-from-extension output-file))
        'json))

  ;; Create site crawl configuration
  (define site-config 
    (make-site-crawl-config
     #:max-pages max-pages
     #:max-depth max-depth
     #:url-pattern url-pattern
     #:same-domain-only same-domain
     #:crawl-delay-ms crawl-delay))
  
  (when verbose
    (printf "Starting site crawl from: ~a~n" url)
    (printf "Max pages: ~a~n" max-pages)
    (printf "Max depth: ~a~n" max-depth)
    (printf "URL pattern: ~a~n" url-pattern)
    (printf "Same domain only: ~a~n" same-domain)
    (printf "Crawl delay: ~a ms~n" crawl-delay))
  
  ;; Progress callback for verbose/non-verbose mode
  (define progress-callback
    (if verbose
        (lambda (message current total)
          (printf "[~a/~a] ~a~n" current total message))
        (lambda (message current total)
          ;; Simple progress updates for non-verbose mode
          (when (or (= current 1)
                    (= current total)
                    (zero? (modulo current 10)))
             (eprintf "Crawled ~a pages...~n" current)))))

  ;; Perform site crawl
  (define result (crawl-site url crawler site-config
                            #:progress-callback progress-callback))
  
  ;; Output results
  (define successful-pages (site-crawl-result-pages result))
  (define failed-urls (site-crawl-result-failed-urls result))
  
  ;; Apply XPath filter if specified
  (define filtered-pages
    (if xpath
        (map (lambda (page) (apply-xpath-to-response page xpath))
             successful-pages)
        successful-pages))
  

  
  (if (empty? filtered-pages)
      (eprintf "Site crawl failed - no pages crawled successfully~n")
      (begin
        (when verbose
          (printf "Site crawl completed successfully~n")
          (print-crawl-statistics result))
        
        ;; Save results if output file specified
        (when output-file
          (define site-results
            (hash 'pages filtered-pages
                  'failed-urls failed-urls
                  'statistics (site-crawl-result-statistics result)
                  'metadata (hash 'seed-url (hash-ref (site-crawl-result-metadata result) 'seed-url)
                                 'base-domain (hash-ref (site-crawl-result-metadata result) 'base-domain))
                  'timestamp (generate-timestamp)))
          
          (output-site-results site-results output-file effective-format verbose)))))

;; @function{cmd-extract}
;; @description{Extract structured data from crawl results using XPath}
(define (cmd-extract input-file
                     #:xpath [xpath-map-str #f]
                     #:parent [parent-xpath #f]
                     #:fields [field-xpaths-str #f]
                     #:output [output-file #f]
                     #:format [format 'json]
                     #:verbose [verbose #f])

  ;; Parse xpath-map from JSON string or build from parent/fields
  (define xpath-map
    (cond
      [xpath-map-str
       ;; Parse JSON object: {"name": "//h1", "price": "//span[@class='price']"}
       (with-handlers ([exn:fail? (lambda (e)
                                    (printf "Error parsing XPath map: ~a~n" (exn-message e))
                                    (exit 1))])
         (let ([parsed (string->jsexpr xpath-map-str)])
           (for/hash ([(k v) (in-hash parsed)])
             (values (if (string? k) (string->symbol k) k) v))))]

      [(and parent-xpath field-xpaths-str)
       ;; Build from parent + fields for item extraction
       (hash 'parent parent-xpath
             'fields (with-handlers ([exn:fail? (lambda (e) (hash))])
                      (string->jsexpr field-xpaths-str)))]

      [field-xpaths-str
       ;; --fields alone works as shorthand for --xpath-map (simple extraction)
       ;; This is convenient for LLM agents who don't need item extraction
       (with-handlers ([exn:fail? (lambda (e)
                                    (printf "Error parsing fields JSON: ~a~n" (exn-message e))
                                    (exit 1))])
         (let ([parsed (string->jsexpr field-xpaths-str)])
           (for/hash ([(k v) (in-hash parsed)])
             (values (if (string? k) (string->symbol k) k) v))))]

      [else
       (printf "Error: Must provide --fields, --xpath-map, or both --parent and --fields~n")
       (printf "~nUsage:~n")
       (printf "  ar-crawl extract <file> --fields '{\"title\": \"//h1\", \"body\": \"//p\"}'~n")
       (printf "  ar-crawl extract <file> --xpath-map '{\"name\": \"//h1\", \"price\": \"//span\"}'~n")
       (printf "  ar-crawl extract <file> --parent \"//div[@class='product']\" --fields '{\"name\": \".//h2\", \"price\": \".//span\"}'~n")
       (exit 1)]))

  (when verbose
    (printf "Extracting from: ~a~n" input-file)
    (printf "XPath map: ~a~n" xpath-map))

  ;; Resolve format
  (define effective-format
    (or format
        (and output-file (detect-format-from-extension output-file))
        'json))

  ;; Load input file - detect SQLite by extension
  (define items
    (with-handlers ([exn:fail? (lambda (e)
                                 (printf "Error loading file: ~a~n" (exn-message e))
                                 (exit 1))])
      (let ([input-str (if (path? input-file) (path->string input-file) input-file)])
        (if (string-suffix? input-str ".db")
            ;; Load from SQLite database
            (load-crawled-pages input-file)
            ;; Load from JSON file
            (let ([input-data
                   (call-with-input-file input-file
                     (lambda (port)
                       (string->jsexpr (port->string port))))])
              (or (hash-ref input-data 'data #f)
                  (hash-ref input-data 'pages #f)
                  '()))))))

  (when verbose
    (printf "Found ~a items to process~n" (length items)))

  ;; Extract from each item
  (define results
    (cond
      ;; Item extraction with parent + fields
      [(hash-ref xpath-map 'parent #f)
       (define parent (hash-ref xpath-map 'parent))
       (define fields (hash-ref xpath-map 'fields (hash)))
       (for/fold ([all-items '()])
                 ([item items]
                  #:when (hash? item))
         (define content (hash-ref item 'content ""))
         (define url (hash-ref item 'url ""))
         (define extracted (extract-items content parent fields))
         (append all-items
                 (for/list ([e extracted])
                   (hash-set e 'source_url url))))]

      ;; Simple field extraction
      [else
       (for/list ([item items]
                  #:when (hash? item))
         (define content (hash-ref item 'content ""))
         (define url (hash-ref item 'url ""))
         (define title (hash-ref item 'title ""))
         (define extracted (extract-by-xpaths content xpath-map))
         (hash-set (hash-set extracted 'source_url url)
                   'source_title title))]))

  (when verbose
    (printf "Extracted ~a records~n" (length results)))

  ;; Output results
  (define output-data
    (hash 'data results
          'metadata (hash 'source input-file
                         'xpath_map xpath-map
                         'record_count (length results))
          'timestamp (generate-timestamp)))

  (if output-file
      (begin
        (ensure-directory (or (path-only output-file) (current-directory)))
        (case effective-format
          [(json)
           (call-with-output-file output-file
             (lambda (port)
               (write-json output-data port #:indent 2))
             #:exists 'replace)]
          [(csv)
           (call-with-output-file output-file
             (lambda (port)
               (extracted-results->csv results port))
             #:exists 'replace)]
          [(sqlite)
           (format-data-with-metadata results 'sqlite output-file output-data)]
          [else
           (call-with-output-file output-file
             (lambda (port)
               (write-json output-data port #:indent 2))
             #:exists 'replace)])
        (when verbose
          (printf "Results saved to: ~a~n" output-file)))
      ;; Output to stdout
      (write-json output-data (current-output-port) #:indent 2)))

;; @function{cmd-sample}
;; @description{Show sample HTML from crawl results to help figure out XPaths}
(define (cmd-sample input-file
                   #:index [index 0]
                   #:length [max-length 5000])

  ;; Load input file - detect SQLite by extension
  (define items
    (with-handlers ([exn:fail? (lambda (e)
                                 (printf "Error loading file: ~a~n" (exn-message e))
                                 (exit 1))])
      (let ([input-str (if (path? input-file) (path->string input-file) input-file)])
        (if (string-suffix? input-str ".db")
            ;; Load from SQLite database
            (load-crawled-pages input-file)
            ;; Load from JSON file
            (let ([input-data
                   (call-with-input-file input-file
                     (lambda (port)
                       (string->jsexpr (port->string port))))])
              (hash-ref input-data 'data '()))))))

  (when (empty? items)
    (printf "No items found in ~a~n" input-file)
    (exit 1))

  (when (>= index (length items))
    (printf "Index ~a out of range. File has ~a items (0-~a)~n"
            index (length items) (- (length items) 1))
    (exit 1))

  (define item (list-ref items index))
  (define url (hash-ref item 'url ""))
  (define title (hash-ref item 'title ""))
  (define content (hash-ref item 'content ""))

  (printf "~n=== Sample HTML from Crawl Results ===~n")
  (printf "File: ~a~n" input-file)
  (printf "Index: ~a of ~a~n" index (length items))
  (printf "URL: ~a~n" url)
  (printf "Title: ~a~n" title)
  (printf "Content length: ~a characters~n" (string-length content))
  (printf "~n--- HTML Content (first ~a chars) ---~n~n" max-length)

  ;; Pretty print the HTML with some basic formatting
  (define truncated
    (if (> (string-length content) max-length)
        (string-append (substring content 0 max-length) "\n\n... [truncated]")
        content))

  (displayln truncated)

  (printf "~n--- XPath Tips ---~n")
  (printf "Common patterns to look for in the HTML:~n")
  (printf "  - class=\"...\"  -> //tag[@class='value'] or //tag[contains(@class,'partial')]~n")
  (printf "  - data-testid  -> //tag[@data-testid='value']~n")
  (printf "  - id=\"...\"    -> //tag[@id='value']~n")
  (printf "~nUse with: ar-crawl extract ~a --xpath-map '{\"field\": \"//xpath\"}'~n" input-file))

;; @function{cmd-stats}
;; @description{Show statistics about a crawl database (SQLite format)}
(define (cmd-stats db-file
                   #:verbose [verbose #f])

  ;; Load and analyze stats
  (define stats
    (with-handlers ([exn:fail? (lambda (e)
                                 (printf "Error loading database: ~a~n" (exn-message e))
                                 (exit 1))])
      (analyze-crawl-stats db-file)))

  (printf "~n=== Crawl Statistics ===~n")
  (printf "Database: ~a~n~n" db-file)

  (printf "--- Page Counts ---~n")
  (printf "  Total pages crawled:     ~a~n" (hash-ref stats 'total_pages))
  (printf "  Pages with titles:       ~a~n" (hash-ref stats 'pages_with_title))
  (printf "  Failed URLs:             ~a~n" (hash-ref stats 'failed_pages))
  (printf "  Discovered links:        ~a~n" (hash-ref stats 'discovered_links))
  (printf "  Max crawl depth:         ~a~n~n" (hash-ref stats 'max_depth))

  (printf "--- Content Statistics ---~n")
  (printf "  Total content length:    ~a characters~n" (hash-ref stats 'total_content_length))
  (printf "  Avg content length:      ~a characters~n~n" (hash-ref stats 'avg_content_length))

  (printf "--- Performance Statistics ---~n")
  (printf "  Avg response time:       ~a ms~n" (hash-ref stats 'avg_response_time_ms))
  (printf "  Max response time:       ~a ms~n~n" (hash-ref stats 'max_response_time_ms))

  (define status-codes (hash-ref stats 'status_codes))
  (when (not (hash-empty? status-codes))
    (printf "--- Status Codes ---~n")
    (for ([(code count) (in-hash status-codes)])
      (printf "  ~a:                     ~a~n" code count))
    (newline))

  (define top-domains (hash-ref stats 'top_domains))
  (when (not (hash-empty? top-domains))
    (printf "--- Top Domains ---~n")
    (for ([(domain count) (in-hash top-domains)])
      (printf "  ~a:                    ~a~n" domain count))
    (newline))

  (printf "Note: Use 'ar-crawl sample ~a' to view sample HTML content.~n" db-file)
  (printf "      Use 'ar-crawl extract ~a --fields \"{...}\"' to extract data.~n~n" db-file))

;; @function{cmd-probe}
;; @description{Probe a URL to measure page load performance and suggest scraping parameters}
(define (cmd-probe url
                   #:verbose [verbose #f]
                   #:output [output-file #f])

  ;; Start playwright service (probe requires it)
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Probing URL: ~a~n" url)
    (printf "Measuring page load timing metrics...~n"))

  ;; Call the playwright probe endpoint
  (define probe-url (format "http://localhost:~a/probe" PLAYWRIGHT_SERVICE_PORT))

  (define response
    (with-handlers ([exn:fail? (lambda (e)
                                  (printf "Probe failed: ~a~n" (exn-message e))
                                  #f)])
      (define req-data (jsexpr->string (hash 'url url)))
      (define port (post-pure-port
                    (string->url probe-url)
                    (string->bytes/utf-8 req-data)
                    (list "Content-Type: application/json")))
      (define raw-response (port->string port))
      (close-input-port port)
      (string->jsexpr raw-response)))

  (when (not response)
    (printf "Failed to probe URL. Is the playwright service running?~n")
    (exit 1))

  ;; Extract key metrics (Racket json library uses symbols for keys)
  (define timing (hash-ref response 'timing (hash)))
  (define resources (hash-ref response 'resources (hash)))
  (define recommendations (hash-ref response 'recommendations (hash)))
  (define probe-time (hash-ref response 'probeTime 0))

  ;; Compute additional metrics (do this once before output formatting)
  (define perf (hash-ref timing 'performance (hash)))
  (define total-bytes (hash-ref resources 'totalTransferSize 0))
  (define by-type (hash-ref resources 'byType (hash)))
  (define network-requests (hash-ref response 'networkRequests (hash)))
  (define network-by-type (hash-ref network-requests 'byType (hash)))
  (define js-time (hash-ref timing 'jsExecutionEstimate 0))
  (define xhr-count (hash-ref network-by-type 'xmlhttprequest 0))
  (define fetch-count (hash-ref network-by-type 'fetch 0))
  (define script-stats (hash-ref by-type 'script (hash)))
  (define script-requests (if (hash? script-stats) (hash-ref script-stats 'count 0) 0))
  (define network-idle-delay (- (hash-ref timing 'networkIdleTime 0)
                                (hash-ref timing 'loadComplete 0)))

  ;; Dynamic content score (0-100)
  (define dynamic-score
    (min 100
         (+ (if (> js-time 500) 30 (if (> js-time 100) 15 0))
            (if (> (+ xhr-count fetch-count) 0) 30 0)
            (if (> script-requests 20) 25 (if (> script-requests 5) 10 0))
            (if (> network-idle-delay 1000) 15 (if (> network-idle-delay 500) 5 0)))))

  ;; Display results
  (printf "~n=== Page Load Metrics ===~n~n")

  (printf "Timing:~n")
  (printf "  DOM Content Loaded: ~a ms~n" (hash-ref timing 'domContentLoaded 0))
  (printf "  Page Load Complete: ~a ms~n" (hash-ref timing 'loadComplete 0))
  (printf "  Network Idle:       ~a ms~n" (hash-ref timing 'networkIdleTime 0))
  (printf "  JS Execution (est): ~a ms~n" (hash-ref timing 'jsExecutionEstimate 0))

  (when verbose
    (printf "~n  Performance API Details:~n")
    (printf "    TTFB:             ~a ms~n" (hash-ref perf 'ttfb 0))
    (printf "    DOM Parsing:      ~a ms~n" (hash-ref perf 'domParsing 0))
    (printf "    DOM Interactive:  ~a ms~n" (hash-ref perf 'domInteractive 0))
    (printf "    DOM Complete:     ~a ms~n" (hash-ref perf 'domComplete 0)))

  (printf "~nResources:~n")
  (printf "  Total Requests:     ~a~n" (hash-ref resources 'totalRequests 0))
  (printf "  Total Transfer:     ~a KB~n" (quotient total-bytes 1024))

  (when verbose
    (printf "~n  By Resource Type:~n")
    (for ([(type stats) (in-hash by-type)])
      (printf "    ~a: ~a requests, ~a KB~n"
              type
              (hash-ref stats 'count 0)
              (quotient (hash-ref stats 'totalSize 0) 1024))))

  ;; Content Analysis
  (printf "~n=== Content Analysis ===~n~n")
  (cond
    [(< dynamic-score 20)
     (printf "  Content Type: Static~n")
     (printf "  The page has minimal JavaScript. Direct HTTP should work fine.~n")
     (printf "  Recommendation: Use -s direct for faster crawling~n")]
    [(< dynamic-score 50)
     (printf "  Content Type: Light JavaScript~n")
     (printf "  The page has some JavaScript but may work with direct HTTP.~n")
     (printf "  Recommendation: Try -s direct first, use -s playwright if content missing~n")]
    [else
     (printf "  Content Type: Dynamic/SPA~n")
     (printf "  The page relies heavily on JavaScript for content.~n")
     (printf "  Recommendation: Use -s playwright for full content~n")])

  (when verbose
    (printf "~n  Dynamic Score: ~a/100~n" dynamic-score)
    (printf "  Factors: JS=~ams, XHR/Fetch=~a, Scripts=~a, NetworkDelay=~ams~n"
            js-time (+ xhr-count fetch-count) script-requests network-idle-delay))

  (printf "~n=== Recommended Scraping Parameters ===~n~n")
  (printf "  --pw-delay ~a        # Wait for JS to complete~n"
          (hash-ref recommendations 'pwDelay 5000))
  (printf "  --pw-scroll-delay ~a  # Delay between scrolls~n"
          (hash-ref recommendations 'scrollDelay 1000))
  (printf "  --timeout ~a      # Request timeout~n"
          (hash-ref recommendations 'timeout 30000))

  (printf "~nProbe completed in ~a ms~n" probe-time)

  ;; Output to file if requested
  (when output-file
    (define output-data
      (hash 'url url
            'timing timing
            'resources resources
            'recommendations recommendations
            'probeTime probe-time
            'timestamp (generate-timestamp)))
    (call-with-output-file output-file
      (lambda (port)
        (write-json output-data port #:indent 2))
      #:exists 'replace)
    (printf "Results saved to: ~a~n" output-file)))

;; @function{extracted-results->csv}
;; @description{Convert extracted results to CSV format}
(define (extracted-results->csv results port)
  (when (not (empty? results))
    ;; Get all unique keys
    (define all-keys
      (remove-duplicates
       (apply append (map hash-keys results))))

    ;; Write header
    (displayln (string-join (map symbol->string all-keys) ",") port)

    ;; Write rows
    (for ([result results])
      (define row
        (for/list ([key all-keys])
          (define val (hash-ref result key ""))
          (define str-val
            (cond
              [(string? val) val]
              [(list? val) (string-join val "; ")]
              [(not val) ""]
              [else (format "~a" val)]))
          ;; CSV escape
          (if (or (string-contains? str-val ",")
                  (string-contains? str-val "\"")
                  (string-contains? str-val "\n"))
              (format "\"~a\"" (string-replace str-val "\"" "\"\""))
              str-val)))
      (displayln (string-join row ",") port))))

;; @function{output-site-results}
;; @description{Output site crawl results to file}
(define (output-site-results results output-file format verbose)
  (define dir (path-only output-file))
  (when dir (ensure-directory dir))
  
  (case format
    [(sqlite)
     ;; Use SQLite formatter for database output
     (format-data-with-metadata 
      (list results) ; Wrap single result in list
      'sqlite 
      output-file 
      results)]
    [else
     ;; Handle other formats as before
     (define content 
       (case format
         [(json) (jsexpr->string results #:encode 'control)]
         [(csv) (results->csv results)]
         [(markdown) (results->markdown results)]
         [else (jsexpr->string results #:encode 'control)]))
     
     (call-with-output-file output-file
       (lambda (port)
         (display content port))
       #:exists 'replace)])
  
  (when verbose
    (printf "Results saved to: ~a~n" output-file)))

;; @function{cmd-health}
;; @description{Check service health}
(define (cmd-health #:config [config-file #f]
                   #:verbose [verbose #f])
  
  (setup-crawler config-file verbose)
  
  (define crawler (create-crawler-from-config))
  
  (printf "Checking service health...~n")
  (define health (health-check crawler))
  
  (printf "Overall Status: ~a~n" (health-status-status health))
  (printf "Uptime: ~a seconds~n" (health-status-uptime health))
  
  (printf "~nService Health:~n")
  (for ([(service healthy?) (in-hash (health-status-services health))])
    (printf "  ~a: ~a~n" service (if healthy? "✓ Healthy" "✗ Unhealthy")))
  
  (when verbose
    (printf "~nDetailed Health Status:~n")
    (pretty-print (health-status->hash health))))

;; @function{cmd-test}
;; @description{Test individual services}
(define (cmd-test #:service [service #f]
                 #:config [config-file #f]
                 #:url [test-url "https://httpbin.org/html"]
                 #:verbose [verbose #f])
  
  (setup-crawler config-file verbose)
  
  (define services-to-test 
    (if service 
        (list service)
        (get-available-services)))
  
  (printf "Testing services with URL: ~a~n~n" test-url)
  
  (for ([svc services-to-test])
    (printf "Testing ~a... " svc)
    (flush-output)
    
    (define start-time (current-milliseconds))
    (define result (call-service svc test-url 
                                (hash-ref global-config 'services (hash))))
    (define end-time (current-milliseconds))
    (define response-time (- end-time start-time))
    
    (if result
        (printf "✓ Success (~a ms)~n" response-time)
        (printf "✗ Failed~n"))
    
    (when (and verbose result)
      (printf "  Content length: ~a chars~n" 
             (string-length (extract-content result)))
      (printf "  Links found: ~a~n" 
             (length (extract-links result))))))

;; @function{cmd-config}
;; @description{Manage configuration}
(define (cmd-config command
                   #:file [config-file "config/default.json"]
                   #:type [config-type 'default])
  
  (case command
    [(init create)
     (printf "Creating configuration file: ~a~n" config-file)
     (ensure-directory (path-only config-file))
     (create-default-config-file config-file config-type)
     (printf "Configuration created. Edit the file to add your API keys.~n")]
    
    [(show view)
     (if (file-exists? config-file)
     (let ([config (load-config config-file)])
     (printf "Configuration from: ~a~n~n" config-file)
     (pretty-print config))
     (printf "Configuration file not found: ~a~n" config-file))]
    
    [(validate check)
    (if (file-exists? config-file)
    (begin
    (printf "Validating configuration: ~a~n" config-file)
    (with-handlers ([exn:fail? 
    (lambda (e) 
    (printf "✗ Invalid: ~a~n" (exn-message e)))])
    (let ([config (load-config config-file)])
      (if (validate-config config)
      (printf "✓ Valid configuration~n")
      (printf "✗ Invalid configuration structure~n")))))
    (printf "Configuration file not found: ~a~n" config-file))]
    
    [else
     (printf "Unknown config command: ~a~n" command)
     (printf "Available commands: init, show, validate~n")]))

;; @function{cmd-services}
;; @description{List available services}
(define (cmd-services #:verbose [verbose #f])
  (printf "Available Crawling Services:~n~n")
  
  (define services (get-available-services))
  
  (for ([service services])
    (printf "• ~a~n" service)
    (when verbose
      (define healthy (test-service-health service))
      (printf "  Status: ~a~n" (if healthy "✓ Available" "✗ Unavailable"))))
  
  (printf "~nTotal services: ~a~n" (length services)))

;; @function{cmd-monitor}
;; @description{Real-time monitoring dashboard}
(define (cmd-monitor #:config [config-file #f]
                    #:interval [interval 5])
  
  (setup-crawler config-file #f)
  
  (define crawler (create-crawler-from-config))
  
  (printf "Starting monitoring dashboard (Ctrl+C to exit)~n")
  (printf "Refresh interval: ~a seconds~n~n" interval)
  
  (let loop ()
    (system "clear")  ; Clear screen (Unix/Linux/Mac)
    
    (printf "=== AR-Crawl Monitoring Dashboard ===~n~n")
    
    (define status (get-crawler-status crawler))
    (define metrics (get-crawler-metrics crawler))
    (define health (health-check crawler))
    
    (printf "Status: ~a~n" (health-status-status health))
    (printf "Active Jobs: ~a~n" (crawler-status-active-jobs status))
    (printf "Total Jobs: ~a~n" (crawler-status-total-jobs status))
    (printf "Success Rate: ~a%~n" 
           (* 100 (crawler-status-success-rate status)))
    (printf "Avg Response Time: ~a ms~n" 
           (crawler-status-average-response-time status))
    
    (printf "~nService Health:~n")
    (for ([(service healthy?) (in-hash (health-status-services health))])
      (printf "  ~a: ~a~n" service (if healthy? "✓" "✗")))
    
    (printf "~nLast updated: ~a~n" (current-milliseconds))
    
    (sleep interval)
    (loop)))

;; Helper Functions
;; ----------------

;; @function{setup-crawler}
;; @description{Setup crawler with configuration}
(define (setup-crawler config-file verbose)
  (when verbose
    (printf "Setting up crawler...~n"))
  
  ;; Load configuration
  (set! global-config
        (cond
          [config-file
           (if (file-exists? config-file)
               (load-config config-file)
               (begin
                 (printf "Config file not found: ~a, using defaults~n" config-file)
                 (default-config)))]
          [(file-exists? "config/default.json")
           (load-config "config/default.json")]
          [(file-exists? "config/production.json")
           (load-config "config/production.json")]
          [else
           (when verbose
             (printf "No config file found, using defaults~n"))
           (default-config)]))
  
  (when verbose
    (printf "Configuration loaded~n")))


;; @function{create-crawler-from-config}
;; @description{Create crawler from global config}
(define (create-crawler-from-config)
  (define config-services (get-config-value global-config '(crawler services) '("direct")))
  (create-production-crawler
   (make-production-crawler-config
    #:services (map (lambda (s) (if (symbol? s) s (string->symbol s))) config-services)
    #:fallback-enabled (get-config-value global-config '(crawler fallback_enabled) #t)
    #:max-concurrent-jobs (get-config-value global-config '(crawler max_concurrent_jobs) 10)
    #:rate-limit-ms (get-config-value global-config '(crawler rate_limit_ms) 1000)
    #:retry-attempts (get-config-value global-config '(crawler retry_attempts) 3)
    #:timeout-ms (get-config-value global-config '(crawler timeout_ms) 30000)
    #:enable-monitoring (get-config-value global-config '(crawler enable_monitoring) #t)
    #:log-level (string->symbol (get-config-value global-config '(crawler log_level) "info"))
    #:output-format (string->symbol (get-config-value global-config '(crawler output_format) "json"))
    #:service-configs (get-config-value global-config '(services) (hash)))))

;; @function{output-results}
;; @description{Output crawl results}
(define (output-results results output-file format verbose)

  (if output-file
      (begin
        (case format
          [(sqlite)
           ;; Use SQLite formatter for database output
           (format-data-with-metadata 
            (job-results-data results) ; Extract data list
            'sqlite 
            output-file 
            (job-results->hash results))] ; Use full results as metadata
          [else
           ;; Handle other formats as before
           (define content 
             (case format
               [(json) (jsexpr->string (job-results->hash results) #:indent 2)]
               [(csv) (results->csv results)]
               [(markdown md) (results->markdown results)]
               [else (jsexpr->string (job-results->hash results))]))
           
           (call-with-output-file output-file
             (lambda (port) (display content port))
             #:exists 'replace)])
        (when verbose
          (printf "Results saved to: ~a~n" output-file)))
      ;; Console output (only for non-SQLite formats)
      (when (not (eq? format 'sqlite))
        (define content 
          (case format
            [(json) (jsexpr->string (job-results->hash results) #:indent 2)]
            [(csv) (results->csv results)]
            [(markdown md) (results->markdown results)]
            [else (jsexpr->string (job-results->hash results))]))
        (display content)))
  
  (when verbose
    (printf "~nResult statistics:~n")
    (printf "Items extracted: ~a~n" (length (job-results-data results)))
    (printf "Errors: ~a~n" (length (job-results-errors results)))))

;; @function{job-results->hash}
;; @description{Convert job results to hash for JSON output}
(define (job-results->hash results)
  (hash 'data (job-results-data results)
        'metadata (job-results-metadata results)
        'errors (job-results-errors results)
        'timestamp (generate-timestamp)))

;; @function{health-status->hash}
;; @description{Convert health status to hash}
(define (health-status->hash health)
  (hash 'status (health-status-status health)
        'services (health-status-services health)
        'uptime (health-status-uptime health)
        'last_check (health-status-last-check health)))

;; @function{results->csv}
;; @description{Convert results to CSV format}
(define (results->csv results)
  "url,timestamp,content_length\n")  ; Simplified CSV for demo

;; @function{results->markdown}
;; @description{Convert results to Markdown format}
(define (results->markdown results)
  (string-append 
   "# Crawl Results\n\n"
   (format "Generated: ~a\n\n" (generate-timestamp))
   "## Data\n\n"
   (if (empty? (job-results-data results))
       "No data extracted.\n"
       "Data extracted successfully.\n")))

;; @function{apply-xpath-filter-to-job-results}
;; @description{Apply XPath filter to job results}
(define (apply-xpath-filter-to-job-results results xpath)
  (define filtered-data
    (map (lambda (item)
           (apply-xpath-to-response item xpath))
         (job-results-data results)))
  
  (job-results filtered-data
               (job-results-metadata results)
               (job-results-errors results)))

;; Main CLI Parser
;; ---------------

;; @function{find-command-index}
;; @description{Find the index of the first non-flag argument (the command)}
(define (find-command-index args)
  (for/first ([i (in-naturals)]
              [arg args]
              #:when (and (not (string-prefix? arg "-"))
                          (not (string-prefix? arg "/"))))
    i))

;; @function{split-args-at-command}
;; @description{Split argument list at the command position}
(define (split-args-at-command args)
  (define cmd-index (find-command-index args))
  (if cmd-index
      (values (take args cmd-index)
              (list-ref args cmd-index)
              (drop args (add1 cmd-index)))
      (values args #f '())))

;; @function{parse-extract-args}
;; @description{Parse extract command arguments after the file}
(define (parse-extract-args args)
  (command-line
   #:program "ar-crawl extract"
   #:argv args
   #:once-each
   [("--xpath-map") xpath-json "JSON object mapping field names to XPath expressions"
    (extract-xpath-param xpath-json)]
   [("--parent") parent "Parent XPath for item extraction (use with --fields)"
    (extract-parent-param parent)]
   [("--fields") fields-json "JSON object mapping field names to XPaths (alone or with --parent)"
    (extract-fields-param fields-json)]
   [("-o" "--output") file "Save results to file"
    (output-file-param file)]
   [("-f" "--format") fmt "Output format: json (default), csv, sqlite"
    (output-format-param (string->symbol fmt))]
   [("-v" "--verbose") "Show detailed progress"
    (verbose-mode #t)]
   #:args remaining
   remaining))

;; @function{parse-sample-args}
;; @description{Parse sample command arguments after the file}
(define (parse-sample-args args)
  (command-line
   #:program "ar-crawl sample"
   #:argv args
   #:once-each
   [("--index") idx "Index of page to show (default: 0)"
    (sample-index-param (string->number idx))]
   [("--length") len "Max length of HTML to show (default: 5000)"
    (sample-length-param (string->number len))]
   #:args remaining
   remaining))

;; @function{parse-probe-args}
;; @description{Parse probe command arguments after the URL}
(define (parse-probe-args args)
  (command-line
   #:program "ar-crawl probe"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output with detailed timing"
    (verbose-mode #t)]
   [("-o" "--output") file "Save results to JSON file"
    (output-file-param file)]
   #:args remaining
   remaining))

;; @function{parse-crawl-args}
;; @description{Parse crawl command arguments after the URL}
(define (parse-crawl-args args)
  (command-line
   #:program "ar-crawl crawl"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   [("-c" "--config") config-file "Path to configuration file"
    (config-file-path config-file)]
   [("-o" "--output") file "Save results to file"
    (output-file-param file)]
   [("-f" "--format") fmt "Output format: json, csv, markdown, sqlite"
    (output-format-param (string->symbol fmt))]
   [("--xpath") xpath "XPath expression to filter HTML content"
    (xpath-filter-param xpath)]
   [("--pw-scroll") "Scroll to bottom of page"
    (pw-scroll #t)]
   [("--pw-scroll-count") count "Number of scroll iterations"
    (pw-scroll-count (string->number count))]
   [("--pw-scroll-delay") delay "Delay between scrolls in ms"
    (pw-scroll-delay (string->number delay))]
   [("--pw-click") selector "CSS selector to click"
    (pw-click-selector selector)]
   [("--pw-click-count") count "Number of times to click"
    (pw-click-count (string->number count))]
   [("--pw-delay") delay "Delay after page load in ms"
    (pw-delay (string->number delay))]
   #:multi
   [("-s" "--service") service "Crawling service to use (repeatable)"
    (selected-services (cons (string->symbol service) (selected-services)))]
   #:args remaining
   remaining))

;; @function{parse-crawl-site-args}
;; @description{Parse crawl-site command arguments after the URL}
(define (parse-crawl-site-args args)
  (command-line
   #:program "ar-crawl crawl-site"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   [("-c" "--config") config-file "Path to configuration file"
    (config-file-path config-file)]
   [("-o" "--output") file "Save results to file"
    (output-file-param file)]
   [("-f" "--format") fmt "Output format: json, csv, markdown, sqlite"
    (output-format-param (string->symbol fmt))]
   [("--xpath") xpath "XPath expression to filter HTML content"
    (xpath-filter-param xpath)]
   [("--max-pages") pages "Maximum number of pages to crawl (default: 50)"
    (max-pages (string->number pages))]
   [("--max-depth") depth "Maximum link-following depth (default: 3)"
    (max-depth (string->number depth))]
   [("--url-pattern") pattern "Regex pattern to filter URLs"
    (url-pattern pattern)]
   [("--allow-external") "Allow following links to external domains"
    (same-domain-only #f)]
   [("--crawl-delay") delay "Delay between requests in ms (default: 1000)"
    (crawl-delay-ms (string->number delay))]
   #:multi
   [("-s" "--service") service "Crawling service to use (repeatable)"
    (selected-services (cons (string->symbol service) (selected-services)))]
   #:args remaining
   remaining))

(define (main)
  (define args (vector->list (current-command-line-arguments)))

  ;; Handle --help and --version at any position
  (when (or (member "--help" args) (member "-h" args))
    (show-main-help)
    (exit 0))
  (when (member "--version" args)
    (show-version)
    (exit 0))

  ;; Find the command (first non-flag argument)
  (define-values (pre-cmd-args command post-cmd-args) (split-args-at-command args))

  ;; Parse global flags from pre-command arguments
  (when (not (empty? pre-cmd-args))
    (command-line
     #:program "ar-crawl"
     #:argv pre-cmd-args
     #:once-each
     [("-v" "--verbose") "Enable verbose output"
      (verbose-mode #t)]
     [("-c" "--config") config-file "Path to configuration file"
      (config-file-path config-file)]
     #:multi
     [("-s" "--service") service "Crawling service to use"
      (selected-services (cons (string->symbol service) (selected-services)))]
     #:args remaining
     (when (not (empty? remaining))
       (printf "Error: Unexpected arguments before command: ~a~n" remaining)
       (exit 1))))

  (cond
    [(not command)
     (show-main-help)]

    [else
     (define cmd-sym (string->symbol command))

     (case cmd-sym
       [(crawl)
        (when (empty? post-cmd-args)
          (printf "Error: URL required for crawl command~n~n")
          (printf "Usage: ar-crawl crawl <url> [options]~n")
          (printf "Run 'ar-crawl help crawl' for more information.~n")
          (exit 1))
        (define url (car post-cmd-args))
        (when (string-prefix? url "-")
           (printf "Error: Invalid URL '~a' (looks like a flag). URLs must not start with '-'~n" url)
           (exit 1))
        (parse-crawl-args (cdr post-cmd-args))
        (cmd-crawl url
                   #:config (config-file-path)
                   #:services (selected-services)
                   #:verbose (verbose-mode)
                   #:output (output-file-param)
                   #:format (output-format-param)
                   #:xpath (xpath-filter-param)
                   #:scroll (pw-scroll)
                   #:scroll-count (pw-scroll-count)
                   #:scroll-delay (pw-scroll-delay)
                   #:click-selector (pw-click-selector)
                   #:click-count (pw-click-count)
                   #:pw-delay (pw-delay))]

       [(crawl-site)
        (when (empty? post-cmd-args)
          (printf "Error: URL required for crawl-site command~n~n")
          (printf "Usage: ar-crawl crawl-site <url> [options]~n")
          (printf "Run 'ar-crawl help crawl-site' for more information.~n")
          (exit 1))
        (define url (car post-cmd-args))
        (when (string-prefix? url "-")
           (printf "Error: Invalid URL '~a' (looks like a flag). URLs must not start with '-'~n" url)
           (exit 1))
        (parse-crawl-site-args (cdr post-cmd-args))
        (cmd-crawl-site url
                        #:config (config-file-path)
                        #:services (selected-services)
                        #:verbose (verbose-mode)
                        #:max-pages (max-pages)
                        #:max-depth (max-depth)
                        #:url-pattern (url-pattern)
                        #:same-domain (same-domain-only)
                        #:crawl-delay (crawl-delay-ms)
                        #:output (output-file-param)
                        #:format (output-format-param)
                        #:xpath (xpath-filter-param))]

       [(health)
        (cmd-health #:config (config-file-path)
                    #:verbose (verbose-mode))]

       [(test)
        (cmd-test #:config (config-file-path)
                  #:verbose (verbose-mode))]

       [(config)
        (when (empty? post-cmd-args)
          (printf "Error: Subcommand required for config command~n~n")
          (printf "Usage: ar-crawl config <subcommand>~n")
          (printf "Subcommands: init, show, validate~n")
          (printf "Run 'ar-crawl help config' for more information.~n")
          (exit 1))
        (cmd-config (string->symbol (car post-cmd-args)))]

       [(services)
        (cmd-services #:verbose (verbose-mode))]

       [(monitor)
        (cmd-monitor #:config (config-file-path))]

       [(extract)
        (when (empty? post-cmd-args)
          (printf "Error: Input file required for extract command~n~n")
          (printf "Usage: ar-crawl extract <file> [options]~n")
          (printf "       ar-crawl extract <file> --xpath-map '{...}'~n")
          (printf "       ar-crawl extract <file> --parent \"//div\" --fields '{...}'~n")
          (printf "Run 'ar-crawl help extract' for more information.~n")
          (exit 1))
        (define input-file (car post-cmd-args))
        (parse-extract-args (cdr post-cmd-args))
        (cmd-extract input-file
                     #:xpath (extract-xpath-param)
                     #:parent (extract-parent-param)
                     #:fields (extract-fields-param)
                     #:output (output-file-param)
                     #:format (output-format-param)
                     #:verbose (verbose-mode))]

       [(sample)
        (when (empty? post-cmd-args)
          (printf "Error: Input file required for sample command~n~n")
          (printf "Usage: ar-crawl sample <file> [--index N] [--length N]~n")
          (exit 1))
        (define input-file (car post-cmd-args))
        (parse-sample-args (cdr post-cmd-args))
        (cmd-sample input-file
                    #:index (sample-index-param)
                    #:length (sample-length-param))]

       [(stats)
        (when (empty? post-cmd-args)
          (printf "Error: Database file required for stats command~n~n")
          (printf "Usage: ar-crawl stats <file.db>~n")
          (exit 1))
        (define db-file (car post-cmd-args))
        (with-handlers ([exn:fail? (lambda (e)
                                     (eprintf "Error analyzing stats: ~a~n" (exn-message e))
                                     (exit 1))])
           (cmd-stats db-file #:verbose (verbose-mode)))]

       [(probe)
        (when (empty? post-cmd-args)
          (printf "Error: URL required for probe command~n~n")
          (printf "Usage: ar-crawl probe <url> [options]~n")
          (printf "Run 'ar-crawl help probe' for more information.~n")
          (exit 1))
        (define probe-target-url (car post-cmd-args))
        (parse-probe-args (cdr post-cmd-args))
        (with-playwright-cleanup
          (cmd-probe probe-target-url
                     #:verbose (verbose-mode)
                     #:output (output-file-param)))]

       [(help)
        (if (empty? post-cmd-args)
            (show-main-help)
            (show-command-help (car post-cmd-args)))]

       [(version)
        (show-version)]

       [else
        (printf "Unknown command: ~a~n~n" command)
        (printf "Run 'ar-crawl help' for usage information.~n")])]))

;; Initialize global parameters
(define verbose-mode (make-parameter #f))
(define config-file-path (make-parameter #f))
(define selected-services (make-parameter '()))

;; Playwright-specific parameters
(define pw-scroll (make-parameter #f))
(define pw-scroll-count (make-parameter 0))
(define pw-scroll-delay (make-parameter 1000))
(define pw-click-selector (make-parameter #f))
(define pw-click-count (make-parameter 1))
(define pw-delay (make-parameter 5000))

;; Version info
(define AR-CRAWL-VERSION "1.0.0")

;; Help Documentation
;; ------------------

;; @function{show-version}
;; @description{Display version information}
(define (show-version)
  (printf "ar-crawl ~a~n" AR-CRAWL-VERSION)
  (printf "Production web crawler with service fallbacks~n")
  (printf "Copyright (c) 2025 Anuna Research~n"))

;; @function{show-main-help}
;; @description{Display main help message with overview of all commands}
(define (show-main-help)
  (printf "~n")
  (printf "AR-CRAWL - Production Web Crawler~n")
  (printf "==================================~n~n")
  (printf "A powerful web crawler with automatic service fallbacks, JavaScript rendering,~n")
  (printf "and multiple output formats.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl <command> [options] [arguments]~n")
  (printf "  ar-crawl --help~n")
  (printf "  ar-crawl --version~n~n")

  (printf "COMMANDS~n")
  (printf "  crawl <url>         Crawl a single URL and extract content~n")
  (printf "  crawl-site <url>    Crawl an entire website following links~n")
  (printf "  probe <url>         Measure page load metrics to inform scraping params~n")
  (printf "  sample <file>       Show sample HTML from crawl results (to figure out XPaths)~n")
  (printf "  extract <file>      Extract structured data from crawl results using XPath~n")
  (printf "  stats <file.db>     Show statistics about crawl database~n")
  (printf "  health              Check health status of configured services~n")
  (printf "  test [--service]    Test crawling services with a sample URL~n")
  (printf "  config <subcommand> Manage configuration files~n")
  (printf "  services            List all available crawling services~n")
  (printf "  monitor             Start real-time monitoring dashboard~n")
  (printf "  help [command]      Show help for a specific command~n~n")

  (printf "GLOBAL OPTIONS~n")
  (printf "  -v, --verbose       Enable verbose output with detailed logging~n")
  (printf "  -c, --config FILE   Path to configuration file (auto-detected by default)~n")
  (printf "      --help          Show this help message (also: ar-crawl help)~n")
  (printf "      --version       Show version information~n~n")

  (printf "QUICK START~n")
  (printf "  # Crawl a single page~n")
  (printf "  ar-crawl crawl https://example.com~n~n")
  (printf "  # Crawl an entire site (max 100 pages)~n")
  (printf "  ar-crawl crawl-site https://example.com --max-pages 100~n~n")
  (printf "  # Save results to a file~n")
  (printf "  ar-crawl crawl https://example.com -o results.json~n~n")
  (printf "  # Use a specific crawling service~n")
  (printf "  ar-crawl crawl https://example.com -s playwright~n~n")

  (printf "Run 'ar-crawl help <command>' for detailed help on a specific command.~n~n"))

;; @function{show-crawl-help}
;; @description{Display help for the crawl command}
(define (show-crawl-help)
  (printf "~n")
  (printf "AR-CRAWL CRAWL - Crawl a Single URL~n")
  (printf "====================================~n~n")
  (printf "Fetch and extract content from a single URL using configured crawling services.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl crawl <url> [options]~n~n")

  (printf "ARGUMENTS~n")
  (printf "  <url>               The URL to crawl (required)~n~n")

  (printf "OPTIONS~n")
  (printf "  -s, --service SVC   Crawling service to use (can be repeated for fallback)~n")
  (printf "                      Available: direct, playwright, firecrawl, scrapingbee,~n")
  (printf "                                 browserless, scraperapi~n")
  (printf "  -o, --output FILE   Save results to file instead of stdout~n")
  (printf "  -f, --format FMT    Output format: json (default), csv, markdown, sqlite~n")
  (printf "      --xpath EXPR    XPath expression to filter HTML content~n")
  (printf "  -c, --config FILE   Configuration file path~n")
  (printf "  -v, --verbose       Show detailed progress and debugging info~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Basic crawl~n")
  (printf "  ar-crawl crawl https://example.com~n~n")
  (printf "  # Crawl with JavaScript rendering using Playwright~n")
  (printf "  ar-crawl crawl https://spa-website.com -s playwright~n~n")
  (printf "  # Save as JSON with verbose output~n")
  (printf "  ar-crawl crawl https://example.com -o page.json -v~n~n")
  (printf "  # Extract only article content using XPath~n")
  (printf "  ar-crawl crawl https://blog.com/post --xpath \"//article\"~n~n")
  (printf "  # Use multiple services with automatic fallback~n")
  (printf "  ar-crawl crawl https://example.com -s firecrawl -s playwright -s direct~n~n")

  (printf "SERVICES~n")
  (printf "  direct       Built-in HTTP client (no API key required)~n")
  (printf "  playwright   Local browser rendering for JavaScript-heavy sites~n")
  (printf "  firecrawl    Cloud-based content extraction API~n")
  (printf "  scrapingbee  Cloud scraping with JavaScript rendering~n")
  (printf "  browserless  Remote browser automation~n")
  (printf "  scraperapi   Proxy rotation and CAPTCHA handling~n~n"))

;; @function{show-crawl-site-help}
;; @description{Display help for the crawl-site command}
(define (show-crawl-site-help)
  (printf "~n")
  (printf "AR-CRAWL CRAWL-SITE - Crawl an Entire Website~n")
  (printf "==============================================~n~n")
  (printf "Recursively crawl a website following links up to specified depth and page limits.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl crawl-site <url> [options]~n~n")

  (printf "ARGUMENTS~n")
  (printf "  <url>                  Starting URL for the crawl (required)~n~n")

  (printf "OPTIONS~n")
  (printf "      --max-pages N      Maximum number of pages to crawl (default: 50)~n")
  (printf "      --max-depth N      Maximum link-following depth (default: 3)~n")
  (printf "      --url-pattern RE   Regex pattern to filter URLs (default: \".*\")~n")
  (printf "      --allow-external   Allow crawling links to external domains~n")
  (printf "      --crawl-delay MS   Delay between requests in milliseconds (default: 1000)~n")
  (printf "  -s, --service SVC      Crawling service to use (can be repeated)~n")
  (printf "  -o, --output FILE      Save results to file~n")
  (printf "  -f, --format FMT       Output format: json, csv, markdown, sqlite~n")
  (printf "      --xpath EXPR       XPath expression to filter content~n")
  (printf "  -c, --config FILE      Configuration file path~n")
  (printf "  -v, --verbose          Show detailed progress~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Crawl a site with default settings~n")
  (printf "  ar-crawl crawl-site https://docs.example.com~n~n")
  (printf "  # Crawl up to 200 pages, 5 levels deep~n")
  (printf "  ar-crawl crawl-site https://example.com --max-pages 200 --max-depth 5~n~n")
  (printf "  # Only crawl blog posts matching a pattern~n")
  (printf "  ar-crawl crawl-site https://blog.com --url-pattern \"/posts/.*\"~n~n")
  (printf "  # Save to SQLite database for analysis~n")
  (printf "  ar-crawl crawl-site https://example.com -o results.db -f sqlite~n~n")
  (printf "  # Slower crawl with 2-second delay (be respectful!)~n")
  (printf "  ar-crawl crawl-site https://example.com --crawl-delay 2000~n~n")
  (printf "  # Include external links~n")
  (printf "  ar-crawl crawl-site https://example.com --allow-external~n~n")

  (printf "NOTES~n")
  (printf "  - By default, only same-domain URLs are followed~n")
  (printf "  - Use --crawl-delay to avoid overwhelming target servers~n")
  (printf "  - The --url-pattern option accepts Racket regex syntax~n")
  (printf "  - Progress is shown in verbose mode with [current/total] prefix~n~n"))

;; @function{show-health-help}
;; @description{Display help for the health command}
(define (show-health-help)
  (printf "~n")
  (printf "AR-CRAWL HEALTH - Check Service Health~n")
  (printf "=======================================~n~n")
  (printf "Check the health and availability of all configured crawling services.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl health [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -c, --config FILE   Configuration file path~n")
  (printf "  -v, --verbose       Show detailed health information~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Quick health check~n")
  (printf "  ar-crawl health~n~n")
  (printf "  # Detailed health report~n")
  (printf "  ar-crawl health -v~n~n")

  (printf "OUTPUT~n")
  (printf "  Shows overall status, uptime, and per-service health indicators:~n")
  (printf "    ✓ Healthy    - Service is responding normally~n")
  (printf "    ✗ Unhealthy  - Service is unavailable or erroring~n~n"))

;; @function{show-test-help}
;; @description{Display help for the test command}
(define (show-test-help)
  (printf "~n")
  (printf "AR-CRAWL TEST - Test Crawling Services~n")
  (printf "=======================================~n~n")
  (printf "Test individual or all crawling services by fetching a sample URL.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl test [options]~n~n")

  (printf "OPTIONS~n")
  (printf "      --service SVC   Test only a specific service~n")
  (printf "  -c, --config FILE   Configuration file path~n")
  (printf "  -v, --verbose       Show response details (content length, links found)~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Test all configured services~n")
  (printf "  ar-crawl test~n~n")
  (printf "  # Test only the playwright service~n")
  (printf "  ar-crawl test --service playwright~n~n")
  (printf "  # Verbose test with response details~n")
  (printf "  ar-crawl test -v~n~n")

  (printf "OUTPUT~n")
  (printf "  For each service, shows:~n")
  (printf "    ✓ Success (Nms)  - Service works, with response time~n")
  (printf "    ✗ Failed         - Service is not working~n~n"))

;; @function{show-config-help}
;; @description{Display help for the config command}
(define (show-config-help)
  (printf "~n")
  (printf "AR-CRAWL CONFIG - Manage Configuration~n")
  (printf "=======================================~n~n")
  (printf "Create, view, and validate configuration files.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl config <subcommand> [options]~n~n")

  (printf "SUBCOMMANDS~n")
  (printf "  init      Create a new configuration file with defaults~n")
  (printf "  show      Display the contents of a configuration file~n")
  (printf "  validate  Check if a configuration file is valid~n~n")

  (printf "OPTIONS~n")
  (printf "  --file FILE   Configuration file path (default: config/default.json)~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Create a new default configuration~n")
  (printf "  ar-crawl config init~n~n")
  (printf "  # Create config in a custom location~n")
  (printf "  ar-crawl config init --file myconfig.json~n~n")
  (printf "  # View current configuration~n")
  (printf "  ar-crawl config show~n~n")
  (printf "  # Validate a configuration file~n")
  (printf "  ar-crawl config validate --file production.json~n~n")

  (printf "CONFIGURATION FILE FORMAT~n")
  (printf "  Configuration uses JSON format with the following structure:~n~n")
  (printf "  {~n")
  (printf "    \"crawler\": {~n")
  (printf "      \"services\": [\"direct\", \"playwright\"],~n")
  (printf "      \"fallback_enabled\": true,~n")
  (printf "      \"rate_limit_ms\": 1000,~n")
  (printf "      \"retry_attempts\": 3,~n")
  (printf "      \"timeout_ms\": 30000~n")
  (printf "    },~n")
  (printf "    \"services\": {~n")
  (printf "      \"firecrawl\": { \"api_key\": \"your-key\" }~n")
  (printf "    }~n")
  (printf "  }~n~n"))

;; @function{show-services-help}
;; @description{Display help for the services command}
(define (show-services-help)
  (printf "~n")
  (printf "AR-CRAWL SERVICES - List Available Services~n")
  (printf "============================================~n~n")
  (printf "Display all available crawling services and their status.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl services [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -v, --verbose   Check and display availability status for each service~n~n")

  (printf "EXAMPLES~n")
  (printf "  # List available services~n")
  (printf "  ar-crawl services~n~n")
  (printf "  # List services with availability status~n")
  (printf "  ar-crawl services -v~n~n")

  (printf "AVAILABLE SERVICES~n")
  (printf "  direct       Built-in HTTP client~n")
  (printf "               - No API key required~n")
  (printf "               - Fast for simple HTML pages~n")
  (printf "               - No JavaScript support~n~n")
  (printf "  playwright   Local browser rendering~n")
  (printf "               - Full JavaScript execution~n")
  (printf "               - Requires Node.js~n")
  (printf "               - Best for SPAs and dynamic content~n~n")
  (printf "  firecrawl    Cloud extraction service~n")
  (printf "               - Requires API key (FIRECRAWL_API_KEY)~n")
  (printf "               - Good content extraction~n")
  (printf "               - Handles complex pages~n~n")
  (printf "  scrapingbee  Cloud scraping service~n")
  (printf "               - Requires API key (SCRAPINGBEE_API_KEY)~n")
  (printf "               - JavaScript rendering~n")
  (printf "               - Proxy rotation~n~n")
  (printf "  browserless  Remote browser automation~n")
  (printf "               - Requires API key (BROWSERLESS_API_KEY)~n")
  (printf "               - Full browser control~n~n")
  (printf "  scraperapi   Proxy and CAPTCHA service~n")
  (printf "               - Requires API key (SCRAPERAPI_API_KEY)~n")
  (printf "               - Automatic proxy rotation~n")
  (printf "               - CAPTCHA solving~n~n"))

;; @function{show-monitor-help}
;; @description{Display help for the monitor command}
(define (show-monitor-help)
  (printf "~n")
  (printf "AR-CRAWL MONITOR - Real-time Monitoring Dashboard~n")
  (printf "==================================================~n~n")
  (printf "Display a live dashboard showing crawler status and metrics.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl monitor [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -c, --config FILE    Configuration file path~n")
  (printf "      --interval SEC   Dashboard refresh interval in seconds (default: 5)~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Start monitoring with defaults~n")
  (printf "  ar-crawl monitor~n~n")
  (printf "  # Fast refresh (every 2 seconds)~n")
  (printf "  ar-crawl monitor --interval 2~n~n")

  (printf "DASHBOARD DISPLAYS~n")
  (printf "  - Overall crawler status~n")
  (printf "  - Active/total job counts~n")
  (printf "  - Success rate percentage~n")
  (printf "  - Average response time~n")
  (printf "  - Per-service health indicators~n")
  (printf "  - Last update timestamp~n~n")
  (printf "Press Ctrl+C to exit the monitoring dashboard.~n~n"))

;; @function{show-extract-help}
;; @description{Show help for extract command}
(define (show-extract-help)
  (printf "~nEXTRACT - Extract structured data from crawl results~n")
  (printf "=====================================================~n~n")
  (printf "Extract specific fields from crawled HTML content using XPath expressions.~n")
  (printf "Powered by sxml/sxpath for robust HTML parsing.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl extract <file> --fields '<json>'~n")
  (printf "  ar-crawl extract <file> --parent '<xpath>' --fields '<json>'~n~n")

  (printf "OPTIONS~n")
  (printf "  --fields <json>          JSON object mapping field names to XPaths~n")
  (printf "  --xpath-map <json>       Alias for --fields~n")
  (printf "  --parent <xpath>         Parent container XPath for repeating items~n")
  (printf "  -o, --output <file>      Output file (stdout if not specified)~n")
  (printf "  -f, --format <fmt>       Output format: json (default), csv, sqlite~n")
  (printf "  -v, --verbose            Show detailed progress~n~n")

  (printf "EXTRACTION MODES~n~n")

  (printf "  1. Simple Field Extraction (--fields)~n")
  (printf "     Extract specific fields from each page in the crawl results.~n~n")
  (printf "     Example: Extract title and all prices~n")
  (displayln "     ar-crawl extract results.json --fields '{")
  (displayln "       \"title\": \"//title\",")
  (displayln "       \"prices\": \"//span[contains(@class,\\\"price\\\")]\"")
  (displayln "     }'")
  (newline)

  (printf "  2. Item Extraction (--parent + --fields)~n")
  (printf "     Extract repeating items like products, articles, etc.~n~n")
  (printf "     Example: Extract all product cards~n")
  (displayln "     ar-crawl extract results.json \\")
  (displayln "       --parent \"//div[contains(@class,'product')]\" \\")
  (displayln "       --fields '{")
  (displayln "         \"name\": \".//h2\",")
  (displayln "         \"price\": \".//span[@class=\\\"price\\\"]\",")
  (displayln "         \"link\": \".//a/@href\"")
  (displayln "       }'")
  (newline)

  (printf "XPATH TIPS~n")
  (printf "  //tag                    Select all <tag> elements~n")
  (printf "  //tag[@class='x']        Select by class attribute~n")
  (printf "  //tag[contains(@class,'x')]  Class contains 'x'~n")
  (printf "  //tag/text()             Get text content~n")
  (printf "  //tag/@href              Get attribute value~n")
  (printf "  .//tag                   Relative to parent (for --fields)~n~n")

  (printf "EXAMPLES~n~n")

  (printf "  # Extract product data from Pick 'n Save crawl~n")
  (displayln "  ar-crawl extract pns-products.json \\")
  (displayln "    --parent \"//div[contains(@data-testid,'ProductCard')]\" \\")
  (displayln "    --fields '{\"name\": \".//h2\", \"price\": \".//span\"}' \\")
  (displayln "    -o products.csv -f csv")
  (newline)

  (printf "  # Extract all links and images~n")
  (displayln "  ar-crawl extract page.json \\")
  (displayln "    --xpath-map '{\"links\": \"//a/@href\", \"images\": \"//img/@src\"}'")
  (newline))

;; @function{show-sample-help}
;; @description{Show help for sample command}
(define (show-sample-help)
  (printf "~nSAMPLE - View HTML from crawl results~n")
  (printf "======================================~n~n")
  (printf "Show sample HTML content from a crawl results file to help~n")
  (printf "figure out the right XPath expressions for data extraction.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl sample <file> [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  --index N      Index of page to show (default: 0)~n")
  (printf "  --length N     Max length of HTML to display (default: 5000)~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Show first page from crawl results~n")
  (printf "  ar-crawl sample results.json~n~n")
  (printf "  # Show third page (index 2)~n")
  (printf "  ar-crawl sample results.json --index 2~n~n")
  (printf "  # Show more HTML content~n")
  (printf "  ar-crawl sample results.json --length 10000~n~n"))

;; @function{show-probe-help}
;; @description{Show help for probe command}
(define (show-probe-help)
  (printf "~nPROBE - Measure page load performance~n")
  (printf "======================================~n~n")
  (printf "Probe a URL using Playwright to measure page load timing metrics.~n")
  (printf "Use this to determine optimal scraping parameters for a site.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl probe <url> [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -v, --verbose       Show detailed timing breakdown~n")
  (printf "  -o, --output FILE   Save results to JSON file~n~n")

  (printf "METRICS MEASURED~n")
  (printf "  DOM Content Loaded  Time until DOMContentLoaded event fires~n")
  (printf "  Page Load Complete  Time until load event fires~n")
  (printf "  Network Idle        Time until no network activity for 500ms~n")
  (printf "  JS Execution (est)  Estimated JavaScript execution time~n~n")

  (printf "VERBOSE MODE DETAILS~n")
  (printf "  TTFB               Time to first byte~n")
  (printf "  DOM Parsing        Time spent parsing DOM~n")
  (printf "  Resource breakdown Requests and transfer size by type~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Basic probe~n")
  (printf "  ar-crawl probe https://example.com~n~n")
  (printf "  # Verbose probe with detailed breakdown~n")
  (printf "  ar-crawl probe https://spa-site.com -v~n~n")
  (printf "  # Save results for later analysis~n")
  (printf "  ar-crawl probe https://example.com -o probe-results.json~n~n")

  (printf "OUTPUT~n")
  (printf "  The command outputs timing metrics and recommended parameters:~n~n")
  (printf "    --pw-delay N        Recommended delay after page load~n")
  (printf "    --pw-scroll-delay N Recommended delay between scrolls~n")
  (printf "    --timeout N         Recommended request timeout~n~n")

  (printf "NOTE~n")
  (printf "  This command uses Playwright and requires the playwright service.~n")
  (printf "  It will be started automatically if not running.~n~n"))

;; @function{show-command-help}
;; @description{Show help for a specific command}
(define (show-command-help command)
  (case (if (string? command) (string->symbol command) command)
    [(crawl) (show-crawl-help)]
    [(crawl-site) (show-crawl-site-help)]
    [(probe) (show-probe-help)]
    [(extract) (show-extract-help)]
    [(sample) (show-sample-help)]
    [(health) (show-health-help)]
    [(test) (show-test-help)]
    [(config) (show-config-help)]
    [(services) (show-services-help)]
    [(monitor) (show-monitor-help)]
    [else
     (printf "Unknown command: ~a~n~n" command)
     (printf "Available commands: crawl, crawl-site, probe, extract, sample, health, test, config, services, monitor~n")
     (printf "Run 'ar-crawl help <command>' for help on a specific command.~n")]))

;; Site crawler parameters
(define max-pages (make-parameter 50))
(define max-depth (make-parameter 3))
(define url-pattern (make-parameter ".*"))
(define same-domain-only (make-parameter #t))
(define crawl-delay-ms (make-parameter 1000))
(define output-file-param (make-parameter #f))
(define output-format-param (make-parameter #f))
(define xpath-filter-param (make-parameter #f))

;; Extract command parameters
(define extract-xpath-param (make-parameter #f))
(define extract-parent-param (make-parameter #f))
(define extract-fields-param (make-parameter #f))

;; Sample command parameters
(define sample-index-param (make-parameter 0))
(define sample-length-param (make-parameter 5000))

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit)

  ;; -------------------------------------------------------------------------
  ;; Argument Parsing Tests
  ;; -------------------------------------------------------------------------

  (test-case "find-command-index - command first"
    (check-equal? (find-command-index '("crawl" "http://example.com")) 0))

  (test-case "find-command-index - flags before command"
    ;; -v is a flag, --config is a flag, file.json is a positional (command), crawl is also positional
    ;; The first non-flag is file.json at index 2
    (check-equal? (find-command-index '("-v" "--config" "file.json" "crawl")) 2))

  (test-case "find-command-index - no command"
    (check-false (find-command-index '("-v" "--help"))))

  (test-case "find-command-index - empty args"
    (check-false (find-command-index '())))

  (test-case "split-args-at-command - basic"
    (define-values (pre cmd post) (split-args-at-command '("crawl" "http://test.com")))
    (check-equal? pre '())
    (check-equal? cmd "crawl")
    (check-equal? post '("http://test.com")))

  (test-case "split-args-at-command - with flags"
    ;; -v is a flag, -c is a flag, config.json is the first non-flag (becomes command)
    (define-values (pre cmd post)
      (split-args-at-command '("-v" "-c" "config.json" "crawl-site" "http://test.com" "--max-pages" "10")))
    (check-equal? pre '("-v" "-c"))
    (check-equal? cmd "config.json")
    (check-equal? post '("crawl-site" "http://test.com" "--max-pages" "10")))

  (test-case "split-args-at-command - no command"
    (define-values (pre cmd post) (split-args-at-command '("-v" "--help")))
    (check-equal? pre '("-v" "--help"))
    (check-false cmd)
    (check-equal? post '()))

  (test-case "split-args-at-command - empty"
    (define-values (pre cmd post) (split-args-at-command '()))
    (check-equal? pre '())
    (check-false cmd)
    (check-equal? post '()))

  ;; -------------------------------------------------------------------------
  ;; Data Conversion Tests
  ;; -------------------------------------------------------------------------

  (test-case "job-results->hash conversion"
    (define results (job-results '((hash 'url "http://test.com"))
                                 (hash 'job-id "123")
                                 '()))
    (define h (job-results->hash results))
    (check-true (hash? h))
    (check-true (hash-has-key? h 'data))
    (check-true (hash-has-key? h 'metadata))
    (check-true (hash-has-key? h 'errors))
    (check-true (hash-has-key? h 'timestamp)))

  (test-case "job-results->hash - empty results"
    (define results (job-results '() (hash) '()))
    (define h (job-results->hash results))
    (check-equal? (hash-ref h 'data) '())
    (check-equal? (hash-ref h 'errors) '()))

  (test-case "health-status->hash conversion"
    ;; Use health-check to get a real health-status since constructor isn't exported
    (setup-crawler #f #f)
    (define crawler (create-crawler-from-config))
    (define health (health-check crawler))
    (define h (health-status->hash health))
    (check-true (hash? h))
    (check-true (symbol? (hash-ref h 'status)))
    (check-true (number? (hash-ref h 'uptime)))
    (check-true (number? (hash-ref h 'last_check)))
    (check-true (hash? (hash-ref h 'services))))

  (test-case "results->csv basic"
    (define results (job-results '() (hash) '()))
    (define csv (results->csv results))
    (check-true (string? csv)))

  (test-case "results->markdown basic"
    (define results (job-results '() (hash) '()))
    (define md (results->markdown results))
    (check-true (string? md))
    (check-true (string-contains? md "# Crawl Results")))

  (test-case "results->markdown with data"
    (define results (job-results '((hash 'content "test")) (hash) '()))
    (define md (results->markdown results))
    (check-true (string-contains? md "Data extracted successfully")))

  ;; -------------------------------------------------------------------------
  ;; extracted-results->csv Tests
  ;; -------------------------------------------------------------------------

  (test-case "extracted-results->csv - basic"
    (define results (list (hash 'name "Product 1" 'price "$10")
                          (hash 'name "Product 2" 'price "$20")))
    (define out (open-output-string))
    (extracted-results->csv results out)
    (define csv (get-output-string out))
    (check-true (string-contains? csv "name"))
    (check-true (string-contains? csv "price"))
    (check-true (string-contains? csv "Product 1")))

  (test-case "extracted-results->csv - empty"
    (define out (open-output-string))
    (extracted-results->csv '() out)
    (check-equal? (get-output-string out) ""))

  (test-case "extracted-results->csv - escapes commas"
    (define results (list (hash 'name "Product, with comma" 'price "$10")))
    (define out (open-output-string))
    (extracted-results->csv results out)
    (define csv (get-output-string out))
    (check-true (string-contains? csv "\"")))

  (test-case "extracted-results->csv - handles lists"
    (define results (list (hash 'tags '("a" "b" "c"))))
    (define out (open-output-string))
    (extracted-results->csv results out)
    (define csv (get-output-string out))
    (check-true (string-contains? csv "a; b; c")))

  ;; -------------------------------------------------------------------------
  ;; XPath Filter Tests
  ;; -------------------------------------------------------------------------

  (test-case "apply-xpath-filter-to-job-results"
    (define results (job-results
                     (list (hash 'content "<html><body><p>test</p></body></html>"
                                 'url "http://test.com"))
                     (hash 'job-id "123")
                     '()))
    (define filtered (apply-xpath-filter-to-job-results results "//p"))
    (check-true (job-results? filtered))
    (check-equal? (length (job-results-data filtered)) 1))

  ;; -------------------------------------------------------------------------
  ;; Version and Help Output Tests
  ;; -------------------------------------------------------------------------

  (test-case "show-version outputs version"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-version))
    (define output (get-output-string out))
    (check-true (string-contains? output "ar-crawl"))
    (check-true (string-contains? output AR-CRAWL-VERSION)))

  (test-case "show-main-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-main-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "AR-CRAWL"))
    (check-true (string-contains? output "USAGE"))
    (check-true (string-contains? output "COMMANDS"))
    (check-true (string-contains? output "crawl"))
    (check-true (string-contains? output "crawl-site")))

  (test-case "show-crawl-help outputs crawl help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-crawl-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "CRAWL"))
    (check-true (string-contains? output "USAGE"))
    (check-true (string-contains? output "--service")))

  (test-case "show-crawl-site-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-crawl-site-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "CRAWL-SITE"))
    (check-true (string-contains? output "--max-pages")))

  (test-case "show-health-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-health-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "HEALTH")))

  (test-case "show-test-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-test-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "TEST")))

  (test-case "show-config-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-config-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "CONFIG"))
    (check-true (string-contains? output "init")))

  (test-case "show-services-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-services-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "SERVICES"))
    (check-true (string-contains? output "direct"))
    (check-true (string-contains? output "playwright")))

  (test-case "show-monitor-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-monitor-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "MONITOR")))

  (test-case "show-extract-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-extract-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "EXTRACT"))
    (check-true (string-contains? output "--xpath-map")))

  (test-case "show-sample-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-sample-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "SAMPLE")))

  (test-case "show-probe-help outputs help"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-probe-help))
    (define output (get-output-string out))
    (check-true (string-contains? output "PROBE")))

  (test-case "show-command-help dispatches correctly"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-command-help "crawl"))
    (check-true (string-contains? (get-output-string out) "CRAWL")))

  (test-case "show-command-help handles unknown command"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (show-command-help "unknown-cmd"))
    (check-true (string-contains? (get-output-string out) "Unknown command")))

  ;; -------------------------------------------------------------------------
  ;; Parameter Tests
  ;; -------------------------------------------------------------------------

  (test-case "parameters have correct defaults"
    (check-false (verbose-mode))
    (check-false (config-file-path))
    (check-equal? (selected-services) '())
    (check-false (pw-scroll))
    (check-equal? (pw-scroll-count) 0)
    (check-equal? (pw-scroll-delay) 1000)
    (check-false (pw-click-selector))
    (check-equal? (pw-click-count) 1)
    (check-equal? (pw-delay) 5000)
    (check-equal? (max-pages) 50)
    (check-equal? (max-depth) 3)
    (check-equal? (url-pattern) ".*")
    (check-true (same-domain-only))
    (check-equal? (crawl-delay-ms) 1000)
    (check-false (output-file-param))
    (check-false (output-format-param))
    (check-false (xpath-filter-param))
    (check-equal? (sample-index-param) 0)
    (check-equal? (sample-length-param) 5000))

  ;; -------------------------------------------------------------------------
  ;; Playwright Service Detection Tests
  ;; -------------------------------------------------------------------------

  (test-case "get-playwright-service-dir returns path"
    (define dir (get-playwright-service-dir))
    (check-true (path-string? dir)))

  (test-case "playwright-service-installed? returns boolean"
    (define result (playwright-service-installed?))
    (check-true (boolean? result)))

  ;; -------------------------------------------------------------------------
  ;; Setup and Configuration Tests
  ;; -------------------------------------------------------------------------

  (test-case "setup-crawler with no config"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (setup-crawler #f #f))
    (check-true (hash? global-config)))

  (test-case "setup-crawler sets global-config"
    (setup-crawler #f #f)
    (check-true (hash? global-config)))

  (test-case "create-crawler-from-config creates crawler"
    (setup-crawler #f #f)
    (define crawler (create-crawler-from-config))
    ;; Verify crawler works by calling get-crawler-status
    (define status (get-crawler-status crawler))
    ;; status has active-jobs accessor
    (check-true (number? (crawler-status-active-jobs status))))

  ;; -------------------------------------------------------------------------
  ;; cmd-services Tests
  ;; -------------------------------------------------------------------------

  (test-case "cmd-services lists services"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (cmd-services #:verbose #f))
    (define output (get-output-string out))
    (check-true (string-contains? output "Available Crawling Services"))
    (check-true (string-contains? output "Total services")))

  (test-case "cmd-services verbose mode"
    (define out (open-output-string))
    (parameterize ([current-output-port out])
      (cmd-services #:verbose #t))
    (define output (get-output-string out))
    (check-true (string-contains? output "Status:")))

  ;; -------------------------------------------------------------------------
  ;; ensure-playwright-if-needed Tests
  ;; -------------------------------------------------------------------------

  (test-case "ensure-playwright-if-needed with empty services"
    ;; Should not error with empty list
    (ensure-playwright-if-needed '() #:verbose #f))

  (test-case "ensure-playwright-if-needed without playwright"
    ;; Should not start playwright if not in list
    (ensure-playwright-if-needed '(direct firecrawl) #:verbose #f))

  ;; -------------------------------------------------------------------------
  ;; stop-playwright-service Tests
  ;; -------------------------------------------------------------------------

  (test-case "stop-playwright-service when not running"
    ;; Should not error when no process running
    (stop-playwright-service))

  ;; -------------------------------------------------------------------------
  ;; Version Constant Test
  ;; -------------------------------------------------------------------------

  (test-case "AR-CRAWL-VERSION is defined"
    (check-true (string? AR-CRAWL-VERSION))
    (check-true (> (string-length AR-CRAWL-VERSION) 0))))

;; Run main if this file is executed directly
(module+ main
  ;; Register cleanup handler for playwright service
  (void (plumber-add-flush! (current-plumber)
                            (lambda (handle)
                              (stop-playwright-service))))
  (main))

