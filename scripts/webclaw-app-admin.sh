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
#    uninstall    <id>                       webclaw-app-uninstaller（custom_script 的卸载脚本先校验 root 所有）
#
#  高层 API（api_version 2，launcher / software-manager 应优先使用）：
#    api-version                             {"api_version":2,"catalog_schema":1,...}
#    catalog-info                            runtime catalog cache 状态（JSON）
#    status       <id>                       安装状态 / 已装版本 / catalog 版本 / update_available（JSON）
#    install      <id>                       apt、.deb（github_release / direct_download）、custom_script
#    upgrade      <id>                       apt、.deb；已是 catalog 最新版时直接返回
#    fetch        <id>                       AppImage/zip/tar 类：按 catalog 下载并校验 sha256，
#                                            交给调用者一个新建的私有目录，launcher 再解压 + install-tree
#  退出码 3 = unsupported：该应用在当前架构/安装方式下不能由这个动作处理（stderr 有说明；
#            status 的 supported / upgrade_supported 会提前给出同样的结论）。fetch 没有 catalog 条目时也返回 3。
#  安装/升级/卸载等 mutating 动作由全局锁 /run/webclaw-app-admin/mutation.lock 串行；只读动作不加锁。
#  install/upgrade 对 AppImage/zip/tar 类是端到端的：root 下载（catalog 时强制 sha256）→
#  webclaw-unpack 低权限用户解包（root 从不执行/解析下载内容）→ root 校验树 → 装进受管目录。
#
#  runtime catalog（/var/lib/webclaw/catalog/runtime-catalog.json，由 webclaw-catalog-update 维护）
#  只能给已知 app 叠加 version 与当前架构的 url + sha256；url 必须落在本 manifest 允许的来源内，
#  使用前按当前 manifest 重新校验。catalog 来的下载一律先在 root 私有目录校验 sha256，不匹配绝不安装。
#  catalog 缺失、不可信或没有该 app 时，走原来的 manifest 解析逻辑。
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

# 路径本身及所有上级目录都要 root 所有、不可被他人写（被 source 的库、cache 文件用）。
assert_trusted_chain() {
    local p="$1"
    while :; do
        assert_root_owned "$p"
        [ "$p" = / ] && break
        p="$(dirname "$p")"
    done
}

CATALOG_LIB=/usr/local/lib/webclaw/runtime-catalog.sh
assert_trusted_chain "$CATALOG_LIB"
# shellcheck source=lib/runtime-catalog.sh
. "$CATALOG_LIB"
CORE_LIB=/opt/lib/on-demand-core.sh

# 所有临时目录都在 root 私有的 0700 目录下，统一在退出时清理。
CLEANUP=()
cleanup() { local d; for d in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -rf -- "$d"; done; }
trap cleanup EXIT
# 用法：private_dir <变量名> <前缀>（不能在 $(...) 里调用，否则登记的清理项会丢）
private_dir() {
    local d
    mkdir -p "$STAGE_ROOT"
    chown root:root "$STAGE_ROOT"
    chmod 700 "$STAGE_ROOT"
    d="$(mktemp -d "$STAGE_ROOT/${2}.XXXXXX")"
    CLEANUP+=("$d")
    printf -v "$1" '%s' "$d"
}

ACTION="${1:-}"
APP_ID="${2:-}"
[ -n "$ACTION" ] || die "缺少动作"

# ─── 全局 mutation 锁 ───────────────────────────────────────────────
# 所有会改系统/安装状态的动作串行执行：同一时刻最多一个 broker 在下载/解包/安装/卸载，
# 这也保证 kill_unpack_procs 只会清理本次解包留下的 webclaw-unpack 进程。
# 只读动作（api-version / catalog-info / status / deb-url）和只建日志文件的 log-prepare 不加锁。
#
# 做法：broker 在 flock -o 下重新执行自己。-o 让锁 fd 不进入子进程，锁由 flock 进程持有到
# 子进程结束——这样 apt 的 postinst、custom_script 启动的常驻进程不会意外继承锁、把后续安装永久卡住。
# 锁目录是 root:root 0700（不用 1777 的 /run/lock：ubuntu 能在那里抢先建同名文件并占住锁）。
# WEBCLAW_APP_ADMIN_LOCKED 只由这里设置；sudo 的 env_reset 不允许 ubuntu 从外部传入它。
MUTATION_LOCK_DIR=/run/webclaw-app-admin
MUTATION_LOCK="$MUTATION_LOCK_DIR/mutation.lock"
MUTATION_LOCK_WAIT=3600
case "$ACTION" in
    apt-prepare|apt-install|deb-install|install|upgrade|fetch|install-tree|wrapper|desktop|postinstall|uninstall)
        if [ "${WEBCLAW_APP_ADMIN_LOCKED:-}" != 1 ]; then
            install -d -m 700 -o root -g root "$MUTATION_LOCK_DIR"
            assert_trusted_chain "$MUTATION_LOCK_DIR"
            if [ -e "$MUTATION_LOCK" ] || [ -L "$MUTATION_LOCK" ]; then
                [ -f "$MUTATION_LOCK" ] && [ ! -L "$MUTATION_LOCK" ] || die "$MUTATION_LOCK 不是普通文件"
                assert_root_owned "$MUTATION_LOCK"
            else
                install -m 600 -o root -g root /dev/null "$MUTATION_LOCK"
            fi
            if ! flock -n "$MUTATION_LOCK" true; then
                log "另一个安装/升级/卸载操作正在进行，等待其完成（最长 ${MUTATION_LOCK_WAIT}s）…"
            fi
            rc=0
            env WEBCLAW_APP_ADMIN_LOCKED=1 flock -o -E 75 -w "$MUTATION_LOCK_WAIT" "$MUTATION_LOCK" \
                /usr/local/bin/webclaw-app-admin "$@" || rc=$?
            [ "$rc" != 75 ] || die "等待其它安装操作超时（${MUTATION_LOCK_WAIT}s），请稍后重试"
            exit "$rc"
        fi
        ;;
