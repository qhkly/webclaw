#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-app-admin —— 按需安装的 root 受控执行器（broker）。
#  安装位置：/usr/local/bin/webclaw-app-admin（root:root 0755）
#  sudoers 只放行这一个入口：ubuntu ALL=(root) NOPASSWD: /usr/local/bin/webclaw-app-admin
#
#  设计原则：调用方只能给「动作 + app_id (+ 固定枚举)」。
#    - 所有源/目标路径都由 app_id 推导，调用方不能传任意路径；
#    - 允许的包名、安装方式、预置脚本全部来自 root 所有、不可被 ubuntu 写的
#      /opt/on-demand-apps/<app_id>.json（manifest 本身就是白名单）；
#    - 用户放在 /tmp 的下载/解压结果先原子 rename 进 root 私有目录，再在那里校验
#      （不是符号链接、属主是调用者、没有硬链接/设备文件），避免 TOCTOU。
#
#  动作：
#    log-prepare  <id>                       准备 /tmp/webclaw-ondemand-<id>.log
#    apt-prepare  <id>                       运行 manifest 声明的 root 预置脚本（加 apt 源等）
#    apt-install  <id>                       apt-get update + install manifest 的 apt_package + postinstall
#    deb-url      <id>                       打印 broker 会下载的 .deb 地址（只读，便于排查）
#    deb-install  <id>                       root 自己按 manifest 下载 .deb 到私有目录并安装
#                                            （Package 必须等于 manifest.package；绝不读取用户提供的 .deb）
#    install-tree <id> appdir|flat|binary    把 /tmp/webclaw-stage-<id> 装进该应用的受管目录
#    wrapper      <id> <受管目录内的可执行文件>  生成 <受管目录>/<id> 启动脚本
#    desktop      <id>                       生成 /usr/share/applications/<id>.desktop
#    postinstall  <id>                       webclaw-app-postinstall
#    uninstall    <id>                       webclaw-app-uninstaller
#
#  .deb 的 maintainer script 以 root 运行，所以 .deb 必须来自 manifest 声明的来源：
#  broker 自己按 manifest 推导 URL、以 root 下载到私有目录，从不接收用户放在 /tmp 的包。
#  剩余信任在上游本身（GitHub release / 官方下载地址），与 apt 源同一级别。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

# 硬编码：安全关键路径不接受任何环境变量覆盖。
MANIFEST_DIR=/opt/on-demand-apps
STAGE_ROOT=/opt/.webclaw-app-admin
USER_NAME=ubuntu

die() { echo "[webclaw-app-admin] 拒绝：$*" >&2; exit 2; }
log() { echo "[webclaw-app-admin] $*" >&2; }

[ "$(id -u)" = 0 ] || die "必须通过 sudo 以 root 运行"

# 调用者：sudo 过来的是 SUDO_UID；root 直接调用（构建期/运维）视为 ubuntu。
CALLER_UID="${SUDO_UID:-$(id -u "$USER_NAME")}"
[[ "$CALLER_UID" =~ ^[0-9]+$ ]] || die "SUDO_UID 非法"
[ "$CALLER_UID" = 0 ] && CALLER_UID="$(id -u "$USER_NAME")"

# 文件/目录必须 root 所有、非符号链接、group/other 不可写。
assert_root_owned() {
    local p="$1"
    [ -e "$p" ] && [ ! -L "$p" ] || die "$p 不存在或是符号链接"
    [ "$(stat -c %u "$p")" = 0 ] || die "$p 不是 root 所有"
    [ -z "$(find "$p" -maxdepth 0 -perm /022 2>/dev/null)" ] || die "$p 可被 group/other 写"
}

ACTION="${1:-}"
APP_ID="${2:-}"
[ -n "$ACTION" ] || die "缺少动作"

