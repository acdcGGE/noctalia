#!/usr/bin/env bash
#
# track-upstream.sh — 追踪 noctalia 上游更新，并重编重打包为独立 deb
# 平台：Deepin 25 / loong64 (LoongArch)，工具链 gcc-14.4.0
#
# 只管 noctalia 一个项目。合成器 scroll 的编译/打包/追上游在另一个仓库：
#   https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64
#   （用它的 scripts/track-scroll.sh）
#
# 子命令：
#   check    拉取上游、报告当前/上游 commit 与新提交数（不改任何文件，安全）
#   update   将 noctalia 切到上游最新（detached HEAD，强制覆盖本地改动）
#   rebuild  重编 + 重新打包 noctalia deb（自动重打 scrollmsg / LoongArch
#            CPU 型号补丁、打包私有运行时、剔除 gcc-14 依赖）
#   sync     update + rebuild 一步到位
#
# 默认（无参数）等同 check。
#
# 所有路径都可用环境变量覆盖，便于换机复用：
#   BUILD_ROOT      构建根目录              默认 $HOME/build
#   NOCTALIA_DIR    noctalia 源码目录       默认 $BUILD_ROOT/noctalia
#   GCC_DIR         gcc-14.4.0 安装前缀    默认 /opt/gcc-14.4.0
#   STB_DIR         stb 头目录（内含 stb/stb_image_resize2.h）
#   PKGCFG          sdbus-c++.pc 所在目录
#   SDBUS_LIB       sdbus-c++ 运行时 .so
#   DEB_OUT         deb 输出 / 暂存目录
#   NOCTALIA_REMOTE 追踪的远端名            默认 origin
#   NOCTALIA_BRANCH 上游分支名              默认 main
#   BUILD_REV       本地修订号              默认 1
#   PATCH_DIR       loong64 补丁目录        默认 脚本同级的 ../patches
#
set -euo pipefail

# ---------------- 配置 ----------------
BUILD_ROOT=${BUILD_ROOT:-"$HOME/build"}
NOCTALIA_DIR=${NOCTALIA_DIR:-"$BUILD_ROOT/noctalia"}
GCC_DIR=${GCC_DIR:-/opt/gcc-14.4.0}
STB_DIR=${STB_DIR:-"$BUILD_ROOT/stb-headers"}
PKGCFG=${PKGCFG:-/usr/local/lib/pkgconfig}
SDBUS_LIB=${SDBUS_LIB:-/usr/local/lib/libsdbus-c++.so.2.3.1}
DEB_OUT=${DEB_OUT:-"$BUILD_ROOT/deb"}
NOCTALIA_REMOTE=${NOCTALIA_REMOTE:-origin}
NOCTALIA_BRANCH=${NOCTALIA_BRANCH:-main}
BUILD_REV=${BUILD_REV:-1}   # 同一上游 hash 下的本地构建序号（换 hash 后从 1 重新计）
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR=${PATCH_DIR:-"$SCRIPT_DIR/../patches"}

# ---------------- 颜色 ----------------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_RST=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_RST=; fi
info(){ echo "${C_B}[*]${C_RST} $*"; }
ok(){ echo "${C_G}[+]${C_RST} $*"; }
warn(){ echo "${C_Y}[!]${C_RST} $*"; }
err(){ echo "${C_R}[x]${C_RST} $*" >&2; }

# ---------------- 前置检查 ----------------
check_prereqs(){
  local miss=0
  for cmd in meson ninja dpkg-deb dpkg-shlibdeps git python3; do
    command -v "$cmd" >/dev/null 2>&1 || { err "缺少命令: $cmd"; miss=1; }
  done
  # gcc-14.4.0 原生提供 <print> 与 std::ranges::to；stb-headers 下只需
  # stb/stb_image_resize2.h（系统 libstb-dev 过旧）。
  for p in "$GCC_DIR/bin/g++" "$STB_DIR/stb/stb_image_resize2.h" \
           "$PKGCFG/sdbus-c++.pc" "$SDBUS_LIB"; do
    [ -e "$p" ] || { err "缺失: $p"; miss=1; }
  done
  [ -d "$NOCTALIA_DIR/build-release" ] || {
    err "缺失构建目录: $NOCTALIA_DIR/build-release（先按 docs/noctalia-build.md §3 完成首次 setup）"
    miss=1
  }
  [ "$miss" -eq 0 ] || { err "前置检查未通过，先完成工具链/依赖准备（见 docs/noctalia-build.md §1–§2）"; return 1; }
  ok "前置检查通过"
}

