#lang racket/base

;; rgba->tiff: encode an `rgba` image as a classic TIFF file with 8-bit
;; contiguous RGBA samples (unassociated/straight alpha).

(require ffi/unsafe
         "ffi.rkt"
         "rgba.rkt")

(define (rgba->tiff path img #:compression [compression 'none])
  (unless (path-string? path)
    (raise-argument-error 'rgba->tiff "path-string?" path))
  (unless (rgba? img)
    (raise-argument-error 'rgba->tiff "rgba?" img))
  (define compression-code (compression-mode->code compression))
  (define width (rgba-width img))
  (define height (rgba-height img))
  (define data (rgba-data img))
  (call-with-open-tiff path "w"
    (lambda (tif)
      (tiff-set-image-width! tif width)
      (tiff-set-image-length! tif height)
      (tiff-set-samples-per-pixel! tif 4)
      (tiff-set-bits-per-sample! tif 8)
      (tiff-set-photometric! tif +photometric-rgb+)
      (tiff-set-orientation! tif +orientation-topleft+)
      (tiff-set-sample-format! tif +sampleformat-uint+)
      ;; One strip for the whole image keeps the writer simple; libtiff
      ;; handles strip buffering for the compression schemes we support.
      (tiff-set-rows-per-strip! tif height)
      (tiff-set-compression! tif compression-code)
      (tiff-set-planar-config-contig! tif)
      ;; Declare the 4th sample as unassociated (straight) alpha, matching
      ;; the `rgba` data model.
      (unless (= 1 (tiff-set-unassociated-alpha! tif))
        (error 'rgba->tiff "TIFFSetField(EXTRASAMPLES) failed (details logged under the 'tiff topic)"))
      (tiff-set-software! tif "Racket tiff 0.1.0")
      ;; TIFFWriteScanline returns 1 on success, -1 on error.  Rows must be
      ;; written in increasing order (required for LZW/Deflate/PackBits).
      (for ([row (in-range height)])
        (define start (* row width 4))
        (unless (= 1 (TIFFWriteScanline tif
                                        (subbytes data start (+ start (* width 4)))
                                        row
                                        0))
          (error 'rgba->tiff
                 "~e: TIFFWriteScanline failed at row ~a (details logged under the 'tiff topic)"
                 path row)))
      ;; The image directory is written by libtiff when the file is closed
      ;; (dynamic-wind in call-with-open-tiff guarantees the close).

      (void))))

(provide rgba->tiff)
