#lang racket

#|
 @title{Universal Scraper CLI}
 @author{Anuna Research}
 @date{2025-06-11}
 
 Main command-line interface for the universal scraper.
|#

(require racket/cmdline
         racket/contract
         racket/match
         racket/string
         racket/path
         uuid
         gregor)

(require "scraper-interfaces.rkt"
         "nlp-xpath-converter.rkt"
         "data-formatter.rkt"
         "universal-web-scraper.rkt"
         "universal-html-parser.rkt"
         "../utils.rkt")

(provide
 (contract-out
  [main (-> void?)]))

;; @function{parse-command-line}
;; @description{Parse command-line arguments into scraper configuration}
;; @returns{scraper-config?} Scraper configuration
(define (parse-command-line)
  (define start-url #f)
  (define description #f)
  (define sample-url #f)
  (define output-dir "./output")
  (define output-format 'json)
  (define url-pattern #f)
  (define use-proxy? #f)
  (define use-cache? #f)
  (define model 'anthropic)
  (define currency "USD")
  (define rate-limit 1000)
  (define max-pages #f)
  
  (command-line
   #:program "universal-scraper"
   #:once-each
   [("-u" "--url") url
                   "Starting URL to scrape"
                   (set! start-url url)]
   
   [("-d" "--description") desc
                           "Natural language description of data to extract"
                           (set! description desc)]
   
   [("-s" "--sample") url
                      "Sample URL for XPath generation (optional)"
                      (set! sample-url url)]
   
   [("-o" "--output") path
                      "Output directory (default: ./output)"
                      (set! output-dir path)]
   
   [("-f" "--format") fmt
                      "Output format: json|csv|ndjson (default: json)"
                      (set! output-format (string->symbol fmt))]
   
   [("-p" "--pattern") regex
                       "URL pattern to follow (optional)"
                       (set! url-pattern regex)]
   
   [("--proxy")
    "Use proxy service"
    (set! use-proxy? #t)]
   
   [("--cache")
    "Use Google cache"
    (set! use-cache? #t)]
   
   [("--model") m
                "LLM model: openai|anthropic (default: anthropic)"
                (set! model (string->symbol m))]
   
   [("--currency") curr
                   "Currency code for price data (default: USD)"
                   (set! currency curr)]
   
   [("--rate-limit") ms
                     "Milliseconds between requests (default: 1000)"
                     (set! rate-limit (string->number ms))]
   
   [("--max-pages") n
                    "Maximum pages to scrape"
                    (set! max-pages (string->number n))]
   
   #:args ()
   
   ;; Validate required arguments
   (unless (and start-url description)
     (displayln "Error: Both --url and --description are required")
     (displayln "Usage: universal-scraper -u URL -d DESCRIPTION [options]")
     (exit 1))
   
   ;; Validate output format
   (unless (member output-format '(json csv ndjson))
     (displayln "Error: Invalid output format. Must be json, csv, or ndjson")
     (exit 1))
   
   ;; Parse extraction spec from description
   (let ([extraction-spec (parse-extraction-description description)])
     (scraper-config start-url
                     extraction-spec
                     url-pattern
                     output-dir
                     output-format
                     use-proxy?
                     use-cache?
                     model
                     rate-limit
                     max-pages
                     currency))))

;; @function{main}
;; @description{Main entry point for the CLI}
;; @returns{void?}
(define (main)
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (displayln (format "Error: ~a" (exn-message exn)))
                     (when (exn:scraper? exn)
                       (displayln "This is a scraper-specific error"))
                     (exit 1))])
    
    (let ([config (parse-command-line)])
      (displayln "Starting Universal Scraper...")
      (displayln (format "URL: ~a" (scraper-config-start-url config)))
      (displayln (format "Description: ~a" 
                         (extraction-spec-parent-description 
                          (scraper-config-extraction-spec config))))
      (displayln (format "Output: ~a (~a format)" 
                         (scraper-config-output-dir config)
                         (scraper-config-output-format config)))
      
      ;; Run the scraper
      (run-scraper config))))

;; @function{run-scraper}
;; @description{Execute the scraping job based on configuration}
;; @param[config]{scraper-config?} Scraper configuration
;; @returns{void?}
(define (run-scraper config)
  ;; Step 1: Generate XPaths from sample page
  (displayln "\nStep 1: Analyzing page structure...")
  (let* ([sample-url (scraper-config-start-url config)]
         [extraction-spec (scraper-config-extraction-spec config)]
         [xpath-targets (spec->xpath-targets extraction-spec sample-url)])
    
    (unless xpath-targets
      (error 'run-scraper "Failed to generate XPath expressions"))
    
    (displayln "Generated XPath expressions successfully")
    
    ;; Step 2: Create parser
    (displayln "\nStep 2: Creating parser...")
    (let ([parser (create-parser-from-xpaths xpath-targets)])
      
      ;; Step 3: Create output formatter
      (displayln "\nStep 3: Setting up output...")
      (let* ([output-path (build-output-path config)]
             [formatter (create-streaming-formatter 
                         (scraper-config-output-format config)
                         output-path)])
        
        ;; Step 4: Create scraping job
        (displayln "\nStep 4: Starting scrape job...")
        (let ([job-id (create-and-monitor-job config parser formatter)])
          
          (displayln (format "\nScraping completed! Job ID: ~a" job-id))
          (displayln (format "Results saved to: ~a" output-path))
          
          ;; Close formatter
          (close-formatter formatter))))))

;; @function{create-parser-from-xpaths}
;; @description{Create a parser function from XPath targets}
;; @param[xpath-targets]{xpath-target?} XPath expressions
;; @returns{parser/c} Parser function
(define (create-parser-from-xpaths xpath-targets)
  (lambda (html-xexp)
    (with-handlers ([exn:fail?
                     (lambda (exn)
                       (displayln (format "Parser error: ~a" 
                                          (exn-message exn)))
                       '())])
      
      ;; Use the existing extract-data function
      (let ([results (extract-data 
                      (hash 'parent_xpath 
                            (xpath-target-parent-xpath xpath-targets)
                            'child_xpaths 
                            (hash->child-xpath-list 
                             (xpath-target-child-xpaths xpath-targets)))
                      html-xexp)])
        
        (if (list? results)
            results
            (list results))))))

;; @function{hash->child-xpath-list}
;; @description{Convert XPath hash to list format expected by extract-data}
;; @param[xpath-hash]{hash?} Hash of field->xpath
;; @returns{list?} List of single-key hashes
(define (hash->child-xpath-list xpath-hash)
  (for/list ([(field xpath) (in-hash xpath-hash)])
    (hash field xpath)))

;; @function{build-output-path}
;; @description{Build output file path from configuration}
;; @param[config]{scraper-config?} Configuration
;; @returns{path-string?} Output file path
(define (build-output-path config)
  (let* ([timestamp (moment->iso8601 (now/moment/utc))]
         [safe-timestamp (string-replace timestamp ":" "-")]
         [filename (format "scrape-~a.~a" 
                           safe-timestamp
                           (scraper-config-output-format config))])
    (build-path (scraper-config-output-dir config) filename)))

;; @function{create-and-monitor-job}
;; @description{Create scraping job and monitor progress}
;; @param[config]{scraper-config?} Configuration
;; @param[parser]{parser/c} Parser function
;; @param[formatter]{formatter?} Output formatter
;; @returns{string?} Job ID
(define (create-and-monitor-job config parser formatter)
  (let ([job-id (uuid-string)]
        [processed-count 0])
    
    ;; Define parser that also writes to formatter
    (define (process-html html-xexp)
      (let ([items (parser html-xexp)])
        (for ([item items])
          (write-item formatter item)
          (set! processed-count (add1 processed-count)))
        
        ;; Progress update
        (when (zero? (modulo processed-count 10))
          (displayln (format "Processed ~a items..." processed-count)))))
    
    ;; Create the scraping job
    (create-scrape-job
     (scraper-config-start-url config)
     (scraper-config-extraction-spec config)
     process-html
     #:pattern (scraper-config-url-pattern config)
     #:use-proxy? (scraper-config-use-proxy? config)
     #:use-cache? (scraper-config-use-cache? config)
     #:max-pages (scraper-config-max-pages config)
     #:rate-limit (scraper-config-rate-limit config))
    
    ;; Monitor job progress
    (monitor-job-progress job-id)
    
    job-id))

;; @function{monitor-job-progress}
;; @description{Monitor and display job progress}
;; @param[job-id]{string?} Job ID
;; @returns{void?}
(define (monitor-job-progress job-id)
  (let loop ()
    (let ([status (get-job-status job-id)])
      (when status
        (match (job-status-state status)
          ['completed 
           (displayln "\nJob completed successfully!")]
          
          ['failed 
           (displayln "\nJob failed!")
           (for ([error (job-status-errors status)])
             (displayln (format "Error: ~a" error)))]
          
          ['running
           (display ".")
           (flush-output)
           (sleep 2)
           (loop)]
          
          [_ (void)])))))

;; Run the program if this is the main module
(module+ main
  (main))
