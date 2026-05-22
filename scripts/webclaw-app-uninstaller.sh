#!/bin/bash
# Root-side uninstaller for webclaw-app-launcher.

set -u

APP_ID="${1:-}"

if [[ ! "$APP_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Invalid app id: $APP_ID" >&2
    exit 1
fi

MANIFEST="/opt/on-demand-apps/${APP_ID}.json"
if [ ! -f "$MANIFEST" ]; then
    echo "Manifest not found: $MANIFEST" >&2
    exit 1
fi

PKG=$(jq -r '.package' "$MANIFEST")
BIN=$(jq -r '.binary' "$MANIFEST")
INSTALL_METHOD=$(jq -r '.install_method // "github_release"' "$MANIFEST")

case "$INSTALL_METHOD" in
    appimage)
        rm -rf "/opt/ondemand-apps/${APP_ID}"
        rm -f "/usr/share/applications/${APP_ID}.desktop"
        ;;
    r2_download|direct_download|cursor_api)
        # 检查是否是通过 dpkg 安装的包（如 .deb 文件安装）
        if dpkg -s "$PKG" >/dev/null 2>&1; then
            apt-get remove -y "$PKG"
        else
            rm -rf "/opt/${APP_ID}"
        fi
        rm -f "/usr/share/applications/${APP_ID}.desktop"
        rm -f "/usr/share/applications/${PKG}.desktop"
        ;;
    apt|github_release)
        if dpkg -s "$PKG" >/dev/null 2>&1; then
            apt-get remove -y "$PKG"
        fi
        rm -f "/usr/share/applications/${APP_ID}.desktop"
        rm -f "/usr/share/applications/${PKG}.desktop"
        ;;
    custom_script)
        UNINSTALL_SCRIPT=$(jq -r '.uninstall_script // empty' "$MANIFEST")
        if [ -n "$UNINSTALL_SCRIPT" ] && [ -x "$UNINSTALL_SCRIPT" ]; then
            DISABLE_ZENITY=1 "$UNINSTALL_SCRIPT"
        else
            echo "No uninstall_script defined for $APP_ID" >&2
            exit 1
        fi
        ;;
    *)
        echo "Unknown install method: $INSTALL_METHOD" >&2
        exit 1
        ;;
esac

if [ -n "$BIN" ] && [ "$BIN" != "null" ]; then
    case "$BIN" in
        /opt/ondemand-apps/"$APP_ID"/*|/opt/"$APP_ID"/*) ;;
        *) [ -e "$BIN" ] && echo "Left binary outside managed path: $BIN" >&2 ;;
    esac
fi

exit 0
