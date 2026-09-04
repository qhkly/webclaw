#!/usr/bin/env bash

webclaw_app_installed() {
    local install_method="$1" package="$2" binary="$3"
    case "$install_method" in
        appimage|cursor_api|direct_download|custom_script|tarball) [ -x "$binary" ] ;;
        apt|github_release) dpkg -s "$package" >/dev/null 2>&1 && [ -x "$binary" ] ;;
        *) return 1 ;;
    esac
}
