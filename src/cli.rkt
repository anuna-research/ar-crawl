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
         json
         net/url
         "production-crawler.rkt"
         "config-manager.rkt"
         "crawl-service-adaptor.rkt"
         "scraper-interfaces.rkt"
         "site-crawler.rkt"
         "data-formatter.rkt"
         "utils.rkt")

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
  (define script-dir (path-only (path->complete-path (find-system-path 'run-file))))
  (simplify-path (build-path script-dir ".." "playwright-service")))

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

;; @function{cmd-crawl}
;; @description{Crawl a single URL}
(define (cmd-crawl url
                  #:config [config-file #f]
                  #:output [output-file #f]
                  #:format [format 'json]
                  #:services [services '()]
                  #:verbose [verbose #f]
                  #:wait [wait #f]
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

  (printf "Crawling URL: ~a~n" url)
  (when verbose
    (printf "Using services: ~a~n" 
           (get-config-value global-config '(crawler services))))
  
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
      (let* ([_ (printf "Crawl completed successfully~n")]
             ;; Apply XPath filter if specified
             [filtered-results
              (if xpath
                  (apply-xpath-filter-to-job-results results xpath)
                  results)])
        (output-results filtered-results output-file format verbose))
      (printf "Crawl failed~n")))

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

  ;; Create site crawl configuration
  (define site-config 
    (make-site-crawl-config
     #:max-pages max-pages
     #:max-depth max-depth
     #:url-pattern url-pattern
     #:same-domain-only same-domain
     #:crawl-delay-ms crawl-delay))
  
  (printf "Starting site crawl from: ~a~n" url)
  (when verbose
    (printf "Max pages: ~a~n" max-pages)
    (printf "Max depth: ~a~n" max-depth)
    (printf "URL pattern: ~a~n" url-pattern)
    (printf "Same domain only: ~a~n" same-domain)
    (printf "Crawl delay: ~a ms~n" crawl-delay))
  
  ;; Progress callback for verbose mode
  (define progress-callback
    (if verbose
        (lambda (message current total)
          (printf "[~a/~a] ~a~n" current total message))
        #f))
  
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
      (printf "Site crawl failed - no pages crawled successfully~n")
      (begin
        (printf "Site crawl completed successfully~n")
        (when verbose
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
          
          (output-site-results site-results output-file format verbose)))))

;; @function{output-site-results}
;; @description{Output site crawl results to file}
(define (output-site-results results output-file format verbose)
  (ensure-directory (path-only output-file))
  
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
        (printf "Results saved to: ~a~n" output-file))
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

(define (main)
  (command-line
   #:program "ar-crawl"
   #:once-each
   [("-v" "--verbose") "Verbose output"
    (verbose-mode #t)]
   [("-c" "--config") config-file "Configuration file"
    (config-file-path config-file)]
   [("--max-pages") pages "Maximum pages to crawl (default: 50)"
    (max-pages (string->number pages))]
   [("--max-depth") depth "Maximum crawl depth (default: 3)"
    (max-depth (string->number depth))]
   [("--url-pattern") pattern "URL regex pattern (default: \".*\")"
    (url-pattern pattern)]
   [("--allow-external") "Allow crawling external domains"
    (same-domain-only #f)]
   [("--crawl-delay") delay "Delay between requests in ms (default: 1000)"
    (crawl-delay-ms (string->number delay))]
   [("-o" "--output") file "Output file path"
    (output-file-param file)]
   [("-f" "--format") fmt "Output format: json, csv, markdown, sqlite (default: json)"
   (output-format-param (string->symbol fmt))]
    [("--xpath") xpath "XPath expression to filter HTML content"
    (xpath-filter-param xpath)]
   
   #:multi
   [("-s" "--service") service "Service to use (can be repeated)"
    (selected-services (cons (string->symbol service) (selected-services)))]
   
   #:args args
   
   (cond
     [(empty? args)
      (printf "AR-Crawl - Production Web Crawler~n")
      (printf "Usage: ar-crawl <command> [options] [args]~n~n")
      (printf "Commands:~n")
      (printf "  crawl <url>       Crawl a single URL~n")
      (printf "  crawl-site <url>  Crawl an entire site following links~n")
      (printf "  health            Check service health~n")
      (printf "  test              Test services~n")
      (printf "  config <cmd>      Manage configuration~n")
      (printf "  services          List available services~n")
       (printf "  monitor           Real-time monitoring~n~n")
      (printf "Use --help with any command for more options.~n")]
     
     [else
      (define command (string->symbol (car args)))
      (define command-args (cdr args))
      
      (case command
        [(crawl)
        (when (empty? command-args)
        (error "URL required for crawl command"))
        (cmd-crawl (car command-args)
        #:config (config-file-path)
        #:services (selected-services)
        #:verbose (verbose-mode)
                    #:output (output-file-param)
                    #:format (output-format-param)
                    #:xpath (xpath-filter-param))]
        
        [(crawl-site)
         (when (empty? command-args)
           (error "URL required for crawl-site command"))

         (cmd-crawl-site (car command-args)
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
         (when (empty? command-args)
           (error "Config command required (init, show, validate)"))
         (cmd-config (string->symbol (car command-args)))]
        
        [(services)
         (cmd-services #:verbose (verbose-mode))]
        
        [(monitor)
         (cmd-monitor #:config (config-file-path))]
        
        [else
         (printf "Unknown command: ~a~n" command)])])))

;; Initialize global parameters
(define verbose-mode (make-parameter #f))
(define config-file-path (make-parameter #f))
(define selected-services (make-parameter '()))

;; Site crawler parameters
(define max-pages (make-parameter 50))
(define max-depth (make-parameter 3))
(define url-pattern (make-parameter ".*"))
(define same-domain-only (make-parameter #t))
(define crawl-delay-ms (make-parameter 1000))
(define output-file-param (make-parameter #f))
(define output-format-param (make-parameter 'json))
(define xpath-filter-param (make-parameter #f))

;; Run main if this file is executed directly
(module+ main
  ;; Register cleanup handler for playwright service
  (plumber-add-flush! (current-plumber)
                      (lambda (handle)
                        (stop-playwright-service)))
  (main))
