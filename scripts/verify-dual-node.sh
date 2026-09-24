#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-verify-dual-node —— 在容器里验证双 Node 运行时。
#    docker exec webclaw webclaw-verify-dual-node          （root 或 ubuntu 均可）
#
#  验证：
#    1. 系统 Node 仍是固定版本（/usr/local/bin/node，root 属主）
#    2. ubuntu 交互 shell 的 node 来自 nvm default
#    3. dashboard 固定跑在系统 Node 上，PATH 里有用户 Node 也截不走
#    4. AI CLI 装在 nvm 全局目录下
#    5. webcode-studiod（及 openclaw/dsh）的启动环境能找到用户 Node 和 CLI
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail

EXPECTED_SYSTEM_NODE="${EXPECTED_SYSTEM_NODE:-v22.22.1}"
SYSTEM_NODE=/usr/local/bin/node
USER_NAME=ubuntu
USER_HOME=/home/ubuntu
NVM_VERSIONS="$USER_HOME/.nvm/versions/node/"
CLIS="${VERIFY_CLIS:-claude codex gemini opencode oh-my-opencode vercel wrangler openclaw dsh}"

pass=0 fail=0
ok()   { echo "  ✓ $*"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $*"; fail=$((fail + 1)); }
note() { echo "  · $*"; }

as_user() {
    if [ "$(id -un)" = "$USER_NAME" ]; then
        env HOME="$USER_HOME" "$@"
    else
        runuser -u "$USER_NAME" -- env HOME="$USER_HOME" "$@"
    fi
}

pid_env() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p"; }

echo "[1] 系统 Node"
sys_ver="$("$SYSTEM_NODE" -v 2>/dev/null)"
[ "$sys_ver" = "$EXPECTED_SYSTEM_NODE" ] && ok "$SYSTEM_NODE = $sys_ver" \
    || bad "$SYSTEM_NODE = ${sys_ver:-<无>}，期望 $EXPECTED_SYSTEM_NODE"
# 官方 tarball 解出来属主是 uid 1001，不一定是 root；真正要保证的是 ubuntu 改不动它。
if as_user test -w "$(readlink -f "$SYSTEM_NODE")" || as_user test -w /usr/local/lib/node_modules; then
    bad "ubuntu 能写系统 Node（/usr/local）"
else
    ok "ubuntu 无法改动系统 Node（/usr/local/bin/node、/usr/local/lib/node_modules）"
fi
[ -d /usr/local/lib/node_modules/webclaw-dashboard-server ] && ok "dashboard 装在系统 Node 全局目录" \
    || bad "/usr/local/lib/node_modules/webclaw-dashboard-server 不存在"

echo "[2] ubuntu 交互 shell 的 node"
user_node="$(as_user bash -ic 'command -v node' 2>/dev/null | tail -n1)"
user_ver="$(as_user bash -ic 'node -v' 2>/dev/null | tail -n1)"
default_ver="$(as_user webclaw-user-node-run nvm version default 2>/dev/null | tail -n1)"
case "$user_node" in
    "$NVM_VERSIONS"*) ok "node → $user_node ($user_ver)" ;;
    *) bad "交互 shell 的 node 不在 nvm 下：${user_node:-<无>}" ;;
esac
[ -n "$default_ver" ] && [ "$user_ver" = "$default_ver" ] && ok "与 nvm default 一致（$default_ver）" \
    || bad "交互 shell node=$user_ver，nvm default=$default_ver"
[ "$("$SYSTEM_NODE" -v)" = "$EXPECTED_SYSTEM_NODE" ] && ok "系统 Node 验证入口：$SYSTEM_NODE -v = $EXPECTED_SYSTEM_NODE"

echo "[3] dashboard 不受用户 Node 影响"
dash_pid="$(pgrep -f 'webclaw-dashboard-server|dashboard-server-override|dashboard-override/dashboard-server' | head -n1)"
if [ -n "$dash_pid" ]; then
    dash_exe="$(readlink -f "/proc/$dash_pid/exe")"
    [ "$dash_exe" = "$(readlink -f "$SYSTEM_NODE")" ] && ok "运行中的 dashboard(pid $dash_pid) 解释器 = $dash_exe" \
        || bad "运行中的 dashboard 解释器 = $dash_exe"
    case "$(pid_env "$dash_pid" PATH)" in
        *"/.nvm/"*) bad "dashboard 的 PATH 含 nvm" ;;
        *) ok "dashboard 的 PATH 不含 nvm" ;;
    esac
