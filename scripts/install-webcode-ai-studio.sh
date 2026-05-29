#!/usr/bin/env bash
set -euo pipefail

# webcode-ai-studio 安装脚本
# 配套 https://github.com/qhkly/webcode-ai-studio
# 从 Cloudflare R2 下载安装包
#
# 环境变量:
#   WEBCODE_AI_STUDIO_VERSION  指定版本号，默认 latest（自动从 R2 获取）
#   WEBCLAW_DOCKER_BUILD=1     在 Docker 构建阶段调用，跳过 zenity
#   WEBCLAW_APP_LAUNCHER=1     由 webclaw-app-launcher 调用，跳过确认对话框
#   DISABLE_ZENITY=1           禁用所有 zenity 对话框

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ -f "/.dockerenv" ] || [ "${WEBCLAW_DOCKER_BUILD:-}" = "1" ]; then
    export WEBCLAW_DOCKER_BUILD=1
fi

PROGRESS_FILE="/tmp/webcode_ai_studio_progress"

R2_BASE="https://launcher.qhkly.com"
PRODUCT_PATH="launcher/webcode-ai-studio"

# 检查是否已安装（deb 包 或 AppImage 安装方式）
if dpkg -s ai-cli-studio 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[INFO] ai-cli-studio 已安装，跳过"
    exit 0
fi
if [ -f "/usr/bin/webcode-ai-studio" ]; then
    echo "[INFO] webcode-ai-studio 已安装，跳过"
    exit 0
fi

# 非 launcher / 非 Docker 构建时显示确认对话框
if [ "${WEBCLAW_APP_LAUNCHER:-}" != "1" ] && [ "${WEBCLAW_DOCKER_BUILD:-}" != "1" ] && [ "${DISABLE_ZENITY:-}" != "1" ]; then
    zenity --question \
      --title="安装 webcode ai studio" \
      --text="<b>确定要安装 webcode ai studio 吗？</b>\n\n这是 AI 编程 CLI 会话管理工具，\n支持管理多个 AI CLI 会话（Claude Code、Codex、Gemini CLI）。\n\n安装后可在 AI 工具菜单中找到。" \
      --ok-label="确定安装" \
      --cancel-label="取消" \
      --width=400 \
      --no-wrap || exit 0
fi

