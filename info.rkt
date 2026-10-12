#lang info

;; 'multi: the collection directory is the `tiff/` subdirectory (the same
;; layout used by draw-lib, db-lib, compiler-lib, ...).  Declaring a string
;; collection name here would make the package single-collection with the
;; package root as the collection directory, which does not match this tree.
(define collection 'multi)
(define version "0.1")
;; rackunit-lib is a run-time dependency: the package ships its test suite
;; and the catalog's dependency check scans shipped modules in run mode.
(define deps '("base" "rackunit-lib"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc
  "FFI bindings to libtiff: decode TIFF images to RGBA, encode RGBA to TIFF, and read TIFF metadata.")
(define pkg-authors '("turinglambdaai"))
(define license 'MIT)
(define scribblings '(("tiff/scribblings/tiff.scrbl" ())))
;; "tiff-tests.rkt" is loaded conditionally by "tiff-test.rkt" (native
;; library probe); the scribblings module is not a test.
(define test-omit-paths '("tiff/test/tiff-tests.rkt"
                          "tiff/scribblings"))
