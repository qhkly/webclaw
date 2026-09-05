#!/usr/bin/env bash
set -euo pipefail

# DeepSeek Harness（@deepseek-ai/dsh）Web UI，安装方式对齐 OpenClaw：
# CLI 全局装进镜像（Dockerfile.base），由 supervisor 常驻拉起。
# 只监听回环地址。dsh 前端写死 <base href="/"> 和根绝对 /api 路径，且上游
# 明确不支持 --host 0.0.0.0，所以 Web UI 只能在容器内访问（桌面图标
# deepseek-harness-browser / noVNC），不能挂在 dashboard 的 /proxy 路径前缀下。
# 端口选 10012：10001-10011 均已被占用；留在统一代理窗口 10001-10100 内，
# 方便日后上游支持子路径部署时直接接 /proxy/10012。

export HOME="${HOME:-/home/ubuntu}"

# 会话/凭证/配置都在 $DSH_HOME（默认 ~/.dsh），落到命名卷里跨容器持久化。
export DSH_HOME="${DSH_HOME:-/home/ubuntu/.dsh}"
mkdir -p "$DSH_HOME"

cd "$HOME"

# --port / --no-open 是 web profile 自己的参数（dsh web --help 可见）。
exec dsh web --port 10012 --no-open
