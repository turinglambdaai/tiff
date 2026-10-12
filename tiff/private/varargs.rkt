#lang racket/base

;; Manual va_list construction for libtiff's TIFFVGetField / TIFFVSetField.
;;
;; WHY THIS EXISTS
;;
;; TIFFGetField and TIFFSetField are C variadic functions (`...`).  Racket
;; CS foreign callouts do not implement the variadic-caller ABI on arm64:
;; every argument past the named ones is delivered to the callee as garbage
;; (verified empirically on macOS arm64 with a diagnostic C library; on
;; x86-64 the register conventions happen to make direct calls work).
;; libtiff exposes non-variadic twins, TIFFVGetField / TIFFVSetField, which
;; take an explicit va_list — and a va_list is just a record pointing at
;; caller-prepared slots, so we build one by hand.  This module implements
;; the ABIs this package targets:
;;
;;   arm64 (Darwin):  va_list is `char *` (yes, really — see the arm64
;;                    psABI): a pointer to the first vararg slot.  Slots
;;                    are 8 bytes; integers, pointers and (promoted)
;;                    doubles each occupy one slot.  Verified with a C
;;                    test program calling TIFFVGetField/TIFFVSetField.
;;
;;   arm64 (Linux, AAPCS64): va_list is a 32-byte container struct
;;                    {void* __stack; void* __gr_top; void* __vr_top;
;;                     int __gr_offs; int __vr_offs} passed BY VALUE.
;;                    GP save area (x0..x7) is 64 bytes, first vararg at
;;                    __gr_top + (-48); VR save area (v0..v7) is 128 bytes,
;;                    doubles at __vr_top + (-128) with a 16-byte stride.
;;
;;   x86-64 (SysV, Linux):  va_list is a 24-byte container
;;                    {u32 gp_offset; u32 fp_offset; void* overflow_arg_area;
;;                     void* reg_save_area} passed by reference (the type is
;;                    an array).  Register save area: x0..x5 (48 bytes) then
;;                    xmm0..xmm7 (128 bytes); GP varargs start at offset 16
;;                    (after the 2 named args), doubles at offset 48 with a
;;                    16-byte stride.
;;                    CRITICAL: the callee's va_start spills the INCOMING
;;                    register args into reg_save_area, overwriting the GP
;;                    vararg slots — so the vararg values must ALSO travel
;;                    as real trailing call arguments (rcx, r8, xmm0), not
;;                    just be written into the slots.  Callers on x86-64
;;                    use the trailing-arg prototypes in ffi.rkt.  The save
;;                    area must be 16-byte aligned (movaps in va_start).
;;
;; All frames are initialized for TIFFGetField/TIFFVSetField, whose named
;; part is (TIFF*, uint32 tag): two named GP arguments, no named FP
;; arguments.  Only up to two varargs are ever needed (EXTRASAMPLES takes a
;; count and a pointer; XRESOLUTION takes one promoted double), so the
;; overflow/stack paths of the ABIs are never exercised.

(require ffi/unsafe)

