#!/usr/bin/env bash
# 代理（mihomo）的共享逻辑，被 startup.sh 和 start-proxy.sh 同时 source。
#
# 存在的理由：代理有两条进入路径 ——
#   1. 开机：startup.sh 读配置、探测 TUN、注入降级用的环境变量，再拉 supervisord；
#   2. 运行时：用户在 dashboard ⚙ 里打开开关，dashboard 只 supervisorctl start proxy，
#      startup.sh 根本不会重跑。
# 两条路径要得出完全一致的结论，所以判定逻辑只能有一份。

PROXY_DIR="${PROXY_DIR:-/home/ubuntu/.webclaw/proxy}"
PROXY_CONFIG_JSON="${PROXY_CONFIG_JSON:-/home/ubuntu/.webclaw/config.json}"
PROXY_MIXED_PORT="${PROXY_MIXED_PORT:-7890}"
PROXY_ENV_FILE="${PROXY_ENV_FILE:-/etc/profile.d/webclaw-proxy.sh}"
PROXY_NO_PROXY="localhost,127.0.0.1,::1,host.docker.internal,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# 从 ~/.webclaw/config.json 里取一个键。这是代理配置的唯一真相：
# dashboard 的 ⚙ 设置页写它，数据卷持久化，没有对应的环境变量。
proxy_cfg_get() {
    python3 -c "
import json,sys
try:
    print(json.load(open('$PROXY_CONFIG_JSON')).get('$1',''),end='')
except Exception:
    pass
" 2>/dev/null
}

# 配置目录。属主给 ubuntu：dashboard（以 ubuntu 运行）要写 nodes.txt，
# 用户也要能在 code-server 里直接编辑。
proxy_prepare_dir() {
    install -d -o ubuntu -g ubuntu -m 775 "$PROXY_DIR"
    if [ ! -e "$PROXY_DIR/nodes.txt" ]; then
        cat > "$PROXY_DIR/nodes.txt" <<'NODESTXT'
# 一行一条分享链接，支持 vmess:// vless:// ss:// trojan:// hysteria2://
# 也可以整段贴 base64 订阅内容。
# 这个文件也可以在 dashboard 的 ⚙ 设置页里改，改完自动重启代理。
NODESTXT
        chown ubuntu:ubuntu "$PROXY_DIR/nodes.txt"
    fi
    # mihomo 的 external-controller secret。不复用 AUTH_PASSWORD：那个值在
    # 启动器生成的 compose 里是加密的（由 dashboard 解密），拿来当 secret 会对不上。
    # 随机生成一次并持久化，dashboard 读同一个文件来调 API 和拼面板链接。
    if [ ! -s "$PROXY_DIR/secret" ]; then
        (umask 077; openssl rand -hex 16 > "$PROXY_DIR/secret")
        chown ubuntu:ubuntu "$PROXY_DIR/secret"
        chmod 640 "$PROXY_DIR/secret"
    fi
}

# 光有 /dev/net/tun 不够，还得有 CAP_NET_ADMIN 才建得起 tun 设备。
# 直接建一个探针设备再删掉，是最省事也最可靠的判定方式。
proxy_detect_mode() {
    if [ -c /dev/net/tun ] && ip tuntap add mode tun dev webclawprobe0 >/dev/null 2>&1; then
        ip tuntap del mode tun dev webclawprobe0 >/dev/null 2>&1 || true
        echo tun
    else
        echo local
    fi
}

# 降级模式才需要 http_proxy 环境变量；TUN 模式下再设就成了双重代理。
proxy_write_env_file() {
    if [ "$1" = "tun" ]; then
        rm -f "$PROXY_ENV_FILE"
        return 0
    fi
    cat > "$PROXY_ENV_FILE" <<PROXYENV
# 由 webclaw 代理服务自动生成（降级模式）。TUN 模式下这个文件不存在。
export http_proxy="http://127.0.0.1:$PROXY_MIXED_PORT"
export https_proxy="http://127.0.0.1:$PROXY_MIXED_PORT"
export all_proxy="http://127.0.0.1:$PROXY_MIXED_PORT"
export HTTP_PROXY="http://127.0.0.1:$PROXY_MIXED_PORT"
export HTTPS_PROXY="http://127.0.0.1:$PROXY_MIXED_PORT"
export ALL_PROXY="http://127.0.0.1:$PROXY_MIXED_PORT"
export no_proxy="$PROXY_NO_PROXY"
export NO_PROXY="$PROXY_NO_PROXY"
PROXYENV
    chmod 644 "$PROXY_ENV_FILE"
}

# TUN 模式下把 DNS 指向 mihomo（127.0.0.1:53），域名规则（GEOSITE）才命中得了；
# 保留 Docker 内嵌 DNS 127.0.0.11 兜底，代理没起来时也不至于完全断网。
proxy_point_resolv_conf() {
    [ "$1" = "tun" ] || return 0
    [ -w /etc/resolv.conf ] || return 0
    grep -q '^nameserver 127\.0\.0\.1$' /etc/resolv.conf 2>/dev/null && return 0
    {
        echo "nameserver 127.0.0.1"
        cat /etc/resolv.conf 2>/dev/null
    } > /tmp/resolv.conf.webclaw \
        && cat /tmp/resolv.conf.webclaw > /etc/resolv.conf
    rm -f /tmp/resolv.conf.webclaw
}
