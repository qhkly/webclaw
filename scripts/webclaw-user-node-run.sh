#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-user-node-run —— 在 ubuntu 的 nvm default Node 环境里执行命令。
#  安装位置：/usr/local/bin/webclaw-user-node-run
#
#  给「不经过交互 shell、拿不到 nvm」的调用方用：桌面快捷方式、supervisor、
#  software-manager、docker exec 等。
#
#    webclaw-user-node-run claude
#    webclaw-user-node-run npm install -g @anthropic-ai/claude-code@latest
#    webclaw-user-node-run nvm ls
#    webclaw-user-node-run --system-node /usr/local/bin/claude-code-ui --port 10007
#
#  - root 调用会自动降到 ubuntu 执行：root 往 ~/.nvm 里 npm -g 会留下 root 属主文件，
#    之后用户自己就升级不动了。
#  - nvm ... / npm -g ... 会先拿用户 Node 锁，和后台升级、其它安装互斥。
#  - --system-node：命令本身用系统 Node（/usr/local/bin/node）跑，但 PATH 里
#    带着用户 Node，它派生的 claude/codex 能找到。给内部常驻的 Node 服务用
#    （claudecodeui、vibe-kanban），用 ~/.nvm/current 这个稳定路径。
#  - 用户 nvm 不可用时：普通模式报错并 exit 127（绝不落回系统 npm/node）；
#    --system-node 模式警告后继续（服务本身用系统 Node）。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

WEBCLAW_USER_NODE_LIB="${WEBCLAW_USER_NODE_LIB:-/opt/webclaw/user-node-env.sh}"
# shellcheck source=user-node-env.sh
. "$WEBCLAW_USER_NODE_LIB"

log() { echo "[webclaw-user-node-run] $*" >&2; }

if [ "$(id -u)" = 0 ] && [ "${WEBCLAW_USER_NODE_ALLOW_ROOT:-0}" != 1 ]; then
    user_home="$(getent passwd "$WEBCLAW_USER_NODE_USER" | cut -d: -f6)"
    exec runuser -u "$WEBCLAW_USER_NODE_USER" -- env \
        HOME="$user_home" USER="$WEBCLAW_USER_NODE_USER" LOGNAME="$WEBCLAW_USER_NODE_USER" \
        "$0" "$@"
fi

system_node=0
if [ "${1:-}" = "--system-node" ]; then
    system_node=1
    shift
fi

if [ $# -eq 0 ]; then
    echo "用法: webclaw-user-node-run [--system-node] <命令> [参数...]" >&2
    exit 2
fi

if [ "$system_node" = 1 ]; then
    # 内部常驻服务本来就跑在系统 Node 上；用户 Node 缺失只影响它派生的 CLI，服务照常启动。
    webclaw_load_user_node --stable || log "用户 Node（$WEBCLAW_USER_NVM_DIR）不可用，派生进程只能用系统 PATH"
else
    # fail closed：用户 Node 模式绝不落回系统 npm/node，否则 npm -g 会装进 root 管的系统 Node，
    # 或者 claude 等用到系统 PATH 上的旧版本，破坏双 Node 隔离。
    if ! webclaw_load_user_node; then
        log "错误：用户 Node（$WEBCLAW_USER_NVM_DIR）不可用，拒绝执行 $1（不会落回系统 PATH）。"
        log "      容器重启会从 /opt/nvm-seed 恢复；或手动检查 $WEBCLAW_USER_NVM_DIR/nvm.sh。"
        exit 127
    fi
fi

# 改动全局状态的命令串行化。锁 fd 会被 exec 出去的进程继承，进程退出才释放。
needs_lock=0
case "$1" in
    nvm) needs_lock=1 ;;
    npm|pnpm|corepack)
        for arg in "${@:2}"; do
            case "$arg" in -g|--global|--location=global) needs_lock=1 ;; esac
        done
        # npm ls/list -g 只读（software-manager 用它检测安装状态），不拿锁，
        # 免得后台 Node 升级期间检测被卡住。子命令取第一个不以 - 开头的参数。
        if [ "$1" = npm ]; then
            for arg in "${@:2}"; do
                case "$arg" in -*) continue ;; ls|list) needs_lock=0 ;; esac
                break
            done
        fi
        ;;
esac
if [ "$needs_lock" = 1 ] && ! webclaw_user_node_lock "${WEBCLAW_USER_NODE_LOCK_WAIT:-1800}"; then
    log "等待用户 Node 锁超时（另有 nvm/npm -g 在运行）：$WEBCLAW_USER_NODE_LOCK"
    exit 75
fi

if [ "$1" = nvm ]; then
    # nvm 是 shell 函数，不能 exec。
    if ! declare -F nvm >/dev/null; then
        log "nvm 不可用"
        exit 127
    fi
    set +o errexit +o nounset +o pipefail
    shift
    nvm "$@"
    exit $?
fi

if [ "$system_node" = 1 ]; then
    cmd="$(command -v "$1" || true)"
    [ -n "$cmd" ] || { log "找不到命令：$1"; exit 127; }
    script="$(readlink -f "$cmd")"
    shift
    # npm 装出来的 bin 是 `#!/usr/bin/env node` 脚本，会被 PATH 里的用户 Node 截走，
    # 这里显式交给系统 Node。非 Node 脚本（原生二进制等）照常执行。
    if head -n1 "$script" 2>/dev/null | grep -Eq '^#!.*[/ ]node([[:space:]]|$)'; then
        exec "$WEBCLAW_SYSTEM_NODE" "$script" "$@"
    fi
    exec "$script" "$@"
fi

exec "$@"
