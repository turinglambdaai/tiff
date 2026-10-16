# AGENTS.md

libtiff 的 Racket FFI 绑定：TIFF 图像读写（MIT，已上架 Racket catalog）。

## 结构

Multi-collection 包：collection 即 `tiff/` 子目录，scribblings 声明在 `tiff/info.rkt`（collection 级）；`test/` 在包内。

## 常用命令

```bash
brew install libtiff            # 原生依赖（CI 同款）
raco pkg install --auto --link "$(pwd)"
raco test tiff/test/tiff-test.rkt
```

## 验证与发版

- CI（`ci.yml`）：装 libtiff → 安装包 → 显式路径跑测试。
- 发版 = tag `v<版本>` + CHANGELOG 同步；catalog 侧为手动提交（pkgd）。

## 仓库特定规矩

- FFI 包：包内测试省略原生绑定模块的加载路径问题走 CI 显式路径模式；本机跑测试前确认 libtiff 在库搜索路径上。
