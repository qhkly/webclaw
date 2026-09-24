#!/usr/bin/env bash
# 在 sudo 测试容器里以 root 运行；所有「ubuntu 能不能做」的检查都真的切到 ubuntu 执行。
set -uo pipefail

pass=0 fail=0
ok()  { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
deny()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d（竟然成功了）"; else ok "$d"; fi; }
as_u()  { runuser -u ubuntu -- "$@"; }
# sudo -l <命令>：只查策略、不执行，允许返回 0。
may()   { as_u sudo -n -l "$@" >/dev/null 2>&1; }
admin() { as_u sudo -n /usr/local/bin/webclaw-app-admin "$@"; }

echo "[1] sudoers 语法与审计"
check "visudo -c 通过" visudo -c
check "webclaw-sudoers-audit 通过" webclaw-sudoers-audit
check "ubuntu 不在 sudo 组" bash -c "! id -nG ubuntu | tr ' ' '\n' | grep -qx sudo"
check "sudo -l 里没有 ALL 命令" bash -c "! runuser -u ubuntu -- sudo -n -l 2>/dev/null | grep -Eq 'NOPASSWD: *ALL|\) *ALL\$'"

echo "[2] ubuntu 不能直接 sudo 的危险命令"
deny "dpkg -i"                         may /usr/bin/dpkg -i /tmp/x.deb
deny "apt-get install -y /tmp/*.deb"   may /usr/bin/apt-get install -y /tmp/webclaw-ondemand-x.deb
deny "apt-get install -fy"             may /usr/bin/apt-get install -fy
deny "apt-get install 任意包"          may /usr/bin/apt-get install -y netcat-openbsd
deny "git"                             may /usr/bin/git --version
deny "supervisorctl"                   may /usr/bin/supervisorctl status
deny "mv 到 /opt"                      may /bin/mv -f /tmp/AppDir /opt/x/AppDir
deny "cp 到 /opt"                      may /bin/cp -a /tmp/x-extract-1/y/. /opt/x/
deny "mkdir /opt/*"                    may /bin/mkdir -p /opt/x
deny "chmod /opt/*"                    may /bin/chmod +x /opt/x/x
deny "mv .desktop"                     may /bin/mv -f /tmp/x.desktop /usr/share/applications/
deny "tee 写 apt 源"                   may /bin/tee /etc/apt/sources.list.d/x.list
deny "gpg 写 keyring"                  may /usr/bin/gpg --dearmor -o /etc/apt/keyrings/x
deny "debconf-set-selections"          may /usr/bin/debconf-set-selections
deny "bash"                            may /bin/bash
deny "未列出的 install-scripts 脚本"   may /opt/install-scripts/evil.sh
deny "install-claude-code.sh（root npm）" may /opt/install-scripts/install-claude-code.sh
deny "直接调用 webclaw-app-uninstaller" may /usr/local/bin/webclaw-app-uninstaller x
deny "直接调用 webclaw-app-postinstall" may /usr/local/bin/webclaw-app-postinstall x
deny "lang-switch 任意参数"            may /usr/local/bin/lang-switch fr
deny "lang-switch 注入参数"            may /usr/local/bin/lang-switch "zh;id"
deny "lang-switch 多参数"              may /usr/local/bin/lang-switch zh en
check "lang-switch zh 放行"           may /usr/local/bin/lang-switch zh
check "lang-switch de 放行"           may /usr/local/bin/lang-switch de
check "列出的 install-scripts 脚本放行" may /opt/install-scripts/install-cc-switch.sh
check "列出的 /opt 安装包装脚本放行"  may /opt/hermes-install-wrapper.sh
check "broker 放行"                   may /usr/local/bin/webclaw-app-admin
check "scripts-updater 放行"          may /usr/local/bin/webclaw-scripts-updater
deny "install-scripts 脚本带额外参数"   may /opt/install-scripts/install-cc-switch.sh --evil
deny "/opt 安装包装脚本带额外参数"      may /opt/hermes-install-wrapper.sh x
deny "uninstall 脚本带额外参数"         may /opt/install-scripts/uninstall-cc-switch.sh a b
deny "scripts-updater 带参数"           may /usr/local/bin/webclaw-scripts-updater --dest /tmp/x
check "broker 可带参数（由 broker 自己校验）" may /usr/local/bin/webclaw-app-admin log-prepare webclaw-test-app
check "列出的脚本真的以 root 执行"     bash -c "runuser -u ubuntu -- sudo -n /opt/install-scripts/install-cc-switch.sh | grep -q 'as root'"

echo "[3] broker 参数校验"
deny "未知动作"                admin rm-rf webclaw-test-app
deny "app_id 路径穿越"         admin log-prepare ../etc/passwd
deny "app_id 含斜杠"           admin log-prepare a/b
deny "app_id 含 .."            admin log-prepare x..y
deny "app_id 大写"             admin log-prepare Evil
deny "app_id 为空"             admin log-prepare ""
deny "保留名 lib（即便有 manifest）" admin install-tree lib appdir
deny "没有 manifest 的 app_id" admin log-prepare nope-not-here
deny "安装方式不匹配（apt-install appimage 应用）" admin apt-install webclaw-test-app
deny "安装方式不匹配（deb-install appimage 应用）" admin deb-install webclaw-test-app
deny "appimage 不允许 flat 布局" admin install-tree webclaw-test-app flat
deny "未知布局"                admin install-tree webclaw-test-dl ../x
deny "manifest 里包名含注入"   admin apt-install webclaw-test-badpkg
deny "预置脚本在 /tmp"         admin apt-prepare webclaw-test-badscript
chmod 664 /opt/on-demand-apps/webclaw-test-gw.json
deny "group 可写的 manifest 不被信任" admin log-prepare webclaw-test-gw
chmod 644 /opt/on-demand-apps/webclaw-test-gw.json
chmod 777 /usr/local/bin/webclaw-test-prepare
deny "可被他人写的预置脚本不执行" admin apt-prepare webclaw-test-apt
chmod 755 /usr/local/bin/webclaw-test-prepare
rm -f /tmp/webclaw-test-prepared
check "root 所有的预置脚本可以执行" admin apt-prepare webclaw-test-apt
check "预置脚本确实跑了"             test -e /tmp/webclaw-test-prepared

echo "[3b] 安全关键路径不受环境变量影响"
mkdir -p /tmp/evil-manifests
echo '{"id":"evilapp","name":"E","package":"x","binary":"/etc/x","install_method":"direct_download"}' > /tmp/evil-manifests/evilapp.json
deny "WEBCLAW_APP_ADMIN_MANIFEST_DIR 不能换 manifest 目录（root 直接调用）" \
    env WEBCLAW_APP_ADMIN_MANIFEST_DIR=/tmp/evil-manifests /usr/local/bin/webclaw-app-admin log-prepare evilapp
deny "经 sudo 带环境变量也不行" \
    runuser -u ubuntu -- sudo -n WEBCLAW_APP_ADMIN_MANIFEST_DIR=/tmp/evil-manifests /usr/local/bin/webclaw-app-admin log-prepare evilapp
rm -rf /tmp/evil-manifests

echo "[4] log-prepare 不跟随符号链接"
passwd_sum="$(sha256sum /etc/passwd)"
as_u ln -sf /etc/passwd /tmp/webclaw-ondemand-webclaw-test-app.log
check "log-prepare 成功"          admin log-prepare webclaw-test-app
check "日志是 ubuntu 的普通文件"   bash -c '[ -f /tmp/webclaw-ondemand-webclaw-test-app.log ] && [ ! -L /tmp/webclaw-ondemand-webclaw-test-app.log ] && [ "$(stat -c %U /tmp/webclaw-ondemand-webclaw-test-app.log)" = ubuntu ]'
check "/etc/passwd 未被改动"      test "$(sha256sum /etc/passwd)" = "$passwd_sum"

echo "[5] deb-install：root 只安装 manifest 来源的包，绝不读取用户的 .deb"
# ubuntu 自己造一个 Package 名完全匹配、postinst 会 touch /root/pwned 的恶意包，放在旧路径。
evil_deb=/tmp/webclaw-ondemand-webclaw-test-deb.deb
as_u bash -c 'set -e; d=$(mktemp -d); mkdir -p $d/DEBIAN
    printf "Package: webclaw-test-deb\nVersion: 9.9\nArchitecture: all\nMaintainer: e <e@e>\nDescription: evil\n" > $d/DEBIAN/control
    printf "#!/bin/sh\ntouch /root/pwned\n" > $d/DEBIAN/postinst; chmod 755 $d/DEBIAN/postinst
    dpkg-deb --build $d '"$evil_deb"' >/dev/null; rm -rf $d'
rm -f /root/pwned
check "前置：恶意包 Package 名与 manifest 完全一致" test "$(dpkg-deb --field "$evil_deb" Package)" = webclaw-test-deb
check "前置：恶意包带 postinst"      bash -c "dpkg-deb -I '$evil_deb' | grep -q postinst"
check "deb-install 成功（装的是 manifest 来源的包）" admin deb-install webclaw-test-deb
check "恶意 postinst 没有执行"        test ! -e /root/pwned
check "装上的是可信的 1.0，不是恶意的 9.9" test "$(dpkg-query -W -f='${Version}' webclaw-test-deb)" = 1.0
check "装上的内容来自可信包"          grep -qx trusted /usr/lib/webclaw-test/webclaw-test-deb/ok
check "broker 根本没碰用户的 .deb"    test -f "$evil_deb" -a "$(stat -c %U "$evil_deb")" = ubuntu
check "没有遗留 root 暂存目录"        test -z "$(ls -A /opt/.webclaw-app-admin 2>/dev/null)"
# 对照：同一个恶意包如果真被 root 安装，payload 确实会生效（证明上面的测试是有效的）。
dpkg -r webclaw-test-deb >/dev/null 2>&1
dpkg -i "$evil_deb" >/dev/null 2>&1
check "对照：恶意包被 root 安装时 payload 确实生效" test -e /root/pwned
dpkg -r webclaw-test-deb >/dev/null 2>&1; rm -f /root/pwned "$evil_deb"

deny "Package 名与 manifest 不符的来源被拒绝" admin deb-install webclaw-test-deb-wrongpkg
check "不符的包没装上"                bash -c "! dpkg -s other-pkg-zz >/dev/null 2>&1"
as_u bash -c 'mkdir -p /tmp/webclaw-evil && cp /opt/webclaw-test-debs/webclaw-test-deb.deb /tmp/webclaw-evil/evil.deb'
deny "file:// 指向 ubuntu 可写位置被拒绝" admin deb-install webclaw-test-deb-tmp
as_u rm -rf /tmp/webclaw-evil
deny "非 https 的来源被拒绝"          admin deb-install webclaw-test-deb-http
deny "带未支持占位符的地址被拒绝"     admin deb-install webclaw-test-deb-placeholder
case "$(dpkg --print-architecture)" in amd64) gh_arch=x86_64 ;; *) gh_arch=aarch64 ;; esac
check "github_release 地址由 broker 按 manifest 推导（version_no_v/arch）" \
    test "$(admin deb-url webclaw-test-ghdeb 2>/dev/null)" = "https://github.com/example-org/example-app/releases/download/v1.2.3/example_1.2.3_${gh_arch}.deb"