# app_id：小写字母数字开头，只含 [a-z0-9._-]，不含 ..，长度 ≤ 64。
[[ "$APP_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [[ "$APP_ID" != *..* ]] || die "非法 app_id：$APP_ID"
# 这些名字在 /opt 下是系统目录，就算有同名 manifest 也不能当安装目录。
case "$APP_ID" in
    lib|webclaw|nvm-seed|install-scripts|on-demand-apps|on-demand-icons|ondemand-apps|\
    code-server|code-server-extensions|dashboard-override|noVNC|novnc|mihomo|v2rayN|v2rayn|\
    skills|desktop-shortcuts|desktop-icons|containerd|.webclaw-app-admin)
        die "保留名：$APP_ID" ;;
esac

MANIFEST="$MANIFEST_DIR/${APP_ID}.json"
assert_root_owned "$MANIFEST_DIR"
assert_root_owned "$MANIFEST"
mf() { jq -r "$1" "$MANIFEST"; }
METHOD="$(mf '.install_method // "github_release"')"

# 受管安装根目录，完全由 app_id + manifest 推导。
app_root() {
    case "$METHOD" in
        appimage) echo "/opt/ondemand-apps/$APP_ID" ;;
        r2_download|direct_download|cursor_api) echo "/opt/$APP_ID" ;;
        *) die "$APP_ID 的安装方式 $METHOD 没有受管目录" ;;
    esac
}

require_method() {
    local m
    for m in "$@"; do [ "$METHOD" = "$m" ] && return 0; done
    die "$APP_ID 的安装方式是 $METHOD，不允许执行 $ACTION"
}

# 把调用者放在 /tmp 的东西原子 rename 进 root 私有目录，之后只对搬进来的对象做校验。
# rename 不跟随符号链接：源若是符号链接，搬进来的也只是符号链接本身，随后被拒绝。
take_from_tmp() {
    local src="$1" dest
    [ -e "$src" ] || [ -L "$src" ] || die "$src 不存在"
    mkdir -p "$STAGE_ROOT"
    chown root:root "$STAGE_ROOT"
    chmod 700 "$STAGE_ROOT"
    dest="$(mktemp -d "$STAGE_ROOT/${APP_ID}.XXXXXX")"
    mv -T -- "$src" "$dest/item" || { rm -rf "$dest"; die "无法接管 $src"; }
    echo "$dest"
}

