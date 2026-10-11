#lang racket/base

;; tiff-info and tiff-page-count: basic metadata over libtiff.

(require racket/contract/base
         "ffi.rkt")

(struct info (width height bits-per-sample samples-per-pixel compression)
  #:transparent)

(define (tiff-info path)
  (unless (path-string? path)
    (raise-argument-error 'tiff-info "path-string?" path))
  (unless (file-exists? path)
    (error 'tiff-info "no such file: ~e" path))
  (call-with-open-tiff path "r"
    (lambda (tif)
      (define width
        (or (tiff-image-width tif)
            (error 'tiff-info "~e: ImageWidth is missing — is this a valid TIFF?" path)))
      (define height
        (or (tiff-image-length tif)
            (error 'tiff-info "~e: ImageLength is missing — is this a valid TIFF?" path)))
      (define samples (or (tiff-samples-per-pixel tif) 1))
      (define bits (or (tiff-bits-per-sample tif)
                       (error 'tiff-info "~e: BitsPerSample is missing" path)))
      (define compression-code (or (tiff-compression tif) +compression-none+))
      (info width height bits samples (compression-code->symbol compression-code)))))

;; Number of IFDs (pages) in the file.  libtiff walks the directory chain
;; itself (TIFFNumberOfDirectories); directories that have not been written
;; to the file do not count, per the libtiff man page.
(define (tiff-page-count path)
  (unless (path-string? path)
    (raise-argument-error 'tiff-page-count "path-string?" path))
  (unless (file-exists? path)
    (error 'tiff-page-count "no such file: ~e" path))
  (call-with-open-tiff path "r" TIFFNumberOfDirectories))

(provide (contract-out
          (struct info ([width exact-positive-integer?]
                        [height exact-positive-integer?]
                        [bits-per-sample (integer-in 1 65535)]
                        [samples-per-pixel (integer-in 1 65535)]
                        [compression symbol?]))
          (tiff-info (-> path-string? info?))
          (tiff-page-count (-> path-string? exact-nonnegative-integer?))))