else
    note "dashboard 没在运行，跳过进程检查"
fi
# 模拟最坏情况：调用方 PATH 里塞满用户 Node（和一个假 node），start-dashboard.sh 仍要用系统 Node。
probe="$(mktemp -d)"
printf '#!/bin/sh\necho FAKE-NODE\n' > "$probe/node"
printf 'console.log("DASHBOARD-NODE " + process.version + " " + process.execPath)\n' > "$probe/dashboard-server.js"
chmod -R a+rX "$probe"
chmod +x "$probe/node"
user_bin="$(as_user bash -ic 'echo $NVM_BIN' 2>/dev/null | tail -n1)"
out="$(as_user env PATH="$probe:$user_bin:$PATH" DASHBOARD_OVERRIDE_DIR="$probe" /opt/start-dashboard.sh 2>&1 | grep DASHBOARD-NODE)"
case "$out" in
    "DASHBOARD-NODE $EXPECTED_SYSTEM_NODE "*) ok "PATH 被用户 Node 抢占时 start-dashboard.sh 仍用 $EXPECTED_SYSTEM_NODE" ;;
    *) bad "start-dashboard.sh 用错了 Node：${out:-<无输出>}" ;;
esac
rm -rf "$probe"

echo "[4] AI CLI 装在 nvm 下"
for cli in $CLIS; do
    path="$(as_user webclaw-user-node-run bash -c "readlink -f \"\$(command -v $cli)\"" 2>/dev/null)"
    case "$path" in
        "$NVM_VERSIONS"*) ok "$cli → $path" ;;
        "") bad "$cli 找不到" ;;
        *) bad "$cli 不在 nvm 下：$path" ;;
    esac
done
for cli in $CLIS; do
    [ -e "/usr/local/bin/$cli" ] && note "注意：/usr/local/bin/$cli 仍存在（系统 Node 下的旧安装，交互 shell 会被 nvm 覆盖）"
done

echo "[5] webcode-studiod / 长驻服务拿到用户 Node"
env_path="$(as_user bash -c '. /opt/webclaw/user-node-env.sh; webclaw_load_user_node --stable || exit 1; echo "$PATH"; command -v node; command -v claude')"
case "$env_path" in
    *"/.nvm/current/bin"*) ok "加载器（--stable）PATH 含 ~/.nvm/current/bin" ;;
    *) bad "加载器 PATH 不含 ~/.nvm/current/bin：$(echo "$env_path" | head -n1)" ;;
esac
[ "$(echo "$env_path" | sed -n 3p)" = "$USER_HOME/.nvm/current/bin/claude" ] && ok "加载器里 claude → ~/.nvm/current/bin/claude" \
    || bad "加载器里找不到 claude：$(echo "$env_path" | sed -n 3p)"
[ "$(readlink -f "$USER_HOME/.nvm/current")" = "$(readlink -f "$USER_HOME/.nvm/versions/node/$default_ver")" ] \
    && ok "~/.nvm/current → $default_ver" || bad "~/.nvm/current 没指向 default（$default_ver）"
for spec in 'webcode-studiod:^/usr/local/bin/webcode-studiod' 'openclaw:openclaw-gateway|openclaw gateway run' 'dsh:dsh web'; do
    prog="${spec%%:*}"
    pid="$(pgrep -f "${spec#*:}" | grep -vx "$$" | head -n1)"
    if [ -z "$pid" ]; then
        note "$prog 没在运行，跳过进程检查"
        continue
    fi
    p="$(pid_env "$pid" PATH)"
    case "$p" in
        *"/.nvm/current/bin"*) ok "$prog(pid $pid) PATH 含 ~/.nvm/current/bin" ;;
        *) bad "$prog(pid $pid) PATH 不含用户 Node：$p" ;;
    esac
done

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