esac

# cache 只有在整条路径 root 所有时才被信任；否则当作没有 catalog。
catalog_cache_trusted() {
    [ -f "$WEBCLAW_CATALOG_FILE" ] && ( assert_trusted_chain "$WEBCLAW_CATALOG_FILE" ) 2>/dev/null
}

# ─── 不需要 app_id 的全局动作 ─────────────────────────────────────────
case "$ACTION" in
    api-version)
        [ "$#" -eq 1 ] || die "$ACTION 不接受参数"
        jq -n --argjson s "$WEBCLAW_CATALOG_SCHEMA" '{api_version: 2, catalog_schema: $s,
            actions: ["api-version", "catalog-info", "status", "install", "upgrade", "uninstall", "fetch"]}'
        exit 0
        ;;
    catalog-info)
        [ "$#" -eq 1 ] || die "$ACTION 不接受参数"
        cache='null' state='{}' trusted=false
        if [ -f "$WEBCLAW_CATALOG_FILE" ]; then
            if catalog_cache_trusted; then
                trusted=true
                cache="$(jq -c '{generated_at, apps: (.apps | keys)}' "$WEBCLAW_CATALOG_FILE" 2>/dev/null || echo null)"
            fi
        fi
        if [ -f "$WEBCLAW_CATALOG_STATE" ] && ( assert_trusted_chain "$WEBCLAW_CATALOG_STATE" ) 2>/dev/null; then
            state="$(jq -c '{last_attempt_at, last_success_at, last_error, last_error_at}' "$WEBCLAW_CATALOG_STATE" 2>/dev/null || echo '{}')"
        fi
        sig=false
        [ -e "$WEBCLAW_CATALOG_PUBKEY" ] && sig=true
        jq -n --argjson c "$cache" --argjson s "$state" --argjson present "$([ -f "$WEBCLAW_CATALOG_FILE" ] && echo true || echo false)" \
            --argjson trusted "$trusted" --argjson sig "$sig" --argjson schema "$WEBCLAW_CATALOG_SCHEMA" \
            --arg url "$WEBCLAW_CATALOG_URL" '
            {catalog_schema: $schema, source_url: $url, signature_required: $sig,
             cache_present: $present, cache_trusted: $trusted,
             generated_at: ($c.generated_at // null), apps: ($c.apps // []),
             last_attempt_at: ($s.last_attempt_at // null), last_success_at: ($s.last_success_at // null),
             last_error: ($s.last_error // null), last_error_at: ($s.last_error_at // null)}'
        exit 0
        ;;
esac

# app_id：小写字母数字开头，只含 [a-z0-9._-]，不含 ..，长度 ≤ 64。
[[ "$APP_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [[ "$APP_ID" != *..* ]] || die "非法 app_id：$APP_ID"
# 这些名字在 /opt 下是系统目录，就算有同名 manifest 也不能当安装目录。
webclaw_reserved_app_id "$APP_ID" && die "保留名：$APP_ID"

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
#   用法：take_from_tmp <变量名> <源>
take_from_tmp() {
    local src="$2"
    [ -e "$src" ] || [ -L "$src" ] || die "$src 不存在"
    private_dir "$1" "$APP_ID"
    mv -T -- "$src" "${!1}/item" || die "无法接管 $src"
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
#   $3 = 这些条目应属于的 uid（默认调用者；broker 自己解包时是 webclaw-unpack）
validate_tree() {
    local item="$1" kind="$2" owner="${3:-$CALLER_UID}" bad link
    [ ! -L "$item" ] || die "源是符号链接"
    case "$kind" in
        dir)  [ -d "$item" ] || die "源不是目录" ;;
        file) [ -f "$item" ] || die "源不是普通文件" ;;
    esac
    bad="$(find "$item" -xdev \( ! -uid "$owner" -o \( -type f -links +1 \) \
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

# ─── runtime catalog 叠加 ────────────────────────────────────────────
ARCH="$(dpkg --print-architecture)"

# 输出当前 app 在 catalog 里的条目（JSON），没有/不可信/不再符合当前 manifest 时输出空。
# 每次使用前都按「当前」manifest 重新跑一遍与 updater 相同的校验。
# 总是在 $(...) 里调用，所以函数体本身就是子 shell，临时目录由子 shell 自己的 EXIT trap 清理。
# shellcheck disable=SC2030,SC2031
catalog_entry() (
    local work res
    catalog_cache_trusted || return 0
    jq -e --arg id "$APP_ID" '.apps[$id] != null' "$WEBCLAW_CATALOG_FILE" >/dev/null 2>&1 || return 0
    CLEANUP=()
    trap cleanup EXIT
    private_dir work catalog
    jq --arg id "$APP_ID" '{schema_version, generated_at, apps: {($id): .apps[$id]}}' \
        "$WEBCLAW_CATALOG_FILE" > "$work/c.json" 2>/dev/null || return 0
    jq -n --arg id "$APP_ID" --slurpfile mf "$MANIFEST" '{($id): $mf[0]}' > "$work/p.json"
    res="$(webclaw_catalog_validate "$work/c.json" "$work/p.json" 2>/dev/null)" || { log "catalog cache 无法解析，忽略"; return 0; }
    if [ "$(jq -r '.errors | length' <<< "$res")" != 0 ]; then
        log "catalog 条目不符合当前本地策略，忽略：$(jq -r '.errors[0]' <<< "$res")"
        return 0
    fi
    jq -c --arg id "$APP_ID" '.catalog.apps[$id]' <<< "$res"
)

# 设置 CAT_VERSION / CAT_URL / CAT_SHA（当前架构；没有就为空）。
load_catalog() {
    local entry
    CAT_VERSION="" CAT_URL="" CAT_SHA="" CAT_RELEASED=""
    entry="$(catalog_entry)"
    [ -n "$entry" ] || return 0
    CAT_VERSION="$(jq -r '.version' <<< "$entry")"
    CAT_RELEASED="$(jq -r '.released_at // empty' <<< "$entry")"
    CAT_URL="$(jq -r --arg a "$ARCH" '.artifacts[$a].url // empty' <<< "$entry")"
    CAT_SHA="$(jq -r --arg a "$ARCH" '.artifacts[$a].sha256 // empty' <<< "$entry")"
    [ -n "$CAT_URL" ] && [ -n "$CAT_SHA" ] || { CAT_URL="" CAT_SHA=""; }
}

# 以 root 下载到私有目录；给了 sha256 就必须匹配，否则删掉并拒绝。
download_verified() {
    local url="$1" dest="$2" sha="${3:-}" actual
    log "以 root 下载 $url"
    curl -q -fsSL --retry 3 --proto =https,file --proto-redir =https -o "$dest" "$url" \
        || die "下载失败：$url"
    if [ -n "$sha" ]; then
        actual="$(sha256sum "$dest" | awk '{print $1}')"
        if [ "$actual" != "$sha" ]; then
            rm -f -- "$dest"
            die "sha256 不匹配（期望 $sha，实际 $actual），不会安装"
        fi
        log "sha256 校验通过"
    fi
}

is_deb_app() {
    case "$METHOD" in
        github_release) return 0 ;;
        direct_download) [ "$(webclaw_artifact_kind "$(mf '.download_url // empty')")" = deb ] ;;
        *) return 1 ;;
    esac
}

check_root_script() {
    local script="$1"
    [[ "$script" =~ ^(/usr/local/bin/[A-Za-z0-9._-]+|/opt/[A-Za-z0-9._-]+\.sh)$ ]] || die "脚本路径不在允许范围：$script"
    assert_root_owned "$(dirname "$script")"
    assert_root_owned "$script"
    [ -f "$script" ] && [ -x "$script" ] || die "脚本不可执行：$script"
}

run_apt_prepare() {
    local script
    script="$(mf '.install_script // empty')"
    [ -n "$script" ] || return 0
    check_root_script "$script"
    "$script"
}

# $1 = install | upgrade
run_apt_install() {
    local pkg
    pkg="$(mf '.apt_package // empty')"
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "manifest 里的 apt_package 非法：$pkg"
    apt-get update
    if [ "$pkg" = wireshark ]; then
        echo "wireshark-common wireshark-common/setuid boolean true" | debconf-set-selections
    fi
    if [ "$1" = upgrade ]; then
        apt-get install -y --only-upgrade "$pkg"
    else
        apt-get install -y "$pkg"
    fi
}

# catalog 有当前架构的 artifact 就用它（强制 sha256），否则走 manifest 推导的旧地址。
run_deb_install() {
    local pkg url sha stage deb_pkg
    pkg="$(mf '.package // empty')"
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "manifest 里的 package 非法：$pkg"
    load_catalog
    if [ -n "$CAT_URL" ]; then
        url="$CAT_URL" sha="$CAT_SHA"
        [ "$(webclaw_artifact_kind "$url")" = deb ] || die "catalog 地址不是 .deb：$url"
        check_deb_url "$url"
        log "使用 runtime catalog：version=$CAT_VERSION"
    else
        url="$(resolve_deb_url)" sha=""
    fi
    private_dir stage "$APP_ID"
    download_verified "$url" "$stage/pkg.deb" "$sha"
    deb_pkg="$(dpkg-deb --field "$stage/pkg.deb" Package 2>/dev/null || true)"
    [ "$deb_pkg" = "$pkg" ] || die ".deb 的 Package=$deb_pkg，与 manifest 声明的 $pkg 不符"
    chown root:root "$stage/pkg.deb"
    chmod 644 "$stage/pkg.deb"
    # _apt 沙箱用户读不到 root 0700 目录，这里显式关掉沙箱，本地文件不需要它。
    apt-get install -y -o APT::Sandbox::User=root "$stage/pkg.deb"
}

# ─── 安装记录（非 dpkg 应用的已装版本）──────────────────────────────
record_dir() { install -d -m 755 -o root -g root /var/lib/webclaw "$WEBCLAW_INSTALLED_DIR"; }
RECORD="$WEBCLAW_INSTALLED_DIR/${APP_ID}.json"
PENDING="$WEBCLAW_INSTALLED_DIR/.pending-${APP_ID}.json"

# $1 = version（可空）$2 = source（catalog / legacy）$3 = sha256（可空）
write_record() {
    record_dir
    jq -n --arg v "$1" --arg src "$2" --arg sha "$3" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: (if $v == "" then null else $v end), source: $src,
          sha256: (if $sha == "" then null else $sha end), installed_at: $t}' | write_root_file "$RECORD" 644
    rm -f -- "$PENDING"
}

# 低层 install-tree 成功后：fetch 在 1 小时内留下的 pending 记录转正；否则记为未知版本（旧逻辑安装）。
promote_record() {
    record_dir
    if [ -f "$PENDING" ] && [ ! -L "$PENDING" ] && [ $(( $(date +%s) - $(stat -c %Y "$PENDING") )) -lt 3600 ]; then
        write_record "$(jq -r '.version // empty' "$PENDING")" catalog "$(jq -r '.sha256 // empty' "$PENDING")"
    else
        write_record "" legacy ""
    fi
}

installed_now() {
    [ -r "$CORE_LIB" ] || return 1
    ( assert_trusted_chain "$CORE_LIB" ) 2>/dev/null || return 1
    # shellcheck source=lib/on-demand-core.sh
    ( . "$CORE_LIB"; webclaw_app_installed "$METHOD" "$(mf '.package // empty')" "$(mf '.binary // empty')" )
}

valid_pkg() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; }

dpkg_version() {
    local pkg
    pkg="$(mf '.package // empty')"
    valid_pkg "$pkg" || return 0
    if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]; then
        dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null
    fi
}