# 在树内逐跳解析一个符号链接，模拟内核的路径解析，但把 ".." 限制在树根以内：
# 任何一跳越过树根就算逃逸，哪怕之后又绕回来（装到 /opt 后同一路径会指向别处）。
#   $1 = 树根；$2 = 链接相对树根的路径。成功 = 最终落点在树内（允许悬空，悬空也在树内）。
# 失败情形：绝对 target、空 target、含换行、越过树根、超过 40 跳（循环）。
resolve_link_in_tree() {
    local root="$1" rel="$2" target c hops=0
    local -a stack=() todo=() parts=()
    if [ "$(dirname "$rel")" != . ]; then
        IFS=/ read -r -a stack <<< "$(dirname "$rel")"
    fi
    target="$(readlink -- "$root/$rel")"
    [[ -n "$target" && "$target" != /* && "$target" != *$'\n'* ]] || return 1
    IFS=/ read -r -a todo <<< "$target"
    while [ "${#todo[@]}" -gt 0 ]; do
        c="${todo[0]}"
        todo=("${todo[@]:1}")
        case "$c" in
            ""|.) continue ;;
            ..)
                [ "${#stack[@]}" -gt 0 ] || return 1
                unset 'stack[-1]'
                continue
                ;;
        esac
        stack+=("$c")
        if [ -L "$root/$(IFS=/; echo "${stack[*]}")" ]; then
            hops=$((hops + 1))
            [ "$hops" -le 40 ] || return 1
            target="$(readlink -- "$root/$(IFS=/; echo "${stack[*]}")")"
            [[ -n "$target" && "$target" != /* && "$target" != *$'\n'* ]] || return 1
            unset 'stack[-1]'
            IFS=/ read -r -a parts <<< "$target"
            todo=("${parts[@]}" "${todo[@]}")
        fi
    done
    return 0
}

# 校验接管来的树（此时已在 root 私有的 0700 目录里，调用者碰不到，没有竞态）：
#   - 顶层不能是符号链接；
#   - 树内符号链接只允许「相对、且逐跳解析都不离开树根」的（AppImage/JetBrains 的库链接）；
#     绝对链接、../ 逃逸、链式最终逃逸、循环一律拒绝；
#   - 每个条目都属于调用者；没有多链接的普通文件（防硬链接到系统文件）；
#   - 没有设备/管道/套接字；文件名不含换行。
validate_tree() {
    local item="$1" kind="$2" bad link
    [ ! -L "$item" ] || die "源是符号链接"
    case "$kind" in
        dir)  [ -d "$item" ] || die "源不是目录" ;;
        file) [ -f "$item" ] || die "源不是普通文件" ;;
    esac
    bad="$(find "$item" -xdev \( ! -uid "$CALLER_UID" -o \( -type f -links +1 \) \
            -o -type b -o -type c -o -type p -o -type s -o -name $'*\n*' \) -print -quit)"
    [ -z "$bad" ] || die "源里有不属于调用者的条目、硬链接、特殊文件或非法文件名：${bad#"$item"}"
    while IFS= read -r -d '' link; do
        resolve_link_in_tree "$item" "${link#"$item"/}" \
            || die "符号链接越界或无法安全解析：${link#"$item"/} -> $(readlink -- "$link")"
    done < <(find "$item" -xdev -type l -print0)
}

# 原子写一个 root 所有的小文件（先写同目录临时文件再 rename，不跟随目标处的符号链接）。
write_root_file() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp "$(dirname "$dest")/.webclaw-app-admin.XXXXXX")"
    cat > "$tmp"
    chown root:root "$tmp"
    chmod "$mode" "$tmp"
    mv -Tf -- "$tmp" "$dest"
}

# ─── .deb 来源：只从 root 所有的 manifest 推导 ───────────────────────
deb_arch_var() {
    local arch
    arch="$(dpkg --print-architecture)"
    jq -r --arg a "$arch" '.arch_map[$a] // empty' "$MANIFEST"
}

github_latest_tag() {
    local repo="$1" tag
    tag="$(curl -fsSL --max-time 30 --proto =https "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null || true)"
    if [ -z "$tag" ]; then
        tag="$(curl -fsSIL --max-time 30 --proto =https --proto-redir =https "https://github.com/${repo}/releases/latest" \
            | awk 'BEGIN{IGNORECASE=1} /^location:/ {gsub("\r","",$2); l=$2} END{sub(".*/tag/","",l); print l}')"
    fi
    echo "$tag"
}

# 允许的来源：https://，或指向 root 所有且整条路径不可被他人写的 file://（测试/离线镜像用）。
check_deb_url() {
    local url="$1" path p
    local url_re='^[A-Za-z0-9:/._~%+=?&@,-]+$'
    [[ "$url" =~ $url_re ]] || die "下载地址含非法字符：$url"
    case "$url" in
        https://*) ;;
        file:///*)
            path="${url#file://}"
            [[ "$path" != *..* ]] || die "file:// 路径不能含 ..：$url"
            p="$path"
            while [ "$p" != / ]; do assert_root_owned "$p"; p="$(dirname "$p")"; done
            ;;
        *) die "只允许 https:// 或 root 所有的 file:// 来源：$url" ;;
    esac
}

resolve_deb_url() {
    local arch_var url version repo asset suffix
    arch_var="$(deb_arch_var)"
    [ -n "$arch_var" ] || die "manifest 没有为当前架构 $(dpkg --print-architecture) 声明 arch_map"
    case "$METHOD" in
        github_release)
            repo="$(mf '.github_repo // empty')"
            [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "manifest 里的 github_repo 非法：$repo"
            if [ "$(mf '.use_fixed_version // false')" = true ]; then
                version="$(mf '.version // empty')"
            else
                version="$(github_latest_tag "$repo")"
            fi
            [[ "$version" =~ ^[A-Za-z0-9._+-]+$ ]] || die "拿不到合法的版本号：$version"
            asset="$(mf '.asset_pattern // empty')"
            asset="${asset//\{version_no_v\}/${version#v}}"
            asset="${asset//\{version\}/$version}"
            asset="${asset//\{arch\}/$arch_var}"
            url="https://github.com/${repo}/releases/download/${version}/${asset}"
            ;;
        direct_download)
            url="$(mf '.download_url // empty')"
            suffix="$(jq -r --arg a "$(dpkg --print-architecture)" --arg f "$arch_var" '.arch_suffix_map[$a] // $f' "$MANIFEST")"
            url="${url//\{arch\}/$arch_var}"
            url="${url//\{arch_suffix\}/$suffix}"
            ;;
        *) die "$APP_ID 不是 .deb 安装方式" ;;
    esac
    [[ "$url" != *"{"* ]] || die "下载地址里还有未支持的占位符：$url"
    [[ "$url" == *.deb* ]] || die "下载地址不是 .deb：$url"
    check_deb_url "$url"
    echo "$url"
}

