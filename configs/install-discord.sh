#!/bin/bash
# Discord 安装脚本
# 从官方 tar.gz 包安装（仅支持 x86_64/amd64）

set -e

# 配置变量
APP_ID="discord"
INSTALL_DIR="/opt/ondemand-apps/discord"
PROGRESS_FILE="/tmp/${APP_ID}_progress"
PROGRESS_DESC_FILE="/tmp/${APP_ID}_progress.desc"
LOG="/tmp/webclaw-ondemand-${APP_ID}.log"

update_progress() { echo "$1" > "$PROGRESS_FILE" 2>/dev/null || true; }
update_progress_desc() { echo "$1" > "$PROGRESS_DESC_FILE" 2>/dev/null || true; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

update_progress 10
update_progress_desc "准备安装 Discord..."
log "开始安装 Discord"

# 检测架构
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    log "不支持的架构: $ARCH"
    log "Discord 仅支持 x86_64/amd64 架构"
    update_progress 100
    exit 1
fi

log "检测到架构: $ARCH"

update_progress 20
update_progress_desc "下载 Discord..."

# 获取最新版本下载链接
DOWNLOAD_URL="https://discord.com/api/download?platform=linux&format=tar.gz"
log "获取下载链接: $DOWNLOAD_URL"

# 获取重定向后的实际 URL
ACTUAL_URL=$(curl -sLI "$DOWNLOAD_URL" | grep -i "^location:" | tail -1 | awk '{print $2}' | tr -d '\r')

if [ -z "$ACTUAL_URL" ] || [ "$ACTUAL_URL" = "None" ]; then
    ACTUAL_URL="$DOWNLOAD_URL"
fi

log "实际下载链接: $ACTUAL_URL"

TMP_FILE="/tmp/discord.tar.gz"
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
update_progress_desc "解压 Discord..."

mkdir -p "$INSTALL_DIR"
if ! tar -xzf "$TMP_FILE" -C "$INSTALL_DIR" >> "$LOG" 2>&1; then
    log "解压失败"
    rm -f "$TMP_FILE"
    update_progress 100
    exit 1
fi

rm -f "$TMP_FILE"

update_progress 80
update_progress_desc "配置 Discord..."

# Discord tar.gz 解压后目录名是 Discord（大写 D）
BINARY_PATH="$INSTALL_DIR/Discord/discord"

# 运行 postinst.sh 脚本（如果存在）
if [ -f "$INSTALL_DIR/Discord/postinst.sh" ]; then
    log "运行 postinst.sh"
    cd "$INSTALL_DIR/Discord"
    bash postinst.sh >> "$LOG" 2>&1 || true
fi

# 复制桌面文件到系统目录
if [ -f "$INSTALL_DIR/Discord/discord.desktop" ]; then
    cp "$INSTALL_DIR/Discord/discord.desktop" /usr/share/applications/
    log "已安装桌面文件"
fi

# 复制图标到系统图标目录
if [ -f "$INSTALL_DIR/Discord/discord.png" ]; then
    mkdir -p /usr/share/icons/hicolor/256x256/apps
    cp "$INSTALL_DIR/Discord/discord.png" /usr/share/icons/hicolor/256x256/apps/discord.png
    log "已安装图标"
fi

if [ -x "$BINARY_PATH" ]; then
    log "Discord 安装成功: $BINARY_PATH"
    update_progress 100
    exit 0
else
    log "安装验证失败"
    update_progress 100
    exit 1
fi
