#lang racket

#|
 @title{NLP to XPath Converter}
 @author{Anuna Research}
 @date{2025-06-11}
 
 This module converts natural language descriptions to structured extraction targets.
|#

(require racket/contract
         racket/match
         racket/string
         json)

(require "scraper-interfaces.rkt"
         "../interpreter/openai.rkt"
         "../interpreter/gcloud.rkt"
         "../utils.rkt")

(provide
 (contract-out
  ;; Parse natural language into extraction targets
  [parse-extraction-description 
   (-> string? extraction-spec?)]
  
  ;; Convert extraction spec to XPath targets
  [spec->xpath-targets 
   (-> extraction-spec? string? (or/c #f xpath-target?))]
  
  ;; Refine XPaths based on extraction results
  [refine-xpath-targets
   (-> xpath-target? (listof string?) any/c xpath-target?)]))

;; @function{parse-extraction-description}
;; @description{Parses natural language description into structured extraction specification}
;; @param[description]{string?} Natural language description of data to extract
;; @returns{extraction-spec?} Structured extraction specification
(define (parse-extraction-description description)
  (let* ([parts (parse-description-parts description)]
         [parent-desc (hash-ref parts 'parent "")]
         [fields (hash-ref parts 'fields '())]
         [constraints (hash-ref parts 'constraints #f)])
    (extraction-spec parent-desc fields constraints)))

;; @function{parse-description-parts}
;; @description{Helper to parse description into parent and field parts}
;; @param[description]{string?} Natural language description
;; @returns{hash?} Hash with 'parent and 'fields keys
(define (parse-description-parts description)
  ;; Look for patterns like "Extract X containing: Y, Z"
  (match description
    [(regexp #rx"[Ee]xtract ([^:]+) containing: (.+)" 
             (list _ parent-part fields-part))
     (hash 'parent (string-trim parent-part)
           'fields (parse-field-list fields-part))]
    
    ;; Fallback: treat entire description as fields
    [else
     (hash 'parent "items"
           'fields (parse-field-list description))]))

;; @function{parse-field-list}
;; @description{Parse comma-separated field list}
;; @param[fields-str]{string?} Comma-separated field names
;; @returns{listof string?} List of field names
(define (parse-field-list fields-str)
  (map string-trim (string-split fields-str ",")))

;; @function{spec->xpath-targets}
;; @description{Convert extraction spec to XPath targets using LLM}
;; @param[spec]{extraction-spec?} Extraction specification
;; @param[sample-url]{string?} URL to analyze for XPath generation
;; @returns{(or/c #f xpath-target?)} XPath targets or #f on failure
(define (spec->xpath-targets spec sample-url)
  (with-handlers ([exn:fail? 
                   (lambda (exn)
                     (raise (exn:scraper:llm
                             (format "Failed to generate XPaths: ~a" 
                                     (exn-message exn))
                             (current-continuation-marks))))])
    
    ;; Fetch and prepare sample HTML
    (let* ([html (fetch-sample-html sample-url)]
           [prompt (build-xpath-prompt spec html)]
           [response (call-llm-for-xpaths prompt)]
           [xpaths (parse-xpath-response response)])
      
      (if (valid-xpath-target? xpaths)
          xpaths
          #f))))

;; @function{fetch-sample-html}
;; @description{Fetch HTML from URL for analysis}
;; @param[url]{string?} URL to fetch
;; @returns{string?} HTML content
(define (fetch-sample-html url)
  ;; This should use the existing html-from-url function
  ;; For now, returning a placeholder
  "<html><body><div class='product'>...</div></body></html>")

;; @function{build-xpath-prompt}
;; @description{Build prompt for LLM to generate XPaths}
;; @param[spec]{extraction-spec?} Extraction specification
;; @param[html]{string?} Sample HTML
;; @returns{string?} Prompt for LLM
(define (build-xpath-prompt spec html)
  (format "Generate XPath expressions to extract the following data:
Parent container: ~a
Fields to extract: ~a
From this HTML structure: ~a

Return as JSON with format:
{
  \"parent_xpath\": \"xpath_expression\",
  \"child_xpaths\": [
    {\"field_name\": \"xpath_expression\"},
    ...
  ]
}"
          (extraction-spec-parent-description spec)
          (string-join (extraction-spec-field-descriptions spec) ", ")
          (substring html 0 (min 5000 (string-length html)))))

;; @function{call-llm-for-xpaths}
;; @description{Call LLM to generate XPath expressions}
;; @param[prompt]{string?} Prompt for LLM
;; @returns{string?} LLM response
(define (call-llm-for-xpaths prompt)
  ;; Use Anthropic by default
  (get-sonnet-response 
   "You are an expert at generating XPath expressions for web scraping."
   prompt))

;; @function{parse-xpath-response}
;; @description{Parse LLM response into XPath target structure}
;; @param[response]{string?} LLM response
;; @returns{xpath-target?} Parsed XPath targets
(define (parse-xpath-response response)
  (let* ([json-str (extract-json-from-response response)]
         [json-data (string->jsexpr json-str)]
         [parent-xpath (hash-ref json-data 'parent_xpath "")]
         [child-xpaths-list (hash-ref json-data 'child_xpaths '())]
         [child-xpaths-hash (list->xpath-hash child-xpaths-list)])
    (xpath-target parent-xpath child-xpaths-hash)))

;; @function{extract-json-from-response}
;; @description{Extract JSON from LLM response}
;; @param[response]{string?} Raw LLM response
;; @returns{string?} Extracted JSON string
(define (extract-json-from-response response)
  ;; Look for JSON between curly braces
  (match response
    [(regexp #rx"\\{[^}]+\\}" (list json-str))
     json-str]
    [else "{\"parent_xpath\": \"//div\", \"child_xpaths\": []}"]))

;; @function{list->xpath-hash}
;; @description{Convert list of xpath objects to hash}
;; @param[xpath-list]{list?} List of xpath objects
;; @returns{hash?} Hash of field-name -> xpath
(define (list->xpath-hash xpath-list)
  (for/hash ([item xpath-list])
    (let ([key (string->symbol (car (hash-keys item)))]
          [value (car (hash-values item))])
      (values key value))))

;; @function{valid-xpath-target?}
;; @description{Validate XPath target structure}
;; @param[target]{any/c} Potential XPath target
;; @returns{boolean?} Whether target is valid
(define (valid-xpath-target? target)
  (and (xpath-target? target)
       (not (string=? "" (xpath-target-parent-xpath target)))
       (> (hash-count (xpath-target-child-xpaths target)) 0)))

;; @function{refine-xpath-targets}
;; @description{Refine XPath expressions based on extraction results}
;; @param[current-target]{xpath-target?} Current XPath targets
;; @param[failed-fields]{listof string?} Fields that failed to extract
;; @param[sample-results]{any/c} Sample extraction results
;; @returns{xpath-target?} Refined XPath targets
(define (refine-xpath-targets current-target failed-fields sample-results)
  (if (empty? failed-fields)
      current-target
      (let* ([prompt (build-refinement-prompt current-target 
                                              failed-fields 
                                              sample-results)]
             [response (call-llm-for-xpaths prompt)]
             [refined (parse-xpath-response response)])
        (merge-xpath-targets current-target refined))))

;; @function{build-refinement-prompt}
;; @description{Build prompt for XPath refinement}
;; @param[target]{xpath-target?} Current XPath targets
;; @param[failed-fields]{listof string?} Failed fields
;; @param[results]{any/c} Sample results
;; @returns{string?} Refinement prompt
(define (build-refinement-prompt target failed-fields results)
  (format "The following XPath expressions failed to extract data:
Parent: ~a
Failed fields: ~a
Current XPaths: ~a
Sample results: ~a

Please provide refined XPath expressions that will successfully extract these fields."
          (xpath-target-parent-xpath target)
          (string-join failed-fields ", ")
          (hash->list (xpath-target-child-xpaths target))
          results))

;; @function{merge-xpath-targets}
;; @description{Merge original and refined XPath targets}
;; @param[original]{xpath-target?} Original targets
;; @param[refined]{xpath-target?} Refined targets
;; @returns{xpath-target?} Merged targets
(define (merge-xpath-targets original refined)
  (xpath-target
   (xpath-target-parent-xpath refined)
   (hash-union (xpath-target-child-xpaths original)
               (xpath-target-child-xpaths refined)
               #:combine (lambda (old new) new))))
