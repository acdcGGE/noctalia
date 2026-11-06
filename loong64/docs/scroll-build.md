# Scroll 文档已迁出 → scroll-loong64 仓库

scroll（合成器）的编译、打包、LightDM 会话、`~/.config/scroll/config`、fcitx5 输入法与追踪上游，现在由**独立仓库**维护：

👉 **[acdcGGE/scroll-loong64 — loong64 工程目录](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64)**

- 完整文档：[`docs/scroll-build.md`](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)
- 打包 / 追上游脚本：[`scripts/track-scroll.sh`](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/scripts/track-scroll.sh)
- 会话入口软链：[`scripts/enable-session.sh`](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/scripts/enable-session.sh)
- 配置片段：[`config/`](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64/config)

## 为什么要分开

| 项目 | 语言 | 工具链 | deb 内容 | 脚本 |
|---|---|---|---|---|
| **noctalia**（本仓库） | C++23 | gcc-14.4.0 + 私有运行时 | `noctalia_*.deb`，约 24 MB | 本仓库 `scripts/track-upstream.sh` |
| **scroll**（另一个仓库） | 纯 C | 系统 gcc 即可 | `scroll_*.deb`，约 7.5 MB，纯系统库 | `track-scroll.sh` |

两个 deb 互相独立、可分别升级。本仓库的 `track-upstream.sh` **只管 noctalia**，不再编译或打包 scroll；反过来 `track-scroll.sh` 也不碰 noctalia。

## 常用命令（在 scroll-loong64 仓库执行）

```bash
loong64/scripts/track-scroll.sh check     # 看上游有无新提交
loong64/scripts/track-scroll.sh sync      # 拉取 + 重编 + 重打 scroll deb
sudo loong64/scripts/enable-session.sh    # LightDM 会话入口软链
scrollmsg reload                          # 重载 ~/.config/scroll/config
```

其余（依赖清单、DRM 后端、`dpkg-shlibdeps` 的 `debian/control` 坑、fcitx5、bindsym 快捷键）请直接看那边文档，避免两份内容分叉。
