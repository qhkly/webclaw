#!/usr/bin/env bash
set -euo pipefail

# webclaw-upgrader 卸载脚本
# 配套 https://github.com/land007/webclaw-upgrader
#
# 环境变量:
#   DISABLE_ZENITY=1  禁用所有 zenity 对话框（由 webclaw-app-uninstaller 调用时设置）

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

# 检查是否已安装
if ! dpkg -s webclaw-upgrader 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[INFO] webclaw-upgrader 未安装，无需卸载"
    exit 0
fi

if [ "${DISABLE_ZENITY:-}" != "1" ]; then
    zenity --question \
      --title="卸载 WebClaw Upgrader" \
      --text="<b>确定要卸载 WebClaw Upgrader 吗？</b>\n\n这将：\n• 移除 webclaw-upgrader 程序\n• 移除 sudoers 权限片段\n\n卸载后可重新点击桌面图标安装。" \
      --ok-label="卸载" \
      --cancel-label="取消" \
      --width=400 \
      --no-wrap || exit 0
fi

do_uninstall() {
    echo "[INFO] 停止 webclaw-upgrader 进程..."
    pkill -f "webclaw-upgrader" 2>/dev/null || true

    echo "[INFO] 移除软件包..."
    apt-get remove -y webclaw-upgrader 2>/dev/null || dpkg -r webclaw-upgrader 2>/dev/null || true

    echo "[INFO] 移除 sudoers 权限片段..."
    rm -f /etc/sudoers.d/webclaw-upgrader

    echo "[INFO] webclaw-upgrader 卸载完成"
}

if [ "${DISABLE_ZENITY:-}" = "1" ]; then
    do_uninstall
else
    {
        echo "20"
        echo "# 停止进程..."
        do_uninstall
        echo "100"
        echo "# 卸载完成！"
    } | zenity --progress \
      --title="卸载 WebClaw Upgrader" \
      --text="正在卸载..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=400

    zenity --info \
      --title="卸载完成" \
      --text="WebClaw Upgrader 已成功卸载。\n\n点击桌面图标可重新安装。" \
      --no-wrap
fi
