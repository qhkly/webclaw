#!/bin/bash
# 构建期非交互预装所有按需桌面应用
#
# 用途: 在 Dockerfile.full 里跑一次,把 configs/on-demand-apps/*.json 声明的所有
#       应用按 manifest 装到与 webclaw-app-launcher.sh 期望一致的路径上,这样
#       桌面图标(Exec=webclaw-app-launcher <id>)首次点击就走"已安装→直接 exec"
#       的快速路径,不再弹 zenity 安装框。
#
# 设计要点:
#   - 与 webclaw-app-launcher.sh 共享同一份 manifest /opt/on-demand-apps/*.json
#   - 检测路径与启动器一致(apt: dpkg -s + [-x BIN]; appimage: [-x BIN])
#   - 单个应用失败软兜底,不拖垮整个 docker build;运行时 launcher 仍是 fallback
#   - 构建期以 root 运行,跳过 sudo
#
# 环境变量:
#   - PREINSTALL_SKIP: 逗号分隔的应用 ID 列表,这些应用将被跳过不预装
#                       示例: PREINSTALL_SKIP=android-studio,blender,eclipse
#   - PREINSTALL_ONLY: 逗号分隔的应用 ID 列表,设置后只预装这些应用
#   - PREINSTALL_REQUIRED: 逗号分隔的应用 ID 列表,这些应用预装失败时直接让构建失败
#   - PREINSTALL_MANIFEST_DIR: manifest 目录,默认 /opt/on-demand-apps
#   - PREINSTALL_POSTINSTALL_BIN: 安装后置钩子,默认 /usr/local/bin/webclaw-app-postinstall
#   - PREINSTALL_APT_UPDATE: 是否先 apt-get update,默认 true
#
# 注意: 此脚本只负责装,不修改 .desktop 文件、不动 /usr/local/bin/webclaw-app-launcher。

set -u

# shellcheck source=lib/on-demand-core.sh
source "${WEBCLAW_LIB_DIR:-/opt/lib}/on-demand-core.sh"

MANIFEST_DIR="${PREINSTALL_MANIFEST_DIR:-/opt/on-demand-apps}"
POSTINSTALL_BIN="${PREINSTALL_POSTINSTALL_BIN:-/usr/local/bin/webclaw-app-postinstall}"
ARCH=$(dpkg --print-architecture)

log()  { echo "[preinstall] $*"; }
warn() { echo "[preinstall] WARN: $*" >&2; }

# ── 检查应用是否在跳过列表中 ────────────────────────────────────────
is_skipped() {
    local id="$1"
    local only_list="${PREINSTALL_ONLY:-}"
    if [ -n "$only_list" ]; then
        local only_ids
        IFS=',' read -ra only_ids <<< "$only_list"
        for only_id in "${only_ids[@]}"; do
            only_id=$(echo "$only_id" | xargs)
            if [ "$id" = "$only_id" ]; then
                return 1
            fi
        done
        return 0
    fi

    local skip_list="${PREINSTALL_SKIP:-}"
    if [ -z "$skip_list" ]; then
        return 1  # 不跳过
    fi
    # 将逗号分隔的列表转为空格分隔,然后检查
    local skipped_ids
    IFS=',' read -ra skipped_ids <<< "$skip_list"
    for skipped_id in "${skipped_ids[@]}"; do
        # 去除空格
        skipped_id=$(echo "$skipped_id" | xargs)
        if [ "$id" = "$skipped_id" ]; then
            return 0  # 跳过
        fi
    done
    return 1  # 不跳过
}

is_required() {
    local id="$1"
    local required_list="${PREINSTALL_REQUIRED:-}"
    if [ -z "$required_list" ]; then
        return 1
    fi
    local required_ids
    IFS=',' read -ra required_ids <<< "$required_list"
    for required_id in "${required_ids[@]}"; do
        required_id=$(echo "$required_id" | xargs)
        if [ "$id" = "$required_id" ]; then
            return 0
        fi
    done
    return 1
}

# ── curl 包装函数（带超时和重试）──────────────────────────────────────
curl_retry() {
    curl -fsSL \
        --connect-timeout 10 \
        --max-time 900 \
        --retry 3 \
        --retry-delay 2 \
        --retry-max-time 1800 \
        --speed-limit 1024 \
        --speed-time 30 \
        "$@"
}

