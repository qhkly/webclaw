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

# token 默认跟 AUTH_PASSWORD 取同一个值，这是整条链路能通的关键。
#
# 请求要连过两道门：外层是 dashboard-server（认 `Bearer $AUTH_PASSWORD`，
# WebSocket 那条认 `?token=$AUTH_PASSWORD`），内层是 studiod 自己的 peer token。
# 而客户端只能带**一个** Authorization 头。两边取同一个值，一把钥匙开两道门；
# 取不同值的话外层先 401，请求根本到不了 studiod。
#
# 真要分开管，就显式设 AI_STUDIO_PEER_TOKEN，同时把它加进 dashboard-server
# 认得的 token 里——否则接不进来。
export AI_STUDIO_PEER_TOKEN="${AI_STUDIO_PEER_TOKEN:-${AUTH_PASSWORD:-changeme}}"

cd "$HOME"
exec /usr/local/bin/webcode-studiod