(define arch (system-type 'arch))
(define os-name (system-type 'os))

(define arm64? (eq? arch 'aarch64))
(define x86-64? (eq? arch 'x86_64))
(define darwin-arm64? (and arm64? (eq? os-name 'macosx)))
(define linux-arm64? (and arm64? (not (eq? os-name 'macosx))))

;; The FFI type of the va_list parameter of TIFFVGetField/TIFFVSetField.
(define va-param-type
  (cond
    [darwin-arm64?  _pointer]  ; va_list is char* — pointer to slot buffer
    [linux-arm64?                   ; va_list is a 32-byte struct, by value
     (make-cstruct-type (list _pointer _pointer _pointer _int32 _int32))]
    [x86-64?        _pointer]  ; pointer to the 24-byte container
    [else (error 'varargs "unsupported architecture: ~a" arch)]))

;; A reusable va_list frame.
;;
;;   (set-int! i v)      put integer vararg i (0-based)
;;   (set-double! i v)   put double vararg i (for promoted float tags)
;;   (set-pointer! i p)  put pointer vararg i (out params, char*, arrays)
;;   (param)             the value to pass as the va_list argument
;;   (free!)             release the underlying buffer
(define (make-va-frame)
  (cond
    ;; ------------------------------------------------------- darwin arm64
    [darwin-arm64?
     ;; 8 slots of 8 bytes are plenty (<= 2 varargs are ever passed).
     (define slots (malloc _uint8 64 'raw))
     (memset slots 0 64)
     (lambda (msg [i 0] [v 0])
       (case msg
         [(set-int!)
          (ptr-set! slots _uint64 i v)]
         [(set-double!)
          ;; One promoted double per call site in libtiff; the 8 value
          ;; bytes go into the slot (the va_arg advance after the read is
          ;; irrelevant for us).
          (ptr-set! slots _double i v)]
         [(set-pointer!)
          (ptr-set! slots _pointer i v)]
         [(param) slots]
         [(free!) (free slots)]
         [else (error 'va-frame "unknown message: ~a" msg)]))]

    ;; --------------------------------------------------- container models
    [else
     ;; reg_save_area must be 16-byte aligned: on x86-64 the callee's
     ;; va_start spills xmm registers into it with movaps, which faults on
     ;; unaligned addresses (the container itself has no alignment needs).
     (define raw (malloc _uint8 512 'raw))
     (memset raw 0 512)
     (define raw-addr (cast raw _pointer _intptr))
     (define aligned-offset (bitwise-and (- 16 (modulo raw-addr 16)) 15))
     (define buf (ptr-add raw aligned-offset)) ; the va_list container
     (define save (ptr-add buf 64))            ; register save area, 16-aligned
     (cond
       [x86-64?
        (ptr-set! buf _uint32 0 16)      ; gp_offset: 2 named GP args consumed
        (ptr-set! buf _uint32 1 48)      ; fp_offset: no named FP args
        (ptr-set! buf _pointer 2 save)   ; overflow_arg_area (never used here)
        (ptr-set! buf _pointer 3 save)]  ; reg_save_area
       [arm64?
        (define gp (ptr-add save 0))     ; x0..x7 spill area
        (define vr (ptr-add save 64))    ; v0..v7 spill area
        (ptr-set! buf _pointer 0 save)               ; __stack (unused)
        (ptr-set! buf _pointer 1 (ptr-add gp 64))    ; __gr_top
        (ptr-set! buf _pointer 2 (ptr-add vr 128))   ; __vr_top
        (ptr-set! buf _int32 3 -48)                  ; __gr_offs: 2 named GP
        (ptr-set! buf _int32 4 -128)])               ; __vr_offs: no named FP
     (define (gp-offset i) (+ 16 (* 8 i)))   ; after 2 named GP args
     (define (fp-offset i)
       ;; x86-64: FP area at reg_save_area+48, 16-byte stride
       ;; arm64:  VR area at __vr_top-128 = save+64, 16-byte stride
       (if x86-64? (+ 48 (* 16 i)) (+ 64 (* 16 i))))
     (lambda (msg [i 0] [v 0])
       (case msg
         [(set-int!)
          (ptr-set! (ptr-add save (gp-offset i)) _uint64 v)]
         [(set-double!)
          (ptr-set! (ptr-add save (fp-offset i)) _double v)]
         [(set-pointer!)
          (ptr-set! (ptr-add save (gp-offset i)) _pointer v)]
         [(param)
          (if linux-arm64?
              (ptr-ref buf va-param-type)  ; 32-byte struct, passed by value
              buf)]
         [(free!) (free buf)]
         [else (error 'va-frame "unknown message: ~a" msg)]))]))

;; The module-level shared frame.  Callers fill the slots they need
;; immediately before each TIFFVGetField/TIFFVSetField call, so stale slot
;; values are never read (every tag reads a fixed, known number of slots).
;; Reuse assumes a single thread per Racket place, like the rest of the FFI.
(define va-frame (make-va-frame))

(provide va-param-type
         make-va-frame
         x86-64?
         (rename-out [va-frame shared-va-frame]))
