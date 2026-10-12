#lang racket/base

;; Test suite for the tiff package.  Run with:
;;
;;     DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib raco test -p tiff
;;
;; (the DYLD_FALLBACK_LIBRARY_PATH is only needed on macOS with a Homebrew
;; libtiff; Linux resolves libtiff through the normal loader paths).

(require rackunit
         racket/file
         racket/path
         racket/port
         (for-syntax racket/base) ; define-runtime-path evaluates at both phases
         racket/runtime-path
         racket/string
         racket/system
         tiff
         (prefix-in raw: tiff/private/ffi))

;; ---------------------------------------------------------------------------
;; Paths

;; Golden file: a 7x5 solid-color TIFF produced by macOS `sips` from a
;; 7x5 PNG of the color (R G B) = (199 32 77) written with racket/draw.
;; Provenance: see README.md ("Regenerating the golden file").
(define-runtime-path golden-tiff-path
  (build-path 'up 'up "test" "data" "golden-sips-red-7x5.tiff"))

;; ---------------------------------------------------------------------------
;; Helpers

(define (with-temp-file proc)
  (define tmp (make-temporary-file "tiff-test-~a.tiff"))
  (dynamic-wind
    (lambda () (void))
    (lambda () (proc tmp))
    (lambda ()
      (when (file-exists? tmp) (delete-file tmp))
      (define png (path-replace-extension tmp #".png"))
      (when (file-exists? png) (delete-file png)))))

;; Procedural gradient with all three color channels varying on every pixel;
;; alpha is opaque everywhere.  (libtiff's RGBA reader premultiplies
;; unassociated alpha, so byte-identical round trips require opaque pixels;
;; the semi-transparent case is covered separately below with a tolerance.)
(define (gradient-rgba w h)
  (define data (make-bytes (* w h 4)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define i (* 4 (+ x (* y w))))
    (bytes-set! data i       (modulo (+ (* 7 x)  (* 13 y) 11)  256))
    (bytes-set! data (+ i 1) (modulo (+ (* 3 x)  (* 29 y) 100) 256))
    (bytes-set! data (+ i 2) (modulo (+ (* 53 x) (* 5 y)  200) 256))
    (bytes-set! data (+ i 3) 255))
  (rgba w h data))

;; Same, but with a varying alpha channel restricted to [128, 255].  (libtiff
;; premultiplying destroys almost all color precision at very low alpha —
;; e.g. a=1 maps every color value to ~1 — so a small round-trip error is
;; only provable for sufficiently large alpha; see the test below.)
(define (alpha-gradient-rgba w h)
  (define data (make-bytes (* w h 4)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define i (* 4 (+ x (* y w))))
    (bytes-set! data i       (modulo (+ (* 7 x)  (* 13 y) 11)  256))
    (bytes-set! data (+ i 1) (modulo (+ (* 3 x)  (* 29 y) 100) 256))
    (bytes-set! data (+ i 2) (modulo (+ (* 53 x) (* 5 y)  200) 256))
    (bytes-set! data (+ i 3) (+ 128 (modulo (+ (* 17 x) (* 11 y)) 128))))
  (rgba w h data))

(define (pixel img x y)
  (define i (* 4 (+ x (* y (rgba-width img)))))
  (subbytes (rgba-data img) i (+ i 4)))

;; Largest per-channel difference in R,G,B between two RGBA byte strings.
(define (max-rgb-diff b1 b2)
  (check-equal? (bytes-length b1) (bytes-length b2))
  (for*/fold ([mx 0]) ([i (in-range 0 (bytes-length b1) 4)] [c (in-range 3)])
    (max mx (abs (- (bytes-ref b1 (+ i c)) (bytes-ref b2 (+ i c)))))))

;; --- sips support (macOS only; skipped elsewhere, e.g. Linux CI) ----------
(define sips-path (find-executable-path "sips"))

(define (sips-run . args)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f sips-path args))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (values (subprocess-status proc) out err))

;; ---------------------------------------------------------------------------
;; 1. Round trips (each compression mode)

