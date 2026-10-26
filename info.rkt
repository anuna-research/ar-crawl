#lang info

(define collection "ar-crawl")
(define deps '("base"
               "parser-tools-lib"
               "html-parsing"
               "uuid"
               "http123"
               "sxml"
               "csv-writing"))
(define build-deps '("rackunit-lib" "compiler-lib"))
