# tiff

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/tiff/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/tiff/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Racket 的 [libtiff](https://libtiff.gitlab.io/libtiff/) FFI 绑定：把 libtiff 能读取的任意 TIFF 解码为 RGBA 像素，把 RGBA 像素编码为 TIFF，并读取基本元数据。

Racket 内置的 `racket/draw` 可读取 PNG、JPEG、GIF 与 BMP——但不支持 TIFF。本包通过直接绑定系统 libtiff 填补这一空缺（不捆绑 C 代码，无需编译）。

## 安装

```sh
raco pkg install tiff          # from the package catalog
# or, from a checkout of this repository:
raco pkg install --link /path/to/tiff
```

本包要求系统已安装 libtiff 4.x；Racket 的 FFI 在运行时加载它（`libtiff.so.6` / `libtiff.so.5` / `libtiff.dylib`，优先尝试带版本号的名称）。

### 平台说明

- **macOS（Homebrew，Apple Silicon）：** Homebrew 把 libtiff 安装到 `/opt/homebrew/lib`（Intel 机器上是 `/usr/local/lib`），而该目录*不在*默认的 `dlopen` 搜索路径中。当加载器默认路径找不到库时，本包会自动尝试这些位置，因此开箱即用。也可以在运行 Racket 前设置 `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`。

- **Linux：** 发行版包（`libtiff-dev` / `libtiff-devel`）会把库放进常规加载路径（`ldconfig` 缓存或 `LD_LIBRARY_PATH`），无需额外配置。

- **Windows：** v0.1 不支持（C 运行时的 DLL 搜索路径，加上 libtiff 在各机器上的可用性参差，使其值得单独立项；欢迎补丁）。

## 快速开始

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

- `(tiff-info path) → info?` — 返回 `(info width height bits-per-sample samples-per-pixel compression)`，即单个目录（IFD）所含的基本元数据。
- `(tiff->rgba path) → rgba?` — 把 `path` 的第一页解码为 `rgba`（见下文）。适用于 libtiff 能转换的任意 TIFF：灰度、二值、调色板、RGB、CMYK、YCbCr，平铺或条带组织，经典 TIFF 或 BigTIFF。
- `(rgba->tiff path img [#:compression mode]) → void?` — 把 `img` 写为 8 位连续 RGBA 采样的经典 TIFF；`mode` 为 `'none 'lzw 'deflate 'packbits` 之一（默认 `'none`）。
- `(tiff-page-count path) → exact-nonnegative-integer?` — 文件中的目录（页）数。
- `(rgba width height data)` — 以 R,G,B,A 字节表示的图像：每像素 4 字节，非预乘 alpha，原点在左上。`data` 必须恰好为 `(* 4 width height)` 字节。

## 值得了解的语义

- **方向：** `tiff->rgba` 总是返回原点在左上的光栅；文件的 `Orientation` 标签由 libtiff 归一化。
- **Alpha：** `rgba` 采用直通（非预乘）alpha。libtiff 的 RGBA 读取器在解码时会对 unassociated-alpha 文件做预乘，因此 `tiff->rgba` 会把结果转换回来；对部分透明的像素，每个颜色通道至多损失 1。不透明像素是精确的，且 `rgba->tiff` 写入的是 unassociated（非预乘）alpha。
- **像素值：** RGBA 接口把非 8 位图像（16 位、浮点）缩放到每通道 8 位。
- **日志：** libtiff 的错误与警告回调被接入 Racket 的 logger（topic 为 `tiff`，级别 `'error` / `'warning`），而非 stdio。由于 libtiff 向处理函数传入 C 的 `va_list`（没有可移植的 FFI 表示），printf 风格的参数不会被插值，记录下来的是格式串本身。失败时抛出 `exn:fail`，消息中包含文件路径；文件句柄总是被关闭（`dynamic-wind`），抛异常时也不例外。

## 范围（v0.1）

- 输入源**仅支持路径**——尚不支持内存中的字节串（需要 `TIFFClientOpen` 回调；已在计划中）。
- 写入仅支持 8 位连续 RGBA、单条带、经典 TIFF（读取端仍可解码 BigTIFF 输入）。
- `tiff->rgba` 只解码多页文件的**第一页**；更深入的页遍历请用 `tiff/private/ffi` 中的原始绑定配合 `TIFFSetDirectory`。

## 开发

```sh
# The env var is optional on this package (it falls back to Homebrew's
# lib directory automatically), but it is the documented, always-works
# invocation on macOS.
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib raco pkg install --auto --link .
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib raco test -p tiff
```

测试在 GitHub Actions 上针对 Ubuntu（apt `libtiff-dev`）与 macOS（`brew install libtiff`）运行；Windows 不在范围内。

### 重新生成 golden 文件

`test/data/golden-sips-red-7x5.tiff` 是一张 7x5 RGBA TIFF，由 macOS 的 `sips` 从一张 7x5 PNG 转换而来；该 PNG 用 `racket/draw` 绘制纯色 (R G B) = (199 32 77)。重新生成步骤：

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

然后视需要更新 `tiff/test/tiff-tests.rkt` 中的期望值。

## 许可证

[MIT](LICENSE) — Copyright (c) 2026 turinglambdaai。libtiff 本身从系统动态加载，仍遵循其自身的许可证（[libtiff license](https://libtiff.gitlab.io/libtiff/misc.html)）。
