#!/bin/bash
# QQ 卸载脚本

set -e

LOG="/tmp/webclaw-ondemand-qq.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log "开始卸载 QQ"

# 卸载 QQ 包
if dpkg -s linuxqq >/dev/null 2>&1; then
    log "移除 linuxqq 包"
    apt-get remove -y linuxqq >> "$LOG" 2>&1 || true
fi

# 清理残留文件
log "清理残留文件"
rm -rf /opt/QQ >> "$LOG" 2>&1 || true
rm -f /usr/bin/linuxqq-electron >> "$LOG" 2>&1 || true
rm -f /usr/share/applications/qq.desktop >> "$LOG" 2>&1 || true

log "QQ 卸载完成"
exit 0