deny "deb-url 不能用于非 .deb 应用"   admin deb-url webclaw-test-app

echo "[6] install-tree / wrapper / desktop"
stage=/tmp/webclaw-stage-webclaw-test-app
mk_appdir() {
    as_u bash -c "rm -rf $stage; mkdir -p $stage/usr/bin; printf '#!/bin/sh\necho APP-OK \"\$APPDIR\"\n' > $stage/AppRun; chmod 755 $stage/AppRun"
}
mk_appdir
check "appimage appdir 安装"      admin install-tree webclaw-test-app appdir
check "安装根目录 root 所有"      test "$(stat -c %U /opt/ondemand-apps/webclaw-test-app)" = root
check "ubuntu 不能在安装根目录下新建文件" bash -c "! runuser -u ubuntu -- touch /opt/ondemand-apps/webclaw-test-app/x 2>/dev/null"
check "安装后整棵树 root 所有"      test -z "$(find /opt/ondemand-apps/webclaw-test-app ! -user root -print -quit)"
check "安装后整棵树 group/other 不可写" test -z "$(find /opt/ondemand-apps/webclaw-test-app -perm /022 -print -quit)"
check "ubuntu 不能改内部文件"       bash -c "! runuser -u ubuntu -- sh -c 'echo x >> /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun' 2>/dev/null"
check "ubuntu 不能在内部子目录建文件" bash -c "! runuser -u ubuntu -- touch /opt/ondemand-apps/webclaw-test-app/AppDir/usr/bin/x 2>/dev/null"
check "ubuntu 不能删除内部文件"     bash -c "! runuser -u ubuntu -- rm -f /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun 2>/dev/null && test -e /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun"
check "wrapper 生成"              admin wrapper webclaw-test-app /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun
check "wrapper 可运行且带 APPDIR" bash -c "runuser -u ubuntu -- /opt/ondemand-apps/webclaw-test-app/webclaw-test-app | grep -q 'APP-OK /opt/ondemand-apps/webclaw-test-app/AppDir'"
check "wrapper root 所有、不可被他人写" test "$(stat -c %U:%a /opt/ondemand-apps/webclaw-test-app/webclaw-test-app)" = root:755
deny "wrapper 目标在安装目录外"   admin wrapper webclaw-test-app /bin/bash
deny "wrapper 目标用 .. 逃逸"     admin wrapper webclaw-test-app /opt/ondemand-apps/webclaw-test-app/AppDir/../../../../bin/bash
# 树现在是 root 所有、ubuntu 放不进符号链接；这里由 root 模拟，只验证 wrapper 的 realpath 检查。
ln -sf /bin/bash /opt/ondemand-apps/webclaw-test-app/AppDir/evil
deny "wrapper 目标经符号链接逃逸" admin wrapper webclaw-test-app /opt/ondemand-apps/webclaw-test-app/AppDir/evil

