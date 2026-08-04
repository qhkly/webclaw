#!/usr/bin/env bash
set -euo pipefail

# add-server.sh —— 把一台远程服务器接入运维基地
#
# 用法:  add-server <名字> <IP或域名> [用户] [端口]
# 例子:  add-server prod-web 203.0.113.10 root
#
# 做五件事:
#   1. 往 ~/.ssh/config 追加 Host 块(含 ControlMaster 连接复用)
#   2. ssh-copy-id 装公钥(唯一一次输密码,之后再也不用)
#   3. 建 ~/servers/<名字> 并 git init(让 AI Studio 的扫描认出它)
#   4. 生成 mount.sh / CLAUDE.md / .claude/settings.json
#   5. 挂载一次验证连通

NAME="${1:-}"
HOST_ADDR="${2:-}"
SSH_USER="${3:-root}"
SSH_PORT="${4:-22}"

if [ -z "${NAME}" ] || [ -z "${HOST_ADDR}" ]; then
    echo "用法: add-server <名字> <IP或域名> [用户] [端口]" >&2
    echo "例子: add-server prod-web 203.0.113.10 root" >&2
    exit 1
fi

# 名字会被拼进文件路径和 ssh 别名,限制成安全字符
if ! printf '%s' "${NAME}" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
    echo "错误: 名字只能用字母、数字、点、下划线、连字符,且以字母或数字开头" >&2
    exit 1
fi

SERVERS_DIR="$HOME/servers"
DIR="${SERVERS_DIR}/${NAME}"
MNT="/mnt/${NAME}"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
KEY="$SSH_DIR/id_ed25519"

echo "==> [1/5] 配置 ssh"

mkdir -p "$SSH_DIR" "$SSH_DIR/cm"
chmod 700 "$SSH_DIR" "$SSH_DIR/cm"

# 没有密钥就生成一把
if [ ! -f "$KEY" ]; then
    echo "    生成 SSH 密钥 $KEY"
    ssh-keygen -t ed25519 -N "" -C "webclaw-ops" -f "$KEY"
fi

touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

if grep -qE "^[[:space:]]*Host[[:space:]]+${NAME}[[:space:]]*$" "$SSH_CONFIG"; then
    echo "    ~/.ssh/config 里已有 Host ${NAME},跳过"
else
    # ControlPath 必须用 %C(哈希)。socket 路径有长度上限,用 %r@%h:%p 遇到长主机名
    # 会溢出,而且不报错,悄悄退回每次重连——连接复用就白配了。
    cat >> "$SSH_CONFIG" <<EOF

Host ${NAME}
    HostName ${HOST_ADDR}
    Port ${SSH_PORT}
    User ${SSH_USER}
    IdentityFile $KEY
    IdentitiesOnly yes
    ControlMaster auto
    ControlPath $SSH_DIR/cm/%C
    ControlPersist 10m
    ServerAliveInterval 15
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new
EOF
    echo "    已写入 Host ${NAME}"
fi

echo "==> [2/5] 安装公钥(这是唯一一次需要输密码)"

if ssh -o BatchMode=yes -o ConnectTimeout=10 "${NAME}" true 2>/dev/null; then
    echo "    已经免密,跳过"
else
    ssh-copy-id -i "$KEY.pub" "${NAME}"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${NAME}" true; then
        echo "错误: 公钥装上了但免密登录仍然失败" >&2
        exit 1
    fi
    echo "    免密登录已生效"
fi

echo "==> [3/5] 建工作目录 $DIR"

mkdir -p "$DIR/.claude"
if [ ! -d "$DIR/.git" ]; then
    git -C "$DIR" init -q
    # git init 只是为了让 AI Studio 的目录扫描认出它(扫一层,含 .git 即一个工程)
fi

echo "==> [4/5] 生成 mount.sh / CLAUDE.md / settings.json"

# ── mount.sh:幂等,已挂载则秒退 ──────────────────────────────────────
cat > "$DIR/mount.sh" <<EOF
#!/usr/bin/env bash
# 挂载 ${NAME} 的根目录到 ${MNT}。已挂载则立刻退出,可以反复跑。
set -euo pipefail

mountpoint -q "${MNT}" && exit 0
mkdir -p "${MNT}"

# reconnect 最重要:网络抖动后自动重连。没有它,挂载会变成"僵尸",
# 任何碰到它的进程会卡死且杀不掉——而运维时你改的就是网络和防火墙。
# cache/kernel_cache 缓存文件属性,大幅减少网络往返。
sshfs "${NAME}:/" "${MNT}" \\
    -o reconnect \\
    -o ServerAliveInterval=15,ServerAliveCountMax=3 \\
    -o ConnectTimeout=10 \\
    -o cache=yes,cache_timeout=60,kernel_cache \\
    -o follow_symlinks

