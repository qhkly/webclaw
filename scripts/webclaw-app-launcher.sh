#!/bin/bash
# 通用按需安装调度器
#
# 用法: webclaw-app-launcher <app-id> [args...]
#
# 行为:
#   - 读 /opt/on-demand-apps/<app-id>.json 拿到包名/二进制/安装方式
#   - 若已装,直接 setsid exec 二进制(透传 args)
#   - 未装则 zenity 询问,确认后按 install_method 执行安装
#
# 支持的 install_method:
#   - "github_release" (默认): 从 .github_repo 拿最新 release,按 .asset_pattern + .arch_map
#                              下载 .deb 到 /tmp/webclaw-ondemand-<id>.deb,sudo apt-get install
#   - "apt":                   直接 sudo apt-get update && sudo apt-get install -y <apt_package>
#                              (适合本来就在 apt 仓库的包,如 VS Code)
#   - "appimage":              从 GitHub 下载 AppImage,解压到 /opt/ondemand-apps/<id>/AppDir
#   - "r2_download":           从自定义 R2 API 下载 zip 包,解压安装到指定目录
#   - "direct_download":       从直接 URL 下载 AppImage,解压安装到指定目录
#   - "cursor_api":            从 Cursor 官方 API 下载 AppImage (支持 AMD64/ARM64)
#
# sudo 授权由 /etc/sudoers.d/webclaw-app-launcher 提供:
#   - apt-get install -y /tmp/webclaw-ondemand-*.deb (固定路径前缀)
#   - apt-get update
#   - 每个 apt 模式应用各自的 apt-get install -y <pkg> 白名单

set -u
set -o pipefail

# shellcheck source=lib/on-demand-core.sh
source "${WEBCLAW_LIB_DIR:-/opt/lib}/on-demand-core.sh"

# ─── 自动检测 DISPLAY（桌面环境可能未传递此变量）────────────
if [ -z "${DISPLAY:-}" ]; then
    # 检查 X11 socket 目录来确定正确的 DISPLAY
    if [ -d /tmp/.X11-unix ]; then
        for X_SOCKET in /tmp/.X11-unix/X*; do
            if [ -S "$X_SOCKET" ]; then
                export DISPLAY=":${X_SOCKET##*/X}"
                break
            fi
        done
    fi
    # 如果还是找不到，默认使用 :1（容器标准配置）
    [ -z "${DISPLAY:-}" ] && export DISPLAY=":1"
fi

APP_ID="${1:-}"
shift || true
ACTION="launch"

if [ "$APP_ID" = "--uninstall" ]; then
    ACTION="uninstall"
    APP_ID="${1:-}"
    shift || true
fi

if [ -z "$APP_ID" ]; then
    zenity --error --title="按需安装" --text="缺少应用 ID 参数" --width=320
    exit 1
fi

MANIFEST="/opt/on-demand-apps/${APP_ID}.json"
LOG="/tmp/webclaw-ondemand-${APP_ID}.log"

if [ ! -f "$MANIFEST" ]; then
    zenity --error --title="按需安装" --text="未找到应用清单:\n$MANIFEST" --width=380
    exit 1
fi

PKG=$(jq -r '.package' "$MANIFEST")
NAME=$(jq -r '.name' "$MANIFEST")
BIN=$(jq -r '.binary' "$MANIFEST")
LAUNCH_BIN=$(jq -r '.launch_binary // empty' "$MANIFEST")
# 如果存在 launch_binary，使用它来启动应用（用于启动 web dashboard 而非 CLI）
[ -n "$LAUNCH_BIN" ] && BIN="$LAUNCH_BIN"
INSTALL_METHOD=$(jq -r '.install_method // "github_release"' "$MANIFEST")
REQUIRES_TERMINAL=$(jq -r '.requires_terminal // "false"' "$MANIFEST")

prepare_log() {
    if [ -x /usr/local/bin/webclaw-log-prepare ]; then
        sudo /usr/local/bin/webclaw-log-prepare "$APP_ID" >/dev/null 2>&1 || true
    fi

    if [ ! -e "$LOG" ]; then
        : > "$LOG" 2>/dev/null || true
    fi

    if [ ! -w "$LOG" ]; then
        LOG="/tmp/webclaw-ondemand-${APP_ID}-${USER:-ubuntu}.log"
        : > "$LOG" 2>/dev/null || true
    fi
}

is_app_installed() {
    webclaw_app_installed "$INSTALL_METHOD" "$PKG" "$BIN"
}

is_app_present() {
    if is_app_installed; then
        return 0
    fi

    if [ "$INSTALL_METHOD" = "appimage" ]; then
        [ -d "/opt/ondemand-apps/${APP_ID}" ]
    elif [ "$INSTALL_METHOD" = "r2_download" ] || [ "$INSTALL_METHOD" = "direct_download" ] || [ "$INSTALL_METHOD" = "cursor_api" ]; then
        [ -d "/opt/${APP_ID}" ]
    elif [ "$INSTALL_METHOD" = "custom_script" ]; then
        [ -d "$(dirname "$BIN")" ]
    else
        dpkg -s "$PKG" 2>/dev/null | grep -q "Status: install ok installed"
    fi
}

