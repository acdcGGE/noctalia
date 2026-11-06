# Noctalia 在 loong64 上的编译、打包与配置

> 目标平台：Deepin 25（loong64 / LoongArch）
> 工具链：**gcc-14.4.0**（源码编译安装到 `/opt/gcc-14.4.0`）
> 产物：独立 deb `noctalia_0.0~noctalia.<hash>-1_loong64.deb`
> 本仓库：https://github.com/acdcGGE/noctalia-loong64/tree/loong64/loong64
> 配套文档：合成器的编译 / 打包 / 会话 / 输入法见
> [scroll-loong64 工程文档](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)

---

## 0. 这是什么、为什么要单独编

noctalia 是 C++23 写的 Wayland 桌面 shell（栏、坞、启动器、通知中心、锁屏、壁纸、会话动作等），**不是**合成器。它需要一个 Wayland 合成器承载，本项目配套的是 [scroll](https://github.com/dawsers/scroll)（sway fork）。因此：

- 本文件只讲 **noctalia**：依赖、编译、私有运行时、注销 bug 修复、打包、启用、快捷键、追踪上游。
- 合成器安装、LightDM 会话入口、会话配置、输入法环境变量 → 见 [scroll 文档](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)，工程文件在 [scroll-loong64 仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64)。
- 两者打包为**互相独立、可分别升级的两个 deb**，分别由各自仓库的脚本产出；noctalia 的 control 里 `Recommends: scroll`。

Deepin 25 自带 gcc-12.3 不支持完整 C++23（`<print>`、`std::ranges::to` 等），apt 源里也没有可用的 g++-14（搜索 `g++-14` 只会误命中 `clang-14-doc`）。因此需要先在 `/opt` 放一套 gcc-14.4.0， noctalia 与运行时都从它来。scroll 是纯 C 项目，用系统 gcc 即可，不需要这套工具链。

---

## 1. 前置：工具链与公共环境

```bash
# gcc-14.4.0（用户自行源码编译，安装到 /opt/gcc-14.4.0，自带 libstdc++ 14.4）
sudo apt-get install -y lld meson ninja-build cmake patchelf

# 约定一个构建根，后文全部用 $BUILD_ROOT
export BUILD_ROOT=$HOME/build
mkdir -p "$BUILD_ROOT"

export CC=/opt/gcc-14.4.0/bin/gcc
export CXX=/opt/gcc-14.4.0/bin/g++
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig    # 自编译的 sdbus-c++
export CFLAGS="-I$BUILD_ROOT/stb-headers"
export CXXFLAGS="-I$BUILD_ROOT/stb-headers"
export LDFLAGS="-fuse-ld=lld -Wl,-rpath,/usr/local/lib/noc:/usr/local/lib"
```

gcc-14 **原生提供** `<print>` 与 `std::ranges::to`，无需额外兼容头。`stb-headers/` 里只需放一个 `stb/stb_image_resize2.h`（见 §2.2）。

> 中文 locale 的隐藏坑：Deepin 源的 `apt-cache` 输出是「候选:」而不是「Candidate:」，容易误判某个包不存在。看不准时直接 `apt-get download <pkg>` 试探，或用 `apt-cache search` 确认包名。

---

## 2. 系统依赖

### 2.1 apt 安装的 dev 库

```bash
sudo apt-get install -y \
  libwayland-dev libwayland-client++1 libwayland-cursor++1 \
  libxkbcommon-dev libinput-dev libdrm-dev \
  libdisplay-info-dev hwdata \
  libpango1.0-dev libcairo2-dev \
  libpipewire-0.3-dev libspa-1.0-dev \
  libqalculate-dev \
  libpng-dev libjpeg-dev libcurl4-gnutls-dev \
  libdbus-1-dev libglib2.0-dev \
  libgtk-3-dev libmagic-dev \
  libsqlite3-dev libfmt-dev \
  libssl-dev
```

**冲突处理（关键）**：`libqalculate-dev` 依赖 `libcurl4-gnutls-dev`，与 `libcurl4-openssl-dev` 互斥。若系统已装后者，先 `sudo apt-get remove libcurl4-openssl-dev`。`hwdata` 别漏，scroll 的 DRM 后端需要它（见 [scroll 文档 §1](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)）。

### 2.2 stb_image_resize2.h

系统 `libstb-dev` 太旧，缺 `stb_image_resize2.h`。从上游 `deprecated/` 取：

```bash
mkdir -p "$BUILD_ROOT/stb-headers/stb"
curl -L -o "$BUILD_ROOT/stb-headers/stb/stb_image_resize2.h" \
  https://raw.githubusercontent.com/nothings/stb/master/deprecated/stb_image_resize2.h
```

noctalia 用 `#include <stb/stb_image_resize2.h>`，目录结构必须是 `stb-headers/stb/stb_image_resize2.h`。

### 2.3 sdbus-c++ 源码编译（Deepin 未打包）

> 旧地址 `https://github.com/systemd/sdbus-cpp` 已 404，用 Kistler-Group 的维护仓库。

```bash
sudo apt-get install -y cmake libexpat1-dev libsystemd-dev
cd "$BUILD_ROOT"
git clone https://github.com/Kistler-Group/sdbus-cpp.git
cd sdbus-cpp && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
         -DCMAKE_BUILD_TYPE=Release \
         -DBUILD_SHARED_LIBS=ON \
         -DSDBUSCPP_BUILD_TESTS=OFF
make -j"$(nproc)"
sudo make install && sudo ldconfig
```

产物：`/usr/local/lib/pkgconfig/sdbus-c++.pc`（这就是 §1 加 `PKG_CONFIG_PATH` 的原因）、运行时 `/usr/local/lib/libsdbus-c++.so.2.3.1`。这个运行时后面要打进 noctalia 的 deb。

---

## 3. 编译

```bash
cd "$BUILD_ROOT"
git clone https://github.com/noctalia-dev/noctalia
cd noctalia

meson setup build-release \
  --buildtype=release \
  -Dcpp_std=c++23 \
  -Dtests=auto \
  -Db_lto=false \
  --prefix /usr/local

meson compile -C build-release noctalia
```

**必须关 LTO（`-Db_lto=false`）**：若曾用 `-Db_lto=true` 编过，对象文件是 LTO 位码，lld 链接时会报 `undefined reference to main`。彻底修复：

```bash
meson setup build-release --wipe --buildtype=release -Dcpp_std=c++23 \
  -Dtests=auto -Db_lto=false --prefix /usr/local
meson compile -C build-release noctalia
```

产物：`build-release/noctalia`（约 62 MB）。

### 3.1 把 RUNPATH 烤进二进制（不要事后 patch）

noctalia 依赖 gcc-14 的 `libstdc++.so.6`，系统只有 gcc-12 的版本。运行时会私有打包到 `/usr/local/lib/noc`，所以链接期就把 rpath 设好：

```bash
meson configure build-release \
  -Dcpp_link_args="-fuse-ld=lld -Wl,-rpath,/usr/local/lib/noc:/usr/local/lib"
meson compile -C build-release noctalia
readelf -d build-release/noctalia | grep -i runpath
# 应输出：/usr/local/lib/noc:/usr/local/lib
```

> 不要用 patchelf 事后改：0.18 版对 60MB+ 二进制会触发 `virtual address space underrun`，把 rpath 截断。链接期烤入最省事也最稳。

---

## 4. 修复「注销无反应」bug（必做）

**根因**：`src/compositors/sway/sway_runtime.cpp` 的 `resolveCommands()` 里，`m_msgCommand`（负责 `exit` / 键盘 / 输入等 IPC）只认 `swaymsg`、`i3-msg`，漏了 `scrollmsg`。而配套合成器只提供 `scrollmsg`，注销时实际执行不存在的 `swaymsg exit`，静默失败。`m_outputCommand` 倒是查了 scrollmsg，所以显示探测正常，只有注销最显眼。

补丁（也可直接用工程目录里的 `patches/scrollmsg-logout-fix.patch`）：

```diff
   void SwayRuntime::resolveCommands() const {
-    if (process::commandExists("swaymsg")) {
+    if (process::commandExists("scrollmsg")) {
+      m_msgCommand = "scrollmsg";
+    } else if (process::commandExists("swaymsg")) {
       m_msgCommand = "swaymsg";
     } else if (process::commandExists("i3-msg")) {
       m_msgCommand = "i3-msg";
```

```bash
cd "$BUILD_ROOT/noctalia"
git apply /path/to/scrollmsg-logout-fix.patch
meson compile -C build-release noctalia
```

> **上游至今未修**：上游只在 `m_outputCommand` 块加了 scrollmsg，`m_msgCommand` 仍缺。所以每次 `track-upstream.sh update` 切到新上游后，补丁都要重打（脚本的 `rebuild` 会自动幂等重打）。检测时必须精确匹配 `m_msgCommand = "scrollmsg"`，若只 grep `commandExists("scrollmsg")` 会被 outputCommand 误触发而跳过补丁。

装完需**注销并重新登录**（内存里仍是旧进程）才生效。

---

## 4.1 修复控制中心「未知 CPU」（LoongArch 必做）

**现象**：控制中心 → 系统，第一行显示「未知 CPU」（英文界面 `Unknown CPU`），而 CPU 曲线、频率、温度都正常。

**根因**：`src/system/hardware_info.cpp` 的 `readCpuModel()` 只认 x86 的小写前缀：

```cpp
if (line.starts_with("model name")) { ... }
```

LoongArch 内核的 `/proc/cpuinfo` 用的是 `Model Name`（首字母大写，且以 tab 填充）：

```
CPU Family		: Loongson-64bit
Model Name		: Loongson-3A5000
```

匹配不上就走 `i18n::tr("system.hardware.unknown-cpu")` 兜底。**这不是配置项问题**：`example.toml` 和用户设置里没有 CPU 名称覆盖项，只能改源码识别逻辑。

**补丁**：`patches/cpu-model-loongarch.patch`。做法是把键名归一化（转小写、去掉空格/tab 等分隔符），再按字段优先级取最具体的值：

| 优先级 | 归一化键 | 来源 | 例子 |
|---|---|---|---|
| 0 | `modelname` | x86 `model name`、LoongArch `Model Name` | `Loongson-3A5000` |
| 1 | `cpumodel` | MIPS/老龙芯 `cpu model` | `Loongson-3A5000 V0.4 FPU V0.1` |
| 2 | `hardware` | ARM `Hardware` | `BCM2711` |
| 3 | `processor` | 老 ARM `Processor` | `ARMv8 Processor rev 3 (v8l)` |

纯数字值会被跳过，避免 x86 的 `processor : 0` 被当成型号。x86 行为不变（仍是第一个 `model name` 的值）。

```bash
cd "$BUILD_ROOT/noctalia"
git apply "$BUILD_ROOT/noctalia-loong64-repo/loong64/patches/cpu-model-loongarch.patch"
meson compile -C build-release noctalia
```

`track-upstream.sh rebuild` 会自动幂等重打此补丁（检测 `cpuInfoKeyRank` 标记，缺了才 `git apply`），`update` 重置源码后不会漏。补丁同时作为 `rebuild` 的第 4 项校验。

**验证**：

```bash
grep -m1 '^Model Name' /proc/cpuinfo        # Model Name  : Loongson-3A5000
loong64/scripts/check-cpu-model.sh         # 从源码抽取解析函数编译 harness，7 组样本断言
```

回归脚本直接抽取 `hardware_info.cpp` 里的三个函数编译运行，覆盖真实 `/proc/cpuinfo` 与 x86 / LoongArch / MIPS / ARM / 无匹配字段等样本；上游改了函数名或补丁丢失时会直接报错。

装上新二进制并**注销重新登录**后，控制中心第一行应显示 `Loongson-3A5000`。CPU 型号在进程里只缓存一次（`std::call_once`），热替换二进制不会刷新已运行的 shell。

---

## 5. 打包成独立 deb

noctalia 的 deb 自带 gcc-14 运行时，装到 `/usr/local/lib/noc`（**故意放子目录**：`ldconfig` 不递归子目录，不会污染系统 libstdc++，只有 noctalia 经 RUNPATH 命中）。

### 5.1 暂存 + 私有运行时

```bash
export DEB_OUT="$BUILD_ROOT/deb"
mkdir -p "$DEB_OUT/noctalia-root"
meson install -C "$BUILD_ROOT/noctalia/build-release" \
  --destdir "$DEB_OUT/noctalia-root" --no-rebuild

mkdir -p "$DEB_OUT/noctalia-root/usr/local/lib/noc"
# libstdc++ 用真实 ELF，注意排除 -gdb.py 辅助文件（见 §5.3 坑 1）
STDC=$(for f in /opt/gcc-14.4.0/lib/libstdc++.so.6.0.*; do
        case "$f" in *.py|*.la|*.a) continue;; esac
        [ -f "$f" ] && echo "$f"
      done | sort -V | tail -1)
cp -a "$STDC" "$DEB_OUT/noctalia-root/usr/local/lib/noc/libstdc++.so.6"
cp -a /opt/gcc-14.4.0/lib/libgcc_s.so.1      "$DEB_OUT/noctalia-root/usr/local/lib/noc/"
cp -a /opt/gcc-14.4.0/lib/libatomic.so.1.2.0 "$DEB_OUT/noctalia-root/usr/local/lib/noc/libatomic.so.1"

cp -a /usr/local/lib/libsdbus-c++.so.2.3.1 "$DEB_OUT/noctalia-root/usr/local/lib/"
ln -sf libsdbus-c++.so.2.3.1 "$DEB_OUT/noctalia-root/usr/local/lib/libsdbus-c++.so.2"
ln -sf libsdbus-c++.so.2.3.1 "$DEB_OUT/noctalia-root/usr/local/lib/libsdbus-c++.so"
```

### 5.2 依赖推导 + control

`dpkg-shlibdeps` **必须在含 `debian/control` 的目录下运行**，否则报 `error: cannot read debian/control`（exit 25）。先在 `$DEB_OUT/debian/control` 放一份最小 control，再 `cd $DEB_OUT` 执行：

```bash
mkdir -p "$DEB_OUT/debian"
cat > "$DEB_OUT/debian/control" <<'EOF'
Source: noctalia-loong64
Section: x11
Priority: optional
Maintainer: local-build <local@build>

Package: noctalia
Architecture: loong64
Description: Noctalia desktop shell (C++23)
EOF

( cd "$DEB_OUT"
  dpkg-shlibdeps --ignore-missing-info -O \
    -e noctalia-root/usr/local/bin/noctalia > "$DEB_OUT/noc-deps.txt" )
# 按逗号切分后逐项过滤，避免用 sed 直接删中间项时吃掉逗号后的空格
NOC_DEPS=$(sed -n 's/^shlibs:Depends=//p' "$DEB_OUT/noc-deps.txt" \
  | tr ',' '\n' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -vE '^(libgcc-s1|libstdc\+\+6)([[:space:]]|$)' \
  | grep -v '^$' \
  | paste -sd, - | sed 's/,/, /g')
```

**必须剔除** `libgcc-s1`、`libstdc++6` 两项：它们已由 `/usr/local/lib/noc` 私有打包，若留在 `Depends` 里，系统只有 gcc-12 的 libstdc++6，`dpkg -i` 会直接拒装。

```bash
NOC_HASH=$(git -C "$BUILD_ROOT/noctalia" rev-parse --short=8 HEAD)
mkdir -p "$DEB_OUT/noctalia-root/DEBIAN"
cat > "$DEB_OUT/noctalia-root/DEBIAN/control" <<EOF
Package: noctalia
Version: 0.0~noctalia.$NOC_HASH-1
Section: x11
Priority: optional
Architecture: loong64
Depends: $NOC_DEPS
Recommends: scroll
Conflicts: noctalia-desktop
Replaces: noctalia-desktop
Maintainer: local-build <local@build>
Description: Noctalia - C++23 desktop shell for Wayland (self-built)
 Desktop shell layer built against gcc-14.4.0. The gcc-14.4.0 runtime
 (libstdc++, libgcc_s, libatomic) is privately bundled under
 /usr/local/lib/noc, and sdbus-c++ under /usr/local/lib, so no system
 gcc-14 is required. Requires a Wayland compositor (e.g. scroll).
EOF
```

`DEBIAN/postinst` 与 `DEBIAN/postrm`（都 `chmod 755`），内容均为 `ldconfig`：

```sh
#!/bin/sh
set -e
case "$1" in configure|abort-upgrade) ldconfig ;; esac   # postinst
# postrm 把上一行的 configure|abort-upgrade 换成 remove|purge
```

### 5.3 两个会让包报废的坑

1. **libstdc++ 通配选错文件**：`/opt/gcc-14.4.0/lib/libstdc++.so.6.0.*` 会同时匹配 `libstdc++.so.6.0.33`（22 MB 真实 ELF）和 `libstdc++.so.6.0.33-gdb.py`（2399 字节文本辅助文件）。`sort -V | tail -1` 可能选中后者 → 打进去的 `libstdc++.so.6` 是坏的，`CXXABI_1.3.15` 找不到，noctalia 起不来。务必按 §5.1 排除 `.py/.la/.a`。
2. **缺 `debian/control`**：见 §5.2，报错是 exit 25 且脚本会中途停住，容易只完成编译没产出 deb。

### 5.4 封包与校验

```bash
dpkg-deb --build --root-owner-group \
  "$DEB_OUT/noctalia-root" "$DEB_OUT/noctalia_0.0~noctalia.${NOC_HASH}-1_loong64.deb"

# 依赖可满足
dpkg --force-conflicts -i --dry-run "$DEB_OUT"/noctalia_*.deb

# 解包校验：真实 ELF、零 /opt、零 not-found
T=$(mktemp -d); dpkg-deb -x "$DEB_OUT"/noctalia_*.deb "$T"
file "$T/usr/local/lib/noc/libstdc++.so.6"          # 必须是 ELF，不是文本
readelf -d "$T/usr/local/bin/noctalia" | grep -i runpath
LD_LIBRARY_PATH="$T/usr/local/lib/noc:$T/usr/local/lib" \
  ldd "$T/usr/local/bin/noctalia" | grep 'not found' || echo "OK: 无缺失"
rm -rf "$T"
```

> 直接 `ldd` 而不设 `LD_LIBRARY_PATH` 时，可能因为系统 gcc-12 与私有 gcc-14 两个 libstdc++ 被同时装载而误报 `CXXABI_1.3.15 not found`；这是 ldd 的双装载假象，按上面强制私有路径即可确认。

---

## 6. 安装与启用

**用 `apt install`，不要用 `dpkg -i`**（原因见 §6.1）：

```bash
cd "$DEB_OUT"                      # deb 所在目录
sudo apt install ./noctalia_*.deb
which noctalia

noctalia --daemon                  # 启动栏/坞/启动器/通知等
noctalia msg settings-open         # 打开设置
noctalia msg --help                # 列出全部可绑动作
```

合成器 scroll 的 deb 由 [scroll-loong64 仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64) 的 `track-scroll.sh rebuild` 单独产出，需要时**用一条命令同时装两个包**：

```bash
sudo apt install ./scroll_*.deb ./noctalia_*.deb
```

### 6.1 从旧合并包 `noctalia-desktop` 迁移

早期版本把 noctalia + scroll 打进单个 `noctalia-desktop` 包，它拥有 `/usr/local/bin/noctalia`、`/usr/local/bin/scroll*`、`/usr/local/lib/noc/` 等全部路径。两个独立 deb 装同一批路径，旧包还在时直接安装会失败：

```
正试图覆盖 /usr/local/bin/noctalia，它同时被包含于软件包 noctalia-desktop ...
```

现在两个包的 control 都带：

```
Conflicts: noctalia-desktop
Replaces: noctalia-desktop
```

`Conflicts` 让 apt 把旧包列入 REMOVED，`Replaces` 允许接管它的文件。用 `apt-get -s install ./两个.deb` 模拟，输出形如：

```
Remv noctalia-desktop [0.0~noctalia.e7c55972+scroll.00b09760-3]
Inst noctalia (...)
Inst scroll (...)
```

即**先移除旧包、再解包新包**，无需手工 purge。注意 `dpkg -i` 不自动解决冲突，会直接报 `conflicting packages - not installing`。

若 apt 因故未自动移除，手动兜底：

```bash
sudo apt purge noctalia-desktop
sudo apt install ./scroll_*.deb ./noctalia_*.deb
```

`purge` 只删包内文件：`~/.config/scroll/config`（自启、输入法环境变量都在里面）位于用户目录，**不受影响**；包内默认配置 `/usr/local/etc/scroll/config` 会由新 scroll 包重建。旧包 postrm 只跑 `ldconfig`，无破坏性动作。替换期间若正运行在 Noctalia/Scroll 会话中，装完再重新登录，别在半途重启会话。

首次运行生成默认 TOML 配置（参考仓库 `example.toml`）。随会话自启动、LightDM 会话入口、输入法配置都写在 `~/.config/scroll/config`，见 [scroll 文档](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)。

---

## 7. 快捷键

noctalia 自身不管全局快捷键——全局键属于合成器。在 `~/.config/scroll/config` 里用 `bindsym` 绑到 `noctalia msg <动作>`（`$mod` 默认 Win/Mod4）：

```ini
bindsym $mod+space   exec "noctalia msg panel-toggle launcher"
bindsym $mod+c       exec "noctalia msg panel-toggle control-center"
bindsym $mod+l       exec "noctalia msg session lock"
bindsym $mod+comma   exec "noctalia msg settings-open"
bindsym Print        exec "noctalia msg screenshot-fullscreen"
bindsym $mod+Shift+s exec "noctalia msg screenshot-region"
bindsym $mod+Shift+w exec "noctalia msg wallpaper-random"
```

无需重启会话，`scrollmsg reload` 生效。完整动作见 `noctalia msg --help`（会话 `session lock/logout/poweroff/reboot/suspend`、截图、壁纸、亮度、剪贴板等）。

> noctalia 内部窗口（launcher / 设置）的导航键在 `example.toml` 的 `[keybinds]` 段，或设置界面里录制，属于非全局键。

---

## 8. 追踪上游更新

本仓库的 `scripts/track-upstream.sh` **只管 noctalia 一个项目**（scroll 用 [另一个仓库](https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64) 的 `track-scroll.sh`，互不耦合）：

```bash
bash loong64/scripts/track-upstream.sh check     # 拉取上游，报告差异（安全，不改文件）
bash loong64/scripts/track-upstream.sh update    # 切到上游最新（detached HEAD）
bash loong64/scripts/track-upstream.sh rebuild   # 重编 + 重打 noctalia deb
bash loong64/scripts/track-upstream.sh sync      # update + rebuild
```

版本号：`0.0~noctalia.<8位上游hash>-<本地修订>`。上游 hash 变化时修订号归 1；同一 hash 下改补丁/修 bug 用 `BUILD_REV=2` 递增。

`rebuild` 自动处理：

- **幂等重打 scrollmsg 补丁**（上游仍未修 `m_msgCommand`，切上游后必重打；检测精确匹配 `m_msgCommand = "scrollmsg"`）。
- **私有运行时**：打包 gcc-14.4.0 的 libstdc++/libgcc_s/libatomic + sdbus-c++；libstdc++ 版本自动探测并排除 `-gdb.py`，并校验是真实 ELF。
- **依赖剔除**：自动去掉 `libstdc++6` / `libgcc-s1`；自动在 `$DEB_OUT` 生成 `debian/control` 后再跑 `dpkg-shlibdeps`。
- **rpath**：通过 `meson configure -Dcpp_link_args` 在链接期烤入。
- 末尾自动校验 ELF、RUNPATH 无 `/opt`、强制私有路径的 `ldd` 零缺失、源码补丁在位、`dpkg --force-conflicts -i --dry-run`。

脚本全部路径可用环境变量覆盖：`BUILD_ROOT`（默认 `$HOME/build`）、`NOCTALIA_DIR`、`GCC_DIR`、`STB_DIR`、`PKGCFG`、`SDBUS_LIB`、`DEB_OUT`、`NOCTALIA_REMOTE`（默认 `origin`）、`NOCTALIA_BRANCH`（默认 `main`）、`BUILD_REV`。

注意：`update` 后是 detached HEAD；离线时 `check` 的 fetch 失败仅警告；上游大改会触发全量重编（约 62 MB 二进制重链接比较耗时）。

---

## 附录 A：路径清单

| 路径 | 用途 |
|---|---|
| `/opt/gcc-14.4.0` | gcc-14.4.0 工具链与运行时来源 |
| `$BUILD_ROOT/noctalia` | noctalia 源码 + `build-release` |
| `$BUILD_ROOT/stb-headers/stb/stb_image_resize2.h` | 系统 libstb-dev 过旧，需补这个头 |
| `$BUILD_ROOT/deb/noctalia-root` | 打包暂存树 |
| `/usr/local/lib/noc` | 私有 gcc-14 运行时（安装后） |
| `/usr/local/lib/libsdbus-c++.so.2.3.1` | 自编译 sdbus-c++ 运行时 |
| `~/.config/scroll/config` | 会话配置：自启动、快捷键、输入法（见 [scroll 文档](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/docs/scroll-build.md)） |

## 附录 B：命令速查

```bash
# 编译
meson setup build-release --buildtype=release -Dcpp_std=c++23 -Dtests=auto -Db_lto=false --prefix /usr/local
meson configure build-release -Dcpp_link_args="-fuse-ld=lld -Wl,-rpath,/usr/local/lib/noc:/usr/local/lib"
meson compile -C build-release noctalia

# 校验
readelf -d build-release/noctalia | grep -i runpath
ldd build-release/noctalia | grep 'not found' || echo OK

# 追踪上游 / 打包
bash loong64/scripts/track-upstream.sh check
bash loong64/scripts/track-upstream.sh sync
dpkg -c noctalia_*.deb | grep -E 'lib/noc|noctalia$'

# 使用
noctalia --daemon
noctalia msg --help
scrollmsg reload
```
