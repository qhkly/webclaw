#!/bin/bash
# QQ 安装包装脚本
# 为 webclaw-app-launcher 提供进度反馈

export WEBCLAW_APP_LAUNCHER=1
export DISABLE_ZENITY=1

# 执行实际安装脚本
/opt/install-qq.sh

# 检查安装结果
if [ $? -eq 0 ]; then
    echo "95" > "/tmp/qq_progress" 2>/dev/null || true
    echo "安装完成" > "/tmp/qq_progress.desc" 2>/dev/null || true
else
    echo "100" > "/tmp/qq_progress" 2>/dev/null || true
    echo "安装失败" > "/tmp/qq_progress.desc" 2>/dev/null || true
    exit 1
fi
