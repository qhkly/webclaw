#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-user-node-update —— 让用户 Node 跟随最新 Node.js（后台、非阻塞）。
#  安装位置：/usr/local/bin/webclaw-user-node-update
#  startup.sh 开机后在后台调用一次；也可以手动跑：webclaw-user-node-update --force
#
#  流程（全程持有用户 Node 锁，和 npm -g / nvm 互斥；拿不到锁就跳过本次）：
#    1. 查最新 Node；和 default 一样就只做第 4 步。
#    2. nvm install <最新> --reinstall-packages-from=<旧 default>，把旧 Node 的
#       全局包（Claude/Codex/OpenClaw...）原版本迁到新 Node。
#    3. 校验新 Node 能跑、旧的全局包一个不少，才切 default + 刷新 ~/.nvm/current；
#       校验失败就卸掉新版本，default 保持不动，下次开机再试。
#       清理：只卸载本脚本以前装的、既不是新 default 也不是旧 default 的版本；
#       用户自己 nvm install 的版本一律不碰。
#    4. 升级 WEBCLAW_USER_NODE_AUTO_UPGRADE 列出的包（默认 Claude Code）到 latest。
#
#  环境变量：
#    WEBCLAW_USER_NODE_AUTO_UPDATE=false   关掉开机自动升级（--force 不受影响）
#    WEBCLAW_USER_NODE_UPDATE_INTERVAL=秒  两次检查的最小间隔，默认 86400
#    WEBCLAW_USER_NODE_AUTO_UPGRADE="包 包" 每次跟着升到 latest 的全局包，空串表示不升
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

WEBCLAW_USER_NODE_LIB="${WEBCLAW_USER_NODE_LIB:-/opt/webclaw/user-node-env.sh}"
# shellcheck source=user-node-env.sh
. "$WEBCLAW_USER_NODE_LIB"

log() { echo "[user-node-update] $(date '+%F %T') $*"; }

if [ "$(id -u)" = 0 ]; then
    user_home="$(getent passwd "$WEBCLAW_USER_NODE_USER" | cut -d: -f6)"
    exec runuser -u "$WEBCLAW_USER_NODE_USER" -- env \
        HOME="$user_home" USER="$WEBCLAW_USER_NODE_USER" LOGNAME="$WEBCLAW_USER_NODE_USER" \
        "$0" "$@"
fi

force=0
[ "${1:-}" = "--force" ] && force=1

if [ "$force" = 0 ] && [ "${WEBCLAW_USER_NODE_AUTO_UPDATE:-true}" = "false" ]; then
    log "WEBCLAW_USER_NODE_AUTO_UPDATE=false，跳过"
    exit 0
fi

if ! webclaw_load_user_node; then
    log "用户 nvm 不可用（$WEBCLAW_USER_NVM_DIR），跳过"
    exit 0
fi

if ! webclaw_user_node_lock 0; then
    log "另一个 nvm/npm -g 任务正在进行，本次跳过"
    exit 0
fi

STAMP="$NVM_DIR/.webclaw-last-update"
MANAGED="$NVM_DIR/.webclaw-managed-versions"
INTERVAL="${WEBCLAW_USER_NODE_UPDATE_INTERVAL:-86400}"
if [ "$force" = 0 ] && [ -f "$STAMP" ] \
    && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt "$INTERVAL" ]; then
    log "距上次检查不足 ${INTERVAL}s，跳过"
    exit 0
fi

# 以下调用 nvm 函数，它不兼容 set -eu。
set +o errexit +o nounset +o pipefail

# 全局包名（含 @scope/name），不含 npm/corepack 这些 Node 自带的。
global_pkgs() {
    local root="$NVM_DIR/versions/node/$1/lib/node_modules" d
    [ -d "$root" ] || return 0
    for d in "$root"/* "$root"/@*/*; do
        [ -d "$d" ] || continue
        d="${d#"$root"/}"
        # 顶层的 @scope 目录本身不是包，里面的 @scope/name 由第二个 glob 列出。
        case "$d" in npm|corepack|@*/\*|@*/*/*) continue ;; @*/*) ;; @*) continue ;; esac
        echo "$d"
    done | sort -u
}

old="$(nvm version default)"
# default 别名坏了（指向已删除的版本）时，加载器退回了 nvm use node，从那个版本迁移。
case "$old" in ""|N/A|none|system) old="$(nvm current)" ;; esac
latest="$(nvm version-remote node 2>/dev/null)"
if [ -z "$latest" ] || [ "$latest" = "N/A" ]; then
    log "拿不到最新 Node 版本（网络不通？），下次开机再试"
    exit 0
fi

if [ "$old" = "$latest" ]; then
    log "用户 Node 已是最新：$latest"
else
    log "升级用户 Node：$old → $latest（迁移全局包）"
    # 用户可能早就手动 nvm install 过这个版本（只是没设成 default）：
    # 那它不归本脚本管，迁移失败时不能卸载，以后也不能被清理。
    preinstalled=0
    [ -d "$NVM_DIR/versions/node/$latest" ] && preinstalled=1
    if nvm install "$latest" --reinstall-packages-from="$old"; then
        missing="$(comm -23 <(global_pkgs "$old") <(global_pkgs "$latest"))"
        if ! nvm exec --silent "$latest" node -e 'process.exit(0)' >/dev/null 2>&1; then
            missing="${missing}${missing:+ }<node 无法运行>"
        fi
    else
        missing="<nvm install 失败>"
    fi

    if [ -n "$missing" ]; then
        log "迁移不完整，保持 default=$old。缺失：$(echo "$missing" | xargs)"
        nvm use --silent "$old" >/dev/null 2>&1
        if [ "$preinstalled" = 0 ]; then
            nvm uninstall "$latest" >/dev/null 2>&1
        else
            log "$latest 是升级前就已安装的版本，保留不卸载"
        fi
        exit 1
    fi

    nvm alias default "$latest" >/dev/null
    webclaw_load_user_node
    log "default 已切到 $latest"

    if [ "$preinstalled" = 0 ]; then
        grep -qxF "$latest" "$MANAGED" 2>/dev/null || echo "$latest" >> "$MANAGED"
    fi
    keep=()
    while read -r v; do
        [ -n "$v" ] || continue
        if [ "$v" = "$latest" ] || [ "$v" = "$old" ]; then
            keep+=("$v")
        elif nvm uninstall "$v" >/dev/null 2>&1; then
            log "清理旧版本 $v"
        else
            keep+=("$v")
        fi
    done < "$MANAGED"
    printf '%s\n' "${keep[@]}" > "$MANAGED"
fi

for pkg in ${WEBCLAW_USER_NODE_AUTO_UPGRADE-@anthropic-ai/claude-code}; do
    log "npm install -g ${pkg}@latest"
    npm install -g --no-fund --no-audit "${pkg}@latest" || log "升级 $pkg 失败（忽略）"
done

touch "$STAMP"
log "完成：node $(node -v) @ $(command -v node)"
