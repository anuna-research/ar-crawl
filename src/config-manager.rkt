#lang racket

#|
 @title{Configuration Manager}
 @author{Anuna Research}
 @date{2025-01-10}
 
 This module handles configuration loading, validation, and environment
 variable substitution for the production crawler.
|#

(require racket/contract
         racket/string
         racket/file
         json
         (prefix-in utils: "utils.rkt"))

(provide
 (contract-out
  ;; Configuration loading
  [load-config (->* (path-string?) 
                   (#:env-substitution boolean?)
                   hash?)]
  
  [load-config-from-string (->* (string?)
                               (#:env-substitution boolean?)
                               hash?)]
  
  [validate-config (-> hash? boolean?)]
  
  ;; Environment variable handling
  [substitute-env-vars (-> hash? hash?)]
  [get-env-var (-> string? (or/c string? #f))]
  [set-env-var (-> string? string? void?)]
  
  ;; Configuration access
  [get-config-value (->* (hash? (listof any/c))
                        ((or/c any/c #f))
                        any/c)]
  
  [merge-configs (-> hash? hash? hash?)]
  
  ;; Default configurations
  [default-config (-> hash?)]
  [development-config (-> hash?)]
  [production-config-template (-> hash?)]
  
  ;; Configuration file operations
  [create-default-config-file (->* (path-string?) (symbol?) void?)]
  [save-config (-> hash? path-string? void?)]))

;; Configuration Loading
;; ---------------------

;; @function{load-config}
;; @description{Load configuration from JSON file}
(define (load-config config-path #:env-substitution [env-substitution #t])
  (unless (file-exists? config-path)
    (error 'load-config "Configuration file not found: ~a" config-path))
  
  (let* ([json-string (file->string config-path)]
         [config (load-config-from-string json-string 
                                         #:env-substitution env-substitution)])
    
    (unless (validate-config config)
      (error 'load-config "Invalid configuration in file: ~a" config-path))
    
    config))

;; @function{load-config-from-string}
;; @description{Load configuration from JSON string}
(define (load-config-from-string json-string #:env-substitution [env-substitution #t])
  (with-handlers ([exn:fail:read?
                   (lambda (e)
                     (error 'load-config-from-string 
                           "Invalid JSON: ~a" (exn-message e)))])
    
    (let ([config (string->jsexpr json-string)])
      (if env-substitution
          (substitute-env-vars config)
          config))))

;; Configuration Validation
;; -------------------------

;; @function{validate-config}
;; @description{Validate configuration structure}
(define (validate-config config)
  (and (hash? config)
       (hash-has-key? config 'crawler)
       (hash-has-key? config 'services)
       (validate-crawler-config (hash-ref config 'crawler))
       (validate-services-config (hash-ref config 'services))))

;; @function{validate-crawler-config}
;; @description{Validate crawler section}
(define (validate-crawler-config crawler-config)
  (and (hash? crawler-config)
       (hash-has-key? crawler-config 'services)
       (list? (hash-ref crawler-config 'services))
       (not (empty? (hash-ref crawler-config 'services)))
       (hash-has-key? crawler-config 'rate_limit_ms)
       (exact-positive-integer? (hash-ref crawler-config 'rate_limit_ms))
       (hash-has-key? crawler-config 'timeout_ms)
       (exact-positive-integer? (hash-ref crawler-config 'timeout_ms))))

;; @function{validate-services-config}
;; @description{Validate services section}
(define (validate-services-config services-config)
  (and (hash? services-config)
       (not (hash-empty? services-config))
       (andmap (lambda (service-config)
                 (hash? service-config))
               (hash-values services-config))))

;; Environment Variable Substitution
;; ----------------------------------

;; @function{substitute-env-vars}
;; @description{Recursively substitute environment variables in config}
(define (substitute-env-vars config)
  (cond
    [(hash? config)
     (for/hash ([(key value) (in-hash config)])
       (values key (substitute-env-vars value)))]
    
    [(list? config)
     (map substitute-env-vars config)]
    
    [(string? config)
     (substitute-string-env-vars config)]
    
    [else config]))

;; @function{substitute-string-env-vars}
;; @description{Substitute environment variables in a string}
(define (substitute-string-env-vars str)
  (regexp-replace* 
   #rx"\\$\\{([^}]+)\\}"
   str
   (lambda (match var-name)
     (or (getenv var-name)
         (begin
           (printf "Warning: Environment variable ~a not found, using empty string~n" var-name)
           "")))))

;; @function{get-env-var}
;; @description{Get environment variable with fallback}
(define (get-env-var var-name [default #f])
  (or (getenv var-name) default))

;; @function{set-env-var}
;; @description{Set environment variable}
(define (set-env-var var-name value)
  (putenv var-name value))

;; Configuration Access
;; --------------------

;; @function{get-config-value}
;; @description{Get nested configuration value}
(define (get-config-value config path [default #f])
  (define (get-nested current-config remaining-path)
    (cond
      [(empty? remaining-path) current-config]
      [(not (hash? current-config)) default]
      [else
       (let ([key (car remaining-path)]
             [rest (cdr remaining-path)])
         (if (hash-has-key? current-config key)
             (get-nested (hash-ref current-config key) rest)
             default))]))
  
  (get-nested config path))

;; @function{merge-configs}
;; @description{Deep merge two configurations}
(define (merge-configs base-config override-config)
  (utils:deep-merge-hash base-config override-config))

;; Default Configurations
;; ----------------------

;; @function{default-config}
;; @description{Get default configuration}
(define (default-config)
  (hash 
   'crawler (hash
             'services '("direct")
             'fallback_enabled #t
             'max_concurrent_jobs 10
             'rate_limit_ms 1000
             'retry_attempts 3
             'timeout_ms 30000
             'enable_monitoring #t
             'log_level "info"
             'output_format "json")
   
   'services (hash
              'direct (hash
                      'timeout 30000
                      'user-agent "AR-Crawl/1.0"
                      'follow_redirects #t)
              
              'firecrawl (hash
                          'api_key "${FIRECRAWL_API_KEY}"
                          'formats '("markdown" "html")
                          'only_main_content #t)
              
              'scrapingbee (hash
                            'api_key "${SCRAPINGBEE_API_KEY}"
                            'render_js #t
                            'premium_proxy #f))
   
   'monitoring (hash
                'metrics_enabled #t
                'health_check_interval 300)
   
   'storage (hash
             'output_directory "./output"
             'temp_directory "./temp")
   
   'security (hash
              'respect_robots_txt #t
              'max_redirects 5)))

;; @function{development-config}
;; @description{Get development configuration}
(define (development-config)
  (merge-configs 
   (default-config)
   (hash 'crawler (hash
   'log_level "debug"
   'rate_limit_ms 500
   'max_concurrent_jobs 5)
         'monitoring (hash
                      'health_check_interval 60))))

;; @function{production-config-template}
;; @description{Get production configuration template}
(define (production-config-template)
  (merge-configs
   (default-config)
   (hash 'crawler (hash
   'services '("direct" "firecrawl" "scrapingbee" "browserless" "scraperapi")
   'max_concurrent_jobs 50
   'rate_limit_ms 1000
   'log_level "info")
         
         'services (hash
                    'browserless (hash
                                  'api_key "${BROWSERLESS_API_KEY}"
                                  'block_ads #t
                                  'stealth #t)
                    
                    'scraperapi (hash
                                 'api_key "${SCRAPERAPI_API_KEY}"
                                 'render #t
                                 'country_code "us"))
         
         'monitoring (hash
                      'alert_thresholds (hash
                                         'error_rate 0.1
                                         'response_time 10000))
         
         'rate_limiting (hash
                         'requests_per_minute 60
                         'burst_limit 10))))

;; Configuration File Operations
;; -----------------------------

;; @function{save-config}
;; @description{Save configuration to file}
(define (save-config config file-path)
  (utils:ensure-directory (path-only file-path))
  (call-with-output-file file-path
    (lambda (port)
      (write-json config port #:indent 2))
    #:exists 'replace))

;; @function{create-default-config-file}
;; @description{Create default configuration file}
(define (create-default-config-file file-path [config-type 'default])
  (define config
    (case config-type
      [(development) (development-config)]
      [(production) (production-config-template)]
      [else (default-config)]))
  
  (save-config config file-path)
  (printf "Created ~a configuration file: ~a~n" config-type file-path))

;; Environment Setup
;; -----------------

;; @function{setup-environment}
;; @description{Setup environment for configuration}
(define (setup-environment [env-file ".env"])
  (when (file-exists? env-file)
    (define lines (file->lines env-file))
    (for ([line lines])
      (when (and (not (string-prefix? line "#"))
                 (string-contains? line "="))
        (define parts (string-split line "=" #:limit 2))
        (when (= (length parts) 2)
          (set-env-var (string-trim (car parts))
                      (string-trim (cadr parts)))))))
  
  (printf "Environment setup complete~n"))

;; Unit Tests
;; ----------

(module+ test
  (require rackunit)
  
  (test-case "Environment variable substitution"
    (putenv "TEST_VAR" "test_value")
    (define config (hash 'key "${TEST_VAR}"))
    (define result (substitute-env-vars config))
    (check-equal? (hash-ref result 'key) "test_value"))
  
  (test-case "Configuration validation"
    (define valid-config (default-config))
    (check-true (validate-config valid-config))
    
    (define invalid-config (hash 'invalid "config"))
    (check-false (validate-config invalid-config)))
  
  (test-case "Nested config access"
    (define config (hash 'level1 (hash 'level2 "value")))
    (check-equal? (get-config-value config '(level1 level2)) "value")
    (check-equal? (get-config-value config '(nonexistent) "default") "default"))
  
  (test-case "Config merging"
    (define base (hash 'a 1 'b (hash 'c 2)))
    (define override (hash 'b (hash 'd 3) 'e 4))
    (define merged (merge-configs base override))
    (check-equal? (hash-ref merged 'a) 1)
    (check-equal? (hash-ref (hash-ref merged 'b) 'c) 2)
    (check-equal? (hash-ref (hash-ref merged 'b) 'd) 3)
    (check-equal? (hash-ref merged 'e) 4)))
