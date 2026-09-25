#!/usr/bin/env bash
# 在 catalog 测试容器里以 root 运行；「ubuntu 能做什么」的检查都真的切到 ubuntu 执行。
set -uo pipefail

pass=0 fail=0
ok()  { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
deny()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d（竟然成功了）"; else ok "$d"; fi; }
as_u()  { runuser -u ubuntu -- "$@"; }
admin() { as_u sudo -n /usr/local/bin/webclaw-app-admin "$@"; }
update() { /usr/local/bin/webclaw-catalog-update "$@"; }
# status 的某个 jq 断言：st <app_id> '<jq 表达式>'
st() { admin status "$1" 2>/dev/null | jq -e "$2" >/dev/null; }
# 返回码断言：rc_is <期望> <命令...>
rc_is() { local want="$1" rc=0; shift; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" = "$want" ]; }
launcher() { as_u env HOME=/home/ubuntu /usr/local/bin/webclaw-app-launcher "$@" </dev/null >/dev/null 2>&1; }
ts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

CACHE=/var/lib/webclaw/catalog/runtime-catalog.json
STATE=/var/lib/webclaw/catalog/state.json
WWW=/srv/www
REMOTE="$WWW/raw.githubusercontent.com/qhkly/webclaw-software-manager/main/runtime-catalog.json"
GH="$WWW/github.com/test-org/ctest-app/releases/download"
GHAI="$WWW/github.com/test-org/ctest-appimage/releases/download"
DL="$WWW/downloads.ctest.example"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) DL_ARCH=x86_64 ;; *) DL_ARCH=aarch64 ;; esac
cache_sum() { sha256sum "$CACHE" 2>/dev/null | awk '{print $1}'; }
installed_ver() { dpkg-query -W -f='${Version}' "${1:-ctest-app}" 2>/dev/null; }
no_stage_left() { test -z "$(ls -A /opt/.webclaw-app-admin 2>/dev/null)" && test -z "$(ls -A /var/lib/webclaw/unpack 2>/dev/null)"; }
no_unpack_procs() {
    local uid p; uid="$(id -u webclaw-unpack)"
    for p in /proc/[0-9]*; do [ "$(stat -c %u "$p" 2>/dev/null)" = "$uid" ] && return 1; done
    return 0
}
sha() { sha256sum "$1" | awk '{print $1}'; }

echo "[0] 本地 HTTPS 服务冒充固定远程地址 + 本地 apt 仓库"
for h in raw.githubusercontent.com github.com api.github.com downloads.ctest.example evil.example; do
    echo "127.0.0.1 $h" >> /etc/hosts
done
mkdir -p "$(dirname "$REMOTE")" "$GH" "$GHAI" "$DL" "$WWW/evil.example" \
    "$WWW/api.github.com/repos/test-org/ctest-appimage/releases"
python3 /opt/test/https-server.py &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null https://github.com/ && break; sleep 0.2; done

# .deb：1.0.0 / 2.0.0 / 3.0.0 是正品；evil 的 Package 名相同，postinst 会 touch /root/pwned。
mk_deb() {  # $1=包名 $2=版本 $3=输出 [$4=evil]
    local d; d="$(mktemp -d)"
    mkdir -p "$d/DEBIAN" "$d/usr/bin"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: catalog test\n' "$1" "$2" > "$d/DEBIAN/control"
    printf '#!/bin/sh\necho %s %s\n' "$1" "$2" > "$d/usr/bin/$1"
    chmod 755 "$d/usr/bin/$1"
    if [ "${4:-}" = evil ]; then
        printf '#!/bin/sh\ntouch /root/pwned\n' > "$d/DEBIAN/postinst"; chmod 755 "$d/DEBIAN/postinst"
    fi
    mkdir -p "$(dirname "$3")"
    dpkg-deb --build --root-owner-group "$d" "$3" >/dev/null
    rm -rf "$d"
}
for v in 1.0.0 2.0.0 3.0.0; do mk_deb ctest-app "$v" "$GH/v$v/ctest-app_${v}_all.deb"; done
mk_deb ctest-app 3.0.0 /tmp/evil.deb evil
SHA_DEB2="$(sha "$GH/v2.0.0/ctest-app_2.0.0_all.deb")"
SHA_DEB3="$(sha "$GH/v3.0.0/ctest-app_3.0.0_all.deb")"
cp /tmp/evil.deb "$GH/v3.0.0/ctest-app_3.0.0_all.deb"   # 远程被换成恶意包，catalog 里仍是正品 sha256

# 单二进制 tar（ctest-dl）与带顶层目录的 tar（ctest-flat）
mk_tgz() {  # $1=版本
    local d; d="$(mktemp -d)"
    printf '#!/bin/sh\necho ctest-dl %s\n' "$1" > "$d/ctest-dl"; chmod 755 "$d/ctest-dl"
    tar -C "$d" -czf "$DL/ctest-dl-$1-$DL_ARCH.tar.gz" ctest-dl
    rm -rf "$d"
}
mk_tgz 1.0.0; mk_tgz 2.0.0; mk_tgz 3.0.0
echo '{"version":"1.0.0"}' > "$DL/ctest-dl-version.json"
SHA_TGZ2="$(sha "$DL/ctest-dl-2.0.0-$DL_ARCH.tar.gz")"
SHA_WRONG="$(printf 'not-the-real-file' | sha256sum | awk '{print $1}')"
FAKE_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
d="$(mktemp -d)"; mkdir -p "$d/ctest-flat-1.0/bin"
printf '#!/bin/sh\necho ctest-flat 1.0\n' > "$d/ctest-flat-1.0/bin/run.sh"; chmod 755 "$d/ctest-flat-1.0/bin/run.sh"
tar -C "$d" -czf "$DL/ctest-flat-1.0.tar.gz" ctest-flat-1.0; rm -rf "$d"
echo '{"version":"1.0"}' > "$DL/ctest-flat-version.json"

