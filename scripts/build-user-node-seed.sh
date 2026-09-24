#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  镜像构建期专用：以 root 身份把用户 Node（nvm + 最新 Node + AI CLI）装进
#  /opt/nvm-seed。seed 是只读模板：root:root、group/other 不可写，ubuntu 改不了；
#  运行时 startup.sh 在 ~/.nvm 卷为空时拷过去，再把副本整棵改成 ubuntu:ubuntu。
#
#    build-user-node-seed.sh init                 装 nvm + 最新 Node，设为 default
#    build-user-node-seed.sh install <包...>       往 seed 的 default Node 里 npm -g
#
#  注意 seed 放在 /opt/nvm-seed 而不是 ~/.nvm：nvm 的全局 bin 是相对符号链接，
#  npm prefix 由 node 可执行文件位置推出，整棵树拷到 ~/.nvm 后照常工作。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

export NVM_DIR="${NVM_DIR:-/opt/nvm-seed}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"

export npm_config_fetch_retries=5
export npm_config_fetch_retry_mintimeout=20000
export npm_config_fetch_retry_maxtimeout=120000
export npm_config_fetch_timeout=300000
export npm_config_fund=false
export npm_config_audit=false
export npm_config_update_notifier=false

umask 022
if [ "$(id -u)" != 0 ]; then
    echo "build-user-node-seed.sh 必须以 root 运行（seed 要 root 所有）" >&2
    exit 1
fi

load_nvm() {
    set +o errexit +o nounset +o pipefail
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent default >/dev/null
    local rc=$?
    set -o errexit -o nounset -o pipefail
    return "$rc"
}

cleanup_caches() {
    rm -rf "$NVM_DIR/.cache" "$HOME/.npm/_cacache" "$HOME/.npm/_logs" "$HOME/.npm/_npx"
}

# npm 生命周期脚本可能以别的 uid 落文件；只修不合规的条目（不对整棵树 chown，
# 否则 overlayfs 会把下层所有文件复制一份，镜像体积翻倍）。
lock_seed() {
    find "$NVM_DIR" ! -user 0 -exec chown -h root:root {} +
    find "$NVM_DIR" ! -type l -perm /022 -exec chmod go-w {} +
}

case "${1:-}" in
    init)
        mkdir -p "$NVM_DIR"
        # Dockerfile.base 里的 ARG NODE_VERSION（系统 Node 版本）会漏进 RUN 环境，
        # nvm 的 install.sh 看到它就会去装那个版本，这里必须清掉。
        unset NODE_VERSION
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
            "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
            | PROFILE=/dev/null bash
        set +o errexit +o nounset +o pipefail
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh" --no-use
        for i in 1 2 3 4 5; do
            nvm install node && break
            echo "[seed] nvm install node 失败，重试 $i/5" >&2
            sleep 10
        done
        latest="$(nvm version node)"
        set -o errexit -o nounset -o pipefail
        [ "$latest" != "N/A" ]
        # default 指向具体版本而不是 node 别名：否则后台升级装好新 Node 的那一刻
        # default 就漂过去了，全局包还没迁完。
        nvm alias default "$latest"
        ln -sfn "versions/node/$latest" "$NVM_DIR/current"
        echo "$latest" > "$NVM_DIR/.webclaw-managed-versions"
        cleanup_caches
        lock_seed
        ;;
    install)
        shift
        load_nvm
        npm install -g "$@"
        cleanup_caches
        lock_seed
        ;;
    *)
        echo "用法: $0 init | install <包...>" >&2
        exit 2
        ;;
esac
