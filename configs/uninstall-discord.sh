#!/bin/bash
# Discord 卸载脚本

set -e

APP_ID="discord"
INSTALL_DIR="/opt/ondemand-apps/discord"
LOG="/tmp/webclaw-ondemand-${APP_ID}-uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log "开始卸载 Discord"

# 删除安装目录
if [ -d "$INSTALL_DIR" ]; then
    log "删除安装目录: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    log "安装目录不存在: $INSTALL_DIR"
fi

# 清理桌面快捷方式
rm -f /home/ubuntu/Desktop/discord.desktop 2>/dev/null || true

# 清理系统桌面文件和图标
rm -f /usr/share/applications/discord.desktop 2>/dev/null || true
rm -f /usr/share/icons/hicolor/*/apps/discord.png 2>/dev/null || true

log "Discord 卸载完成"
exit 0