# 假 AppImage：--appimage-extract 时生成 squashfs-root；顺带尝试越权写、留后台进程。
mk_appimage() {  # $1=版本 $2=输出 [$3=evil：树里带越界符号链接]
    mkdir -p "$(dirname "$2")"
    {
        printf '#!/bin/sh\n[ "$1" = --appimage-extract ] || exit 1\n'
        printf 'mkdir -p squashfs-root/usr/bin\n'
        printf 'printf "#!/bin/sh\\necho ctest-appimage %s \\$APPDIR\\n" > squashfs-root/AppRun\n' "$1"
        printf 'chmod 755 squashfs-root/AppRun\nid -un > squashfs-root/extracted-by\n'
        printf 'touch /root/pwned-appimage /opt/pwned-appimage 2>/dev/null\n'
        printf '(sleep 60 >/dev/null 2>&1 &)\n'
        [ "${3:-}" = evil ] && printf 'ln -s /etc squashfs-root/etc-link\n'
        printf 'exit 0\n'
    } > "$2"
    chmod 755 "$2"
}
mk_appimage 1.0.0 "$GHAI/v1.0.0/CTest-1.0.0-$DL_ARCH.AppImage"
mk_appimage 2.0.0 "$GHAI/v2.0.0/CTest-2.0.0-$DL_ARCH.AppImage"
mk_appimage 3.0.0 "$GHAI/v3.0.0/CTest-3.0.0-$DL_ARCH.AppImage" evil
echo '{"tag_name":"v1.0.0"}' > "$WWW/api.github.com/repos/test-org/ctest-appimage/releases/latest"
SHA_AI2="$(sha "$GHAI/v2.0.0/CTest-2.0.0-$DL_ARCH.AppImage")"
SHA_AI3="$(sha "$GHAI/v3.0.0/CTest-3.0.0-$DL_ARCH.AppImage")"

