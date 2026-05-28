#!/bin/bash
# Telegram Desktop 安装脚本
# 下载官方 tar.xz 包并解压到指定目录

set -e

# 配置变量
APP_ID="telegram"
PKG_NAME="telegram"
INSTALL_DIR="/opt/ondemand-apps/telegram"
PROGRESS_FILE="/tmp/${APP_ID}_progress"
PROGRESS_DESC_FILE="/tmp/${APP_ID}_progress.desc"
LOG="/tmp/webclaw-ondemand-${APP_ID}.log"

# 更新进度函数
update_progress() {
    echo "$1" > "$PROGRESS_FILE" 2>/dev/null || true
}

# 更新进度描述
update_progress_desc() {
    echo "$1" > "$PROGRESS_DESC_FILE" 2>/dev/null || true
}

# 记录日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

update_progress 10
update_progress_desc "准备安装 Telegram..."

log "开始安装 Telegram Desktop"

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="x64"
        ;;
    aarch64)
        ARCH_SUFFIX="arm64"
        ;;
    *)
        log "不支持的架构: $ARCH"
        update_progress 100
        exit 1
        ;;
esac

log "检测到架构: $ARCH ($ARCH_SUFFIX)"

update_progress 20
update_progress_desc "下载 Telegram..."

# 获取最新版本下载链接
DOWNLOAD_BASE_URL="https://telegram.org/dl/desktop/linux"
log "获取下载链接: $DOWNLOAD_BASE_URL"

# 获取重定向后的实际 URL
ACTUAL_URL=$(curl -sLI "$DOWNLOAD_BASE_URL" | grep -i "^location:" | tail -1 | awk '{print $2}' | tr -d '\r')

if [ -z "$ACTUAL_URL" ] || [ "$ACTUAL_URL" = "None" ]; then
    log "无法获取下载链接"
    ACTUAL_URL="$DOWNLOAD_BASE_URL"
fi

log "实际下载链接: $ACTUAL_URL"

# 下载 tar.xz 包
TMP_FILE="/tmp/telegram.tar.xz"
if ! curl -fsSL -m 300 "$ACTUAL_URL" -o "$TMP_FILE" >> "$LOG" 2>&1; then
    log "下载失败: $ACTUAL_URL"
    update_progress 100
    exit 1
fi

# 检查文件是否有效
if [ ! -s "$TMP_FILE" ]; then
    log "下载的文件为空或无效"
    update_progress 100
    rm -f "$TMP_FILE"
    exit 1
fi

log "下载完成，文件大小: $(stat -c%s "$TMP_FILE" 2>/dev/null || stat -f%z "$TMP_FILE" 2>/dev/null) bytes"

update_progress 50
update_progress_desc "解压 Telegram..."

# 创建安装目录
mkdir -p "$INSTALL_DIR"

# 解压 tar.xz 包
if ! tar -xJf "$TMP_FILE" -C "$INSTALL_DIR" >> "$LOG" 2>&1; then
    log "解压失败"
    rm -f "$TMP_FILE"
    update_progress 100
    exit 1
fi

# 清理临时文件
rm -f "$TMP_FILE"

update_progress 80
update_progress_desc "配置 Telegram..."

# 检查解压后的内容
log "解压后的内容:"
ls -la "$INSTALL_DIR" >> "$LOG" 2>&1

# Telegram tar.xz 解压后通常在 Telegram 子目录中
# 可能的路径：/opt/ondemand-apps/telegram/Telegram/Telegram
BINARY_PATH="$INSTALL_DIR/Telegram/Telegram"

if [ -x "$BINARY_PATH" ]; then
    log "Telegram 安装成功: $BINARY_PATH"
    update_progress 100
    exit 0
else
    log "安装验证失败，查找可执行文件..."
    TELEGRAM_BIN=$(find "$INSTALL_DIR" -name "Telegram" -executable 2>/dev/null | head -1 || true)
    if [ -n "$TELEGRAM_BIN" ]; then
        log "找到 Telegram 可执行文件: $TELEGRAM_BIN"
        update_progress 100
        exit 0
    fi
    log "安装验证失败"
    update_progress 100
    exit 1
fi
