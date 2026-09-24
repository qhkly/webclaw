#!/bin/bash
# GNOME Flashback desktop language switch script
export DISPLAY=:1
export XDG_RUNTIME_DIR=/run/user/1000

# 先把各种别名归一成 7 个短代码：sudoers 只精确放行
# `lang-switch zh|en|ja|es|pt|ko|de` 这 7 条，不允许任意参数。
case "${1:-}" in
    zh|zh_CN|zh-CN|chinese|中文) LANG_CODE=zh ;;
    en|en_US|en-US|english) LANG_CODE=en ;;
    ja|ja_JP|ja-JP|japanese|日本語) LANG_CODE=ja ;;
    es|es_ES|es-ES|es-419|spanish|español) LANG_CODE=es ;;
    pt|pt_BR|pt-BR|portuguese|português) LANG_CODE=pt ;;
    ko|ko_KR|ko-KR|korean|한국어) LANG_CODE=ko ;;
    de|de_DE|de-DE|german|deutsch) LANG_CODE=de ;;
    *) LANG_CODE="" ;;
esac

if [ "$(id -u)" -ne 0 ] && [ -n "$LANG_CODE" ] && command -v sudo >/dev/null 2>&1; then
    if sudo -n /usr/local/bin/lang-switch "$LANG_CODE" 2>/dev/null; then
        exit 0
    fi
fi

# 保存语言偏好到 ubuntu 用户的 home 目录
LANG_FILE="/home/ubuntu/.config/gnome-language"
mkdir -p "$(dirname "$LANG_FILE")"

set_locale_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi

    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

apply_locale() {
    local lang="$1"
    local language="$2"

    set_locale_key /etc/environment LANG "$lang"
    set_locale_key /etc/environment LANGUAGE "$language"
    set_locale_key /etc/environment LC_ALL "$lang"

    set_locale_key /etc/default/locale LANG "$lang"
    set_locale_key /etc/default/locale LANGUAGE "$language"
    set_locale_key /etc/default/locale LC_ALL "$lang"

    if [ "$(id -u)" -eq 0 ]; then
        update-locale LANG="$lang" LC_ALL="$lang" LANGUAGE="$language" 2>/dev/null || true
    fi
}

set_gnome_locale() {
    local lang="$1"

    if [ "$(id -u)" -eq 0 ]; then
        mkdir -p /run/user/1000/dconf
        chown -R ubuntu:ubuntu /run/user/1000/dconf 2>/dev/null || true
        sudo -u ubuntu DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            gsettings set org.gnome.system.locale locale "$lang" 2>/dev/null || true
    else
        gsettings set org.gnome.system.locale locale "$lang" 2>/dev/null || true
    fi
}

locale_available() {
    local lang="$1"
    local normalized
    normalized=$(printf '%s\n' "$lang" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')

    locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/' | grep -qx "$normalized" && return 0
    return 1
}

ensure_locale_available() {
    local lang="$1"
    local base="${lang%%.*}"

    locale_available "$lang" && return 0

    if [ "$(id -u)" -eq 0 ] && [ -f "/usr/share/i18n/locales/$base" ] && command -v locale-gen >/dev/null 2>&1; then
        sed -i "s/^# *${base}.UTF-8 UTF-8/${base}.UTF-8 UTF-8/" /etc/locale.gen 2>/dev/null || true
        locale-gen "$lang" >/dev/null 2>&1 || true
    fi

    locale_available "$lang"
}

switch_language() {
    local requested_lang="$1"
    local language_chain="$2"
    local label="$3"
    local lang="$requested_lang"

    if ! ensure_locale_available "$lang"; then
        echo "Requested locale $requested_lang is not installed; falling back to English (en_US.UTF-8)." >&2
        lang="en_US.UTF-8"
        language_chain="en_US:en"
        label="English"
    fi

    echo "$lang" > "$LANG_FILE"
    if [ "$(id -u)" -eq 0 ]; then
        chown ubuntu:ubuntu "$LANG_FILE"
    fi

    apply_locale "$lang" "$language_chain"
    set_gnome_locale "$lang"

    echo "已切换到 $label ($lang)"
    echo "Restarting desktop..."
}

case "$1" in
    zh|zh_CN|zh-CN|chinese|中文)
        switch_language "zh_CN.UTF-8" "zh_CN:zh" "中文"
        ;;
    en|en_US|en-US|english)
        switch_language "en_US.UTF-8" "en_US:en" "English"
        ;;
    ja|ja_JP|ja-JP|japanese|日本語)
        switch_language "ja_JP.UTF-8" "ja_JP:ja" "日本語"
        ;;
    es|es_ES|es-ES|es-419|spanish|español)
        switch_language "es_ES.UTF-8" "es_ES:es" "Español"
        ;;
    pt|pt_BR|pt-BR|portuguese|português)
        switch_language "pt_BR.UTF-8" "pt_BR:pt" "Português"
        ;;
    ko|ko_KR|ko-KR|korean|한국어)
        switch_language "ko_KR.UTF-8" "ko_KR:ko" "한국어"
        ;;
    de|de_DE|de-DE|german|deutsch)
        switch_language "de_DE.UTF-8" "de_DE:de" "Deutsch"
        ;;
    *)
        echo "用法: lang-switch {zh|en|ja|es|pt|ko|de}"
        echo "  zh    - 中文 (Chinese)"
        echo "  en    - English"
        echo "  ja    - 日本語 (Japanese)"
        echo "  es    - Español (Spanish)"
        echo "  pt    - Português (Portuguese Brazil)"
        echo "  ko    - 한국어 (Korean)"
        echo "  de    - Deutsch (German)"
        exit 1
        ;;
esac

# 重启 supervisor 的 desktop 进程以应用新语言
if command -v supervisorctl >/dev/null 2>&1; then
    nohup setsid sh -c 'sleep 0.5; supervisorctl restart desktop >/dev/null 2>&1' \
        >/dev/null 2>&1 &
fi