install_main() {
    echo "30" > "$PROGRESS_FILE"

    # 获取系统架构
    ARCH=$(dpkg --print-architecture)
    # 映射 Debian 架构到 R2 metadata 的 key
    case "$ARCH" in
        amd64) R2_ARCH_KEY="linux" ;;
        arm64) R2_ARCH_KEY="linux_aarch64" ;;
        *)
            echo "[ERROR] 不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    # 获取版本信息
    VER="${WEBCODE_AI_STUDIO_VERSION:-latest}"
    if [ "$VER" = "latest" ]; then
        echo "[INFO] 获取最新版本信息..."
        METADATA_URL="${R2_BASE}/${PRODUCT_PATH}/latest.json"
        METADATA=$(curl -fsSL "$METADATA_URL")
        if [ -z "$METADATA" ]; then
            echo "[ERROR] 无法获取版本信息，请检查网络连接或稍后重试"
            exit 1
        fi
        VER=$(echo "$METADATA" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        if [ -z "$VER" ]; then
            VER=$(echo "$METADATA" | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        fi
    fi
    echo "[INFO] 安装 ai-cli-studio v${VER} (${ARCH})"

    echo "50" > "$PROGRESS_FILE"

    # 从 metadata 提取下载 URL（使用已有的 METADATA）
    # 优先使用对应架构，否则使用通用 linux 版本
    DOWNLOAD_URL=$(echo "$METADATA" | python3 -c "import json, sys; data = json.load(sys.stdin); assets = data.get('assets', {}); print(assets.get('${R2_ARCH_KEY}', assets.get('linux', {})).get('url', ''))")

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "[ERROR] 无法找到 ${R2_ARCH_KEY} 的下载链接"
        echo "[DEBUG] Metadata: $(echo "$METADATA" | head -100)"
        exit 1
    fi

    echo "[INFO] 下载 ${DOWNLOAD_URL}"

    # 下载 zip 包（实际包含 deb 文件）
    TMP_DIR=$(mktemp -d)
    curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/ai-cli-studio.zip"

    echo "70" > "$PROGRESS_FILE"

    # 解压 zip 获取 deb 包
    unzip -q "${TMP_DIR}/ai-cli-studio.zip" -d "${TMP_DIR}/"

    # 查找 deb 或 AppImage 文件
    DEB_FILE=$(find "${TMP_DIR}" -name "*.deb" | head -n1)
    APPIMAGE_FILE=$(find "${TMP_DIR}" -name "*.AppImage" | head -n1)

    if [ -n "$DEB_FILE" ]; then
        echo "[INFO] 安装 deb 包: $(basename "$DEB_FILE")"
        dpkg -i "$DEB_FILE" || apt-get install -fy
    elif [ -n "$APPIMAGE_FILE" ]; then
        echo "[INFO] 安装 AppImage（提取模式，无需 FUSE）: $(basename "$APPIMAGE_FILE")"

        chmod +x "$APPIMAGE_FILE"

        # 提取 AppImage（无需 FUSE）
        EXTRACT_DIR="${TMP_DIR}/extracted"
        mkdir -p "$EXTRACT_DIR"
        cd "$EXTRACT_DIR"
        "$APPIMAGE_FILE" --appimage-extract 2>/dev/null || true

        # Docker build / QEMU 环境下 --appimage-extract 可能失败（AppImage 运行时无法访问 /proc/self/exe）
        # 降级方案：用 unsquashfs 直接提取 squashfs 内容
        if [ ! -d "${EXTRACT_DIR}/squashfs-root" ]; then
            echo "[INFO] --appimage-extract 失败，改用 unsquashfs 提取..."
            command -v unsquashfs >/dev/null 2>&1 || apt-get install -y squashfs-tools -qq 2>/dev/null
            # AppImage = ELF 运行时 + squashfs，通过魔数 (0x73717368 小端) 定位偏移
            SQFS_OFFSET=$(LANG=C grep -oba $'\x68\x73\x71\x73' "$APPIMAGE_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [ -n "$SQFS_OFFSET" ]; then
                unsquashfs -o "$SQFS_OFFSET" -d "${EXTRACT_DIR}/squashfs-root" "$APPIMAGE_FILE" 2>&1 | tail -2 || true
            else
                unsquashfs -d "${EXTRACT_DIR}/squashfs-root" "$APPIMAGE_FILE" 2>&1 | tail -2 || true
            fi
        fi
        cd /

        # 查找实际可执行文件（排除 .so）
        BINARY=$(find "${EXTRACT_DIR}/squashfs-root" -maxdepth 4 -type f -name "webcode-ai-studio" ! -name "*.so" 2>/dev/null | head -n1)

        if [ -z "$BINARY" ]; then
            echo "[ERROR] 无法在 AppImage 中找到可执行文件"
            ls -la "${EXTRACT_DIR}/squashfs-root/usr/bin/" 2>/dev/null || true
            rm -rf "$TMP_DIR"
            exit 1
        fi

        echo "[INFO] 找到二进制: $BINARY"

        # 将提取内容移动到 /opt/ai-cli-studio
        INSTALL_DIR="/opt/ai-cli-studio"
        rm -rf "$INSTALL_DIR"
        mv "${EXTRACT_DIR}/squashfs-root" "$INSTALL_DIR"

        # 确定安装后的实际二进制路径
        BINARY_NAME=$(basename "$BINARY")
        ACTUAL_BINARY=$(find "$INSTALL_DIR" -maxdepth 4 -type f -name "$BINARY_NAME" ! -name "*.so" | head -n1)
        chmod +x "$ACTUAL_BINARY"

        # 创建启动脚本：通过 AppRun 启动（不能直接运行二进制）
        # AppRun.wrapped 设置完整 LD_LIBRARY_PATH（含 $APPDIR/lib/...），
        # WebKit2GTK 子进程通过相对路径 ././/lib/.../WebKitNetworkProcess 查找自身，
        # 必须借助 AppRun.wrapped 设置的路径才能找到。
        cat > /usr/bin/webcode-ai-studio <<WRAPPER_EOF
#!/bin/bash
export APPDIR="${INSTALL_DIR}"
cd "${INSTALL_DIR}"
exec "${INSTALL_DIR}/AppRun" "\$@"
WRAPPER_EOF
        chmod +x /usr/bin/webcode-ai-studio
    else
        echo "[ERROR] 无法找到 deb 或 AppImage 文件"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    # 清理临时文件
    rm -rf "$TMP_DIR"

    # 复制图标到 on-demand-icons（供 update-desktop-icons 使用）
    mkdir -p /opt/on-demand-icons
    ICON_SRC=$(find /usr/share/icons/hicolor -name "webcode-ai-studio.png" | sort -r | head -n1)
    if [ -n "$ICON_SRC" ]; then
        cp "$ICON_SRC" /opt/on-demand-icons/webcode-ai-studio.png
    fi

    echo "100" > "$PROGRESS_FILE"
    echo "[INFO] ai-cli-studio 安装完成"
}

if [ "${DISABLE_ZENITY:-}" = "1" ] || [ "${WEBCLAW_DOCKER_BUILD:-}" = "1" ] || [ "${WEBCLAW_APP_LAUNCHER:-}" = "1" ]; then
    install_main
else
    {
        echo "10"
        echo "# 准备安装..."
        install_main
        echo "100"
        echo "# 安装完成！"
    } | zenity --progress \
      --title="安装 webcode ai studio" \
      --text="正在安装..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=400

    if [ -f "/usr/bin/webcode-ai-studio" ]; then
        zenity --info \
          --title="安装成功" \
          --text="webcode ai studio 安装成功！\n\n可在 AI 工具菜单中找到。" \
          --no-wrap
    else
        zenity --error \
          --title="安装失败" \
          --text="webcode ai studio 安装失败，请查看系统日志。" \
          --no-wrap
        exit 1
    fi
fi

rm -f "$PROGRESS_FILE" 2>/dev/null || true
