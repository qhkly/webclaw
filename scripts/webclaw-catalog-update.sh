#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-catalog-update —— 拉取运行时软件目录（runtime catalog），校验后原子落盘。
#  安装位置：/usr/local/bin/webclaw-catalog-update（root:root 0755，不在 sudoers 里）
#
#  用法：webclaw-catalog-update [--if-stale]
#    --if-stale  6 小时内成功过、或 10 分钟内尝试过就直接退出（startup 后台用）。
#  远程地址固定写在 runtime-catalog.sh 里，不接受参数或环境变量覆盖。
#
#  流程：flock 串行 → 下载到 root 私有临时目录 → （配置了公钥时）校验 detached 签名
#        → 严格 schema + 本地 source policy 校验 → 防回滚 / 防未来时间冻结 → 原子 rename 到 cache。
#  任何一步失败：旧 cache（last-known-good）原样保留，只在 state.json 里记下错误。
#  单个已知 app 的条目不合规 = 整份 catalog 拒绝（fail closed）。
#  未知 app_id 被丢弃，不会写进 cache，也就不可能凭空得到 root 安装能力。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LIB=/usr/local/lib/webclaw/runtime-catalog.sh
STALE_SUCCESS_SECS=$((6 * 3600))
STALE_ATTEMPT_SECS=600
MAX_FUTURE_SKEW_SECS=$((24 * 3600))

die()  { echo "[webclaw-catalog-update] 错误：$*" >&2; exit 2; }
log()  { echo "[webclaw-catalog-update] $*" >&2; }

[ "$(id -u)" = 0 ] || die "必须以 root 运行"

IF_STALE=0
case "$#:${1:-}" in
    0:) ;;
    1:--if-stale) IF_STALE=1 ;;
    *) die "不接受参数（只允许 --if-stale）" ;;
esac

# 被 source 的库和它的上级目录必须 root 所有、不可被他人写。
trusted_path() {
    local p="$1"
    while :; do
        [ -e "$p" ] && [ ! -L "$p" ] || die "$p 不存在或是符号链接"
        [ "$(stat -c %u "$p")" = 0 ] || die "$p 不是 root 所有"
        [ -z "$(find "$p" -maxdepth 0 -perm /022 2>/dev/null)" ] || die "$p 可被 group/other 写"
        [ "$p" = / ] && break
        p="$(dirname "$p")"
    done
}
trusted_path "$LIB"
# shellcheck source=lib/runtime-catalog.sh
. "$LIB"

# cache 目录：root:root 0755，文件 0644（内容不是秘密，software-manager 可以只读）。
install -d -m 755 -o root -g root /var/lib/webclaw "$WEBCLAW_CATALOG_DIR"
trusted_path "$WEBCLAW_CATALOG_DIR"

exec 9>"$WEBCLAW_CATALOG_DIR/.lock"
flock -w 120 9 || die "等待锁超时"

now="$(date +%s)"
state_get() { jq -r --arg k "$1" '.[$k] // empty' "$WEBCLAW_CATALOG_STATE" 2>/dev/null || true; }

if [ "$IF_STALE" = 1 ] && [ -f "$WEBCLAW_CATALOG_STATE" ]; then
    last_ok="$(state_get last_success_epoch)"
    last_try="$(state_get last_attempt_epoch)"
    if [[ "$last_ok" =~ ^[0-9]+$ ]] && [ $((now - last_ok)) -lt "$STALE_SUCCESS_SECS" ] \
        && [ -f "$WEBCLAW_CATALOG_FILE" ]; then
        log "6 小时内已成功刷新过，跳过"
        exit 0
    fi
    if [[ "$last_try" =~ ^[0-9]+$ ]] && [ $((now - last_try)) -lt "$STALE_ATTEMPT_SECS" ]; then
        log "10 分钟内刚尝试过，跳过"
        exit 0
    fi
fi

# state.json：只记录时间和简短错误，不含任何下载内容。
write_state() {
    local result="$1" msg="$2" tmp
    msg="$(printf '%s' "$msg" | tr -d '\000-\037' | cut -c1-400)"
    tmp="$(mktemp "$WEBCLAW_CATALOG_DIR/.state.XXXXXX")"
    {
        if [ -f "$WEBCLAW_CATALOG_STATE" ]; then cat "$WEBCLAW_CATALOG_STATE"; else echo '{}'; fi
    } | jq --arg r "$result" --arg m "$msg" --argjson now "$now" \
        --arg iso "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" '
        (if type == "object" then . else {} end)
        | .last_attempt_epoch = $now | .last_attempt_at = $iso
        | if $r == "ok" then .last_success_epoch = $now | .last_success_at = $iso | .last_error = null | .last_error_at = null
          else .last_error = $m | .last_error_at = $iso end' > "$tmp" 2>/dev/null \
        || jq -n --arg m "$msg" --argjson now "$now" '{last_attempt_epoch: $now, last_error: $m}' > "$tmp"
    chmod 644 "$tmp"
    mv -Tf -- "$tmp" "$WEBCLAW_CATALOG_STATE"
}