echo "已挂载 ${NAME}:/ -> ${MNT}"
EOF
chmod +x "$DIR/mount.sh"

# ── 探测系统信息,填进 CLAUDE.md ─────────────────────────────────────
OS_INFO="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${NAME}" \
    'grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d \"' 2>/dev/null || true)"
[ -z "${OS_INFO}" ] && OS_INFO="(未探测到)"

# 注意:下面 heredoc 里的 $(date +%F) 要转义,否则会在生成时就被执行
cat > "$DIR/CLAUDE.md" <<EOF
# ${NAME} (${HOST_ADDR})

这是一台**远程 Linux 服务器**的运维工作目录。你现在不在那台服务器上。

## 第一步

开始任何工作前先跑一次(已挂载会立刻退出):

    ~/servers/${NAME}/mount.sh

## 两条通道

**改文件 → 用挂载路径,当本地文件改**

服务器上的路径前面加 \`${MNT}\` 就是这里的路径:

    /etc/nginx/nginx.conf  →  ${MNT}/etc/nginx/nginx.conf

直接用 Read / Edit 工具操作这些路径,改动立刻生效在服务器上。

**跑命令 → 用 ssh**

    ssh ${NAME} 'apt install -y nginx'
    ssh ${NAME} 'systemctl reload nginx'

## 三条规则

1. **不要在挂载目录里搜索。** \`grep -r\` / \`find\` / glob 在挂载上是几千次
   网络往返,会非常慢。要搜索请用:

       ssh ${NAME} 'grep -r xxx /etc'

   在服务器本地搜完再把结果传回来,快几百倍。
   挂载路径只用来**读或改已经知道路径的单个文件**。

2. **不加 \`ssh ${NAME}\` 前缀的命令跑在运维基地上,不是服务器上。**
   直接跑 \`apt install\` / \`systemctl\` 你操作的是错的机器。

3. **改配置前先备份,改完必须验证:**

       ssh ${NAME} 'cp /etc/nginx/nginx.conf{,.bak-\$(date +%F)}'
       ssh ${NAME} 'nginx -t && systemctl reload nginx'

## 挂载卡住了怎么办

    fusermount -u ${MNT} && ~/servers/${NAME}/mount.sh

## 这台机器

- 地址: ${HOST_ADDR}:${SSH_PORT} (${SSH_USER})
- OS: ${OS_INFO}
- 跑着: <填:nginx / postgres / docker ...>
- 注意: <填:只有你知道的坑,比如「8080 端口被 X 占着不要动」>

最后两行随手补,那是模型永远猜不到、而且会越积越有用的东西。
EOF

# ── 权限规则 ────────────────────────────────────────────────────────
# 铁律:allow 里只放明确的只读命令。绝不要放 Bash(*) 或 Bash(ssh ${NAME} *)
# 这种通配——放了的话所有保护一次性归零。
cat > "$DIR/.claude/settings.json" <<EOF
{
  "permissions": {
    "allow": [
      "Bash(~/servers/${NAME}/mount.sh)",
      "Bash(ssh ${NAME} cat *)",
      "Bash(ssh ${NAME} grep *)",
      "Bash(ssh ${NAME} ls *)",
      "Bash(ssh ${NAME} systemctl status *)",
      "Bash(ssh ${NAME} journalctl *)",
      "Bash(ssh ${NAME} docker ps*)",
      "Bash(ssh ${NAME} docker logs *)"
    ],
    "deny": [
      "Bash(rm -rf /mnt/*)",
      "Bash(rm -r /mnt/*)",
      "Bash(mv /mnt/*)",
      "Bash(chmod -R *)",
      "Bash(chown -R *)",
      "Bash(mkfs*)",
      "Bash(dd *)",
      "Bash(ssh ${NAME} rm -rf *)",
      "Bash(ssh ${NAME} mkfs*)",
      "Bash(ssh ${NAME} dd *)"
    ]
  }
}
EOF

git -C "$DIR" add -A >/dev/null 2>&1 || true
git -C "$DIR" commit -q -m "接入服务器 ${NAME} (${HOST_ADDR})" >/dev/null 2>&1 || true

echo "==> [5/5] 挂载"

"$DIR/mount.sh"

if [ ! -e "${MNT}/etc" ]; then
    echo "警告: 挂载完成但读不到 ${MNT}/etc,请手工检查" >&2
fi

cat <<EOF

完成。${NAME} 已接入。

  工作目录:  $DIR
  挂载点:    ${MNT}   (服务器路径前面加 ${MNT} 就是这里的路径)
  跑命令:    ssh ${NAME} '<命令>'

还差一步:在 AI Studio 的设置里把 ${SERVERS_DIR} 加成扫描目录,
${NAME} 就会出现在工程列表里。新建会话时记得关掉 worktree 开关。
EOF