# apt 应用的「最新」= 本地 apt 列表里的候选版本（不联网；列表由 install/upgrade 时的 apt-get update 刷新）。
apt_candidate() {
    local pkg cand
    pkg="$(mf '.apt_package // empty')"
    valid_pkg "$pkg" || return 0
    cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ] && echo "$cand"
    return 0
}

# 只在两边都是 dpkg 能比较的版本号时给结论；返回 true / false / null。
compare_update() {
    local installed="${1#v}" latest="${2#v}"
    local re='^[0-9][A-Za-z0-9.+~:-]*$'
    installed="${installed#rust-v}" latest="${latest#rust-v}"
    if [ -z "$installed" ] || [ -z "$latest" ] || ! [[ "$installed" =~ $re ]] || ! [[ "$latest" =~ $re ]]; then
        echo null
    elif dpkg --compare-versions "$latest" gt "$installed" 2>/dev/null; then
        echo true
    else
        echo false
    fi
}

# fresh：cache 可信且 24 小时内刷新成功；stale：可信但超过 24 小时；
# offline：有可信 cache 但最近一次刷新失败（仍在用 last-known-good）；unavailable：没有可信 cache。
catalog_state() {
    local last_ok last_err
    if ! catalog_cache_trusted; then echo unavailable; return; fi
    if [ -f "$WEBCLAW_CATALOG_STATE" ] && ( assert_trusted_chain "$WEBCLAW_CATALOG_STATE" ) 2>/dev/null; then
        last_ok="$(jq -r '.last_success_epoch // empty' "$WEBCLAW_CATALOG_STATE" 2>/dev/null || true)"
        last_err="$(jq -r '.last_error // empty' "$WEBCLAW_CATALOG_STATE" 2>/dev/null || true)"
    fi
    if [ -n "${last_err:-}" ]; then
        echo offline
    elif [[ "${last_ok:-}" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - last_ok )) -le 86400 ]; then
        echo fresh
    else
        echo stale
    fi
}