(for ([mode (in-list '(none lzw deflate packbits))])
  (test-case (format "round-trip gradient 61x37, compression ~a" mode)
    (with-temp-file
     (lambda (tmp)
       (define img (gradient-rgba 61 37))
       (rgba->tiff tmp img #:compression mode)
       (define back (tiff->rgba tmp))
       (check-equal? (rgba-width back) 61)
       (check-equal? (rgba-height back) 37)
       (check-equal? (rgba-data back) (rgba-data img) "pixel bytes must be identical")
       (define i (tiff-info tmp))
       (check-equal? (info-width i) 61)
       (check-equal? (info-height i) 37)
       (check-equal? (info-bits-per-sample i) 8)
       (check-equal? (info-samples-per-pixel i) 4)
       (check-equal? (info-compression i) mode)))))

;; Semi-transparent pixels: libtiff premultiplies on decode, we convert back
;; to straight alpha, so the round trip is exact for alpha and within +-1 per
;; color channel.
(test-case "round-trip with varying alpha stays within +-1 per channel"
  (with-temp-file
   (lambda (tmp)
     (define img (alpha-gradient-rgba 61 37))
     (rgba->tiff tmp img)
     (define back (tiff->rgba tmp))
     (check-true (<= (max-rgb-diff (rgba-data img) (rgba-data back)) 1)
                 "color channels must differ by at most 1")
     ;; alpha channel is carried through exactly
     (check-equal?
      (for/and ([i (in-range 3 (bytes-length (rgba-data img)) 4)])
        (= (bytes-ref (rgba-data img) i) (bytes-ref (rgba-data back) i)))
      #t))))

;; ---------------------------------------------------------------------------
;; 2. Golden file (produced by macOS sips from a solid-color PNG)

(test-case "golden: sips-generated 7x5 RGBA TIFF"
  (define i (tiff-info golden-tiff-path))
  (check-equal? (info-width i) 7)
  (check-equal? (info-height i) 5)
  (check-equal? (info-bits-per-sample i) 8)
  (check-equal? (info-samples-per-pixel i) 4)
  (check-equal? (info-compression i) 'none)
  (check-equal? (tiff-page-count golden-tiff-path) 1)

  (define img (tiff->rgba golden-tiff-path))
  (check-equal? (rgba-width img) 7)
  (check-equal? (rgba-height img) 5)
  ;; Every pixel is the opaque color (199 32 77); check corners and center.
  (define expected (bytes 199 32 77 255))
  (check-equal? (pixel img 0 0) expected)
  (check-equal? (pixel img 6 0) expected)
  (check-equal? (pixel img 0 4) expected)
  (check-equal? (pixel img 6 4) expected)
  (check-equal? (pixel img 3 2) expected))

;; Dev-time cross-validation: hand our own writer's output to macOS `sips`
;; and confirm it decodes as a 61x37 image, then convert it to PNG to prove
;; the file is readable by a completely independent TIFF consumer.  This
;; check is skipped wherever sips is unavailable (e.g. Ubuntu CI).
(when sips-path
  (test-case "sips cross-validates our writer (macOS only)"
    (with-temp-file
     (lambda (tmp)
       (rgba->tiff tmp (gradient-rgba 61 37) #:compression 'lzw)
       (define-values (code out _err)
         (sips-run "-g" "pixelWidth" "-g" "pixelHeight" "-g" "space"
                   (path->string tmp)))
       (check-equal? code 0)
       (check-true (string-contains? out "pixelWidth: 61") out)
       (check-true (string-contains? out "pixelHeight: 37") out)
       (check-true (or (string-contains? out "space: RGBA")
                       (string-contains? out "space: RGB"))
                   out)
       ;; full conversion to PNG proves sips/CoreGraphics decoded the file
       (define png-out (path-replace-extension tmp #".png"))
       (define-values (code2 _o2 _e2)
         (sips-run "-s" "format" "png" (path->string tmp)
                   "--out" (path->string png-out)))
       (check-equal? code2 0)
       (check-true (file-exists? png-out))
       (check-equal? (subbytes (file->bytes png-out) 1 4) #"PNG")))))

;; ---------------------------------------------------------------------------
;; 3. Error handling: clear exn:fail, no crashes; TIFFClose always runs via
;; dynamic-wind inside call-with-open-tiff.

(test-case "errors"
  (define missing
    (build-path (find-system-path 'temp-dir) "tiff-test-no-such-file.tiff"))
  ;; clean up leftovers from any earlier run of this suite
  (when (file-exists? missing) (delete-file missing))
  (check-exn exn:fail? (lambda () (tiff->rgba missing)))
  (check-exn exn:fail? (lambda () (tiff-info missing)))
  (check-exn exn:fail? (lambda () (tiff-page-count missing)))
  ;; A writer creating a new file is normal behavior, but a path in a
  ;; nonexistent directory must fail cleanly.
  (define bad-dir
    (build-path (find-system-path 'temp-dir) "tiff-test-no-such-dir" "x.tiff"))
  (check-exn exn:fail? (lambda () (rgba->tiff bad-dir (gradient-rgba 2 2))))

  (with-temp-file
   (lambda (tmp)
     ;; non-TIFF file
     (display-to-file "this is definitely not a TIFF file" tmp
                      #:exists 'truncate)
     (check-exn exn:fail? (lambda () (tiff->rgba tmp)))
     (check-exn exn:fail? (lambda () (tiff-info tmp)))
     (check-exn exn:fail? (lambda () (tiff-page-count tmp)))

     ;; truncated TIFF: keep only the header region — the first IFD (at
     ;; offset 178 in this file) is cut off, so neither opening nor decoding
     ;; can succeed
     (define golden (file->bytes golden-tiff-path))
     (call-with-output-file tmp
       (lambda (o)
         (write-bytes (subbytes golden 0 (min 128 (bytes-length golden))) o))
       #:exists 'truncate)
     (check-exn exn:fail? (lambda () (tiff->rgba tmp)))
     (check-exn exn:fail? (lambda () (tiff-info tmp)))))

  ;; invalid compression mode: rejected by the contract (exn:fail:contract
  ;; is a subtype of exn:fail)
  (check-exn exn:fail?
             (lambda ()
               (rgba->tiff (make-temporary-file "tiff-test-~a.tiff")
                           (gradient-rgba 2 2)
                           #:compression 'jpeg))))

;; ---------------------------------------------------------------------------
;; 4. Orientation: build a bottom-left-origin TIFF with the raw FFI.  With
;; ORIENTATION = BOTLEFT, scanline 0 is the BOTTOM row of the image, so a
;; top-left raster from tiff->rgba must flip it vertically.

(define (row-color r) (bytes (+ 30 r) (+ 40 r) (+ 50 r) 255))

(define (write-bottom-left-tiff path w h)
  (define tif (raw:TIFFOpen path "w"))
  (check-not-false tif)
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (raw:tiff-set-image-width! tif w)
      (raw:tiff-set-image-length! tif h)
      (raw:tiff-set-samples-per-pixel! tif 4)
      (raw:tiff-set-bits-per-sample! tif 8)
      (raw:tiff-set-photometric! tif raw:+photometric-rgb+)
      (raw:tiff-set-orientation! tif raw:+orientation-botleft+)
      (raw:tiff-set-sample-format! tif raw:+sampleformat-uint+)
      (raw:tiff-set-rows-per-strip! tif h)
      (raw:tiff-set-compression! tif raw:+compression-none+)
      (raw:tiff-set-planar-config-contig! tif)
      (check-equal? (raw:tiff-set-unassociated-alpha! tif) 1)
      (for ([r (in-range h)])
        (define line (make-bytes (* w 4)))
        (for ([x (in-range w)])
          (bytes-copy! line (* 4 x) (row-color r)))
        (check-equal? (raw:TIFFWriteScanline tif line r 0) 1)))
    (lambda () (raw:TIFFClose tif))))

(test-case "orientation: bottom-left origin comes out top-left"
  (with-temp-file
   (lambda (tmp)
     (define w 9)
     (define h 7)
     (write-bottom-left-tiff tmp w h)
     (define img (tiff->rgba tmp))
     (check-equal? (pixel img 0 0) (row-color (- h 1))
                   "top raster row must show the image's bottom row")
     (check-equal? (pixel img 0 (- h 1)) (row-color 0)
                   "bottom raster row must show the image's top row")
     (check-equal? (pixel img 4 3) (row-color 3))
     ;; stability: decoding again gives the identical bytes
     (check-equal? (rgba-data (tiff->rgba tmp)) (rgba-data img)))))

;; ---------------------------------------------------------------------------
;; 5. Multi-page: a two-page TIFF written with the raw FFI.

(define (write-solid-page tif w h rgb)
  (raw:tiff-set-image-width! tif w)
  (raw:tiff-set-image-length! tif h)
  (raw:tiff-set-samples-per-pixel! tif 4)
  (raw:tiff-set-bits-per-sample! tif 8)
  (raw:tiff-set-photometric! tif raw:+photometric-rgb+)
  (raw:tiff-set-orientation! tif raw:+orientation-topleft+)
  (raw:tiff-set-sample-format! tif raw:+sampleformat-uint+)
  (raw:tiff-set-rows-per-strip! tif h)
  (raw:tiff-set-compression! tif raw:+compression-none+)
  (raw:tiff-set-planar-config-contig! tif)
  (check-equal? (raw:tiff-set-unassociated-alpha! tif) 1)
  (define line (make-bytes (* w 4)))
  (for ([x (in-range w)]) (bytes-copy! line (* 4 x) (bytes (car rgb) (cadr rgb) (caddr rgb) 255)))
  (for ([r (in-range h)])
    (check-equal? (raw:TIFFWriteScanline tif line r 0) 1)))

(test-case "two-page TIFF: page count and first-page decode"
  (with-temp-file
   (lambda (tmp)
     (define tif (raw:TIFFOpen tmp "w"))
     (check-not-false tif)
     (dynamic-wind
       (lambda () (void))
       (lambda ()
         (write-solid-page tif 8 6 '(10 20 30))
         (check-equal? (raw:TIFFWriteDirectory tif) 1)
         (write-solid-page tif 8 6 '(200 100 50)))
       (lambda () (raw:TIFFClose tif)))
     (check-equal? (tiff-page-count tmp) 2)
     ;; tiff->rgba reads the first directory
     (define img (tiff->rgba tmp))
     (check-equal? (pixel img 0 0) (bytes 10 20 30 255))
     (check-equal? (pixel img 7 5) (bytes 10 20 30 255)))))
