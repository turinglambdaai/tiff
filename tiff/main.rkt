#lang racket/base

;; tiff: FFI bindings to libtiff.
;;
;; Decode any TIFF libtiff can read to RGBA, encode RGBA to TIFF, and read
;; basic metadata.  See tiff/scribblings/tiff.scrbl for the full manual.

(require racket/contract/base
         "private/ffi.rkt"
         "private/rgba.rkt"
         "private/decode.rkt"
         "private/encode.rkt"
         "private/meta.rkt")

(define compression-mode/c (symbols 'none 'lzw 'deflate 'packbits))

(provide (contract-out
          (struct rgba ([width exact-positive-integer?]
                        [height exact-positive-integer?]
                        [data bytes?]))
          (struct info ([width exact-positive-integer?]
                        [height exact-positive-integer?]
                        [bits-per-sample (integer-in 1 65535)]
                        [samples-per-pixel (integer-in 1 65535)]
                        [compression symbol?]))
          (tiff-info (-> path-string? info?))
          (tiff->rgba (-> path-string? rgba?))
          (rgba->tiff (->* (path-string? rgba?)
                           (#:compression compression-mode/c)
                           void?))
          (tiff-page-count (-> path-string? exact-nonnegative-integer?))
          (compression-mode/c flat-contract?)))