WORK="$(mktemp -d /var/lib/webclaw/.catalog-work.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    write_state error "$*"
    log "拒绝：$*（保留旧 cache）"
    exit 1
}

# -q：不读 ~/.curlrc；只允许 https，包括重定向。
fetch() {
    curl -q -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 60 \
        --max-filesize "$WEBCLAW_CATALOG_MAX_BYTES" -o "$2" "$1"
}

log "拉取 $WEBCLAW_CATALOG_URL"
fetch "$WEBCLAW_CATALOG_URL" "$WORK/catalog.json" || fail "下载失败（离线或远程不可达）"
size="$(stat -c %s "$WORK/catalog.json")"
[ "$size" -le "$WEBCLAW_CATALOG_MAX_BYTES" ] || fail "catalog 超过 $WEBCLAW_CATALOG_MAX_BYTES 字节"

# 签名 hook：公钥存在就强制校验 ed25519 detached 签名；没有公钥时靠固定 URL + source policy + sha256。
if [ -e "$WEBCLAW_CATALOG_PUBKEY" ]; then
    trusted_path "$WEBCLAW_CATALOG_PUBKEY"
    fetch "$WEBCLAW_CATALOG_SIG_URL" "$WORK/catalog.sig" || fail "已配置签名公钥，但下载签名失败"
    openssl pkeyutl -verify -pubin -inkey "$WEBCLAW_CATALOG_PUBKEY" -rawin \
        -in "$WORK/catalog.json" -sigfile "$WORK/catalog.sig" >/dev/null 2>&1 \
        || fail "签名校验失败"
    log "签名校验通过"
fi

webclaw_catalog_policies > "$WORK/policies.json" || fail "读取本地 manifest 失败"
webclaw_catalog_validate "$WORK/catalog.json" "$WORK/policies.json" > "$WORK/result.json" 2>/dev/null \
    || fail "不是合法 JSON"

errors="$(jq -r '.errors | length' "$WORK/result.json")"
if [ "$errors" != 0 ]; then
    jq -r '.errors[]' "$WORK/result.json" | sed 's/^/[webclaw-catalog-update]   ✗ /' >&2
    fail "schema/source policy 校验失败（$errors 处）：$(jq -r '.errors[0]' "$WORK/result.json")"
fi
ignored="$(jq -r '.ignored | join(" ")' "$WORK/result.json")"
[ -z "$ignored" ] || log "忽略本地没有 manifest 的 app：$ignored"

# 防回滚：新 catalog 的 generated_at 不能早于当前 cache。
# 防冻结：generated_at 也不能明显超前本机时间——否则一份误发的「未来」catalog 一旦落盘，
# 之后所有正常 catalog 都会被当成回滚拒绝，cache 被长期冻结。
new_gen="$(jq -r '.catalog.generated_at' "$WORK/result.json")"
new_epoch="$(date -d "$new_gen" +%s 2>/dev/null)" || fail "generated_at 无法解析：$new_gen"
[ "$new_epoch" -le $((now + MAX_FUTURE_SKEW_SECS)) ] \
    || fail "generated_at $new_gen 超前本机时间 24 小时以上（拒绝，防止冻结后续更新）"
if [ -f "$WEBCLAW_CATALOG_FILE" ]; then
    old_gen="$(jq -r '.generated_at // empty' "$WEBCLAW_CATALOG_FILE" 2>/dev/null || true)"
    old_epoch="$(date -d "$old_gen" +%s 2>/dev/null || echo 0)"
    [ "$new_epoch" -ge "$old_epoch" ] || fail "generated_at $new_gen 早于当前 cache 的 $old_gen（拒绝回滚）"
fi

jq '.catalog' "$WORK/result.json" > "$WORK/cache.json"
chown root:root "$WORK/cache.json"
chmod 644 "$WORK/cache.json"
tmp="$(mktemp "$WEBCLAW_CATALOG_DIR/.runtime-catalog.XXXXXX")"
cat "$WORK/cache.json" > "$tmp"
chmod 644 "$tmp"
sync -f "$tmp" 2>/dev/null || true
mv -Tf -- "$tmp" "$WEBCLAW_CATALOG_FILE"
write_state ok ""
log "已更新：generated_at=$new_gen，$(jq '.apps | length' "$WEBCLAW_CATALOG_FILE") 个已知 app"
