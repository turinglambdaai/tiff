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
;; The catalog build farm runs `raco test --package`, executing every module
;; in the package as a test.  The modules that load libtiff at require time
;; cannot run on machines without the native library (the farm), so they are
;; omitted here; the CI workflow and `raco test tiff/test/tiff-test.rkt`
;; exercise the full suite through the probe entry point.
(define test-omit-paths
  '("tiff/test/tiff-tests.rkt"      ; loaded conditionally by the entry probe
    "tiff/scribblings"              ; documentation, not tests
    "tiff/main.rkt"
    "tiff/private/ffi.rkt"
    "tiff/private/decode.rkt"
    "tiff/private/encode.rkt"
    "tiff/private/meta.rkt"))
