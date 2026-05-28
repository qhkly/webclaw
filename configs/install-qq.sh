#!/bin/bash
# QQ Linux 安装脚本
# 由于官方下载链接可能变化，此脚本尝试多种方式获取 QQ

set -e

# 配置变量
APP_ID="qq"
PKG_NAME="linuxqq"
INSTALL_DIR="/opt/QQ"
PROGRESS_FILE="/tmp/${APP_ID}_progress"
PROGRESS_DESC_FILE="/tmp/${APP_ID}_progress.desc"
LOG="/tmp/webclaw-ondemand-${APP_ID}.log"

# 更新进度函数
update_progress() {
    echo "$1" > "$PROGRESS_FILE" 2>/dev/null || true
}

# 更新进度描述
update_progress_desc() {
    echo "$1" > "$PROGRESS_DESC_FILE" 2>/dev/null || true
}

# 记录日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

# 更新进度
update_progress 10
update_progress_desc "准备安装环境..."

log "开始安装 QQ"

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="amd64"
        ;;
    aarch64)
        ARCH_SUFFIX="arm64"
        ;;
    *)
        log "不支持的架构: $ARCH"
        update_progress 100
        exit 1
        ;;
esac

log "检测到架构: $ARCH ($ARCH_SUFFIX)"

# 安装依赖
update_progress 20
update_progress_desc "安装依赖包..."

log "安装依赖"
apt-get update >> "$LOG" 2>&1 || true

# 尝试安装 gtk2.0 和其他可能的依赖
apt-get install -y libgtk2.0-0 libnotify4 libxtst6 libxss1 libxrandr2 >> "$LOG" 2>&1 || true

update_progress 30
update_progress_desc "搜索可用的 QQ 下载源..."

# 定义多个可能的下载源
declare -A DOWNLOAD_SOURCES

# 正确的下载链接格式（包含日期和序号）
# 格式：https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.28_260429_${ARCH_SUFFIX}_01.deb
DOWNLOAD_SOURCES[qqv6_3_2_28]="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.28_260429_${ARCH_SUFFIX}_01.deb"
DOWNLOAD_SOURCES[qqv6_3_2_6]="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.6_260429_${ARCH_SUFFIX}_01.deb"
DOWNLOAD_SOURCES[qqv6_3_1_2]="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.1.2_260429_${ARCH_SUFFIX}_01.deb"

# 备用格式（不包含日期序号）
DOWNLOAD_SOURCES[qqv6_simple]="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.28_${ARCH_SUFFIX}.deb"
DOWNLOAD_SOURCES[qqv1_simple]="https://dldir1.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.28_${ARCH_SUFFIX}.deb"

# GitHub releases（备用）
DOWNLOAD_SOURCES[github1]="https://github.com/linuxqq/linuxqq-releases/releases/download/v3.2.28/LinuxQQ_v3.2.28_${ARCH_SUFFIX}.deb"

# 尝试其他版本号和日期
for VER in "3.2.6" "3.1.2"; do
    DOWNLOAD_SOURCES[qqv6${VER}]="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_${VER}_260429_${ARCH_SUFFIX}_01.deb"
done

log "测试 ${#DOWNLOAD_SOURCES[@]} 个可能的下载源"

# 测试每个下载源
DOWNLOAD_URL=""
for source in "${!DOWNLOAD_SOURCES[@]}"; do
    TEST_URL="${DOWNLOAD_SOURCES[$source]}"
    log "测试 $source: $TEST_URL"

    HTTP_CODE=$(curl -sI -m 5 "$TEST_URL" 2>> "$LOG" | grep "HTTP" | head -1 | awk '{print $2}')
    if [ "$HTTP_CODE" = "200" ]; then
        DOWNLOAD_URL="$TEST_URL"
        log "找到可用链接: $source -> $DOWNLOAD_URL"
        break
    fi
done

# 如果所有链接都失败，提供备用方案
if [ -z "$DOWNLOAD_URL" ]; then
    log "警告: 所有自动下载源都不可用"
    update_progress 40
    update_progress_desc "下载源不可用，使用备用方案..."

    # 备用方案1: 尝试从官方页面动态获取
    log "尝试从官方页面获取下载链接"
    PAGE_CONTENT=$(curl -sL "https://im.qq.com/linuxqq/download.html" 2>> "$LOG" || echo "")

    if [ -n "$PAGE_CONTENT" ]; then
        # 尝试多种正则表达式匹配
        DOWNLOAD_URL=$(echo "$PAGE_CONTENT" | grep -oP 'https://[^"]*\.qq\.com[^"]*linuxqq[^"]*\.deb' | head -1 || echo "")
        if [ -z "$DOWNLOAD_URL" ]; then
            DOWNLOAD_URL=$(echo "$PAGE_CONTENT" | grep -oP 'https://[^"]*dldir[^"]*\.deb' | head -1 || echo "")
        fi
        if [ -z "$DOWNLOAD_URL" ]; then
            DOWNLOAD_URL=$(echo "$PAGE_CONTENT" | grep -oP 'https://[^"]*LinuxQQ[^"]*\.deb' | head -1 || echo "")
        fi

        if [ -n "$DOWNLOAD_URL" ]; then
            log "从页面提取到链接: $DOWNLOAD_URL"

            # 验证链接是否有效
            HTTP_CODE=$(curl -sI -m 5 "$DOWNLOAD_URL" 2>> "$LOG" | grep "HTTP" | head -1 | awk '{print $2}')
            if [ "$HTTP_CODE" != "200" ]; then
                log "提取的链接无效: $HTTP_CODE"
                DOWNLOAD_URL=""
            fi
        fi
    fi
