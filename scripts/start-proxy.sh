#!/usr/bin/env bash
set -euo pipefail

# mihomo（Clash.Meta）无头代理内核。
#
# 为什么不是 v2rayN：v2rayN 是 Avalonia 桌面程序，lite 模式没有 X 根本起不来。
# 它的 TUN 模式底层就是 mihomo/sing-box，所以这里直接把内核裸跑成常驻服务。
# 选 mihomo 而不是 sing-box：mihomo 的 proxy-provider 内置 common/convert，
# 能直接吃 base64 订阅和 vmess:// / vless:// / ss:// / trojan:// 分享链接，
# 不用我们自己写链接解析。
#
# 配置从哪来：~/.webclaw/config.json（dashboard ⚙ 设置页写它）+ 同目录的 nodes.txt。
# 没有 PROXY_* 环境变量入口 —— 改订阅不该需要重建容器。
# 注意本脚本必须能独立读配置：用户在网页里改完，dashboard 只会
# supervisorctl restart proxy，startup.sh 不会重跑。
#
# 两种工作模式（自动探测，见 proxy-common.sh）：
#   tun   —— 需要 /dev/net/tun + CAP_NET_ADMIN，容器内所有进程无感知走代理，
#            连 Node 的 fetch（undici 默认不读 http_proxy）也覆盖得到。
#   local —— 没权限时的降级：只开 mixed-port 7890，靠 http_proxy 环境变量生效。
#
# 端口：external-controller + 网页面板走 10013。10001-10012 已被占用，
# 10013 仍在 dashboard 的 10001-10100 统一代理窗口内，
# 可经 http://<host>:20000/proxy/10013/ui/ 访问。

. /opt/lib/proxy-common.sh

MIHOMO_BIN="${MIHOMO_BIN:-/opt/mihomo/mihomo}"
MIHOMO_UI="${MIHOMO_UI:-/opt/mihomo/ui}"
PROXY_API_PORT="${PROXY_API_PORT:-10013}"
# mihomo 只允许读取 -d 工作目录下的路径，面板装在 /opt/mihomo/ui 属于目录外，
# 不显式放行会直接 fatal: "path is not subpath of home directory or SAFE_PATHS"
export SAFE_PATHS="${SAFE_PATHS:-$MIHOMO_UI}"

log() { echo "[proxy] $*"; }

if [ ! -x "$MIHOMO_BIN" ]; then
    log "找不到 mihomo 内核（$MIHOMO_BIN），代理不启动"
    exit 1
fi

proxy_prepare_dir
NODES_FILE="$PROXY_DIR/nodes.txt"

# 配置只认 config.json，没有环境变量兜底
PROXY_SUB_URL="$(proxy_cfg_get PROXY_SUB_URL)"
PROXY_RULE="$(proxy_cfg_get PROXY_RULE)"
[ -n "$PROXY_RULE" ] || PROXY_RULE=cn
PROXY_SECRET="$(cat "$PROXY_DIR/secret")"

# startup.sh 开机时已经探过并传进来；网页里临时打开代理时没这个变量，自己探一次，
# 顺便把降级模式的环境变量文件和 TUN 模式的 resolv.conf 收拾好。
if [ -z "${PROXY_EFFECTIVE_MODE:-}" ]; then
    PROXY_EFFECTIVE_MODE=$(proxy_detect_mode)
    proxy_write_env_file "$PROXY_EFFECTIVE_MODE"
    proxy_point_resolv_conf "$PROXY_EFFECTIVE_MODE"
    if [ "$PROXY_EFFECTIVE_MODE" = "local" ]; then
        log "提示: 没有 TUN 能力，降级到 http_proxy 模式。"
        log "      已经在跑的服务（code-server / openclaw 等）要重启容器才会全部走代理。"
    fi
fi
log "工作模式: $PROXY_EFFECTIVE_MODE（分流: $PROXY_RULE）"

# ── 订阅来源：URL 和手贴的 nodes.txt 两种都支持，都有就都用 ──────────────
PROVIDER_NAMES=()
{
    echo "proxy-providers:"
    if [ -n "$PROXY_SUB_URL" ]; then
        PROVIDER_NAMES+=("sub")
        cat <<PROVIDER
  sub:
    type: http
    url: "$PROXY_SUB_URL"
    path: ./providers/sub.yaml
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
PROVIDER
    fi
    # 只有注释/空行不算数：空 provider 会让内核起不来
    if [ -s "$NODES_FILE" ] && grep -qvE '^[[:space:]]*(#|$)' "$NODES_FILE"; then
        PROVIDER_NAMES+=("local")
        cat <<PROVIDER
  local:
    type: file
    path: ./nodes.txt
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
PROVIDER
    fi
} > "$PROXY_DIR/.providers.yaml"