case "$ACTION" in
    log-prepare)
        log_file="/tmp/webclaw-ondemand-${APP_ID}.log"
        # /tmp 有 sticky 位，但仍防一手：已有的符号链接直接删掉再建。
        rm -f -- "$log_file"
        install -m 644 -o "$CALLER_UID" -g "$CALLER_UID" /dev/null "$log_file"
        ;;

    apt-prepare)
        require_method apt
        script="$(mf '.install_script // empty')"
        [ -n "$script" ] || exit 0
        [[ "$script" =~ ^(/usr/local/bin/[A-Za-z0-9._-]+|/opt/[A-Za-z0-9._-]+\.sh)$ ]] || die "预置脚本路径不在允许范围：$script"
        assert_root_owned "$(dirname "$script")"
        assert_root_owned "$script"
        exec "$script"
        ;;

    apt-install)
        require_method apt
        pkg="$(mf '.apt_package // empty')"
        [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "manifest 里的 apt_package 非法：$pkg"
        apt-get update
        if [ "$pkg" = wireshark ]; then
            echo "wireshark-common wireshark-common/setuid boolean true" | debconf-set-selections
        fi
        apt-get install -y "$pkg"
        exec /usr/local/bin/webclaw-app-postinstall "$APP_ID"
        ;;

    deb-url)
        require_method github_release direct_download
        resolve_deb_url
        ;;

    deb-install)
        require_method github_release direct_download
        pkg="$(mf '.package // empty')"
        [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "manifest 里的 package 非法：$pkg"
        url="$(resolve_deb_url)"
        mkdir -p "$STAGE_ROOT"
        chown root:root "$STAGE_ROOT"
        chmod 700 "$STAGE_ROOT"
        stage="$(mktemp -d "$STAGE_ROOT/${APP_ID}.XXXXXX")"
        trap 'rm -rf "$stage"' EXIT
        log "以 root 下载 $url"
        curl -fsSL --retry 3 --proto =https,file --proto-redir =https -o "$stage/pkg.deb" "$url" \
            || die "下载失败：$url"
        deb_pkg="$(dpkg-deb --field "$stage/pkg.deb" Package 2>/dev/null || true)"
        [ "$deb_pkg" = "$pkg" ] || die ".deb 的 Package=$deb_pkg，与 manifest 声明的 $pkg 不符"
        chown root:root "$stage/pkg.deb"
        chmod 644 "$stage/pkg.deb"
        # _apt 沙箱用户读不到 root 0700 目录，这里显式关掉沙箱，本地文件不需要它。
        apt-get install -y -o APT::Sandbox::User=root "$stage/pkg.deb"
        ;;

    install-tree)
        require_method appimage r2_download direct_download cursor_api
        layout="${3:-}"
        root="$(app_root)"
        case "$layout" in
            appdir) kind="dir" ;;
            flat)   kind="dir"; [ "$METHOD" = appimage ] && die "appimage 只支持 appdir 布局" ;;
            binary) kind="file"; [ "$METHOD" = appimage ] && die "appimage 只支持 appdir 布局" ;;
            *) die "未知布局：$layout（只允许 appdir / flat / binary）" ;;
        esac
        stage="$(take_from_tmp "/tmp/webclaw-stage-${APP_ID}")"
        trap 'rm -rf "$stage"' EXIT
        validate_tree "$stage/item" "$kind"

        [ "$METHOD" = appimage ] && { mkdir -p /opt/ondemand-apps; chmod 755 /opt/ondemand-apps; }
        rm -rf -- "$root"
        case "$layout" in
            appdir)
                mkdir -m 755 "$root"
                mv -T "$stage/item" "$root/AppDir"
                chmod -R a+rX,go-w "$root/AppDir"
                ;;
            flat)
                mv -T "$stage/item" "$root"
                chmod -R a+rX,go-w "$root"
                ;;
            binary)
                mkdir -m 755 "$root"
                mv -T "$stage/item" "$root/$APP_ID"
                chmod 755 "$root/$APP_ID"
                ;;
        esac
        # 整棵树归 root、group/other 不可写：装好的程序只能由 broker/卸载器改动，
        # 之后 wrapper 写到这里时调用者也没法预埋任何东西。
        # 都不跟随符号链接：chown -R -P -h 只改链接本身；chmod -R 遍历时忽略符号链接
        # （命令行操作数 $root 是已确认的真实目录）。树内链接已确认不出树，本来也碰不到树外。
        chown -R -P -h root:root "$root"
        chmod -R a+rX,go-w "$root"
        chmod 755 "$root"
        ;;

    wrapper)
        require_method appimage r2_download direct_download cursor_api
        root="$(app_root)"
        target="${3:-}"
        [ -n "$target" ] || die "缺少 wrapper 目标"
        assert_root_owned "$root"
        real="$(realpath -e -- "$target" 2>/dev/null)" || die "wrapper 目标不存在：$target"
        case "$real" in "$root"/*) ;; *) die "wrapper 目标不在 $root 内：$real" ;; esac
        [ -f "$real" ] && [ -x "$real" ] || die "wrapper 目标不是可执行文件：$real"
        [ "$real" != "$root/$APP_ID" ] || die "目标就是 wrapper 本身"
        if [ "$METHOD" = appimage ] && [ "$real" = "$root/AppDir/AppRun" ]; then
            body="APPDIR=$(printf '%q' "$root/AppDir") exec $(printf '%q' "$real") \"\$@\""
        else
            body="exec $(printf '%q' "$real") \"\$@\""
        fi
        printf '#!/bin/bash\n%s\n' "$body" | write_root_file "$root/$APP_ID" 755
        ;;

    desktop)
        require_method r2_download direct_download cursor_api
        root="$(app_root)"
        # manifest 是可信的，但 Name 进 .desktop 前仍去掉换行/控制字符，防止注入额外键。
        name="$(mf '.name // empty' | tr -d '\000-\037')"
        [ -n "$name" ] || name="$APP_ID"
        case "$METHOD" in
            cursor_api) comment="AI Code Editor"; categories="IDE;Development;" ;;
            r2_download) comment="$name"; categories="Utility;Application;" ;;
            *) comment="$name"; categories="Utility;" ;;
        esac
        # lite 镜像里可能没有这个目录
        install -d -m 755 -o root -g root /usr/share/applications
        write_root_file "/usr/share/applications/${APP_ID}.desktop" 644 <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=$comment
Exec=$root/$APP_ID %F
Icon=$APP_ID
Terminal=false
Categories=$categories
EOF
        ;;

    postinstall)
        exec /usr/local/bin/webclaw-app-postinstall "$APP_ID"
        ;;

    uninstall)
        exec /usr/local/bin/webclaw-app-uninstaller "$APP_ID"
        ;;

    *)
        die "未知动作：$ACTION"
        ;;
esac
