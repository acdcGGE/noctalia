#!/usr/bin/env bash
#
# enable-session.sh — 让 LightDM 登录界面能看到 Scroll 会话
#
# Deepin 的 LightDM 只扫描 /usr/share/wayland-sessions，而 deb 把
# scroll.desktop 装到 /usr/local/share/wayland-sessions，需软链同步。
# 需 sudo 执行；每次重装 scroll deb 后再跑一次即可。
#
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行本脚本" >&2; exit 1; }

SCROLL_DESKTOP=/usr/local/share/wayland-sessions/scroll.desktop
NOCTALIA_DESKTOP=/usr/local/share/applications/dev.noctalia.Noctalia.desktop

[ -e "$SCROLL_DESKTOP" ] || { echo "找不到 $SCROLL_DESKTOP，先安装 scroll deb" >&2; exit 1; }

mkdir -p /usr/share/wayland-sessions
ln -sf "$SCROLL_DESKTOP" /usr/share/wayland-sessions/scroll.desktop
echo "[+] 会话入口已链接：/usr/share/wayland-sessions/scroll.desktop"

if [ -e "$NOCTALIA_DESKTOP" ]; then
  mkdir -p /usr/share/applications
  ln -sf "$NOCTALIA_DESKTOP" /usr/share/applications/
  echo "[+] 应用菜单入口已链接"
fi

echo
echo "完成。请注销回到登录界面（或 sudo systemctl restart lightdm），选择 Scroll 会话登录。"
echo "无图形登录器时可 Ctrl+Alt+F2 切 TTY 后直接运行 scroll。"
echo "注意：不要与 Deepin 自带 DDE 同时运行，两个合成器会抢显示。"
