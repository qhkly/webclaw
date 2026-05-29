#!/bin/bash
set -e

MODE="${MODE:-desktop}"

# ─── Docker socket GID fix ───────────────────────────────────────────
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "$DOCKER_GID" = "0" ]; then
        # 宿主 socket 归属 root:root（GID 0），常见于 macOS Docker Desktop 透传。
        # 没法把容器内 docker 组改成 GID 0（会与 root 组冲突），
        # 改方向：把 socket 的组所有权交给容器内已存在的 docker 组。
        chgrp docker /var/run/docker.sock 2>/dev/null || true
        chmod 660 /var/run/docker.sock 2>/dev/null || true
    else
        # 正常 Linux 宿主：把容器内 docker 组 GID 对齐到宿主 socket 的 GID。
        groupmod -g "$DOCKER_GID" docker 2>/dev/null || true
    fi
    usermod -aG docker ubuntu 2>/dev/null || true
fi

# ─── Docker-in-Docker (DinD) mode ────────────────────────────────────
# dockerd 现在由 supervisor 自动管理，根据 DOCKER_SOCK_MODE 环境变量启动
DOCKER_SOCK_MODE="${DOCKER_SOCK_MODE:-host}"
export DOCKER_SOCK_MODE
usermod -aG docker ubuntu 2>/dev/null || true

# ─── Create project directory and standard user directories ──────────
mkdir -p /home/ubuntu/projects
# 标准用户目录直接挂在 /home/ubuntu/ 下（XDG 风格），方便桌面 Home 图标自然看到。
# 主机端命名透传：macOS 挂 ~/Movies → /home/ubuntu/Movies，Linux/Windows 挂 ~/Videos → /home/ubuntu/Videos。
# 因此 Movies/Videos 两个目录名都可能出现，由挂载决定；预创建只覆盖 5 个稳定目录。
install -d -o ubuntu -g ubuntu /home/ubuntu/Desktop /home/ubuntu/Documents /home/ubuntu/Downloads /home/ubuntu/Pictures /home/ubuntu/Music
mkdir -p /home/ubuntu/.local/share/vibe-kanban

# ─── Initialize common skills directory ───────────────────────────────
if [ -f /opt/init-skills.sh ]; then
    echo "[startup] Initializing common skills directory..."
    /opt/init-skills.sh
fi

# 后台递归修复 /home/ubuntu 权限，避免大目录阻塞启动。
# 保留用户本地目录挂载点的原始 owner，避免把宿主机目录重置成 ubuntu。
# 容器侧不知道当前是 macOS 还是 Linux/Windows 主机连过来，
# 因此 Movies 与 Videos 两个视频目录名都需要 skip。
readonly LOCAL_PROJECT_DIRS=(
    "/home/ubuntu/Desktop"
    "/home/ubuntu/Documents"
    "/home/ubuntu/Downloads"
    "/home/ubuntu/Pictures"
    "/home/ubuntu/Videos"
    "/home/ubuntu/Movies"
    "/home/ubuntu/Music"
    "/home/ubuntu/projects/docker"
    "/home/ubuntu/projects/docker_build"
)

background_chown_home() {
    local find_args=("/home/ubuntu")
    local skip_dir

    for skip_dir in "${LOCAL_PROJECT_DIRS[@]}"; do
        find_args+=("(" "-path" "$skip_dir" "-o" "-path" "$skip_dir/*" ")" "-prune" "-o")
    done

    find "${find_args[@]}" -exec chown ubuntu:ubuntu {} + >/dev/null 2>&1 || true
}

echo "[startup] Starting background chown for /home/ubuntu (excluding local project mounts)..."
(background_chown_home) &

mkdir -p /home/ubuntu/recordings
chown ubuntu:ubuntu /home/ubuntu/recordings

# Ensure .config is writable by ubuntu (chrome-data volume mounts here)
mkdir -p /home/ubuntu/.config
chown ubuntu:ubuntu /home/ubuntu/.config

# ─── SSH directory (persistent keys and config) ───────────────────────
mkdir -p /home/ubuntu/.ssh
chown ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh

# Fix permissions for existing SSH files
find /home/ubuntu/.ssh -type f \( -name 'id_rsa' -o -name 'id_ed25519' -o -name 'id_ecdsa' \) -exec chmod 600 {} \; 2>/dev/null || true
find /home/ubuntu/.ssh -type f -name '*.pub' -exec chmod 644 {} \; 2>/dev/null || true
chmod 600 /home/ubuntu/.ssh/config 2>/dev/null || true
chmod 600 /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true

