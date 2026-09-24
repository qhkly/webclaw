#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-apply-user-sudo —— 按环境变量幂等地重算 ubuntu 的人工 sudo 档位。
#  安装位置：/usr/local/bin/webclaw-apply-user-sudo（root 所有，只由 startup.sh 以 root 调用，
#  不在 sudoers 里）。每次启动都跑一遍，切换档位后重启即生效/收回。
#
#  三档（启动器显式传 true/false）：
#    ENABLE_USER_SUDO=false                                → 关闭：不在 sudo 组，无免密文件
#    ENABLE_USER_SUDO=true  ENABLE_USER_SUDO_NOPASSWD=false → 密码：PASSWORD 非空才进 sudo 组
#    ENABLE_USER_SUDO=true  ENABLE_USER_SUDO_NOPASSWD=true  → 免密：写 /etc/sudoers.d/webclaw-user-nopasswd
#  NOPASSWD=true 但 ENABLE_USER_SUDO≠true 时以关闭为准。
#  自动化用的受控入口（webclaw-app-admin 等）与这里无关，三档下都不变。
#  不修改 /etc/sudoers 主文件。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER_NAME=ubuntu
NOPASSWD_FILE=/etc/sudoers.d/webclaw-user-nopasswd
NOPASSWD_RULE='ubuntu ALL=(ALL:ALL) NOPASSWD: ALL'

[ "$(id -u)" = 0 ] || { echo "webclaw-apply-user-sudo 必须以 root 运行" >&2; exit 1; }

enable="${ENABLE_USER_SUDO:-false}"
nopasswd="${ENABLE_USER_SUDO_NOPASSWD:-false}"
password="${PASSWORD:-}"

remove_nopasswd() { rm -f -- "$NOPASSWD_FILE"; }
leave_sudo_group() { gpasswd -d "$USER_NAME" sudo >/dev/null 2>&1 || true; }

write_nopasswd() {
    local tmp
    # 临时文件建在 sudoers.d 同目录（root 0755），sudo 会忽略名字里带 . 的文件，
    # 校验通过后 rename 就位，任何时刻都不会出现半截或可被他人写的规则文件。
    tmp="$(mktemp /etc/sudoers.d/.webclaw-user-nopasswd.XXXXXX)"
    printf '%s\n' "$NOPASSWD_RULE" > "$tmp"
    chown root:root "$tmp"
    chmod 0440 "$tmp"
    if ! visudo -c -q -f "$tmp" >/dev/null; then
        rm -f -- "$tmp"
        echo "[user-sudo] ERROR: 生成的免密规则未通过 visudo，保持关闭" >&2
        return 1
    fi
    mv -Tf -- "$tmp" "$NOPASSWD_FILE"
}

if [ "$enable" != true ]; then
    remove_nopasswd
    leave_sudo_group
    if [ "$nopasswd" = true ]; then
        echo "[user-sudo] WARNING: ENABLE_USER_SUDO_NOPASSWD=true 但 ENABLE_USER_SUDO 未开启，以关闭为准"
    fi
    echo "[user-sudo] 人工 sudo：关闭（自动化只能用 webclaw-app-admin 等受控入口）"
elif [ "$nopasswd" = true ]; then
    usermod -aG sudo "$USER_NAME"
    if write_nopasswd; then
        echo "[user-sudo] 人工 sudo：免密码（用户显式选择；/etc/sudoers.d/webclaw-user-nopasswd）"
    else
        remove_nopasswd
        leave_sudo_group
        exit 1
    fi
else
    remove_nopasswd
    if [ -n "$password" ]; then
        usermod -aG sudo "$USER_NAME"
        echo "[user-sudo] 人工 sudo：需要密码"
    else
        leave_sudo_group
        echo "[user-sudo] WARNING: ENABLE_USER_SUDO=true 但没有设置 PASSWORD，没有密码可输，人工 sudo 保持不可用"
    fi
fi
