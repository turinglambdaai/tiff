#lang racket/base

;; The pixel-blob type shared by the public API.
;;
;; An `rgba` value holds a width x height image as a Racket byte string with
;; exactly 4 bytes per pixel in R,G,B,A order, non-premultiplied (straight)
;; alpha, top-left origin.  The guard enforces the byte-string length.

(require racket/contract/base)

(struct rgba (width height data)
  #:transparent
  #:guard
  (lambda (width height data name)
    (unless (exact-positive-integer? width)
      (raise-argument-error name "exact-positive-integer?" 0 width height data))
    (unless (exact-positive-integer? height)
      (raise-argument-error name "exact-positive-integer?" 1 width height data))
    (unless (bytes? data)
      (raise-argument-error name "bytes?" 2 width height data))
    (unless (= (bytes-length data) (* 4 width height))
      (raise-argument-error
       name
       (format "(bytes of length ~a, i.e. 4 bytes per pixel)" (* 4 width height))
       2
       width height data))
    (values width height data)))

(provide (contract-out
          (struct rgba ([width exact-positive-integer?]
                        [height exact-positive-integer?]
                        [data bytes?]))))
