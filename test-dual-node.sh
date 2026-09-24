#!/bin/bash
#
# 双 Node 运行时回归测试：构建精简测试镜像（tests/dual-node/Dockerfile，复用仓库里的
# 真实脚本），挂一个全新的空卷到 ~/.nvm 模拟首次启动，然后在容器里跑断言。
# 需要本机 Docker 与外网（下载 Node / nvm / npm 包）。
#   ./test-dual-node.sh                    # 本机架构
#   PLATFORM=linux/amd64 ./test-dual-node.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="webclaw-dual-node-test:local"
VOLUME="webclaw-dual-node-test-nvm-$$"
PLATFORM_ARGS=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

cleanup() { docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -f "$SCRIPT_DIR/tests/dual-node/Dockerfile" -t "$IMAGE" "$SCRIPT_DIR"
docker volume create "$VOLUME" >/dev/null
docker run --rm ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -v "$VOLUME:/home/ubuntu/.nvm" "$IMAGE" /opt/test/in-container.sh