download_with_progress() {
    local url="$1"
    local output="$2"
    local start="${3:-10}"
    local end="${4:-50}"
    local label="${5:-正在下载}"
    local span=$((end - start))
    local total=""
    local size=0
    local percent=$start
    local download_percent=0
    local curl_pid
    local rc=0

    echo "$start"
    echo "# ${label}..."

    total=$(curl -fsIL "$url" 2>>"$LOG" \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r","",$2); value=$2} END{print value}')

    # 如果获取不到 Content-Length（可能是重定向 URL），尝试用 -L
    if [ -z "$total" ] || [ "$total" -le 0 ] 2>/dev/null; then
        total=$(curl -fsILL "$url" 2>>"$LOG" \
            | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r","",$2); value=$2} END{print value}')
    fi

    rm -f "$output"
    curl -fsSL "$url" -o "$output" 2>>"$LOG" &
    curl_pid=$!

    while kill -0 "$curl_pid" >/dev/null 2>&1; do
        if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null && [ -f "$output" ]; then
            size=$(wc -c < "$output" 2>/dev/null || echo 0)
            percent=$((start + (size * span / total)))
            download_percent=$((size * 100 / total))
            [ "$percent" -ge "$end" ] && percent=$((end - 1))
            [ "$download_percent" -gt 99 ] && download_percent=99
            echo "$percent"
            echo "# ${label}... ${download_percent}%"
        else
            echo "# ${label}..."
        fi
        sleep 1
    done

    wait "$curl_pid" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "下载失败: $url" >> "$LOG"
        echo "100"
        return "$rc"
    fi

    echo "$end"
    return 0
}

get_github_latest_tag() {
    local repo="$1"
    local tag=""

    tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>>"$LOG" \
        | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -z "$tag" ]; then
        tag=$(curl -fsSIL "https://github.com/${repo}/releases/latest" 2>>"$LOG" \
            | awk 'BEGIN{IGNORECASE=1} /^location:/ {gsub("\r","",$2); location=$2} END{sub(".*/tag/","",location); print location}')
    fi

    echo "$tag"
}

# 可选: manifest 里固定要传给二进制的参数(比如 VS Code 在容器里必须 --no-sandbox,
# 不带的话 chrome-sandbox SUID 检查失败立刻静默退出)
mapfile -t DEFAULT_ARGS < <(jq -r '.default_args // [] | .[]' "$MANIFEST")

if [ "$ACTION" = "uninstall" ]; then
    if ! is_app_present; then
        zenity --info \
            --title="$NAME" \
            --text="<b>$NAME</b> 当前未安装。" \
            --width=340
        [ -x /usr/local/bin/update-desktop-icons ] && /usr/local/bin/update-desktop-icons
        exit 0
    fi

    zenity --question \
        --title="卸载 $NAME" \
        --text="确定要卸载 <b>$NAME</b> 吗？\n\n卸载后可再次点击桌面图标重新安装。" \
        --ok-label="卸载" --cancel-label="取消" \
        --width=420 || exit 0

    prepare_log
    echo "Uninstall requested: app_id=${APP_ID}, name=${NAME}, method=${INSTALL_METHOD}, package=${PKG}, binary=${BIN}" >> "$LOG"

    if ! {
        echo "20"
        echo "# 正在卸载 $NAME..."
        if ! sudo /usr/local/bin/webclaw-app-uninstaller "$APP_ID" >>"$LOG" 2>&1; then
            echo "100"; exit 1
        fi
        echo "90"
        echo "# 正在更新桌面图标..."
        [ -x /usr/local/bin/update-desktop-icons ] && /usr/local/bin/update-desktop-icons
        echo "100"
        echo "# 完成"
    } | zenity --progress \
        --title="卸载 $NAME" \
        --text="准备中..." \
        --percentage=0 --auto-close --no-cancel --width=420; then
        zenity --error \
            --title="$NAME" \
            --text="卸载失败,详细日志:\n$LOG" \
            --width=420
        exit 1
    fi

    if is_app_installed; then
        echo "Uninstall verification failed: package or binary is still present." >> "$LOG"
        dpkg -s "$PKG" >> "$LOG" 2>&1 || true
        [ -e "$BIN" ] && ls -l "$BIN" >> "$LOG" 2>&1 || true
        zenity --error \
            --title="$NAME" \
            --text="卸载失败,详细日志:\n$LOG" \
            --width=420
        exit 1
    fi

    [ -x /usr/local/bin/update-desktop-icons ] && /usr/local/bin/update-desktop-icons

    zenity --info \
        --title="$NAME" \
        --text="<b>$NAME</b> 已卸载。" \
        --width=340
    exit 0
fi

# 已装 -> 直接启动,setsid 脱离终端避免阻塞 dbus-launch 等
# 根据安装方法使用不同的检查方式
if is_app_installed; then
    # 确保输入法环境变量被传递（fcitx5 前端模块仍使用 fcitx 这个值）
    export GTK_IM_MODULE=${GTK_IM_MODULE:-fcitx}
    export QT_IM_MODULE=${QT_IM_MODULE:-fcitx}
    export XMODIFIERS=${XMODIFIERS:-@im=fcitx}

    if [ "$REQUIRES_TERMINAL" = "true" ]; then
        sudo -u ubuntu DISPLAY="$DISPLAY" \
            GTK_IM_MODULE="$GTK_IM_MODULE" \
            QT_IM_MODULE="$QT_IM_MODULE" \
            XMODIFIERS="$XMODIFIERS" \
            gnome-terminal -- "$BIN" "${DEFAULT_ARGS[@]}" "$@" &
        exit 0
    fi
    setsid env \
        GTK_IM_MODULE="$GTK_IM_MODULE" \
        QT_IM_MODULE="$QT_IM_MODULE" \
        XMODIFIERS="$XMODIFIERS" \
        "$BIN" "${DEFAULT_ARGS[@]}" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

# 未装 -> 询问
zenity --question \
    --title="$NAME" \
    --text="<b>$NAME</b> 尚未安装。\n\n点「安装」会下载并安装最新版,\n这会占用一些磁盘空间。" \
    --ok-label="安装" --cancel-label="取消" \
    --width=400 || exit 0

prepare_log
echo "Install requested: app_id=${APP_ID}, name=${NAME}, method=${INSTALL_METHOD}, package=${PKG}, binary=${BIN}" >> "$LOG"

case "$INSTALL_METHOD" in
    apt)
        # ─── apt 仓库直装(VS Code 等 / Antigravity 等) ─────────────────
        APT_PKG=$(jq -r '.apt_package' "$MANIFEST")
        INSTALL_SCRIPT=$(jq -r '.install_script // empty' "$MANIFEST")

        # 如果有预安装脚本(如添加 apt 仓库),先执行
        if [ -n "$INSTALL_SCRIPT" ] && [ -x "$INSTALL_SCRIPT" ]; then
            {
                echo "5"
                echo "# 正在准备安装环境..."
                if ! sudo "$INSTALL_SCRIPT" >>"$LOG" 2>&1; then
                    echo "安装脚本执行失败" >> "$LOG"
                    echo "100"; exit 1
                fi
                echo "35"
                echo "# 环境准备完成"
            } | zenity --progress \
                --title="安装 $NAME" \
                --text="准备中..." \
                --percentage=0 --auto-close --no-cancel --width=420
        fi

        {
            echo "40"
            echo "# 正在刷新 apt 索引..."
            if ! sudo /usr/bin/apt-get update >>"$LOG" 2>&1; then
                echo "apt-get update 失败" >> "$LOG"
                echo "100"; exit 1
            fi

            echo "60"
            echo "# 正在安装 $NAME ($APT_PKG)..."
            # Wireshark 需要预配置 debconf 避免交互提示
            if [ "$APT_PKG" = "wireshark" ]; then
                echo "wireshark-common wireshark-common/setuid boolean true" | sudo debconf-set-selections >>"$LOG" 2>&1
            fi
            if ! sudo /usr/bin/apt-get install -y "$APT_PKG" >>"$LOG" 2>&1; then
                echo "apt-get install $APT_PKG 失败" >> "$LOG"
                echo "100"; exit 1
            fi

            # 安装后置钩子: 委托给受控的 root-side 脚本, 按 app_id 分发
            # (例如 Wireshark 需要 groupadd / usermod / setcap)
            echo "70"
            echo "# 正在配置..."
            sudo /usr/local/bin/webclaw-app-postinstall "$APP_ID" >>"$LOG" 2>&1 || true

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    github_release)
        # ─── GitHub release 下 .deb 装(OpenTypeless / CC Switch 等) ──
        REPO=$(jq -r '.github_repo' "$MANIFEST")
        ASSET_PATTERN=$(jq -r '.asset_pattern' "$MANIFEST")
        ARCH=$(dpkg --print-architecture)
        ARCH_VAR=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$MANIFEST")
        if [ -z "$ARCH_VAR" ]; then
            zenity --error --title="$NAME" --text="不支持的架构: $ARCH" --width=320
            exit 1
        fi

        {
            VERSION=""
            if [ "$(jq -r '.use_fixed_version // false' "$MANIFEST")" = "true" ]; then
                VERSION=$(jq -r '.version // empty' "$MANIFEST")
                echo "5"
                echo "# 使用指定版本 $VERSION..."
            else
                echo "5"
                echo "# 正在查询最新版本..."
                VERSION=$(get_github_latest_tag "$REPO")
            fi
            if [ -z "$VERSION" ]; then
                echo "无法获取最新版本号" >> "$LOG"
                echo "100"; exit 1
            fi

            VERSION_NO_V="${VERSION#v}"
            ASSET=${ASSET_PATTERN//\{version_no_v\}/$VERSION_NO_V}
            ASSET=${ASSET//\{version\}/$VERSION}
            ASSET=${ASSET//\{arch\}/$ARCH_VAR}
            URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
            DEB="/tmp/webclaw-ondemand-${APP_ID}.deb"

            rm -f "$DEB"
            if ! download_with_progress "$URL" "$DEB" 15 60 "正在下载 $NAME v$VERSION (${ARCH_VAR})"; then
                echo "100"; exit 1
            fi

            echo "65"
            echo "# 正在安装 .deb 包..."
            if ! sudo /usr/bin/apt-get install -y "$DEB" >>"$LOG" 2>&1; then
                echo "apt-get install 失败" >> "$LOG"
                rm -f "$DEB"
                echo "100"; exit 1
            fi

            rm -f "$DEB"
            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    appimage)
        # ─── GitHub release 下 AppImage 解压安装(Obsidian 等) ───────
        # AppImage 解压安装更可靠，不依赖 fuse 挂载
        REPO=$(jq -r '.github_repo' "$MANIFEST")
        ASSET_PATTERN=$(jq -r '.asset_pattern' "$MANIFEST")
        ARCH=$(dpkg --print-architecture)
        ARCH_VAR=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$MANIFEST")
        if [ -z "$ARCH_VAR" ]; then
            zenity --error --title="$NAME" --text="不支持的架构: $ARCH" --width=320
            exit 1
        fi

        # AppImage 解压目录
        APPIMAGE_EXTRACT_DIR="/opt/ondemand-apps/${APP_ID}"
        APPIMAGE_TMP="/tmp/webclaw-ondemand-${APP_ID}.AppImage"
        sudo /bin/mkdir -p "$APPIMAGE_EXTRACT_DIR" 2>>"$LOG"

        {
            echo "5"
            echo "# 正在查询最新版本..."
            VERSION_TAG=$(get_github_latest_tag "$REPO")
            VERSION="${VERSION_TAG#v}"
            if [ -z "$VERSION" ]; then
                echo "无法获取最新版本号" >> "$LOG"
                echo "100"; exit 1
            fi

            # 替换版本和架构后缀(注意: arch_var 可能是空字符串)
            ASSET=${ASSET_PATTERN//\{version\}/$VERSION}
            ASSET=${ASSET//\{arch_suffix\}/$ARCH_VAR}
            URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET}"

            rm -f "$APPIMAGE_TMP"
            rm -rf "$APPIMAGE_EXTRACT_DIR"
            if ! download_with_progress "$URL" "$APPIMAGE_TMP" 15 40 "正在下载 $NAME v$VERSION"; then
                echo "100"; exit 1
            fi

            echo "40"
            echo "# 正在准备 AppImage..."
            chmod +x "$APPIMAGE_TMP" 2>>"$LOG"

            echo "50"
            echo "# 正在解压 AppImage..."
            cd /tmp
            rm -rf /tmp/squashfs-root /tmp/AppDir
            if ! "$APPIMAGE_TMP" --appimage-extract >/dev/null 2>>"$LOG"; then
                echo "解压失败" >> "$LOG"
                rm -f "$APPIMAGE_TMP"
                echo "100"; exit 1
            fi

            # pkgforge 系列 AppImage: /tmp/squashfs-root 是个 symlink → ./AppDir,
            # 必须解到真实目录,否则后面 mv 走的是 symlink 本身、留下孤儿 AppDir
            EXTRACTED=$(readlink -f /tmp/squashfs-root)

            # 可选: 把 AppImage 自带的旧 Mesa GL 库替换为系统 Mesa 的符号链接,
            # 解决 pkgforge 的 anylinux.so 劫持 dlopen 强制加载老 GL 导致 GTK4
            # 应用(如 Ghostty)只能拿到 OpenGL 3.3、达不到 4.3+ 要求的问题
            if [ "$(jq -r '.unbundle_gl // false' "$MANIFEST")" = "true" ]; then
                echo "65"
                echo "# 正在卸绑 AppImage 自带 GL 库,改用系统 Mesa..."
                LIBD="$EXTRACTED/shared/lib"
                SYSD="/usr/lib/$(gcc -print-multiarch 2>/dev/null || dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
                if [ -d "$LIBD" ]; then
                    mkdir -p "$LIBD/.gl-bundled-bak"
                    for pat in libEGL libGL libGLX libGLES libGLdispatch libgbm; do
                        for f in "$LIBD/${pat}"*; do
                            [ -e "$f" ] || continue
                            case "$f" in *.gl-bundled-bak*) continue ;; esac
                            mv -f "$f" "$LIBD/.gl-bundled-bak/" 2>>"$LOG" || true
                        done
                    done
                    for name in libEGL.so.1 libGL.so.1 libGLX.so.0 libGLdispatch.so.0 \
                                libGLX_mesa.so.0 libEGL_mesa.so.0 libgbm.so.1 libGLESv2.so.2; do
                        [ -e "$SYSD/$name" ] && ln -sfn "$SYSD/$name" "$LIBD/$name"
                    done
                fi
            fi

            echo "75"
            echo "# 正在安装..."
            # 把解压结果嵌套放进 $APPIMAGE_EXTRACT_DIR/AppDir,
            # 让 manifest 里的 binary 路径(如 .../ghostty/AppDir/bin/ghostty)自然成立
            if ! sudo /bin/mv -f "$EXTRACTED" "$APPIMAGE_EXTRACT_DIR/AppDir" 2>>"$LOG"; then
                echo "移动失败" >> "$LOG"
                rm -f "$APPIMAGE_TMP"
                rm -rf /tmp/squashfs-root "$EXTRACTED"
                echo "100"; exit 1
            fi
            sudo /bin/chmod -R a+rX "$APPIMAGE_EXTRACT_DIR/AppDir" 2>>"$LOG" || true
            if [ -x "$APPIMAGE_EXTRACT_DIR/AppDir/AppRun" ]; then
                cat > /tmp/${APP_ID}-wrapper.sh <<EOF
#!/bin/bash
APPDIR="$APPIMAGE_EXTRACT_DIR/AppDir" exec "$APPIMAGE_EXTRACT_DIR/AppDir/AppRun" "\$@"
EOF
                sudo /bin/mv -f /tmp/${APP_ID}-wrapper.sh "$APPIMAGE_EXTRACT_DIR/${APP_ID}" 2>>"$LOG"
                sudo /bin/chmod +x "$APPIMAGE_EXTRACT_DIR/${APP_ID}" 2>>"$LOG"
            fi

            # 清理临时文件
            rm -f "$APPIMAGE_TMP"
            rm -rf /tmp/squashfs-root

            echo "90"
            echo "# 正在配置..."
            sudo /usr/local/bin/webclaw-app-postinstall "$APP_ID" >>"$LOG" 2>&1 || true

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    r2_download)
        # ─── R2 自定义 API 下载安装(WebClaw Launcher) ───────────────────
        DOWNLOAD_API=$(jq -r '.download_api' "$MANIFEST")

        # 检查架构支持
        ARCH=$(dpkg --print-architecture)
        UNSUPPORTED_ARCHS=$(jq -r '.unsupported_archs // [] | .[]' "$MANIFEST" 2>/dev/null || echo "")
        for UNSUP in $UNSUPPORTED_ARCHS; do
            if [ "$ARCH" = "$UNSUP" ]; then
                zenity --error --title="$NAME" \
                    --text="$NAME 暂不支持 $ARCH 架构。\n\n目前仅支持 AMD64 (x86_64) 平台。" \
                    --width=380
                exit 1
            fi
        done

        # 根据 arch_map 获取对应的 asset_key
        ASSET_KEY=$(jq -r --arg a "$ARCH" '.arch_map[$a] // .asset_key // empty' "$MANIFEST")
        if [ -z "$ASSET_KEY" ]; then
            zenity --error --title="$NAME" --text="不支持的架构: $ARCH" --width=320
            exit 1
        fi

        INSTALL_DIR="/opt/${APP_ID}"

        {
            echo "5"
            echo "# 正在查询最新版本..."
            API_RESP=$(curl -fsSL "$DOWNLOAD_API" 2>>"$LOG")
            if [ -z "$API_RESP" ]; then
                echo "无法获取版本信息" >> "$LOG"
                echo "100"; exit 1
            fi

            VERSION=$(echo "$API_RESP" | jq -r '.version // .latest // empty' 2>>"$LOG")
            if [ -z "$VERSION" ]; then
                echo "无法解析版本号" >> "$LOG"
                echo "100"; exit 1
            fi

            DOWNLOAD_URL=$(echo "$API_RESP" | jq -r ".assets.${ASSET_KEY}.url // empty" 2>>"$LOG")
            if [ -z "$DOWNLOAD_URL" ]; then
                echo "无法获取下载链接" >> "$LOG"
                echo "100"; exit 1
            fi

            TMP_ZIP="/tmp/webclaw-launcher-${VERSION}.zip"
            TMP_EXTRACT="/tmp/webclaw-launcher-extract"

            rm -f "$TMP_ZIP"
            rm -rf "$TMP_EXTRACT"
            if ! download_with_progress "$DOWNLOAD_URL" "$TMP_ZIP" 15 50 "正在下载 $NAME v$VERSION"; then
                echo "100"; exit 1
            fi

            echo "50"
            echo "# 正在解压..."
            mkdir -p "$TMP_EXTRACT"
            if ! unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT" 2>>"$LOG"; then
                echo "解压失败" >> "$LOG"
                rm -f "$TMP_ZIP"
                echo "100"; exit 1
            fi

            echo "50"
            echo "# 正在解压 zip..."
            mkdir -p "$TMP_EXTRACT"
            if ! unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT" 2>>"$LOG"; then
                echo "解压 zip 失败" >> "$LOG"
                rm -f "$TMP_ZIP"
                echo "100"; exit 1
            fi

            echo "60"
            echo "# 正在准备 AppImage..."

            # 查找 zip 中的 AppImage 文件
            APPIMAGE_FILE=$(find "$TMP_EXTRACT" -maxdepth 1 -name "*.AppImage" | head -1)
            if [ -z "$APPIMAGE_FILE" ]; then
                echo "未找到 AppImage 文件" >> "$LOG"
                rm -rf "$TMP_EXTRACT" "$TMP_ZIP"
                echo "100"; exit 1
            fi

            chmod +x "$APPIMAGE_FILE" 2>>"$LOG"

            echo "70"
            echo "# 正在解压 AppImage..."

            # 解压 AppImage
            cd /tmp
            rm -rf /tmp/squashfs-root /tmp/AppDir
            if ! "$APPIMAGE_FILE" --appimage-extract >/dev/null 2>>"$LOG"; then
                echo "AppImage 解压失败" >> "$LOG"
                rm -rf "$TMP_EXTRACT" "$TMP_ZIP"
                echo "100"; exit 1
            fi

            EXTRACTED=$(readlink -f /tmp/squashfs-root)

            echo "85"
            echo "# 正在安装..."

            # 创建安装目录
            sudo /bin/mkdir -p "$INSTALL_DIR" 2>>"$LOG"

            # 将解压结果移动到安装目录
            if ! sudo /bin/mv -f "$EXTRACTED" "$INSTALL_DIR/AppDir" 2>>"$LOG"; then
                echo "移动失败" >> "$LOG"
                rm -rf "$TMP_EXTRACT" "$TMP_ZIP" /tmp/squashfs-root
                echo "100"; exit 1
            fi

            # 创建启动脚本，指向 AppDir 中的可执行文件
            # 需要找到实际的二进制文件位置
            ACTUAL_BIN=$(find "$INSTALL_DIR/AppDir" -type f -executable -name "webclaw-launcher" | head -1)
            if [ -n "$ACTUAL_BIN" ]; then
                # 创建一个启动脚本
                cat > /tmp/webclaw-launcher-wrapper.sh <<EOF
#!/bin/bash
exec "$ACTUAL_BIN" "\$@"
EOF
                sudo /bin/mv -f /tmp/${APP_ID}-wrapper.sh "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
                sudo /bin/chmod +x "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
            else
                echo "未找到 ${APP_ID} 可执行文件" >> "$LOG"
                rm -rf "$TMP_EXTRACT" "$TMP_ZIP" /tmp/squashfs-root
                echo "100"; exit 1
            fi

            # 清理临时文件
            rm -rf "$TMP_EXTRACT" "$TMP_ZIP" /tmp/squashfs-root

            # 创建 desktop 快捷方式
            cat > /tmp/${APP_ID}.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Comment=$NAME
Exec=$INSTALL_DIR/${APP_ID} %F
Icon=$APP_ID
Terminal=false
Categories=Utility;Application;
EOF
            sudo /bin/mv -f /tmp/${APP_ID}.desktop /usr/share/applications/ 2>>"$LOG"

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    direct_download)
        # ─── 直接 URL 下载安装(Cursor / WebClaw Launcher 等) ────────────────
        DOWNLOAD_URL=$(jq -r '.download_url' "$MANIFEST")
        VERSION_API=$(jq -r '.version_api // empty' "$MANIFEST")
        ARCH=$(dpkg --print-architecture)
        VERSION=""
        DIRECT_URL=""

        # 检查不支持的架构列表
        UNSUPPORTED_ARCHS=$(jq -r '.unsupported_archs // [] | .[]' "$MANIFEST" 2>/dev/null || echo "")
        for UNSUP in $UNSUPPORTED_ARCHS; do
            if [ "$ARCH" = "$UNSUP" ]; then
                zenity --error --title="$NAME" \
                    --text="$NAME 暂不支持 $ARCH 架构。\n\n目前仅支持 AMD64 (x86_64) 平台。" \
                    --width=380
                exit 1
            fi
        done

        ARCH_VAR=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$MANIFEST")
        ARCH_SUFFIX=$(jq -r --arg a "$ARCH" --arg fallback "$ARCH_VAR" '.arch_suffix_map[$a] // $fallback // empty' "$MANIFEST")
        if [ -z "$ARCH_VAR" ]; then
            zenity --error --title="$NAME" --text="不支持的架构: $ARCH" --width=320
            exit 1
        fi

        # ─── 获取版本号和下载链接 ─────────────────────────────────────────────
        # 方式1: 通过 version_api (自定义 JSON API)
        if [ -n "$VERSION_API" ]; then
            if [[ "$VERSION_API" == file:///* ]]; then
                # 本地脚本：file:///path/to/script.sh
                SCRIPT_PATH="${VERSION_API#file://}"  # 注意：两个斜杠，不是三个
                VERSION=$("$SCRIPT_PATH" 2>>"$LOG" | jq -r '.version // .latest // empty' 2>>"$LOG")
            else
                # HTTP API
                VERSION=$(curl -fsSL "$VERSION_API" 2>>"$LOG" | jq -r '.version // .latest // empty' 2>>"$LOG")
            fi
        fi

        # 方式2: JetBrains 产品 - 使用官方 API 获取最新版本和下载链接
        JETBRAINS_CODE=$(jq -r '.jetbrains_code // empty' "$MANIFEST" 2>/dev/null)
        if [ -n "$JETBRAINS_CODE" ]; then
            # JetBrains API: https://data.services.jetbrains.com/products/releases?code=XXX&latest=true&type=release
            JB_API_RESP=$(curl -fsSL "https://data.services.jetbrains.com/products/releases?code=${JETBRAINS_CODE}&latest=true&type=release" 2>>"$LOG")
            # 提取版本号
            if [ -z "$VERSION" ]; then
                VERSION=$(echo "$JB_API_RESP" | jq -r ".[\"${JETBRAINS_CODE}\"][0].version // empty" 2>>"$LOG")
            fi
            # 根据架构获取正确的下载链接
            if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
                DIRECT_URL=$(echo "$JB_API_RESP" | jq -r ".[\"${JETBRAINS_CODE}\"][0].downloads.linuxARM64.link // empty" 2>>"$LOG")
            else
                DIRECT_URL=$(echo "$JB_API_RESP" | jq -r ".[\"${JETBRAINS_CODE}\"][0].downloads.linux.link // empty" 2>>"$LOG")
            fi
            # 如果 API 返回了直接链接，使用它
            echo "JetBrains latest ${JETBRAINS_CODE}: version=${VERSION}, url=${DIRECT_URL}" >> "$LOG"
            if [ -n "$DIRECT_URL" ] && [ "$DIRECT_URL" != "null" ]; then
                DOWNLOAD_URL="$DIRECT_URL"
            fi
        fi

        # 如果还是获取不到版本，报错
        if [ -z "$VERSION" ] && [[ "$DOWNLOAD_URL" == *"{version}"* ]]; then
            zenity --error --title="$NAME" --text="无法获取版本号" --width=320
            exit 1
        fi

        # 替换版本和架构占位符（使用 sed 因为 bash 模式替换对花括号支持不佳）
        DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | sed "s/{version}/${VERSION}/g")
        DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | sed "s/{arch}/${ARCH_VAR}/g")
        DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | sed "s/{arch_suffix}/${ARCH_SUFFIX}/g")
        if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
            zenity --error --title="$NAME" --text="无法获取下载链接" --width=320
            exit 1
        fi
        INSTALL_DIR="/opt/${APP_ID}"

        # ─── 特殊处理: .deb 文件直接安装 ───────────────────────────────────
        if [[ "$DOWNLOAD_URL" == *".deb"* ]]; then
            DEB="/tmp/webclaw-ondemand-${APP_ID}.deb"
            {
                rm -f "$DEB"
                if ! download_with_progress "$DOWNLOAD_URL" "$DEB" 10 60 "正在下载 $NAME"; then
                    echo "100"; exit 1
                fi

                echo "60"
                echo "# 正在安装..."
                if ! sudo /usr/bin/apt-get install -y "$DEB" >>"$LOG" 2>&1; then
                    echo "安装失败" >> "$LOG"
                    rm -f "$DEB"
                    echo "100"; exit 1
                fi

                rm -f "$DEB"
                echo "100"
                echo "# 完成"
            } | zenity --progress \
                --title="安装 $NAME" \
                --text="准备中..." \
                --percentage=0 --auto-close --no-cancel --width=420

            # 验证安装结果（dpkg 包检查）
            if dpkg -s "$PKG" 2>/dev/null | grep -q "Status: install ok installed"; then
                [ -x /usr/local/bin/update-desktop-icons ] && /usr/local/bin/update-desktop-icons
                zenity --info \
                    --title="$NAME" \
                    --text="<b>$NAME</b> 安装完成!\n\n再次点击桌面图标即可启动。" \
                    --width=360
            else
                zenity --error \
                    --title="$NAME" \
                    --text="安装失败,详细日志:\n$LOG" \
                    --width=420
                exit 1
            fi
            exit 0
        fi

        {
            TMP_APPIMAGE="/tmp/${APP_ID}.AppImage"
            TMP_ZIP="/tmp/${APP_ID}.zip"
            rm -f "$TMP_APPIMAGE" "$TMP_ZIP" "/tmp/${APP_ID}.tar.gz"

            # 检测文件类型（AppImage、zip 或 tar.gz）
            if [[ "$DOWNLOAD_URL" == *".tar.gz"* ]] || [[ "$DOWNLOAD_URL" == *".tgz"* ]]; then
                TMP_TAR="/tmp/${APP_ID}.tar.gz"
                if ! download_with_progress "$DOWNLOAD_URL" "$TMP_TAR" 10 50 "正在下载 $NAME"; then
                    echo "100"; exit 1
                fi
            elif [[ "$DOWNLOAD_URL" == *".zip"* ]]; then
                if ! download_with_progress "$DOWNLOAD_URL" "$TMP_ZIP" 10 50 "正在下载 $NAME"; then
                    echo "100"; exit 1
                fi
            else
                # Cursor 的 latest 实际上会重定向到具体的版本文件
                if ! download_with_progress "$DOWNLOAD_URL" "$TMP_APPIMAGE" 10 50 "正在下载 $NAME"; then
                    echo "100"; exit 1
                fi
            fi

            echo "50"
            echo "# 正在解压..."

            cd /tmp
            rm -rf /tmp/squashfs-root /tmp/AppDir

            if [ -f "${TMP_TAR:-}" ]; then
                # 解压 tar.gz 包（用于 JetBrains 工具等）
                TMP_EXTRACT="/tmp/${APP_ID}-extract-$$"
                rm -rf "$TMP_EXTRACT"
                mkdir -p "$TMP_EXTRACT"
                if ! tar --no-same-owner --no-same-permissions -xzf "$TMP_TAR" -C "$TMP_EXTRACT" 2>>"$LOG"; then
                    echo "解压 tar.gz 失败" >> "$LOG"
                    rm -f "$TMP_TAR"
                    echo "100"; exit 1
                fi
                rm -f "$TMP_TAR"

                # 查找解压后的内容（可能是目录或直接是二进制文件）
                EXTRACTED_DIR=$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -1)
                EXTRACTED_FILE=$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type f -executable | head -1)

                if [ -n "$EXTRACTED_DIR" ]; then
                    # 标准情况：解压后是目录
                    EXTRACTED="$EXTRACTED_DIR"
                elif [ -n "$EXTRACTED_FILE" ]; then
                    # 特殊情况：直接是可执行文件（如 Codex CLI）
                    # 将文件移动到安装目录
                    sudo /bin/mkdir -p "$INSTALL_DIR" 2>>"$LOG"
                    if ! sudo /bin/mv -f "$EXTRACTED_FILE" "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"; then
                        echo "移动二进制文件失败" >> "$LOG"
                        rm -rf "$TMP_EXTRACT"
                        echo "100"; exit 1
                    fi
                    sudo /bin/chmod +x "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
                    rm -rf "$TMP_EXTRACT"
                    # 设置 ACTUAL_BIN 以便后续代码跳过查找步骤
                    ACTUAL_BIN="$INSTALL_DIR/${APP_ID}"
                    # 设置 EXTRACTED 为空，跳过后续的复制逻辑
                    EXTRACTED=""
                else
                    echo "未找到解压目录或可执行文件" >> "$LOG"
                    echo "100"; exit 1
                fi

            elif [ -f "$TMP_ZIP" ]; then
                # 解压 zip 包
                TMP_EXTRACT="/tmp/${APP_ID}-extract-$$"
                rm -rf "$TMP_EXTRACT"
                mkdir -p "$TMP_EXTRACT"
                if ! unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT" 2>>"$LOG"; then
                    echo "解压 zip 失败" >> "$LOG"
                    rm -f "$TMP_ZIP"
                    echo "100"; exit 1
                fi

                # 查找 AppImage 并解压
                APPIMAGE_FILE=$(find "$TMP_EXTRACT" -maxdepth 2 -name "*.AppImage" | head -1)
                if [ -z "$APPIMAGE_FILE" ]; then
                    # 没有 AppImage，直接使用解压后的内容
                    EXTRACTED="$TMP_EXTRACT"
                else
                    chmod +x "$APPIMAGE_FILE" 2>>"$LOG"
                    if ! "$APPIMAGE_FILE" --appimage-extract >/dev/null 2>>"$LOG"; then
                        echo "AppImage 解压失败" >> "$LOG"
                        rm -rf "$TMP_EXTRACT" "$TMP_ZIP"
                        echo "100"; exit 1
                    fi
                    EXTRACTED=$(readlink -f /tmp/squashfs-root)
                fi
            elif [ -f "$TMP_APPIMAGE" ]; then
                chmod +x "$TMP_APPIMAGE" 2>>"$LOG"
                if ! "$TMP_APPIMAGE" --appimage-extract >/dev/null 2>>"$LOG"; then
                    echo "AppImage 解压失败" >> "$LOG"
                    rm -f "$TMP_APPIMAGE"
                    echo "100"; exit 1
                fi
                EXTRACTED=$(readlink -f /tmp/squashfs-root)
            else
                echo "未找到有效的安装包" >> "$LOG"
                echo "100"; exit 1
            fi

            echo "70"
            echo "# 正在安装..."

            sudo /bin/mkdir -p "$INSTALL_DIR" 2>>"$LOG"
            # 判断是否是 tar.gz 解压的内容
            if [ -d "$EXTRACTED" ] && [ ! -f "$TMP_APPIMAGE" ] && [ ! -f "$TMP_ZIP" ]; then
                # tar.gz: 复制解压目录内容到安装目录，避免 sudoers 匹配 shell 展开的多个源文件。
                if ! sudo /bin/cp -a "$EXTRACTED/." "$INSTALL_DIR/" 2>>"$LOG"; then
                    echo "复制失败" >> "$LOG"
                    rm -f "$TMP_APPIMAGE" "$TMP_ZIP"
                    rm -rf /tmp/squashfs-root "$TMP_EXTRACT"
                    echo "100"; exit 1
                fi
                # 清理空的提取目录
                rm -rf "$(dirname "$EXTRACTED")"
            else
                # AppImage/zip: 移动到 AppDir 子目录
                if ! sudo /bin/mv -f "$EXTRACTED" "$INSTALL_DIR/AppDir" 2>>"$LOG"; then
                    echo "移动失败" >> "$LOG"
                    rm -f "$TMP_APPIMAGE" "$TMP_ZIP"
                    rm -rf /tmp/squashfs-root "$TMP_EXTRACT"
                    echo "100"; exit 1
                fi
            fi

            # 查找实际的二进制文件（按优先级尝试多个可能的名字）
            # 对于 tar.gz 安装的工具，先检查 AppDir，再检查根目录
            # AppDir/AppRun 优先：linuxdeploy 打的 AppImage 必须经 AppRun 才能 source
            # apprun-hooks/linuxdeploy-plugin-gtk.sh 设置 GTK_PATH/GIO_MODULE_DIR 等，
            # 否则 GTK 应用启动时 init 失败（webclaw-launcher 这种 Tauri/GTK 应用）
            if [ -z "$ACTUAL_BIN" ]; then
                if [ -x "$INSTALL_DIR/AppDir/AppRun" ]; then
                    ACTUAL_BIN="$INSTALL_DIR/AppDir/AppRun"
                fi
                if [ -z "$ACTUAL_BIN" ] && [ -d "$INSTALL_DIR/AppDir" ]; then
                    ACTUAL_BIN=$(find "$INSTALL_DIR/AppDir" -type f -executable -name "${APP_ID}" | head -1)
                fi
                if [ -z "$ACTUAL_BIN" ]; then
                    ACTUAL_BIN=$(find "$INSTALL_DIR" -maxdepth 3 -type f -executable -name "${APP_ID}.sh" | head -1)
                fi
                if [ -z "$ACTUAL_BIN" ]; then
                    ACTUAL_BIN=$(find "$INSTALL_DIR/AppDir" -type f -executable -name "cursor" | head -1)
                fi
                if [ -z "$ACTUAL_BIN" ]; then
                    ACTUAL_BIN=$(find "$INSTALL_DIR/AppDir" -type f -executable -name "tauri-app" | head -1)
                fi
                # 最后尝试：找 usr/bin 下任何可执行文件
                if [ -z "$ACTUAL_BIN" ] && [ -d "$INSTALL_DIR/AppDir/usr/bin" ]; then
                    ACTUAL_BIN=$(find "$INSTALL_DIR/AppDir/usr/bin" -type f -executable | head -1)
                fi
            fi
            if [ -n "$ACTUAL_BIN" ]; then
                # 只在二进制文件不在正确位置时创建 wrapper
                if [ "$ACTUAL_BIN" != "$INSTALL_DIR/${APP_ID}" ]; then
                    cat > /tmp/${APP_ID}-wrapper.sh <<EOF
#!/bin/bash
exec "$ACTUAL_BIN" "\$@"
EOF
                    sudo /bin/mv -f /tmp/${APP_ID}-wrapper.sh "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
                    sudo /bin/chmod +x "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
                fi
            else
                echo "未找到可执行文件" >> "$LOG"
                rm -f "$TMP_APPIMAGE" "$TMP_ZIP"
                rm -rf /tmp/squashfs-root "$TMP_EXTRACT"
                echo "100"; exit 1
            fi

            # 创建 desktop 快捷方式
            cat > /tmp/${APP_ID}.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Exec=$INSTALL_DIR/${APP_ID} %F
Icon=$APP_ID
Terminal=false
Categories=Utility;
EOF
            sudo /bin/mv -f /tmp/${APP_ID}.desktop /usr/share/applications/ 2>>"$LOG"

            # 清理临时文件
            rm -f "$TMP_APPIMAGE" "$TMP_ZIP"
            rm -f "${TMP_TAR:-}"
            rm -rf /tmp/squashfs-root "$TMP_EXTRACT"

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    cursor_api)
        # ─── Cursor 官方 API 下载安装 ─────────────────────────────────────
        API_BASE=$(jq -r '.api_base' "$MANIFEST")
        VERSION=$(jq -r '.version' "$MANIFEST")
        ARCH=$(dpkg --print-architecture)
        ARCH_VAR=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$MANIFEST")
        if [ -z "$ARCH_VAR" ]; then
            zenity --error --title="$NAME" --text="不支持的架构: $ARCH" --width=320
            exit 1
        fi

        INSTALL_DIR="/opt/${APP_ID}"
        API_URL="${API_BASE}/${ARCH_VAR}/cursor/${VERSION}"

        {
            echo "10"
            echo "# 正在获取下载链接..."
            # API 返回 302 重定向，使用 -L 跟随重定向
            TMP_APPIMAGE="/tmp/${APP_ID}.AppImage"
            rm -f "$TMP_APPIMAGE"

            if ! download_with_progress "$API_URL" "$TMP_APPIMAGE" 10 50 "正在下载 $NAME"; then
                echo "100"; exit 1
            fi

            chmod +x "$TMP_APPIMAGE" 2>>"$LOG"

            echo "50"
            echo "# 正在解压 AppImage..."

            cd /tmp
            rm -rf /tmp/squashfs-root /tmp/AppDir
            if ! "$TMP_APPIMAGE" --appimage-extract >/dev/null 2>>"$LOG"; then
                echo "AppImage 解压失败" >> "$LOG"
                rm -f "$TMP_APPIMAGE"
                echo "100"; exit 1
            fi

            EXTRACTED=$(readlink -f /tmp/squashfs-root)

            echo "70"
            echo "# 正在安装..."

            sudo /bin/mkdir -p "$INSTALL_DIR" 2>>"$LOG"
            if ! sudo /bin/mv -f "$EXTRACTED" "$INSTALL_DIR/AppDir" 2>>"$LOG"; then
                echo "移动失败" >> "$LOG"
                rm -f "$TMP_APPIMAGE"
                rm -rf /tmp/squashfs-root
                echo "100"; exit 1
            fi
            sudo /bin/chmod -R a+rX "$INSTALL_DIR/AppDir" 2>>"$LOG" || true
            if [ -x "$INSTALL_DIR/AppDir/cursor" ] && [ ! -x "$INSTALL_DIR/AppDir/usr/share/cursor/cursor" ]; then
                sudo /bin/mv -f "$INSTALL_DIR/AppDir/cursor" "$INSTALL_DIR/AppDir/usr/share/cursor/cursor" 2>>"$LOG" || true
                sudo /bin/chmod +x "$INSTALL_DIR/AppDir/usr/share/cursor/cursor" 2>>"$LOG" || true
            fi

            if [ -x "$INSTALL_DIR/AppDir/AppRun" ]; then
                cat > /tmp/${APP_ID}-wrapper.sh <<EOF
#!/bin/bash
exec "$INSTALL_DIR/AppDir/AppRun" "\$@"
EOF
                sudo /bin/mv -f /tmp/${APP_ID}-wrapper.sh "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
                sudo /bin/chmod +x "$INSTALL_DIR/${APP_ID}" 2>>"$LOG"
            else
                echo "未找到 cursor 可执行文件" >> "$LOG"
                rm -f "$TMP_APPIMAGE"
                rm -rf /tmp/squashfs-root
                echo "100"; exit 1
            fi

            # 创建 desktop 快捷方式
            cat > /tmp/${APP_ID}.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Comment=AI Code Editor
Exec=$INSTALL_DIR/${APP_ID} %F
Icon=$APP_ID
Terminal=false
Categories=IDE;Development;
EOF
            sudo /bin/mv -f /tmp/${APP_ID}.desktop /usr/share/applications/ 2>>"$LOG"

            # 清理临时文件
            rm -f "$TMP_APPIMAGE"
            rm -rf /tmp/squashfs-root

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420
        ;;

    custom_script)
        # ─── 自定义脚本安装 (Hermes, webclaw-upgrader 等) ─────────────────────
        INSTALL_SCRIPT=$(jq -r '.install_script // empty' "$MANIFEST")
        INSTALL_WRAPPER=$(jq -r '.install_wrapper // empty' "$MANIFEST")
        # install_wrapper 优先；没有时直接用 install_script
        [ -z "$INSTALL_WRAPPER" ] && INSTALL_WRAPPER="$INSTALL_SCRIPT"

        if [ -z "$INSTALL_WRAPPER" ] || [ ! -x "$INSTALL_WRAPPER" ]; then
            zenity --error --title="$NAME" \
                --text="未找到安装脚本或脚本不可执行:\n$INSTALL_WRAPPER" \
                --width=420
            exit 1
        fi

        APP_ICON=$(jq -r '.icon // empty' "$MANIFEST")
        ICON_ARG=()
        [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ] && ICON_ARG=("--window-icon=$APP_ICON")

        PROGRESS_FILE="/tmp/${APP_ID}_progress"
        : > "$PROGRESS_FILE"

        {
            echo "5"
            echo "# 正在安装 $NAME..."
            echo "10"
            echo "# 准备安装环境..."

            # 后台运行安装包装脚本（已内置 WEBCLAW_APP_LAUNCHER=1 DISABLE_ZENITY=1）
            sudo "$INSTALL_WRAPPER" >>"$LOG" 2>&1 &
            INSTALL_PID=$!

            # 监控进度文件并实时更新 zenity
            (
                while kill -0 $INSTALL_PID 2>/dev/null; do
                    if [ -f "$PROGRESS_FILE" ]; then
                        PROGRESS=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "30")
                        echo "${PROGRESS}"
                        if [ -f "$PROGRESS_FILE.desc" ]; then
                            DESC=$(cat "$PROGRESS_FILE.desc" 2>/dev/null || echo "安装中...")
                        else
                            case "$PROGRESS" in
                                10|20) DESC="安装依赖..." ;;
                                30|40) DESC="下载安装包..." ;;
                                50|60) DESC="运行安装程序..." ;;
                                70|80) DESC="配置..." ;;
                                90) DESC="收尾..." ;;
                                *) DESC="安装中..." ;;
                            esac
                        fi
                        echo "# $DESC"
                    fi
                    sleep 2
                done
                echo "100"
                echo "# 完成"
                rm -f "$PROGRESS_FILE" "$PROGRESS_FILE.desc" 2>/dev/null || true
            ) &

            wait $INSTALL_PID
            INSTALL_STATUS=$?

            if [ $INSTALL_STATUS -ne 0 ]; then
                echo "安装脚本执行失败" >> "$LOG"
                echo "100"; exit 1
            fi

            echo "100"
            echo "# 完成"
        } | zenity --progress \
            --title="安装 $NAME" \
            --text="准备中..." \
            --percentage=0 --auto-close --no-cancel --width=420 \
            "${ICON_ARG[@]+"${ICON_ARG[@]}"}"
        ;;

    *)
        zenity --error --title="$NAME" \
            --text="未知的 install_method: $INSTALL_METHOD" --width=380
        exit 1
        ;;