# # ─── DNA directory (self-evolution source) ───────────────────────────
# # DNA_REPO_URL: 机器人的基因来源，支持 fork 仓库，默认指向原始库
# DNA_REPO_URL="${DNA_REPO_URL:-https://github.com/land007/webcode}"
# mkdir -p /home/ubuntu/dna
# if [ -z "$(ls -A /home/ubuntu/dna 2>/dev/null)" ]; then
#     echo "[startup] DNA directory is empty, cloning from ${DNA_REPO_URL} ..."
#     git clone "$DNA_REPO_URL" /home/ubuntu/dna \
#         && echo "[startup] DNA cloned successfully" \
#         || echo "[startup] WARNING: Failed to clone DNA repository, robot will retry manually"
# fi
# chown -R ubuntu:ubuntu /home/ubuntu/dna

# ─── Persist bash history ────────────────────────────────────────────
HIST_DIR="/home/ubuntu/.local/share/shell"
mkdir -p "$HIST_DIR"
if [ ! -f "$HIST_DIR/.bash_history" ]; then
    touch "$HIST_DIR/.bash_history"
fi
ln -sf "$HIST_DIR/.bash_history" /home/ubuntu/.bash_history
chown -R ubuntu:ubuntu "$HIST_DIR"

# ─── Persist gitconfig ──────────────────────────────────────────────
if [ -f /home/ubuntu/.gitconfig-vol ]; then
    ln -sf /home/ubuntu/.gitconfig-vol /home/ubuntu/.gitconfig
fi
# Set git user from environment variables (if provided)
if [ -n "$GIT_USER_NAME" ]; then
    sudo -u ubuntu git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    sudo -u ubuntu git config --global user.email "$GIT_USER_EMAIL"
fi

# ─── code-server data directory ─────────────────────────────────────
mkdir -p /home/ubuntu/.code-server/User
# Generate languagepacks.json on every start (CLI install doesn't create it, and
# rebuilt images may add more language packs while reusing an old user volume).
/opt/create-languagepacks.sh /home/ubuntu/.code-server /opt/code-server-extensions
# Write default argv.json (locale) if not already set by user
if [ ! -f /home/ubuntu/.code-server/User/argv.json ]; then
    echo '{"locale":"zh-cn"}' > /home/ubuntu/.code-server/User/argv.json
fi
chown -R ubuntu:ubuntu /home/ubuntu/.code-server

# ─── OpenClaw data directory ───────────────────────────────────────
mkdir -p /home/ubuntu/.openclaw
chown -R ubuntu:ubuntu /home/ubuntu/.openclaw

