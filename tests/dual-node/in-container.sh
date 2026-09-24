#!/usr/bin/env bash
# 在测试容器里以 root 运行（~/.nvm 是一个全新的空命名卷，模拟首次启动）。
set -uo pipefail

pass=0 fail=0
ok()  { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
as_ubuntu() { runuser -u ubuntu -- env HOME=/home/ubuntu "$@"; }

NVM=/home/ubuntu/.nvm
. /opt/webclaw/user-node-env.sh

echo "[a] 空卷首启：从 seed 恢复"
check "卷一开始是空的" test -z "$(ls -A "$NVM")"
webclaw_user_node_restore_seed
check "nvm.sh 已就位" test -s "$NVM/nvm.sh"
check "~/.nvm 属主 ubuntu" test "$(stat -c %U "$NVM")" = ubuntu
check "版本目录属主 ubuntu" test "$(stat -c %U "$NVM/versions/node")" = ubuntu
check "未留下 .webclaw-seeding" test ! -e "$NVM/.webclaw-seeding"
check "副本整棵归 ubuntu（没有残留 root 文件）" test -z "$(find "$NVM" ! -user ubuntu -print -quit)"
check "seed 本身 root 所有" test -z "$(find /opt/nvm-seed ! -user root -print -quit)"
check "seed 无 group/other 可写" test -z "$(find /opt/nvm-seed ! -type l -perm /022 -print -quit)"
check "ubuntu 不能改 seed" bash -c "! runuser -u ubuntu -- touch /opt/nvm-seed/x 2>/dev/null && ! runuser -u ubuntu -- touch /opt/nvm-seed/nvm.sh 2>/dev/null"
check "ubuntu 能写自己的 ~/.nvm" runuser -u ubuntu -- touch "$NVM/nvm.sh"

echo "[b] 幂等 / 中断恢复"
touch "$NVM/user-marker"
out="$(webclaw_user_node_restore_seed)"
check "已有 nvm 时不重拷" test -z "$out" -a -e "$NVM/user-marker"
touch "$NVM/.webclaw-seeding"
webclaw_user_node_restore_seed >/dev/null
check "中断后清空重拷" test ! -e "$NVM/user-marker" -a -s "$NVM/nvm.sh" -a ! -e "$NVM/.webclaw-seeding"

echo "[c] 执行器"
check "root 调用降权到 ubuntu" test "$(webclaw-user-node-run id -un)" = ubuntu
check "执行器里 node 来自 nvm" bash -c "webclaw-user-node-run bash -c 'command -v node' | grep -q '^$NVM/versions/node/'"
check "--system-node 用系统 Node 跑 node 脚本" \
    test "$(printf '#!/usr/bin/env node\nconsole.log(process.version)\n' > /tmp/p.js; chmod 755 /tmp/p.js; webclaw-user-node-run --system-node /tmp/p.js)" = v22.22.1
check "--system-node 下 PATH 仍带用户 Node" \
    bash -c "webclaw-user-node-run --system-node bash -c 'command -v claude' | grep -q '^$NVM/current/bin/claude$'"

echo "[d] webcode-studiod 启动环境"
out="$(as_ubuntu /opt/start-webcode-studiod.sh 2>&1)"
echo "$out" | sed 's/^/    /'
check "studiod PATH 含 ~/.nvm/current/bin" grep -q "STUDIOD-PATH=$NVM/current/bin:" <<<"$out"
check "studiod 找得到 claude" grep -q "STUDIOD-CLAUDE=$NVM/current/bin/claude" <<<"$out"

echo "[e] 容器内验证脚本"
VERIFY_CLIS=claude webclaw-verify-dual-node && ok "webclaw-verify-dual-node 通过" || bad "webclaw-verify-dual-node 失败"

echo "[f] 锁"
as_ubuntu flock "$NVM/.webclaw.lock" sleep 60 &
holder=$!
sleep 1
out="$(webclaw-user-node-update --force 2>&1)"
check "有人持锁时后台升级直接跳过" grep -q "本次跳过" <<<"$out"
WEBCLAW_USER_NODE_LOCK_WAIT=2 webclaw-user-node-run npm install -g left-pad >/dev/null 2>&1
check "npm -g 等锁超时返回 75" test $? = 75
start=$(date +%s)
WEBCLAW_USER_NODE_LOCK_WAIT=5 webclaw-user-node-run npm ls -g --depth=0 >/dev/null 2>&1; rc=$?
check "持锁时 npm ls -g 仍立即执行（只读不拿锁）" test "$rc" = 0 -a $(( $(date +%s) - start )) -lt 5
WEBCLAW_USER_NODE_LOCK_WAIT=5 webclaw-user-node-run npm list -g @anthropic-ai/claude-code >/dev/null 2>&1
check "持锁时 npm list -g <pkg> 也不等锁" test $? = 0
WEBCLAW_USER_NODE_LOCK_WAIT=2 webclaw-user-node-run npm --loglevel=warn install -g left-pad >/dev/null 2>&1
check "子命令前有选项的 npm install -g 仍要锁（75）" test $? = 75
WEBCLAW_USER_NODE_LOCK_WAIT=2 webclaw-user-node-run npm uninstall -g ls >/dev/null 2>&1
check "包名叫 ls 的 npm uninstall -g 仍要锁（75）" test $? = 75
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "[g] 升级 Node：迁移全局包后再切 default"
latest="$(webclaw-user-node-run nvm version default)"
for v in 20 22; do
    for _ in 1 2 3 4 5; do
        webclaw-user-node-run nvm install "$v" >/dev/null 2>&1 && break
        sleep 3
    done
done
as_ubuntu bash -c '. ~/.nvm/nvm.sh --no-use; nvm use --silent 22 && npm install -g --no-fund --no-audit cowsay >/dev/null'
v20="$(webclaw-user-node-run nvm version 20)"
v22="$(webclaw-user-node-run nvm version 22)"
webclaw-user-node-run nvm alias default "$v22" >/dev/null
printf '%s\n%s\n' "$v20" "$latest" > "$NVM/.webclaw-managed-versions"
# 模拟「旧 default 是 22，最新版还没装」：先卸掉 latest，让升级器真的走一遍安装+迁移。
webclaw-user-node-run nvm uninstall "$latest" >/dev/null 2>&1
out="$(WEBCLAW_USER_NODE_AUTO_UPGRADE="" webclaw-user-node-update --force 2>&1)"
echo "$out" | grep '^\[user-node-update\]' | sed 's/^/    /'
check "default 切到最新 $latest" test "$(webclaw-user-node-run nvm version default)" = "$latest"
check "全局包 cowsay 迁移到新 Node" test -d "$NVM/versions/node/$latest/lib/node_modules/cowsay"
check "~/.nvm/current → $latest" test "$(readlink "$NVM/current")" = "versions/node/$latest"
check "旧 default $v22 保留（回滚用）" test -d "$NVM/versions/node/$v22"
check "受管的更老版本 $v20 被清理" test ! -d "$NVM/versions/node/$v20"
check "系统 Node 未受影响" test "$(/usr/local/bin/node -v)" = v22.22.1
out="$(WEBCLAW_USER_NODE_AUTO_UPGRADE="" webclaw-user-node-update 2>&1)"
check "24h 内再次运行被节流" grep -q "跳过" <<<"$out"


echo "[h] 迁移失败回滚：只卸载本次新装的版本"
# 往旧 default 里塞两个 registry 上不存在的「全局包」，让迁移必然失败。
fake_pkgs() {
    local nm="$NVM/versions/node/$1/lib/node_modules"
    mkdir -p "$nm/webclaw-fake-missing-zz9" "$nm/@webclaw-fake/pkg-zz9"
    echo '{"name":"webclaw-fake-missing-zz9","version":"9.9.9"}' > "$nm/webclaw-fake-missing-zz9/package.json"
    echo '{"name":"@webclaw-fake/pkg-zz9","version":"9.9.9"}' > "$nm/@webclaw-fake/pkg-zz9/package.json"
    chown -R ubuntu:ubuntu "$nm"
}
fake_pkgs "$v22"
webclaw-user-node-run nvm alias default "$v22" >/dev/null
rm -f "$NVM/.webclaw-last-update"
: > "$NVM/.webclaw-managed-versions"
# A：latest 是用户早就装好的（不是 default）→ 迁移失败也必须保留
out="$(WEBCLAW_USER_NODE_AUTO_UPGRADE="" webclaw-user-node-update --force 2>&1)"
echo "$out" | grep '^\[user-node-update\]' | sed 's/^/    /'
check "A: 迁移失败被识别" grep -q "迁移不完整" <<<"$out"
check "A: default 仍是 $v22" test "$(webclaw-user-node-run nvm version default)" = "$v22"
check "A: 用户预装的 $latest 没被卸载" test -d "$NVM/versions/node/$latest"
check "A: 预装版本不记入受管清单" bash -c "! grep -qxF '$latest' '$NVM/.webclaw-managed-versions'"
check "缺失列表含 @scope/name" grep -q "@webclaw-fake/pkg-zz9" <<<"$out"
check "缺失列表不把 @scope 目录当包名" bash -c "! grep -Eq '缺失：(.* )?@webclaw-fake( |$)' <<<\"\$1\"" _ "$out"
# B：latest 升级前不存在 → 本次新装，失败后回滚卸载
webclaw-user-node-run nvm uninstall "$latest" >/dev/null 2>&1
check "B: 前置条件：$latest 已不存在" test ! -d "$NVM/versions/node/$latest"
out="$(WEBCLAW_USER_NODE_AUTO_UPGRADE="" webclaw-user-node-update --force 2>&1)"
echo "$out" | grep '^\[user-node-update\]' | sed 's/^/    /'
check "B: 迁移失败被识别" grep -q "迁移不完整" <<<"$out"
check "B: 本次新装的 $latest 已回滚卸载" test ! -d "$NVM/versions/node/$latest"
check "B: default 仍是 $v22" test "$(webclaw-user-node-run nvm version default)" = "$v22"


echo "[i] 用户 nvm 不可用时 fail closed"
mv "$NVM/nvm.sh" "$NVM/nvm.sh.hidden"
out="$(webclaw-user-node-run npm -v 2>/tmp/err)"; rc=$?
check "npm -v 退出码 127"                test "$rc" = 127
check "没有输出系统 npm 的版本"          test -z "$out"
check "报错说明不会落回系统 PATH"        grep -q "不会落回系统 PATH" /tmp/err
webclaw-user-node-run npm install -g left-pad >/dev/null 2>&1; rc=$?
check "npm install -g 退出码 127"        test "$rc" = 127
check "系统 Node 全局目录没被装进东西"   test ! -e /usr/local/lib/node_modules/left-pad
webclaw-user-node-run node -v >/dev/null 2>&1; rc=$?
check "node -v 不落到系统 node（127）"   test "$rc" = 127
webclaw-user-node-run claude --version >/dev/null 2>&1; rc=$?
check "claude 不落到系统 PATH（127）"    test "$rc" = 127
printf '#!/usr/bin/env node\nconsole.log(process.version)\n' > /tmp/sysnode-probe.js; chmod 755 /tmp/sysnode-probe.js
check "--system-node 仍能用系统 Node 启动服务" test "$(webclaw-user-node-run --system-node /tmp/sysnode-probe.js 2>/dev/null)" = v22.22.1
mv "$NVM/nvm.sh.hidden" "$NVM/nvm.sh"
check "恢复 nvm 后普通模式恢复正常"      bash -c "webclaw-user-node-run node -v | grep -q '^v'"

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
