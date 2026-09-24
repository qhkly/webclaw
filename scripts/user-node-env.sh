# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────
#  用户 Node（ubuntu 的 nvm）环境加载器 —— 只能被 bash source，不要直接执行。
#  安装位置：/opt/webclaw/user-node-env.sh
#
#  WebClaw 有两套 Node，互不覆盖：
#    系统 Node  /usr/local/bin/node（固定 22.22.1，root 管）
#               → dashboard / clipboard / claudecodeui 等内部常驻服务。
#                 dashboard 是 bytenode 字节码，换一个 Node 小版本都跑不起来。
#    用户 Node  /home/ubuntu/.nvm（nvm default，默认跟随最新 Node）
#               → Claude Code / Codex / Gemini / OpenCode / OpenClaw / dsh 等
#                 AI/开发 CLI，ubuntu 自己 nvm install / npm -g，不需要 root。
#
#  用法：
#    . /opt/webclaw/user-node-env.sh
#    webclaw_load_user_node            # PATH 前插 nvm default 的 bin
#    webclaw_load_user_node --stable   # 长驻进程用：PATH 走 ~/.nvm/current/bin，
#                                      # 后台升级 Node 后派生的 CLI 自动跟上新版本
#  加载失败返回 1，PATH 保持原样（调用方自己决定是报错还是降级）。
# ─────────────────────────────────────────────────────────────────────

WEBCLAW_SYSTEM_NODE="${WEBCLAW_SYSTEM_NODE:-/usr/local/bin/node}"
WEBCLAW_USER_NODE_USER="${WEBCLAW_USER_NODE_USER:-ubuntu}"
WEBCLAW_USER_NVM_DIR="${WEBCLAW_USER_NVM_DIR:-/home/ubuntu/.nvm}"
WEBCLAW_NVM_SEED_DIR="${WEBCLAW_NVM_SEED_DIR:-/opt/nvm-seed}"
# 所有「改动用户 Node 全局状态」的操作（nvm install / npm -g / 后台升级）共用这把锁。
WEBCLAW_USER_NODE_LOCK="${WEBCLAW_USER_NODE_LOCK:-$WEBCLAW_USER_NVM_DIR/.webclaw.lock}"

webclaw_load_user_node() {
    local stable=0 rc=0 restore_opts
    [ "${1:-}" = "--stable" ] && stable=1

    # nvm.sh 不兼容 set -u / set -e / pipefail，调用方（start 脚本）大多开着，临时关掉再还原。
    restore_opts="$(set +o)"
    set +o errexit +o nounset +o pipefail

    # 这几个变量存在时 nvm use 会直接拒绝工作。
    unset npm_config_prefix NPM_CONFIG_PREFIX PREFIX
    export NVM_DIR="$WEBCLAW_USER_NVM_DIR"

    if [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use \
        && { nvm use --silent default >/dev/null 2>&1 || nvm use --silent node >/dev/null 2>&1; } \
        && [ -n "${NVM_BIN:-}" ]; then
        webclaw__user_node_point_current
        if [ "$stable" = 1 ] && [ "$(readlink -f "$NVM_DIR/current/bin" 2>/dev/null)" = "$(readlink -f "$NVM_BIN")" ]; then
            PATH="${PATH//"$NVM_BIN"/"$NVM_DIR/current/bin"}"
            NVM_BIN="$NVM_DIR/current/bin"
            export PATH NVM_BIN
        fi
    else
        rc=1
    fi

    eval "$restore_opts"
    return "$rc"
}

# ~/.nvm/current → 当前 default 版本目录（和 nvm 自带 NVM_SYMLINK_CURRENT 同名同语义）。
# 长驻进程把它放进 PATH 而不是 versions/node/vX/bin：后台升级换了 default、
# 旧版本被清理之后，它派生出来的 claude/codex 仍然找得到。
# 只由加载器/升级器在 default 已确定后刷新；交互 shell 里临时 nvm use 不碰它。
# 用「新建临时链接 + rename」原子替换，并发加载也不会出现半截状态。
webclaw__user_node_point_current() {
    local target tmp
    target="$(dirname "$NVM_BIN")"
    target="${target#"$NVM_DIR"/}"
    [ "$(readlink "$NVM_DIR/current" 2>/dev/null)" = "$target" ] && return 0
    [ -w "$NVM_DIR" ] || return 0
    tmp="$NVM_DIR/.current.$$"
    ln -sfn "$target" "$tmp" 2>/dev/null && mv -Tf "$tmp" "$NVM_DIR/current" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}

# 需要改动用户 Node 全局状态时先拿锁（fd 9）。等待秒数默认 30 分钟。
webclaw_user_node_lock() {
    local wait="${1:-1800}"
    exec 9>>"$WEBCLAW_USER_NODE_LOCK" || return 1
    if [ "$wait" = 0 ]; then
        flock -n 9
    else
        flock -w "$wait" 9
    fi
}

# startup.sh（root）调用：~/.nvm 是持久卷，第一次挂上来是空的，会遮住镜像里的东西。
# 所以镜像把完整的 nvm 放在 /opt/nvm-seed，这里在卷为空时整份拷过去。
#   - 卷里已有 nvm.sh → 当作用户自己的 nvm，原样保留（含用户升级过的 Node/CLI）。
#   - 上次拷到一半容器被杀（留有 .webclaw-seeding）→ 清空重拷。
webclaw_user_node_restore_seed() {
    local dir="$WEBCLAW_USER_NVM_DIR" seed="$WEBCLAW_NVM_SEED_DIR"
    local partial="$dir/.webclaw-seeding"

    if [ ! -s "$seed/nvm.sh" ]; then
        echo "[user-node] 镜像里没有 $seed，跳过 nvm 初始化"
        return 0
    fi

    mkdir -p "$dir"
    if [ -e "$partial" ]; then
        echo "[user-node] 检测到上次未完成的 nvm 初始化，清空 $dir 后重来"
        find "$dir" -mindepth 1 -delete
    elif [ -s "$dir/nvm.sh" ]; then
        chown "$WEBCLAW_USER_NODE_USER:$WEBCLAW_USER_NODE_USER" "$dir"
        return 0
    fi

    echo "[user-node] $dir 为空，从 $seed 初始化用户 nvm..."
    touch "$partial"
    cp -a "$seed/." "$dir/"
    # seed 是 root 所有的只读模板，副本整棵交给用户（-h：符号链接改自身，不跟随）。
    chown -R -h "$WEBCLAW_USER_NODE_USER:$WEBCLAW_USER_NODE_USER" "$dir"
    rm -f "$partial"
    echo "[user-node] nvm 初始化完成"
}