# ---------------- check ----------------
cmd_check(){
  info "检查 noctalia ($NOCTALIA_REMOTE/$NOCTALIA_BRANCH)"
  git -C "$NOCTALIA_DIR" fetch -q "$NOCTALIA_REMOTE" 2>/dev/null \
    || warn "fetch 失败（可能离线，沿用旧数据）"
  local cur up count
  cur=$(git -C "$NOCTALIA_DIR" rev-parse --short=8 HEAD)
  up=$(git -C "$NOCTALIA_DIR" rev-parse --short=8 "$NOCTALIA_REMOTE/$NOCTALIA_BRANCH" 2>/dev/null || echo "??")
  count=$(git -C "$NOCTALIA_DIR" rev-list --count "HEAD..$NOCTALIA_REMOTE/$NOCTALIA_BRANCH" 2>/dev/null || echo "?")
  echo "  noctalia: cur=$cur  upstream=$up  new_commits=$count"
  if [ "$count" != "?" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    warn "有 $count 个新提交（建议版本 0.0~noctalia.$up-$BUILD_REV）"
    git -C "$NOCTALIA_DIR" log --oneline -8 "HEAD..$NOCTALIA_REMOTE/$NOCTALIA_BRANCH" | sed 's/^/      /'
  elif [ "$count" = "?" ]; then
    warn "无法比较（检查 NOCTALIA_REMOTE / NOCTALIA_BRANCH）"
  else
    ok "已是最新（cur=$cur）"
  fi
}

# ---------------- 幂等重打 scrollmsg 修复 ----------------
# noctalia 的 sway 后端 m_msgCommand 只认 swaymsg/i3-msg，漏了 scrollmsg，
# 导致注销/键盘布局等 IPC 失效。上游只在 m_outputCommand 块加了 scrollmsg，
# m_msgCommand（用于 exit 注销）仍未修，所以此补丁每次切上游后都必须重打。
# 检测必须精确匹配 m_msgCommand = "scrollmsg"，否则会被 outputCommand 里的
# scrollmsg 误触发而跳过补丁。
apply_scrollmsg_fix(){
  local f="$NOCTALIA_DIR/src/compositors/sway/sway_runtime.cpp"
  if grep -q 'm_msgCommand = "scrollmsg"' "$f"; then
    ok "scrollmsg 修复已存在（m_msgCommand 块），跳过"
    return 0
  fi
  warn "重新应用 scrollmsg 修复…"
  python3 - "$f" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
old = ('    if (process::commandExists("swaymsg")) {\n'
       '      m_msgCommand = "swaymsg";\n'
       '    } else if (process::commandExists("i3-msg")) {')
new = ('    if (process::commandExists("scrollmsg")) {\n'
       '      m_msgCommand = "scrollmsg";\n'
       '    } else if (process::commandExists("swaymsg")) {\n'
       '      m_msgCommand = "swaymsg";\n'
       '    } else if (process::commandExists("i3-msg")) {')
if old in s:
    s = s.replace(old, new, 1)
    open(f, 'w').write(s)
    print("applied scrollmsg fix")
else:
    print("WARN: 无法定位插入点，请手动检查 resolveCommands() 或用 patches/ 里的补丁")
PY
}

# ---------------- 幂等重打 LoongArch CPU 型号识别补丁 ----------------
# 上游 readCpuModel() 只认 x86 的小写 "model name" 前缀；LoongArch 内核输出
# "Model Name\t\t: Loongson-3A5000"，于是控制中心显示「未知 CPU」。补丁把键名
# 归一化后按优先级匹配多种架构字段。切上游会重置源码，所以每次 rebuild 都要重打。
apply_cpu_model_fix(){
  local f="$NOCTALIA_DIR/src/system/hardware_info.cpp"
  local p="$PATCH_DIR/cpu-model-loongarch.patch"
  if grep -q 'cpuInfoKeyRank' "$f"; then
    ok "LoongArch CPU 型号识别补丁已存在，跳过"
    return 0
  fi
  [ -f "$p" ] || { err "缺少补丁: $p"; return 1; }
  warn "重新应用 LoongArch CPU 型号识别补丁…"
  ( cd "$NOCTALIA_DIR" && git apply --check "$p" && git apply "$p" ) || {
    err "CPU 型号补丁应用失败（上游可能改过 hardware_info.cpp），请手动合并 $p"
    return 1
  }
  grep -q 'cpuInfoKeyRank' "$f" || { err "CPU 型号补丁应用后校验失败"; return 1; }
  ok "CPU 型号补丁已应用"
}

# ---------------- 切到上游最新 ----------------
cmd_update(){
  info "将 noctalia 切到 $NOCTALIA_REMOTE/$NOCTALIA_BRANCH 最新（detached HEAD，强制覆盖本地改动）"
  git -C "$NOCTALIA_DIR" checkout -f -q "$NOCTALIA_REMOTE/$NOCTALIA_BRANCH"
  cmd_check
}

# ---------------- 重编 + 重打包 ----------------
cmd_rebuild(){
  check_prereqs
  local rev=$BUILD_REV

  # ===== 编译 =====
  info "重编 noctalia（gcc-14.4.0）"
  apply_scrollmsg_fix
  apply_cpu_model_fix
  ( cd "$NOCTALIA_DIR"
    export CC="$GCC_DIR/bin/gcc" CXX="$GCC_DIR/bin/g++"
    export PKG_CONFIG_PATH="$PKGCFG"
    export CFLAGS="-I$STB_DIR" CXXFLAGS="-I$STB_DIR"
    export LDFLAGS="-fuse-ld=lld -Wl,-rpath,/usr/local/lib/noc:/usr/local/lib"
    meson configure build-release \
      -Dcpp_link_args="-fuse-ld=lld -Wl,-rpath,/usr/local/lib/noc:/usr/local/lib" >/dev/null
    meson compile -C build-release noctalia 2>&1 | tail -5
  )
  local noc_hash
  noc_hash=$(git -C "$NOCTALIA_DIR" rev-parse --short=8 HEAD)

  # ===== 暂存树 =====
  info "meson install 暂存到 $DEB_OUT/noctalia-root"
  rm -rf "$DEB_OUT/noctalia-root"
  mkdir -p "$DEB_OUT/noctalia-root" "$DEB_OUT/debian"
  meson install -C "$NOCTALIA_DIR/build-release" \
    --destdir "$DEB_OUT/noctalia-root" --no-rebuild >/dev/null

  # ===== 私有运行时：noc (gcc-14.4.0) + sdbus-c++ =====
  local root="$DEB_OUT/noctalia-root"
  local noc="$root/usr/local/lib/noc"
  mkdir -p "$noc"
  local stdc
  # 注意：libstdc++.so.6.0.* 会同时匹配到 libstdc++.so.6.0.NN-gdb.py（2KB 文本
  # 辅助文件），必须排除 .py/.la/.a，否则可能选中"假"库，打包后 noctalia
  # 会因 CXXABI_1.3.15 not found 无法启动。
  stdc=$(for f in "$GCC_DIR"/lib/libstdc++.so.6.0.*; do
           case "$f" in *.py|*.la|*.a) continue;; esac
           [ -f "$f" ] && echo "$f"
         done | sort -V | tail -1)
  [ -n "$stdc" ] || { err "找不到 $GCC_DIR/lib/libstdc++.so.6.0.*"; return 1; }
  if ! file -b "$stdc" | grep -q ELF; then
    err "选中的 libstdc++ 不是 ELF: $stdc"
    return 1
  fi
  cp -a "$stdc" "$noc/libstdc++.so.6"
  cp -a "$GCC_DIR/lib/libgcc_s.so.1"      "$noc/"
  cp -a "$GCC_DIR/lib/libatomic.so.1.2.0" "$noc/libatomic.so.1"
  cp -a "$SDBUS_LIB" "$root/usr/local/lib/"
  # 由 libsdbus-c++.so.2.3.1 推出 SONAME 软链(libsdbus-c++.so.2)
  # 与开发软链(libsdbus-c++.so)。sed 输出完整文件名，直接用作链接名。
  local sdbus_base sdbus_soname sdbus_dev
  sdbus_base=$(basename "$SDBUS_LIB")
  sdbus_soname=$(printf '%s' "$sdbus_base" | sed -E 's/(\.so\.[0-9]+).*/\1/')
  sdbus_dev=$(printf '%s' "$sdbus_base" | sed -E 's/(\.so)\..*/\1/')
  ln -sf "$sdbus_base" "$root/usr/local/lib/$sdbus_soname"
  ln -sf "$sdbus_base" "$root/usr/local/lib/$sdbus_dev"
  ok "私有运行时已暂存: $(du -h "$noc/libstdc++.so.6" | cut -f1) libstdc++ + sdbus"

  # ===== 依赖推导 =====
  # dpkg-shlibdeps 必须在含 debian/control 的目录下运行，否则报
  # "cannot read debian/control" (exit 25)。stderr 单独留档、失败立即打印，
  # 不要静默吞掉 —— 之前就因静默中断而「编译完了却没产出 deb」。
  cat > "$DEB_OUT/debian/control" <<'EOF'
Source: noctalia-loong64
Section: x11
Priority: optional
Maintainer: local-build <local@build>

Package: noctalia
Architecture: loong64
Description: Noctalia desktop shell (C++23)
EOF
  local deps_file="$DEB_OUT/noc-deps.txt"
  local shlib_err="$DEB_OUT/noc-shlib-err.txt"
  if ! ( cd "$DEB_OUT"
         dpkg-shlibdeps --ignore-missing-info -O \
           -e noctalia-root/usr/local/bin/noctalia > "$deps_file" 2> "$shlib_err" ); then
    err "dpkg-shlibdeps 失败："
    cat "$shlib_err" >&2
    return 1
  fi
  # noctalia 的 Depends 必须剔除 gcc-14 运行时项（已私有打包），否则
  # 系统只有 gcc-12 的 libstdc++6，dpkg -i 会直接拒装。
  # 按逗号切分后逐项过滤，避免用 sed 直接删中间项时把逗号后的空格也吃掉
  # （会出现 ",libgles2" 这类虽可解析但不规范的分隔）。
  local noc_deps
  noc_deps=$(sed -n 's/^shlibs:Depends=//p' "$deps_file" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -vE '^(libgcc-s1|libstdc\+\+6)([[:space:]]|$)' \
    | grep -v '^$' \
    | paste -sd, - | sed 's/,/, /g')
  [ -n "$noc_deps" ] || { err "依赖推导结果为空，请检查 $deps_file"; return 1; }
  ok "依赖（已剔除私有运行时）: $noc_deps"

  # ===== control + 钩子 =====
  mkdir -p "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<EOF
Package: noctalia
Version: 0.0~noctalia.$noc_hash-$rev
Section: x11
Priority: optional
Architecture: loong64
Depends: $noc_deps
Recommends: scroll
Conflicts: noctalia-desktop
Replaces: noctalia-desktop
Maintainer: local-build <local@build>
Description: Noctalia - C++23 desktop shell for Wayland (self-built)
 Desktop shell layer (bar, dock, launcher, notifications, control center)
 built against gcc-14.4.0. The gcc-14.4.0 runtime (libstdc++, libgcc_s,
 libatomic) is privately bundled under /usr/local/lib/noc, and the sdbus-c++
 runtime is bundled under /usr/local/lib, so no system gcc-14 is required.
 Requires a Wayland compositor (e.g. the scroll package).
EOF
  cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in configure|abort-upgrade) ldconfig ;; esac
