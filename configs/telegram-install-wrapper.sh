#!/bin/bash
# Telegram Desktop 安装包装脚本
# 提供进度反馈和用户交互

set -e

APP_ID="telegram"
SCRIPT_DIR="/opt"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-${APP_ID}.sh"
PROGRESS_FILE="/tmp/${APP_ID}_progress"
PROGRESS_DESC_FILE="/tmp/${APP_ID}_progress.desc"

# 初始化进度
echo "0" > "$PROGRESS_FILE"
echo "准备安装..." > "$PROGRESS_DESC_FILE"

# 显示确认对话框（如果可用）
if command -v zenity >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
    zenity --question \
        --title="安装 Telegram Desktop" \
        --text="Telegram Desktop 是一款注重速度和安全的即时通讯应用。\n\n是否继续安装？" \
        --width=400 \
        --icon-name="telegram-desktop" \
        2>/dev/null || {
        # 用户取消
        echo "用户取消安装"
        exit 1
    }
fi

# 执行安装脚本
exec bash "$INSTALL_SCRIPT"