# 当前架构 / 安装方式能否由 broker 端到端处理。设置 SUP=true|false、SUP_MSG。
support_check() {
    local archs
    SUP=true SUP_MSG=""
    case "$METHOD" in
        apt|github_release|direct_download|appimage|cursor_api|r2_download|custom_script) ;;
        *) SUP=false SUP_MSG="未知的安装方式 $METHOD"; return ;;
    esac
    if [ "$(jq -r --arg a "$ARCH" '(.unsupported_archs // []) | index($a) != null' "$MANIFEST")" = true ]; then
        SUP=false SUP_MSG="不支持当前架构 $ARCH"; return
    fi
    archs="$(jq -r '(.architectures // []) | join(" ")' "$MANIFEST")"
    if [ -n "$archs" ] && [[ " $archs " != *" $ARCH "* ]]; then
        SUP=false SUP_MSG="只支持 $archs 架构，当前是 $ARCH"; return
    fi
    case "$METHOD" in
        github_release|appimage|cursor_api)
            jq -e --arg a "$ARCH" '.arch_map | has($a)' "$MANIFEST" >/dev/null 2>&1 \
                || { SUP=false SUP_MSG="manifest 没有为 $ARCH 声明 arch_map"; return; }
            ;;
        direct_download)
            jq -e --arg a "$ARCH" '.arch_map | has($a)' "$MANIFEST" >/dev/null 2>&1 \
                || [[ "$(mf '.download_url // empty')" != *"{arch"* ]] \
                || { SUP=false SUP_MSG="manifest 没有为 $ARCH 声明 arch_map"; return; }
            ;;
        r2_download)
            jq -e --arg a "$ARCH" '(.arch_map | has($a)) or (.asset_key != null)' "$MANIFEST" >/dev/null 2>&1 \
                || { SUP=false SUP_MSG="manifest 没有为 $ARCH 声明下载资源"; return; }
            ;;
        custom_script)
            ( check_root_script "$(mf '.install_wrapper // .install_script // empty')" ) 2>/dev/null \
                || { SUP=false SUP_MSG="安装脚本缺失或不是 root 所有"; return; }
            ;;
    esac
}

upgrade_supported() {
    [ "$SUP" = true ] || return 1
    [ "$METHOD" != custom_script ] || [ "$(mf '.upgrade_by_reinstall // false')" = true ]
}

# 输出 status JSON；同时设置 ST_INSTALLED / ST_UPDATE 供 upgrade 使用。
# 字段与 Software Manager v2 契约对齐：latest_version / catalog_state / supported / message 在顶层。
build_status() {
    local installed=false iv="" vsrc="" update latest="" lsrc="" cstate up=false msg
    installed_now && installed=true
    iv="$(dpkg_version)"
    if [ -n "$iv" ]; then
        vsrc=dpkg
    elif [ -f "$RECORD" ] && ( assert_root_owned "$RECORD" ) 2>/dev/null; then
        iv="$(jq -r '.version // empty' "$RECORD" 2>/dev/null || true)"
        vsrc=record
    fi
    load_catalog
    cstate="$(catalog_state)"
    if [ -n "$CAT_VERSION" ]; then
        latest="$CAT_VERSION" lsrc=catalog
    elif [ "$METHOD" = apt ]; then
        latest="$(apt_candidate)"
        [ -n "$latest" ] && lsrc=apt
    fi
    update=null
    [ "$installed" = true ] && [ -n "$latest" ] && update="$(compare_update "$iv" "$latest")"
    support_check
    upgrade_supported && up=true
    msg="$SUP_MSG"
    if [ "$SUP" = true ] && [ "$up" = false ]; then
        msg="该应用的安装脚本不支持重复执行升级，请卸载后重新安装"
    fi
    ST_INSTALLED="$installed" ST_UPDATE="$update"
    jq -n --arg id "$APP_ID" --arg m "$METHOD" --arg arch "$ARCH" --argjson inst "$installed" \
        --arg iv "$iv" --arg vsrc "$vsrc" --arg cv "$CAT_VERSION" --arg rel "$CAT_RELEASED" \
        --argjson art "$([ -n "$CAT_URL" ] && echo true || echo false)" \
        --arg latest "$latest" --arg lsrc "$lsrc" --arg cstate "$cstate" \
        --argjson upd "$update" --argjson sup "$SUP" --argjson up "$up" --arg msg "$msg" '
        def n: if . == "" then null else . end;
        {app_id: $id, install_method: $m, arch: $arch,
         supported: $sup, message: ($msg | n),
         installed: $inst,
         installed_version: ($iv | n), installed_version_source: ($vsrc | n),
         latest_version: ($latest | n), latest_version_source: ($lsrc | n),
         update_available: $upd,
         upgrade_supported: $up, upgrade_via: (if $up then "broker" else "unsupported" end),
         catalog_state: $cstate,
         catalog: (if $cv == "" then null else
             {version: $cv, released_at: ($rel | n), artifact_for_arch: $art} end)}'
}

