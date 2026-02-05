#lang racket

#|
@title{AR-Crawl CLI Tool}
@author{Anuna Research}
@date{2025-01-10}

Command-line interface for the web crawler for agents with service fallbacks.
|#

(require racket/cmdline
         racket/file
         racket/pretty
         racket/system
         racket/port
         racket/hash
         json
         net/url
         net/base64
         "production-crawler.rkt"
         "config-manager.rkt"
         "crawl-service-adaptor.rkt"
         "scraper-interfaces.rkt"
         "site-crawler.rkt"
         "data-formatter.rkt"
         "html-extractor.rkt"
         "utils.rkt"
         "error-handler.rkt"
         "version-info.rkt")

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

;; @function{resolve-symlink}
;; @description{Resolve symlinks to get the real path of a file}
(define (resolve-symlink path-str)
  ;; Try to resolve symlinks using realpath command
  ;; Try common locations for realpath across different systems
  (define realpath-paths '("/bin/realpath" "/usr/bin/realpath"))
  (define realpath-cmd
    (or (findf file-exists? realpath-paths)
        (car realpath-paths)))
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define-values (proc stdout stdin stderr)
      (subprocess #f #f #f realpath-cmd path-str))
    (define output (port->string stdout))
    (close-input-port stdout)
    (close-output-port stdin)
    (close-input-port stderr)
    (subprocess-wait proc)
    (define trimmed (string-trim output))
    (and (non-empty-string? trimmed) (file-exists? trimmed) trimmed)))

;; @function{get-playwright-service-dir}
;; @description{Get the playwright-service directory path}
(define (get-playwright-service-dir)
  ;; Check environment variable first
  (define env-dir (getenv "PLAYWRIGHT_SERVICE_DIR"))
  (cond
    [(and env-dir (directory-exists? env-dir)) env-dir]
    [else
     ;; Get executable path - try both exec-file and run-file
     (define exec-file-path (path->string (find-system-path 'exec-file)))
     (define run-file-path
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (path->string (find-system-path 'run-file))))

     ;; Try to resolve symlinks to get the actual binary location
     (define resolved-path (resolve-symlink exec-file-path))

     ;; Build candidates from multiple possible executable locations
     (define exec-paths
       (filter values (list resolved-path exec-file-path run-file-path)))

     ;; Build all candidate directories from all possible exec paths
     (define home-dir (getenv "HOME"))
     (define candidates
       (append
        ;; Standard install locations (check these first as universal fallbacks)
        (if home-dir
            (list
             ;; Standard install location from install.sh
             (simplify-path (build-path home-dir ".local" "lib" "ar-crawl" "playwright-service")))
            '())
        ;; Locations relative to executable paths
        (apply append
               (for/list ([exec-path (in-list exec-paths)])
                 (define script-dir (path-only (path->complete-path exec-path)))
                 (list
                  ;; For installed binary at ~/.local/bin: check ~/.local/lib/ar-crawl/playwright-service
                  (simplify-path (build-path script-dir ".." "lib" "ar-crawl" "playwright-service"))
                  ;; For dist/ar-crawl-dist/bin/ar-crawl: check ../lib/playwright-service
                  (simplify-path (build-path script-dir ".." "lib" "playwright-service"))
                  ;; For dist/ar-crawl binary: go up twice to reach repo root
                  (simplify-path (build-path script-dir ".." ".." "playwright-service"))
                  ;; For racket src/cli.rkt: go up once
                  (simplify-path (build-path script-dir ".." "playwright-service")))))
        ;; Current working directory fallback
        (list (simplify-path (build-path (current-directory) "playwright-service")))))

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
                  #:dry-run [dry-run #f]
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

  ;; Resolve format
  (define effective-format
    (or format
        (and output-file (detect-format-from-extension output-file))
        'json))

  ;; Dry-run mode: show what would be done and exit
  (when dry-run
    (printf "~n~a~n~n" (color-bold "=== Dry Run: crawl ==="))
    (printf "URL:             ~a~n" url)
    (printf "Services:        ~a~n" effective-services)
    (printf "Output file:     ~a~n" (or output-file "(stdout)"))
    (printf "Output format:   ~a~n" effective-format)
    (when xpath
      (printf "XPath filter:    ~a~n" xpath))
    (when scroll
      (printf "Scroll:          enabled (~a iterations, ~a ms delay)~n" scroll-count scroll-delay))
    (when click-selector
      (printf "Click selector:  ~a (count: ~a)~n" click-selector click-count))
    (printf "PW delay:        ~a ms~n" delay)
    (printf "~nNo crawling will be performed.~n")
    (exit EXIT-SUCCESS))

  (ensure-playwright-if-needed effective-services #:verbose verbose)

  (define crawler (create-crawler-from-config))

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
        (output-results filtered-results output-file effective-format verbose)
        (if verbose
            (printf "Crawl completed successfully~n")
            (eprintf "Done.~n")))
      (eprintf "Crawl failed~n")))

;; @function{cmd-crawl-site}
;; @description{Crawl an entire site with link following}
(define (cmd-crawl-site url
                       #:config [config-file #f]
                       #:output [output-file #f]
                       #:format [format 'json]
                       #:services [services '()]
                       #:verbose [verbose #f]
                       #:dry-run [dry-run #f]
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

  ;; Dry-run mode: show what would be done and exit
  (when dry-run
    (printf "~n~a~n~n" (color-bold "=== Dry Run: crawl-site ==="))
    (printf "Seed URL:        ~a~n" url)
    (printf "Services:        ~a~n" effective-services)
    (printf "Max pages:       ~a~n" max-pages)
    (printf "Max depth:       ~a~n" max-depth)
    (printf "URL pattern:     ~a~n" url-pattern)
    (printf "Same domain:     ~a~n" same-domain)
    (printf "Crawl delay:     ~a ms~n" crawl-delay)
    (printf "Output file:     ~a~n" (or output-file "(stdout)"))
    (printf "Output format:   ~a~n" effective-format)
    (when xpath
      (printf "XPath filter:    ~a~n" xpath))
    (printf "~nNo crawling will be performed.~n")
    (exit EXIT-SUCCESS))

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

;; ============================================================================
;; File Type Filtering Helpers
;; ============================================================================

;; @function{file-type->extensions}
;; @description{Map file type names to their extensions}
(define (file-type->extensions type-name)
  (case (string->symbol type-name)
    [(pdf) '("pdf")]
    [(image) '("jpg" "jpeg" "png" "gif" "svg" "webp" "bmp" "ico")]
    [(video) '("mp4" "webm" "mov" "avi" "mkv" "flv" "wmv")]
    [(audio) '("mp3" "wav" "ogg" "flac" "aac" "m4a")]
    [(archive) '("zip" "tar" "tar.gz" "tgz" "rar" "7z" "bz2")]
    [(document) '("pdf" "doc" "docx" "txt" "rtf" "odt")]
    [(spreadsheet) '("xls" "xlsx" "csv" "ods")]
    [(presentation) '("ppt" "pptx" "odp")]
    [(code) '("js" "py" "rb" "java" "cpp" "c" "go" "rs" "sh")]
    [else '()]))

;; @function{extract-extension-from-url}
;; @description{Extract file extension from URL (handles query params and fragments)}
(define (extract-extension-from-url url-str)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (if (not (string? url-str))
        #f
        (let* ([url-without-query (car (string-split url-str "?"))]
               [url-without-fragment (car (string-split url-without-query "#"))]
               [parts (string-split url-without-fragment ".")])
          (if (> (length parts) 1)
              (string-downcase (last parts))
              #f)))))

;; @function{url-has-extension?}
;; @description{Check if URL ends with one of the given extensions (case-insensitive)}
(define (url-has-extension? url-str extensions)
  (let ([ext (extract-extension-from-url url-str)])
    (and ext (member ext extensions))))

;; @function{extract-files-from-items}
;; @description{Extract files from crawl result items matching extensions}
(define (extract-files-from-items items extensions)
  (apply append
         (for/list ([item items]
                    #:when (hash? item))
           (let ([content (hash-ref item 'content "")]
                 [url (hash-ref item 'url "")])
             ;; Extract all links with href attributes
             (let* ([sxml (html->sxml content)]
                    [link-fn (make-xpath "//a[@href]")]
                    [links (link-fn sxml)])
               (filter-map
                (lambda (link)
                  (let ([href (sxml-attr link 'href)]
                        [text (sxml->text link)])
                    (and href
                         (url-has-extension? href extensions)
                         (hash 'url href
                               'link_text text
                               'extension (extract-extension-from-url href)
                               'source_url url))))
                links))))))

;; ============================================================================
;; URL Resolution Helpers
;; ============================================================================

;; @function{looks-like-url?}
;; @description{Check if a string looks like a URL (for auto-resolution)}
(define (looks-like-url? str)
  (and (string? str)
       (not (string=? str ""))
       (or (string-prefix? str "http://")
           (string-prefix? str "https://")
           (string-prefix? str "//")
           (string-prefix? str "/")
           (regexp-match? #px"^\\.\\.?/" str))))

;; @function{resolve-url}
;; @description{Resolve a URL relative to a base URL}
(define (resolve-url base-url-str url-str)
  (with-handlers ([exn:fail? (lambda (e) url-str)])
    (cond
      ;; Already absolute URL with protocol
      [(or (string-prefix? url-str "http://")
           (string-prefix? url-str "https://"))
       url-str]

      ;; Protocol-relative URL (//example.com/path)
      [(string-prefix? url-str "//")
       (let* ([base (string->url base-url-str)]
              [scheme (url-scheme base)])
         (string-append scheme ":" url-str))]

      ;; Relative URL - use combine-url/relative
      [else
       (let ([base (string->url base-url-str)]
             [rel url-str])
         (url->string (combine-url/relative base rel)))])))

;; @function{resolve-urls-in-hash}
;; @description{Resolve all URL-like values in a hash using source_url as base}
(define (resolve-urls-in-hash item)
  (define base-url (hash-ref item 'source_url #f))
  (if (not base-url)
      item  ; No source_url, can't resolve
      (for/hash ([(key val) (in-hash item)])
        (values key
                (cond
                  ;; Resolve single URL value
                  [(and (not (eq? key 'source_url))
                        (looks-like-url? val))
                   (resolve-url base-url val)]

                  ;; Resolve list of URLs
                  [(and (list? val)
                        (andmap string? val)
                        (andmap looks-like-url? val))
                   (map (lambda (u) (resolve-url base-url u)) val)]

                  ;; Keep value as-is
                  [else val])))))

;; ============================================================================
;; File Download Helpers
;; ============================================================================

;; @function{sanitize-filename}
;; @description{Sanitize filename for safe saving}
(define (sanitize-filename filename)
  (regexp-replace* #px"[^a-zA-Z0-9._-]" filename "_"))

;; @function{extract-filename-from-url}
;; @description{Extract filename from URL}
(define (extract-filename-from-url url-str)
  (with-handlers ([exn:fail? (lambda (e) "download")])
    (let* ([url (string->url url-str)]
           [path-parts (url-path url)]
           [last-part (if (empty? path-parts)
                          (path/param "" '())
                          (last path-parts))]
           [filename (path/param-path last-part)])
      (if (or (string=? filename "") (string-suffix? filename "/"))
          "download"
          (sanitize-filename filename)))))

;; @function{download-file}
;; @description{Download a file from URL to local path}
(define (download-file url-str dest-path #:verbose [verbose #f])
  (with-handlers ([exn:fail? (lambda (e)
                               (when verbose
                                 (printf "Error downloading ~a: ~a~n" url-str (exn-message e)))
                               #f)])
    (when verbose
      (printf "Downloading: ~a~n" url-str))

    ;; Use net/url library for simple HTTP download
    (define in-port (get-pure-port (string->url url-str)))
    (call-with-output-file dest-path
      (lambda (out-port)
        (copy-port in-port out-port))
      #:exists 'replace)
    (close-input-port in-port)
    #t))

;; @function{download-files-from-results}
;; @description{Download files from extraction results}
(define (download-files-from-results results download-dir
                                     #:rate-limit [rate-limit-ms 0]
                                     #:skip-existing [skip-existing #f]
                                     #:verbose [verbose #f])
  (make-directory* download-dir)

  (define total (length results))
  (define downloaded 0)
  (define skipped 0)
  (define failed 0)

  (for ([result results]
        [idx (in-naturals 1)])
    (let* ([url (hash-ref result 'url #f)]
           [filename (if url (extract-filename-from-url url) #f)]
           [dest-path (if filename (build-path download-dir filename) #f)])

      (when (and url filename dest-path)
        (cond
          [(and skip-existing (file-exists? dest-path))
           (when verbose
             (printf "[~a/~a] Skipping (exists): ~a~n" idx total filename))
           (set! skipped (+ skipped 1))]

          [else
           (when verbose
             (printf "[~a/~a] Downloading: ~a~n" idx total filename))

           (if (download-file url dest-path #:verbose verbose)
               (set! downloaded (+ downloaded 1))
               (begin
                 (set! failed (+ failed 1))
                 (when verbose
                   (printf "Failed to download: ~a~n" url))))

           ;; Rate limiting
           (when (and (> rate-limit-ms 0) (< idx total))
             (sleep (/ rate-limit-ms 1000.0)))]))))

  (when verbose
    (printf "~nDownload complete:~n")
    (printf "  Downloaded: ~a~n" downloaded)
    (printf "  Skipped: ~a~n" skipped)
    (printf "  Failed: ~a~n" failed))

  (hash 'downloaded downloaded
        'skipped skipped
        'failed failed
        'total total))

;; @function{cmd-extract}
;; @description{Extract structured data from crawl results using XPath or file type filtering}
(define (cmd-extract input-file
                     #:xpath [xpath-map-str #f]
                     #:parent [parent-xpath #f]
                     #:fields [field-xpaths-str #f]
                     #:file-types [file-types '()]
                     #:extensions [extensions '()]
                     #:output [output-file #f]
                     #:format [format 'json]
                     #:resolve-urls [resolve-urls #f]
                     #:download [download #f]
                     #:download-dir [download-dir "downloads"]
                     #:rate-limit [rate-limit 0]
                     #:skip-existing [skip-existing #f]
                     #:verbose [verbose #f])

  ;; Determine extraction mode
  (define file-type-mode? (or (not (empty? file-types)) (not (empty? extensions))))

  ;; Build extensions list from file types
  (define all-extensions
    (if file-type-mode?
        (remove-duplicates
         (append extensions
                 (apply append (map file-type->extensions file-types))))
        '()))

  ;; Parse xpath-map from JSON string or build from parent/fields
  (define xpath-map
    (cond
      [file-type-mode? #f]  ;; No XPath map for file type mode

      [xpath-map-str
       ;; Parse JSON object: {"name": "//h1", "price": "//span[@class='price']"}
       (with-handlers ([exn:fail? (lambda (e)
                                    (let ([details (json-parse-error-details e xpath-map-str)])
                                      (report-error-and-exit 'json-parse-error
                                                            "Failed to parse --xpath-map JSON"
                                                            details)))])
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
                                    (let ([details (json-parse-error-details e field-xpaths-str)])
                                      (report-error-and-exit 'json-parse-error
                                                            "Failed to parse --fields JSON"
                                                            details)))])
         (let ([parsed (string->jsexpr field-xpaths-str)])
           (for/hash ([(k v) (in-hash parsed)])
             (values (if (string? k) (string->symbol k) k) v))))]

      [else
       (printf "Error: Must provide --fields, --xpath-map, --file-type, --extension, or both --parent and --fields~n")
       (printf "~nUsage:~n")
       (printf "  ar-crawl extract <file> --fields '{\"title\": \"//h1\", \"body\": \"//p\"}'~n")
       (printf "  ar-crawl extract <file> --file-type pdf~n")
       (printf "  ar-crawl extract <file> --extension pdf --extension docx~n")
       (printf "  ar-crawl extract <file> --parent \"//div[@class='product']\" --fields '{\"name\": \".//h2\", \"price\": \".//span\"}'~n")
       (exit 1)]))

  (when verbose
    (printf "Extracting from: ~a~n" input-file)
    (when (not file-type-mode?)
      (printf "XPath map: ~a~n" xpath-map))
    (when file-type-mode?
      (printf "File types: ~a~n" file-types)
      (printf "Extensions: ~a~n" all-extensions)))

  ;; Resolve format
  (define effective-format
    (or format
        (and output-file (detect-format-from-extension output-file))
        'json))

  ;; Set output format for error handler
  (current-output-format effective-format)

  ;; Load input file - detect SQLite by extension
  (define items
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to load file: ~a~n" (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
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
      ;; File type filtering mode
      [file-type-mode?
       (extract-files-from-items items all-extensions)]

      ;; Item extraction with parent + fields
      [(and xpath-map (hash-ref xpath-map 'parent #f))
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

  ;; Apply URL resolution if requested
  (define final-results
    (if resolve-urls
        (begin
          (when verbose
            (printf "Resolving URLs to absolute form...~n"))
          (map resolve-urls-in-hash results))
        results))

  (when verbose
    (printf "Extracted ~a records~n" (length final-results)))

  ;; Download files if requested
  (define download-stats
    (if download
        (begin
          (when verbose
            (printf "~nDownloading files to: ~a~n" download-dir))
          (download-files-from-results final-results download-dir
                                       #:rate-limit rate-limit
                                       #:skip-existing skip-existing
                                       #:verbose verbose))
        #f))

  ;; Output results
  (define output-data
    (hash 'data final-results
          'metadata (if download-stats
                        (hash 'source input-file
                              'xpath_map xpath-map
                              'record_count (length final-results)
                              'urls_resolved resolve-urls
                              'download_stats download-stats)
                        (hash 'source input-file
                              'xpath_map xpath-map
                              'record_count (length final-results)
                              'urls_resolved resolve-urls))
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
                                 (eprintf "~a: failed to load file: ~a~n" (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
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
    (eprintf "~a: no items found in ~a~n" (color-error "error") input-file)
    (exit EXIT-ERROR))

  (when (>= index (length items))
    (eprintf "~a: index ~a out of range (file has ~a items, valid range: 0-~a)~n"
             (color-error "error") index (length items) (- (length items) 1))
    (exit EXIT-ERROR))

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
                   #:verbose [verbose #f]
                   #:format [format #f])

  ;; Load and analyze stats
  (define stats
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to load database: ~a~n" (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (analyze-crawl-stats db-file)))

  (if (eq? format 'json)
      (displayln (jsexpr->string stats #:encode 'control))
      (begin
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

        (let ([status-codes (hash-ref stats 'status_codes)])
          (when (not (hash-empty? status-codes))
            (printf "--- Status Codes ---~n")
            (for ([(code count) (in-hash status-codes)])
              (printf "  ~a:                     ~a~n" code count))
            (newline)))

        (let ([top-domains (hash-ref stats 'top_domains)])
          (when (not (hash-empty? top-domains))
            (printf "--- Top Domains ---~n")
            (for ([(domain count) (in-hash top-domains)])
              (printf "  ~a:                    ~a~n" domain count))
            (newline)))

        (printf "Note: Use 'ar-crawl sample ~a' to view sample HTML content.~n" db-file)
        (printf "      Use 'ar-crawl extract ~a --fields \"{...}\"' to extract data.~n~n" db-file))))

;; @function{cmd-session}
;; @description{Start an interactive session for LLM agents to drive Playwright}
;; Input format: JSON objects matching Playwright API actions
;; Example: {"type": "goto", "url": "https://example.com"}
;; Example: {"type": "click", "selector": "#button"}
;; Special commands: state, commit, exit
(define (cmd-session #:verbose [verbose #f])

  ;; Start playwright service
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Starting interactive session...~n"))

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Create session
  (define session-id
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to create session: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (post-pure-port
                    (string->url (string-append base-url "/session/create"))
                    (string->bytes/utf-8 "{}")
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      (hash-ref data 'sessionId)))

  ;; Output session info as JSON for LLM consumption
  (displayln (jsexpr->string (hash 'sessionId session-id 'status "ready")))
  (flush-output)

  ;; REPL loop - accepts JSON actions
  (let loop ()
    (define input (read-line))

    (unless (eof-object? input)
      (define cmd-str (string-trim input))

      (cond
        [(string=? cmd-str "") (loop)]

        ;; Exit without saving
        [(member cmd-str '("exit" "quit"))
         (with-handlers ([exn:fail? void])
           (define resp (delete-pure-port
                         (string->url (format "~a/session/~a" base-url session-id))))
           (close-input-port resp))
         (displayln (jsexpr->string (hash 'status "closed")))
         (void)]

        ;; Get current state with filtering options (consistent with extract command)
        ;; state                                      -> minimal (just url/title)
        ;; state --actions                            -> clickable elements
        ;; state --forms                              -> form inputs
        ;; state --fields '{"name": "//h1"}'          -> extract fields by XPath
        ;; state --parent "//div" --fields '{"x":"./a"}' -> extract repeated items
        ;; state --html                               -> include raw HTML
        [(or (string=? cmd-str "state") (string-prefix? cmd-str "state "))
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (loop))])
           ;; Parse --fields and --parent options (consistent with extract command)
           (define fields-match (regexp-match #px"--fields\\s+'([^']+)'" cmd-str))
           (define parent-match (regexp-match #px"--parent\\s+\"([^\"]+)\"" cmd-str))

           (cond
             ;; XPath extraction with --fields (and optional --parent)
             [fields-match
              (define fields-json (cadr fields-match))
              (define parent-xpath (and parent-match (cadr parent-match)))

              ;; Fetch HTML from session
              (define state-url (format "~a/session/~a/state?html=true&view=minimal" base-url session-id))
              (define resp (get-pure-port (string->url state-url)))
              (define data (string->jsexpr (port->string resp)))
              (close-input-port resp)

              (define html (hash-ref data 'html ""))
              (define url (hash-ref data 'url ""))
              (define title (hash-ref data 'title ""))

              ;; Parse fields JSON
              (define field-xpaths
                (with-handlers ([exn:fail? (lambda (e)
                                             (displayln (jsexpr->string (hash 'error (format "Invalid JSON: ~a" (exn-message e)))))
                                             #f)])
                  (string->jsexpr fields-json)))

              (when field-xpaths
                (define results
                  (if parent-xpath
                      ;; Extract repeated items using parent + fields
                      (extract-items html parent-xpath field-xpaths)
                      ;; Extract single fields
                      (extract-by-xpaths html field-xpaths)))

                (displayln (jsexpr->string
                            (hash 'url url
                                  'title title
                                  'results results)))
                (flush-output))
              (loop)]

             ;; Server-side filtering (--actions, --forms, etc.)
             [else
              (define params '())
              (when (string-contains? cmd-str "--actions")
                (set! params (cons "view=actions" params)))
              (when (string-contains? cmd-str "--forms")
                (set! params (cons "view=forms" params)))
              (when (string-contains? cmd-str "--full")
                (set! params (cons "view=full" params)))
              (when (string-contains? cmd-str "--html")
                (set! params (cons "html=true" params)))

              (define query-string (if (empty? params) "" (string-append "?" (string-join params "&"))))
              (define state-url (format "~a/session/~a/state~a" base-url session-id query-string))
              (define resp (get-pure-port (string->url state-url)))
              (displayln (port->string resp))
              (close-input-port resp)
              (flush-output)
              (loop)]))]

        ;; Commit session and output recording
        [(or (string=? cmd-str "commit") (string-prefix? cmd-str "commit "))
         (define parts (string-split cmd-str))
         (define output-file (if (> (length parts) 1) (list-ref parts 1) #f))

         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (void))])
           (define resp (post-pure-port
                         (string->url (format "~a/session/~a/commit" base-url session-id))
                         #""
                         (list "Content-Type: application/json")))
           (define data (string->jsexpr (port->string resp)))
           (close-input-port resp)

           (define recording (hash-ref data 'recording (hash)))

           (if output-file
               (begin
                 (call-with-output-file output-file
                   (lambda (port)
                     (write-json recording port #:indent 2))
                   #:exists 'replace)
                 (displayln (jsexpr->string (hash 'status "committed" 'file output-file))))
               (displayln (jsexpr->string (hash 'status "committed" 'recording recording)))))
         (void)]

        ;; JSON action - parse and execute
        [(string-prefix? cmd-str "{")
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'success #f 'error (exn-message e))))
                                      (flush-output)
                                      (loop))])
           (define action (string->jsexpr cmd-str))
           (define resp (post-pure-port
                         (string->url (format "~a/session/~a/action" base-url session-id))
                         (string->bytes/utf-8 cmd-str)
                         (list "Content-Type: application/json")))
           (displayln (port->string resp))
           (close-input-port resp)
           (flush-output)
           (loop))]

        ;; Help (for debugging)
        [(string=? cmd-str "help")
         (displayln (jsexpr->string
                     (hash 'commands
                           (hash 'actions "Send JSON objects matching Playwright API"
                                 'state "Get page state: state [--actions|--forms|--fields '...']"
                                 'commit "End session and return recording JSON"
                                 'exit "Close session without saving")
                           'stateOptions (hash
                                          '--actions "clickable elements only"
                                          '--forms "form inputs only"
                                          '--fields "XPath extraction (same as extract cmd)"
                                          '--parent "parent XPath for repeated items")
                           'examples '("state --fields '{\"title\": \"//h1\"}'"
                                       "state --fields '{\"links\": \"//a/@href\"}'"
                                       "state --parent \"//tr\" --fields '{\"name\": \".//td[1]\", \"price\": \".//td[2]\"}'")
                           'actionTypes '("goto" "click" "fill" "type" "hover" "press" "scroll"
                                          "waitForSelector" "evaluate" "screenshot" "goBack"
                                          "goForward" "reload" "selectOption" "check" "uncheck"
                                          "focus" "dblclick" "setViewport" "customStep"))))
         (loop)]

        ;; Unknown command
        [else
         (displayln (jsexpr->string (hash 'error "Unknown command. Send JSON action or use: state, commit, exit, help")))
         (flush-output)
         (loop)]))))

;; ============================================================================
;; Android Emulator Commands
;; ============================================================================

;; @function{cmd-android-devices}
;; @description{List connected Android devices via ADB}
(define (cmd-android-devices #:verbose [verbose #f])
  (start-playwright-service #:verbose verbose)
  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  (with-handlers ([exn:fail? (lambda (e)
                               (displayln (jsexpr->string (hash 'error (exn-message e))))
                               (exit EXIT-ERROR))])
    (define resp (get-pure-port
                  (string->url (string-append base-url "/android/devices"))))
    (define data (string->jsexpr (port->string resp)))
    (close-input-port resp)
    (displayln (jsexpr->string data))))

;; @function{cmd-android-session}
;; @description{Start an interactive Android automation session}
(define (cmd-android-session device-serial #:verbose [verbose #f])
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Starting Android session on device: ~a~n" device-serial))

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Create Android session
  (define session-id
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to create Android session: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (post-pure-port
                    (string->url (string-append base-url "/android/session/create"))
                    (string->bytes/utf-8 (jsexpr->string (hash 'serial device-serial)))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)

      ;; Check for error in response
      (when (hash-has-key? data 'error)
        (eprintf "~a: ~a~n" (color-error "error") (hash-ref data 'error))
        (exit EXIT-ERROR))

      (hash-ref data 'sessionId)))

  ;; Output session info as JSON
  (displayln (jsexpr->string (hash 'sessionId session-id
                                   'device device-serial
                                   'status "ready")))
  (flush-output)

  ;; REPL loop - accepts JSON actions
  (let loop ()
    (define input (read-line))

    (unless (eof-object? input)
      (define cmd-str (string-trim input))

      (cond
        [(string=? cmd-str "") (loop)]

        ;; Exit without saving
        [(member cmd-str '("exit" "quit"))
         (with-handlers ([exn:fail? void])
           (define resp (delete-pure-port
                         (string->url (format "~a/android/session/~a" base-url session-id))))
           (close-input-port resp))
         (displayln (jsexpr->string (hash 'status "closed")))
         (void)]

        ;; Get current session state
        [(or (string=? cmd-str "state") (string-prefix? cmd-str "state "))
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (loop))])
           (define state-url (format "~a/android/session/~a/state" base-url session-id))
           (define resp (get-pure-port (string->url state-url)))
           (displayln (port->string resp))
           (close-input-port resp)
           (flush-output)
           (loop))]

        ;; Take screenshot
        [(or (string=? cmd-str "screenshot") (string-prefix? cmd-str "screenshot "))
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (loop))])
           (define parts (string-split cmd-str))
           (define output-file (if (> (length parts) 1) (list-ref parts 1) #f))

           (define screenshot-url
             (if output-file
                 (format "~a/android/session/~a/screenshot?path=~a" base-url session-id output-file)
                 (format "~a/android/session/~a/screenshot" base-url session-id)))

           (define resp (get-pure-port (string->url screenshot-url)))

           (if output-file
               (begin
                 (displayln (port->string resp))
                 (close-input-port resp))
               ;; Binary data - report size
               (let ([data (port->bytes resp)])
                 (close-input-port resp)
                 (displayln (jsexpr->string (hash 'size (bytes-length data)
                                                  'hint "Use 'screenshot <file.png>' to save")))))
           (flush-output)
           (loop))]

        ;; List WebViews
        [(string=? cmd-str "webviews")
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (loop))])
           (define result
             (let ()
               (define resp (post-pure-port
                             (string->url (format "~a/android/session/~a/action" base-url session-id))
                             (string->bytes/utf-8 (jsexpr->string (hash 'type "listWebViews")))
                             (list "Content-Type: application/json")))
               (define data (string->jsexpr (port->string resp)))
               (close-input-port resp)
               data))
           (displayln (jsexpr->string result))
           (flush-output)
           (loop))]

        ;; Shell command
        [(string-prefix? cmd-str "shell ")
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (loop))])
           (define command (substring cmd-str 6))  ; Remove "shell "
           (define resp (post-pure-port
                         (string->url (format "~a/android/session/~a/shell" base-url session-id))
                         (string->bytes/utf-8 (jsexpr->string (hash 'command command)))
                         (list "Content-Type: application/json")))
           (displayln (port->string resp))
           (close-input-port resp)
           (flush-output)
           (loop))]

        ;; Commit session and output recording
        [(or (string=? cmd-str "commit") (string-prefix? cmd-str "commit "))
         (define parts (string-split cmd-str))
         (define output-file (if (> (length parts) 1) (list-ref parts 1) #f))

         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'error (exn-message e))))
                                      (void))])
           (define resp (post-pure-port
                         (string->url (format "~a/android/session/~a/commit" base-url session-id))
                         (string->bytes/utf-8 "{}")
                         (list "Content-Type: application/json")))
           (define recording (string->jsexpr (port->string resp)))
           (close-input-port resp)

           (if output-file
               (begin
                 (call-with-output-file output-file
                   (lambda (port)
                     (write-json recording port #:indent 2))
                   #:exists 'replace)
                 (displayln (jsexpr->string (hash 'status "committed" 'file output-file))))
               (displayln (jsexpr->string (hash 'status "committed" 'recording recording)))))
         (void)]

        ;; JSON action - parse and execute
        [(string-prefix? cmd-str "{")
         (with-handlers ([exn:fail? (lambda (e)
                                      (displayln (jsexpr->string (hash 'success #f 'error (exn-message e))))
                                      (flush-output)
                                      (loop))])
           (define action (string->jsexpr cmd-str))
           (define resp (post-pure-port
                         (string->url (format "~a/android/session/~a/action" base-url session-id))
                         (string->bytes/utf-8 cmd-str)
                         (list "Content-Type: application/json")))
           (displayln (port->string resp))
           (close-input-port resp)
           (flush-output)
           (loop))]

        ;; Help
        [(string=? cmd-str "help")
         (displayln (jsexpr->string
                     (hash 'commands
                           (hash 'actions "Send JSON objects for Android actions"
                                 'state "Get current session state"
                                 'screenshot "Take screenshot: screenshot [file.png]"
                                 'webviews "List active WebViews"
                                 'shell "Run shell command: shell <command>"
                                 'commit "End session and return recording JSON"
                                 'exit "Close session without saving")
                           'actionTypes
                           (hash 'tap "{\"type\": \"tap\", \"selector\": \"text=Button\"}"
                                 'longTap "{\"type\": \"longTap\", \"selector\": \"text=Item\"}"
                                 'swipe "{\"type\": \"swipe\", \"selector\": \"res=list\", \"direction\": \"up\", \"percent\": 50}"
                                 'scroll "{\"type\": \"scroll\", \"selector\": \"res=view\", \"direction\": \"down\"}"
                                 'fill "{\"type\": \"fill\", \"selector\": \"res=input\", \"text\": \"hello\"}"
                                 'press "{\"type\": \"press\", \"key\": \"Enter\"}"
                                 'launchBrowser "{\"type\": \"launchBrowser\", \"url\": \"https://...\"}")
                           'selectors
                           (hash 'resourceId "res=com.example:id/button"
                                 'text "text=Submit"
                                 'description "desc=Menu button"
                                 'class "class=android.widget.Button"
                                 'compound "res=btn&&text=OK"))))
         (loop)]

        ;; Unknown command
        [else
         (displayln (jsexpr->string (hash 'error "Unknown command. Send JSON action or use: state, screenshot, shell, commit, exit, help")))
         (flush-output)
         (loop)]))))

;; @function{cmd-android-replay}
;; @description{Replay an Android recording on a device}
(define (cmd-android-replay recording-file
                            #:device [device #f]
                            #:speed [speed 1.0]
                            #:screenshots [screenshots #f]
                            #:verbose [verbose #f])
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Replaying Android recording: ~a~n" recording-file))

  ;; Load recording file
  (define recording
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to read recording file: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (call-with-input-file recording-file
        (lambda (port) (read-json port)))))

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Replay the recording
  (with-handlers ([exn:fail? (lambda (e)
                               (displayln (jsexpr->string (hash 'error (exn-message e))))
                               (exit EXIT-ERROR))])
    (define request-body
      (hash 'recording recording
            'serial device
            'speed speed
            'screenshotPerStep (if screenshots #t #f)))

    (define resp (post-pure-port
                  (string->url (string-append base-url "/android/replay"))
                  (string->bytes/utf-8 (jsexpr->string request-body))
                  (list "Content-Type: application/json")))
    (define result (string->jsexpr (port->string resp)))
    (close-input-port resp)
    (displayln (jsexpr->string result))))

;; @function{parse-android-args}
;; @description{Parse arguments for android command}
(define (parse-android-args args)
  (command-line
   #:program "ar-crawl android"
   #:argv args
   #:args remaining
   remaining))

;; @function{parse-android-session-args}
;; @description{Parse arguments for android session subcommand}
(define (parse-android-session-args args)
  (command-line
   #:program "ar-crawl android session"
   #:argv args
   #:args remaining
   remaining))

;; @function{parse-android-replay-args}
;; @description{Parse arguments for android replay subcommand}
(define android-replay-device (make-parameter #f))
(define android-replay-speed (make-parameter 1.0))
(define android-replay-screenshots (make-parameter #f))

(define (parse-android-replay-args args)
  (command-line
   #:program "ar-crawl android replay"
   #:argv args
   #:once-each
   [("-d" "--device") serial "Target device serial" (android-replay-device serial)]
   [("-s" "--speed") spd "Replay speed multiplier" (android-replay-speed (string->number spd))]
   [("--screenshots") "Capture screenshot per step" (android-replay-screenshots #t)]
   #:args remaining
   remaining))

;; @function{parse-android-baseline-args}
;; @description{Parse arguments for android baseline subcommand}
(define android-baseline-device (make-parameter #f))
(define android-baseline-output (make-parameter #f))
(define android-baseline-name (make-parameter #f))
(define android-baseline-apk (make-parameter #f))
(define android-baseline-pkg (make-parameter #f))
(define android-baseline-wait (make-parameter 2000))

(define (parse-android-baseline-args args)
  (command-line
   #:program "ar-crawl android baseline"
   #:argv args
   #:once-each
   [("-d" "--device") serial "Target device serial" (android-baseline-device serial)]
   [("-o" "--output") file "Output file path for baseline image" (android-baseline-output file)]
   [("-n" "--name") name "Baseline name/identifier" (android-baseline-name name)]
   [("--apk") path "APK file to install before capturing" (android-baseline-apk path)]
   [("-p" "--pkg") pkg "Package name to launch" (android-baseline-pkg pkg)]
   [("-w" "--wait") ms "Wait time (ms) after launch (default: 2000)" (android-baseline-wait (string->number ms))]
   #:args remaining
   remaining))

;; @function{parse-android-test-args}
;; @description{Parse arguments for android test subcommand}
(define android-test-device (make-parameter #f))
(define android-test-pkg (make-parameter #f))
(define android-test-stop-on-failure (make-parameter #t))
(define android-test-step-delay (make-parameter 500))
(define android-test-output (make-parameter #f))

(define (parse-android-test-args args)
  (command-line
   #:program "ar-crawl android test"
   #:argv args
   #:once-each
   [("-d" "--device") serial "Target device serial" (android-test-device serial)]
   [("-p" "--pkg") pkg "Package name (optional, for crash detection)" (android-test-pkg pkg)]
   [("--continue") "Continue running after failures" (android-test-stop-on-failure #f)]
   [("--delay") ms "Delay between steps in ms (default: 500)" (android-test-step-delay (string->number ms))]
   [("-o" "--output") file "Output results file (JSON)" (android-test-output file)]
   #:args remaining
   remaining))

;; @function{parse-android-verify-args}
;; @description{Parse arguments for android verify subcommand}
(define android-verify-device (make-parameter #f))
(define android-verify-baseline (make-parameter #f))
(define android-verify-script (make-parameter #f))
(define android-verify-pkg (make-parameter #f))
(define android-verify-threshold (make-parameter 0))
(define android-verify-wait (make-parameter 3000))
(define android-verify-output (make-parameter #f))
(define android-verify-continue (make-parameter #f))
(define android-verify-skip-install (make-parameter #f))

(define (parse-android-verify-args args)
  (command-line
   #:program "ar-crawl android verify"
   #:argv args
   #:once-each
   [("-d" "--device") serial "Target device serial" (android-verify-device serial)]
   [("-b" "--baseline") file "Baseline screenshot file to compare against" (android-verify-baseline file)]
   [("-s" "--script") file "Test script file (JSON)" (android-verify-script file)]
   [("-p" "--pkg") pkg "Package name (required with --skip-install)" (android-verify-pkg pkg)]
   [("-t" "--threshold") pct "Visual diff threshold percentage (default: 0)" (android-verify-threshold (string->number pct))]
   [("-w" "--wait") ms "Wait time (ms) after launch before comparison (default: 3000)" (android-verify-wait (string->number ms))]
   [("-o" "--output") file "Output results file (JSON)" (android-verify-output file)]
   [("--continue") "Continue even if visual diff fails" (android-verify-continue #t)]
   [("--skip-install") "Skip APK install, connect to running app (requires --pkg)" (android-verify-skip-install #t)]
   #:args remaining
   remaining))

;; @function{cmd-android-baseline}
;; @description{Capture baseline screenshots for visual regression testing}
(define (cmd-android-baseline #:device [device #f]
                              #:output [output-file #f]
                              #:name [baseline-name #f]
                              #:apk [apk-path #f]
                              #:pkg [pkg-name #f]
                              #:wait [wait-time 2000]
                              #:verbose [verbose #f])
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Starting Android baseline capture...~n"))

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Get devices
  (define devices-result
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to get Android devices: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (get-pure-port
                    (string->url (string-append base-url "/android/devices"))))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  (define devices (hash-ref devices-result 'devices '()))

  (when (null? devices)
    (eprintf "~a: no Android devices found~n" (color-error "error"))
    (eprintf "Connect a device or start an emulator, then run 'adb devices' to verify.~n")
    (exit EXIT-ERROR))

  ;; Select device
  (define target-device
    (if device
        (findf (lambda (d) (equal? (hash-ref d 'serial) device)) devices)
        (car devices)))

  (unless target-device
    (eprintf "~a: device not found: ~a~n" (color-error "error") device)
    (eprintf "Available devices:~n")
    (for ([d (in-list devices)])
      (eprintf "  ~a (~a)~n" (hash-ref d 'serial) (hash-ref d 'model "")))
    (exit EXIT-ERROR))

  (define serial (hash-ref target-device 'serial))
  (when verbose
    (printf "Using device: ~a (~a)~n" serial (hash-ref target-device 'model "")))

  ;; Create session
  (define session-id
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to create Android session: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (post-pure-port
                    (string->url (string-append base-url "/android/session/create"))
                    (string->bytes/utf-8 (jsexpr->string (hash 'serial serial)))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)

      (when (hash-has-key? data 'error)
        (eprintf "~a: ~a~n" (color-error "error") (hash-ref data 'error))
        (exit EXIT-ERROR))

      (hash-ref data 'sessionId)))

  (when verbose
    (printf "Session created: ~a~n" session-id))

  ;; Helper to execute session actions
  (define (session-action action)
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: action failed: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (hash 'error (exn-message e)))])
      (define resp (post-pure-port
                    (string->url (format "~a/android/session/~a/action" base-url session-id))
                    (string->bytes/utf-8 (jsexpr->string action))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  ;; Track effective package name (may be set from APK install)
  (define effective-pkg pkg-name)

  ;; Install APK if provided
  (when apk-path
    (when verbose
      (printf "Installing APK: ~a~n" apk-path))
    (define install-result (session-action (hash 'type "install"
                                                  'apk apk-path
                                                  'verify #t)))
    (when (hash-ref install-result 'error #f)
      (eprintf "~a: APK install failed: ~a~n"
               (color-error "error") (hash-ref install-result 'error))
      ;; Close session before exit
      (with-handlers ([exn:fail? void])
        (define resp (delete-pure-port
                      (string->url (format "~a/android/session/~a" base-url session-id))))
        (close-input-port resp))
      (exit EXIT-ERROR))

    (when (hash-ref install-result 'pkg #f)
      (set! effective-pkg (hash-ref install-result 'pkg))
      (when verbose
        (printf "Installed package: ~a~n" effective-pkg))))

  ;; Launch app if package specified
  (when effective-pkg
    (when verbose
      (printf "Launching: ~a~n" effective-pkg))
    (define launch-result (session-action (hash 'type "launchApp" 'pkg effective-pkg)))
    (when (hash-ref launch-result 'error #f)
      (eprintf "~a: launch failed: ~a~n"
               (color-error "warning") (hash-ref launch-result 'error)))

    (when verbose
      (printf "Waiting ~a ms for app to settle...~n" wait-time))
    (sleep (/ wait-time 1000.0)))

  ;; Generate baseline name
  (define name (or baseline-name
                   (format "baseline-~a-~a"
                           (or effective-pkg "screen")
                           (current-seconds))))

  (when verbose
    (printf "Capturing baseline: ~a~n" name))

  ;; Capture baseline
  (define baseline-result
    (session-action (hash 'type "captureBaseline"
                          'name name
                          'path output-file
                          'metadata (hash 'pkg effective-pkg
                                          'capturedAt (current-seconds)))))

  (when (hash-ref baseline-result 'error #f)
    (eprintf "~a: baseline capture failed: ~a~n"
             (color-error "error") (hash-ref baseline-result 'error))
    ;; Close session before exit
    (with-handlers ([exn:fail? void])
      (define resp (delete-pure-port
                    (string->url (format "~a/android/session/~a" base-url session-id))))
      (close-input-port resp))
    (exit EXIT-ERROR))

  ;; Close session
  (with-handlers ([exn:fail? void])
    (define resp (delete-pure-port
                  (string->url (format "~a/android/session/~a" base-url session-id))))
    (close-input-port resp))

  ;; Output result
  (define result-data
    (hash 'status "captured"
          'name name
          'size (hash-ref baseline-result 'size 0)
          'device serial
          'pkg effective-pkg))

  (when output-file
    (set! result-data (hash-set result-data 'file output-file)))

  (displayln (jsexpr->string result-data)))

;; @function{cmd-android-test}
;; @description{Run test scripts on Android devices}
(define (cmd-android-test script-file
                          #:device [device #f]
                          #:pkg [pkg-name #f]
                          #:stop-on-failure [stop-on-failure #t]
                          #:step-delay [step-delay 500]
                          #:output [output-file #f]
                          #:verbose [verbose #f])
  ;; Read script file
  (unless (file-exists? script-file)
    (eprintf "~a: script file not found: ~a~n" (color-error "error") script-file)
    (exit EXIT-ERROR))

  (define script-content (file->string script-file))
  (define script-json
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: invalid JSON in script file: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (string->jsexpr script-content)))

  ;; Start service
  (start-playwright-service #:verbose verbose)

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Get devices
  (define devices-result
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to get Android devices: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (get-pure-port
                    (string->url (string-append base-url "/android/devices"))))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  (define devices (hash-ref devices-result 'devices '()))

  (when (null? devices)
    (eprintf "~a: no Android devices found~n" (color-error "error"))
    (eprintf "Connect a device or start an emulator, then run 'adb devices' to verify.~n")
    (exit EXIT-ERROR))

  ;; Select device
  (define target-device
    (if device
        (findf (lambda (d) (equal? (hash-ref d 'serial) device)) devices)
        (car devices)))

  (unless target-device
    (eprintf "~a: device not found: ~a~n" (color-error "error") device)
    (eprintf "Available devices:~n")
    (for ([d (in-list devices)])
      (eprintf "  ~a (~a)~n" (hash-ref d 'serial) (hash-ref d 'model "")))
    (exit EXIT-ERROR))

  (define serial (hash-ref target-device 'serial))
  (eprintf "Using device: ~a (~a)~n" serial (hash-ref target-device 'model ""))

  ;; Create session
  (define session-id
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to create Android session: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (post-pure-port
                    (string->url (string-append base-url "/android/session/create"))
                    (string->bytes/utf-8 (jsexpr->string (hash 'serial serial)))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)

      (when (hash-has-key? data 'error)
        (eprintf "~a: ~a~n" (color-error "error") (hash-ref data 'error))
        (exit EXIT-ERROR))

      (hash-ref data 'sessionId)))

  (eprintf "Session: ~a~n" session-id)

  ;; Helper to cleanup session
  (define (cleanup)
    (with-handlers ([exn:fail? void])
      (define resp (delete-pure-port
                    (string->url (format "~a/android/session/~a" base-url session-id))))
      (close-input-port resp)))

  ;; Helper to execute session actions
  (define (session-action action)
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: action failed: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (hash 'error (exn-message e)))])
      (define resp (post-pure-port
                    (string->url (format "~a/android/session/~a/action" base-url session-id))
                    (string->bytes/utf-8 (jsexpr->string action))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  (define test-result #f)

  (with-handlers ([exn:fail? (lambda (e)
                               (cleanup)
                               (eprintf "~a: ~a~n" (color-error "error") (exn-message e))
                               (exit EXIT-ERROR))])

    ;; Prepare test request
    (define test-request
      (if (hash-has-key? script-json 'steps)
          ;; Script is already in test format
          (hash-set* script-json
                     'type "runTest"
                     'stopOnFailure stop-on-failure
                     'stepDelay step-delay)
          ;; Wrap steps array in test format
          (hash 'type "runTest"
                'name (path->string (file-name-from-path script-file))
                'steps script-json
                'stopOnFailure stop-on-failure
                'stepDelay step-delay)))

    (eprintf "Running test: ~a~n" (hash-ref test-request 'name "unnamed"))
    (eprintf "Steps: ~a~n" (length (hash-ref test-request 'steps '())))

    ;; Run test
    (set! test-result (session-action test-request))

    ;; Check for crashes if package specified
    (when pkg-name
      (define crash-result (session-action (hash 'type "checkCrash" 'pkg pkg-name)))
      (when (and test-result (hash? test-result))
        (set! test-result (hash-set test-result 'crashCheck crash-result))))

    ;; Cleanup
    (cleanup))

  ;; Output results
  (define test-info (if (hash? test-result) (hash-ref test-result 'test (hash)) (hash)))
  (define passed (hash-ref test-info 'passed #f))
  (define steps-executed (hash-ref test-info 'stepsExecuted 0))
  (define steps-passed (hash-ref test-info 'stepsPassed 0))

  (eprintf "~n=== Test Results ===~n")
  (eprintf "Status: ~a~n" (if passed "PASSED" "FAILED"))
  (eprintf "Steps: ~a/~a passed~n" steps-passed steps-executed)

  (when (and (not passed) (hash-ref test-info 'failedStep #f))
    (eprintf "Failed at step: ~a~n" (hash-ref test-info 'failedStep))
    (eprintf "Reason: ~a~n" (hash-ref test-info 'failureReason "")))

  (eprintf "Duration: ~ams~n" (hash-ref test-info 'duration 0))

  ;; Write output file if specified
  (when output-file
    (call-with-output-file output-file
      (lambda (out) (write-json test-result out))
      #:exists 'replace)
    (eprintf "Results saved to: ~a~n" output-file))

  ;; JSON output to stdout
  (displayln (jsexpr->string (or test-result (hash 'error "no result"))))

  (exit (if passed EXIT-SUCCESS EXIT-ERROR)))

;; @function{cmd-android-verify}
;; @description{Complete APK verification workflow: install, launch, visual compare, test, report}
(define (cmd-android-verify apk-file
                            #:device [device #f]
                            #:baseline [baseline-file #f]
                            #:script [script-file #f]
                            #:pkg [pkg-override #f]
                            #:threshold [threshold 0]
                            #:wait [wait-time 3000]
                            #:output [output-file #f]
                            #:continue-on-visual-fail [continue-on-fail #f]
                            #:skip-install [skip-install #f]
                            #:verbose [verbose #f])
  ;; Validate inputs based on mode
  (when skip-install
    (unless pkg-override
      (eprintf "~a: --pkg is required when using --skip-install~n" (color-error "error"))
      (exit EXIT-ERROR)))

  (unless skip-install
    (unless (file-exists? apk-file)
      (eprintf "~a: APK file not found: ~a~n" (color-error "error") apk-file)
      (exit EXIT-ERROR)))

  ;; Start service
  (start-playwright-service #:verbose verbose)

  (define base-url (format "http://localhost:~a" PLAYWRIGHT_SERVICE_PORT))

  ;; Get devices
  (define devices-result
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to get Android devices: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (get-pure-port
                    (string->url (string-append base-url "/android/devices"))))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  (define devices (hash-ref devices-result 'devices '()))

  (when (null? devices)
    (eprintf "~a: no Android devices found~n" (color-error "error"))
    (eprintf "Connect a device or start an emulator, then run 'adb devices' to verify.~n")
    (exit EXIT-ERROR))

  ;; Select device
  (define target-device
    (if device
        (findf (lambda (d) (equal? (hash-ref d 'serial) device)) devices)
        (car devices)))

  (unless target-device
    (eprintf "~a: device not found: ~a~n" (color-error "error") device)
    (eprintf "Available devices:~n")
    (for ([d (in-list devices)])
      (eprintf "  ~a (~a)~n" (hash-ref d 'serial) (hash-ref d 'model "")))
    (exit EXIT-ERROR))

  (define serial (hash-ref target-device 'serial))
  (eprintf "Using device: ~a (~a)~n" serial (hash-ref target-device 'model ""))

  ;; Create session
  (define session-id
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "~a: failed to create Android session: ~a~n"
                                          (color-error "error") (exn-message e))
                                 (exit EXIT-ERROR))])
      (define resp (post-pure-port
                    (string->url (string-append base-url "/android/session/create"))
                    (string->bytes/utf-8 (jsexpr->string (hash 'serial serial)))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)

      (when (hash-has-key? data 'error)
        (eprintf "~a: ~a~n" (color-error "error") (hash-ref data 'error))
        (exit EXIT-ERROR))

      (hash-ref data 'sessionId)))

  (eprintf "Session: ~a~n" session-id)

  ;; Helper to cleanup session
  (define (cleanup)
    (with-handlers ([exn:fail? void])
      (define resp (delete-pure-port
                    (string->url (format "~a/android/session/~a" base-url session-id))))
      (close-input-port resp)))

  ;; Helper to execute session actions
  (define (session-action action)
    (with-handlers ([exn:fail? (lambda (e)
                                 (hash 'error (exn-message e) 'success #f))])
      (define resp (post-pure-port
                    (string->url (format "~a/android/session/~a/action" base-url session-id))
                    (string->bytes/utf-8 (jsexpr->string action))
                    (list "Content-Type: application/json")))
      (define data (string->jsexpr (port->string resp)))
      (close-input-port resp)
      data))

  ;; Results accumulator
  (define results
    (hash 'apk (if skip-install #f apk-file)
          'package (if skip-install pkg-override #f)
          'device serial
          'timestamp (current-seconds)
          'skipInstall skip-install
          'steps '()))

  (define overall-passed #t)
  (define pkg-name pkg-override)  ;; Will be set by install or from --pkg

  (with-handlers ([exn:fail? (lambda (e)
                               (cleanup)
                               (eprintf "~a: ~a~n" (color-error "error") (exn-message e))
                               (exit EXIT-ERROR))])

    ;; Step 1: Install APK (or skip if --skip-install)
    (if skip-install
        (begin
          (eprintf "~n=== Step 1: Skipping Install (using running app) ===~n")
          (eprintf "  → Package: ~a~n" pkg-name)
          (set! results (hash-set results 'install (hash 'skipped #t 'package pkg-name))))
        (let* ([install-result (session-action (hash 'type "install" 'apk (path->string (simple-form-path apk-file))))]
               [install-success (hash-ref install-result 'success #f)])
          (eprintf "~n=== Step 1: Installing APK ===~n")
          (set! pkg-name (or pkg-override (hash-ref install-result 'pkg #f)))

          (if install-success
              (eprintf "  ✓ Installed: ~a~n" pkg-name)
              (begin
                (eprintf "  ✗ Install failed: ~a~n" (hash-ref install-result 'error "unknown"))
                (set! overall-passed #f)))

          (set! results (hash-set results 'install install-result))

          (unless install-success
            (cleanup)
            (eprintf "~n~a: APK installation failed~n" (color-error "error"))
            (exit EXIT-ERROR))))

    ;; Step 2: Launch app
    (eprintf "~n=== Step 2: Launching App ===~n")
    (define launch-result (session-action (hash 'type "launchApp" 'pkg pkg-name)))
    (define launch-success (hash-ref launch-result 'success #f))

    (if launch-success
        (eprintf "  ✓ Launched: ~a~n" pkg-name)
        (begin
          (eprintf "  ✗ Launch failed: ~a~n" (hash-ref launch-result 'error "unknown"))
          (set! overall-passed #f)))

    (set! results (hash-set results 'launch launch-result))

    (unless launch-success
      (cleanup)
      (eprintf "~n~a: App launch failed~n" (color-error "error"))
      (exit EXIT-ERROR))

    ;; Wait for app to stabilize
    (eprintf "  Waiting ~ams for app to stabilize...~n" wait-time)
    (sleep (/ wait-time 1000.0))

    ;; Step 3: Visual comparison (if baseline provided)
    (define visual-result #f)
    (when baseline-file
      (eprintf "~n=== Step 3: Visual Comparison ===~n")
      (if (file-exists? baseline-file)
          (let ()
            ;; Load baseline image
            (define baseline-data (file->bytes baseline-file))
            (define baseline-b64 (bytes->string/utf-8 (base64-encode baseline-data)))

            ;; Capture and compare current screenshot
            (define compare-result
              (session-action (hash 'type "compareScreenshot"
                                    'baseline baseline-b64
                                    'threshold threshold)))

            (set! visual-result compare-result)
            (define visual-passed (hash-ref compare-result 'success #f))
            (define diff-percent (hash-ref compare-result 'diffPercent 100))

            (if visual-passed
                (eprintf "  ✓ Visual match (diff: ~a%, threshold: ~a%)~n" diff-percent threshold)
                (begin
                  (eprintf "  ✗ Visual mismatch (diff: ~a%, threshold: ~a%)~n" diff-percent threshold)
                  (unless continue-on-fail
                    (set! overall-passed #f)))))
          (begin
            (eprintf "  ⚠ Baseline file not found: ~a~n" baseline-file)
            (set! visual-result (hash 'skipped #t 'reason "baseline file not found"))))

      (set! results (hash-set results 'visual visual-result)))

    ;; Step 4: Run test script (if provided)
    (define test-result #f)
    (when script-file
      (eprintf "~n=== Step 4: Running Test Script ===~n")
      (if (file-exists? script-file)
          (let ()
            (define script-content (file->string script-file))
            (define script-json
              (with-handlers ([exn:fail? (lambda (e)
                                           (hash 'error (format "Invalid JSON: ~a" (exn-message e))))])
                (string->jsexpr script-content)))

            (when (hash? script-json)
              (define test-request
                (if (hash-has-key? script-json 'steps)
                    (hash-set* script-json 'type "runTest" 'stopOnFailure #t)
                    (hash 'type "runTest"
                          'name (path->string (file-name-from-path script-file))
                          'steps script-json
                          'stopOnFailure #t)))

              (set! test-result (session-action test-request))
              (define test-info (hash-ref test-result 'test (hash)))
              (define test-passed (hash-ref test-info 'passed #f))
              (define steps-executed (hash-ref test-info 'stepsExecuted 0))
              (define steps-passed (hash-ref test-info 'stepsPassed 0))

              (if test-passed
                  (eprintf "  ✓ Test passed (~a/~a steps)~n" steps-passed steps-executed)
                  (begin
                    (eprintf "  ✗ Test failed (~a/~a steps)~n" steps-passed steps-executed)
                    (when (hash-ref test-info 'failedStep #f)
                      (eprintf "    Failed at: ~a~n" (hash-ref test-info 'failedStep))
                      (eprintf "    Reason: ~a~n" (hash-ref test-info 'failureReason "")))
                    (set! overall-passed #f)))))
          (begin
            (eprintf "  ⚠ Script file not found: ~a~n" script-file)
            (set! test-result (hash 'skipped #t 'reason "script file not found"))))

      (set! results (hash-set results 'test test-result)))

    ;; Step 5: Check for crashes
    (eprintf "~n=== Step 5: Crash Detection ===~n")
    (define crash-result (session-action (hash 'type "checkCrash" 'pkg pkg-name)))
    (define has-crash (hash-ref crash-result 'crashed #f))
    (define has-anr (hash-ref crash-result 'anr #f))

    (if (or has-crash has-anr)
        (begin
          (eprintf "  ✗ Crash/ANR detected~n")
          (when has-crash (eprintf "    Crash: ~a~n" (hash-ref crash-result 'crashMessage "")))
          (when has-anr (eprintf "    ANR: ~a~n" (hash-ref crash-result 'anrMessage "")))
          (set! overall-passed #f))
        (eprintf "  ✓ No crashes detected~n"))

    (set! results (hash-set results 'crashCheck crash-result))

    ;; Cleanup
    (cleanup))

  ;; Final summary
  (eprintf "~n========================================~n")
  (eprintf "VERIFICATION ~a~n" (if overall-passed "PASSED" "FAILED"))
  (eprintf "========================================~n")

  (define final-results (hash-set results 'passed overall-passed))

  ;; Write output file if specified
  (when output-file
    (call-with-output-file output-file
      (lambda (out) (write-json final-results out))
      #:exists 'replace)
    (eprintf "Results saved to: ~a~n" output-file))

  ;; JSON output to stdout
  (displayln (jsexpr->string final-results))

  (exit (if overall-passed EXIT-SUCCESS EXIT-ERROR)))

;; @function{parse-session-command}
;; @description{Parse a command string into a JSON action object}
(define (parse-session-command cmd-str)
  (define parts (string-split cmd-str))
  (define cmd (car parts))
  (define args (cdr parts))

  (case (string->symbol cmd)
    [(navigate)
     (if (empty? args)
         #f
         (hash 'type "navigate" 'url (car args)))]

    [(click)
     (if (empty? args)
         #f
         (hash 'type "click" 'selectors (list (list (string-join args " ")))))]

    [(type fill)
     (if (< (length args) 2)
         #f
         (let ([selector (car args)]
               [text (string-join (cdr args) " ")])
           (hash 'type "fill" 'selectors (list (list selector)) 'value text)))]

    [(scroll)
     (if (empty? args)
         (hash 'type "scroll" 'x 0 'y 0)
         (hash 'type "scroll"
               'x (if (> (length args) 0) (string->number (car args)) 0)
               'y (if (> (length args) 1) (string->number (cadr args)) 0)))]

    [(think)
     (hash 'type "customStep"
           'name "agent_thought"
           'parameters (hash 'note (string-join args " ")))]

    [(screenshot)
     (hash 'type "screenshot" 'fullPage #t)]

    [else #f]))

;; @function{cmd-replay}
;; @description{Replay a Chrome DevTools Recorder JSON recording}
(define (cmd-replay recording-file
                    #:output [output-file #f]
                    #:format [output-format 'json]
                    #:verbose [verbose #f])

  ;; Start playwright service (replay requires it)
  (start-playwright-service #:verbose verbose)

  (when verbose
    (printf "Replaying recording: ~a~n" recording-file))

  ;; Load recording JSON
  (define recording
    (with-handlers ([exn:fail? (lambda (e)
                                  (eprintf "~a: failed to load recording: ~a~n"
                                           (color-error "error") (exn-message e))
                                  (exit EXIT-ERROR))])
      (call-with-input-file recording-file
        (lambda (port)
          (string->jsexpr (port->string port))))))

  ;; Call the playwright replay endpoint
  (define replay-url (format "http://localhost:~a/replay" PLAYWRIGHT_SERVICE_PORT))

  (define response
    (with-handlers ([exn:fail? (lambda (e)
                                  (eprintf "~a: replay failed: ~a~n"
                                           (color-error "error") (exn-message e))
                                  #f)])
      (define req-data (jsexpr->string (hash 'recording recording)))
      (define port (post-pure-port
                    (string->url replay-url)
                    (string->bytes/utf-8 req-data)
                    (list "Content-Type: application/json")))
      (define raw-response (port->string port))
      (close-input-port port)
      (string->jsexpr raw-response)))

  (when (not response)
    (exit EXIT-ERROR))

  ;; Check for error in response
  (when (hash-ref response 'error #f)
    (eprintf "~a: ~a~n" (color-error "error") (hash-ref response 'error))
    (exit EXIT-ERROR))

  (when verbose
    (define rec-info (hash-ref response 'recording (hash)))
    (printf "Recording '~a' completed~n" (hash-ref rec-info 'title "untitled"))
    (printf "Steps executed: ~a~n" (hash-ref rec-info 'stepsExecuted 0))
    (printf "Final URL: ~a~n" (hash-ref response 'url ""))
    (define meta (hash-ref response 'metadata (hash)))
    (printf "Total time: ~a ms~n" (hash-ref meta 'totalTime 0)))

  ;; Output results
  (define output-data
    (hash 'data (list (hash 'content (hash-ref response 'content "")
                            'url (hash-ref response 'url "")
                            'title (hash-ref response 'title "")
                            'links (hash-ref response 'links '())))
          'metadata (hash-ref response 'metadata (hash))
          'recording (hash-ref response 'recording (hash))
          'timestamp (generate-timestamp)))

  (if output-file
      (begin
        (ensure-directory (or (path-only output-file) (current-directory)))
        (call-with-output-file output-file
          (lambda (port)
            (display (jsexpr->string output-data #:indent 2) port))
          #:exists 'replace)
        (when verbose
          (printf "Results saved to: ~a~n" output-file)))
      ;; Output to stdout
      (displayln (jsexpr->string output-data #:indent 2))))

;; @function{cmd-probe}
;; @description{Probe a URL to measure page load performance and suggest scraping parameters}
(define (cmd-probe url
                   #:verbose [verbose #f]
                   #:output [output-file #f]
                   #:format [output-format #f])

  ;; Start playwright service (probe requires it)
  (start-playwright-service #:verbose (and verbose (not (eq? output-format 'json))))

  (when (and verbose (not (eq? output-format 'json)))
    (printf "Probing URL: ~a~n" url)
    (printf "Measuring page load timing metrics...~n"))

  ;; Call the playwright probe endpoint
  (define probe-url (format "http://localhost:~a/probe" PLAYWRIGHT_SERVICE_PORT))

  (define response
    (with-handlers ([exn:fail? (lambda (e)
                                  (unless (eq? output-format 'json)
                                    (eprintf "~a: probe failed: ~a~n" (color-error "error") (exn-message e)))
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
    (if (eq? output-format 'json)
        (displayln (jsexpr->string (hash 'error "Probe failed" 'details "Check playwright service or URL") #:encode 'control))
        (eprintf "~a: failed to probe URL (check if playwright service is running)~n" (color-error "error")))
    (exit EXIT-ERROR))

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
  (if (eq? output-format 'json)
      (let ([output-data
             (hash 'url url
                   'timing timing
                   'resources resources
                   'recommendations recommendations
                   'probeTime probe-time
                   'dynamicScore dynamic-score
                   'timestamp (generate-timestamp))])
        (displayln (jsexpr->string output-data #:encode 'control)))
      (begin
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

        (printf "~nProbe completed in ~a ms~n" probe-time)))

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
                    #:verbose [verbose #f]
                    #:format [format #f])

  (setup-crawler config-file (and verbose (not (eq? format 'json))))

  (define crawler (create-crawler-from-config))

  (when (and verbose (not (eq? format 'json)))
    (printf "Checking service health...~n"))

  (define health (health-check crawler))

  (if (eq? format 'json)
      (let* ([raw-health (health-status->hash health)]
             [h1 (hash-set raw-health 'status (symbol->string (hash-ref raw-health 'status)))]
             [json-health (hash-set h1 'uptime (exact->inexact (hash-ref h1 'uptime)))])
        (displayln (jsexpr->string json-health #:encode 'control)))
      (begin
        (printf "Overall Status: ~a~n" (health-status-status health))
        (printf "Uptime: ~a seconds~n" (exact->inexact (health-status-uptime health)))

        (printf "~nService Health:~n")
        (for ([(service healthy?) (in-hash (health-status-services health))])
          (printf "  ~a: ~a~n" service (if healthy? "✓ Healthy" "✗ Unhealthy")))

        (when verbose
          (printf "~nDetailed Health Status:~n")
          (pretty-print (health-status->hash health))))))

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
(define (cmd-services #:verbose [verbose #f]
                      #:format [format #f])
  (define services (get-available-services))

  (if (eq? format 'json)
      (let ([data (hash 'services (map symbol->string services)
                        'count (length services)
                        'statuses (if verbose
                                      (for/hash ([s services])
                                        (values s (test-service-health s)))
                                      (hash)))])
        (displayln (jsexpr->string data #:encode 'control)))
      (begin
        (printf "Available Crawling Services:~n~n")

        (for ([service services])
          (printf "• ~a~n" service)
          (when verbose
            (define healthy (test-service-health service))
            (printf "  Status: ~a~n" (if healthy "✓ Available" "✗ Unavailable"))))

        (printf "~nTotal services: ~a~n" (length services)))))

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

;; @function{validate-url-or-error}
;; @description{Validate URL and return detailed error info if invalid}
;; @param[url-str]{string?} The URL to validate
;; @returns{(values boolean? hash?)} Valid? and error details
(define (validate-url-or-error url-str)
  (cond
    [(not (string? url-str))
     (values #f (hash 'error_type 'invalid-type
                      'message "URL must be a string"
                      'suggestions (list "Provide a URL as a string")))]

    [(string-prefix? url-str "-")
     (values #f (url-error-details url-str 'looks-like-flag))]

    [(not (regexp-match? #rx"^https?://" url-str))
     (let ([fixed-url (string-append "https://" url-str)])
       (values #f (hash 'error_type 'missing-protocol
                       'url url-str
                       'suggestion fixed-url
                       'message (format "Invalid URL '~a'" url-str)
                       'suggestions (list (format "Did you mean: ~a?" fixed-url)
                                        "URLs must include the protocol (http:// or https://)"))))]

    [(not (ok-http-url? url-str))
     (values #f (hash 'error_type 'invalid-url
                     'url url-str
                     'message (format "Invalid URL '~a'" url-str)
                     'suggestions (list "Check URL format"
                                      "Ensure it includes protocol (http:// or https://)")))]

    [else (values #t (hash))]))

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
   [("--resolve-urls") "Resolve relative URLs to absolute URLs using source_url as base"
    (extract-resolve-urls-param #t)]
   [("--download") "Download extracted files to local directory"
    (extract-download-param #t)]
   [("--download-dir") dir "Directory for downloaded files (default: downloads)"
    (extract-download-dir-param dir)]
   [("--rate-limit") ms "Rate limit between downloads in milliseconds (default: 0)"
    (extract-rate-limit-param (string->number ms))]
   [("--skip-existing") "Skip downloading files that already exist"
    (extract-skip-existing-param #t)]
   [("-v" "--verbose") "Show detailed progress"
    (verbose-mode #t)]
   #:multi
   [("--file-type") type "File type to extract (pdf, image, video, audio, archive, etc.)"
    (extract-file-types-param (cons type (extract-file-types-param)))]
   [("--extension") ext "File extension to extract (can be repeated)"
    (extract-extensions-param (cons ext (extract-extensions-param)))]
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
   [("-f" "--format") fmt "Output format: json"
    (output-format-param (string->symbol fmt))]
   [("-o" "--output") file "Save results to JSON file"
    (output-file-param file)]
   #:args ()
   (void)))

;; @function{parse-replay-args}
;; @description{Parse replay command arguments after the recording file}
(define (parse-replay-args args)
  (command-line
   #:program "ar-crawl replay"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   [("-o" "--output") file "Save results to file"
    (output-file-param file)]
   [("-f" "--format") fmt "Output format: json"
    (output-format-param (string->symbol fmt))]
   #:args ()
   (void)))

;; @function{parse-session-args}
;; @description{Parse session command arguments}
(define (parse-session-args args)
  (command-line
   #:program "ar-crawl session"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   #:args ()
   (void)))

;; @function{parse-crawl-args}
;; @description{Parse crawl command arguments after the URL}
(define (parse-crawl-args args)
  (command-line
   #:program "ar-crawl crawl"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   [("-n" "--dry-run") "Show what would be done without crawling"
    (dry-run-mode #t)]
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
   [("-n" "--dry-run") "Show what would be done without crawling"
    (dry-run-mode #t)]
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

;; @function{parse-services-args}
;; @description{Parse services command arguments}
(define (parse-services-args args)
  (command-line
   #:program "ar-crawl services"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Check and display availability status for each service"
    (verbose-mode #t)]
   [("-f" "--format") fmt "Output format: json"
    (output-format-param (string->symbol fmt))]
   #:args ()
   (void)))

;; @function{parse-health-args}
;; @description{Parse health command arguments}
(define (parse-health-args args)
  (command-line
   #:program "ar-crawl health"
   #:argv args
   #:once-each
   [("-c" "--config") config-file "Path to configuration file"
    (config-file-path config-file)]
   [("-v" "--verbose") "Show detailed health information"
    (verbose-mode #t)]
   [("-f" "--format") fmt "Output format: json"
    (output-format-param (string->symbol fmt))]
   #:args ()
   (void)))

;; @function{parse-stats-args}
;; @description{Parse stats command arguments after the file}
(define (parse-stats-args args)
  (command-line
   #:program "ar-crawl stats"
   #:argv args
   #:once-each
   [("-v" "--verbose") "Enable verbose output"
    (verbose-mode #t)]
   [("-f" "--format") fmt "Output format: json"
    (output-format-param (string->symbol fmt))]
   #:args ()
   (void)))

(define (main)
  (define args (vector->list (current-command-line-arguments)))

  ;; Initialize color mode based on environment
  (init-color-mode!)

  ;; Handle --no-color and --color flags early (before other parsing)
  (when (member "--no-color" args)
    (color-enabled #f))
  (when (member "--color" args)
    (force-color #t)
    (color-enabled #t))

  ;; Handle --help and --version at any position
  (when (or (member "--help" args) (member "-h" args))
    (show-main-help)
    (exit EXIT-SUCCESS))
  (when (member "--version" args)
    (show-version)
    (exit EXIT-SUCCESS))

  ;; Filter out color flags before further parsing
  (set! args (filter (lambda (a) (not (member a '("--no-color" "--color")))) args))

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
     [("-q" "--quiet") "Suppress non-essential output"
      (quiet-mode #t)]
     [("-n" "--dry-run") "Show what would be done without doing it"
      (dry-run-mode #t)]
     [("-c" "--config") config-file "Path to configuration file"
      (config-file-path config-file)]
     #:multi
     [("-s" "--service") service "Crawling service to use"
      (selected-services (cons (string->symbol service) (selected-services)))]
     #:args remaining
     (when (not (empty? remaining))
       (eprintf "~a: unexpected arguments before command: ~a~n"
                (color-error "error") remaining)
       (exit EXIT-USAGE))))

  (cond
    [(not command)
     (show-main-help)]

    [else
     (define cmd-sym (string->symbol command))

     (case cmd-sym
       [(crawl)
        (when (empty? post-cmd-args)
          (eprintf "~a: URL required for crawl command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl crawl <url> [options]~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help crawl"))
          (exit EXIT-USAGE))
        (define url (car post-cmd-args))
        (when (string-prefix? url "-")
           (eprintf "~a: invalid URL '~a' (looks like a flag)~n" (color-error "error") url)
           (eprintf "~nURLs must not start with '-'. Did you forget to specify a URL?~n")
           (exit EXIT-USAGE))
        (parse-crawl-args (cdr post-cmd-args))
        (cmd-crawl url
                   #:config (config-file-path)
                   #:services (selected-services)
                   #:verbose (verbose-mode)
                   #:dry-run (dry-run-mode)
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
          (eprintf "~a: URL required for crawl-site command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl crawl-site <url> [options]~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help crawl-site"))
          (exit EXIT-USAGE))
        (define url (car post-cmd-args))
        (when (string-prefix? url "-")
           (eprintf "~a: invalid URL '~a' (looks like a flag)~n" (color-error "error") url)
           (eprintf "~nURLs must not start with '-'. Did you forget to specify a URL?~n")
           (exit EXIT-USAGE))
        (parse-crawl-site-args (cdr post-cmd-args))
        (cmd-crawl-site url
                        #:config (config-file-path)
                        #:services (selected-services)
                        #:verbose (verbose-mode)
                        #:dry-run (dry-run-mode)
                        #:max-pages (max-pages)
                        #:max-depth (max-depth)
                        #:url-pattern (url-pattern)
                        #:same-domain (same-domain-only)
                        #:crawl-delay (crawl-delay-ms)
                        #:output (output-file-param)
                        #:format (output-format-param)
                        #:xpath (xpath-filter-param))]

       [(health)
        (parse-health-args post-cmd-args)
        (cmd-health #:config (config-file-path)
                    #:verbose (verbose-mode)
                    #:format (output-format-param))]

       [(test)
        (cmd-test #:config (config-file-path)
                  #:verbose (verbose-mode))]

       [(config)
        (when (empty? post-cmd-args)
          (eprintf "~a: subcommand required for config command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl config <subcommand>~n")
          (eprintf "Subcommands: init, show, validate~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help config"))
          (exit EXIT-USAGE))
        (cmd-config (string->symbol (car post-cmd-args)))]

       [(services)
        (parse-services-args post-cmd-args)
        (cmd-services #:verbose (verbose-mode)
                      #:format (output-format-param))]

       [(monitor)
        (cmd-monitor #:config (config-file-path))]

       [(extract)
        (when (empty? post-cmd-args)
          (eprintf "~a: input file required for extract command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl extract <file> [options]~n")
          (eprintf "       ar-crawl extract <file> --xpath-map '{...}'~n")
          (eprintf "       ar-crawl extract <file> --parent \"//div\" --fields '{...}'~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help extract"))
          (exit EXIT-USAGE))
        (define input-file (car post-cmd-args))
        (parse-extract-args (cdr post-cmd-args))
        (cmd-extract input-file
                     #:xpath (extract-xpath-param)
                     #:parent (extract-parent-param)
                     #:fields (extract-fields-param)
                     #:file-types (extract-file-types-param)
                     #:extensions (extract-extensions-param)
                     #:output (output-file-param)
                     #:format (output-format-param)
                     #:resolve-urls (extract-resolve-urls-param)
                     #:download (extract-download-param)
                     #:download-dir (extract-download-dir-param)
                     #:rate-limit (extract-rate-limit-param)
                     #:skip-existing (extract-skip-existing-param)
                     #:verbose (verbose-mode))]

       [(sample)
        (when (empty? post-cmd-args)
          (eprintf "~a: input file required for sample command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl sample <file> [--index N] [--length N]~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help sample"))
          (exit EXIT-USAGE))
        (define input-file (car post-cmd-args))
        (parse-sample-args (cdr post-cmd-args))
        (cmd-sample input-file
                    #:index (sample-index-param)
                    #:length (sample-length-param))]

       [(stats)
        (when (empty? post-cmd-args)
          (eprintf "~a: database file required for stats command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl stats <file.db> [options]~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help stats"))
          (exit EXIT-USAGE))
        (define db-file (car post-cmd-args))
        (parse-stats-args (cdr post-cmd-args))
        (with-handlers ([exn:fail? (lambda (e)
                                     (eprintf "~a: ~a~n" (color-error "error") (exn-message e))
                                     (exit EXIT-ERROR))])
           (cmd-stats db-file #:verbose (verbose-mode)
                      #:format (output-format-param)))]

       [(probe)
        (when (empty? post-cmd-args)
          (eprintf "~a: URL required for probe command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl probe <url> [options]~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help probe"))
          (exit EXIT-USAGE))
        (define probe-target-url (car post-cmd-args))
        (parse-probe-args (cdr post-cmd-args))
        (with-playwright-cleanup
          (cmd-probe probe-target-url
                     #:verbose (verbose-mode)
                     #:output (output-file-param)
                     #:format (output-format-param)))]

       [(replay)
        (when (empty? post-cmd-args)
          (eprintf "~a: recording file required for replay command~n~n" (color-error "error"))
          (eprintf "Usage: ar-crawl replay <recording.json> [options]~n")
          (eprintf "~nThe recording file should be a Chrome DevTools Recorder JSON export.~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help replay"))
          (exit EXIT-USAGE))
        (define recording-file (car post-cmd-args))
        (parse-replay-args (cdr post-cmd-args))
        (with-playwright-cleanup
          (cmd-replay recording-file
                      #:verbose (verbose-mode)
                      #:output (output-file-param)
                      #:format (output-format-param)))]

       [(session)
        (parse-session-args post-cmd-args)
        (with-playwright-cleanup
          (cmd-session #:verbose (verbose-mode)))]

       [(android)
        (when (empty? post-cmd-args)
          (eprintf "~a: subcommand required for android command~n~n" (color-error "error"))
          (eprintf "Subcommands: devices, session, replay, baseline, test, verify~n~n")
          (eprintf "Usage:~n")
          (eprintf "  ar-crawl android devices              List connected Android devices~n")
          (eprintf "  ar-crawl android session <serial>     Start interactive session~n")
          (eprintf "  ar-crawl android replay <file.json>   Replay a recording~n")
          (eprintf "  ar-crawl android baseline [options]   Capture baseline screenshot~n")
          (eprintf "  ar-crawl android test <script.json>   Run test scripts~n")
          (eprintf "  ar-crawl android verify <app.apk>     Complete APK verification workflow~n~n")
          (eprintf "Run '~a' for more information.~n" (color-dim "ar-crawl help android"))
          (exit EXIT-USAGE))

        (define subcmd (car post-cmd-args))
        (define subcmd-args (cdr post-cmd-args))

        (case (string->symbol subcmd)
          [(devices)
           (with-playwright-cleanup
             (cmd-android-devices #:verbose (verbose-mode)))]

          [(session)
           (when (empty? subcmd-args)
             (eprintf "~a: device serial required for android session~n~n" (color-error "error"))
             (eprintf "Usage: ar-crawl android session <device-serial>~n~n")
             (eprintf "First run '~a' to list available devices.~n"
                      (color-dim "ar-crawl android devices"))
             (exit EXIT-USAGE))
           (define device-serial (car subcmd-args))
           (parse-android-session-args (cdr subcmd-args))
           (with-playwright-cleanup
             (cmd-android-session device-serial #:verbose (verbose-mode)))]

          [(replay)
           (when (empty? subcmd-args)
             (eprintf "~a: recording file required for android replay~n~n" (color-error "error"))
             (eprintf "Usage: ar-crawl android replay <recording.json> [options]~n")
             (exit EXIT-USAGE))
           (define recording-file (car subcmd-args))
           (parse-android-replay-args (cdr subcmd-args))
           (with-playwright-cleanup
             (cmd-android-replay recording-file
                                 #:device (android-replay-device)
                                 #:speed (android-replay-speed)
                                 #:screenshots (android-replay-screenshots)
                                 #:verbose (verbose-mode)))]

          [(baseline)
           ;; Parse positional args - first non-option arg could be package or APK
           (define positional-args (parse-android-baseline-args subcmd-args))
           ;; If positional arg provided, treat as package or APK
           (when (not (empty? positional-args))
             (define arg (car positional-args))
             (cond
               [(string-suffix? arg ".apk")
                (android-baseline-apk arg)]
               [else
                (android-baseline-pkg arg)]))
           (with-playwright-cleanup
             (cmd-android-baseline #:device (android-baseline-device)
                                   #:output (android-baseline-output)
                                   #:name (android-baseline-name)
                                   #:apk (android-baseline-apk)
                                   #:pkg (android-baseline-pkg)
                                   #:wait (android-baseline-wait)
                                   #:verbose (verbose-mode)))]

          [(test)
           (when (empty? subcmd-args)
             (eprintf "~a: script file required for android test~n~n" (color-error "error"))
             (eprintf "Usage: ar-crawl android test <script.json> [options]~n")
             (exit EXIT-USAGE))
           (define script-file (car subcmd-args))
           (parse-android-test-args (cdr subcmd-args))
           (with-playwright-cleanup
             (cmd-android-test script-file
                               #:device (android-test-device)
                               #:pkg (android-test-pkg)
                               #:stop-on-failure (android-test-stop-on-failure)
                               #:step-delay (android-test-step-delay)
                               #:output (android-test-output)
                               #:verbose (verbose-mode)))]

          [(verify)
           ;; Parse args first to check for --skip-install
           (define positional-args (parse-android-verify-args subcmd-args))

           ;; Determine APK file (optional with --skip-install)
           (define apk-file
             (cond
               [(not (empty? positional-args)) (car positional-args)]
               [(android-verify-skip-install) #f]  ;; No APK needed with --skip-install
               [else
                (eprintf "~a: APK file required for android verify~n~n" (color-error "error"))
                (eprintf "Usage: ar-crawl android verify <app.apk> [options]~n")
                (eprintf "       ar-crawl android verify --skip-install --pkg <package> [options]~n")
                (eprintf "~nOptions:~n")
                (eprintf "  -b, --baseline <file>    Baseline screenshot for visual comparison~n")
                (eprintf "  -s, --script <file>      Test script (JSON) to execute~n")
                (eprintf "  -d, --device <serial>    Target device serial~n")
                (eprintf "  -p, --pkg <package>      Package name (required with --skip-install)~n")
                (eprintf "  -t, --threshold <pct>    Visual diff threshold (default: 0)~n")
                (eprintf "  -o, --output <file>      Output results file (JSON)~n")
                (eprintf "      --skip-install       Skip APK install, test running app~n")
                (exit EXIT-USAGE)]))

           (with-playwright-cleanup
             (cmd-android-verify apk-file
                                 #:device (android-verify-device)
                                 #:baseline (android-verify-baseline)
                                 #:script (android-verify-script)
                                 #:pkg (android-verify-pkg)
                                 #:threshold (android-verify-threshold)
                                 #:wait (android-verify-wait)
                                 #:output (android-verify-output)
                                 #:continue-on-visual-fail (android-verify-continue)
                                 #:skip-install (android-verify-skip-install)
                                 #:verbose (verbose-mode)))]

          [else
           (eprintf "~a: unknown android subcommand '~a'~n" (color-error "error") subcmd)
           (eprintf "~nAvailable subcommands: devices, session, replay, baseline, test, verify~n")
           (exit EXIT-USAGE)])]

       [(help)
        (if (empty? post-cmd-args)
            (show-main-help)
            (show-command-help (car post-cmd-args)))]

       [(version)
        (show-version)]

       [else
        (define suggestion (suggest-command command))
        (eprintf "~a: unknown command '~a'~n" (color-error "error") command)
        (when suggestion
          (eprintf "~n    Did you mean '~a'?~n" (color-info suggestion)))
        (eprintf "~nRun '~a' for usage information.~n"
                 (color-dim "ar-crawl help"))
        (exit EXIT-USAGE)])]))

;; Initialize global parameters
(define verbose-mode (make-parameter #f))
(define quiet-mode (make-parameter #f))
(define config-file-path (make-parameter #f))
(define selected-services (make-parameter '()))
(define dry-run-mode (make-parameter #f))

;; Color control parameters - follows clig.dev guidelines
;; Colors disabled when: NO_COLOR set, TERM=dumb, --no-color, or not a TTY
(define color-enabled (make-parameter #f))
(define force-color (make-parameter #f))

;; @function{should-use-color?}
;; @description{Determine if color output should be used based on environment and flags}
(define (should-use-color?)
  (cond
    [(force-color) #t]  ; --color flag overrides everything
    [(getenv "NO_COLOR") #f]  ; NO_COLOR env var disables color
    [(equal? (getenv "TERM") "dumb") #f]  ; dumb terminal
    [(not (terminal-port? (current-output-port))) #f]  ; not a TTY
    [else #t]))

;; Initialize color based on environment
(define (init-color-mode!)
  (color-enabled (should-use-color?)))

;; Playwright-specific parameters
(define pw-scroll (make-parameter #f))
(define pw-scroll-count (make-parameter 0))
(define pw-scroll-delay (make-parameter 1000))
(define pw-click-selector (make-parameter #f))
(define pw-click-count (make-parameter 1))
(define pw-delay (make-parameter 5000))

;; Version info - imported from version-info.rkt (generated at build time)

;; Exit codes - standardized per clig.dev
(define EXIT-SUCCESS 0)
(define EXIT-ERROR 1)
(define EXIT-USAGE 2)

;; ANSI color codes
(define ANSI-RESET "\033[0m")
(define ANSI-RED "\033[31m")
(define ANSI-GREEN "\033[32m")
(define ANSI-YELLOW "\033[33m")
(define ANSI-BLUE "\033[34m")
(define ANSI-BOLD "\033[1m")
(define ANSI-DIM "\033[2m")

;; @function{colorize}
;; @description{Apply ANSI color code if colors are enabled}
(define (colorize text color-code)
  (if (color-enabled)
      (string-append color-code text ANSI-RESET)
      text))

;; @function{color-error}
;; @description{Format text as error (red)}
(define (color-error text)
  (colorize text ANSI-RED))

;; @function{color-success}
;; @description{Format text as success (green)}
(define (color-success text)
  (colorize text ANSI-GREEN))

;; @function{color-warning}
;; @description{Format text as warning (yellow)}
(define (color-warning text)
  (colorize text ANSI-YELLOW))

;; @function{color-info}
;; @description{Format text as info (blue)}
(define (color-info text)
  (colorize text ANSI-BLUE))

;; @function{color-bold}
;; @description{Format text as bold}
(define (color-bold text)
  (colorize text ANSI-BOLD))

;; @function{color-dim}
;; @description{Format text as dim}
(define (color-dim text)
  (colorize text ANSI-DIM))

;; @function{msg}
;; @description{Print message to stderr (for non-data output per clig.dev)}
(define (msg fmt . args)
  (unless (quiet-mode)
    (apply eprintf (string-append fmt "~n") args)))

;; @function{msg-verbose}
;; @description{Print verbose message to stderr only if verbose mode is on}
(define (msg-verbose fmt . args)
  (when (verbose-mode)
    (apply eprintf (string-append fmt "~n") args)))

;; @function{die}
;; @description{Print error message and exit with given code}
(define (die code fmt . args)
  (eprintf "~a: ~a~n" (color-error "error") (apply format fmt args))
  (exit code))

;; @function{die-usage}
;; @description{Print usage error and exit}
(define (die-usage fmt . args)
  (apply die EXIT-USAGE fmt args))

;; Known commands for typo suggestions
(define KNOWN-COMMANDS
  '("crawl" "crawl-site" "probe" "replay" "session" "android" "sample" "extract" "stats"
    "health" "test" "config" "services" "monitor" "help" "version"))

;; @function{levenshtein-distance}
;; @description{Calculate edit distance between two strings for typo detection}
(define (levenshtein-distance s1 s2)
  (define len1 (string-length s1))
  (define len2 (string-length s2))
  (define dp (make-vector (add1 len1)))
  (for ([i (in-range (add1 len1))])
    (vector-set! dp i (make-vector (add1 len2) 0)))
  (for ([i (in-range (add1 len1))])
    (vector-set! (vector-ref dp i) 0 i))
  (for ([j (in-range (add1 len2))])
    (vector-set! (vector-ref dp 0) j j))
  (for* ([i (in-range 1 (add1 len1))]
         [j (in-range 1 (add1 len2))])
    (define cost (if (char=? (string-ref s1 (sub1 i))
                             (string-ref s2 (sub1 j))) 0 1))
    (vector-set! (vector-ref dp i) j
                 (min (add1 (vector-ref (vector-ref dp (sub1 i)) j))
                      (add1 (vector-ref (vector-ref dp i) (sub1 j)))
                      (+ cost (vector-ref (vector-ref dp (sub1 i)) (sub1 j))))))
  (vector-ref (vector-ref dp len1) len2))

;; @function{suggest-command}
;; @description{Suggest similar commands for typo correction}
(define (suggest-command input)
  (define candidates
    (filter (lambda (cmd)
              (<= (levenshtein-distance input cmd) 2))
            KNOWN-COMMANDS))
  (if (empty? candidates)
      #f
      (argmin (lambda (cmd) (levenshtein-distance input cmd)) candidates)))

;; Help Documentation
;; ------------------

;; @function{show-version}
;; @description{Display version information}
(define (show-version)
  (printf "ar-crawl ~a~n" AR-CRAWL-VERSION)
  (printf "Web crawler for agents with service fallbacks~n")
  (printf "Copyright (c) 2025 Anuna Research~n")
  (printf "License: Apache-2.0~n")
  (printf "https://codeberg.org/anuna/ar-crawl~n"))

;; @function{show-main-help}
;; @description{Display main help message with overview of all commands}
(define (show-main-help)
  (printf "~n")
  (printf "AR-CRAWL - Web Crawler for Agents~n")
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
  (printf "  replay <file>       Replay a Chrome DevTools Recorder JSON recording~n")
  (printf "  session             Interactive Playwright session for LLM agents~n")
  (printf "  android <subcmd>    Control Android emulators for mobile automation~n")
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
  (printf "  -q, --quiet         Suppress non-essential output~n")
  (printf "  -n, --dry-run       Show what would be done without doing it~n")
  (printf "  -c, --config FILE   Path to configuration file (auto-detected by default)~n")
  (printf "      --no-color      Disable colored output~n")
  (printf "      --color         Force colored output (even in pipes)~n")
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
  (printf "  -v, --verbose       Show detailed progress and debugging info~n")
  (printf "  -n, --dry-run       Show what would be done without crawling~n~n")

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
  (printf "  -v, --verbose          Show detailed progress~n")
  (printf "  -n, --dry-run          Show what would be done without crawling~n~n")

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
  (printf "  ar-crawl extract <file> --parent '<xpath>' --fields '<json>'~n")
  (printf "  ar-crawl extract <file> --file-type <type>~n")
  (printf "  ar-crawl extract <file> --extension <ext>~n~n")

  (printf "OPTIONS~n")
  (printf "  --fields <json>          JSON object mapping field names to XPaths~n")
  (printf "  --xpath-map <json>       Alias for --fields~n")
  (printf "  --parent <xpath>         Parent container XPath for repeating items~n")
  (printf "  --file-type <type>       Extract files by type (repeatable)~n")
  (printf "  --extension <ext>        Extract files by extension (repeatable)~n")
  (printf "  -o, --output <file>      Output file (stdout if not specified)~n")
  (printf "  -f, --format <fmt>       Output format: json (default), csv, sqlite~n")
  (printf "  --resolve-urls           Resolve relative URLs to absolute URLs~n")
  (printf "  --download               Download extracted files to local directory~n")
  (printf "  --download-dir <dir>     Directory for downloads (default: downloads)~n")
  (printf "  --rate-limit <ms>        Rate limit between downloads in ms (default: 0)~n")
  (printf "  --skip-existing          Skip downloading files that already exist~n")
  (printf "  -v, --verbose            Show detailed progress~n~n")

  (printf "FILE TYPES~n")
  (printf "  pdf, image, video, audio, archive, document, spreadsheet,~n")
  (printf "  presentation, code~n~n")

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

  (printf "  3. File Type Filtering (--file-type, --extension)~n")
  (printf "     Extract downloadable files by type or extension.~n~n")
  (printf "     Example: Extract all PDFs~n")
  (displayln "     ar-crawl extract page.json --file-type pdf --resolve-urls")
  (newline)
  (printf "     Example: Extract multiple types~n")
  (displayln "     ar-crawl extract page.json --file-type pdf --file-type image")
  (newline)
  (printf "     Example: Custom extensions~n")
  (displayln "     ar-crawl extract page.json --extension docx --extension xlsx")
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
  (newline)

  (printf "  # Extract all PDFs for download~n")
  (displayln "  ar-crawl extract page.json --file-type pdf --resolve-urls -o pdfs.json")
  (newline)

  (printf "  # Extract and download all PDFs directly~n")
  (displayln "  ar-crawl extract page.json --file-type pdf --resolve-urls \\")
  (displayln "    --download --download-dir pdfs/ -v")
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

;; @function{show-replay-help}
;; @description{Show help for replay command}
(define (show-replay-help)
  (printf "~nREPLAY - Replay Chrome DevTools Recorder recordings~n")
  (printf "====================================================~n~n")
  (printf "Replay a Chrome DevTools Recorder JSON recording to automate browser~n")
  (printf "interactions and capture the final page state.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl replay <recording.json> [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -v, --verbose       Show detailed step execution~n")
  (printf "  -o, --output FILE   Save results to JSON file~n")
  (printf "  -f, --format FMT    Output format: json (default)~n~n")

  (printf "RECORDING FORMAT~n")
  (printf "  Chrome DevTools Recorder exports JSON files with interaction steps.~n~n")
  (printf "  Supported step types:~n")
  (printf "    navigate          - Go to a URL~n")
  (printf "    click             - Click an element~n")
  (printf "    doubleClick       - Double-click an element~n")
  (printf "    change            - Fill in a form field~n")
  (printf "    keyDown/keyUp     - Keyboard input~n")
  (printf "    scroll            - Scroll page or element~n")
  (printf "    hover             - Hover over element~n")
  (printf "    waitForElement    - Wait for element to appear~n")
  (printf "    waitForExpression - Wait for JS expression~n")
  (printf "    setViewport       - Set browser viewport size~n~n")

  (printf "HOW TO CREATE A RECORDING~n")
  (printf "  1. Open Chrome DevTools (F12)~n")
  (printf "  2. Click 'More tools' > 'Recorder' (or Ctrl+Shift+P, type 'Recorder')~n")
  (printf "  3. Click 'Start new recording', name it, click 'Start'~n")
  (printf "  4. Perform your interactions in the browser~n")
  (printf "  5. Click 'End recording'~n")
  (printf "  6. Click 'Export' > 'JSON' to save the recording file~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Basic replay~n")
  (printf "  ar-crawl replay login-flow.json~n~n")
  (printf "  # Replay with verbose output~n")
  (printf "  ar-crawl replay checkout.json -v~n~n")
  (printf "  # Save final page state~n")
  (printf "  ar-crawl replay user-journey.json -o result.json~n~n")
  (printf "  # Then extract data from the result~n")
  (printf "  ar-crawl extract result.json --fields '{\"title\": \"//title\"}'~n~n")

  (printf "OUTPUT~n")
  (printf "  Returns JSON with:~n")
  (printf "    content           - Final page HTML~n")
  (printf "    url               - Final page URL~n")
  (printf "    title             - Page title~n")
  (printf "    links             - All links on page~n")
  (printf "    recording.title   - Recording name~n")
  (printf "    recording.stepsExecuted - Number of steps run~n")
  (printf "    recording.stepResults - Per-step success/failure~n~n")

  (printf "NOTE~n")
  (printf "  This command uses Playwright and requires the playwright service.~n")
  (printf "  It will be started automatically if not running.~n~n"))

;; @function{show-session-help}
;; @description{Show help for session command}
(define (show-session-help)
  (printf "~nSESSION - Interactive Playwright session for LLM agents~n")
  (printf "========================================================~n~n")
  (printf "Start an interactive browser session that accepts Playwright commands as JSON.~n")
  (printf "Designed for LLM agents to drive browser automation with step recording.~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl session [options]~n~n")

  (printf "OPTIONS~n")
  (printf "  -v, --verbose       Show debug output~n~n")

  (printf "COMMANDS (stdin)~n")
  (printf "  {\"type\": \"...\", ...}   Execute Playwright action (JSON)~n")
  (printf "  state                   Get current page state (url/title only)~n")
  (printf "  state --actions         Get clickable elements~n")
  (printf "  state --forms           Get form inputs~n")
  (printf "  state --full            Get full accessibility snapshot~n")
  (printf "  state --html            Include raw HTML in response~n")
  (printf "  state --fields '...'    Extract fields by XPath (JSON map)~n")
  (printf "  state --parent \"...\" --fields '...'~n")
  (printf "                          Extract repeated items with parent context~n")
  (printf "  commit [file]           End session, output/save recording~n")
  (printf "  exit                    Close session without saving~n")
  (printf "  help                    Show available actions~n~n")

  (printf "PLAYWRIGHT ACTIONS (JSON format)~n")
  (printf "  Navigation:~n")
  (printf "    {\"type\": \"goto\", \"url\": \"https://...\"}~n")
  (printf "    {\"type\": \"goBack\"}~n")
  (printf "    {\"type\": \"goForward\"}~n")
  (printf "    {\"type\": \"reload\"}~n~n")

  (printf "  Interaction:~n")
  (printf "    {\"type\": \"click\", \"selector\": \"#button\"}~n")
  (printf "    {\"type\": \"dblclick\", \"selector\": \".item\"}~n")
  (printf "    {\"type\": \"fill\", \"selector\": \"input[name=q]\", \"value\": \"search\"}~n")
  (printf "    {\"type\": \"type\", \"selector\": \"#input\", \"text\": \"hello\", \"delay\": 50}~n")
  (printf "    {\"type\": \"selectOption\", \"selector\": \"select\", \"value\": \"opt1\"}~n")
  (printf "    {\"type\": \"check\", \"selector\": \"#checkbox\"}~n")
  (printf "    {\"type\": \"uncheck\", \"selector\": \"#checkbox\"}~n")
  (printf "    {\"type\": \"hover\", \"selector\": \".menu\"}~n")
  (printf "    {\"type\": \"focus\", \"selector\": \"#input\"}~n~n")

  (printf "  Keyboard:~n")
  (printf "    {\"type\": \"press\", \"key\": \"Enter\"}~n")
  (printf "    {\"type\": \"press\", \"selector\": \"#input\", \"key\": \"Tab\"}~n")
  (printf "    {\"type\": \"keyDown\", \"key\": \"Shift\"}~n")
  (printf "    {\"type\": \"keyUp\", \"key\": \"Shift\"}~n~n")

  (printf "  Scroll:~n")
  (printf "    {\"type\": \"scroll\", \"x\": 0, \"y\": 500}~n")
  (printf "    {\"type\": \"scrollIntoView\", \"selector\": \"#footer\"}~n~n")

  (printf "  Wait:~n")
  (printf "    {\"type\": \"waitForSelector\", \"selector\": \".loaded\"}~n")
  (printf "    {\"type\": \"waitForNavigation\"}~n")
  (printf "    {\"type\": \"waitForLoadState\", \"state\": \"networkidle\"}~n")
  (printf "    {\"type\": \"waitForTimeout\", \"timeout\": 1000}~n~n")

  (printf "  Capture:~n")
  (printf "    {\"type\": \"screenshot\"}~n")
  (printf "    {\"type\": \"screenshot\", \"selector\": \"#element\", \"fullPage\": true}~n")
  (printf "    {\"type\": \"evaluate\", \"expression\": \"document.title\"}~n~n")

  (printf "  Viewport:~n")
  (printf "    {\"type\": \"setViewport\", \"width\": 1280, \"height\": 720}~n~n")

  (printf "  Custom (for recording notes):~n")
  (printf "    {\"type\": \"customStep\", \"name\": \"thought\", \"parameters\": {\"note\": \"...\"}}}~n~n")

  (printf "OUTPUT FORMAT~n")
  (printf "  All output is JSON, one object per line:~n")
  (printf "  - Session start: {\"sessionId\": \"...\", \"status\": \"ready\"}~n")
  (printf "  - Action result: {\"success\": true, \"url\": \"...\", \"title\": \"...\"}~n")
  (printf "  - State (basic): {\"url\": \"...\", \"title\": \"...\"}~n")
  (printf "  - State (--actions/--forms/--full): includes \"snapshot\": {...}~n")
  (printf "  - State (--fields): includes \"results\": {...} or [...]~n")
  (printf "  - Commit: {\"status\": \"committed\", \"recording\": {...}}~n")
  (printf "  - Error: {\"success\": false, \"error\": \"...\"}~n~n")

  (printf "EXAMPLES~n")
  (printf "  # Start session and navigate~n")
  (printf "  $ ar-crawl session~n")
  (printf "  {\"sessionId\":\"abc-123\",\"status\":\"ready\"}~n")
  (printf "  {\"type\": \"goto\", \"url\": \"https://example.com\"}~n")
  (printf "  {\"success\":true,\"url\":\"https://example.com/\",\"title\":\"Example\"}~n~n")

  (printf "  # Get page state (basic - url/title only)~n")
  (printf "  state~n")
  (printf "  {\"url\":\"...\",\"title\":\"...\"}~n~n")

  (printf "  # Get clickable elements or form inputs~n")
  (printf "  state --actions~n")
  (printf "  state --forms~n~n")

  (printf "  # Extract data using XPath~n")
  (printf "  state --fields '{\"title\": \"//h1\", \"links\": \"//a/@href\"}'~n")
  (printf "  {\"url\":\"...\",\"title\":\"...\",\"results\":{\"title\":\"Page Title\",\"links\":[...]}}~n~n")

  (printf "  # Extract repeated items (e.g., table rows)~n")
  (printf "  state --parent \"//tr\" --fields '{\"name\": \".//td[1]\", \"price\": \".//td[2]\"}'~n")
  (printf "  {\"url\":\"...\",\"title\":\"...\",\"results\":[{\"name\":\"...\",\"price\":\"...\"},...]}}~n~n")

  (printf "  # Save recording~n")
  (printf "  commit flow.json~n")
  (printf "  {\"status\":\"committed\",\"file\":\"flow.json\"}~n~n")

  (printf "RECORDING FORMAT~n")
  (printf "  Sessions produce Chrome DevTools Recorder compatible JSON:~n")
  (printf "  {\"title\": \"LLM Agent Session\", \"steps\": [...]}~n~n")
  (printf "  Use 'ar-crawl replay' to replay recordings.~n~n")

  (printf "NOTES~n")
  (printf "  - Selectors: CSS, XPath (//), text=, aria/, [data-testid=\"\"]~n")
  (printf "  - All actions support optional \"timeout\" parameter (ms)~n")
  (printf "  - This command uses Playwright and requires the playwright service.~n")
  (printf "  - Service starts automatically if not running.~n~n"))

(define (show-android-help)
  (printf "~nANDROID - Control Android emulators for mobile automation~n")
  (printf "===========================================================~n~n")
  (printf "Start Android automation sessions to test mobile apps and mobile web.~n")
  (printf "Uses Playwright's experimental Android API via ADB.~n~n")

  (printf "PREREQUISITES~n")
  (printf "  - Android SDK with ADB installed~n")
  (printf "  - Android emulator running OR physical device connected~n")
  (printf "  - ADB daemon started: adb start-server~n")
  (printf "  - Device authorized (check: adb devices)~n~n")

  (printf "SUBCOMMANDS~n")
  (printf "  devices                     List connected Android devices~n")
  (printf "  session <serial>            Start interactive session on device~n")
  (printf "  replay <file.json>          Replay a recording~n")
  (printf "  baseline [pkg|apk]          Capture baseline screenshot for visual regression~n")
  (printf "  test <script.json>          Run test scripts for APK verification~n")
  (printf "  verify <app.apk>            Complete APK verification workflow~n~n")

  (printf "USAGE~n")
  (printf "  ar-crawl android devices~n")
  (printf "  ar-crawl android session <device-serial>~n")
  (printf "  ar-crawl android replay <recording.json> [options]~n")
  (printf "  ar-crawl android baseline [package|app.apk] [options]~n")
  (printf "  ar-crawl android test <script.json> [options]~n")
  (printf "  ar-crawl android verify <app.apk> [options]~n~n")

  (printf "REPLAY OPTIONS~n")
  (printf "  -d, --device <serial>       Target device (default: from recording)~n")
  (printf "  -s, --speed <multiplier>    Replay speed (default: 1.0)~n")
  (printf "      --screenshots           Capture screenshot per step~n~n")

  (printf "BASELINE OPTIONS~n")
  (printf "  -d, --device <serial>       Target device (default: first available)~n")
  (printf "  -o, --output <file>         Output file path for baseline image~n")
  (printf "  -n, --name <name>           Baseline name/identifier~n")
  (printf "      --apk <path>            APK file to install before capturing~n")
  (printf "  -p, --pkg <package>         Package name to launch~n")
  (printf "  -w, --wait <ms>             Wait time after launch (default: 2000)~n~n")

  (printf "TEST OPTIONS~n")
  (printf "  -d, --device <serial>       Target device (default: first available)~n")
  (printf "  -p, --pkg <package>         Package name (optional, for crash detection)~n")
  (printf "      --continue              Continue running after failures~n")
  (printf "      --delay <ms>            Delay between steps in ms (default: 500)~n")
  (printf "  -o, --output <file>         Output results file (JSON)~n~n")

  (printf "VERIFY OPTIONS~n")
  (printf "  -d, --device <serial>       Target device (default: first available)~n")
  (printf "  -b, --baseline <file>       Baseline screenshot for visual comparison~n")
  (printf "  -s, --script <file>         Test script (JSON) to execute~n")
  (printf "  -p, --pkg <package>         Package name (required with --skip-install)~n")
  (printf "  -t, --threshold <pct>       Visual diff threshold percentage (default: 0)~n")
  (printf "  -w, --wait <ms>             Wait time after launch (default: 3000)~n")
  (printf "  -o, --output <file>         Output results file (JSON)~n")
  (printf "      --continue              Continue even if visual diff fails~n")
  (printf "      --skip-install          Skip APK install, test already-running app~n~n")

  (printf "SESSION COMMANDS (stdin)~n")
  (printf "  {\"type\": \"...\", ...}        Execute Android action (JSON)~n")
  (printf "  state                       Get current session state~n")
  (printf "  screenshot [file.png]       Take screenshot~n")
  (printf "  webviews                    List active WebViews~n")
  (printf "  shell <command>             Run ADB shell command~n")
  (printf "  commit [file.json]          End session, output/save recording~n")
  (printf "  exit                        Close session without saving~n")
  (printf "  help                        Show available actions~n~n")

  (printf "ANDROID ACTIONS (JSON format)~n")
  (printf "  Tap:~n")
  (printf "    {\"type\": \"tap\", \"selector\": \"text=Submit\"}~n")
  (printf "    {\"type\": \"tap\", \"selector\": \"res=com.example:id/button\"}~n")
  (printf "    {\"type\": \"longTap\", \"selector\": \"text=Item\"}~n~n")

  (printf "  Gestures:~n")
  (printf "    {\"type\": \"swipe\", \"selector\": \"res=list\", \"direction\": \"up\", \"percent\": 50}~n")
  (printf "    {\"type\": \"scroll\", \"selector\": \"res=view\", \"direction\": \"down\"}~n")
  (printf "    {\"type\": \"fling\", \"selector\": \"res=list\", \"direction\": \"down\"}~n")
  (printf "    {\"type\": \"pinchOpen\", \"selector\": \"res=image\", \"percent\": 50}~n")
  (printf "    {\"type\": \"pinchClose\", \"selector\": \"res=image\", \"percent\": 50}~n")
  (printf "    {\"type\": \"drag\", \"selector\": \"res=item\", \"dest\": {\"x\": 500, \"y\": 800}}~n~n")

  (printf "  Text Input:~n")
  (printf "    {\"type\": \"fill\", \"selector\": \"res=input\", \"text\": \"hello\"}~n")
  (printf "    {\"type\": \"type\", \"text\": \"hello\"}  (to focused element)~n")
  (printf "    {\"type\": \"press\", \"key\": \"Enter\"}~n~n")

  (printf "  Wait:~n")
  (printf "    {\"type\": \"wait\", \"selector\": \"text=Loading\", \"state\": \"gone\"}~n~n")

  (printf "  Browser (launches Chrome):~n")
  (printf "    {\"type\": \"launchBrowser\", \"url\": \"https://example.com\"}~n~n")

  (printf "  Device Operations:~n")
  (printf "    {\"type\": \"screenshot\"}~n")
  (printf "    {\"type\": \"info\"}                    Get device info~n")
  (printf "    {\"type\": \"info\", \"selector\": \"...\"}  Get widget info~n~n")

  (printf "SELECTOR FORMATS~n")
  (printf "  res=com.example:id/button    Resource ID~n")
  (printf "  text=Submit                  Text content~n")
  (printf "  desc=Menu button             Content description~n")
  (printf "  class=android.widget.Button  Widget class~n")
  (printf "  res=btn&&text=OK             Compound (AND)~n~n")

  (printf "EXAMPLES~n")
  (printf "  # List devices~n")
  (printf "  $ ar-crawl android devices~n")
  (printf "  {\"devices\":[{\"serial\":\"emulator-5554\",\"model\":\"sdk_gphone64\"}]}~n~n")

  (printf "  # Start session~n")
  (printf "  $ ar-crawl android session emulator-5554~n")
  (printf "  {\"sessionId\":\"android-abc123\",\"status\":\"ready\"}~n~n")

  (printf "  # Tap and swipe~n")
  (printf "  {\"type\": \"tap\", \"selector\": \"text=Settings\"}~n")
  (printf "  {\"type\": \"swipe\", \"selector\": \"res=list\", \"direction\": \"up\"}~n~n")

  (printf "  # Save recording~n")
  (printf "  commit mobile-flow.json~n~n")

  (printf "  # Replay on another device~n")
  (printf "  $ ar-crawl android replay mobile-flow.json -d emulator-5556~n~n")

  (printf "  # Capture baseline screenshot~n")
  (printf "  $ ar-crawl android baseline com.example.app -o baseline.png~n")
  (printf "  {\"status\":\"captured\",\"name\":\"baseline-com.example.app-1234\",\"size\":45678}~n~n")

  (printf "  # Capture baseline from APK~n")
  (printf "  $ ar-crawl android baseline app-debug.apk -n initial-state~n~n")

  (printf "  # Run test script~n")
  (printf "  $ ar-crawl android test tests.json -d emulator-5554~n")
  (printf "  {\"test\":{\"passed\":true,\"stepsExecuted\":5,\"stepsPassed\":5,\"duration\":2340}}~n~n")

  (printf "  # Run test with crash detection~n")
  (printf "  $ ar-crawl android test tests.json -p com.example.app -o results.json~n~n")

  (printf "  # Complete APK verification workflow~n")
  (printf "  $ ar-crawl android verify app-debug.apk -b baseline.png -s tests.json~n")
  (printf "  === Step 1: Installing APK ===~n")
  (printf "    ✓ Installed: com.example.app~n")
  (printf "  === Step 2: Launching App ===~n")
  (printf "    ✓ Launched: com.example.app~n")
  (printf "  === Step 3: Visual Comparison ===~n")
  (printf "    ✓ Visual match (diff: 0.00%, threshold: 0%)~n")
  (printf "  === Step 4: Running Test Script ===~n")
  (printf "    ✓ Test passed (5/5 steps)~n")
  (printf "  === Step 5: Crash Detection ===~n")
  (printf "    ✓ No crashes detected~n")
  (printf "  ========================================~n")
  (printf "  VERIFICATION PASSED~n~n")

  (printf "  # Verify with custom threshold~n")
  (printf "  $ ar-crawl android verify app.apk -b baseline.png -t 5 --continue~n~n")

  (printf "RECORDING FORMAT~n")
  (printf "  Android recordings include device metadata:~n")
  (printf "  {\"title\": \"...\", \"device\": {\"serial\": \"...\", \"model\": \"...\"},~n")
  (printf "   \"steps\": [{\"type\": \"android/tap\", ...}], \"metadata\": {...}}~n~n")

  (printf "NOTES~n")
  (printf "  - Requires Playwright service (starts automatically)~n")
  (printf "  - Android API is experimental - some features may change~n")
  (printf "  - WebView automation requires Chrome 87+ on device~n")
  (printf "  - For browser testing, use 'launchBrowser' action~n~n"))

;; @function{show-command-help}
;; @description{Show help for a specific command}
(define (show-command-help command)
  (case (if (string? command) (string->symbol command) command)
    [(crawl) (show-crawl-help)]
    [(crawl-site) (show-crawl-site-help)]
    [(probe) (show-probe-help)]
    [(replay) (show-replay-help)]
    [(session) (show-session-help)]
    [(android) (show-android-help)]
    [(extract) (show-extract-help)]
    [(sample) (show-sample-help)]
    [(health) (show-health-help)]
    [(test) (show-test-help)]
    [(config) (show-config-help)]
    [(services) (show-services-help)]
    [(monitor) (show-monitor-help)]
    [else
     (printf "Unknown command: ~a~n~n" command)
     (printf "Available commands: crawl, crawl-site, probe, replay, session, android, extract, sample, health, test, config, services, monitor~n")
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
(define extract-resolve-urls-param (make-parameter #f))
(define extract-file-types-param (make-parameter '()))
(define extract-extensions-param (make-parameter '()))
(define extract-download-param (make-parameter #f))
(define extract-download-dir-param (make-parameter "downloads"))
(define extract-rate-limit-param (make-parameter 0))
(define extract-skip-existing-param (make-parameter #f))

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

