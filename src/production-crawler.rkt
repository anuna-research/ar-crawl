#lang racket

#|
 @title{Production Web Crawler}
 @author{Anuna Research}
 @date{2025-01-10}
 
 This module provides a production-ready web crawler with service fallbacks,
 robust error handling, monitoring, and configuration management.
|#

(require racket/contract
         racket/logging
         racket/async-channel
         data/queue
         json
         uuid
         gregor
         "scraper-interfaces.rkt"
         "crawl-service-adaptor.rkt"
         "utils.rkt")

(provide
 (contract-out
  ;; Main crawler interface
  [create-production-crawler 
   (->* (crawler-config?)
        ()
        production-crawler?)]
  
  [start-crawling 
   (-> production-crawler? string? job-id/c)]
  
  [stop-crawling 
   (-> production-crawler? job-id/c boolean?)]
  
  [get-crawler-status 
   (-> production-crawler? (or/c #f crawler-status?))]
  
  [get-job-results 
   (-> production-crawler? job-id/c (or/c #f job-results?))]
  
  ;; Configuration
  [make-production-crawler-config 
   (->* ()
        (#:services (listof symbol?)
         #:fallback-enabled boolean?
         #:max-concurrent-jobs exact-positive-integer?
         #:rate-limit-ms exact-positive-integer?
         #:retry-attempts exact-positive-integer?
         #:timeout-ms exact-positive-integer?
         #:enable-monitoring boolean?
         #:log-level symbol?
         #:output-format symbol?
         #:service-configs hash?)
        crawler-config?)]
  
  ;; Monitoring and health
  [get-crawler-metrics 
  (-> production-crawler? crawler-metrics?)]
  
  [health-check 
  (-> production-crawler? health-status?)]
   
   ;; Struct accessors
   [crawler-status-active-jobs (-> crawler-status? exact-nonnegative-integer?)]
   [crawler-status-total-jobs (-> crawler-status? exact-nonnegative-integer?)]
   [crawler-status-success-rate (-> crawler-status? real?)]
   [crawler-status-average-response-time (-> crawler-status? real?)]
   [crawler-status-last-error (-> crawler-status? (or/c string? #f))]
   
   [health-status-status (-> health-status? symbol?)]
   [health-status-services (-> health-status? hash?)]
   [health-status-uptime (-> health-status? real?)]
   [health-status-last-check (-> health-status? exact-integer?)]))

;; Data Structures
;; ---------------

(struct crawler-config
  (services                  ; List of crawling services to use
   fallback-enabled         ; Enable automatic fallback
   max-concurrent-jobs      ; Maximum concurrent crawling jobs
   rate-limit-ms           ; Rate limit between requests
   retry-attempts          ; Number of retry attempts
   timeout-ms              ; Request timeout
   enable-monitoring       ; Enable metrics collection
   log-level               ; Logging level
   output-format           ; Output format (json, csv, etc.)
   service-configs)        ; Service-specific configurations
  #:transparent)

(struct production-crawler
  (config
   job-manager
   metrics-collector
   logger
   [active-jobs #:mutable]
   [completed-jobs #:mutable]
   [job-counter #:mutable])
  #:transparent)

(struct crawler-job
  (id
   url
   config
   [status #:mutable]
   start-time
   [end-time #:mutable]
   [results #:mutable]
   [errors #:mutable]
   [attempts #:mutable])
  #:transparent)

(struct crawler-status
  (active-jobs
   total-jobs
   success-rate
   average-response-time
   last-error)
  #:transparent)

(struct crawler-metrics
  (requests-total
   requests-successful
   requests-failed
   average-response-time
   services-used
   errors-by-type)
  #:transparent)

(struct health-status
  (status        ; 'healthy | 'degraded | 'unhealthy
   services      ; Service health map
   uptime        ; Uptime in seconds
   last-check)   ; Last health check time
  #:transparent)

;; Configuration Functions
;; -----------------------

;; @function{make-production-crawler-config}
;; @description{Create production crawler configuration}
(define (make-production-crawler-config
         #:services [services '(firecrawl scrapingbee browserless scraperapi)]
         #:fallback-enabled [fallback-enabled #t]
         #:max-concurrent-jobs [max-concurrent-jobs 10]
         #:rate-limit-ms [rate-limit-ms 1000]
         #:retry-attempts [retry-attempts 3]
         #:timeout-ms [timeout-ms 30000]
         #:enable-monitoring [enable-monitoring #t]
         #:log-level [log-level 'info]
         #:output-format [output-format 'json]
         #:service-configs [service-configs (hash)])
  
  (crawler-config services
                            fallback-enabled
                            max-concurrent-jobs
                            rate-limit-ms
                            retry-attempts
                            timeout-ms
                            enable-monitoring
                            log-level
                            output-format
                            service-configs))

;; Crawler Creation
;; ----------------

;; @function{create-production-crawler}
;; @description{Create a new production crawler instance}
(define (create-production-crawler config)
  (define logger (make-logger 'production-crawler))
  
  (define job-manager (make-job-manager config logger))
  
  (define metrics-collector 
    (if (crawler-config-enable-monitoring config)
        (make-metrics-collector)
        #f))
  
  (log-info logger "Production crawler created with config: ~a" config)
  
  (production-crawler config
                     job-manager
                     metrics-collector
                     logger
                     (make-hash)    ; active-jobs
                     (make-hash)    ; completed-jobs
                     0))            ; job-counter

;; Job Management
;; --------------

;; @function{start-crawling}
;; @description{Start a new crawling job}
(define (start-crawling crawler url)
  (define config (production-crawler-config crawler))
  (define logger (production-crawler-logger crawler))
  (define job-id (uuid-string))
  
  (log-info logger "Starting crawling job ~a for URL: ~a" job-id url)
  
  (define job (crawler-job job-id
                          url
                          config
                          'running
                          (current-milliseconds)
                          #f     ; end-time
                          #f     ; results
                          '()    ; errors
                          0))    ; attempts
  
  ;; Store job
  (hash-set! (production-crawler-active-jobs crawler) job-id job)
  (set-production-crawler-job-counter! crawler 
                                      (add1 (production-crawler-job-counter crawler)))
  
  ;; Start job in thread
  (thread (lambda () (execute-crawling-job crawler job)))
  
  job-id)

;; @function{stop-crawling}
;; @description{Stop a running crawling job}
(define (stop-crawling crawler job-id)
  (define active-jobs (production-crawler-active-jobs crawler))
  (define job (hash-ref active-jobs job-id #f))
  
  (if job
      (begin
        (set-crawler-job-status! job 'cancelled)
        (set-crawler-job-end-time! job (current-milliseconds))
        (hash-remove! active-jobs job-id)
        (log-info (production-crawler-logger crawler) 
                 "Stopped crawling job: ~a" job-id)
        #t)
      #f))

;; Job Execution
;; -------------

;; @function{execute-crawling-job}
;; @description{Execute a single crawling job with retries and fallbacks}
(define (execute-crawling-job crawler job)
  (define config (production-crawler-config crawler))
  (define logger (production-crawler-logger crawler))
  (define services (crawler-config-services config))
  (define max-attempts (crawler-config-retry-attempts config))
  
  (define (attempt-crawl attempt-num)
    (when (< attempt-num max-attempts)
      (set-crawler-job-attempts! job (add1 (crawler-job-attempts job)))
      
      (log-debug logger "Crawling attempt ~a/~a for job ~a" 
                (add1 attempt-num) max-attempts (crawler-job-id job))
      
      (define start-time (current-milliseconds))
      
      (define result
        (if (crawler-config-fallback-enabled config)
            (fetch-with-fallback (crawler-job-url job) services
                               #:config (crawler-config-service-configs config)
                               #:max-retries 1)
            (call-service (car services) (crawler-job-url job) 
                         (hash-ref (crawler-config-service-configs config) 
                                  (car services) (hash)))))
      
      (define end-time (current-milliseconds))
      (define response-time (- end-time start-time))
      
      ;; Update metrics
      (when (production-crawler-metrics-collector crawler)
        (record-request-metrics (production-crawler-metrics-collector crawler)
                               result response-time))
      
      (cond
        [result
        ;; Success
        (set-crawler-job-results! job result)
        (set-crawler-job-status! job 'completed)
        (set-crawler-job-end-time! job end-time)
        (log-info logger "Crawling job ~a completed successfully" 
                   (crawler-job-id job))]
        
        [(< (add1 attempt-num) max-attempts)
         ;; Retry
         (define error-msg (format "Attempt ~a failed, retrying..." (add1 attempt-num)))
         (set-crawler-job-errors! job 
                                 (cons error-msg (crawler-job-errors job)))
         (log-warning logger "Job ~a: ~a" (crawler-job-id job) error-msg)
         (sleep (/ (crawler-config-rate-limit-ms config) 1000))
         (attempt-crawl (add1 attempt-num))]
        
        [else
         ;; Final failure
         (set-crawler-job-status! job 'failed)
         (set-crawler-job-end-time! job end-time)
         (define error-msg "All retry attempts exhausted")
         (set-crawler-job-errors! job 
                                 (cons error-msg (crawler-job-errors job)))
         (log-error logger "Job ~a failed: ~a" (crawler-job-id job) error-msg)]))
    
    ;; Move from active jobs to completed jobs when done
    (hash-set! (production-crawler-completed-jobs crawler) 
               (crawler-job-id job) job)
    (hash-remove! (production-crawler-active-jobs crawler) 
                  (crawler-job-id job)))
  
  (attempt-crawl 0))

;; Status and Results
;; ------------------

;; @function{get-crawler-status}
;; @description{Get current crawler status}
(define (get-crawler-status crawler)
  (define active-jobs (hash-values (production-crawler-active-jobs crawler)))
  (define total-jobs (production-crawler-job-counter crawler))
  
  (define metrics (if (production-crawler-metrics-collector crawler)
                     (get-current-metrics (production-crawler-metrics-collector crawler))
                     #f))
  
  (define success-rate 
    (if (and metrics (> (crawler-metrics-requests-total metrics) 0))
        (/ (crawler-metrics-requests-successful metrics)
           (crawler-metrics-requests-total metrics))
        0))
  
  (crawler-status (length active-jobs)
                 total-jobs
                 success-rate
                 (if metrics 
                     (crawler-metrics-average-response-time metrics) 
                     0)
                 (get-last-error crawler)))

;; @function{get-job-results}
;; @description{Get results for a specific job}
(define (get-job-results crawler job-id)
  (define job (or (hash-ref (production-crawler-active-jobs crawler) job-id #f)
                  (hash-ref (production-crawler-completed-jobs crawler) job-id #f)))
  
  (if job
      (job-results (list (crawler-job-results job))
                  (hash 'job-id job-id
                        'url (crawler-job-url job)
                        'status (symbol->string (crawler-job-status job))
                        'duration (if (crawler-job-end-time job)
                                     (- (crawler-job-end-time job)
                                        (crawler-job-start-time job))
                                     #f))
                  (crawler-job-errors job))
      #f))

;; Metrics and Monitoring
;; ----------------------

;; @function{make-metrics-collector}
;; @description{Create metrics collector}
(define (make-metrics-collector)
  (define metrics (make-hash))
  (hash-set! metrics 'requests-total 0)
  (hash-set! metrics 'requests-successful 0)
  (hash-set! metrics 'requests-failed 0)
  (hash-set! metrics 'response-times '())
  (hash-set! metrics 'services-used (make-hash))
  (hash-set! metrics 'errors-by-type (make-hash))
  (hash-set! metrics 'start-time (current-milliseconds))
  metrics)

;; @function{record-request-metrics}
;; @description{Record metrics for a request}
(define (record-request-metrics metrics result response-time)
  (hash-update! metrics 'requests-total add1 0)
  
  (if result
      (hash-update! metrics 'requests-successful add1 0)
      (hash-update! metrics 'requests-failed add1 0))
  
  (hash-update! metrics 'response-times 
               (lambda (times) (cons response-time times)) '()))

;; @function{get-current-metrics}
;; @description{Get current metrics snapshot}
(define (get-current-metrics metrics)
  (define response-times (hash-ref metrics 'response-times '()))
  (define avg-time (if (empty? response-times)
                      0
                      (/ (apply + response-times) (length response-times))))
  
  (crawler-metrics (hash-ref metrics 'requests-total 0)
                  (hash-ref metrics 'requests-successful 0)
                  (hash-ref metrics 'requests-failed 0)
                  avg-time
                  (hash-ref metrics 'services-used (hash))
                  (hash-ref metrics 'errors-by-type (hash))))

;; @function{get-crawler-metrics}
;; @description{Get crawler metrics}
(define (get-crawler-metrics crawler)
  (if (production-crawler-metrics-collector crawler)
      (get-current-metrics (production-crawler-metrics-collector crawler))
      (crawler-metrics 0 0 0 0 (hash) (hash))))

;; Health Checks
;; -------------

;; @function{health-check}
;; @description{Perform health check on crawler and services}
(define (health-check crawler)
  (define config (production-crawler-config crawler))
  (define services (crawler-config-services config))
  
  (define service-health
    (for/hash ([service services])
      (values service (test-service-health service))))
  
  (define healthy-services 
    (length (filter identity (hash-values service-health))))
  
  (define total-services (length services))
  
  (define status
    (cond
      [(= healthy-services total-services) 'healthy]
      [(> healthy-services 0) 'degraded]
      [else 'unhealthy]))
  
  (define uptime 
    (if (production-crawler-metrics-collector crawler)
        (/ (- (current-milliseconds)
              (hash-ref (production-crawler-metrics-collector crawler) 'start-time))
           1000)
        0))
  
  (health-status status
                service-health
                uptime
                (current-milliseconds)))

;; Utility Functions
;; -----------------

;; @function{make-job-manager}
;; @description{Create job manager}
(define (make-job-manager config logger)
  (hash 'config config 'logger logger))

;; @function{get-last-error}
;; @description{Get the last error from any job}
(define (get-last-error crawler)
  (define jobs (hash-values (production-crawler-active-jobs crawler)))
  (define all-errors 
    (apply append (map crawler-job-errors jobs)))
  
  (if (empty? all-errors)
      #f
      (car all-errors)))

;; Logging Helpers
;; ---------------

(define (log-debug logger msg . args)
  (log-message logger 'debug (apply format msg args)))

(define (log-info logger msg . args)
  (log-message logger 'info (apply format msg args)))

(define (log-warning logger msg . args)
  (log-message logger 'warning (apply format msg args)))

(define (log-error logger msg . args)
  (log-message logger 'error (apply format msg args)))

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "Crawler configuration"
    (define config (make-production-crawler-config))
    (check-true (crawler-config? config))
    (check-equal? (crawler-config-services config)
                  '(firecrawl scrapingbee browserless scraperapi)))
  
  (test-case "Crawler creation"
    (define config (make-production-crawler-config))
    (define crawler (create-production-crawler config))
    (check-true (production-crawler? crawler))
    (check-equal? (production-crawler-job-counter crawler) 0))
  
  (test-case "Health status"
    (define config (make-production-crawler-config))
    (define crawler (create-production-crawler config))
    (define health (health-check crawler))
    (check-true (health-status? health))))
