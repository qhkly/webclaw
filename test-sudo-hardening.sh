#!/bin/bash
#
# sudo 最小权限回归测试：构建精简测试镜像（tests/sudo/Dockerfile，使用仓库里真实的
# sudoers / webclaw-app-admin / 审计脚本），在容器里验证 ubuntu 能做什么、不能做什么。
# 需要本机 Docker 与外网（[8] apt、[9] scripts-updater 会真实下载）。
#   ./test-sudo-hardening.sh
#   PLATFORM=linux/amd64 ./test-sudo-hardening.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="webclaw-sudo-test:local"
PLATFORM_ARGS=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -f "$SCRIPT_DIR/tests/sudo/Dockerfile" -t "$IMAGE" "$SCRIPT_DIR"
docker run --rm ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} "$IMAGE" /opt/test/in-container.sh
