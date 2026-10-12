#lang racket/base

;; Low-level FFI bindings to libtiff (https://libtiff.gitlab.io/libtiff/).
;;
;; This module is private to the `tiff` package; the public API lives in
;; `tiff/main.rkt`.  Signatures, varargs arities and return-value semantics
;; follow the libtiff 4.x documentation and man pages (verified against
;; libtiff 4.7):
;;
;;   TIFFOpen            returns NULL on failure
;;   TIFFGetField        returns 1 if the tag is defined in the current
;;                       directory, 0 otherwise (out params untouched when 0)
;;   TIFFSetField        returns 1 on success, 0 on error
;;   TIFFReadScanline    returns 1 on success, -1 on error
;;   TIFFWriteScanline   returns 1 on success, -1 on error
;;   TIFFReadDirectory   returns 1 on success, 0 on error / no more dirs
;;   TIFFWriteDirectory  returns 1 on success, 0 on error
;;   TIFFSetDirectory    returns 1 on success, 0 on error
;;   TIFFNumberOfDirectories returns tdir_t (uint32_t): the number of
;;                       directories in the file
;;   TIFFReadRGBAImageOriented returns 1 if the image was read and converted,
;;                       0 on error
;;   TIFFRGBAImageOK     returns 1 if the image can be converted to RGBA,
;;                       0 otherwise (with an explanation in emsg)

(require ffi/unsafe
         ffi/unsafe/define
         racket/list
         "varargs.rkt")

;; ---------------------------------------------------------------------------
;; Library loading
;;
;; The version list makes the loader prefer versioned sonames
;; (libtiff.so.6 / libtiff.so.5 / libtiff.6.dylib / libtiff.5.dylib) before
;; the unversioned name, so the library is found even on systems that ship
;; the runtime library without the -dev symlink (libtiff.so).
;;
;; If the bare-name load fails, we try the absolute locations where Homebrew
;; installs libtiff (/opt/homebrew/lib on Apple Silicon, /usr/local/lib on
;; Intel).  This matters because on macOS DYLD_FALLBACK_LIBRARY_PATH is not
;; always visible to spawned test/doc processes, and Homebrew's lib directory
;; is not in the default dlopen path; see README.md.
(define libtiff-lib
  (let ()
    (define (try name)
      (with-handlers ([exn:fail? (lambda (_) #f)]) (ffi-lib name '("6" "5" ""))))
    (define fallback-dirs
      '("/opt/homebrew/lib"                 ; Homebrew (Apple Silicon)
        "/opt/homebrew/opt/libtiff/lib"     ; Homebrew keg
        "/usr/local/lib"                    ; Homebrew (Intel) / source builds
        "/usr/local/opt/libtiff/lib"))      ; Homebrew keg (Intel)
    (define fallback
      (let loop ([dirs fallback-dirs])
        (and (pair? dirs)
             (or (try (build-path (car dirs) "libtiff"))
                 (loop (cdr dirs))))))
    (or (try "libtiff")
        fallback
        (raise
         (exn:fail
          (string-append
           "tiff: could not load libtiff (tried the loader's default paths, "
           "DYLD_LIBRARY_PATH/LD_LIBRARY_PATH, and common Homebrew locations). "
           "Install libtiff, e.g. `brew install libtiff` or "
           "`apt-get install libtiff-dev`, or set DYLD_FALLBACK_LIBRARY_PATH "
           "to the directory containing libtiff.")
          (current-continuation-marks))))))

(define-ffi-definer define-libtiff libtiff-lib)

;; Opaque library handle.  TIFFOpen returns NULL on failure; _tif/null
;; models that.  All other entry points receive a live handle.
(define _tif (_cpointer 'TIFF))
(define _tif/null (_cpointer/null 'TIFF))

;; ---------------------------------------------------------------------------
;; Tag values and enumerations (from tiff.h)

(define +tag-image-width+       256)  ; TIFFTAG_IMAGEWIDTH       (uint32)
(define +tag-image-length+      257)  ; TIFFTAG_IMAGELENGTH      (uint32)
(define +tag-bits-per-sample+   258)  ; TIFFTAG_BITSPERSAMPLE    (uint16)
(define +tag-compression+       259)  ; TIFFTAG_COMPRESSION      (uint16)
(define +tag-photometric+       262)  ; TIFFTAG_PHOTOMETRIC      (uint16)
(define +tag-document-name+     269)  ; TIFFTAG_DOCUMENTNAME     (ascii)
(define +tag-image-description+ 270)  ; TIFFTAG_IMAGEDESCRIPTION (ascii)
(define +tag-orientation+       274)  ; TIFFTAG_ORIENTATION      (uint16)
(define +tag-samples-per-pixel+ 277)  ; TIFFTAG_SAMPLESPERPIXEL  (uint16)
(define +tag-rows-per-strip+    278)  ; TIFFTAG_ROWSPERSTRIP     (uint32)
(define +tag-x-resolution+      282)  ; TIFFTAG_XRESOLUTION      (float)
(define +tag-y-resolution+      283)  ; TIFFTAG_YRESOLUTION      (float)
(define +tag-planar-config+     284)  ; TIFFTAG_PLANARCONFIG     (uint16)
(define +tag-software+          305)  ; TIFFTAG_SOFTWARE         (ascii)
(define +tag-date-time+         306)  ; TIFFTAG_DATETIME         (ascii)
(define +tag-artist+            315)  ; TIFFTAG_ARTIST           (ascii)
(define +tag-extrasamples+      338)  ; TIFFTAG_EXTRASAMPLES     (u16 count + u16* array)
(define +tag-sample-format+     339)  ; TIFFTAG_SAMPLEFORMAT     (uint16)
(define +tag-copyright+       33432)  ; TIFFTAG_COPYRIGHT        (ascii)

;; ExtraSamples values (tiff.h)
(define +extrasample-unspecified+   0) ; meaning of extra sample unknown
(define +extrasample-associated+    1) ; premultiplied (associated) alpha
(define +extrasample-unassociated+  2) ; straight (unassociated) alpha

;; Orientation values (tiff.h)
(define +orientation-topleft+  1)
(define +orientation-topright+ 2)
(define +orientation-botright+ 3)
(define +orientation-botleft+  4)

;; PhotometricInterpretation values (subset, tiff.h)
(define +photometric-miniswhite+ 0)
(define +photometric-minisblack+ 1)
(define +photometric-rgb+        2)
(define +photometric-palette+    3)

;; SampleFormat / PlanarConfiguration values (tiff.h)
(define +sampleformat-uint+     1)
(define +planarconfig-contig+   1)

;; Compression scheme codes (tiff.h)
(define +compression-none+          1)
(define +compression-lzw+           5)
(define +compression-jpeg+          7)
(define +compression-adobe-deflate+ 8)
(define +compression-packbits+  32773)
(define +compression-deflate+   32946) ; legacy Deflate code (same algorithm as 8)

;; Compression modes supported by rgba->tiff, and the mapping back to
;; symbolic names for tiff-info.  Unknown codes are reported as `code-N`.
(define compression-codes
  '((none . 1) (lzw . 5) (deflate . 8) (packbits . 32773)))

(define (compression-mode->code mode)
  (cond
    [(assq mode compression-codes) => cdr]
    [else (raise-argument-error 'compression-mode->code
                                (format "one of ~a" (map car compression-codes))
                                mode)]))

(define (compression-code->symbol code)
  (case code
    [(1) 'none]
    [(5) 'lzw]
    [(7) 'jpeg]
    [(8 32946) 'deflate]
    [(32773) 'packbits]
    [else (string->symbol (format "code-~a" code))]))

;; ---------------------------------------------------------------------------
;; Error and warning routing
;;
;; libtiff reports errors and warnings through two callback registries
;; (TIFFSetErrorHandler / TIFFSetWarningHandler).  The callback type is
;;
;;     typedef void (*TIFFErrorHandler)(const char *module,
;;                                      const char *fmt, va_list ap);
;;
;; A C va_list has no portable FFI representation, so the callbacks below
;; accept it as an opaque _pointer and NEVER dereference it: on macOS arm64
;; va_list is in fact passed as a pointer, while on Linux arm64 it is passed
;; by value, in which case the slot we read is simply garbage — harmless as
;; long as the value is never used as a pointer.  The trade-off is that
;; printf-style arguments in libtiff messages are not interpolated; we log
;; the format string itself, which usually carries the substance of the
;; message.  Messages are routed into Racket's logging system with the
;; `current-logger` at the time of the call, using topic `tiff` and level
;; 'error or 'warning.

(define (log-from-libtiff level module fmt)
  (log-message (current-logger) level 'tiff
               (string-append "libtiff (" module "): " fmt
                              "  [printf-style arguments are not interpolated]")
               #f))

;; Keep the callback objects in module-level bindings for the lifetime of
;; the process so the GC can never collect a handler libtiff might call.
(define tiff-handler-type
  (_cprocedure (list _string _string _pointer) _void))

(define error-handler-callback
  (cast (lambda (module fmt _ap) (log-from-libtiff 'error module fmt))
        tiff-handler-type
        _fpointer))

(define warning-handler-callback
  (cast (lambda (module fmt _ap) (log-from-libtiff 'warning module fmt))
        tiff-handler-type
        _fpointer))

(define-libtiff TIFFSetErrorHandler (_fun _fpointer -> _fpointer))
(define-libtiff TIFFSetWarningHandler (_fun _fpointer -> _fpointer))

;; Install the log-routing handlers once, for the lifetime of the process.
(void (TIFFSetErrorHandler error-handler-callback)
      (TIFFSetWarningHandler warning-handler-callback))

;; ---------------------------------------------------------------------------
;; Plain (non-variadic) entry points

(define-libtiff TIFFOpen (_fun _path _string -> _tif/null))
(define-libtiff TIFFClose (_fun _tif -> _void))

(define-libtiff TIFFReadDirectory (_fun _tif -> _int))
(define-libtiff TIFFWriteDirectory (_fun _tif -> _int))
(define-libtiff TIFFSetDirectory (_fun _tif _uint16 -> _int))
(define-libtiff TIFFNumberOfDirectories (_fun _tif -> _uint32)) ; tdir_t = uint32_t

(define-libtiff TIFFScanlineSize64 (_fun _tif -> _uint64))
(define-libtiff TIFFReadScanline (_fun _tif _pointer _uint32 _uint16 -> _int))
(define-libtiff TIFFWriteScanline (_fun _tif _pointer _uint32 _uint16 -> _int))

(define-libtiff TIFFReadRGBAImageOriented
  (_fun _tif _uint32 _uint32 _pointer _int _int -> _int))
;; emsg is a caller-provided char[1024] buffer.
(define-libtiff TIFFRGBAImageOK
  (_fun _tif _pointer -> _int))

;; ---------------------------------------------------------------------------
;; TIFFGetField / TIFFSetField specializations
;;
;; TIFFGetField and TIFFSetField are C variadic functions
;; (int TIFFGetField(TIFF*, uint32, ...)).  A variadic call cannot be
;; expressed portably from Racket, so we define fixed-arity specializations,
;; one per argument shape, all mapping to the same C symbol via #:c-id.
;; This is the standard practice for wrapping varargs APIs: each wrapper
;; type-checks its tag+shape (a mismatched pair would corrupt memory).
;; C's default argument promotions also matter: a uint16 value is passed as
;; a 32-bit int in a variadic call and a float as a double, which is what
;; libtiff reads back with va_arg(ap, int) / va_arg(ap, double) — hence the
;; _uint32 slot in the set-field bindings even for 16-bit tags.
;;
;; IMPORTANT CAVEAT: Racket CS foreign callouts do not implement the
;; variadic-caller ABI on arm64 — every argument past the named ones is
;; delivered as garbage there (see private/varargs.rkt, where this was
;; verified against a diagnostic C library).  The specializations below are
;; therefore kept for platforms where direct variadic calls work (x86-64),
;; but THIS PACKAGE'S INTERNAL CODE never uses them: the safe per-tag
;; accessors below go through TIFFVGetField/TIFFVSetField with a manually
;; constructed va_list (tiff/private/varargs.rkt), which is correct on every
;; supported platform.  Callers MUST pair a tag with the argument shape
;; libtiff documents for it; the safe wrappers enforce that.

(define-libtiff tiff-get-field/u32
  (_fun _tif _uint32 (value : (_ptr o _uint32)) -> (present? : _int) -> (values present? value))
  #:c-id TIFFGetField)

(define-libtiff tiff-get-field/u16
  (_fun _tif _uint32 (value : (_ptr o _uint16)) -> (present? : _int) -> (values present? value))
  #:c-id TIFFGetField)

(define-libtiff tiff-get-field/float
  (_fun _tif _uint32 (value : (_ptr o _float)) -> (present? : _int) -> (values present? value))
  #:c-id TIFFGetField)

;; ASCII tags: libtiff hands back a char* into its own storage; the FFI
;; copies it into an immutable Racket string and frees nothing (the char*
;; stays owned by libtiff).
(define-libtiff tiff-get-field/string
  (_fun _tif _uint32 (cell : (_ptr o _pointer)) -> (present? : _int) -> (values present? cell))
  #:c-id TIFFGetField)

;; TIFFTAG_EXTRASAMPLES getter: TIFFGetField(tif, tag, uint16* count,
;; uint16** values) — two out params, count then array pointer.
(define-libtiff tiff-get-field/extrasamples
  (_fun _tif _uint32
        (count : (_ptr o _uint16))
        (values-ptr : (_ptr o _pointer))
        -> (present? : _int)
        -> (values present? count values-ptr))
  #:c-id TIFFGetField)

(define-libtiff tiff-set-field/int
  (_fun _tif _uint32 _uint32 -> _int)
  #:c-id TIFFSetField)

(define-libtiff tiff-set-field/float
  (_fun _tif _uint32 _double -> _int)
  #:c-id TIFFSetField)

(define-libtiff tiff-set-field/string
  (_fun _tif _uint32 _string -> _int)
  #:c-id TIFFSetField)

;; TIFFTAG_EXTRASAMPLES setter: TIFFSetField(tif, tag, uint16 count,
;; uint16* values).
(define-libtiff tiff-set-field/int+pointer
  (_fun _tif _uint32 _uint32 _pointer -> _int)
  #:c-id TIFFSetField)

;; ---------------------------------------------------------------------------
;; The va_list bridge (used by all internal get/set paths)
;;
;; TIFFVGetField / TIFFVSetField are the documented non-variadic twins of
;; TIFFGetField / TIFFVSetField: they take an explicit va_list, which
;; tiff/private/varargs.rkt constructs by hand for each supported ABI.  See
;; the "WHY THIS EXISTS" comment there for the arm64 rationale.
(define-libtiff TIFFVGetField/std (_fun _tif _uint32 va-param-type -> _int)
  #:c-id TIFFVGetField)
(define-libtiff TIFFVSetField/std (_fun _tif _uint32 va-param-type -> _int)
  #:c-id TIFFVSetField)

;; x86-64 (SysV): the callee's va_start spills the INCOMING register args
;; into reg_save_area, overwriting any pre-written GP vararg slots — so the
;; vararg values must ALSO travel as real trailing arguments (rcx, r8,
;; xmm0).  Values a tag does not read are simply never consumed.  On arm64
;; the caller-owned va_list storage IS the source of truth (no callee-side
;; spill into it), so no trailing arguments exist there.
(define-libtiff TIFFVGetField/x86
  (_fun _tif _uint32 va-param-type _int64 _int64 _double -> _int)
  #:c-id TIFFVGetField)
(define-libtiff TIFFVSetField/x86
  (_fun _tif _uint32 va-param-type _int64 _int64 _double -> _int)
  #:c-id TIFFVSetField)

(define (vget tif tag [v0 0] [v1 0] [d 0.0])
  (if x86-64?
      (TIFFVGetField/x86 tif tag (shared-va-frame 'param) v0 v1 d)
      (TIFFVGetField/std tif tag (shared-va-frame 'param))))

(define (vset tif tag [v0 0] [v1 0] [d 0.0])
  (if x86-64?
      (TIFFVSetField/x86 tif tag (shared-va-frame 'param) v0 v1 d)
      (TIFFVSetField/std tif tag (shared-va-frame 'param))))

;; Reusable scratch cells for TIFFGetField's out parameters.  Values in them
;; are only read after TIFFVGetField reports the tag present, so stale
;; content never escapes.  These live for the lifetime of the process.
(define cell-u32   (malloc _uint32 1 'raw))
(define cell-u16   (malloc _uint16 1 'raw))
(define cell-float (malloc _float 1 'raw))
(define cell-ptr-a (malloc _pointer 1 'raw))
(define cell-ptr-b (malloc _pointer 1 'raw))

;; Scratch byte string holding the NUL-terminated encoding of the most
;; recent string passed to TIFFVSetField; it must stay alive for the
;; duration of the call (libtiff copies the string internally).
(define string-scratch #f)

;; ---------------------------------------------------------------------------
;; Safe per-tag accessors
;;
;; The wrappers below hard-code a specific tag + argument shape, so misuse
;; becomes a Racket-level error instead of memory corruption.  Each getter
;; returns #f when the tag is absent from the current directory (the call
;; reported 0).

(define (get-u32 tif tag)
  (shared-va-frame 'set-pointer! 0 cell-u32)
  (define present? (vget tif tag (cast cell-u32 _pointer _int64)))
  (and (= 1 present?) (ptr-ref cell-u32 _uint32)))

(define (get-u16 tif tag)
  (shared-va-frame 'set-pointer! 0 cell-u16)
  (define present? (vget tif tag (cast cell-u16 _pointer _int64)))
  (and (= 1 present?) (ptr-ref cell-u16 _uint16)))

(define (get-float tif tag)
  (shared-va-frame 'set-pointer! 0 cell-float)
  (define present? (vget tif tag (cast cell-float _pointer _int64)))
  (and (= 1 present?) (ptr-ref cell-float _float)))

;; When the tag is present the out cell holds a valid char* owned by
;; libtiff; convert (copy) it into a Racket string.
(define (get-string tif tag)
  (shared-va-frame 'set-pointer! 0 cell-ptr-a)
  (define present? (vget tif tag (cast cell-ptr-a _pointer _int64)))
  (and (= 1 present?)
       (let ([p (ptr-ref cell-ptr-a _pointer)])
         (and p (cast p _pointer _string)))))

(define (tiff-image-width tif)       (get-u32 tif +tag-image-width+))
(define (tiff-image-length tif)      (get-u32 tif +tag-image-length+))
(define (tiff-bits-per-sample tif)   (get-u16 tif +tag-bits-per-sample+))
(define (tiff-compression tif)       (get-u16 tif +tag-compression+))
(define (tiff-photometric tif)       (get-u16 tif +tag-photometric+))
(define (tiff-orientation tif)       (get-u16 tif +tag-orientation+))
(define (tiff-samples-per-pixel tif) (get-u16 tif +tag-samples-per-pixel+))
(define (tiff-rows-per-strip tif)    (get-u32 tif +tag-rows-per-strip+))
(define (tiff-x-resolution tif)      (get-float tif +tag-x-resolution+))
(define (tiff-y-resolution tif)      (get-float tif +tag-y-resolution+))
(define (tiff-document-name tif)     (get-string tif +tag-document-name+))
(define (tiff-image-description tif) (get-string tif +tag-image-description+))
(define (tiff-software tif)          (get-string tif +tag-software+))
(define (tiff-date-time tif)         (get-string tif +tag-date-time+))
(define (tiff-artist tif)            (get-string tif +tag-artist+))
(define (tiff-copyright tif)         (get-string tif +tag-copyright+))

;; Returns the list of ExtraSamples codes, or #f when the tag is absent.
;; Per libtiff, the FIRST extra sample is the one the RGBA interface treats
;; as alpha.
(define (tiff-extrasamples tif)
  (shared-va-frame 'set-pointer! 0 cell-u16)    ; uint16*  count
  (shared-va-frame 'set-pointer! 1 cell-ptr-a)  ; uint16** values
  (define present? (vget tif +tag-extrasamples+
                         (cast cell-u16 _pointer _int64)
                         (cast cell-ptr-a _pointer _int64)))
  (and (= 1 present?)
       (let ([count (ptr-ref cell-u16 _uint16)])
         (and (> count 0)
              (let ([p (ptr-ref cell-ptr-a _pointer)])
                (ptr-ref p (_array/list _uint16 count)))))))

;; Setters raise exn:fail on failure (libtiff has already logged why).
;; All scalar tags go through the integer slot: 16-bit values are passed as
;; 32-bit due to C default argument promotions in variadic calls, and float
;; tags take a promoted double.

(define (set-int! who tif tag value)
  (shared-va-frame 'set-int! 0 value)
  (unless (= 1 (vset tif tag value))
    (error who "TIFFSetField failed for tag ~a with value ~a (details logged under the 'tiff topic)"
           tag value)))

(define (tiff-set-image-width! tif v)       (set-int! 'tiff-set-image-width! tif +tag-image-width+ v))
(define (tiff-set-image-length! tif v)      (set-int! 'tiff-set-image-length! tif +tag-image-length+ v))
(define (tiff-set-bits-per-sample! tif v)   (set-int! 'tiff-set-bits-per-sample! tif +tag-bits-per-sample+ v))
(define (tiff-set-compression! tif v)       (set-int! 'tiff-set-compression! tif +tag-compression+ v))
(define (tiff-set-photometric! tif v)       (set-int! 'tiff-set-photometric! tif +tag-photometric+ v))
(define (tiff-set-orientation! tif v)       (set-int! 'tiff-set-orientation! tif +tag-orientation+ v))
(define (tiff-set-samples-per-pixel! tif v) (set-int! 'tiff-set-samples-per-pixel! tif +tag-samples-per-pixel+ v))
(define (tiff-set-rows-per-strip! tif v)    (set-int! 'tiff-set-rows-per-strip! tif +tag-rows-per-strip+ v))
(define (tiff-set-sample-format! tif v)     (set-int! 'tiff-set-sample-format! tif +tag-sample-format+ v))
(define (tiff-set-planar-config-contig! tif)
  (set-int! 'tiff-set-planar-config-contig! tif +tag-planar-config+ +planarconfig-contig+))

(define (set-float! who tif tag value)
  (shared-va-frame 'set-double! 0 value)
  (unless (= 1 (vset tif tag 0 0 value))
    (error who "TIFFSetField failed for tag ~a with value ~a (details logged under the 'tiff topic)"
           tag value)))

(define (tiff-set-x-resolution! tif v) (set-float! 'tiff-set-x-resolution! tif +tag-x-resolution+ v))
(define (tiff-set-y-resolution! tif v) (set-float! 'tiff-set-y-resolution! tif +tag-y-resolution+ v))

(define (set-string! who tif tag s)
  ;; The NUL-terminated byte string must outlive the call; libtiff copies
  ;; the string into its own storage.
  (set! string-scratch
        (bytes-append (string->bytes/utf-8 s) #"\0"))
  (shared-va-frame 'set-pointer! 0 string-scratch)
  (unless (= 1 (vset tif tag (cast string-scratch _pointer _int64)))
    (error who "TIFFSetField failed for tag ~a (details logged under the 'tiff topic)" tag)))

(define (tiff-set-software! tif s) (set-string! 'tiff-set-software! tif +tag-software+ s))

;; Declare the 4th sample as unassociated (straight) alpha.  Returns 1 on
;; success.  libtiff copies the count/array on set, so the temporary cell is
;; freed immediately.
(define (tiff-set-unassociated-alpha! tif)
  (define cell (malloc _uint16 1 'raw))
  (ptr-set! cell _uint16 +extrasample-unassociated+)
  (begin0
    (set-extrasamples/int+pointer! tif 1 cell)
    (free cell)))

;; ExtraSamples setter on the va_list bridge: returns the libtiff status
;; (1 on success, 0 on failure).
(define (set-extrasamples/int+pointer! tif count values)
  (shared-va-frame 'set-int! 0 count)
  (shared-va-frame 'set-pointer! 1 values)
  (vset tif +tag-extrasamples+ count (cast values _pointer _int64)))

;; ---------------------------------------------------------------------------
;; RAII-style helpers

;; Opens `path` with libtiff mode `mode` ("r", "w", ...) and guarantees
;; TIFFClose runs — including when `proc` raises — via dynamic-wind.
(define (call-with-open-tiff path mode proc)
  (define tif (TIFFOpen path mode))
  (unless tif
    (error 'call-with-open-tiff
           "TIFFOpen(~e, ~a) failed (libtiff's message was logged under the 'tiff topic)"
           path mode))
  (dynamic-wind
    (lambda () (void))
    (lambda () (proc tif))
    (lambda () (TIFFClose tif))))

;; Copy a NUL-terminated C message out of a caller-provided buffer of bytes
;; (used for TIFFRGBAImageOK's char emsg[1024]).
(define (c-bytes->string b)
  (define len
    (or (for/first ([i (in-naturals)] [c (in-bytes b)] #:when (zero? c)) i)
        (bytes-length b)))
  (bytes->string/utf-8 (subbytes b 0 len)))

;; ---------------------------------------------------------------------------

(provide ;; library handle & raw bindings
         _tif _tif/null
         TIFFOpen TIFFClose
         TIFFSetErrorHandler TIFFSetWarningHandler
         TIFFReadDirectory TIFFWriteDirectory TIFFSetDirectory
         TIFFNumberOfDirectories
         TIFFScanlineSize64 TIFFReadScanline TIFFWriteScanline
         TIFFReadRGBAImageOriented TIFFRGBAImageOK
         tiff-get-field/u32 tiff-get-field/u16 tiff-get-field/float
         tiff-get-field/string tiff-get-field/extrasamples
         tiff-set-field/int tiff-set-field/float tiff-set-field/string
         tiff-set-field/int+pointer

         ;; tag constants
         +tag-image-width+ +tag-image-length+ +tag-bits-per-sample+
         +tag-compression+ +tag-photometric+ +tag-document-name+
         +tag-image-description+ +tag-orientation+ +tag-samples-per-pixel+
         +tag-rows-per-strip+ +tag-x-resolution+ +tag-y-resolution+
         +tag-planar-config+ +tag-software+ +tag-date-time+ +tag-artist+
         +tag-extrasamples+ +tag-sample-format+ +tag-copyright+

         ;; enum constants
         +extrasample-unspecified+ +extrasample-associated+
         +extrasample-unassociated+
         +orientation-topleft+ +orientation-topright+ +orientation-botright+
         +orientation-botleft+
         +photometric-miniswhite+ +photometric-minisblack+ +photometric-rgb+
         +photometric-palette+
         +sampleformat-uint+ +planarconfig-contig+
         +compression-none+ +compression-lzw+ +compression-jpeg+
         +compression-adobe-deflate+ +compression-packbits+ +compression-deflate+

         ;; compression mapping
         compression-codes compression-mode->code compression-code->symbol

         ;; safe per-tag accessors
         tiff-image-width tiff-image-length tiff-bits-per-sample
         tiff-compression tiff-photometric tiff-orientation
         tiff-samples-per-pixel tiff-rows-per-strip tiff-x-resolution
         tiff-y-resolution tiff-document-name tiff-image-description
         tiff-software tiff-date-time tiff-artist tiff-copyright
         tiff-extrasamples
         tiff-set-image-width! tiff-set-image-length! tiff-set-bits-per-sample!
         tiff-set-compression! tiff-set-photometric! tiff-set-orientation!
         tiff-set-samples-per-pixel! tiff-set-rows-per-strip!
         tiff-set-sample-format! tiff-set-planar-config-contig!
         tiff-set-x-resolution! tiff-set-y-resolution! tiff-set-software!
         tiff-set-unassociated-alpha!

         ;; helpers
         call-with-open-tiff c-bytes->string)
