#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  webclaw-sudoers-audit —— 校验 ubuntu 的 sudo 授权仍是最小集合。
#  安装位置：/usr/local/bin/webclaw-sudoers-audit；构建末尾执行，失败即构建失败。
#
#  检查：
#    1. visudo -c 通过；
#    2. 没有给 ubuntu（或 %sudo 之外的组）任何 NOPASSWD ALL / 命令通配；
#       除 broker 外，每条规则都必须约束参数（"" 或精确参数）；
#    3. 每条 NOPASSWD 规则引用的可执行文件及其所有上级目录都是 root 所有、
#       非符号链接、group/other 不可写（否则 ubuntu 能改脚本内容 = 任意 root）。
#       /opt/install-scripts/ 下尚未下载的脚本允许不存在（目录本身仍要检查）。
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail

fail=0
bad() { echo "[sudoers-audit] ✗ $*" >&2; fail=1; }

# 唯一例外：用户显式选择「免密 sudo」时 webclaw-apply-user-sudo 在运行时生成的固定文件。
# 只在内容与预期那一行完全一致、且 root:root 0440 时跳过；否则照常审计（从而报错）。
# 镜像构建阶段它不存在；其它任何 NOPASSWD ALL 仍然会被拒绝。
USER_NOPASSWD_FILE=/etc/sudoers.d/webclaw-user-nopasswd
USER_NOPASSWD_RULE='ubuntu ALL=(ALL:ALL) NOPASSWD: ALL'
SUDOERS_FILES=(/etc/sudoers)
for f in /etc/sudoers.d/*; do
    if [ "$f" = "$USER_NOPASSWD_FILE" ] && [ ! -L "$f" ] \
        && [ "$(stat -c %u:%g:%a "$f")" = 0:0:440 ] \
        && [ "$(cat "$f")" = "$USER_NOPASSWD_RULE" ]; then
        echo "[sudoers-audit] · 跳过运行时用户显式开启的免密 sudo 文件 $f"
        continue
    fi
    SUDOERS_FILES+=("$f")
done

visudo -c >/dev/null || bad "visudo -c 失败"

# 规则行（去注释、去 Defaults）。
rules="$(cat "${SUDOERS_FILES[@]}" 2>/dev/null | sed 's/#.*//' | grep -vE '^\s*(Defaults|$|@include)' || true)"

while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        *NOPASSWD:*ALL*) bad "免密 ALL：$line" ;;
    esac
    case "$line" in
        ubuntu*ALL\)*ALL|ubuntu*ALL\)\ ALL*) bad "ubuntu 拥有全部命令：$line" ;;
    esac
    if [[ "$line" == *NOPASSWD:* ]]; then
        cmd="${line#*NOPASSWD:}"
        cmd="$(echo "$cmd" | awk '{print $1}')"
        [[ "$cmd" == *'*'* ]] && bad "命令路径含通配：$line"
        [[ "$line" == *'*'* ]] && bad "参数含通配：$line"
        [[ "$cmd" == /* ]] || { bad "命令不是绝对路径：$line"; continue; }
        # sudoers 里命令后不写参数 = 允许任意参数。只有 broker 自己校验参数，其余必须显式约束
        # （写 "" 表示只允许无参数，或写出精确参数）。
        args="$(echo "${line#*NOPASSWD:}" | awk '{$1=""; sub(/^ +/, ""); print}')"
        if [ -z "$args" ] && [ "$cmd" != /usr/local/bin/webclaw-app-admin ]; then
            bad "未约束参数（应写 \"\" 或精确参数）：$line"
        fi
        if [ ! -e "$cmd" ]; then
            case "$cmd" in /opt/install-scripts/*) ;; *) bad "引用的命令不存在：$cmd" ;; esac
        fi
        p="$cmd"
        while :; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                [ -L "$p" ] && [ "$p" = "$cmd" ] && case "$p" in /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) ;; *) bad "$p 是符号链接" ;; esac
                [ "$(stat -c %u "$p")" = 0 ] || bad "$p 不是 root 所有"
                [ -z "$(find "$p" -maxdepth 0 -perm /022 ! -type l 2>/dev/null)" ] || bad "$p 可被 group/other 写"
            fi
            [ "$p" = / ] && break
            p="$(dirname "$p")"
        done
    fi
done <<< "$rules"

if [ "$fail" = 0 ]; then
    echo "[sudoers-audit] ✓ sudoers 最小权限检查通过"
fi
exit "$fail"
