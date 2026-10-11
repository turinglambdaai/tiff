#lang racket/base

;; tiff->rgba: decode any TIFF that libtiff can handle into an RGBA byte
;; blob via libtiff's high-level RGBA interface.

(require ffi/unsafe
         "ffi.rkt"
         "rgba.rkt")

;; Recover a straight-alpha channel value from a premultiplied one:
;; v' = round(v * 255 / a), with integer arithmetic (half-up rounding).
;; For a = 255 this is the identity; for a = 0 the premultiplied value is 0
;; anyway, so nothing to do.
(define (unpremultiply v a)
  (quotient (+ (* v 255) (quotient a 2)) a))

;; Convert premultiplied RGB in place to straight alpha.  `data` is a fresh
;; Racket byte string (copied out of the libtiff raster), so mutating it is
;; safe.  Alpha bytes are kept as-is.
(define (un-premultiply! data)
  (for ([i (in-range 0 (bytes-length data) 4)])
    (define a (bytes-ref data (+ i 3)))
    (unless (or (= a 255) (= a 0))
      (bytes-set! data i       (unpremultiply (bytes-ref data i)       a))
      (bytes-set! data (+ i 1) (unpremultiply (bytes-ref data (+ i 1)) a))
      (bytes-set! data (+ i 2) (unpremultiply (bytes-ref data (+ i 2)) a))))
  data)

(define (tiff->rgba path)
  (unless (path-string? path)
    (raise-argument-error 'tiff->rgba "path-string?" path))
  (unless (file-exists? path)
    (error 'tiff->rgba "no such file: ~e" path))
  (call-with-open-tiff path "r"
    (lambda (tif)
      (define width
        (or (tiff-image-width tif)
            (error 'tiff->rgba "~e: ImageWidth is missing — is this a valid TIFF?" path)))
      (define height
        (or (tiff-image-length tif)
            (error 'tiff->rgba "~e: ImageLength is missing — is this a valid TIFF?" path)))
      ;; libtiff refuses some photometric interpretations (e.g. unknown
      ;; CFA patterns); ask it first so the error message is precise.
      (define emsg (make-bytes 1024 0))
      (unless (= 1 (TIFFRGBAImageOK tif emsg))
        (error 'tiff->rgba "~e: libtiff cannot convert this image to RGBA (~a)"
               path
               (c-bytes->string emsg)))
      ;; Raster for libtiff: one uint32 per pixel.  malloc 'raw + explicit
      ;; free in dynamic-wind; the pointer never escapes this block.
      (define pixel-count (* width height))
      (define raster (malloc _uint32 pixel-count 'raw))
      (dynamic-wind
          (lambda () (void))
          (lambda ()
            ;; Request ORIENTATION_TOPLEFT so the raster is filled with a
            ;; top-left origin regardless of the file's Orientation tag
            ;; (libtiff flips the data as needed); stopOnError = 1 aborts on
            ;; decode errors and returns 0.
            (define ok
              (TIFFReadRGBAImageOriented tif width height raster
                                         +orientation-topleft+ 1))
            (unless (= 1 ok)
              (error 'tiff->rgba
                     "~e: libtiff failed to decode the image to RGBA (details logged under the 'tiff topic)"
                     path))
            ;; TIFFReadRGBAImageOriented stores one uint32 per pixel whose
            ;; VALUE is packed as 0xAABBGGRR (libtiff's TIFFGetR/G/B/A macros
            ;; read this host-order value: R = v & 0xff, G = (v >> 8) & 0xff,
            ;; B = (v >> 16) & 0xff, A = (v >> 24) & 0xff).  On a
            ;; little-endian host — x86-64 and arm64, the only platforms this
            ;; package supports — that uint32 sits in memory as the byte
            ;; sequence R,G,B,A, so the raw buffer already has the RGBA byte
            ;; layout of the `rgba` type.  A big-endian port would need to
            ;; swap bytes within each pixel here.
            (define data (make-bytes (* 4 pixel-count)))
            (memcpy data raster (bytes-length data))
            ;; libtiff's RGBA reader returns PREMULTIPLIED pixels for files
            ;; whose first extra sample is declared associated or
            ;; unassociated alpha (see the TIFFRGBAImage man page: "For
            ;; files with unassociated alpha, the TIFFRGBAImage reading
            ;; routines multiply the RGB values by the alpha channel values
            ;; before saving them in the raster").  Our `rgba` type is
            ;; documented as straight (non-premultiplied) alpha, so convert
            ;; back; this is lossy by at most 1 per channel for partially
            ;; transparent pixels, and an exact no-op for opaque ones.
            (define extra (tiff-extrasamples tif))
            (define premultiplied-source?
              (and extra
                   (memq (car extra)
                         (list +extrasample-associated+ +extrasample-unassociated+))
                   #t))
            (rgba width height
                  (if premultiplied-source?
                      (un-premultiply! data)
                      data)))
          (lambda () (free raster))))))

(provide tiff->rgba)