# ── 通用重试函数（指数退避）────────────────────────────────────────────
retry_op() {
    local max_attempts=$1
    local initial_delay=$2
    shift 2
    local attempt=1
    local delay=$initial_delay

    while [ "$attempt" -le "$max_attempts" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            warn "重试 $attempt/$max_attempts (等待 ${delay}s)..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# ── 集中刷一次 apt 索引 ──────────────────────────────────────────────
if [ "${PREINSTALL_APT_UPDATE:-true}" != "false" ]; then
    retry_op 3 5 apt-get update || warn "apt-get update 失败,后续 apt 安装可能失败"
fi

get_github_latest_tag() {
    local repo="$1"
    local tag

    tag=$(retry_op 3 5 curl_retry "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -z "$tag" ]; then
        tag=$(retry_op 3 5 curl_retry -I "https://github.com/${repo}/releases/latest" \
            | awk 'BEGIN{IGNORECASE=1} /^location:/ {gsub("\r","",$2); location=$2} END{sub(".*/tag/","",location); print location}')
    fi

    echo "$tag"
}

replace_release_tokens() {
    local template="$1"
    local version="$2"
    local arch="$3"
    local arch_suffix="${4:-$3}"
    local version_no_v="${version#v}"

    template=${template//\{version_no_v\}/$version_no_v}
    template=${template//\{version\}/$version}
    template=${template//\{arch_suffix\}/$arch_suffix}
    template=${template//\{arch\}/$arch}
    echo "$template"
}

get_version_from_api() {
    local version_api="$1"
    if [[ "$version_api" == file:///* ]]; then
        local script_path="${version_api#file://}"
        retry_op 3 5 "$script_path" | jq -r '.version // .latest // empty' 2>/dev/null
    else
        retry_op 3 5 curl_retry "$version_api" | jq -r '.version // .latest // empty' 2>/dev/null
    fi
}

# ── apt 模式 ────────────────────────────────────────────────────────
preinstall_apt() {
    local id="$1" manifest="$2"
    local apt_pkg install_script
    apt_pkg=$(jq -r '.apt_package' "$manifest")
    install_script=$(jq -r '.install_script // empty' "$manifest")

    # 如果有 install_script，先执行（用于添加仓库密钥等）
    if [ -n "$install_script" ] && [ -x "$install_script" ]; then
        log "$id: 执行安装脚本 $install_script"
        retry_op 3 5 "$install_script" || {
            warn "$id: 安装脚本执行失败"
            return 1
        }
    fi

    log "$id: apt install $apt_pkg"

    # Wireshark 装前预设 dumpcap setuid 不询问
    if [ "$apt_pkg" = "wireshark" ]; then
        echo "wireshark-common wireshark-common/setuid boolean true" | debconf-set-selections
    fi

    retry_op 3 5 apt-get install -y "$apt_pkg" || {
        warn "$id: apt install 失败"
        return 1
    }

    # Wireshark 装后给 dumpcap 抓包能力 + 把 ubuntu 加入 wireshark 组
    if [ "$apt_pkg" = "wireshark" ]; then
        # 先确保 wireshark 组存在（某些情况下 apt 安装不会自动创建）
        groupadd -f wireshark
        usermod -a -G wireshark ubuntu || warn "$id: usermod failed"
        setcap cap_net_raw,cap_net_admin=ep /usr/bin/dumpcap || warn "$id: setcap failed"
        if [ -f /usr/share/applications/org.wireshark.Wireshark.desktop ] \
            && [ -f /opt/on-demand-icons/wireshark.png ]; then
            sed -i 's|^Icon=.*|Icon=/opt/on-demand-icons/wireshark.png|' \
                /usr/share/applications/org.wireshark.Wireshark.desktop
            rm -f /usr/share/applications/wireshark.desktop
            update-desktop-database /usr/share/applications 2>/dev/null || true
        fi
    fi
}

# ── github_release(.deb) 模式 ──────────────────────────────────────
preinstall_github_release() {
    local id="$1" manifest="$2"
    local repo pattern arch_var version tag asset url deb

    repo=$(jq -r '.github_repo' "$manifest")
    pattern=$(jq -r '.asset_pattern' "$manifest")
    arch_var=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$manifest")

    if [ -z "$arch_var" ]; then
        log "$id: arch=$ARCH 不在 arch_map 中,跳过"
        return 0
    fi

    if [ "$(jq -r '.use_fixed_version // false' "$manifest")" = "true" ]; then
        tag=$(jq -r '.version // empty' "$manifest")
    else
        tag=$(get_github_latest_tag "$repo")
    fi
    if [ -z "$tag" ]; then
        warn "$id: 拿不到最新版本号,跳过"
        return 1
    fi
    version="${tag#v}"

    asset=$(replace_release_tokens "$pattern" "$tag" "$arch_var")
    url="https://github.com/${repo}/releases/download/${tag}/${asset}"
    deb="/tmp/preinstall-${id}.deb"

    log "$id: 下载 $url"
    rm -f "$deb"
    if ! retry_op 3 5 curl_retry "$url" -o "$deb"; then
        warn "$id: 下载失败"
        return 1
    fi

    log "$id: apt install .deb"
    retry_op 3 5 apt-get install -y "$deb" || {
        warn "$id: apt install .deb 失败"
        rm -f "$deb"
        return 1
    }
    rm -f "$deb"
}

# ── AppImage 解压辅助函数 ─────────────────────────────────────────────────
# 先尝试 --appimage-extract; 跨架构构建时 (arm64 on amd64 via QEMU) 回退到 unsquashfs。
# 参数: <appimage_path> <dest_dir>
# 成功时 dest_dir 包含解压内容; 返回 0。
try_extract_appimage() {
    local appimage="$1" dest="$2"
    rm -rf "$dest" /tmp/squashfs-root /tmp/AppDir

    # 方法1: 标准自解压
    if ( cd /tmp && "$appimage" --appimage-extract >/dev/null 2>&1 ); then
        mv -f "$(readlink -f /tmp/squashfs-root)" "$dest"
        chmod -R a+rX "$dest"
        rm -rf /tmp/squashfs-root
        return 0
    fi

    # 方法2: unsquashfs 直接提取 squashfs（适用于跨架构构建）
    if ! command -v unsquashfs >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends squashfs-tools >/dev/null 2>&1 || true
    fi
    if command -v unsquashfs >/dev/null 2>&1; then
        local offset
        # 定位 squashfs 魔数: 'sqsh'(大端) 或 'hsqs'(小端)。
        # GNU grep 默认会把 AppImage 视为二进制文件并只输出
        # "Binary file ... matches"，必须用 -a 才能拿到可传给 unsquashfs 的 offset。
        offset=$(LC_ALL=C grep -abo -m1 -e 'sqsh' -e 'hsqs' "$appimage" 2>/dev/null \
                 | head -1 | cut -d: -f1)
        [ -z "$offset" ] && offset=188   # AppImage type 2 默认偏移
        if [[ "$offset" =~ ^[0-9]+$ ]] && unsquashfs -no-progress -offset "$offset" -d "$dest" "$appimage" >/dev/null 2>&1; then
            chmod -R a+rX "$dest"
            return 0
        fi
    fi

    return 1
}

# ── appimage 模式 ───────────────────────────────────────────────────
preinstall_appimage() {
    local id="$1" manifest="$2"
    local repo pattern arch_var tag version asset url tmp extract_dir unbundle_gl bin

    repo=$(jq -r '.github_repo' "$manifest")
    pattern=$(jq -r '.asset_pattern' "$manifest")
    arch_var=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$manifest")
    unbundle_gl=$(jq -r '.unbundle_gl // false' "$manifest")
    bin=$(jq -r '.binary' "$manifest")

    # arch_map 里登记了但 value 为空字符串(如 obsidian amd64="")也是合法的
    if ! jq -e --arg a "$ARCH" '.arch_map | has($a)' "$manifest" >/dev/null; then
        log "$id: arch=$ARCH 不在 arch_map 中,跳过"
        return 0
    fi

    tag=$(get_github_latest_tag "$repo")
    if [ -z "$tag" ]; then
        warn "$id: 拿不到最新版本号,跳过"
        return 1
    fi
    version="${tag#v}"

    asset=$(replace_release_tokens "$pattern" "$version" "$arch_var" "$arch_var")
    local download_url="https://github.com/${repo}/releases/download/${tag}/${asset}"

    extract_dir="/opt/ondemand-apps/${id}"
    tmp="/tmp/preinstall-${id}.AppImage"

    rm -f "$tmp"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    # 使用 GitHub API 下载（更可靠，避免 404）
    if ! github_api_download "$repo" "$asset" "$tmp"; then
        # API 下载失败，尝试直接下载
        log "$id: API 下载失败，尝试直接下载 $download_url"
        if ! retry_op 3 5 curl_retry "$download_url" -o "$tmp"; then
            warn "$id: 下载失败"
            return 1
        fi
    fi
    chmod +x "$tmp"

    log "$id: 解压 AppImage"
    if ! try_extract_appimage "$tmp" "$extract_dir/AppDir"; then
        warn "$id: AppImage 解压失败（--appimage-extract 和 unsquashfs 均失败）"
        rm -f "$tmp"
        return 1
    fi

    # 可选: 把 AppImage 自带的旧 Mesa GL 库换成系统 Mesa 软链
    # (与 webclaw-app-launcher.sh:227-246 保持一致)
    if [ "$unbundle_gl" = "true" ]; then
        log "$id: 卸绑 AppImage 自带 GL 库"
        local libd="$extract_dir/AppDir/shared/lib"
        local sysd
        sysd="/usr/lib/$(gcc -print-multiarch 2>/dev/null || dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
        if [ -d "$libd" ]; then
            mkdir -p "$libd/.gl-bundled-bak"
            local pat f
            for pat in libEGL libGL libGLX libGLES libGLdispatch libgbm; do
                for f in "$libd/${pat}"*; do
                    [ -e "$f" ] || continue
                    case "$f" in *.gl-bundled-bak*) continue ;; esac
                    mv -f "$f" "$libd/.gl-bundled-bak/" || true
                done
            done
            local name
            for name in libEGL.so.1 libGL.so.1 libGLX.so.0 libGLdispatch.so.0 \
                        libGLX_mesa.so.0 libEGL_mesa.so.0 libgbm.so.1 libGLESv2.so.2; do
                [ -e "$sysd/$name" ] && ln -sfn "$sysd/$name" "$libd/$name"
            done
        fi
    fi

    if [ ! -x "$bin" ] && [ -x "$extract_dir/AppDir/$(basename "$bin")" ]; then
        ln -sfn "$extract_dir/AppDir/$(basename "$bin")" "$bin"
    fi

    rm -f "$tmp"
}

# ── cursor_api 模式 (Cursor 编辑器) ─────────────────────────────────────
preinstall_cursor_api() {
    local id="$1" manifest="$2"
    local api_base arch_var version api_url install_dir tmp app_dir

    api_base=$(jq -r '.api_base' "$manifest")
    arch_var=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$manifest")

    if [ -z "$arch_var" ]; then
        log "$id: arch=$ARCH 不在 arch_map 中,跳过"
        return 0
    fi

    # 动态获取最新版本
    version=$(retry_op 3 5 curl_retry "https://api2.cursor.sh/updates/latest" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [ -z "$version" ]; then
        # 如果动态获取失败,使用 manifest 中硬编码的版本
        version=$(jq -r '.version' "$manifest")
        log "$id: 使用硬编码版本 $version"
    else
        log "$id: 获取到最新版本 $version"
    fi

    install_dir="/opt/${id}"
    api_url="${api_base}/${arch_var}/cursor/${version}"
    tmp="/tmp/preinstall-${id}.AppImage"

    log "$id: 下载 $api_url"
    rm -f "$tmp"
    rm -rf "$install_dir"
    mkdir -p "$install_dir"

    if ! retry_op 3 5 curl_retry "$api_url" -o "$tmp"; then
        warn "$id: 下载失败"
        return 1
    fi
    chmod +x "$tmp"

    log "$id: 解压 AppImage"
    app_dir="$install_dir/AppDir"
    if ! try_extract_appimage "$tmp" "$app_dir"; then
        warn "$id: AppImage 解压失败（--appimage-extract 和 unsquashfs 均失败）"
        rm -f "$tmp"
        return 1
    fi
    if [ -x "$app_dir/cursor" ] && [ ! -x "$app_dir/usr/share/cursor/cursor" ]; then
        mv -f "$app_dir/cursor" "$app_dir/usr/share/cursor/cursor"
        chmod +x "$app_dir/usr/share/cursor/cursor"
    fi
    cat > "$install_dir/cursor" <<EOF
#!/bin/bash
exec "$app_dir/AppRun" "\$@"
EOF
    chmod +x "$install_dir/cursor"

    rm -f "$tmp"
    rm -rf /tmp/squashfs-root /tmp/AppDir
}

# ── direct_download 模式 (webclaw-launcher 等) ─────────────────────────
preinstall_direct_download() {
    local id="$1" manifest="$2"
    local download_url version_api arch_var arch_suffix version install_dir tmp jetbrains_code unsupported_arch bin pkg candidate_name

    pkg=$(jq -r '.package' "$manifest")
    download_url=$(jq -r '.download_url' "$manifest")
    version_api=$(jq -r '.version_api // empty' "$manifest")
    bin=$(jq -r '.binary' "$manifest")
    arch_var=$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$manifest")
    arch_suffix=$(jq -r --arg a "$ARCH" --arg fallback "$arch_var" '.arch_suffix_map[$a] // $fallback // empty' "$manifest")
    jetbrains_code=$(jq -r '.jetbrains_code // empty' "$manifest")

    for unsupported_arch in $(jq -r '.unsupported_archs // [] | .[]' "$manifest" 2>/dev/null); do
        if [ "$ARCH" = "$unsupported_arch" ]; then
            log "$id: arch=$ARCH 不受支持,跳过"
            return 0
        fi
    done

    if [ -z "$arch_var" ] && [ -z "$arch_suffix" ]; then
        log "$id: arch=$ARCH 不在 arch_map 中,跳过"
        return 0
    fi

    # 如果提供了 version_api，先获取版本号
    if [ -n "$version_api" ]; then
        version=$(get_version_from_api "$version_api")
        if [ -z "$version" ]; then
            warn "$id: 无法获取版本号"
            return 1
        fi
        log "$id: 获取到版本 $version"
    else
        version=$(jq -r '.version // empty' "$manifest")
    fi

    if [ -n "$jetbrains_code" ]; then
        local jb_api_resp direct_url
        jb_api_resp=$(retry_op 3 5 curl_retry "https://data.services.jetbrains.com/products/releases?code=${jetbrains_code}&latest=true&type=release")
        if [ -z "$version" ]; then
            version=$(echo "$jb_api_resp" | jq -r ".[\"${jetbrains_code}\"][0].version // empty" 2>/dev/null)
        fi
        if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
            direct_url=$(echo "$jb_api_resp" | jq -r ".[\"${jetbrains_code}\"][0].downloads.linuxARM64.link // empty" 2>/dev/null)
        else
            direct_url=$(echo "$jb_api_resp" | jq -r ".[\"${jetbrains_code}\"][0].downloads.linux.link // empty" 2>/dev/null)
        fi
        if [ -n "$direct_url" ] && [ "$direct_url" != "null" ]; then
            download_url="$direct_url"
        fi
        log "$id: JetBrains ${jetbrains_code} version=${version}"
    fi

    if [ -z "$version" ] && [[ "$download_url" == *"{version}"* ]]; then
        warn "$id: 无法获取版本号"
        return 1
    fi

    # 替换 URL 中的占位符
    download_url=$(replace_release_tokens "$download_url" "$version" "$arch_var" "$arch_suffix")

    install_dir="/opt/${id}"
    tmp="/tmp/preinstall-${id}"

    log "$id: 下载 $download_url"
    rm -f "$tmp".*

    # 检测文件类型
    local file_type="unknown"
    if [[ "$download_url" == *".AppImage"* ]] || [[ "$download_url" == *"appimage"* ]]; then
        file_type="appimage"
    elif [[ "$download_url" == *".zip"* ]]; then
        file_type="zip"
    elif [[ "$download_url" == *".tar.gz"* ]]; then
        file_type="tar.gz"
    elif [[ "$download_url" == *".deb"* ]]; then
        file_type="deb"
    fi

    # GitHub URL 使用 API 下载
    if [[ "$download_url" == *"github.com"* ]] && [[ "$download_url" == *"/releases/download/"* ]]; then
        local asset_name
        asset_name=$(basename "$download_url")
        if ! github_api_download "$(echo "$download_url" | sed 's|.*github.com/\([^/]*\)/\([^/]*\)/releases/download/.*|\1/\2|')" "$asset_name" "${tmp}.${file_type}"
        then
            # API 下载失败,尝试直接下载
            if ! retry_op 3 5 curl_retry "$download_url" -o "${tmp}.${file_type}"; then
                warn "$id: 下载失败"
                return 1
            fi
        fi
    else
        # 非 GitHub URL,直接下载
        if ! retry_op 3 5 curl_retry -L "$download_url" -o "${tmp}.${file_type}"; then
            warn "$id: 下载失败"
            return 1
        fi
    fi

    if [ "$file_type" != "deb" ]; then
        rm -rf "$install_dir"
        mkdir -p "$install_dir"
    fi

    case "$file_type" in
        appimage)
            log "$id: 解压 AppImage"
            chmod +x "${tmp}.${file_type}"
            if ! try_extract_appimage "${tmp}.${file_type}" "$install_dir/AppDir"; then
                warn "$id: AppImage 解压失败"
                rm -f "${tmp}.${file_type}"
                return 1
            fi
            ;;
        zip)
            log "$id: 解压 zip"
            local extract_tmp appimage_file
            extract_tmp="/tmp/preinstall-${id}-extract"
            rm -rf "$extract_tmp"
            mkdir -p "$extract_tmp"
            if ! unzip -q "${tmp}.zip" -d "$extract_tmp"; then
                warn "$id: zip 解压失败"
                rm -f "${tmp}.zip"
                rm -rf "$extract_tmp"
                return 1
            fi

            appimage_file=$(find "$extract_tmp" -maxdepth 2 -type f -name "*.AppImage" | head -1)
            if [ -n "$appimage_file" ]; then
                chmod +x "$appimage_file"
                if ! try_extract_appimage "$appimage_file" "$install_dir/AppDir"; then
                    warn "$id: AppImage 解压失败"
                    rm -f "${tmp}.zip"
                    rm -rf "$extract_tmp"
                    return 1
                fi
            else
                mv "$extract_tmp"/* "$install_dir/"
            fi

            # 如果 zip 里有单层目录,把内容提出来
            local files
            files=("$install_dir"/*)
            if [ "${#files[@]}" -eq 1 ] && [ -d "${files[0]}" ] && [ "$(basename "${files[0]}")" != "AppDir" ]; then
                mv "${files[0]}"/* "$install_dir/"
                rmdir "${files[0]}"
            fi
            rm -rf "$extract_tmp"
            ;;
        tar.gz)
            log "$id: 解压 tar.gz"
            local extract_tmp extracted_dir extracted_file
            extract_tmp="/tmp/preinstall-${id}-extract"
            rm -rf "$extract_tmp"
            mkdir -p "$extract_tmp"
            if ! tar -xzf "${tmp}.tar.gz" -C "$extract_tmp"; then
                warn "$id: tar.gz 解压失败"
                rm -f "${tmp}.tar.gz"
                rm -rf "$extract_tmp"
                return 1
            fi

            extracted_dir=$(find "$extract_tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
            extracted_file=$(find "$extract_tmp" -mindepth 1 -maxdepth 1 -type f -perm -111 | head -1)
            if [ -n "$extracted_dir" ]; then
                mv "$extracted_dir"/* "$install_dir/"
            elif [ -n "$extracted_file" ]; then
                mv -f "$extracted_file" "$install_dir/${id}"
                chmod +x "$install_dir/${id}"
            else
                warn "$id: tar.gz 中未找到目录或可执行文件"
                rm -f "${tmp}.tar.gz"
                rm -rf "$extract_tmp"
                return 1
            fi
            rm -rf "$extract_tmp"
            ;;
        deb)
            log "$id: apt install .deb"
            if ! retry_op 3 5 apt-get install -y "${tmp}.deb"; then
                warn "$id: apt install .deb 失败"
                rm -f "${tmp}.deb"
                return 1
            fi
            ;;
        *)
            warn "$id: 未知文件类型: $file_type"
            rm -f "${tmp}".*
            return 1
            ;;
    esac

    if [ ! -x "$bin" ] && [ -x "$install_dir/AppDir/AppRun" ]; then
        mkdir -p "$(dirname "$bin")"
        cat > "$bin" <<EOF
#!/bin/bash
exec "$install_dir/AppDir/AppRun" "\$@"
EOF
        chmod +x "$bin"
    elif [ ! -x "$bin" ] && [ -x "$install_dir/${id}" ]; then
        mkdir -p "$(dirname "$bin")"
        ln -sfn "$install_dir/${id}" "$bin"
    elif [ ! -x "$bin" ] && [ "$file_type" = "deb" ]; then
        local actual_bin
        actual_bin=$(dpkg -L "$pkg" 2>/dev/null | while IFS= read -r candidate; do
            [ -f "$candidate" ] && [ -x "$candidate" ] || continue
            candidate_name=$(basename "$candidate")
            if [ "$candidate_name" = "$id" ] || [ "$candidate_name" = "$pkg" ] || [[ "$candidate_name" == *.sh ]]; then
                echo "$candidate"
                break
            fi
        done)
        if [ -z "$actual_bin" ]; then
            actual_bin=$(find /usr/bin /usr/share /opt -type f -perm -111 -path "*${id}*" 2>/dev/null | head -1)
        fi
        if [ -n "$actual_bin" ]; then
            mkdir -p "$(dirname "$bin")"
            ln -sfn "$actual_bin" "$bin"
        fi
    fi

    rm -f "${tmp}".*
}

# ── GitHub API 下载辅助函数 ───────────────────────────────────────────
# 直接访问 GitHub releases URL 可能返回 404,通过 API 下载更可靠
github_api_download() {
    local repo="$1"
    local asset_name="$2"
    local output="$3"

    log "通过 GitHub API 下载 $asset_name"

    # 获取 asset 的 API URL
    local asset_url
    asset_url=$(retry_op 3 5 curl_retry "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .url')

    if [ -z "$asset_url" ]; then
        warn "未找到 asset: $asset_name"
        return 1
    fi

    # 使用 API 下载（需要 Accept: application/octet-stream header）
    if ! retry_op 3 5 curl_retry -H "Accept: application/octet-stream" "$asset_url" -o "$output"; then
        warn "GitHub API 下载失败: $asset_name"
        return 1
    fi

    return 0
}

# ── 检测应用是否已装,跳过 ───────────────────────────────────────────
already_installed() { webclaw_app_installed "$@"; }

preinstall_custom_script() {
    local id="$1" manifest="$2" script
    script="$(jq -r '.install_script // empty' "$manifest")"
    if [ -z "$script" ] || [ ! -f "$script" ]; then
        warn "$id: install_script 不存在: $script"
        return 1
    fi
    WEBCLAW_DOCKER_BUILD=1 DISABLE_ZENITY=1 bash "$script"
}

# ── 主循环 ──────────────────────────────────────────────────────────
shopt -s nullglob
for manifest in "$MANIFEST_DIR"/*.json; do
    id=$(jq -r '.id' "$manifest")
    pkg=$(jq -r '.package' "$manifest")
    bin=$(jq -r '.binary' "$manifest")
    install_method=$(jq -r '.install_method // "github_release"' "$manifest")

    # 检查是否在跳过列表中
    if is_skipped "$id"; then
        log "$id: 在跳过列表中,跳过预装 (运行时仍可按需安装)"
        continue
    fi

    if already_installed "$install_method" "$pkg" "$bin"; then
        log "$id: 已安装,跳过"
        continue
    fi

    installed=false
    case "$install_method" in
        apt)             preinstall_apt             "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        github_release)  preinstall_github_release  "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        appimage)        preinstall_appimage        "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        cursor_api)      preinstall_cursor_api      "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        direct_download) preinstall_direct_download "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        custom_script)   preinstall_custom_script   "$id" "$manifest" && installed=true || warn "$id: 预装失败,运行时按需安装可兜底" ;;
        *)               warn "$id: 未知 install_method=$install_method,跳过" ;;
    esac

    if [ "$installed" != "true" ] && is_required "$id"; then
        echo "[preinstall] ERROR: $id 是必装应用,预装失败,终止构建" >&2
        exit 1
    fi

    if [ "$installed" = "true" ] && [ -x "$POSTINSTALL_BIN" ]; then
        "$POSTINSTALL_BIN" "$id" || true
    fi
done

log "完成,清理 apt 缓存"
apt-get clean
rm -rf /var/lib/apt/lists/*
