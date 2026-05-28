#!/bin/bash
# Telegram Desktop 卸载脚本

set -e

APP_ID="telegram"
INSTALL_DIR="/opt/ondemand-apps/telegram"
LOG="/tmp/webclaw-ondemand-${APP_ID}-uninstall.log"

# 记录日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log "开始卸载 Telegram Desktop"

# 删除安装目录
if [ -d "$INSTALL_DIR" ]; then
    log "删除安装目录: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    log "安装目录不存在: $INSTALL_DIR"
fi

# 清理桌面快捷方式
rm -f /home/ubuntu/Desktop/telegram.desktop 2>/dev/null || true

log "Telegram Desktop 卸载完成"
exit 0
