#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

DISABLE_ZENITY="${DISABLE_ZENITY:-0}"

if [ "$DISABLE_ZENITY" != "1" ]; then
    zenity --question \
      --title="卸载 AI CLI Studio" \
      --text="<b>确定要卸载 AI CLI Studio 吗？</b>\n\n这将删除程序文件。" \
      --ok-label="卸载" \
      --cancel-label="取消" \
      --width=400 \
      --no-wrap || exit 0
fi

do_uninstall() {
    echo "30"
    echo "# 卸载 AI CLI Studio..."

    # deb 安装方式
    if dpkg -s ai-cli-studio 2>/dev/null | grep -q "Status: install ok installed"; then
        dpkg -r ai-cli-studio || true
    fi

    # AppImage 安装方式
    rm -f /usr/bin/webcode-ai-studio
    rm -rf /opt/ai-cli-studio

    echo "70"
    echo "# 清理桌面图标..."

    rm -f /home/ubuntu/Desktop/webcode-ai-studio.desktop

    if [ -x /usr/local/bin/update-desktop-icons ]; then
        sudo -u ubuntu /usr/local/bin/update-desktop-icons || true
    fi

    echo "100"
    echo "# 卸载完成"
}

if [ "$DISABLE_ZENITY" = "1" ]; then
    do_uninstall
else
    {
        echo "10"
        echo "# 准备卸载..."
        do_uninstall
    } | zenity --progress \
      --title="卸载 AI CLI Studio" \
      --text="正在卸载..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=400

    zenity --info \
      --title="卸载完成" \
      --text="AI CLI Studio 已成功卸载。" \
      --no-wrap
fi
