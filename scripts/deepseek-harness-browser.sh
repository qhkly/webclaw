#!/usr/bin/env bash
# DeepSeek Harness 浏览器启动脚本（无菜单栏模式，对齐 openclaw-browser）
set -euo pipefail

# dsh web 只监听 127.0.0.1:10012，且每次启动生成一次性 launch token
# （GET /?token=... 换 30 天 Cookie）。token URL 打在 dsh 自己的标准输出里，
# 由 supervisor 落在 /tmp/deepseek_harness_stdout.log，这里取最近一条。
# 注意：dsh 前端写死了 <base href="/"> 和根绝对 /api 路径，套在
# dashboard 的 /proxy/10012/ 路径前缀下会挂，只能在容器内以回环源访问
# （桌面图标 / noVNC 里操作，上游也不支持 --host 0.0.0.0）。
URL="http://127.0.0.1:10012"
TOKEN_URL="$(sed -n 's|^dsh web: \(http://127\.0\.0\.1:10012/?token=[^ ]*\)$|\1|p' \
    /tmp/deepseek_harness_stdout.log 2>/dev/null | tail -n 1 || true)"
[ -n "$TOKEN_URL" ] && URL="$TOKEN_URL"

# 检测可用浏览器（x86 用 google-chrome，arm 用 chromium）
BROWSER=""
if command -v google-chrome >/dev/null 2>&1; then
    BROWSER="google-chrome"
elif command -v chromium >/dev/null 2>&1; then
    BROWSER="chromium"
else
    echo "Error: No browser found (google-chrome or chromium required)" >&2
    exit 1
fi

# 使用 --app 模式打开，隐藏菜单栏和地址栏，并最大化窗口
exec "$BROWSER" --app="$URL" --start-maximized "$@"
