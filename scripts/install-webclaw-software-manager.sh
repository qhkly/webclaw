#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ -f "/.dockerenv" ] || [ "${WEBCLAW_DOCKER_BUILD:-}" = "1" ]; then
    export WEBCLAW_DOCKER_BUILD=1
fi

# 检查是否已安装
if dpkg -s webclaw-software-manager 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[INFO] webclaw-software-manager 已安装，跳过"
    exit 0
fi

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) DEB_ARCH="amd64" ;;
    arm64) DEB_ARCH="arm64" ;;
    *)
        echo "[ERROR] 不支持的架构: $ARCH"
        exit 1
        ;;
esac

echo "[INFO] 获取 webclaw-software-manager 最新版本..."
LATEST_TAG=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
    "https://github.com/qhkly/webclaw-software-manager/releases/latest" 2>/dev/null \
    | sed 's|.*/tag/v\?||' | tr -d '\r' || echo "")
if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG=$(curl -fsSL -H "User-Agent: webclaw-software-manager/0.1" \
        "https://api.github.com/repos/qhkly/webclaw-software-manager/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "")
fi

if [ -z "$LATEST_TAG" ]; then
    echo "[ERROR] 无法获取最新版本，请检查网络连接"
    exit 1
fi
echo "[INFO] 安装 webclaw-software-manager v${LATEST_TAG} (${ARCH})"

# Tauri 打包产物文件名格式：Webclaw.Software.Manager_VERSION_ARCH.deb
DEB_NAME="Webclaw.Software.Manager_${LATEST_TAG}_${DEB_ARCH}.deb"
DOWNLOAD_URL="https://github.com/qhkly/webclaw-software-manager/releases/download/v${LATEST_TAG}/${DEB_NAME}"
echo "[INFO] 下载: ${DOWNLOAD_URL}"

TMP_DIR=$(mktemp -d)
curl -fsSL --progress-bar -L "$DOWNLOAD_URL" -o "${TMP_DIR}/webclaw-software-manager.deb"

echo "[INFO] 安装 deb 包..."
dpkg -i "${TMP_DIR}/webclaw-software-manager.deb" || apt-get install -fy

mkdir -p /opt/on-demand-icons
# 优先使用最大分辨率图标（sort -rV 让 512x512 排在 128x128 前面）；
# 仅当找到的图标比已有的更大时才覆盖，保留 Dockerfile 预置的 512x512。
ICON_SRC=$(find /usr/share/icons /usr/share/pixmaps -name "webclaw-software-manager.png" 2>/dev/null | sort -rV | head -1)
if [ -n "$ICON_SRC" ]; then
    SRC_SIZE=$(file "$ICON_SRC" | grep -o '[0-9]* x [0-9]*' | awk '{print $1}' || echo 0)
    DST_SIZE=$(file /opt/on-demand-icons/webclaw-software-manager.png 2>/dev/null | grep -o '[0-9]* x [0-9]*' | awk '{print $1}' || echo 0)
    [ "$SRC_SIZE" -gt "$DST_SIZE" ] 2>/dev/null && cp "$ICON_SRC" /opt/on-demand-icons/webclaw-software-manager.png || true
fi

rm -rf "$TMP_DIR"

# 确保缓存目录属于 ubuntu，避免首次写入时权限报错
mkdir -p /home/ubuntu/.local/share/webclaw-software-manager
chown -R ubuntu:ubuntu /home/ubuntu/.local/share/webclaw-software-manager

echo "[INFO] webclaw-software-manager 安装完成"
