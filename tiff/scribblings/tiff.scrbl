#lang scribble/manual

@(require scribble/manual-struct
          (for-label tiff
                     racket/base
                     racket/contract))

@title[#:tag "top"]{tiff: TIFF images via libtiff}
@author{turinglambdaai}

@defmodule[tiff]

The @racket[tiff] package provides FFI bindings to
@hyperlink["https://libtiff.gitlab.io/libtiff/"]{libtiff}, the standard C
library for reading and writing TIFF files.  It can decode any TIFF that
libtiff can handle — grayscale, bilevel, palette, RGB, CMYK, YCbCr,
tiled or stripped, classic TIFF or BigTIFF — into RGBA pixels, and it can
encode RGBA pixels back into TIFF.

@section{Why this package exists}

Racket's built-in @racket[racket/draw] reads PNG, JPEG, GIF and BMP bitmaps,
but not TIFF.  TIFF refuses to die: it is the lingua franca of scanners,
scientific imaging, geospatial data and document management.  Rather than
reimplement 40 years of TIFF arcana in pure Racket, @racket[tiff] binds
directly to the system libtiff — no bundled C code, nothing to compile, and
every TIFF feature libtiff supports comes along for the ride.

@section{Installation and platform notes}

Install the package and make sure libtiff 4.x is present on the system:

@itemlist[
 @item{@bold{macOS (Homebrew).}  @exec{brew install libtiff}.  Homebrew
   puts the library in @filepath{/opt/homebrew/lib} (Apple Silicon) or
   @filepath{/usr/local/lib} (Intel).  Those locations are not in the
   default @tt{dlopen} path, so the package also probes them directly and
   normally just works.  If your libtiff lives somewhere else, run Racket
   with:

   @verbatim|{
DYLD_FALLBACK_LIBRARY_PATH=/dir/with/libtiff racket ...
}|}

 @item{@bold{Linux.}  Install the distro package (@tt{libtiff-dev} on
   Debian/Ubuntu, @tt{libtiff-devel} on Fedora).  The loader finds the
   versioned soname through the @tt{ldconfig} cache or
   @envvar{LD_LIBRARY_PATH}; no extra configuration is needed.}

 @item{@bold{Windows.}  Not supported in v0.1.}

]

The loader prefers versioned sonames (@filepath{libtiff.so.6},
@filepath{libtiff.so.5}, @filepath{libtiff.6.dylib}) before the unversioned
development symlink, so systems that only ship the runtime library work
fine.

@section{Data model}

@defstruct*[rgba ([width exact-positive-integer?]
                  [height exact-positive-integer?]
                  [data bytes?])]{

An in-memory image: @racket[data] holds exactly @racket[(* 4 width height)]
bytes, four bytes per pixel in R, G, B, A order, with @emph{straight}
(non-premultiplied) alpha and a top-left origin (row 0 is the top row).
The constructor checks the byte-string length.

}

@section{Reading and writing}

@defproc[(tiff-info [path path-string?]) info?]{

Returns basic metadata for the first directory of @racket[path]:

@racketblock[
(tiff-info "photo.tiff")
;; ==> (info 4000 3000 8 4 'lzw)
]

The @racket[compression] field is a symbol: @racket['none], @racket['lzw],
@racket['deflate], @racket['packbits], @racket['jpeg], or @racket['code-N]
for schemes this package does not name.

}

@defproc[(tiff->rgba [path path-string?]) rgba?]{

Decodes the first page of @racket[path] through libtiff's high-level RGBA
interface.  Non-8-bit samples are scaled to 8 bits, other photometric
interpretations are converted to RGB transparently, and the result always
has a top-left origin regardless of the file's @tt{Orientation} tag.

Two alpha subtleties, handled for you:

@itemlist[
 @item{Files with no alpha decode with @racket[alpha = 255]
   everywhere.}
 @item{libtiff's RGBA reader returns @emph{premultiplied} pixels for files
   whose alpha is declared associated or unassociated.  Because the
   @racket[rgba] type is straight alpha, @racket[tiff->rgba] converts the
   values back.  Opaque pixels are exact; partially transparent pixels may
   differ from the file's nominal values by at most 1 per color channel.}

]

Signals @racket[exn:fail] if the file is missing, is not a TIFF, or cannot
be decoded; libtiff's own diagnostics are logged under the @tt{tiff} topic
(see @secref["logging"]).

}

@defproc[(rgba->tiff [path path-string?]
                     [img rgba?]
                     [#:compression mode compression-mode/c 'none])
         void?]{

Writes @racket[img] to @racket[path] as a classic TIFF with 8-bit
contiguous RGBA samples (the fourth sample declared as unassociated/straight
alpha).  @racket[mode] is one of @racket['none], @racket['lzw],
@racket['deflate], or @racket['packbits].

@racketblock[
(rgba->tiff "out.tiff" img #:compression 'deflate)
]

}

@defproc[(tiff-page-count [path path-string?])
         exact-nonnegative-integer?]{

Returns the number of directories (pages) in the file.  Note that
@racket[tiff->rgba] always decodes the @emph{first} page; walking to later
pages requires the raw bindings in @filepath{tiff/private/ffi}.

}

@section[#:tag "logging"]{Error handling and logging}

libtiff reports problems through two C callback registries.  This package
routes them into Racket's logger with topic @racket['tiff] and levels
@racket['error] and @racket['warning], using @racket[current-logger] at the
time of the call:

@racketblock[
(define receiver (make-log-receiver (current-logger) 'warning 'tiff))
]

Because libtiff passes its handlers a C @tt{va_list}, which has no portable
FFI representation, printf-style arguments are @emph{not} interpolated; the
format string itself is logged.  Racket-level failures raise
@racket[exn:fail] with messages that include the file path.  File handles
are managed with @racket[dynamic-wind], so libtiff files are always closed —
including when an exception unwinds through a decode or encode.

@section{Limitations and future work}

@itemlist[
 @item{Sources and destinations are @emph{paths only} in v0.1; decoding from
   in-memory byte strings needs @tt{TIFFClientOpen} callbacks and is
   planned.}
 @item{Writing supports 8-bit contiguous RGBA only (one strip, classic
   TIFF).  Reading has no such restriction.}
 @item{@racket[tiff->rgba] scales 16-bit and floating-point input down to
   8 bits per channel, following libtiff's RGBA interface.}
 @item{Only the four corner orientations are normalized by libtiff;
   mirrored/rotated variants (Orientation 5-8) are reflected, not rotated.}
]

@section{Raw bindings}

The low-level bindings live in the private module
@racket[tiff/private/ffi]: @tt{TIFFOpen}, @tt{TIFFClose},
fixed-arity specializations of the varargs @tt{TIFFGetField}/
@tt{TIFFSetField}, the scanline API, the RGBA image API, and the safe
per-tag wrappers used by the public functions.  They are exported for
applications that need more of libtiff than the high-level API exposes, but
are undocumented here and may shift between minor releases.
