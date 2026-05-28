#!/bin/bash
# QQ 版本检测脚本
# 从官方页面动态获取最新的版本信息和下载链接

set -e

echo "=== QQ Linux 版本检测 ==="

# 方法1: 检查当前已知的最新版本
echo ""
echo "方法1: 检查已知版本"
CURRENT_VERSION="3.2.28"
KNOWN_DATE="260429"

for arch in "amd64" "arm64"; do
    URL="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_${CURRENT_VERSION}_${KNOWN_DATE}_${arch}_01.deb"
    echo -n "  测试 $arch: "
    HTTP_CODE=$(curl -sI -m 3 "$URL" 2>&1 | grep "HTTP" | head -1 | awk '{print $2}')
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ 可用 ($URL)"
    else
        echo "❌ $HTTP_CODE"
    fi
done

# 方法2: 尝试检测更新的版本（测试最近几周的日期）
echo ""
echo "方法2: 检测更新的版本"

BASE_DATE="20260429"  # 4月29日
TODAY=$(date +%Y%m%d)
CURRENT_UNIX=$(date -d "$TODAY" +%s)
KNOWN_UNIX=$(date -d "$BASE_DATE" +%s)

# 测试最近30天的日期（每周二）
for i in {0..30}; do
    TEST_DATE=$(date -d "$BASE_DATE + $i days" +%Y%m%d 2>/dev/null) || continue
    TEST_UNIX=$(date -d "$BASE_DATE + $i days" +%s 2>/dev/null) || continue

    # 只在周二检查（QQ 通常周二发布）
    # [ $(date -d "$BASE_DATE + $i days" +%u 2>/dev/null) -eq 2 ] || continue

    for arch in "amd64"; do
        URL="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.28_${TEST_DATE}_${arch}_01.deb"
        HTTP_CODE=$(curl -sI -m 2 "$URL" 2>&1 | grep "HTTP" | head -1 | awk '{print $2}')

        if [ "$HTTP_CODE" = "200" ]; then
            echo "  找到更新日期: $TEST_DATE ($URL)"
            echo "  这意味着可能有新版本"
            break 2
        fi
    done
done

# 方法3: 检查版本号变化
echo ""
echo "方法3: 检测版本号变化"

for ver in "3.2.29" "3.2.30" "3.3.0"; do
    for arch in "amd64"; do
        URL="https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_${ver}_260429_${arch}_01.deb"
        HTTP_CODE=$(curl -sI -m 2 "$URL" 2>&1 | grep "HTTP" | head -1 | awk '{print $2}')

        if [ "$HTTP_CODE" = "200" ]; then
            echo "  ✅ 发现新版本: $ver ($URL)"
            break 2
        fi
    done
done

echo ""
echo "=== 推荐的更新策略 ==="
echo "1. 当前版本: $CURRENT_VERSION (日期: $BASE_DATE)"
echo "2. 下载链接格式: https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_{version}_{date}_{arch}_01.deb"
echo "3. 定期检查：建议每周二检查新版本（QQ 通常周二发布）"
echo ""
echo "如需更新安装脚本，手动修改 configs/install-qq.sh 中的下载源配置"
