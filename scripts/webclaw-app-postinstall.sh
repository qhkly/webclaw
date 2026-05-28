#!/bin/bash
# Root-side post-install hook for webclaw-app-launcher.
# 用法: sudo webclaw-app-postinstall <app_id>
#
# 用 root-side 硬编码动作的方式做安装后处置（建组、加用户、setcap 等），
# 避免在 sudoers 里写带 = 号的 setcap 参数（sudo 会把 = 当 env 赋值导致匹配失败）。
# 添加新应用的 post-install 钩子时，仅在下方 case 中加一段，sudoers 不需要改。

set -u

APP_ID="${1:-}"

if [[ ! "$APP_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Invalid app id: $APP_ID" >&2
    exit 1
fi

case "$APP_ID" in
    ghostty)
        # Ghostty's bundled GTK4 scans /usr/lib/gtk-4.0 instead of the
        # distro multiarch path, so expose the fcitx5 GTK4 module there.
        MODULE=$(find /usr/lib -path '*/gtk-4.0/4.0.0/immodules/libim-fcitx5.so' ! -path '/usr/lib/gtk-4.0/*' -print -quit 2>/dev/null || true)
        if [ -n "$MODULE" ]; then
            mkdir -p /usr/lib/gtk-4.0/4.0.0/immodules
            ln -sfn "$MODULE" /usr/lib/gtk-4.0/4.0.0/immodules/libim-fcitx5.so
        fi

        # Keep an AppDir-local link as a fallback for AppImages that do
        # include their own module search path.
        APPDIR=/opt/ondemand-apps/ghostty/AppDir
        if [ -n "$MODULE" ] && [ -d "$APPDIR" ]; then
            TARGET_DIR="$APPDIR/shared/lib/gtk-4.0/4.0.0/immodules"
            mkdir -p "$TARGET_DIR"
            ln -sfn "$MODULE" "$TARGET_DIR/libim-fcitx5.so"
        fi
        ;;
    wireshark)
        # wireshark-common 包安装时本应通过 dpkg-reconfigure 自动创建 wireshark 组并
        # setcap dumpcap；但 apt -y 在容器环境下 debconf 时序不稳定，常常没生效。
        # 这里幂等地补做一次（groupadd -f / usermod -a / setcap 都可重复执行）。
        groupadd -f wireshark
        usermod -a -G wireshark ubuntu
        setcap cap_net_raw,cap_net_admin=ep /usr/bin/dumpcap

        # Keep the single official menu entry, but use WebClaw's cleaner icon.
        if [ -f /usr/share/applications/org.wireshark.Wireshark.desktop ] \
            && [ -f /opt/on-demand-icons/wireshark.png ]; then
            sed -i 's|^Icon=.*|Icon=/opt/on-demand-icons/wireshark.png|' \
                /usr/share/applications/org.wireshark.Wireshark.desktop
            rm -f /usr/share/applications/wireshark.desktop
            update-desktop-database /usr/share/applications 2>/dev/null || true
        fi
        ;;
    qq)
        # QQ 官方 desktop 文件使用 Categories=Network，导致被归类到"互联网"分类
        # 修改为更合适的分类
        if [ -f /usr/share/applications/qq.desktop ]; then
            # 完全移除 Network 分类，使用更合适的分类
            sed -i 's|Categories=Network;|Categories=GNOME;GTK;Utility;|' \
                /usr/share/applications/qq.desktop
            update-desktop-database /usr/share/applications 2>/dev/null || true
        fi
        ;;
    *)
        # 没有钩子的应用直接成功返回（避免 launcher 误判失败）
        exit 0
        ;;
esac

exit 0
