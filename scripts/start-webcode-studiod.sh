#!/usr/bin/env bash
set -euo pipefail

# AI Studio 无头节点。让桌面端的 WebCode AI Studio 把这个容器当成一台远程 Studio
# 接进去：容器里的工程和会话出现在你本机的侧边栏，CLI 进程跑在容器里。

export HOME="${HOME:-/home/ubuntu}"

# 数据目录放进 .webclaw 下，跟着卷一起持久化。不能用默认位置：
# 默认走 dirs::data_dir()，容器重建就全丢了，instance_id 一变，桌面端那边
# 会把它当成一台**新的**远程主机，旧卡片留在那儿再也连不上。
export AI_STUDIO_DATA_DIR="${AI_STUDIO_DATA_DIR:-/home/ubuntu/.webclaw/ai-studio}"
mkdir -p "$AI_STUDIO_DATA_DIR"

# 监听 10010。选这个端口不是随意的：dashboard-server 的统一代理只转发
# 10001-10100，落在窗口外就完全够不着（见 PROXY_ARCHITECTURE.md）。
# 对外只暴露 20000 一个口，这个端口不要在 compose 里 publish。
export AI_STUDIO_DEV_PORT="${AI_STUDIO_DEV_PORT:-10010}"

# 联邦接入。无头下界面上那个勾点不到，只能靠环境变量打开。
export AI_STUDIO_PEER_ENABLED="${AI_STUDIO_PEER_ENABLED:-1}"
export AI_STUDIO_PEER_SCOPE="${AI_STUDIO_PEER_SCOPE:-lan}"

# peer token 必须是 dashboard-server 也认得的那几个值之一，这是整条链路能通的关键。
#
# 请求要连过两道门：外层是 dashboard-server（认 `Bearer $AUTH_PASSWORD` 或
# `Bearer $OPENCLAW_GATEWAY_TOKEN`，也认同名的 `?token=`），内层是 studiod 自己的
# peer token。而客户端只能带**一个** Authorization 头，两边必须是同一个值，
# 一把钥匙开两道门；取别的值外层先 401，请求根本到不了 studiod。
#
# launcher 建的容器一律显式下发 AI_STUDIO_PEER_TOKEN=$OPENCLAW_GATEWAY_TOKEN，
# 走的就是这条。下面的 fallback 只对手工 docker run 有意义，而且注意：
# AUTH_PASSWORD 在 launcher 生成的 compose 里是 `ENC:[...]` 密文（dashboard-server
# 自己会解密，studiod 不会），所以那种场合别指望这个 fallback。
export AI_STUDIO_PEER_TOKEN="${AI_STUDIO_PEER_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-${AUTH_PASSWORD:-changeme}}}"

# 文件读写 / Git 这两项能力，ai-studio 上游刻意**不给**环境变量入口
# （见 core/src/commands/peer_commands.rs 里 apply_server_env_overrides 的注释）：
# 理由是「让对面读写这台机器上的文件」值得每次在界面上点头确认一次。
#
# 但那个前提在容器里不成立——无头节点根本没有界面可点，于是这两项永远开不了，
# 桌面端那边「新建工程」「拖文件进对话」一律灰着，报「对方没有开启这项能力」。
# 而且看风险：上面已经默认 AI_STUDIO_PEER_ENABLED=1，peer token 就是网关 token，
# 能过这道门的人本来就能用 create-session 在这台机器上跑任意命令。在此之上再给
# 文件读写，边际风险约等于零，挡住它只是让功能不可用而已。
#
# 所以这里播一份默认配置——这是**容器场景下的一次刻意例外**，不是推翻上游判断。
# 只在文件不存在时写：那里面会存明文 peer token，已有的配置一个字都不能碰。
PEERS_JSON="$AI_STUDIO_DATA_DIR/peers.json"
if [ ! -e "$PEERS_JSON" ]; then
  bool() { case "${1:-}" in 0|false|no) echo false;; *) echo true;; esac; }
  # 先写临时文件设好权限再 rename，和 ai-studio 自己的 save_store() 一致：
  # 直接写目标路径会出现一个短暂的 0644 窗口。
  umask 077
  cat > "$PEERS_JSON.tmp" <<JSON
{
  "peers": [],
  "server": {
    "enabled": true,
    "accessMode": "lan-only",
    "allowFiles": $(bool "${AI_STUDIO_PEER_ALLOW_FILES:-1}"),
    "allowGit": $(bool "${AI_STUDIO_PEER_ALLOW_GIT:-1}")
  }
}
JSON
  chmod 600 "$PEERS_JSON.tmp"
  mv "$PEERS_JSON.tmp" "$PEERS_JSON"
  # enabled/accessMode 写不写都一样——真正生效的是上面那两个环境变量覆盖。
  # 写进去只是让这个文件自己说得清自己是什么状态。
fi

cd "$HOME"
exec /usr/local/bin/webcode-studiod