# 本地 apt 仓库（只留这一个源，测试不依赖外网）
APTREPO=/srv/apt
mkdir -p "$APTREPO"
publish_apt() {  # 把 $APTREPO 里的 .deb 生成 Packages / Release
    local f
    : > "$APTREPO/Packages"
    for f in "$APTREPO"/*.deb; do
        dpkg-deb -f "$f" Package Version Architecture Maintainer Description >> "$APTREPO/Packages"
        printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(sha "$f")" >> "$APTREPO/Packages"
    done
    printf 'Origin: ctest\nLabel: ctest\nDate: %s\nSHA256:\n %s %s Packages\n' \
        "$(date -u -R)" "$(sha "$APTREPO/Packages")" "$(stat -c %s "$APTREPO/Packages")" > "$APTREPO/Release"
}
mk_deb ctest-aptpkg 1.0 "$APTREPO/ctest-aptpkg_1.0_all.deb"
publish_apt
mkdir -p /etc/apt/sources.list.d.off
mv /etc/apt/sources.list.d/* /etc/apt/sources.list.d.off/ 2>/dev/null || true
: > /etc/apt/sources.list
echo "deb [trusted=yes] file:$APTREPO ./" > /etc/apt/sources.list.d/ctest.list
apt-get update -qq >/dev/null 2>&1

publish() { mkdir -p "$(dirname "$REMOTE")"; cat > "$REMOTE"; }
# 基础合法 catalog：$1 = generated_at（相对时间，如 "-20 days"）；$2 = 额外 jq 修改
good_catalog() {
    jq -n --arg gen "$(ts "${1:--20 days}")" --arg arch "$ARCH" \
        --arg d2 "$SHA_DEB2" --arg t2 "$SHA_TGZ2" --arg a2 "$SHA_AI2" --arg fake "$FAKE_SHA" --arg dla "$DL_ARCH" '
        {schema_version: 1, generated_at: $gen, apps: {
            "ctest-ghdeb": {version: "2.0.0", released_at: "2026-09-20T08:00:00+08:00",
                artifacts: {($arch): {url: "https://github.com/test-org/ctest-app/releases/download/v2.0.0/ctest-app_2.0.0_all.deb", sha256: $d2}}},
            "ctest-dl": {version: "2.0.0",
                artifacts: {($arch): {url: "https://downloads.ctest.example/ctest-dl-2.0.0-\($dla).tar.gz", sha256: $t2}}},
            "ctest-appimage": {version: "2.0.0",
                artifacts: {($arch): {url: "https://github.com/test-org/ctest-appimage/releases/download/v2.0.0/CTest-2.0.0-\($dla).AppImage", sha256: $a2}}},
            "ctest-apt": {version: "1.0"},
            "brand-new-app": {version: "9.9.9",
                artifacts: {($arch): {url: "https://evil.example/pwn.deb", sha256: $fake}}}
        }}' | jq "${2:-.}"
}

echo "[1] 权限与基础 API"
check "updater / 共享库 root 所有、他人不可写" \
    bash -c 'for p in /usr/local/bin/webclaw-catalog-update /usr/local/lib/webclaw/runtime-catalog.sh /usr/local/lib/webclaw /var/lib/webclaw/catalog; do [ "$(stat -c %U "$p")" = root ] && [ -z "$(find "$p" -maxdepth 0 -perm /022)" ] || exit 1; done'
deny  "ubuntu 不能 sudo 运行 updater"            as_u sudo -n /usr/local/bin/webclaw-catalog-update
deny  "ubuntu 直接运行 updater 被拒绝"           as_u /usr/local/bin/webclaw-catalog-update
deny  "ubuntu 不能写 cache 目录"                 as_u touch /var/lib/webclaw/catalog/x
deny  "ubuntu 进不了解包目录"                    as_u ls /var/lib/webclaw/unpack
deny  "updater 拒绝任意参数"                     update --url https://evil.example/x.json
check "webclaw-sudoers-audit 通过"               webclaw-sudoers-audit
check "api-version 输出合法 JSON 且 api_version=2" bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin api-version | jq -e '.api_version == 2 and .catalog_schema == 1' >/dev/null"
deny  "api-version 不接受多余参数"               admin api-version x
check "catalog-info（无 cache）合法 JSON"        bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin catalog-info | jq -e '.cache_present == false' >/dev/null"
check "status 顶层字段齐全（Software Manager v2 契约）" \
    st ctest-ghdeb 'has("supported") and has("message") and has("installed") and has("installed_version") and has("latest_version") and has("update_available") and has("upgrade_supported") and has("catalog_state") and .catalog_state == "unavailable"'

echo "[2] 没有 catalog（远程 404）：旧逻辑照常"
rm -f "$REMOTE"
deny  "远程 404 时 updater 失败"                 update
check "失败后没有生成 cache"                     test ! -e "$CACHE"
check "state 记录了错误"                         bash -c "jq -e '.last_error | length > 0' $STATE >/dev/null"
check "catalog_state=unavailable"                st ctest-ghdeb '.catalog_state == "unavailable"'
check "[deb] install 走旧逻辑（manifest 固定 v1.0.0）" admin install ctest-ghdeb
check "  → 装上 1.0.0"                           test "$(installed_ver)" = 1.0.0
check "  → status：installed、版本来自 dpkg、latest 未知" \
    st ctest-ghdeb '.installed and .installed_version == "1.0.0" and .installed_version_source == "dpkg" and .latest_version == null and .catalog == null and .update_available == null and .supported'
check "[AppImage] install 走旧逻辑（GitHub latest → v1.0.0）" admin install ctest-appimage
check "  → wrapper 可运行、带 APPDIR"            bash -c "runuser -u ubuntu -- /opt/ondemand-apps/ctest-appimage/ctest-appimage | grep -qx 'ctest-appimage 1.0.0 /opt/ondemand-apps/ctest-appimage/AppDir'"
check "  → status 版本来自安装记录"              st ctest-appimage '.installed and .installed_version == "1.0.0" and .installed_version_source == "record"'
check "[tar 单文件] install 走旧逻辑（version_api → 1.0.0）" admin install ctest-dl
check "  → 装上 1.0.0"                           bash -c "/opt/ctest-dl/ctest-dl | grep -qx 'ctest-dl 1.0.0'"
check "[tar 目录] install（launch_script 作入口）" admin install ctest-flat
check "  → binary 与 wrapper 都可运行"           bash -c "/opt/ctest-flat/bin/run.sh | grep -q 1.0 && /opt/ctest-flat/ctest-flat | grep -q 1.0"
check "  → desktop 指向受管 wrapper"              grep -qx 'Exec=/opt/ctest-flat/ctest-flat %F' /usr/share/applications/ctest-flat.desktop
check "没有 catalog 时 fetch 返回 3"             rc_is 3 admin fetch ctest-dl
check "没有遗留 root 暂存/解包目录"              no_stage_left

echo "[3] apt：install → status → upgrade"
check "apt install"                              admin install ctest-apt
check "  → 装上 1.0"                             test "$(installed_ver ctest-aptpkg)" = 1.0
check "  → status：latest（apt 候选 1.0），无更新" st ctest-apt '.installed and .installed_version == "1.0" and .latest_version == "1.0" and .update_available == false and .upgrade_supported'
mk_deb ctest-aptpkg 2.0 "$APTREPO/ctest-aptpkg_2.0_all.deb"; publish_apt
check "apt upgrade（仓库有 2.0；apt 不按 catalog 跳过）" admin upgrade ctest-apt
check "  → 升到 2.0"                             test "$(installed_ver ctest-aptpkg)" = 2.0
check "  → status 版本 2.0"                      st ctest-apt '.installed_version == "2.0"'

echo "[4] 合法 catalog：原子更新、未知 app 被丢弃、跨 API upgrade"
good_catalog | publish
check "updater 成功"                             update
check "cache root:root 0644"                     test "$(stat -c %U:%G:%a "$CACHE")" = root:root:644
check "未知 app（本地无 manifest）没有进入 cache" bash -c "jq -e '.apps | has(\"brand-new-app\") | not' $CACHE >/dev/null"
check "目录里没有遗留临时文件"                   test -z "$(find /var/lib/webclaw -name '.catalog-work.*' -o -name '.runtime-catalog.*' -o -name '.state.*' | head -1)"
check "catalog_state=fresh"                      st ctest-ghdeb '.catalog_state == "fresh"'
check "[deb] status：latest_version=2.0.0、update_available=true" \
    st ctest-ghdeb '.latest_version == "2.0.0" and .latest_version_source == "catalog" and .catalog.version == "2.0.0" and .update_available == true'
check "[deb] upgrade"                            admin upgrade ctest-ghdeb
check "  → 2.0.0，update_available=false"        bash -c "test \"\$(dpkg-query -W -f='\${Version}' ctest-app)\" = 2.0.0"
check "  → status 无更新"                        st ctest-ghdeb '.installed_version == "2.0.0" and .update_available == false'
check "  → 已是最新时 upgrade 直接成功返回"      bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin upgrade ctest-ghdeb 2>&1 | grep -q 无需升级"
check "[AppImage] status：1.0.0 → latest 2.0.0"  st ctest-appimage '.installed_version == "1.0.0" and .latest_version == "2.0.0" and .update_available == true and .upgrade_supported'
check "[AppImage] upgrade"                       admin upgrade ctest-appimage
check "  → 运行的是 2.0.0"                       bash -c "runuser -u ubuntu -- /opt/ondemand-apps/ctest-appimage/ctest-appimage | grep -q 'ctest-appimage 2.0.0'"
check "  → status 2.0.0、来源 catalog、无更新"   st ctest-appimage '.installed_version == "2.0.0" and .update_available == false'
check "  → 解包以 webclaw-unpack 身份执行"       grep -qx webclaw-unpack /opt/ondemand-apps/ctest-appimage/AppDir/extracted-by
check "  → 解包代码没能写 /root、/opt"           test ! -e /root/pwned-appimage -a ! -e /opt/pwned-appimage
check "  → 解包用户没有残留进程"                 no_unpack_procs
check "  → 安装树 root 所有、他人不可写"         test -z "$(find /opt/ondemand-apps/ctest-appimage ! -user root -print -quit)" -a -z "$(find /opt/ondemand-apps/ctest-appimage ! -type l -perm /022 -print -quit)"
check "[tar] upgrade 到 catalog 2.0.0"           admin upgrade ctest-dl
check "  → 2.0.0"                                bash -c "/opt/ctest-dl/ctest-dl | grep -qx 'ctest-dl 2.0.0'"
check "  → status 版本来自记录"                  st ctest-dl '.installed_version == "2.0.0" and .installed_version_source == "record" and .update_available == false'
check "没有遗留 root 暂存/解包目录"              no_stage_left

echo "[5] 不合规 catalog 整份拒绝，last-known-good 不被覆盖"
GOOD_SUM="$(cache_sum)"
reject() {  # $1=描述；stdin=远程内容
    publish
    if update >/tmp/upd.log 2>&1; then
        bad "$1（竟然被接受）"
    elif [ "$(cache_sum)" != "$GOOD_SUM" ]; then
        bad "$1（被拒绝但 cache 变了）"
    else
        ok "$1"
    fi
}
echo '{"schema_version":1,' | reject "坏 JSON"
good_catalog "-19 days" '.schema_version = 2' | reject "schema_version=2"
good_catalog "-19 days" '.schema_version = "1"' | reject "schema_version 是字符串"
good_catalog "-19 days" 'del(.generated_at)' | reject "缺 generated_at"
good_catalog "-19 days" '.generated_at = "yesterday"' | reject "generated_at 不是 RFC3339"
good_catalog "-19 days" '.extra = 1' | reject "未知顶层字段"
good_catalog "-19 days" '.apps["ctest-ghdeb"].install_method = "custom_script"' | reject "条目试图带 install_method"
good_catalog "-19 days" '.apps["ctest-ghdeb"].install_script = "/tmp/x.sh"' | reject "条目试图带 install_script"
good_catalog "-19 days" '.apps["ctest-ghdeb"].package = "bash"' | reject "条目试图带 package"
good_catalog "-19 days" '.apps["ctest-dl"].binary = "/usr/bin/sudo"' | reject "条目试图带 binary"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.path = \"/etc\"" | reject "artifact 试图带 path"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.sha256 = \"ABC\"" | reject "sha256 太短"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.sha256 |= ascii_upcase" | reject "sha256 大写"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url |= sub(\"^https\"; \"http\")" | reject "http:// URL"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url = \"https://github.com/other-org/ctest-app/releases/download/v2.0.0/ctest-app_2.0.0_all.deb\"" | reject "github repo 越界"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url = \"https://github.com/test-org/ctest-app/archive/x.deb\"" | reject "github 非 releases/download 路径"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url = \"https://github.com/test-org/ctest-app/releases/download/../../../../evil/r/releases/download/x.deb\"" | reject "../ 路径穿越"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url = \"https://github.com/test-org/ctest-app/releases/download/%2e%2e/x.deb\"" | reject "编码的 ../"
good_catalog "-19 days" ".apps[\"ctest-ghdeb\"].artifacts.$ARCH.url = \"https://github.com@evil.example/test-org/ctest-app/releases/download/v1/x.deb\"" | reject "userinfo 伪装 host"
good_catalog "-19 days" ".apps[\"ctest-dl\"].artifacts.$ARCH.url = \"https://evil.example/ctest-dl-2.0.0.tar.gz\"" | reject "direct_download 换 host"
good_catalog "-19 days" ".apps[\"ctest-dl\"].artifacts.$ARCH.url = \"https://downloads.ctest.example.evil.example/x.tar.gz\"" | reject "host 前缀拼接绕过"
good_catalog "-19 days" ".apps[\"ctest-dl\"].artifacts.$ARCH.url = \"https://downloads.ctest.example/ctest-dl.AppImage\"" | reject "改变安装包类型（tar → AppImage）"
good_catalog "-19 days" ".apps[\"ctest-appimage\"].artifacts.$ARCH.url = \"https://github.com/test-org/ctest-appimage/releases/download/v2.0.0/x.deb\"" | reject "改变安装包类型（AppImage → deb）"
good_catalog "-19 days" ".apps[\"ctest-apt\"].artifacts = {\"$ARCH\": {\"url\": \"https://downloads.ctest.example/x.deb\", \"sha256\": \"$FAKE_SHA\"}}" | reject "apt 应用带下载地址"
good_catalog "-19 days" ".apps[\"ctest-custom\"] = {version: \"1\", artifacts: {\"$ARCH\": {url: \"https://downloads.ctest.example/x.sh\", sha256: \"$FAKE_SHA\"}}}" | reject "custom_script 应用带下载地址"
good_catalog "-19 days" '.apps["ctest-ghdeb"].artifacts.riscv64 = .apps["ctest-ghdeb"].artifacts[]' | reject "未知架构"
good_catalog "-19 days" ".apps[\"ctest-noarch\"] = {version: \"1\", artifacts: {\"$ARCH\": {url: \"https://downloads.ctest.example/ctest-noarch.tar.gz\", sha256: \"$FAKE_SHA\"}}}" | reject "本地策略声明不支持的架构"
good_catalog "-19 days" '.apps["Evil_ID"] = {version: "1"}' | reject "非法 app_id"
good_catalog "-19 days" '.apps["ctest-ghdeb"].version = "1.0; rm -rf /"' | reject "非法 version"
{ good_catalog "-19 days"; good_catalog "-19 days"; } | reject "多个 JSON 值"
good_catalog "-30 days" | reject "generated_at 早于 cache（防回滚）"
good_catalog "+3 days" | reject "generated_at 超前本机 24 小时以上（防冻结）"
good_catalog "+400 days" | reject "generated_at 极远未来（防冻结）"
head -c 1100000 /dev/zero | tr '\0' ' ' | reject "超过大小上限"
check "拒绝之后 catalog_state=offline（仍在用 last-known-good）" st ctest-ghdeb '.catalog_state == "offline" and .latest_version == "2.0.0"'
good_catalog "-19 days" | publish
check "未来时间被拒之后，正常 catalog 仍能更新（没有被冻结）" update
check "  → catalog_state 回到 fresh"             st ctest-ghdeb '.catalog_state == "fresh"'
jq '.last_success_epoch = 1000' "$STATE" > /tmp/state.json && cat /tmp/state.json > "$STATE"
check "超过 24 小时没刷新成功 → catalog_state=stale" st ctest-ghdeb '.catalog_state == "stale"'

echo "[6] 未知 app 得不到安装能力；cache 被篡改时 broker 重新校验"
deny  "未知 app install 被拒绝"                  admin install brand-new-app
deny  "未知 app fetch 被拒绝"                    admin fetch brand-new-app
deny  "未知 app status 被拒绝"                   admin status brand-new-app
cp "$CACHE" /tmp/cache.bak
jq --arg arch "$ARCH" --arg fake "$FAKE_SHA" '.apps["brand-new-app"] = {version: "1", artifacts: {($arch): {url: "https://evil.example/pwn.deb", sha256: $fake}}}
    | .apps["ctest-ghdeb"].artifacts[$arch].url = "https://evil.example/ctest-app.deb"' /tmp/cache.bak > "$CACHE"
deny  "cache 里被塞进未知 app 也装不了"          admin install brand-new-app
check "cache 里越界的 url 被 broker 忽略，回退 manifest 地址" \
    bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin deb-url ctest-ghdeb 2>/dev/null | grep -qx 'https://github.com/test-org/ctest-app/releases/download/v1.0.0/ctest-app_1.0.0_all.deb'"
cp /tmp/cache.bak "$CACHE"
chown ubuntu "$CACHE"
check "cache 不是 root 所有时被当作不存在"       st ctest-ghdeb '.catalog == null and .catalog_state == "unavailable"'
chown root "$CACHE"

echo "[7] sha256 不匹配 / 恶意归档绝不安装"
good_catalog "-18 days" ".apps[\"ctest-ghdeb\"] = {version: \"3.0.0\", artifacts: {\"$ARCH\": {url: \"https://github.com/test-org/ctest-app/releases/download/v3.0.0/ctest-app_3.0.0_all.deb\", sha256: \"$SHA_DEB3\"}}}
    | .apps[\"ctest-dl\"].version = \"3.0.0\" | .apps[\"ctest-dl\"].artifacts[\"$ARCH\"] = {url: \"https://downloads.ctest.example/ctest-dl-3.0.0-$DL_ARCH.tar.gz\", sha256: \"$SHA_WRONG\"}
    | .apps[\"ctest-appimage\"].version = \"3.0.0\" | .apps[\"ctest-appimage\"].artifacts[\"$ARCH\"] = {url: \"https://github.com/test-org/ctest-appimage/releases/download/v3.0.0/CTest-3.0.0-$DL_ARCH.AppImage\", sha256: \"$SHA_AI3\"}" | publish
check "catalog（3.0.0）被接受（updater 不下载安装包）" update
rm -f /root/pwned
deny  "[deb] 远程包被换掉时 upgrade 失败"        admin upgrade ctest-ghdeb
check "  → 恶意 postinst 没有执行"               test ! -e /root/pwned
check "  → 仍是 2.0.0"                           test "$(installed_ver)" = 2.0.0
check "  → 日志里明确是 sha256 不匹配"           bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin upgrade ctest-ghdeb 2>&1 | grep -q 'sha256 不匹配'"
deny  "[tar] sha256 不匹配时 upgrade 失败"       admin upgrade ctest-dl
check "  → 仍是 2.0.0"                           bash -c "/opt/ctest-dl/ctest-dl | grep -qx 'ctest-dl 2.0.0'"
rc=0; admin fetch ctest-dl >/dev/null 2>&1 || rc=$?
check "[tar] fetch 遇到 sha256 不匹配时失败且不是 3" test "$rc" != 0 -a "$rc" != 3
check "  → 没有交付任何文件给调用者"             test -z "$(ls -d /tmp/webclaw-artifact-ctest-dl.* 2>/dev/null)"
deny  "[AppImage] 解包结果含越界符号链接时 upgrade 失败" admin upgrade ctest-appimage
check "  → 旧版本（2.0.0）原样保留"              bash -c "runuser -u ubuntu -- /opt/ondemand-apps/ctest-appimage/ctest-appimage | grep -q 'ctest-appimage 2.0.0'"
check "  → status 仍是 2.0.0"                    st ctest-appimage '.installed_version == "2.0.0"'
check "没有遗留 root 暂存/解包目录、没有解包进程" bash -c "$(declare -f no_stage_left no_unpack_procs); no_stage_left && no_unpack_procs"

echo "[8] 不支持 / custom_script 升级语义"
check "不支持当前架构：status supported=false 且有 message" st ctest-noarch '.supported == false and (.message | length > 0) and .upgrade_supported == false'
check "不支持当前架构：install 返回 3 并说明 unsupported" \
    bash -c "out=\$(runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin install ctest-noarch 2>&1); rc=\$?; [ \$rc = 3 ] && echo \"\$out\" | grep -q unsupported"
check "安装脚本在 /tmp：status supported=false"  st ctest-badcustom '.supported == false'
check "安装脚本在 /tmp：install 返回 3"          rc_is 3 admin install ctest-badcustom
rm -f /var/log/ctest-custom-runs
check "[custom] install（经 broker）"            admin install ctest-custom
check "  → 脚本以 root 运行"                     grep -qx 'ran as root' /opt/ctest-custom/ran
check "  → status：upgrade_supported（manifest 声明 upgrade_by_reinstall）" st ctest-custom '.installed and .supported and .upgrade_supported and .upgrade_via == "broker"'
check "[custom] upgrade 重新执行同一个受信脚本"  admin upgrade ctest-custom
check "  → 脚本共执行 2 次"                      test "$(wc -l < /var/log/ctest-custom-runs)" = 2
check "未声明 upgrade_by_reinstall：status upgrade_supported=false 且有 message" \
    st ctest-custom2 '.installed and .supported and .upgrade_supported == false and (.message | length > 0)'
check "  → upgrade 明确返回 3（unsupported）"    rc_is 3 admin upgrade ctest-custom2
chmod 777 /opt/ctest-install.sh
check "可被他人写的 install_script：supported=false" st ctest-custom '.supported == false'
deny  "  → install 被拒绝"                       admin install ctest-custom
chmod 755 /opt/ctest-install.sh
check "broker uninstall custom_script"           admin uninstall ctest-custom
check "  → 已卸载"                               test ! -e /opt/ctest-custom

echo "[9] launcher 回归（zenity 为桩）"
good_catalog "-17 days" | publish
check "恢复合法 catalog"                         update
check "launcher 卸载 ctest-ghdeb"                launcher --uninstall ctest-ghdeb
check "  → 已卸载"                               bash -c "! dpkg -s ctest-app >/dev/null 2>&1"
check "launcher 安装 .deb 应用"                  launcher ctest-ghdeb
check "  → 经 broker 高层 install 按 catalog 装上 2.0.0" test "$(installed_ver)" = 2.0.0
check "  → 日志里是 broker 的 catalog 安装"      grep -q '使用 runtime catalog：version=2.0.0' /tmp/webclaw-ondemand-ctest-ghdeb.log
check "  → broker status 识别为已安装"           st ctest-ghdeb '.installed and .installed_version == "2.0.0"'
check "launcher 不再直接调用低层 deb-install / apt-install / sudo 脚本" \
    bash -c "! grep -Eq 'admin (deb-install|apt-install|apt-prepare)|sudo -n \"\\\$INSTALL_WRAPPER\"' /usr/local/bin/webclaw-app-launcher"
check "broker uninstall ctest-dl"                admin uninstall ctest-dl
check "  → 安装记录已删除、status 未安装"        bash -c "test ! -e /var/lib/webclaw/installed/ctest-dl.json"
check "  → status 未安装"                        st ctest-dl '.installed == false and .installed_version == null'
check "launcher 安装 tar 应用（经 broker install）" launcher ctest-dl
check "  → 装上的是 catalog 的 2.0.0"            bash -c "/opt/ctest-dl/ctest-dl | grep -qx 'ctest-dl 2.0.0'"
check "  → 日志里是 broker 的 catalog 安装"      grep -q '使用 runtime catalog：version=2.0.0' /tmp/webclaw-ondemand-ctest-dl.log
check "  → status 识别"                          st ctest-dl '.installed and .installed_version == "2.0.0" and .update_available == false'
check "launcher --upgrade AppImage 应用（已是最新 → 直接成功）" launcher --upgrade ctest-appimage
check "  → 仍可运行"                             bash -c "runuser -u ubuntu -- /opt/ondemand-apps/ctest-appimage/ctest-appimage | grep -q 2.0.0"
admin uninstall ctest-dl >/dev/null 2>&1
good_catalog "-16 days" ".apps[\"ctest-dl\"].artifacts[\"$ARCH\"].sha256 = \"$SHA_WRONG\"" | publish
check "发布 sha256 错误的 ctest-dl"              update
deny  "launcher 遇到 sha256 不匹配时安装失败"    launcher ctest-dl
check "  → 没有装上"                             test ! -e /opt/ctest-dl/ctest-dl
check "  → 明确没有回退旧流程"                   grep -q 'not falling back' /tmp/webclaw-ondemand-ctest-dl.log
good_catalog "-15 days" 'del(.apps["ctest-dl"])' | publish
check "发布不含 ctest-dl 的 catalog"             update
check "launcher 回退旧解析（version_api → 1.0.0）" launcher ctest-dl
check "  → 装上的是 1.0.0"                       bash -c "/opt/ctest-dl/ctest-dl | grep -qx 'ctest-dl 1.0.0'"
check "  → status 版本 1.0.0（来自旧逻辑解析）、latest 未知" st ctest-dl '.installed and .installed_version == "1.0.0" and .latest_version == null and .update_available == null'
check "launcher 安装 custom_script 应用（经 broker install）" launcher ctest-custom
check "  → 脚本以 root 运行"                     grep -qx 'ran as root' /opt/ctest-custom/ran
runs_before="$(wc -l < /var/log/ctest-custom-runs)"
check "launcher --upgrade custom_script（upgrade_by_reinstall=true）成功" launcher --upgrade ctest-custom
check "  → 受信脚本被重新执行了一次"             test "$(wc -l < /var/log/ctest-custom-runs)" = $((runs_before + 1))
check "  → 走的是 broker upgrade"                bash -c "! grep -q unsupported /tmp/webclaw-ondemand-ctest-custom.log"
: > /tmp/zenity.log
deny  "launcher --upgrade 未声明 upgrade_by_reinstall 的 custom_script 失败" launcher --upgrade ctest-custom2
check "  → 脚本没有被执行"                       test "$(wc -l < /var/log/ctest-custom-runs)" = $((runs_before + 1))
check "  → broker 明确返回 unsupported"          grep -q 'unsupported' /tmp/webclaw-ondemand-ctest-custom2.log
check "  → 用户看到「暂不支持自动升级」"         grep -q '暂不支持自动升级' /tmp/zenity.log
check "launcher 的 custom_script 分支用 BROKER_VERB 调 broker（不自行判断、不直接 sudo 脚本）" \
    grep -qF 'admin "$BROKER_VERB" "$APP_ID" >>"$LOG" 2>&1 &' /usr/local/bin/webclaw-app-launcher

echo "[10] 签名 hook（配置公钥后签名成为强制项）"
mkdir -p /etc/webclaw
openssl genpkey -algorithm ed25519 -out /tmp/sign.key 2>/dev/null
openssl pkey -in /tmp/sign.key -pubout -out /etc/webclaw/runtime-catalog.pub 2>/dev/null
chmod 644 /etc/webclaw/runtime-catalog.pub
GOOD_SUM="$(cache_sum)"
good_catalog "-14 days" | publish
rm -f "$REMOTE.sig"
deny  "有公钥但没有签名：拒绝"                   update
check "  → cache 未变"                           test "$(cache_sum)" = "$GOOD_SUM"
printf 'garbage-signature-of-64-bytes-garbage-signature-of-64-bytes-xx' > "$REMOTE.sig"
deny  "签名错误：拒绝"                           update
openssl pkeyutl -sign -inkey /tmp/sign.key -rawin -in "$REMOTE" -out "$REMOTE.sig" 2>/dev/null
check "签名正确：接受"                           update
check "catalog-info 报告 signature_required"     bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin catalog-info | jq -e '.signature_required == true' >/dev/null"
chown ubuntu /etc/webclaw/runtime-catalog.pub
deny  "公钥不是 root 所有：拒绝"                 update
rm -rf /etc/webclaw "$REMOTE.sig" /tmp/sign.key

echo "[11] 节流 / 环境变量不能换远程地址"
good_catalog "-13 days" | publish
check "正常刷新"                                 update
before="$(jq -r .last_attempt_epoch "$STATE")"
echo 'broken' | publish
check "--if-stale 在 6 小时内直接跳过"            update --if-stale
check "  → 没有发起新的尝试"                     test "$(jq -r .last_attempt_epoch "$STATE")" = "$before"
good_catalog "-1 hours" '.apps["ctest-ghdeb"].version = "66.6.6"' > "$WWW/evil.example/c.json"
good_catalog "-12 days" | publish
check "带 WEBCLAW_CATALOG_URL 环境变量运行"      env WEBCLAW_CATALOG_URL=https://evil.example/c.json /usr/local/bin/webclaw-catalog-update
check "  → 仍然拉的是固定地址"                   bash -c "jq -e --arg g '$(ts "-12 days" | cut -c1-10)' '.generated_at | startswith(\$g)' $CACHE >/dev/null"

echo "[12] 全局 mutation 锁：并发安装不会互相 kill，只读 status 不受影响"
# 慢 AppImage：解包时先 sleep 6 秒，结束后才写 finished；若解包进程被别人 kill，安装会失败。
mkdir -p "$WWW/api.github.com/repos/test-org/ctest-slow/releases" "$WWW/github.com/test-org/ctest-slow/releases/download/v1.0.0"
echo '{"tag_name":"v1.0.0"}' > "$WWW/api.github.com/repos/test-org/ctest-slow/releases/latest"
{
    printf '#!/bin/sh\n[ "$1" = --appimage-extract ] || exit 1\n'
    printf 'sleep 6\nmkdir -p squashfs-root\n'
    printf 'printf "#!/bin/sh\\necho slow-ok\\n" > squashfs-root/AppRun\nchmod 755 squashfs-root/AppRun\n'
    printf 'echo finished > squashfs-root/finished\nexit 0\n'
} > "$WWW/github.com/test-org/ctest-slow/releases/download/v1.0.0/Slow-1.0.0-$DL_ARCH.AppImage"
chmod 755 "$WWW/github.com/test-org/ctest-slow/releases/download/v1.0.0/Slow-1.0.0-$DL_ARCH.AppImage"
check "锁目录 root:root 0700"                    test "$(stat -c %U:%G:%a /run/webclaw-app-admin)" = root:root:700
check "锁文件 root 所有的普通文件"               bash -c 'f=/run/webclaw-app-admin/mutation.lock; [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %U "$f")" = root ]'
deny  "ubuntu 不能在锁目录里建文件"              as_u touch /run/webclaw-app-admin/x
admin uninstall ctest-flat >/dev/null 2>&1
unpack_count() { find /var/lib/webclaw/unpack -mindepth 1 -maxdepth 1 -name 'job.*' | wc -l; }
( admin install ctest-slow >/tmp/slow.log 2>&1; echo "$?" > /tmp/slow.rc; date +%s.%N > /tmp/slow.end ) &
A=$!
for _ in $(seq 1 100); do no_unpack_procs || break; sleep 0.1; done
check "A（慢 AppImage）已进入 webclaw-unpack 解包" bash -c "$(declare -f no_unpack_procs); ! no_unpack_procs"
( admin install ctest-flat >/tmp/flat.log 2>&1; echo "$?" > /tmp/flat.rc; date +%s.%N > /tmp/flat.end ) &
B=$!
sleep 1
max_jobs=0
t0="$(date +%s)"
check "A 解包期间只读 status 仍立即返回"         timeout 5 bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin status ctest-slow | jq -e . >/dev/null"
check "A 解包期间 api-version / catalog-info 仍立即返回" timeout 5 bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin api-version >/dev/null && runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin catalog-info >/dev/null"
while kill -0 "$A" 2>/dev/null; do
    n="$(unpack_count)"; [ "$n" -gt "$max_jobs" ] && max_jobs="$n"
    sleep 0.1
done
check "A 解包期间 B 没有进入下载/解包（同一时刻最多 1 个解包任务）" test "$max_jobs" -le 1
check "B 在等待锁时有明确提示"                   grep -q '正在进行，等待其完成' /tmp/flat.log
wait "$A"; wait "$B"
check "A 成功（没有被 B kill）"                  test "$(cat /tmp/slow.rc)" = 0
check "  → A 的解包完整跑完"                     grep -qx finished /opt/ondemand-apps/ctest-slow/AppDir/finished
check "B 成功"                                   test "$(cat /tmp/flat.rc)" = 0
check "  → B 在 A 结束之后才完成（被串行化）"    bash -c "awk -v a=\"\$(cat /tmp/slow.end)\" -v b=\"\$(cat /tmp/flat.end)\" 'BEGIN{exit !(b >= a)}'"
check "  → 两个应用都能被 status 识别"           bash -c "runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin status ctest-slow | jq -e .installed >/dev/null && runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin status ctest-flat | jq -e .installed >/dev/null"
check "custom_script 留下的常驻进程不持有锁（下一个 mutating 动作 20s 内完成）" \
    timeout 20 runuser -u ubuntu -- sudo -n /usr/local/bin/webclaw-app-admin uninstall ctest-slow
deny  "sudo 不允许 ubuntu 传入 WEBCLAW_APP_ADMIN_LOCKED 绕过锁" \
    runuser -u ubuntu -- sudo -n WEBCLAW_APP_ADMIN_LOCKED=1 /usr/local/bin/webclaw-app-admin uninstall ctest-flat
check "没有遗留 root 暂存/解包目录、没有解包进程" bash -c "$(declare -f no_stage_left no_unpack_procs); no_stage_left && no_unpack_procs"

echo "[13] 离线：已有 cache 与旧逻辑照常"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
GOOD_SUM="$(cache_sum)"
deny  "离线时 updater 失败"                      update
check "  → last-known-good 保留"                 test "$(cache_sum)" = "$GOOD_SUM"
check "  → status 仍可用：catalog_state=offline、latest 来自 cache" st ctest-ghdeb '.installed and .catalog_state == "offline" and .latest_version == "2.0.0"'
check "  → 已装应用照常识别"                     st ctest-appimage '.installed and .installed_version == "2.0.0"'
check "webclaw-sudoers-audit 仍通过"             webclaw-sudoers-audit
check "没有遗留 root 暂存/解包目录"              no_stage_left

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