etc_list="$(ls /etc | sha256sum)"
as_u bash -c "rm -rf $stage; ln -s /etc $stage"
deny "暂存目录是指向 /etc 的符号链接" admin install-tree webclaw-test-app appdir
check "/etc 原封不动"             test "$(ls /etc | sha256sum)" = "$etc_list" -a -d /etc
check "拒绝后旧安装还在"          test -x /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun
rm -f /opt/ondemand-apps/webclaw-test-app/AppDir/evil
etc_perm="$(stat -c %a /etc)"
bad_link() {  # $1=描述 $2=链接相对暂存根的路径 $3=target [额外链接对: 路径 target ...]
    local d="$1"; shift
    mk_appdir
    while [ $# -ge 2 ]; do
        as_u mkdir -p "$(dirname "$stage/$1")"
        as_u ln -s "$2" "$stage/$1"
        shift 2
    done
    deny "$d" admin install-tree webclaw-test-app appdir
}
bad_link "嵌套的绝对链接（usr/sub -> /etc）"          usr/sub /etc
bad_link "绝对链接指向树内也拒绝（x -> /opt/...）"    x /opt/ondemand-apps/webclaw-test-app/AppDir/AppRun
bad_link "../../etc 相对逃逸"                         usr/e ../../etc
bad_link "链式链接最终逃逸（a -> b, b -> ..）"        a b b ..
bad_link "先逃出树再绕回来也拒绝（d -> ., x -> d/../item/AppRun）" d . x d/../item/AppRun
bad_link "目录链接后接 .. 逃逸（usr/up -> .., x -> usr/up/../etc）" usr/up .. x usr/up/../etc
bad_link "循环链接（l1 -> l2, l2 -> l1）"             l1 l2 l2 l1
bad_link "自指链接（s -> s）"                         s s
check "/etc 仍原封不动（内容与权限）" test "$(ls /etc | sha256sum)" = "$etc_list" -a "$(stat -c %a /etc)" = "$etc_perm"

# 合法的树内相对链接（AppImage / JetBrains 的库链接形态）
mk_appdir
as_u bash -c "set -e; cd $stage
    mkdir -p usr/lib usr/share/tool
    printf 'lib-content\n' > usr/lib/libfoo.so.1.2
    ln -s libfoo.so.1.2 usr/lib/libfoo.so.1
    ln -s libfoo.so.1 usr/lib/libfoo.so
    ln -s ../../AppRun usr/bin/app
    ln -s ../../lib usr/share/tool/lib
    ln -s ../share/tool/lib/libfoo.so usr/bin/libfoo-via-dir-link
    ln -s missing-but-inside usr/lib/dangling"
check "树内相对链接（含链式、目录链接、树内悬空）安装成功" admin install-tree webclaw-test-app appdir
T=/opt/ondemand-apps/webclaw-test-app/AppDir
check "链接原样保留"                test "$(readlink $T/usr/lib/libfoo.so)" = libfoo.so.1 -a "$(readlink $T/usr/bin/app)" = ../../AppRun
check "链式链接解析到树内真实文件"  test "$(realpath $T/usr/lib/libfoo.so)" = "$T/usr/lib/libfoo.so.1.2"
check "经目录链接的链式链接可读"    grep -qx lib-content "$T/usr/bin/libfoo-via-dir-link"
check "链接指向的 AppRun 可执行"    bash -c "runuser -u ubuntu -- $T/usr/bin/app | grep -q APP-OK"
check "链接本身也归 root（不跟随）" test -z "$(find /opt/ondemand-apps/webclaw-test-app ! -user root -print -quit)"
check "普通文件/目录 group/other 不可写" test -z "$(find /opt/ondemand-apps/webclaw-test-app ! -type l -perm /022 -print -quit)"
check "链接目标文件 root 所有且 644" test "$(stat -c %U:%a $T/usr/lib/libfoo.so.1.2)" = root:644
check "ubuntu 不能经链接改写目标"   bash -c "! runuser -u ubuntu -- sh -c 'echo x >> $T/usr/lib/libfoo.so' 2>/dev/null"
check "ubuntu 不能替换链接"         bash -c "! runuser -u ubuntu -- ln -sfn /etc $T/usr/lib/libfoo.so 2>/dev/null && test \"\$(readlink $T/usr/lib/libfoo.so)\" = libfoo.so.1"
mk_appdir
cp /etc/hostname "$stage/rootfile"
deny "暂存树里有 root 的文件"     admin install-tree webclaw-test-app appdir
mk_appdir
as_u mkfifo "$stage/fifo"
deny "暂存树里有 FIFO"            admin install-tree webclaw-test-app appdir
mk_appdir
if as_u ln /etc/hostname "$stage/hl" 2>/dev/null; then
    deny "暂存树里有指向系统文件的硬链接" admin install-tree webclaw-test-app appdir
else
    ok "内核 protected_hardlinks 已阻止 ubuntu 硬链接系统文件（无需 broker 兜底）"
fi
as_u rm -rf "$stage"

dl=/tmp/webclaw-stage-webclaw-test-dl
as_u bash -c "mkdir -p $dl/bin; printf '#!/bin/sh\necho DL-OK\n' > $dl/bin/tool; chmod 755 $dl/bin/tool"
check "direct_download flat 安装" admin install-tree webclaw-test-dl flat
check "flat 树内容保留"           test -x /opt/webclaw-test-dl/bin/tool
check "flat 安装后整棵树 root 所有" test -z "$(find /opt/webclaw-test-dl ! -user root -print -quit)"
check "ubuntu 不能改 flat 树里的文件" bash -c "! runuser -u ubuntu -- sh -c 'echo x >> /opt/webclaw-test-dl/bin/tool' 2>/dev/null"
check "flat wrapper"              admin wrapper webclaw-test-dl /opt/webclaw-test-dl/bin/tool
check "flat wrapper 可运行"       bash -c "runuser -u ubuntu -- /opt/webclaw-test-dl/webclaw-test-dl | grep -q DL-OK"
check "desktop 生成"              admin desktop webclaw-test-dl
check "desktop 只有一个 Exec=（Name 里的换行被剥掉）" test "$(grep -c '^Exec=' /usr/share/applications/webclaw-test-dl.desktop)" = 1
check "desktop 的 Exec 指向受管 wrapper" grep -qx 'Exec=/opt/webclaw-test-dl/webclaw-test-dl %F' /usr/share/applications/webclaw-test-dl.desktop
as_u bash -c "printf '#!/bin/sh\necho BIN-OK\n' > $dl; chmod 755 $dl"
check "direct_download binary 安装" admin install-tree webclaw-test-dl binary
check "binary 可运行"             bash -c "runuser -u ubuntu -- /opt/webclaw-test-dl/webclaw-test-dl | grep -q BIN-OK"
check "binary 安装后 root 所有、不可被他人写" test "$(stat -c %U:%a /opt/webclaw-test-dl/webclaw-test-dl)" = root:755
deny "desktop 不允许 appimage 应用（没有受管 Exec）" admin desktop webclaw-test-app

echo "[7] 卸载只动受管路径"
check "uninstall appimage 应用"   admin uninstall webclaw-test-app
check "受管目录已删除"            test ! -e /opt/ondemand-apps/webclaw-test-app
check "uninstall direct_download 应用" admin uninstall webclaw-test-dl
check "/opt/webclaw-test-dl 已删除" test ! -e /opt/webclaw-test-dl

echo "[8] apt-install（真实 apt，需要网络）"
if admin apt-install webclaw-test-apt >/tmp/apt.log 2>&1; then
    check "manifest 声明的包已安装" bash -c "dpkg -s hello 2>/dev/null | grep -q 'install ok installed'"
else
    bad "apt-install 失败：$(tail -n 3 /tmp/apt.log | tr '\n' ' ')"
fi

echo "[9] webclaw-scripts-updater（真实下载，需要网络）"
as_u true
touch /opt/install-scripts/ubuntu-planted.sh && chown ubuntu /opt/install-scripts/ubuntu-planted.sh
if as_u sudo -n /usr/local/bin/webclaw-scripts-updater >/tmp/upd.log 2>&1; then
    check "脚本目录 root 所有"       test "$(stat -c %U:%a /opt/install-scripts)" = root:755
    check "目录内全部 root 所有"     test -z "$(find /opt/install-scripts ! -user root -print -quit)"
    check "目录内无 group/other 可写" test -z "$(find /opt/install-scripts -perm /022 -print -quit)"
    check "目录内无符号链接"         test -z "$(find /opt/install-scripts -type l -print -quit)"
    check "旧目录里预埋的文件已随替换消失" test ! -e /opt/install-scripts/ubuntu-planted.sh
    check "拿到了真实脚本"           test -x /opt/install-scripts/install-cc-switch.sh
    check "没有遗留临时目录"         test -z "$(ls -d /opt/.install-scripts.new.* 2>/dev/null)"
    check "更新后审计仍通过"         webclaw-sudoers-audit
else
    bad "updater 失败：$(tail -n 3 /tmp/upd.log | tr '\n' ' ')"
fi
# 更新失败（这里用不可达代理模拟）时旧目录必须原样保留、且没有半成品。
offline() { env https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 /usr/local/bin/webclaw-scripts-updater "$@"; }
before="$(ls -l /opt/install-scripts | sha256sum)"
deny "下载失败时 updater 报错"        offline
check "下载失败后旧脚本目录原样保留" test "$(ls -l /opt/install-scripts | sha256sum)" = "$before"
check "下载失败后没有遗留临时目录"   test -z "$(ls -d /opt/.install-scripts.new.* 2>/dev/null)"
check "下载失败后没有遗留备份"       test ! -e /opt/.install-scripts.backup
deny "updater 不接受参数（root 直接调用也拒绝）" /usr/local/bin/webclaw-scripts-updater --dest /tmp/x
deny "WEBCLAW_INSTALL_SCRIPTS_DIR 不能改目标目录" env WEBCLAW_INSTALL_SCRIPTS_DIR=/tmp/evil-dest https_proxy=http://127.0.0.1:9 /usr/local/bin/webclaw-scripts-updater
check "没有写到环境变量指定的目录"   test ! -e /tmp/evil-dest

# 模拟上次更新在「旧目录已挪到备份、新目录还没放上去」时被 SIGKILL：
mv -T /opt/install-scripts /opt/.install-scripts.backup
check "前置：DEST 缺失、只剩备份"    test ! -e /opt/install-scripts -a -d /opt/.install-scripts.backup
deny "中断后再次运行（仍然离线）"    offline
check "启动时从备份恢复了 DEST"      test "$(ls -l /opt/install-scripts | sha256sum)" = "$before"
check "恢复后备份不再残留"           test ! -e /opt/.install-scripts.backup
check "恢复后审计仍通过"             webclaw-sudoers-audit
# 模拟新目录已就位但备份没来得及删：
mkdir /opt/.install-scripts.backup && touch /opt/.install-scripts.backup/stale.sh
deny "有残留备份时运行（离线）"      offline
check "残留备份被清理、DEST 不受影响" test ! -e /opt/.install-scripts.backup -a "$(ls -l /opt/install-scripts | sha256sum)" = "$before"

echo "[10] 审计能发现被放宽的配置"
chmod 775 /opt/hermes-install-wrapper.sh
deny "被 sudoers 引用的脚本变成 group 可写时审计失败" webclaw-sudoers-audit
chmod 755 /opt/hermes-install-wrapper.sh
echo 'ubuntu ALL=(root) NOPASSWD: /opt/install-scripts/*.sh' > /etc/sudoers.d/zz-test && chmod 440 /etc/sudoers.d/zz-test
deny "出现通配规则时审计失败"    webclaw-sudoers-audit
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/zz-test
deny "出现免密 ALL 时审计失败"   webclaw-sudoers-audit
echo 'ubuntu ALL=(root) NOPASSWD: /opt/install-scripts/install-cc-switch.sh' > /etc/sudoers.d/zz-test
deny "脚本规则没约束参数时审计失败" webclaw-sudoers-audit
rm -f /etc/sudoers.d/zz-test
check "恢复后审计通过"           webclaw-sudoers-audit

echo "[11] 人工 sudo 三档与来回切换（关闭 → 密码 → 免密 → 关闭）"
NPF=/etc/sudoers.d/webclaw-user-nopasswd
PW='webclaw-test-pw-123'
echo "ubuntu:$PW" | chpasswd
apply() { env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin ENABLE_USER_SUDO="$1" ENABLE_USER_SUDO_NOPASSWD="$2" PASSWORD="$3" /usr/local/bin/webclaw-apply-user-sudo; }
in_group() { id -nG ubuntu | tr ' ' '\n' | grep -qx sudo; }
sudo_n()  { as_u sudo -k >/dev/null 2>&1; as_u sudo -n true >/dev/null 2>&1; }
sudo_pw() { as_u sudo -k >/dev/null 2>&1; printf '%s\n' "$PW" | as_u sudo -S -p '' true >/dev/null 2>&1; }
broker_ok() { may /usr/local/bin/webclaw-app-admin; }

check "关闭：应用成功"                apply false false "$PW"
check "关闭：不在 sudo 组"            bash -c '! id -nG ubuntu | tr " " "\n" | grep -qx sudo'
check "关闭：没有免密文件"            test ! -e "$NPF"
deny  "关闭：sudo -n true 失败"       sudo_n
deny  "关闭：有密码也不能 sudo"       sudo_pw
check "关闭：受控 broker 仍可用"      broker_ok

check "密码：应用成功"                apply true false "$PW"
check "密码：在 sudo 组"              in_group
check "密码：没有免密文件"            test ! -e "$NPF"
deny  "密码：无凭据 sudo -n true 失败" sudo_n
check "密码：输入密码可以 sudo"       sudo_pw
check "密码：受控 broker 仍可用"      broker_ok

check "免密：应用成功"                apply true true ""
check "免密：文件 root:root 0440"     test "$(stat -c %U:%G:%a "$NPF")" = root:root:440
check "免密：内容是精确的一条规则"    test "$(cat "$NPF")" = 'ubuntu ALL=(ALL:ALL) NOPASSWD: ALL'
check "免密：visudo -c 通过"          visudo -c -q
check "免密：sudo -n true 成功（不依赖 PASSWORD）" sudo_n
check "免密：ubuntu 不能改写免密文件" bash -c "! runuser -u ubuntu -- sh -c 'echo x >> $NPF' 2>/dev/null"
check "免密：没有遗留临时文件"        test -z "$(find /etc/sudoers.d -maxdepth 1 -name '.webclaw-user-nopasswd.*' -print -quit)"
check "免密：审计只跳过这个精确文件，其余照常通过" webclaw-sudoers-audit
check "免密：受控 broker 仍可用"      broker_ok
check "免密：重复应用幂等"            bash -c "$(declare -f apply); apply true true '' >/dev/null && test \"\$(stat -c %a $NPF)\" = 440"

check "免密 → 关闭：应用成功"         apply false false "$PW"
check "关闭：免密文件已删除"          test ! -e "$NPF"
check "关闭：已移出 sudo 组"          bash -c '! id -nG ubuntu | tr " " "\n" | grep -qx sudo'
deny  "关闭：sudo -n true 失败"       sudo_n

check "NOPASSWD=true 但 ENABLE=false：以关闭为准" apply false true "$PW"
check "  → 没有免密文件"              test ! -e "$NPF"
deny  "  → sudo -n true 失败"         sudo_n

check "ENABLE=true 但 PASSWORD 为空（密码模式）：应用成功" apply true false ""
check "  → 有明确 warning"            bash -c "$(declare -f apply); apply true false '' | grep -q WARNING"
check "  → 不在 sudo 组（无密码可输）" bash -c '! id -nG ubuntu | tr " " "\n" | grep -qx sudo'
deny  "  → sudo -n true 失败"         sudo_n

# 审计仍拒绝被篡改/非预期的免密文件
printf 'ubuntu ALL=(ALL) NOPASSWD: ALL\n' > "$NPF"; chmod 440 "$NPF"
deny  "免密文件内容不是预期那一行时审计失败" webclaw-sudoers-audit
printf 'ubuntu ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$NPF"; chmod 644 "$NPF"
deny  "免密文件权限不是 0440 时审计失败" webclaw-sudoers-audit
check "重新应用关闭档会清掉它"        apply false false ""
check "  → 文件已删除且审计通过"      bash -c "test ! -e $NPF && webclaw-sudoers-audit >/dev/null"
echo 'ubuntu ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/zz-other && chmod 440 /etc/sudoers.d/zz-other
deny  "其它文件里的同样规则不会被豁免" webclaw-sudoers-audit
rm -f /etc/sudoers.d/zz-other

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
