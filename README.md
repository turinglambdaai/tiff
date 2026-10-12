# tiff

[![CI](https://github.com/turinglambdaai/tiff/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/tiff/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

FFI bindings to [libtiff](https://libtiff.gitlab.io/libtiff/) for Racket:
decode any TIFF that libtiff can read into RGBA pixels, encode RGBA pixels
into TIFF, and read basic metadata.

Racket's built-in `racket/draw` reads PNG, JPEG, GIF and BMP — but not TIFF.
This package fills that gap by binding directly to the system libtiff (no
bundled C code, no compilation).

## Installation

```sh
raco pkg install tiff          # from the package catalog
# or, from a checkout of this repository:
raco pkg install --link /path/to/tiff
```

The package requires libtiff 4.x to be installed on the system; Racket's
FFI loads it at runtime (`libtiff.so.6` / `libtiff.so.5` / `libtiff.dylib`,
versioned names first).

### Platform notes

- **macOS (Homebrew, Apple Silicon):** Homebrew installs libtiff into
  `/opt/homebrew/lib` (or `/usr/local/lib` on Intel), which is *not* in the
  default `dlopen` path.  The package tries those locations automatically
  when the library is not found in the loader's default path, so it works
  out of the box.  Alternatively, set
  `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib` before running Racket.

- **Linux:** distro packages (`libtiff-dev` / `libtiff-devel`) put the
  library on the normal loader path (`ldconfig` cache or
  `LD_LIBRARY_PATH`); no extra configuration is needed.

- **Windows:** not supported in v0.1 (the C runtime's DLL search paths and
  per-machine libtiff availability make this a separate project; patches
  welcome).

## Quick start

```racket
(require tiff)

;; Read metadata.
(tiff-info "photo.tiff")
;; => (info 4000 3000 8 4 'lzw)

;; Decode any TIFF libtiff can handle to RGBA.
(define img (tiff->rgba "photo.tiff"))
(rgba-width img)   ; 4000
(rgba-height img)  ; 3000
;; rgba-data: bytes? with exactly 4 bytes per pixel, R,G,B,A order,
;; non-premultiplied alpha, top-left origin.
(subbytes (rgba-data img) 0 4) ; the top-left pixel

;; Encode RGBA back to TIFF.
(rgba->tiff "out.tiff" img #:compression 'deflate)
;; #:compression accepts '(none lzw deflate packbits); default 'none.

;; Number of pages (IFDs) in a multi-page file.
(tiff-page-count "multi-page.tiff") ; e.g. 2
```

## API

- `(tiff-info path) → info?` — `(info width height bits-per-sample
  samples-per-pixel compression)`, one directory's worth of basic metadata.
- `(tiff->rgba path) → rgba?` — decode the first page of `path` to an `rgba`
  (see below).  Works for any TIFF libtiff can convert: grayscale, bilevel,
  palette, RGB, CMYK, YCbCr, tiled or stripped, classic or BigTIFF.
- `(rgba->tiff path img [#:compression mode]) → void?` — write `img` as a
  classic TIFF with 8-bit contiguous RGBA samples; `mode` is one of
  `'none 'lzw 'deflate 'packbits` (default `'none`).
- `(tiff-page-count path) → exact-nonnegative-integer?` — number of
  directories (pages) in the file.
- `(rgba width height data)` — image as R,G,B,A bytes, 4 bytes per pixel,
  non-premultiplied alpha, top-left origin.  `data` must have exactly
  `(* 4 width height)` bytes.

## Semantics worth knowing

- **Orientation:** `tiff->rgba` always returns a top-left-origin raster; the
  file's `Orientation` tag is normalized by libtiff.
- **Alpha:** `rgba` is straight (non-premultiplied) alpha.  libtiff's RGBA
  reader premultiplies unassociated-alpha files while decoding, so
  `tiff->rgba` converts the result back; for partially transparent pixels
  this is lossy by at most 1 per color channel.  Opaque pixels are exact,
  and `rgba->tiff` writes unassociated alpha.
- **Pixel values:** the RGBA interface scales non-8-bit images (16-bit,
  float) to 8 bits per channel.
- **Logging:** libtiff's error and warning callbacks are routed into
  Racket's logger with topic `tiff` (`'error` / `'warning` levels) instead
  of stdio.  Because libtiff hands handlers a C `va_list`, which has no
  portable FFI representation, printf-style arguments are not interpolated;
  the format string itself is logged.  Failures raise `exn:fail` with
  messages that include the file path; file handles are always closed
  (`dynamic-wind`), including on exceptions.

## Scope (v0.1)

- Sources are **paths only** — no in-memory byte strings yet (that needs
  `TIFFClientOpen` callbacks; planned).
- Writing supports 8-bit contiguous RGBA only, one strip, classic TIFF
  (readers can still decode BigTIFF input).
- `tiff->rgba` decodes the **first page** of a multi-page file; use the
  raw bindings in `tiff/private/ffi` plus `TIFFSetDirectory` for deeper
  page walking.

## Development

```sh
# The env var is optional on this package (it falls back to Homebrew's
# lib directory automatically), but it is the documented, always-works
# invocation on macOS.
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib raco pkg install --auto --link .
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib raco test -p tiff
```

Tests run on GitHub Actions against Ubuntu (apt `libtiff-dev`) and macOS
(`brew install libtiff`); Windows is excluded.

### Regenerating the golden file

`test/data/golden-sips-red-7x5.tiff` is a 7x5 RGBA TIFF produced by macOS
`sips` from a 7x5 PNG of the solid color (R G B) = (199 32 77) drawn with
`racket/draw`.  To regenerate it:

```sh
# 1. draw the PNG (from a scratch directory)
racket -e '(require racket/draw racket/class)
(define bm (make-bitmap 7 5 #f))
(define dc (send bm make-dc))
(send dc set-background (make-object color% 199 32 77 1.0))
(send dc clear)
(send bm save-file "tiny-red.png" (quote png))'

# 2. convert with sips
sips -s format tiff tiny-red.png --out test/data/golden-sips-red-7x5.tiff
```

then update the expected values in `tiff/test/tiff-tests.rkt` if needed.

## License

[MIT](LICENSE) — Copyright (c) 2026 turinglambdaai.  libtiff itself is
dynamically loaded from the system and remains under its own license
([libtiff license](https://libtiff.gitlab.io/libtiff/misc.html)).
