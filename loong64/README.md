# Noctalia on loong64

在 **Deepin 25（loong64 / LoongArch）** 上编译、打包、部署 [noctalia](https://github.com/noctalia-dev/noctalia)（C++23 Wayland 桌面 shell）的移植工程文件。

本目录位于仓库的 **`loong64` 分支**，只新增文件，**不改动 noctalia 上游源码**；`main` 分支保持为上游镜像。

> 配套合成器 [scroll](https://github.com/dawsers/scroll) 的工程文件在**另一个仓库**：
> https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64
> 两个项目互不耦合，各自有独立的构建/打包/追上游脚本与文档。

---

## 为什么需要这套东西

| 问题 | 处理 |
|---|---|
| 系统 gcc-12.3 不支持完整 C++23（`<print>`、`std::ranges::to`） | 使用源码编译的 **gcc-14.4.0**（`/opt/gcc-14.4.0`），原生提供所需标准库 |
| 系统 `libstdc++` 版本太旧 | 把 gcc-14.4.0 的运行时私有打包到 `/usr/local/lib/noc`，链接期烤入 RUNPATH，不污染系统 |
| `libsdbus-c++-dev` 在 Deepin 未打包 | 从 Kistler-Group/sdbus-cpp 源码编译，运行时一并打进 deb |
| `libstb-dev` 太旧，缺 `stb_image_resize2.h` | 从 nothings/stb `deprecated/` 取单头文件 |
| noctalia 注销无反应 | scroll 的 IPC 工具叫 `scrollmsg` 而非 `swaymsg`，打 `patches/` 里的补丁 |
| 控制中心显示「未知 CPU」 | 上游只读 x86 的 `model name`，LoongArch 输出 `Model Name : Loongson-3A5000`；打 `patches/cpu-model-loongarch.patch`（详见文档 §4.1） |
| `libqalculate-dev` 与 `libcurl4-openssl-dev` 冲突 | 先移除后者，再装 `libcurl4-gnutls-dev` |

产物是**一个独立 deb**：

```
noctalia_0.0~noctalia.<8位上游hash>-<本地修订>_loong64.deb   自带 gcc-14 运行时 + sdbus-c++，约 24 MB
```

`scroll_*.deb` 由 [scroll-loong64 仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64) 单独产出（纯系统库依赖，约 7.5 MB），需要时一并安装。noctalia 的 control 里以 `Recommends: scroll` 声明这层关系。

---

## 目录结构

```
loong64/
├── README.md                         本文件
├── docs/
│   ├── noctalia-build.md             Noctalia 编译 / 打包 / 启用（完整独立文档）
│   └── scroll-build.md               指针页：指向 scroll-loong64 仓库的文档
├── scripts/
│   ├── track-upstream.sh             只管 noctalia：check / update / rebuild / sync
│   ├── check-cpu-model.sh            CPU 型号识别回归检查（7 组样本断言）
│   └── enable-session.sh             LightDM 会话入口软链（需 sudo）
├── patches/
│   ├── scrollmsg-logout-fix.patch    注销 bug 修复（标准 unified diff）
│   └── cpu-model-loongarch.patch     LoongArch CPU 型号识别（标准 unified diff）
└── config/
    ├── scroll-config.snippet          ~/.config/scroll/config 片段（输入法/自启/快捷键）
    └── profile.snippet                ~/.profile 输入法环境变量片段
```

`scripts/track-upstream.sh` **只编译、只打包 noctalia**，不会产出 scroll deb；合成器请用 scroll 仓库的 `track-scroll.sh`。两份工程目录下的 `config/` 片段内容按各自语境略有侧重，会话配置以 [scroll 仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64/config) 为准。

---

## 快速开始

1. **准备工具链与依赖** → 按 [`docs/noctalia-build.md`](docs/noctalia-build.md) §1–§2（gcc-14.4.0、apt 依赖、sdbus-c++、stb 头）
2. **编译 + 首次打包** → 按文档的「编译」「打包」章节；或环境就绪后直接 `scripts/track-upstream.sh rebuild`
3. **打源码补丁** → `scrollmsg-logout-fix.patch` + `cpu-model-loongarch.patch`（`rebuild` 会自动幂等重打这两个补丁；`scripts/check-cpu-model.sh` 可回归验证识别逻辑）
4. **安装** → `sudo apt install ./noctalia_*.deb`。**必须用 apt**：control 声明了 `Conflicts/Replaces: noctalia-desktop`，apt 会自动移除旧合并包；`dpkg -i` 不会处理冲突、会直接失败（详见文档 §6.1）
5. **合成器与会话** → 见 [scroll-loong64 仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64)：装 `scroll_*.deb`、`enable-session.sh`、配置 `~/.config/scroll/config` 与 fcitx5
6. **追上游** → 本仓库 `track-upstream.sh check` / `sync`；scroll 用它的 `track-scroll.sh`

脚本的全部路径都可用环境变量覆盖（`BUILD_ROOT`、`NOCTALIA_DIR`、`GCC_DIR`、`STB_DIR`、`PKGCFG`、`SDBUS_LIB`、`DEB_OUT`、`NOCTALIA_REMOTE`、`NOCTALIA_BRANCH`、`BUILD_REV`、`PATCH_DIR`，见脚本头部），默认 `$HOME/build`。

```bash
loong64/scripts/track-upstream.sh check     # 安全：只看 noctalia 有无新提交
loong64/scripts/track-upstream.sh sync      # 一键 update + 重编 + 重打包 noctalia deb
```

---

## 已验证的打包要点

`rebuild` 里固化了几个踩过坑的处理，手工打包时不要漏：

1. **libstdc++ 通配要排除 `-gdb.py`**：`libstdc++.so.6.0.*` 会匹配到 `libstdc++.so.6.0.NN-gdb.py`（2 KB 文本辅助文件），选错会导致打进去的 `libstdc++.so.6` 是坏的、`CXXABI_1.3.15 not found`。脚本还会额外校验选中的文件是真实 ELF。
2. **`dpkg-shlibdeps` 必须在含 `debian/control` 的目录下运行**，否则 `error: cannot read debian/control`（exit 25）会静默中断打包。脚本 stderr 单独留档、失败立即打印。
3. **noctalia 的 `Depends` 要剔除** `libstdc++6` / `libgcc-s1`（已私有打包），否则 `dpkg -i` 拒装。
4. **不要事后用 patchelf 改 RUNPATH**：0.18 对 60MB+ 二进制会触发 `virtual address space underrun`。在链接期用 `meson configure -Dcpp_link_args` 烤入。
5. **scrollmsg 检测要精确匹配** `m_msgCommand = "scrollmsg"`：上游只在 `m_outputCommand` 块加了 scrollmsg，只 grep `commandExists("scrollmsg")` 会误判已修复而跳过补丁。
6. **ldd 校验要强制私有路径**：不设 `LD_LIBRARY_PATH` 时，系统 gcc-12 与私有 gcc-14 的 libstdc++ 被同时装载，会误报 `CXXABI_1.3.15 not found`。
7. **CPU 型号补丁要按标记检测**：`grep cpuInfoKeyRank` 判断补丁是否在位，未打时用 `git apply --check` + `git apply` 重打；上游改动 `hardware_info.cpp` 导致上下文失配时会明确报错而不是静默跳过。

`rebuild` 结束会自动检查：私有 libstdc++ 是 ELF、RUNPATH 无 `/opt` 泄漏、强制私有路径下 `ldd` 零缺失、源码补丁在位、`dpkg --force-conflicts -i --dry-run` 通过。

---

## 平台与工具链

- OS：Deepin 25 "beige"，arch `loong64`
- 编译器：gcc-14.4.0（`/opt/gcc-14.4.0`），链接器 lld
- 构建：meson + ninja；打包：dpkg-deb / dpkg-shlibdeps

> scroll 是纯 C 项目，用系统 gcc 即可编译；gcc-14.4.0 只为 noctalia 的 C++23 所需。

## 上游与许可

noctalia 与 scroll 各自的上游许可见其仓库；本目录仅为 loong64 平台的构建/打包工程文件与文档。上游地址：

- https://github.com/noctalia-dev/noctalia
- https://github.com/dawsers/scroll