esac

# 验证安装结果
if [ "$INSTALL_METHOD" = "appimage" ] || [ "$INSTALL_METHOD" = "r2_download" ] || [ "$INSTALL_METHOD" = "direct_download" ] || [ "$INSTALL_METHOD" = "cursor_api" ] || [ "$INSTALL_METHOD" = "custom_script" ]; then
    # AppImage / r2_download / custom_script: 检查文件是否存在且可执行
    if [ -x "$BIN" ]; then
        INSTALL_OK=1
    else
        INSTALL_OK=0
    fi
else
    # apt/github_release: 检查 dpkg 包
    if dpkg -s "$PKG" 2>/dev/null | grep -q "Status: install ok installed"; then
        INSTALL_OK=1
    else
        INSTALL_OK=0
    fi
fi

if [ "$INSTALL_OK" = 1 ]; then
	    # 在桌面创建图标
	    DESKTOP_DIR="/home/ubuntu/Desktop"
	    DESKTOP_ICON="$DESKTOP_DIR/${APP_ID}.desktop"
	    # 创建桌面图标
	    if [ ! -f "$DESKTOP_ICON" ]; then
	        ICON="/opt/on-demand-icons/${APP_ID}.png"
	        [ ! -e "$ICON" ] && ICON="$APP_ID"

	        cat > "$DESKTOP_ICON" <<EOFICON
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Name[zh_CN]=$NAME
Comment=Launch $NAME
Comment[zh_CN]=启动 $NAME
Exec=/usr/local/bin/webclaw-app-launcher $APP_ID
Icon=$ICON
Terminal=false
StartupNotify=true
EOFICON
	        chown ubuntu:ubuntu "$DESKTOP_ICON" 2>/dev/null || true
	        chmod +x "$DESKTOP_ICON" 2>/dev/null || true
	    fi

	    # 更新应用菜单
	    [ -x /usr/local/bin/update-desktop-icons ] && /usr/local/bin/update-desktop-icons
    zenity --info \
        --title="$NAME" \
        --text="<b>$NAME</b> 安装完成!\n\n再次点击桌面图标即可启动。" \
        --width=360
else
    zenity --error \
        --title="$NAME" \
        --text="安装失败,详细日志:\n$LOG" \
        --width=420
    exit 1
fi