# ─── 归档类应用：root 下载/校验，专用低权限用户解包，root 校验后装进受管目录 ──
# root 从不执行、也不解析下载来的归档：AppImage 的 --appimage-extract、unzip、tar 都以
# webclaw-unpack（无登录、无 sudo、不在 ubuntu 组）身份在 /var/lib/webclaw/unpack/<随机> 里完成。
# 该目录 root:webclaw-unpack 0710，ubuntu 进不去；解包结束后 root 杀掉该用户所有残留进程，
# 再把结果 rename 进 root 私有目录，按 validate_tree 校验（属主、硬链接、特殊文件、越界链接）。
UNPACK_USER=webclaw-unpack
UNPACK_BASE=/var/lib/webclaw/unpack

# 以下脚本以 webclaw-unpack 身份在任务目录里执行；参数只有固定枚举，不拼接任何外部字符串。
# 产物：./out（目录或单个文件）和 ./layout（appdir / flat / binary）。
# shellcheck disable=SC2016
UNPACK_SCRIPT='
set -euo pipefail
kind="$1" unbundle="$2" cursorfix="$3"
extract_appimage() {
    chmod 755 "$1"
    rm -rf squashfs-root
    "./$1" --appimage-extract >/dev/null
    ex="$(readlink -f squashfs-root)"
    case "$ex" in "$PWD"/*) ;; *) echo "AppImage 解压结果越界：$ex" >&2; exit 1 ;; esac
    [ -d "$ex" ] || { echo "AppImage 解压结果不是目录" >&2; exit 1; }
    mv -T "$ex" out
    rm -rf squashfs-root
    echo appdir > layout
}
case "$kind" in
    appimage) extract_appimage artifact ;;
    zip)
        mkdir x
        unzip -q artifact -d x
        ai="$(find x -maxdepth 2 -type f -name "*.AppImage" -print -quit)"
        if [ -n "$ai" ]; then
            mv -T "$ai" inner.AppImage
            extract_appimage inner.AppImage
        else
            mv -T x out
            echo appdir > layout
        fi
        ;;
    tar)
        mkdir x
        tar --no-same-owner --no-same-permissions -xzf artifact -C x
        d="$(find x -mindepth 1 -maxdepth 1 -type d -print -quit)"
        f="$(find x -mindepth 1 -maxdepth 1 -type f -executable -print -quit)"
        if [ -n "$d" ]; then
            mv -T "$d" out; echo flat > layout
        elif [ -n "$f" ]; then
            mv -T "$f" out; echo binary > layout
        else
            echo "归档里没有目录或可执行文件" >&2; exit 1
        fi
        ;;
    *) echo "未知安装包类型 $kind" >&2; exit 1 ;;
esac
if [ "$(cat layout)" = appdir ]; then
    # 与 launcher 相同：把 AppImage 自带的旧 GL 库挪开（指向系统 Mesa 的链接由 postinstall 生成）
    if [ "$unbundle" = true ] && [ -d out/shared/lib ]; then
        mkdir -p out/shared/lib/.gl-bundled-bak
        for pat in libEGL libGL libGLX libGLES libGLdispatch libgbm; do
            for f in out/shared/lib/"$pat"*; do
                [ -e "$f" ] || [ -L "$f" ] || continue
                mv -f "$f" out/shared/lib/.gl-bundled-bak/
            done
        done
    fi
    if [ "$cursorfix" = true ] && [ -x out/cursor ] && [ ! -x out/usr/share/cursor/cursor ]; then
        mkdir -p out/usr/share/cursor
        mv -f out/cursor out/usr/share/cursor/cursor
    fi
fi
'

unpack_ids() {
    UNPACK_UID="$(id -u "$UNPACK_USER" 2>/dev/null)" || die "缺少解包专用用户 $UNPACK_USER"
    UNPACK_GID="$(id -g "$UNPACK_USER")"
    [ "$UNPACK_UID" != 0 ] && [ "$UNPACK_UID" != "$CALLER_UID" ] && [ "$UNPACK_UID" != "$(id -u "$USER_NAME")" ] \
        || die "$UNPACK_USER 的 uid 不安全：$UNPACK_UID"
}

as_unpack() {
    setpriv --reuid="$UNPACK_UID" --regid="$UNPACK_GID" --clear-groups --no-new-privs \
        env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME="$UNPACK_BASE" LANG=C.UTF-8 "$@"
}

kill_unpack_procs() {
    local p _
    for _ in 1 2 3; do
        for p in /proc/[0-9]*; do
            [ "$(stat -c %u "$p" 2>/dev/null)" = "$UNPACK_UID" ] && kill -9 "${p#/proc/}" 2>/dev/null
        done
        sleep 0.2
    done
    return 0
}

# $1 = 已校验的安装包 $2 = kind；设置 UNPACKED（root 私有目录里的 item）与 LAYOUT。
unpack_artifact() {
    local job stage unbundle=false cursorfix=false
    unpack_ids
    install -d -m 710 -o root -g "$UNPACK_GID" "$UNPACK_BASE"
    job="$(mktemp -d "$UNPACK_BASE/job.XXXXXX")"
    # 在主 shell 里调用（不是子 shell），清理项不会丢
    # shellcheck disable=SC2031
    CLEANUP+=("$job")
    chown "$UNPACK_UID:$UNPACK_GID" "$job"
    chmod 700 "$job"
    install -m 600 -o "$UNPACK_UID" -g "$UNPACK_GID" "$1" "$job/artifact"
    [ "$(mf '.unbundle_gl // false')" = true ] && unbundle=true
    [ "$METHOD" = cursor_api ] && cursorfix=true
    log "以 $UNPACK_USER 身份解包（$2）"
    if ! ( cd "$job" && timeout 3600 setpriv --reuid="$UNPACK_UID" --regid="$UNPACK_GID" --clear-groups --no-new-privs \
            env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME="$job" LANG=C.UTF-8 \
            bash -c "$UNPACK_SCRIPT" webclaw-unpack "$2" "$unbundle" "$cursorfix" ); then
        kill_unpack_procs
        die "解包失败"
    fi
    kill_unpack_procs
    LAYOUT="$(head -c 16 "$job/layout" 2>/dev/null || true)"
    case "$LAYOUT" in appdir|flat|binary) ;; *) die "解包结果的布局非法：$LAYOUT" ;; esac
    [ ! -L "$job/out" ] || die "解包结果是符号链接"
    private_dir stage "$APP_ID"
    mv -T -- "$job/out" "$stage/item" || die "无法接管解包结果"
    UNPACKED="$stage/item"
    if [ "$LAYOUT" = binary ]; then
        validate_tree "$UNPACKED" file "$UNPACK_UID"
    else
        validate_tree "$UNPACKED" dir "$UNPACK_UID"
    fi
}

# 把已校验的 item 装进受管目录（与低层 install-tree 同一套逻辑）。$1 = item $2 = layout
install_tree_item() {
    local item="$1" layout="$2" root
    root="$(app_root)"
    case "$layout" in
        appdir) ;;
        flat|binary) [ "$METHOD" = appimage ] && die "appimage 只支持 appdir 布局" ;;
        *) die "未知布局：$layout（只允许 appdir / flat / binary）" ;;
    esac
    [ "$METHOD" = appimage ] && { mkdir -p /opt/ondemand-apps; chmod 755 /opt/ondemand-apps; }
    rm -rf -- "$root"
    case "$layout" in
        appdir)
            mkdir -m 755 "$root"
            mv -T "$item" "$root/AppDir"
            ;;
        flat)
            mv -T "$item" "$root"
            ;;
        binary)
            mkdir -m 755 "$root"
            mv -T "$item" "$root/$APP_ID"
            chmod 755 "$root/$APP_ID"
            ;;
    esac
    # 整棵树归 root、group/other 不可写：装好的程序只能由 broker/卸载器改动，
    # 之后 wrapper 写到这里时调用者也没法预埋任何东西。
    # 都不跟随符号链接：chown -R -P -h 只改链接本身；chmod -R 遍历时忽略符号链接
    # （命令行操作数 $root 是已确认的真实目录）。树内链接已确认不出树，本来也碰不到树外。
    # setuid/setgid 位一律去掉：安装包里的程序只以普通用户身份运行。
    chown -R -P -h root:root "$root"
    chmod -R a+rX,go-w,ug-s "$root"
    chmod 755 "$root"
}

make_wrapper() {
    local target="$1" root real body
    root="$(app_root)"
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
}

make_desktop() {
    local root name comment categories
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
}

# 版本 API 脚本（file:///usr/local/bin/...）虽然是 root 所有的可信代码，也只以解包用户身份运行。
run_version_api() {
    local api="$1" path
    case "$api" in
        https://*)
            curl -q -fsSL --max-time 30 --proto =https --proto-redir =https "$api" 2>/dev/null ;;
        file:///usr/local/bin/*)
            path="${api#file://}"
            check_root_script "$path"
            unpack_ids
            ( cd / && as_unpack timeout 120 "$path" 2>/dev/null ) ;;
        *) die "manifest 里的 version_api 不在允许范围：$api" ;;
    esac
}

# 旧逻辑：按 manifest 在线解析归档下载地址（与 launcher 原来的解析一致）。设置 SRC_URL / SRC_VERSION。
resolve_archive_legacy() {
    local arch_var suffix repo tag asset api resp jb key
    arch_var="$(jq -r --arg a "$ARCH" '.arch_map[$a] // empty' "$MANIFEST")"
    SRC_URL="" SRC_VERSION=""
    case "$METHOD" in
        appimage)
            repo="$(mf '.github_repo // empty')"
            [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "manifest 里的 github_repo 非法：$repo"
            tag="$(github_latest_tag "$repo")"
            SRC_VERSION="${tag#v}"
            asset="$(mf '.asset_pattern // empty')"
            asset="${asset//\{version\}/$SRC_VERSION}"
            asset="${asset//\{arch_suffix\}/$arch_var}"
            SRC_URL="https://github.com/${repo}/releases/download/v${SRC_VERSION}/${asset}"
            ;;
        cursor_api)
            SRC_VERSION="$(mf '.version // empty')"
            SRC_URL="$(mf '.api_base // empty')/${arch_var}/cursor/${SRC_VERSION}"
            ;;
        r2_download)
            key="$(jq -r --arg a "$ARCH" '.arch_map[$a] // .asset_key // empty' "$MANIFEST")"
            resp="$(run_version_api "$(mf '.download_api // empty')")" || die "无法获取版本信息"
            SRC_VERSION="$(jq -r '.version // .latest // empty' <<< "$resp" 2>/dev/null || true)"
            SRC_URL="$(jq -r --arg k "$key" '.assets[$k].url // empty' <<< "$resp" 2>/dev/null || true)"
            ;;
        direct_download)
            SRC_URL="$(mf '.download_url // empty')"
            api="$(mf '.version_api // empty')"
            if [ -n "$api" ]; then
                resp="$(run_version_api "$api" || true)"
                SRC_VERSION="$(jq -r '.version // .latest // empty' <<< "$resp" 2>/dev/null || true)"
            fi
            jb="$(mf '.jetbrains_code // empty')"
            if [ -n "$jb" ]; then
                [[ "$jb" =~ ^[A-Z]{2,8}$ ]] || die "manifest 里的 jetbrains_code 非法：$jb"
                resp="$(curl -q -fsSL --max-time 30 --proto =https \
                    "https://data.services.jetbrains.com/products/releases?code=${jb}&latest=true&type=release" 2>/dev/null || true)"
                [ -n "$SRC_VERSION" ] || SRC_VERSION="$(jq -r --arg c "$jb" '.[$c][0].version // empty' <<< "$resp" 2>/dev/null || true)"
                if [ "$ARCH" = arm64 ]; then
                    SRC_URL="$(jq -r --arg c "$jb" '.[$c][0].downloads.linuxARM64.link // empty' <<< "$resp" 2>/dev/null || true)"
                else
                    SRC_URL="$(jq -r --arg c "$jb" '.[$c][0].downloads.linux.link // empty' <<< "$resp" 2>/dev/null || true)"
                fi
            fi
            if [[ "$SRC_URL" == *"{version}"* ]] && [ -z "$SRC_VERSION" ]; then
                die "无法获取版本号"
            fi
            suffix="$(jq -r --arg a "$ARCH" --arg f "$arch_var" '.arch_suffix_map[$a] // $f' "$MANIFEST")"
            SRC_URL="${SRC_URL//\{version\}/$SRC_VERSION}"
            SRC_URL="${SRC_URL//\{arch\}/$arch_var}"
            SRC_URL="${SRC_URL//\{arch_suffix\}/$suffix}"
            ;;
    esac
    [[ -z "$SRC_VERSION" || "$SRC_VERSION" =~ ^[A-Za-z0-9._+~-]{1,64}$ ]] || SRC_VERSION=""
    [ -n "$SRC_URL" ] || die "无法解析下载地址"
    [[ "$SRC_URL" != *"{"* ]] || die "下载地址里还有未支持的占位符：$SRC_URL"
    # 在线解析出来的地址（尤其是 API 返回的）同样必须落在本地 source policy 允许的来源内。
    webclaw_url_allowed "$MANIFEST" "$SRC_URL" || die "下载地址不在本地策略允许的来源内：$SRC_URL"
}

expected_archive_kind() {
    case "$METHOD" in
        appimage|cursor_api) echo appimage ;;
        r2_download) echo zip ;;
        direct_download)
            if [ -n "$(mf '.download_url // empty')" ]; then
                webclaw_artifact_kind "$(mf '.download_url')"
            else
                echo tar
            fi ;;
    esac
}

# 找启动入口（与 launcher 原逻辑相同的优先级，最后退到 manifest 的 launch_script）。
locate_entry() {
    local root="$1" bin=""
    if [ -x "$root/AppDir/AppRun" ]; then
        bin="$root/AppDir/AppRun"
    fi
    if [ -z "$bin" ] && [ -d "$root/AppDir" ]; then
        bin="$(find "$root/AppDir" -type f -executable -name "$APP_ID" -print -quit)"
    fi
    [ -n "$bin" ] || bin="$(find "$root" -maxdepth 3 -type f -executable -name "${APP_ID}.sh" -print -quit)"
    if [ -z "$bin" ] && [ -d "$root/AppDir" ]; then
        bin="$(find "$root/AppDir" -type f \( -name cursor -o -name tauri-app \) -executable -print -quit)"
    fi
    if [ -z "$bin" ] && [ -d "$root/AppDir/usr/bin" ]; then
        bin="$(find "$root/AppDir/usr/bin" -type f -executable -print -quit)"
    fi
    if [ -z "$bin" ]; then
        local ls
        ls="$(mf '.launch_script // empty')"
        [[ "$ls" =~ ^[A-Za-z0-9._/-]+$ && "$ls" != *..* ]] && [ -x "$root/$ls" ] && bin="$root/$ls"
    fi
    echo "$bin"
}

# 端到端安装归档类应用：catalog（强制 sha256）或旧逻辑解析 → root 下载 → 低权限解包 → 校验 → 安装。
run_archive_install() {
    local sha="" origin kind dl root entry bin
    load_catalog
    if [ -n "$CAT_URL" ]; then
        SRC_URL="$CAT_URL" SRC_VERSION="$CAT_VERSION" sha="$CAT_SHA" origin=catalog
        log "使用 runtime catalog：version=$CAT_VERSION"
    else
        resolve_archive_legacy
        origin=legacy
        log "runtime catalog 没有 $APP_ID，按 manifest 在线解析：version=${SRC_VERSION:-未知}"
    fi
    if [ "$METHOD" = direct_download ] && [ "$(mf '.jetbrains_code // empty')" != "" ] && [ -z "$(mf '.download_url // empty')" ]; then
        kind=tar
    else
        kind="$(webclaw_artifact_kind "$SRC_URL")"
        # cursor 的 API 地址没有扩展名：类型以 manifest 为准
        [ "$METHOD" = cursor_api ] && kind=appimage
    fi
    [ "$kind" = "$(expected_archive_kind)" ] || die "安装包类型 $kind 与本地策略 $(expected_archive_kind) 不符"
    private_dir dl "$APP_ID"
    download_verified "$SRC_URL" "$dl/artifact" "$sha"
    unpack_artifact "$dl/artifact" "$kind"
    install_tree_item "$UNPACKED" "$LAYOUT"
    root="$(app_root)"
    if [ "$LAYOUT" != binary ]; then
        entry="$(locate_entry "$root")"
        if [ -n "$entry" ] && [ "$entry" != "$root/$APP_ID" ]; then
            make_wrapper "$entry"
        elif [ -z "$entry" ] && [ "$METHOD" != appimage ]; then
            die "安装后没有找到可执行入口"
        fi
    fi
    [ "$METHOD" = appimage ] || make_desktop
    write_record "$SRC_VERSION" "$origin" "$sha"
    /usr/local/bin/webclaw-app-postinstall "$APP_ID" || log "postinstall 返回非 0（忽略）"
    bin="$(mf '.binary // empty')"
    [ -x "$bin" ] || die "安装完成但 manifest 声明的 binary 不存在：$bin"
    log "$APP_ID 安装完成（${SRC_VERSION:-版本未知}，来源 $origin）"
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
        run_apt_prepare
        ;;

    apt-install)
        require_method apt
        run_apt_install install
        exec /usr/local/bin/webclaw-app-postinstall "$APP_ID"
        ;;

    deb-url)
        require_method github_release direct_download
        load_catalog
        if [ -n "$CAT_URL" ]; then echo "$CAT_URL"; else resolve_deb_url; fi
        ;;

    deb-install)
        require_method github_release direct_download
        run_deb_install
        ;;

    status)
        build_status
        ;;

    install|upgrade)
        support_check
        if [ "$SUP" != true ]; then
            echo "[webclaw-app-admin] unsupported：$APP_ID —— $SUP_MSG" >&2
            exit 3
        fi
        if [ "$ACTION" = upgrade ]; then
            build_status > /dev/null
            [ "$ST_INSTALLED" = true ] || die "$APP_ID 尚未安装，请用 install"
            if ! upgrade_supported; then
                echo "[webclaw-app-admin] unsupported：$APP_ID 的安装脚本不支持重复执行升级（manifest 未声明 upgrade_by_reinstall）" >&2
                exit 3
            fi
            # 只有 catalog 明确给出版本、且不比已装版本新时才跳过；apt 总是交给 apt 判断。
            if [ "$METHOD" != apt ] && [ -n "$CAT_VERSION" ] && [ "$ST_UPDATE" = false ]; then
                log "$APP_ID 已是 catalog 最新版本（$CAT_VERSION），无需升级"
                exit 0
            fi
        fi
        case "$METHOD" in
            apt)
                run_apt_prepare
                run_apt_install "$ACTION"
                /usr/local/bin/webclaw-app-postinstall "$APP_ID"
                ;;
            custom_script)
                # 只执行本地 manifest 声明的、root 所有的固定脚本；catalog 不能影响这里。
                script="$(mf '.install_wrapper // .install_script // empty')"
                check_root_script "$script"
                exec "$script"
                ;;
            *)
                if is_deb_app; then
                    run_deb_install
                    /usr/local/bin/webclaw-app-postinstall "$APP_ID"
                else
                    run_archive_install
                fi
                ;;
        esac
        ;;

    fetch)
        require_method appimage r2_download direct_download cursor_api
        is_deb_app && die "$APP_ID 是 .deb 应用，请用 install"
        record_dir
        rm -f -- "$PENDING"
        load_catalog
        if [ -z "$CAT_URL" ]; then
            log "runtime catalog 里没有 $APP_ID 当前架构（$ARCH）的 artifact"
            exit 3
        fi
        kind="$(webclaw_artifact_kind "$CAT_URL")"
        private_dir stage "$APP_ID"
        download_verified "$CAT_URL" "$stage/artifact" "$CAT_SHA"
        jq -n --arg v "$CAT_VERSION" --arg u "$CAT_URL" --arg s "$CAT_SHA" \
            '{version: $v, source: "catalog", url: $u, sha256: $s}' | write_root_file "$PENDING" 600
        # 交付：root 用 mktemp 在 /tmp 新建一个随机名目录（不会撞上调用者预埋的链接），
        # 把校验过的文件放进去后整体交给调用者。
        out="$(mktemp -d /tmp/webclaw-artifact-"${APP_ID}".XXXXXX)"
        install -m 644 "$stage/artifact" "$out/artifact"
        chown -R "$CALLER_UID:$CALLER_UID" "$out"
        chmod 700 "$out"
        jq -n --arg id "$APP_ID" --arg v "$CAT_VERSION" --arg u "$CAT_URL" --arg s "$CAT_SHA" \
            --arg k "$kind" --arg f "$out/artifact" \
            '{app_id: $id, version: $v, url: $u, sha256: $s, kind: $k, file: $f}'
        ;;

    install-tree)
        require_method appimage r2_download direct_download cursor_api
        layout="${3:-}"
        case "$layout" in
            appdir|flat) kind="dir" ;;
            binary) kind="file" ;;
            *) die "未知布局：$layout（只允许 appdir / flat / binary）" ;;
        esac
        [ "$METHOD" = appimage ] && [ "$layout" != appdir ] && die "appimage 只支持 appdir 布局"
        take_from_tmp stage "/tmp/webclaw-stage-${APP_ID}"
        validate_tree "$stage/item" "$kind"
        install_tree_item "$stage/item" "$layout"
        promote_record
        ;;

    wrapper)
        require_method appimage r2_download direct_download cursor_api
        make_wrapper "${3:-}"
        ;;

    desktop)
        require_method r2_download direct_download cursor_api
        make_desktop
        ;;

    postinstall)
        exec /usr/local/bin/webclaw-app-postinstall "$APP_ID"
        ;;

    uninstall)
        # 卸载器会执行 manifest 里的 uninstall_script：先确认它 root 所有、路径在允许范围内。
        if [ "$METHOD" = custom_script ]; then
            script="$(mf '.uninstall_script // empty')"
            [ -z "$script" ] || check_root_script "$script"
        fi
        /usr/local/bin/webclaw-app-uninstaller "$APP_ID"
        rm -f -- "$RECORD" "$PENDING"
        ;;

    *)
        die "未知动作：$ACTION"
        ;;
esac
