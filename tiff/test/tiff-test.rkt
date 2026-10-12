#lang racket/base

;; Test entry point.  The real suite lives in "tiff-tests.rkt" and is
;; loaded only when libtiff is available: machines without the native
;; library (e.g. the package catalog's build farm) skip cleanly instead of
;; reporting failures.

(define lib-available?
  (with-handlers ([exn:fail? (λ (_) #f)])
    (dynamic-require 'tiff/main #f)
    #t))

(unless lib-available?
  (printf "tiff: libtiff not available; skipping tests\n"))

(when lib-available?
  (dynamic-require "tiff-tests.rkt" #f))
