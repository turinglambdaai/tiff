#lang info

;; 'multi: the collection directory is the `tiff/` subdirectory (the same
;; layout used by draw-lib, db-lib, compiler-lib, ...).  Declaring a string
;; collection name here would make the package single-collection with the
;; package root as the collection directory, which does not match this tree.
(define collection 'multi)
(define version "0.1.0")
(define deps '("base"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc
  "FFI bindings to libtiff: decode TIFF images to RGBA, encode RGBA to TIFF, and read TIFF metadata.")
(define pkg-authors '("turinglambdaai"))
(define license 'MIT)
(define scribblings '(("scribblings/tiff.scrbl" ())))
