#!/usr/bin/env bash
set -euo pipefail

dpkg -r webclaw-software-manager 2>/dev/null || apt-get remove -y webclaw-software-manager 2>/dev/null || true
rm -f /opt/on-demand-icons/webclaw-software-manager.png
echo "[INFO] webclaw-software-manager 已卸载"
