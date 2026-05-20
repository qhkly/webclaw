#!/bin/bash
# Safely update GNOME Flashback desktop menu state without HUP-killing gnome-panel.

set -u

DESKTOP_USER="${WEBCLAW_DESKTOP_USER:-ubuntu}"
DISPLAY_VALUE="${DISPLAY:-}"
XDG_RUNTIME_DIR_VALUE="${XDG_RUNTIME_DIR:-}"
THEME_OVERRIDE=""
ACTION="menu-only"
LOG_FILE="/tmp/webclaw-gnome-panel-safe-refresh.log"

usage() {
    cat <<'EOF'
Usage: webclaw-desktop-panel-safe-refresh [--menu-only|--ensure-panel|--restart-panel|--status] [--theme light|dark]

  --menu-only      Update desktop database and ensure the panel is running (default).
  --ensure-panel   Start gnome-panel only if it is missing.
  --restart-panel  Restart via "gnome-panel --replace"; never send HUP.
  --status         Print panel process status.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --menu-only|menu-only)
            ACTION="menu-only"
            ;;
        --ensure-panel|ensure-panel)
            ACTION="ensure-panel"
            ;;
        --restart-panel|restart-panel)
            ACTION="restart-panel"
            ;;
        --status|status)
            ACTION="status"
            ;;
        --theme)
            shift
            THEME_OVERRIDE="${1:-}"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

detect_display() {
    if [ -n "$DISPLAY_VALUE" ]; then
        echo "$DISPLAY_VALUE"
        return
    fi

    local socket
    socket=$(find /tmp/.X11-unix -maxdepth 1 -type s -name 'X*' 2>/dev/null | sort | head -n 1 || true)
    if [ -n "$socket" ]; then
        echo ":${socket##*/X}"
        return
    fi

    echo ":1"
}

desktop_uid() {
    id -u "$DESKTOP_USER" 2>/dev/null || echo "$(id -u)"
}

desktop_home() {
    getent passwd "$DESKTOP_USER" 2>/dev/null | cut -d: -f6
}

ensure_runtime_dir() {
    local uid runtime_dir
    uid=$(desktop_uid)
    runtime_dir="${XDG_RUNTIME_DIR_VALUE:-/run/user/$uid}"
    mkdir -p "$runtime_dir" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && id "$DESKTOP_USER" >/dev/null 2>&1; then
        chown "$DESKTOP_USER:$DESKTOP_USER" "$runtime_dir" 2>/dev/null || true
    fi
    chmod 700 "$runtime_dir" 2>/dev/null || true
    echo "$runtime_dir"
}

resolved_theme() {
    if [ "$THEME_OVERRIDE" = "dark" ]; then
        echo "Adwaita-dark"
        return
    fi
    if [ "$THEME_OVERRIDE" = "light" ] || [ "$THEME_OVERRIDE" = "bright" ]; then
        echo "Adwaita"
        return
    fi
    if [ -f "/home/$DESKTOP_USER/.config/webclaw/theme" ] \
        && grep -qi '^dark$' "/home/$DESKTOP_USER/.config/webclaw/theme"; then
        echo "Adwaita-dark"
        return
    fi
    echo "Adwaita"
}

run_as_desktop_user() {
    local home display runtime theme
    home=$(desktop_home)
    [ -n "$home" ] || home="$HOME"
    display=$(detect_display)
    runtime=$(ensure_runtime_dir)
    theme=$(resolved_theme)

    if [ "$(id -u)" -eq 0 ] && id "$DESKTOP_USER" >/dev/null 2>&1; then
        runuser -u "$DESKTOP_USER" -- env \
            HOME="$home" \
            DISPLAY="$display" \
            XDG_RUNTIME_DIR="$runtime" \
            XDG_MENU_PREFIX="gnome-flashback-" \
            GTK_THEME="$theme" \
            "$@"
    else
        env \
            HOME="$home" \
            DISPLAY="$display" \
            XDG_RUNTIME_DIR="$runtime" \
            XDG_MENU_PREFIX="gnome-flashback-" \
            GTK_THEME="$theme" \
            "$@"
    fi
}

update_desktop_database() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database /usr/share/applications 2>/dev/null || true
    fi
}

panel_is_running() {
    run_as_desktop_user pgrep -x gnome-panel >/dev/null 2>&1
}

start_panel() {
    local theme
    theme=$(resolved_theme)
    run_as_desktop_user sh -c "nohup env GTK_THEME='$theme' gnome-panel --replace >'$LOG_FILE' 2>&1 &"
}

case "$ACTION" in
    status)
        run_as_desktop_user pgrep -a -x gnome-panel || true
        ;;
    ensure-panel)
        if panel_is_running; then
            run_as_desktop_user pgrep -a -x gnome-panel || true
        else
            start_panel
            sleep 1
            run_as_desktop_user pgrep -a -x gnome-panel || {
                tail -40 "$LOG_FILE" 2>/dev/null || true
                exit 1
            }
        fi
        ;;
    restart-panel)
        start_panel
        sleep 1
        run_as_desktop_user pgrep -a -x gnome-panel || {
            tail -40 "$LOG_FILE" 2>/dev/null || true
            exit 1
        }
        ;;
    menu-only)
        update_desktop_database
        if ! panel_is_running; then
            start_panel
            sleep 1
        fi
        run_as_desktop_user pgrep -a -x gnome-panel || true
        ;;
esac
