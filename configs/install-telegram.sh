#!/bin/bash
# Telegram Desktop 安装脚本
# 从官方 tar.xz 包安装（仅支持 x86_64/amd64）

set -e

# 配置变量
APP_ID="telegram"
INSTALL_DIR="/opt/ondemand-apps/telegram"
PROGRESS_FILE="/tmp/${APP_ID}_progress"
PROGRESS_DESC_FILE="/tmp/${APP_ID}_progress.desc"
LOG="/tmp/webclaw-ondemand-${APP_ID}.log"

update_progress() { echo "$1" > "$PROGRESS_FILE" 2>/dev/null || true; }
update_progress_desc() { echo "$1" > "$PROGRESS_DESC_FILE" 2>/dev/null || true; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

update_progress 10
update_progress_desc "准备安装 Telegram..."
log "开始安装 Telegram Desktop"

# 检测架构
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    log "不支持的架构: $ARCH"
    log "Telegram Desktop 仅支持 x86_64/amd64 架构"
    log "ARM64 用户请使用: flatpak install flathub org.telegram.desktop"
    update_progress 100
    exit 1
fi

log "检测到架构: $ARCH"

update_progress 20
update_progress_desc "下载 Telegram..."

DOWNLOAD_URL="https://telegram.org/dl/desktop/linux"
ACTUAL_URL=$(curl -sLI "$DOWNLOAD_URL" | grep -i "^location:" | tail -1 | awk '{print $2}' | tr -d '\r')

if [ -z "$ACTUAL_URL" ] || [ "$ACTUAL_URL" = "None" ]; then
    ACTUAL_URL="$DOWNLOAD_URL"
fi

log "下载链接: $ACTUAL_URL"

TMP_FILE="/tmp/telegram.tar.xz"
if ! curl -fsSL -m 300 "$ACTUAL_URL" -o "$TMP_FILE" >> "$LOG" 2>&1; then
    log "下载失败"
    update_progress 100
    exit 1
fi

if [ ! -s "$TMP_FILE" ]; then
    log "下载的文件为空"
    update_progress 100
    rm -f "$TMP_FILE"
    exit 1
fi

log "下载完成，文件大小: $(stat -c%s "$TMP_FILE" 2>/dev/null || stat -f%z "$TMP_FILE" 2>/dev/null) bytes"

update_progress 50
update_progress_desc "解压 Telegram..."

mkdir -p "$INSTALL_DIR"
if ! tar -xJf "$TMP_FILE" -C "$INSTALL_DIR" >> "$LOG" 2>&1; then
    log "解压失败"
    rm -f "$TMP_FILE"
    update_progress 100
    exit 1
fi

rm -f "$TMP_FILE"

update_progress 80
update_progress_desc "配置 Telegram..."

BINARY_PATH="$INSTALL_DIR/Telegram/Telegram"
if [ -x "$BINARY_PATH" ]; then
    log "Telegram 安装成功: $BINARY_PATH"
    update_progress 100
    exit 0
else
    log "安装验证失败"
    update_progress 100
    exit 1
fi
