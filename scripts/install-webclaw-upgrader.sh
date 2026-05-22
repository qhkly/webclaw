#!/usr/bin/env bash
set -euo pipefail

# webclaw-upgrader 安装脚本
# 配套 https://github.com/land007/webclaw-upgrader
#
# 环境变量:
#   WEBCLAW_UPGRADER_VERSION  指定版本号，默认 latest（自动解析 GitHub API）
#   WEBCLAW_DOCKER_BUILD=1    在 Docker 构建阶段调用，跳过 zenity
#   WEBCLAW_APP_LAUNCHER=1    由 webclaw-app-launcher 调用，跳过确认对话框
#   DISABLE_ZENITY=1          禁用所有 zenity 对话框

export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ -f "/.dockerenv" ] || [ "${WEBCLAW_DOCKER_BUILD:-}" = "1" ]; then
    export WEBCLAW_DOCKER_BUILD=1
fi

PROGRESS_FILE="/tmp/webclaw_upgrader_progress"

# 检查是否已安装
if dpkg -s webclaw-upgrader 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[INFO] webclaw-upgrader 已安装，跳过"
    exit 0
fi

# 非 launcher / 非 Docker 构建时显示确认对话框
if [ "${WEBCLAW_APP_LAUNCHER:-}" != "1" ] && [ "${WEBCLAW_DOCKER_BUILD:-}" != "1" ] && [ "${DISABLE_ZENITY:-}" != "1" ]; then
    zenity --question \
      --title="安装 WebClaw Upgrader" \
      --text="<b>确定要安装 WebClaw Upgrader 吗？</b>\n\n这是容器内的软件升级管理工具，\n支持在线升级各组件并查看 Supervisor 状态。\n\n安装后右键桌面图标可卸载。" \
      --ok-label="确定安装" \
      --cancel-label="取消" \
      --width=400 \
      --no-wrap || exit 0
fi

install_main() {
    echo "30" > "$PROGRESS_FILE"

    ARCH=$(dpkg --print-architecture)
    VER="${WEBCLAW_UPGRADER_VERSION:-latest}"
    if [ "$VER" = "latest" ]; then
        echo "[INFO] 获取最新版本..."
        VER=$(curl -fsSL https://api.github.com/repos/land007/webclaw-upgrader/releases/latest \
            | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)
    fi
    echo "[INFO] 安装 webclaw-upgrader v${VER} (${ARCH})"

    echo "50" > "$PROGRESS_FILE"

    DEB_URL="https://github.com/land007/webclaw-upgrader/releases/download/v${VER}/WebClaw.Upgrader_${VER}_${ARCH}.deb"
    echo "[INFO] 下载 ${DEB_URL}"
    curl -fsSL "$DEB_URL" -o /tmp/webclaw-upgrader.deb
    dpkg -i /tmp/webclaw-upgrader.deb || apt-get install -fy
    rm -f /tmp/webclaw-upgrader.deb

    echo "80" > "$PROGRESS_FILE"

    echo "[INFO] 部署 sudoers 权限片段..."
    cat > /etc/sudoers.d/webclaw-upgrader << 'SUDOERS_EOF'
# webclaw-upgrader 升级工具的 sudoers 片段
# 配套 https://github.com/land007/webclaw-upgrader
#
# 仅允许 ubuntu 用户调用升级所需的 root 命令，不影响全局 sudo 策略
# (即便 startup.sh 在设置 PASSWORD 时移除了全局 NOPASSWD,此片段仍生效)
#
# TODO(v0.2): 让 Rust 端不再用 `bash -c` 调用 post_install,从而移除 /bin/bash -c 通配符

# apt 模式: 刷新索引 + 仅升级已安装包
ubuntu ALL=(root) NOPASSWD: /usr/bin/apt-get update
ubuntu ALL=(root) NOPASSWD: /usr/bin/apt-get install -y --only-upgrade *

# npm 全局升级
ubuntu ALL=(root) NOPASSWD: /usr/bin/npm install -g *

# binary-download 模式: 下载、解压、替换二进制目录
ubuntu ALL=(root) NOPASSWD: /usr/bin/curl *
ubuntu ALL=(root) NOPASSWD: /bin/tar *
ubuntu ALL=(root) NOPASSWD: /bin/mv *
ubuntu ALL=(root) NOPASSWD: /bin/rm -rf /opt/*
ubuntu ALL=(root) NOPASSWD: /bin/chown *

# Supervisor 控制(升级后重启 + 状态板查询/重启)
ubuntu ALL=(root) NOPASSWD: /usr/bin/supervisorctl *

# post_install 当前由 software.rs 通过 `sudo bash -c <cmdline>` 调用
# manifest 内 post_install 字段都是 `supervisorctl restart <name>` 形态
ubuntu ALL=(root) NOPASSWD: /bin/bash -c *
SUDOERS_EOF
    chmod 0440 /etc/sudoers.d/webclaw-upgrader
    visudo -c -f /etc/sudoers.d/webclaw-upgrader

    echo "100" > "$PROGRESS_FILE"
    echo "[INFO] webclaw-upgrader 安装完成"
}

if [ "${DISABLE_ZENITY:-}" = "1" ] || [ "${WEBCLAW_DOCKER_BUILD:-}" = "1" ] || [ "${WEBCLAW_APP_LAUNCHER:-}" = "1" ]; then
    install_main
else
    {
        echo "10"
        echo "# 准备安装..."
        install_main
        echo "100"
        echo "# 安装完成！"
    } | zenity --progress \
      --title="安装 WebClaw Upgrader" \
      --text="正在安装..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=400

    if dpkg -s webclaw-upgrader 2>/dev/null | grep -q "Status: install ok installed"; then
        zenity --info \
          --title="安装成功" \
          --text="WebClaw Upgrader 安装成功！\n\n右键桌面图标可选择「卸载」。" \
          --no-wrap
    else
        zenity --error \
          --title="安装失败" \
          --text="WebClaw Upgrader 安装失败，请查看系统日志。" \
          --no-wrap
        exit 1
    fi
fi

rm -f "$PROGRESS_FILE" 2>/dev/null || true