fi

# 如果还是找不到，提供手动安装指导
if [ -z "$DOWNLOAD_URL" ]; then
    log "错误: 无法找到可用的下载源"
    update_progress 100
    update_progress_desc "QQ 安装失败：无法找到下载源"

    # 创建错误提示文件
    cat > "/tmp/qq-install-error.txt" <<EOF
QQ 安装失败

无法自动找到 QQ 的下载源。请尝试以下方法：

1. 访问 QQ Linux 官方网站：https://im.qq.com/linuxqq/download.html
2. 手动下载对应架构的 deb 包
3. 使用以下命令安装：
   sudo dpkg -i LinuxQQ_*.deb
   sudo apt-get install -f

当前支持的架构：$ARCH_SUFFIX
EOF

    exit 1
fi

update_progress 50
update_progress_desc "下载 QQ 安装包..."

# 下载 deb 包
DEB_FILE="/tmp/linuxqq-${ARCH_SUFFIX}.deb"
log "下载 QQ 从: $DOWNLOAD_URL"

if ! curl -fsSL -m 300 "$DOWNLOAD_URL" -o "$DEB_FILE" >> "$LOG" 2>&1; then
    log "下载失败: $DOWNLOAD_URL"
    update_progress 100
    exit 1
fi

# 检查文件是否有效
if [ ! -s "$DEB_FILE" ]; then
    log "下载的文件为空或无效"
    update_progress 100
    exit 1
fi

log "下载完成，文件大小: $(stat -c%s "$DEB_FILE" 2>/dev/null || stat -f%z "$DEB_FILE" 2>/dev/null) bytes"

# 验证是否为有效的 deb 包
if ! dpkg -I "$DEB_FILE" >> "$LOG" 2>&1; then
    log "下载的文件不是有效的 deb 包"
    rm -f "$DEB_FILE"
    update_progress 100
    exit 1
fi

update_progress 60
update_progress_desc "安装 QQ..."

# 获取包信息
PACKAGE_INFO=$(dpkg -I "$DEB_FILE" 2>> "$LOG" || true)
if echo "$PACKAGE_INFO" | grep -q "Package:"; then
    PACKAGE_NAME=$(echo "$PACKAGE_INFO" | grep "^ Package:" | awk '{print $2}')
    VERSION=$(echo "$PACKAGE_INFO" | grep "^ Version:" | awk '{print $2}')
    log "包信息: $PACKAGE_NAME 版本 $VERSION"
else
    log "警告: 无法解析包信息"
    PACKAGE_NAME="linuxqq"
fi

# 安装 deb 包
update_progress 70
if ! dpkg -i "$DEB_FILE" >> "$LOG" 2>&1; then
    log "dpkg 安装失败，尝试修复依赖"
    update_progress_desc "修复依赖..."
    apt-get install -f -y >> "$LOG" 2>&1 || true
    if ! dpkg -i "$DEB_FILE" >> "$LOG" 2>&1; then
        log "安装失败"
        rm -f "$DEB_FILE"
        update_progress 100
        exit 1
    fi
fi

# 清理临时文件
rm -f "$DEB_FILE"

update_progress 90
update_progress_desc "配置 QQ..."

# 验证安装
if [ -x "/opt/QQ/qq" ]; then
    log "QQ 安装成功: /opt/QQ/qq"
    update_progress 100
    exit 0
elif [ -x "/usr/bin/linuxqq-electron" ]; then
    log "QQ 安装成功: /usr/bin/linuxqq-electron"
    update_progress 100
    exit 0
elif [ -x "/usr/bin/qq" ]; then
    log "QQ 安装成功: /usr/bin/qq"
    update_progress 100
    exit 0
else
    log "安装验证失败，查找可执行文件..."
    QQ_BIN=$(find /opt /usr/bin -name "*qq*" -executable 2>/dev/null | head -1 || true)
    if [ -n "$QQ_BIN" ]; then
        log "找到 QQ 可执行文件: $QQ_BIN"
        update_progress 100
        exit 0
    fi
    log "安装验证失败"
    update_progress 100
    exit 1
fi
