#!/bin/bash
#
# runtime catalog 回归测试：构建精简测试镜像（tests/catalog/Dockerfile，使用仓库里真实的
# broker / catalog updater / launcher），容器内起一个本地 HTTPS 服务冒充固定的远程地址，
# 验证 catalog 校验、last-known-good、sha256、broker 高层 API 与 launcher 回归。不需要外网。
#   ./test-runtime-catalog.sh
#   PLATFORM=linux/amd64 ./test-runtime-catalog.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="webclaw-catalog-test:local"
PLATFORM_ARGS=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

# startup 必须持续刷新，而不是只在容器启动时 one-shot。单次 updater 失败由 `|| true`
# 吞掉，循环仍会在下一轮重试；真正联网频率由 updater 的 --if-stale 节流。
# 只检查 catalog 刷新那一段（从它的标题到下一个 "Mode selection" 标题），避免被别处的循环误判。
# 「成功后 --if-stale 节流」的行为本身由容器内测试 [11] 验证。
catalog_block="$(awk '/运行时软件目录（runtime catalog）后台刷新/ {on=1} /Mode selection/ {on=0} on' "$SCRIPT_DIR/scripts/startup.sh")"
static_check() {  # $1=描述 $2=扩展正则
    if ! grep -Eq -- "$2" <<< "$catalog_block"; then
        echo "FAIL: startup.sh 的 catalog 刷新段 $1" >&2
        exit 1
    fi
}
[ -n "$catalog_block" ] || { echo "FAIL: startup.sh 里找不到 catalog 刷新段" >&2; exit 1; }
static_check "不是常驻循环"                          'while[[:space:]]+(:|true)[[:space:]]*;[[:space:]]*do'
static_check "没有用 --if-stale 调用 updater"       'webclaw-catalog-update[[:space:]]+--if-stale'
static_check "单次失败没有 || true（会结束循环）"   'webclaw-catalog-update[[:space:]]+--if-stale[^|]*\|\|[[:space:]]*true'
# 两次检查之间的 sleep 必须在循环体里（开头那个 sleep 20 只是启动延迟，不算）。
if ! awk '/while[[:space:]]+(:|true)/ {on=1; next} on' <<< "$catalog_block" | grep -Eq 'sleep[[:space:]]+[0-9]+'; then
    echo "FAIL: startup.sh 的 catalog 刷新循环体里没有两次检查之间的 sleep" >&2
    exit 1
fi
static_check "没有放到后台（会阻塞 startup）"       '^[[:space:]]*\).*&[[:space:]]*$'
if grep -Eq '(^|[[:space:];])(exit|break)([[:space:];]|$)' <<< "$catalog_block"; then
    echo "FAIL: startup.sh 的 catalog 刷新段里出现 exit/break，循环可能提前结束" >&2
    exit 1
fi
echo "PASS: startup 的 catalog 刷新是非阻塞的常驻循环"

docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -f "$SCRIPT_DIR/tests/catalog/Dockerfile" -t "$IMAGE" "$SCRIPT_DIR"
docker run --rm ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} "$IMAGE" /opt/test/in-container.sh