# ─── OpenClaw config ────────────────────────────────────────────────
# OpenClaw reads openclaw.json (not openclaw.json5).
# We need to ensure three things regardless of whether onboard has run:
#   1. gateway.port = 10003  (matches supervisor --port flag, fixes CLI tools)
#   2. gateway.controlUi.dangerouslyDisableDeviceAuth = true
#      (disable browser device-pairing; token auth is sufficient in a container)
#   3. gateway.controlUi.allowInsecureAuth = true  (allow HTTP, not just HTTPS)
#   4. browser.noSandbox = true and tools.alsoAllow includes browser
#      (OpenClaw browser control needs Chromium no-sandbox in the container and
#       the browser tool must be exposed in addition to the coding profile)
OPENCLAW_JSON="/home/ubuntu/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_JSON" ]; then
    # Patch existing config (written by openclaw onboard)
    PATCHED=$(jq '
        .gateway.port = 10003 |
        .gateway.controlUi.dangerouslyDisableDeviceAuth = true |
        .gateway.controlUi.allowInsecureAuth = true |
        .browser.noSandbox = true |
        .tools.profile = (.tools.profile // "coding") |
        .tools.alsoAllow = (((.tools.alsoAllow // []) + ["browser"]) | unique)
    ' "$OPENCLAW_JSON") && echo "$PATCHED" > "$OPENCLAW_JSON" \
        && echo "[startup] OpenClaw config patched (port=10003, browser enabled in coding profile)" \
        || echo "[startup] WARNING: Failed to patch OpenClaw config"
else
    # First-ever run before onboard: write a minimal bootstrap config
    cat > "$OPENCLAW_JSON" <<'EOF'
{
  "browser": {
    "noSandbox": true
  },
  "tools": {
    "profile": "coding",
    "alsoAllow": ["browser"]
  },
  "gateway": {
    "port": 10003,
    "mode": "local",
    "bind": "loopback",
    "auth": { "mode": "token" },
    "controlUi": {
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
EOF
    echo "[startup] OpenClaw bootstrap config written"
fi
chown ubuntu:ubuntu "$OPENCLAW_JSON"

# ─── Load persisted runtime config (overrides docker run env vars) ───
WEBCODE_CFG=/home/ubuntu/.webclaw/config.json
if [ -f "$WEBCODE_CFG" ]; then
  echo "[startup] Loading persisted config from $WEBCODE_CFG"
  for KEY in AUTH_USER AUTH_PASSWORD VNC_PASSWORD OPENCLAW_GATEWAY_TOKEN \
             GIT_USER_NAME GIT_USER_EMAIL CF_TUNNEL_TOKEN \
             ENABLE_KANBAN ENABLE_OPENCLAW ENABLE_CLAUDECODEUI; do
    VAL=$(python3 -c "
import json,sys
try:
  d=json.load(open('$WEBCODE_CFG'))
  print(d.get('$KEY',''),end='')
except: pass
" 2>/dev/null)
    [ -n "$VAL" ] && export "$KEY=$VAL"
  done
fi

# ─── Dashboard auth setup (Basic Auth for all web services) ──────────
export AUTH_USER="${AUTH_USER:-admin}"
export AUTH_PASSWORD="${AUTH_PASSWORD:-changeme}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-sk-webcode}"
export VNC_PASSWORD="${VNC_PASSWORD:-changeme}"
echo "[startup] Basic Auth enabled — user: $AUTH_USER"

# ─── Cloudflare Tunnel (optional) ─────────────────────────────────
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "[startup] Cloudflare Tunnel enabled"
    export CF_TUNNEL_TOKEN
else
    echo "[startup] Cloudflare Tunnel disabled (CF_TUNNEL_TOKEN not set)"
    export CF_TUNNEL_TOKEN="unused"
    sed -i 's/autostart=true/autostart=false/' /etc/supervisor/conf.d/supervisor-cloudflared.conf
fi

# ─── Background tool upgrades (non-blocking) ─────────────────────────
# Upgrade claude-code for ubuntu user via nvm
su -l ubuntu -c \
    'source ~/.nvm/nvm.sh 2>/dev/null && npm install -g @anthropic-ai/claude-code@latest >> /tmp/claude-upgrade.log 2>&1' &

# ─── Enable ClaudeCodeUI Platform mode (no authentication required) ───
if [ -f /opt/enable-claudecodeui-platform-mode.sh ]; then
    bash /opt/enable-claudecodeui-platform-mode.sh
fi

# ─── Export service enable flags for supervisor ───────────────────────
export WEBCODE_HAS_VIBE_KANBAN="${WEBCODE_HAS_VIBE_KANBAN:-false}"
export WEBCODE_HAS_CLAUDECODEUI="${WEBCODE_HAS_CLAUDECODEUI:-false}"
export ENABLE_KANBAN="${ENABLE_KANBAN:-$WEBCODE_HAS_VIBE_KANBAN}"
export ENABLE_OPENCLAW="${ENABLE_OPENCLAW:-true}"
export ENABLE_CLAUDECODEUI="${ENABLE_CLAUDECODEUI:-$WEBCODE_HAS_CLAUDECODEUI}"
export ENABLE_FUSE="${ENABLE_FUSE:-false}"

# ─── Desktop icons behavior ────────────────────────────────────────────
# CLEAN_DESKTOP: 控制桌面图标显示行为
#   - true（默认）: 未安装应用仅在 Applications 菜单中显示，不在桌面显示
#   - false: 保持传统行为，所有应用（包括未安装）都在桌面显示
export CLEAN_DESKTOP="${CLEAN_DESKTOP:-true}"

# ─── Ubuntu user password setup ────────────────────────────────────
# 设置 ubuntu 用户密码（如果提供了 PASSWORD 环境变量）
if [ -n "$PASSWORD" ]; then
    echo "[startup] Setting ubuntu user password"
    echo "ubuntu:$PASSWORD" | chpasswd
    # 移除 NOPASSWD，改为使用密码验证
    if grep -q "NOPASSWD" /etc/sudoers; then
        sed -i '/NOPASSWD/d' /etc/sudoers
        echo "[startup] Removed NOPASSWD from sudoers, password now required"
    fi
fi

# ─── Mode selection ─────────────────────────────────────────────────
if [ "$MODE" = "lite" ]; then
    echo "[startup] Lite mode: starting code-server + OpenClaw only (no VNC desktop)"
    exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord-lite.conf
else
    echo "[startup] Desktop mode: starting full GNOME desktop + all services"

    # VNC password setup
    mkdir -p /home/ubuntu/.vnc
    # Prefer the documented/runtime-managed VNC_PASSWORD variable.
    # Keep PASSWORD as a backward-compatible fallback for older compose files.
    VNC_PASS="${VNC_PASSWORD:-${PASSWORD:-$(openssl rand -base64 8)}}"
    if [ -z "$VNC_PASSWORD" ] && [ -z "$PASSWORD" ]; then
        echo "[startup] Generated VNC password: $VNC_PASS"
    fi

    # Find vncpasswd binary (could be vncpasswd or tigervncpasswd)
    VNCPASSWD_BIN=""
    for cmd in vncpasswd tigervncpasswd /usr/bin/vncpasswd /usr/bin/tigervncpasswd; do
        if command -v "$cmd" &>/dev/null || [ -x "$cmd" ]; then
            VNCPASSWD_BIN="$cmd"
            break
        fi
    done

    if [ -n "$VNCPASSWD_BIN" ]; then
        echo "$VNC_PASS" | "$VNCPASSWD_BIN" -f > /home/ubuntu/.vnc/passwd
    else
        echo "[startup] WARNING: vncpasswd not found, writing password via Python"
        python3 /opt/vnc-setpass.py "$VNC_PASS" /home/ubuntu/.vnc/passwd
    fi

    chmod 600 /home/ubuntu/.vnc/passwd
    chown -R ubuntu:ubuntu /home/ubuntu/.vnc

    # XDG_RUNTIME_DIR for ubuntu user (fcitx5, dbus, dconf need it)
    mkdir -p /run/user/1000
    chown ubuntu:ubuntu /run/user/1000
    chmod 700 /run/user/1000
    mkdir -p /run/user/1000/dconf
    chown -R ubuntu:ubuntu /run/user/1000/dconf
    chmod 700 /run/user/1000/dconf

    # PulseAudio socket directory
    mkdir -p /run/user/1000/pulse
    chown ubuntu:ubuntu /run/user/1000/pulse

    # D-Bus system bus (needed by PulseAudio for null-sink module)
    mkdir -p /run/dbus
    if [ -f /run/dbus/pid ] && [ ! -S /run/dbus/system_bus_socket ]; then
        rm -f /run/dbus/pid
        echo "[startup] Removed stale /run/dbus/pid"
    fi
    if [ ! -S /run/dbus/system_bus_socket ]; then
        dbus-daemon --system --fork
        echo "[startup] D-Bus system bus started"
    fi

    # fcitx5 configuration
    FCITX_DIR=/home/ubuntu/.config/fcitx5
    mkdir -p "$FCITX_DIR"

    # fcitx5 global config - hotkey to toggle input methods.
    cat > "$FCITX_DIR/config" <<'FCITX_EOF'
[Hotkey]
EnumerateWithTriggerKeys=True
EnumerateForwardKeys=
EnumerateBackwardKeys=
EnumerateSkipFirst=False

[Hotkey/TriggerKeys]
0=Shift_L

[Hotkey/AltTriggerKeys]
0=Shift+Shift_L

[Hotkey/EnumerateGroupForwardKeys]
0=Super+space

[Hotkey/EnumerateGroupBackwardKeys]
0=Shift+Super+space

[Hotkey/ActivateKeys]
0=Hangul_Hanja

[Hotkey/DeactivateKeys]
0=Hangul_Romaja

[Hotkey/PrevPage]
0=Up

[Hotkey/NextPage]
0=Down

[Hotkey/PrevCandidate]
0=Shift+Tab

[Hotkey/NextCandidate]
0=Tab

[Hotkey/TogglePreedit]
0=Control+Alt+P

[Behavior]
ActiveByDefault=False
ShareInputState=No
PreeditEnabledByDefault=True
ShowInputMethodInformation=True
showInputMethodInformationWhenFocusIn=False
CompactInputMethodInformation=True
ShowFirstInputMethodInformation=True
DefaultPageSize=5
OverrideXkbOption=False
PreloadInputMethod=True
FCITX_EOF

    # fcitx5 profile - multi-language input methods.
    if [ ! -f "$FCITX_DIR/profile" ]; then
        ITEMS='[Groups/0/Items/0]
Name=keyboard-us
Layout=
'
        ITEM_INDEX=1

        # Smart input engines (Chinese, Japanese, Korean). Keep Chinese first.
        for im in pinyin mozc hangul; do
            if dpkg -l "fcitx5-$im" 2>/dev/null | grep -q '^ii' || \
               { [ "$im" = "pinyin" ] && dpkg -l fcitx5-chinese-addons 2>/dev/null | grep -q '^ii'; }; then
                ITEMS="${ITEMS}
[Groups/0/Items/${ITEM_INDEX}]
Name=${im}
Layout=
"
                ITEM_INDEX=$((ITEM_INDEX + 1))
            fi
        done

        if dpkg -l fcitx5-chinese-addons 2>/dev/null | grep -q '^ii'; then
            DEFAULT_IM=pinyin
        elif dpkg -l fcitx5-mozc 2>/dev/null | grep -q '^ii'; then
            DEFAULT_IM=mozc
        elif dpkg -l fcitx5-hangul 2>/dev/null | grep -q '^ii'; then
            DEFAULT_IM=hangul
        else
            DEFAULT_IM=keyboard-us
        fi

        cat > "$FCITX_DIR/profile" <<FCITX_PROFILE_EOF
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=${DEFAULT_IM}

${ITEMS}
[GroupOrder]
0=Default
FCITX_PROFILE_EOF
    fi

    chown -R ubuntu:ubuntu /home/ubuntu/.config

    # Reset gnome-panel layout in user dconf so it reads from layout file.
    # This handles stale layout data persisted in Docker volumes.
    sudo -u ubuntu dbus-run-session -- dconf reset -f /org/gnome/gnome-panel/ 2>/dev/null || true

    # 兜底：旧的 Docker 卷可能持久化了 show-icons=false，导致镜像里的 dconf 默认值被覆盖。
    # 写一次保证桌面图标始终启用。
    sudo -u ubuntu dbus-run-session -- dconf write /org/gnome/gnome-flashback/desktop/show-icons true 2>/dev/null || true

    # Clean stale X locks (previously in vnc-wrapper.sh)
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

    # Clean stale Chromium/Chrome locks (including hostname-specific profiles)
    rm -f /home/ubuntu/.config/chromium/SingletonLock
    rm -f /home/ubuntu/.config/google-chrome/SingletonLock
    rm -f /home/ubuntu/.config/chromium-*/SingletonLock 2>/dev/null || true
    rm -f /home/ubuntu/.config/google-chrome-*/SingletonLock 2>/dev/null || true

    # Copy xsession (supervisor desktop process reads ~/.xsession)
    cp /opt/xsession /home/ubuntu/.xsession
    chmod +x /home/ubuntu/.xsession
    chown ubuntu:ubuntu /home/ubuntu/.xsession

    # Desktop shortcuts: keep only the baseline desktop clean on first run.
    # After this marker exists, users can freely add/remove desktop icons.
    # Use /run/ for runtime state (cleared on container restart, not persisted across hosts)
    mkdir -p /run/webclaw
    chmod 755 /run/webclaw
    DESKTOP_DEFAULTS_MARKER="/run/webclaw/desktop-defaults-v2"
    mkdir -p /home/ubuntu/Desktop /home/ubuntu/.local/share/desktop-icons/hidden /home/ubuntu/.config/webclaw
    if [ ! -f "$DESKTOP_DEFAULTS_MARKER" ]; then
        find /home/ubuntu/Desktop -maxdepth 1 -type f -name '*.desktop' \
            ! -name 'chrome.desktop' \
            ! -name 'appearance.desktop' \
            ! -name 'language.desktop' \
            ! -name 'v2rayN.desktop' \
            ! -name 'openclaw.desktop' \
            ! -name 'terminal.desktop' \
            ! -name 'claude-code.desktop' \
            -exec mv -f {} /home/ubuntu/.local/share/desktop-icons/hidden/ \; 2>/dev/null || true
        for shortcut in v2rayN openclaw claude-code codex-cli webcode-ai-studio; do
            cp "/opt/desktop-shortcuts/${shortcut}.desktop" /home/ubuntu/Desktop/ 2>/dev/null || true
        done
        touch "$DESKTOP_DEFAULTS_MARKER"
    fi
    rm -f /home/ubuntu/Desktop/lang-chinese.desktop /home/ubuntu/Desktop/lang-english.desktop
    rm -f /home/ubuntu/Desktop/*uninstall.desktop
    chmod +x /home/ubuntu/Desktop/*.desktop 2>/dev/null || true
    chown -R ubuntu:ubuntu /home/ubuntu/Desktop /home/ubuntu/.local/share/desktop-icons /home/ubuntu/.config/webclaw

    # 更新桌面图标状态（未安装应用显示下载标记）
    # 必须以 ubuntu 身份跑：xsession 起来时 gnome-flashback 的 inotify 监听属于 ubuntu，
    # 用 root 写文件时 owner/mtime 时序会让首次渲染拿到旧缓存（→ 启动后看不到 ⬇）。
    if [ -x /usr/local/bin/update-desktop-icons ]; then
        sudo -u ubuntu /usr/local/bin/update-desktop-icons || true
    fi

    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi
# v2.1.40