EOF
  cat > "$root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in remove|purge) ldconfig ;; esac
EOF
  chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

  # ===== 封包 =====
  local noc_deb="$DEB_OUT/noctalia_0.0~noctalia.${noc_hash}-${rev}_loong64.deb"
  dpkg-deb --build --root-owner-group "$root" "$noc_deb"
  ok "打包完成: $noc_deb ($(du -h "$noc_deb" | cut -f1))"

  # ===== 校验 =====
  local bin="$root/usr/local/bin/noctalia"
  info "校验 1: 私有 libstdc++ 是真实 ELF"
  file -b "$noc/libstdc++.so.6" | grep -q ELF || { err "libstdc++ 不是 ELF"; return 1; }
  ok "OK: $(du -h "$noc/libstdc++.so.6" | cut -f1) ELF"
  info "校验 2: RUNPATH（应为 /usr/local/lib/noc:/usr/local/lib，无 /opt）"
  local rpath
  rpath=$(readelf -d "$bin" | grep -i runpath || true)
  echo "  $rpath"
  if printf '%s' "$rpath" | grep -q '/opt/'; then
    err "RUNPATH 含 /opt 硬编码路径"; return 1
  fi
  info "校验 3: ldd（强制私有路径，排除双装载假象）"
  if LD_LIBRARY_PATH="$noc:$root/usr/local/lib" ldd "$bin" 2>&1 | grep -q 'not found'; then
    LD_LIBRARY_PATH="$noc:$root/usr/local/lib" ldd "$bin" 2>&1 | grep 'not found' >&2
    err "有未解析的动态库"; return 1
  fi
  ok "OK: 零 not found"
  info "校验 4: 源码补丁在位（scrollmsg 注销 + LoongArch CPU 型号）"
  grep -q 'm_msgCommand = "scrollmsg"' \
    "$NOCTALIA_DIR/src/compositors/sway/sway_runtime.cpp" \
    && ok "OK: scrollmsg 补丁" || { err "scrollmsg 补丁丢失"; return 1; }
  grep -q 'cpuInfoKeyRank' "$NOCTALIA_DIR/src/system/hardware_info.cpp" \
    && ok "OK: CPU 型号补丁" || { err "CPU 型号补丁丢失"; return 1; }
  info "校验 5: dpkg --force-conflicts -i --dry-run（忽略与旧合并包的预期冲突）"
  dpkg --force-conflicts -i --dry-run "$noc_deb" 2>&1 | tail -4 || warn "dry-run 报告依赖未满足，请用 sudo apt install 补齐"

  echo
  info "安装: sudo apt install ./$(basename "$noc_deb")"
  info "      apt 会自动移除旧合并包 noctalia-desktop；请勿用 dpkg -i"
  info "本脚本不产出 scroll deb；请用 scroll-loong64 仓库的 scripts/track-scroll.sh"
}

