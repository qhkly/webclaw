#!/usr/bin/env bash
# 测试替身：真 webcode-studiod 是原生二进制，这里只报告它继承到的环境。
echo "STUDIOD-PATH=$PATH"
echo "STUDIOD-NODE=$(command -v node) $(node -v 2>/dev/null)"
echo "STUDIOD-CLAUDE=$(command -v claude)"
