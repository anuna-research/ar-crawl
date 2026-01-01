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
     (or (getenv var-name) ""))))

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

;; ============================================================================
;; Unit Tests
;; ============================================================================

(module+ test
  (require rackunit
           racket/file)

  ;; Helper for temp files
  (define (with-temp-config-file content proc)
    (let ([path (make-temporary-file "config-~a.json")])
      (dynamic-wind
        (lambda () (display-to-file content path #:exists 'replace))
        (lambda () (proc path))
        (lambda () (when (file-exists? path) (delete-file path))))))

  ;; Environment Variable Tests
  (test-case "substitute-env-vars in hash"
    (putenv "TEST_VAR" "test_value")
    (define config (hash 'key "${TEST_VAR}"))
    (define result (substitute-env-vars config))
    (check-equal? (hash-ref result 'key) "test_value"))

  (test-case "substitute-env-vars in nested hash"
    (putenv "NESTED_VAR" "nested")
    (define config (hash 'outer (hash 'inner "${NESTED_VAR}")))
    (define result (substitute-env-vars config))
    (check-equal? (hash-ref (hash-ref result 'outer) 'inner) "nested"))

  (test-case "substitute-env-vars in list"
    (putenv "LIST_VAR" "item")
    (define config (list "${LIST_VAR}" "static"))
    (define result (substitute-env-vars config))
    (check-equal? result '("item" "static")))

  (test-case "substitute-env-vars with missing var uses empty string"
    (define config (hash 'key "${NONEXISTENT_VAR_12345}"))
    (define result (substitute-env-vars config))
    (check-equal? (hash-ref result 'key) ""))

  (test-case "substitute-env-vars preserves non-string values"
    (define config (hash 'num 42 'bool #t 'str "text"))
    (define result (substitute-env-vars config))
    (check-equal? (hash-ref result 'num) 42)
    (check-equal? (hash-ref result 'bool) #t))

  (test-case "get-env-var returns value"
    (putenv "GET_TEST" "value")
    (check-equal? (get-env-var "GET_TEST") "value"))

  (test-case "get-env-var returns #f for missing"
    (check-false (get-env-var "MISSING_VAR_99999")))

  (test-case "set-env-var sets value"
    (set-env-var "SET_TEST" "new_value")
    (check-equal? (getenv "SET_TEST") "new_value"))

  ;; Configuration Validation Tests
  (test-case "validate-config accepts valid config"
    (define valid-config (default-config))
    (check-true (validate-config valid-config)))

  (test-case "validate-config rejects non-hash"
    (check-false (validate-config "not a hash"))
    (check-false (validate-config '())))

  (test-case "validate-config rejects missing crawler"
    (check-false (validate-config (hash 'services (hash)))))

  (test-case "validate-config rejects missing services"
    (check-false (validate-config (hash 'crawler (hash)))))

  (test-case "validate-config rejects empty services list"
    (check-false (validate-config
                  (hash 'crawler (hash 'services '()
                                       'rate_limit_ms 1000
                                       'timeout_ms 30000)
                        'services (hash 'direct (hash))))))

  (test-case "validate-config rejects invalid rate_limit_ms"
    (check-false (validate-config
                  (hash 'crawler (hash 'services '("direct")
                                       'rate_limit_ms "not a number"
                                       'timeout_ms 30000)
                        'services (hash 'direct (hash))))))

  ;; Configuration Loading Tests
  (test-case "load-config-from-string parses JSON"
    (define json "{\"crawler\": {\"services\": [\"direct\"], \"rate_limit_ms\": 1000, \"timeout_ms\": 30000}, \"services\": {\"direct\": {}}}")
    (define result (load-config-from-string json #:env-substitution #f))
    (check-true (hash? result))
    (check-true (hash-has-key? result 'crawler)))

  (test-case "load-config-from-string with env substitution"
    (putenv "CONFIG_VAL" "substituted")
    (define json "{\"key\": \"${CONFIG_VAL}\"}")
    (define result (load-config-from-string json))
    (check-equal? (hash-ref result 'key) "substituted"))

  (test-case "load-config-from-string without env substitution"
    (define json "{\"key\": \"${SHOULD_NOT_SUB}\"}")
    (define result (load-config-from-string json #:env-substitution #f))
    (check-equal? (hash-ref result 'key) "${SHOULD_NOT_SUB}"))

  (test-case "load-config-from-string rejects invalid JSON"
    (check-exn exn:fail?
               (lambda () (load-config-from-string "not json"))))

  (test-case "load-config loads from file"
    (with-temp-config-file
     (jsexpr->string (default-config))
     (lambda (path)
       (define result (load-config path))
       (check-true (hash? result))
       (check-true (validate-config result)))))

  (test-case "load-config fails for missing file"
    (check-exn exn:fail?
               (lambda () (load-config "/nonexistent/path/config.json"))))

  (test-case "load-config fails for invalid config"
    (with-temp-config-file
     "{\"invalid\": true}"
     (lambda (path)
       (check-exn exn:fail?
                  (lambda () (load-config path))))))

  ;; Configuration Access Tests
  (test-case "get-config-value retrieves nested values"
    (define config (hash 'level1 (hash 'level2 (hash 'level3 "value"))))
    (check-equal? (get-config-value config '(level1 level2 level3)) "value"))

  (test-case "get-config-value returns default for missing path"
    (define config (hash 'a 1))
    (check-equal? (get-config-value config '(nonexistent) "default") "default"))

  (test-case "get-config-value returns default for non-hash intermediate"
    (define config (hash 'a "not a hash"))
    (check-equal? (get-config-value config '(a b) "default") "default"))

  (test-case "get-config-value with empty path returns config"
    (define config (hash 'a 1))
    (check-equal? (get-config-value config '()) config))

  ;; Config Merging Tests
  (test-case "merge-configs merges deeply"
    (define base (hash 'a 1 'b (hash 'c 2)))
    (define override (hash 'b (hash 'd 3) 'e 4))
    (define merged (merge-configs base override))
    (check-equal? (hash-ref merged 'a) 1)
    (check-equal? (hash-ref (hash-ref merged 'b) 'c) 2)
    (check-equal? (hash-ref (hash-ref merged 'b) 'd) 3)
    (check-equal? (hash-ref merged 'e) 4))

  (test-case "merge-configs override wins for same keys"
    (define base (hash 'a 1))
    (define override (hash 'a 2))
    (check-equal? (hash-ref (merge-configs base override) 'a) 2))

  ;; Default Configurations Tests
  (test-case "default-config returns valid config"
    (define config (default-config))
    (check-true (validate-config config))
    (check-true (hash-has-key? config 'crawler))
    (check-true (hash-has-key? config 'services)))

  (test-case "development-config returns valid config"
    (define config (development-config))
    (check-true (validate-config config))
    (check-equal? (get-config-value config '(crawler log_level)) "debug"))

  (test-case "production-config-template returns valid config"
    (define config (production-config-template))
    (check-true (validate-config config))
    (check-true (> (length (get-config-value config '(crawler services))) 1)))

  ;; File Operations Tests
  (test-case "save-config writes JSON file"
    (let ([path (make-temporary-file "save-test-~a.json")])
      (dynamic-wind
        void
        (lambda ()
          (save-config (hash 'test "value") path)
          (check-true (file-exists? path))
          (let ([content (file->string path)])
            (check-true (string-contains? content "test"))))
        (lambda () (when (file-exists? path) (delete-file path))))))

  (test-case "save-config creates parent directory"
    (let ([dir (make-temporary-file "savedir-~a" 'directory)])
      (dynamic-wind
        void
        (lambda ()
          (let ([path (build-path dir "sub" "config.json")])
            (save-config (hash 'a 1) path)
            (check-true (file-exists? path))))
        (lambda () (delete-directory/files dir)))))

  (test-case "create-default-config-file creates default config"
    (let ([path (make-temporary-file "create-test-~a.json")])
      (dynamic-wind
        (lambda () (when (file-exists? path) (delete-file path)))
        (lambda ()
          (create-default-config-file path)
          (check-true (file-exists? path))
          (let ([loaded (load-config path)])
            (check-true (validate-config loaded))))
        (lambda () (when (file-exists? path) (delete-file path))))))

  (test-case "create-default-config-file creates development config"
    (let ([path (make-temporary-file "dev-test-~a.json")])
      (dynamic-wind
        (lambda () (when (file-exists? path) (delete-file path)))
        (lambda ()
          (create-default-config-file path 'development)
          (let ([loaded (load-config path)])
            (check-equal? (get-config-value loaded '(crawler log_level)) "debug")))
        (lambda () (when (file-exists? path) (delete-file path))))))

  (test-case "create-default-config-file creates production config"
    (let ([path (make-temporary-file "prod-test-~a.json")])
      (dynamic-wind
        (lambda () (when (file-exists? path) (delete-file path)))
        (lambda ()
          (create-default-config-file path 'production)
          (let ([loaded (load-config path #:env-substitution #f)])
            (check-true (validate-config loaded))))
        (lambda () (when (file-exists? path) (delete-file path)))))))