if [ ${#PROVIDER_NAMES[@]} -eq 0 ]; then
    log "警告: 既没有 PROXY_SUB_URL 也没有 $NODES_FILE，将没有任何可用节点。"
    log "      填一个订阅链接，或把 vmess:// / vless:// / ss:// 链接一行一条贴进 nodes.txt 后重启本服务。"
    : > "$PROXY_DIR/.providers.yaml"
fi

provider_use_block() {
    local indent="$1"
    if [ ${#PROVIDER_NAMES[@]} -gt 0 ]; then
        echo "${indent}use:"
        for name in "${PROVIDER_NAMES[@]}"; do
            echo "${indent}  - $name"
        done
    fi
}

# ── DNS / TUN ────────────────────────────────────────────────────────────
# fake-ip 只在 tun 模式下用：降级模式里应用直连 198.18.x.x 假地址会全废。
if [ "$PROXY_EFFECTIVE_MODE" = "tun" ]; then
    DNS_MODE_BLOCK="  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '*.docker.internal'
    - localhost
    - host.docker.internal"
    # 监听 127.0.0.1:53 —— Docker 内嵌 DNS 在 127.0.0.11:53，两者不冲突。
    # startup.sh 会把 /etc/resolv.conf 指过来，让域名规则（GEOSITE）真的能命中。
    DNS_LISTEN="127.0.0.1:53"
else
    DNS_MODE_BLOCK="  enhanced-mode: normal"
    DNS_LISTEN="127.0.0.1:1053"
fi

# strict-route 必须关：开了之后从宿主机进来的 20000 连接的回包也会被塞进 tun，
# dashboard / code-server 会直接失联。这是这套方案最容易翻车的一处。
TUN_BLOCK=""
if [ "$PROXY_EFFECTIVE_MODE" = "tun" ]; then
    TUN_BLOCK="tun:
  enable: true
  stack: gvisor
  device: webclaw-tun
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - any:53
"
fi

# ── 分流规则 ─────────────────────────────────────────────────────────────
# 公共前缀：私网 / 容器自身 / host.docker.internal 一律直连，
# 否则 docker.sock、dashboard 回环调用、局域网访问全会被卷进代理。
RULES_COMMON="  - DOMAIN-SUFFIX,docker.internal,DIRECT
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,lan,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - GEOIP,PRIVATE,DIRECT,no-resolve"

if [ "$PROXY_RULE" = "global" ]; then
    RULES_TAIL="  - MATCH,PROXY"
else
    RULES_TAIL="  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY"
fi

# ── 生成 config.yaml（每次启动重写；节点只来自 provider，不手写）─────────
CONFIG="$PROXY_DIR/config.yaml"
{
    echo "# 本文件由 /opt/start-proxy.sh 每次启动自动生成，手工改动会被覆盖。"
    echo "# 要改节点：改 PROXY_SUB_URL 环境变量，或编辑 $NODES_FILE"
    echo "mixed-port: $PROXY_MIXED_PORT"
    echo "allow-lan: false"
    echo "bind-address: 127.0.0.1"
    echo "mode: rule"
    echo "ipv6: false"
    echo "log-level: info"
    echo "external-controller: 127.0.0.1:$PROXY_API_PORT"
    echo "secret: \"$PROXY_SECRET\""
    [ -d "$MIHOMO_UI" ] && echo "external-ui: $MIHOMO_UI"
    # geo 数据首次启动要现下，而这时候代理还没生效 —— 默认源在国内基本拉不动，
    # 拉不到 mihomo 会直接 fatal。所以固定用 jsdelivr 的国内可达镜像。
    echo "geodata-mode: false"
    echo "geo-auto-update: true"
    echo "geo-update-interval: 168"
    echo "geox-url:"
    echo "  geoip: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
    echo "  geosite: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
    echo "  mmdb: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
    echo "profile:"
    echo "  store-selected: true"
    echo "  store-fake-ip: true"
    echo ""
    [ -n "$TUN_BLOCK" ] && printf '%s\n' "$TUN_BLOCK"
    echo "dns:"
    echo "  enable: true"
    echo "  listen: $DNS_LISTEN"
    echo "  ipv6: false"
    printf '%s\n' "$DNS_MODE_BLOCK"
    echo "  nameserver:"
    echo "    - https://223.5.5.5/dns-query"
    echo "    - https://1.1.1.1/dns-query"
    echo ""
    cat "$PROXY_DIR/.providers.yaml"
    echo ""
    echo "proxy-groups:"
    if [ ${#PROVIDER_NAMES[@]} -gt 0 ]; then
        echo "  - name: PROXY"
        echo "    type: select"
        echo "    proxies:"
        echo "      - AUTO"
        echo "      - DIRECT"
        provider_use_block "    "
        echo "  - name: AUTO"
        echo "    type: url-test"
        echo "    url: https://www.gstatic.com/generate_204"
        echo "    interval: 300"
        echo "    tolerance: 50"
        provider_use_block "    "
    else
        # 没有任何节点来源时只放一个空壳分组，内核照常起来（面板可访问），流量全直连
        echo "  - name: PROXY"
        echo "    type: select"
        echo "    proxies:"
        echo "      - DIRECT"
    fi
    echo ""
    echo "rules:"
    printf '%s\n' "$RULES_COMMON"
    printf '%s\n' "$RULES_TAIL"
} > "$CONFIG"

rm -f "$PROXY_DIR/.providers.yaml"

# geoip/geosite 由 mihomo 首次运行时自行下载（走直连），落在 $PROXY_DIR 里持久化
exec "$MIHOMO_BIN" -d "$PROXY_DIR"
