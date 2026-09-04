#!/usr/bin/env bash
set -euo pipefail

# webcode-studiod（AI Studio 无头节点）安装脚本
# 配套 https://github.com/qhkly/webcode-ai-studio
#
# 和 install-webcode-ai-studio.sh 的区别：那个装的是**有头**的 AppImage，只有桌面版
# 用得上，还要 X 和 WebKitGTK；这个装的是同一个发布包里并排放着的无头二进制，
# 不链接 tauri、没有任何 GUI 依赖，所以 lite / 桌面 / full 三种镜像都能跑。
# 两者同源同版本，走的是同一个 R2 发布路径。
#
# 环境变量:
#   WEBCODE_STUDIOD_VERSION  版本号，默认 latest（从 latest.json 取）
#
# 注意：v0.1.66 之前的发布包里**没有**这个二进制（它是随 webcode-core 拆分
# 一起进来的）。装不到时这个脚本会直接失败，不会留下一个半装好的镜像。

R2_BASE="https://launcher.qhkly.com"
PRODUCT_PATH="launcher/webcode-ai-studio"
INSTALL_PATH="/usr/local/bin/webcode-studiod"

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) ZIP_ARCH="x64" ;;
    arm64) ZIP_ARCH="arm64" ;;
    *)
        echo "[ERROR] 不支持的架构: $ARCH" >&2
        exit 1
        ;;
esac

VER="${WEBCODE_STUDIOD_VERSION:-latest}"
if [ "$VER" = "latest" ]; then
    echo "[INFO] 获取最新版本信息..."
    METADATA=$(curl -fsSL "${R2_BASE}/${PRODUCT_PATH}/latest.json")
    VER=$(echo "$METADATA" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    if [ -z "$VER" ]; then
        VER=$(echo "$METADATA" | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    fi
    if [ -z "$VER" ]; then
        echo "[ERROR] 无法从 latest.json 解析版本号" >&2
        exit 1
    fi
fi
VER="${VER#v}"

ZIP_URL="${R2_BASE}/${PRODUCT_PATH}/versions/v${VER}/webcode-ai-studio-linux-${ZIP_ARCH}.zip"
echo "[INFO] 安装 webcode-studiod v${VER} (${ARCH}) <- ${ZIP_URL}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$ZIP_URL" -o "${TMP_DIR}/studio.zip"

# 只取无头二进制。同一个 zip 里还躺着 100+ MB 的 AppImage/deb，那是给桌面版
# 按需安装用的（install-webcode-ai-studio.sh），不进这一层。
unzip -q -o -j "${TMP_DIR}/studio.zip" "webcode-studiod" -d "$TMP_DIR" || true

if [ ! -f "${TMP_DIR}/webcode-studiod" ]; then
    echo "[ERROR] 发布包 v${VER} 里没有 webcode-studiod。" >&2
    echo "        它从 v0.1.66 起才随包发布；请指定 WEBCODE_STUDIOD_VERSION 到更新的版本。" >&2
    echo "[DEBUG] 包内文件：" >&2
    unzip -l "${TMP_DIR}/studio.zip" >&2 || true
    exit 1
fi

install -m 0755 "${TMP_DIR}/webcode-studiod" "$INSTALL_PATH"

# 装完当场验一下：架构装错（比如 arm64 机器上拿了 x64 包）在这里就该炸，
# 而不是等到容器起来 supervisor 反复重启才被发现。
if ! file "$INSTALL_PATH" | grep -q "ELF"; then
    echo "[ERROR] ${INSTALL_PATH} 不是 ELF 可执行文件" >&2
    exit 1
fi

echo "[INFO] webcode-studiod v${VER} 安装完成 -> ${INSTALL_PATH}"