cmd_sync(){ cmd_update; cmd_rebuild; }

usage(){
  cat <<'USG'
用法: track-upstream.sh [check|update|rebuild|sync]

  check    拉取上游并报告 noctalia 差异（默认，安全不改文件）
  update   将 noctalia 切到上游最新 commit
  rebuild  重编并重新打包 noctalia deb（自动重打 scrollmsg / LoongArch
           CPU 型号补丁、打包 noc/sdbus 运行时、剔除 gcc-14 依赖、
           按上游 hash 升版本号）
  sync     update + rebuild 一步到位

只产出 noctalia deb。scroll 的编译/打包请用 scroll-loong64 仓库的
track-scroll.sh：https://github.com/acdcGGE/scroll-loong64/tree/loong64/loong64

版本号策略: 0.0~noctalia.<8位上游hash>-<本地修订>
  - 上游 hash 变化 → 本地修订从 1 重新计数
  - 同一 hash 多次本地修订（如修 bug）→ 递增 2/3/…

环境变量: BUILD_ROOT NOCTALIA_DIR GCC_DIR STB_DIR PKGCFG SDBUS_LIB
          DEB_OUT NOCTALIA_REMOTE NOCTALIA_BRANCH BUILD_REV PATCH_DIR
USG
}

case "${1:-check}" in
  check)   cmd_check ;;
  update)  cmd_update ;;
  rebuild) cmd_rebuild ;;
  sync)    cmd_sync ;;
  -h|--help|help) usage ;;
  *) err "未知子命令: $1"; usage; exit 1 ;;
esac
