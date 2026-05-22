#!/bin/bash
# webclaw-upgrader 安装 wrapper 脚本
# 设置 launcher 调用所需的环境变量，然后执行实际安装脚本
export WEBCLAW_APP_LAUNCHER=1
export DISABLE_ZENITY=1
exec /opt/install-webclaw-upgrader.sh "$@"
