# ─────────────────────────────────────────────────────────────
#  Overlay layer: adds desktop components and config files
#  on top of the base image
# ─────────────────────────────────────────────────────────────
ARG WEBCLAW_BASE_VERSION=latest
ARG WEBCLAW_BASE_IMAGE=ghcr.io/land007/webclaw_base
FROM ${WEBCLAW_BASE_IMAGE}:${WEBCLAW_BASE_VERSION}

# Build-time flags (inherited from base, but can override)
ARG INSTALL_DESKTOP=true

# ─── 6. GNOME Flashback desktop (VNC-compatible, no GL needed) ──────
# Note: intentionally NO --no-install-recommends here so gnome desktop
# components pull in all recommended packages for a complete desktop.
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y \
            gnome-session-flashback gnome-terminal nautilus \
            metacity dbus-x11 gnome-panel gnome-settings-daemon \
            adwaita-icon-theme gnome-themes-extra \
            xfonts-base fonts-dejavu-core fonts-liberation2 fontconfig \
            fonts-hack \
            dconf-cli at-spi2-core \
            eog evince gnome-screenshot gedit xdg-user-dirs \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 6b. Language packs for desktop localization ─────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            language-pack-zh-hans language-pack-zh-hans-base \
            language-pack-gnome-zh-hans language-pack-gnome-zh-hans-base \
            language-pack-en language-pack-en-base \
            language-pack-gnome-en language-pack-gnome-en-base \
            language-pack-ja language-pack-ja-base \
            language-pack-gnome-ja language-pack-gnome-ja-base \
            language-pack-es language-pack-es-base \
            language-pack-gnome-es language-pack-gnome-es-base \
            language-pack-pt language-pack-pt-base \
            language-pack-gnome-pt language-pack-gnome-pt-base \
            language-pack-ko language-pack-ko-base \
            language-pack-gnome-ko language-pack-gnome-ko-base \
            language-pack-de language-pack-de-base \
            language-pack-gnome-de language-pack-gnome-de-base \
        && locale-gen en_US.UTF-8 zh_CN.UTF-8 ja_JP.UTF-8 es_ES.UTF-8 pt_BR.UTF-8 ko_KR.UTF-8 de_DE.UTF-8 \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# Ubuntu 24.04 stores language-pack translations under locale-langpack,
# while some desktop applications only search /usr/share/locale.
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        for pair in zh_CN:zh_CN zh_TW:zh_TW en_US:en_US ja_JP:ja es_ES:es pt_BR:pt_BR ko_KR:ko de_DE:de; do \
            target="${pair%%:*}"; source="${pair##*:}"; \
            if [ -d "/usr/share/locale-langpack/$source" ] && [ ! -e "/usr/share/locale/$target" ]; then \
                ln -sf "/usr/share/locale-langpack/$source" "/usr/share/locale/$target"; \
            fi; \
        done; \
    fi

# ─── 6b. GNOME / Terminal font defaults + panel layout fix + flashback 桌面图标默认开 ───
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        mkdir -p /etc/dconf/profile /etc/dconf/db/local.d \
        && printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user \
        && printf '[org/gnome/desktop/interface]\nmonospace-font-name='"'"'Hack 11'"'"'\n' \
           > /etc/dconf/db/local.d/00-terminal-font \
        && printf '[org/gnome/gnome-flashback/desktop]\nshow-icons=true\n' \
           > /etc/dconf/db/local.d/01-flashback-desktop-icons \
        && dconf update \
        && cp /usr/share/gnome-panel/layouts/default.layout \
           /usr/share/gnome-panel/layouts/gnome-flashback.layout \
        && cp /usr/share/gnome-panel/layouts/default.layout \
           /usr/share/gnome-panel/layouts/ubuntu.layout; \
    fi

# ─── 6c. hsetroot for dynamic background color switching ───────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends hsetroot \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 6d. Theme switch script (light/dark mode) ─────────────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        if [ -f scripts/theme-switch.sh ]; then \
            cp scripts/theme-switch.sh /usr/local/bin/theme-switch \
            && chmod +x /usr/local/bin/theme-switch \
            && printf '\n# Theme switch aliases\nalias light-mode="/usr/local/bin/theme-switch light"\nalias dark-mode="/usr/local/bin/theme-switch dark"\n' >> /home/ubuntu/.bashrc; \
        fi; \
    fi

# ─── 6e. Language switch script (Chinese/English) ───────────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        if [ -f scripts/lang-switch.sh ]; then \
            cp scripts/lang-switch.sh /usr/local/bin/lang-switch \
            && chmod +x /usr/local/bin/lang-switch \
            && printf '\n# Language switch aliases\nalias chinese="/usr/local/bin/lang-switch zh"\nalias english="/usr/local/bin/lang-switch en"\n' >> /home/ubuntu/.bashrc; \
        fi; \
    fi

# ─── 7. VNC + noVNC ─────────────────────────────────────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y \
            tigervnc-standalone-server tigervnc-common tigervnc-tools \
            x11-xserver-utils \
            python3 python3-numpy \
        && git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git /opt/noVNC \
        && git clone --depth 1 --branch v0.12.0 https://github.com/novnc/websockify.git /opt/noVNC/utils/websockify \
        && ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 8. Input methods (fcitx5 + multi-language support) ────────────
# Include GTK4 frontend for modern apps such as Ghostty, plus XIM/GTK/Qt
# frontends through fcitx5-frontend-all.
#
# 输入法：
# - fcitx5-chinese-addons: 拼音等中文输入
# - fcitx5-mozc: Mozc（日语）
# - fcitx5-hangul: 韩语输入法
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y \
            fcitx5 fcitx5-frontend-all fcitx5-frontend-gtk4 fcitx5-config-qt \
            fcitx5-chinese-addons fcitx5-mozc fcitx5-hangul \
            fonts-noto-cjk fonts-noto-cjk-extra \
        && mkdir -p /usr/lib/gtk-4.0/4.0.0/immodules \
        && ln -sfn /usr/lib/$(gcc -print-multiarch)/gtk-4.0/4.0.0/immodules/libim-fcitx5.so \
            /usr/lib/gtk-4.0/4.0.0/immodules/libim-fcitx5.so \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 8e. VS Code apt repo + 共享 code-server 扩展目录(本体按需安装) ──────
# Microsoft VS Code 官方仓库支持 amd64/arm64,只添加仓库,不预装本体;
# /usr/bin/code 在用户首次点击桌面图标时由 webclaw-app-launcher (apt 模式) 安装。
# 扩展目录提前软链到共享的 code-server-extensions,装完即用。
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | \
            gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg && \
        echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] \
             https://packages.microsoft.com/repos/code stable main" \
             > /etc/apt/sources.list.d/vscode.list && \
        mkdir -p /home/ubuntu/.vscode && \
        ln -s /opt/code-server-extensions /home/ubuntu/.vscode/extensions && \
        chown -h ubuntu:ubuntu /home/ubuntu/.vscode/extensions && \
        chown -R ubuntu:ubuntu /home/ubuntu/.vscode; \
    fi

# ─── 8b. PulseAudio + Python WebSocket server deps ──────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            pulseaudio pulseaudio-utils \
            python3-websockets \
            python3-pip \
            python3-xlib \
            ffmpeg \
            libopus0 \
            gcc python3-dev \
        && apt-get clean && rm -rf /var/lib/apt/lists/* \
        && pip3 install --no-cache-dir --break-system-packages opuslib; \
    fi

# ─── 8c. SSH Server ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd && chmod 0755 /var/run/sshd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config \
    && echo "GatewayPorts no" >> /etc/ssh/sshd_config \
    && echo "X11Forwarding no" >> /etc/ssh/sshd_config

# ─── 8d. Snapd (用于 Telegram Desktop 等 snap 应用安装) ───────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        snapd \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s /var/lib/snapd/snap /snap || true

# ─── 9. Docker CLI + daemon (auto-detect arch) ───────────────────────
# docker-ce and containerd.io are needed for DinD mode; cli is the primary use case.
# Packages are installed but daemon is NOT started by default — startup.sh handles DinD.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && for i in 1 2 3; do \
        apt-get update && apt-get install -y --no-install-recommends \
            docker-ce-cli docker-ce containerd.io docker-compose-plugin && break || sleep 15; \
       done \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ─── 9b. Cloudflare Tunnel client (best-effort; network can be flaky in CI) ───
RUN set -eux; \
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null; \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" \
        > /etc/apt/sources.list.d/cloudflared.list; \
    install_ok=""; \
    for attempt in 1 2 3; do \
        if apt-get update \
            && apt-get install -y --no-install-recommends \
                -o Acquire::Retries=3 \
                -o Acquire::http::Timeout=30 \
                -o Acquire::https::Timeout=30 \
                cloudflared; then \
            install_ok=1; \
            break; \
        fi; \
        echo "[build] cloudflared install attempt ${attempt} failed; retrying..." >&2; \
        rm -rf /var/lib/apt/lists/*; \
        sleep $((attempt * 5)); \
    done; \
    if [ -z "$install_ok" ]; then \
        echo "[build] cloudflared could not be installed after retries; continuing without it. Cloudflare Tunnel will stay unavailable unless the package is added later." >&2; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ─── 10. Browser: amd64=Google Chrome, arm64=Chromium ────────────────
# /usr/local/bin/browser 由 scripts/browser.sh 统一提供(运行时探测 chrome/chromium),
# 避免之前 Dockerfile inline printf '$$HOSTNAME=$$(hostname)' 的 $$ 逃逸陷阱
# (RUN 指令里 docker 不把 $$ 转成 $,只有 docker compose YAML 才转,
#  导致脚本被 sh 当成 PID 拼接,Browser 图标长期点击无反应)。
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
            curl -LO https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
            && apt-get update && apt-get install -y ./google-chrome-stable_current_amd64.deb \
            && rm -f google-chrome-stable_current_amd64.deb; \
        else \
            apt-get update \
            && apt-get install -y --no-install-recommends debian-archive-keyring libgtk-3-0 \
            && mkdir -p /tmp/libgtk-3-0-dummy/DEBIAN \
            && printf '%s\n' \
                'Package: libgtk-3-0' \
                'Version: 3.24.41-1.1' \
                'Section: libs' \
                'Priority: optional' \
                'Architecture: arm64' \
                'Depends: libgtk-3-0t64' \
                'Maintainer: webclaw <noreply@example.com>' \
                'Description: Compatibility package for Debian Chromium on Ubuntu noble' \
                > /tmp/libgtk-3-0-dummy/DEBIAN/control \
            && dpkg-deb --build /tmp/libgtk-3-0-dummy /tmp/libgtk-3-0-dummy.deb \
            && dpkg -i /tmp/libgtk-3-0-dummy.deb \
            && rm -rf /tmp/libgtk-3-0-dummy /tmp/libgtk-3-0-dummy.deb \
            && printf '%s\n' \
                'deb [arch=arm64 signed-by=/usr/share/keyrings/debian-archive-bookworm-stable.gpg] http://deb.debian.org/debian bookworm main' \
                'deb [arch=arm64 signed-by=/usr/share/keyrings/debian-archive-bookworm-security-automatic.gpg] http://security.debian.org/debian-security bookworm-security main' \
                > /etc/apt/sources.list.d/debian-bookworm-chromium.list \
            && printf '%s\n' \
                'Package: *' \
                'Pin: release n=bookworm' \
                'Pin-Priority: 100' \
                '' \
                'Package: *' \
                'Pin: release n=bookworm-security' \
                'Pin-Priority: 100' \
                '' \
                'Package: chromium chromium-common chromium-sandbox' \
                'Pin: release n=bookworm-security' \
                'Pin-Priority: 990' \
                > /etc/apt/preferences.d/debian-chromium \
            && apt-get update \
            && apt-get install -y --no-install-recommends chromium chromium-common chromium-sandbox \
            && rm -f /etc/apt/sources.list.d/debian-bookworm-chromium.list /etc/apt/preferences.d/debian-chromium; \
        fi \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 11. User setup & docker group ──────────────────────────────────
RUN groupadd -f docker && usermod -aG docker ubuntu \
    && mkdir -p /home/ubuntu/projects /home/ubuntu/Desktop /home/ubuntu/Documents \
       /home/ubuntu/Downloads /home/ubuntu/Pictures /home/ubuntu/Music \
       /home/ubuntu/.local/share /home/ubuntu/.code-server \
    && touch /home/ubuntu/.hushlogin \
    && chown -R ubuntu:ubuntu /home/ubuntu

# ─── 11b. v2rayN (GUI proxy client) ─────────────────────────────────
# Latest Linux releases do not always publish .deb artifacts. Use the portable
# zip bundle so the image can continue tracking the newest stable v2rayN release.
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        ARCH=$(dpkg --print-architecture) \
        && case "$ARCH" in \
            amd64) V2RAYN_ARCH=64 ;; \
            arm64) V2RAYN_ARCH=arm64 ;; \
            *) echo "Unsupported v2rayN architecture: $ARCH" >&2; exit 1 ;; \
        esac \
        && apt-get update \
        && apt-get install -y --no-install-recommends unzip \
        && V2RAYN_ASSET="v2rayN-linux-${V2RAYN_ARCH}.zip" \
        && V2RAYN_RELEASE_JSON=/tmp/v2rayn-release.json \
        && curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: webclaw-docker-build' \
            https://api.github.com/repos/2dust/v2rayN/releases/latest \
            -o "$V2RAYN_RELEASE_JSON" \
        && V2RAYN_VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$V2RAYN_RELEASE_JSON") \
        && V2RAYN_URL=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); name=sys.argv[2]; matches=[a["browser_download_url"] for a in data.get("assets", []) if a.get("name") == name]; print(matches[0] if matches else "")' "$V2RAYN_RELEASE_JSON" "$V2RAYN_ASSET") \
        && test -n "$V2RAYN_VER" \
        && test -n "$V2RAYN_URL" \
        && echo "Installing v2rayN ${V2RAYN_VER} from ${V2RAYN_ASSET}" \
        && curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
            -H 'User-Agent: webclaw-docker-build' \
            "$V2RAYN_URL" \
            -o /tmp/v2rayn.zip \
        && rm -rf /opt/v2rayN /tmp/v2rayn-unpack \
        && mkdir -p /tmp/v2rayn-unpack \
        && unzip -q /tmp/v2rayn.zip -d /tmp/v2rayn-unpack \
        && mv "/tmp/v2rayn-unpack/v2rayN-linux-${V2RAYN_ARCH}" /opt/v2rayN \
        && chmod +x \
            /opt/v2rayN/v2rayN \
            /opt/v2rayN/AmazTool \
            /opt/v2rayN/bin/xray/xray \
            /opt/v2rayN/bin/sing_box/sing-box \
            /opt/v2rayN/bin/mihomo/mihomo \
        && rm -rf /tmp/v2rayn.zip /tmp/v2rayn-unpack "$V2RAYN_RELEASE_JSON" \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 11c. Enhanced clipboard support (xclip + Node.js) ─────────────────
# 安装 xclip 用于剪贴板操作，安装 Node.js 依赖用于剪贴板服务
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends xclip \
        && npm install -g express multer \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 11d. 按需安装运行时依赖 + zenity（替代 CC Switch / OpenTypeless 预装）─────
# CC Switch 与 OpenTypeless 都是 Tauri 应用,共用同一组运行时库;
# 这些库装在镜像里(每个应用按需安装时不再各自拉一遍依赖,体验更顺畅)。
# .deb 本体不再预装,改由 /usr/local/bin/webclaw-app-launcher 在用户首次点击时下载安装。
# zenity 用于安装时弹出确认对话框 + 进度条。
# libxdo3: OpenTypeless 上游 .deb 的 control 漏声明该依赖,运行期 ldd 才能发现,
# 而镜像构建末段会清 apt 缓存,在线 apt-get install 找不到该包。预装兜底。
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends \
             libwebkit2gtk-4.1-0 \
             libayatana-appindicator3-1 \
             libgtk-3-0 \
             libxdo3 \
             zenity \
             jq \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# ─── 12. Config files (COPY last — most likely to change) ───────────
COPY configs/ /tmp/_configs/
COPY scripts/ /tmp/_scripts/
COPY skills/ /opt/skills/

# 等宽字体别名：fontconfig 会把 ui-monospace / SF Mono / Menlo 这些 Linux 上
# 不存在的家族名松散匹配到比例字体 Noto Sans CJK SC，导致 AI CLI Studio 的
# xterm 终端按比例字体量格宽，字符全被摊开。显式指到真实的等宽字体。
# 必须放 conf.d/57-*（早于 60-latin.conf），local.conf 读得太晚，对泛型名
# monospace 的规则会失效。lite 镜像没装 fontconfig，缓存刷不了也不算错。
RUN mkdir -p /etc/fonts/conf.d \
    && cp /tmp/_configs/57-webclaw-mono.conf /etc/fonts/conf.d/57-webclaw-mono.conf \
    && if command -v fc-cache >/dev/null 2>&1; then fc-cache -f; fi

RUN cp /tmp/_configs/supervisord.conf /etc/supervisor/supervisord.conf \
    && cp /tmp/_configs/supervisord-lite.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-code-server.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-openclaw.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-webtty.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-cloudflared.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-analytics.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-dind.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-dashboard.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-clipboard.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_configs/supervisor-ssh.conf /etc/supervisor/conf.d/ \
    && cp /tmp/_scripts/theme-switch.sh /usr/local/bin/theme-switch \
    && cp /tmp/_scripts/lang-switch.sh /usr/local/bin/lang-switch \
    && cp /tmp/_scripts/desktop-language-picker.sh /usr/local/bin/desktop-language-picker \
    && cp /tmp/_scripts/desktop-theme-picker.sh /usr/local/bin/desktop-theme-picker \
    && cp /tmp/_scripts/start-dashboard.sh /opt/start-dashboard.sh \
    && cp /tmp/_scripts/start-webtty.sh /opt/start-webtty.sh \
    && cp /tmp/_scripts/start-openclaw.sh /opt/start-openclaw.sh \
    && cp /tmp/_scripts/start-ssh.sh /opt/start-ssh.sh \
    && cp /tmp/_scripts/openclaw-browser.sh /usr/local/bin/openclaw-browser \
    && cp /tmp/_scripts/code-server-browser.sh /usr/local/bin/code-server-browser \
    && cp /tmp/_scripts/install-hermes.sh /opt/install-hermes.sh \
    && cp /tmp/_scripts/uninstall-hermes.sh /opt/uninstall-hermes.sh \
    && cp /tmp/_scripts/hermes-install-wrapper.sh /opt/hermes-install-wrapper.sh \
    && cp /tmp/_scripts/install-webcode-ai-studio.sh /opt/install-webcode-ai-studio.sh \
    && cp /tmp/_scripts/uninstall-webcode-ai-studio.sh /opt/uninstall-webcode-ai-studio.sh \
    && cp /tmp/_scripts/install-webcode-git-manager.sh /opt/install-webcode-git-manager.sh \
    && cp /tmp/_scripts/uninstall-webcode-git-manager.sh /opt/uninstall-webcode-git-manager.sh \
    && cp /tmp/_scripts/install-webclaw-software-manager.sh /opt/install-webclaw-software-manager.sh \
    && cp /tmp/_scripts/uninstall-webclaw-software-manager.sh /opt/uninstall-webclaw-software-manager.sh \
    && cp /tmp/_scripts/hermes-launcher.sh /usr/local/bin/hermes-launcher \
    && cp /tmp/_scripts/start-hermes-dashboard.sh /opt/start-hermes-dashboard.sh \
    && cp /tmp/_scripts/hermes-browser.sh /opt/hermes-browser.sh \
    && cp /tmp/_scripts/browser.sh /usr/local/bin/browser \
    && cp /tmp/_scripts/launchpad.sh /usr/local/bin/launchpad \
    && cp /tmp/_scripts/webclaw-app-launcher.sh /usr/local/bin/webclaw-app-launcher \
    && cp /tmp/_scripts/webclaw-app-uninstaller.sh /usr/local/bin/webclaw-app-uninstaller \
    && cp /tmp/_scripts/webclaw-app-postinstall.sh /usr/local/bin/webclaw-app-postinstall \
    && cp /tmp/_scripts/webclaw-log-prepare.sh /usr/local/bin/webclaw-log-prepare \
    && cp /tmp/_scripts/update-desktop-icons.sh /usr/local/bin/update-desktop-icons \
    && cp /tmp/_scripts/webclaw-desktop-panel-safe-refresh.sh /usr/local/bin/webclaw-desktop-panel-safe-refresh \
    && cp /tmp/_scripts/install-antigravity.sh /usr/local/bin/install-antigravity \
    && cp /tmp/_scripts/preinstall-on-demand.sh /usr/local/bin/preinstall-on-demand.sh \
    && cp /tmp/_scripts/add-server.sh /usr/local/bin/add-server \
    && cp /tmp/_configs/install-qq.sh /opt/install-qq.sh \
    && cp /tmp/_configs/uninstall-qq.sh /opt/uninstall-qq.sh \
    && cp /tmp/_configs/qq-install-wrapper.sh /opt/qq-install-wrapper.sh \
    && cp /tmp/_configs/install-telegram.sh /opt/install-telegram.sh \
    && cp /tmp/_configs/uninstall-telegram.sh /opt/uninstall-telegram.sh \
    && cp /tmp/_configs/telegram-install-wrapper.sh /opt/telegram-install-wrapper.sh \
    && cp /tmp/_configs/install-discord.sh /opt/install-discord.sh \
    && cp /tmp/_configs/uninstall-discord.sh /opt/uninstall-discord.sh \
    && cp -r /tmp/_scripts/on-demand-helpers/ /usr/local/bin/on-demand-helpers/ \
    && cp /tmp/_scripts/startup.sh /opt/startup.sh \
    && cp /tmp/_scripts/init-skills.sh /opt/init-skills.sh \
    && cp /tmp/_scripts/skills-sync-loop.sh /opt/skills-sync-loop.sh \
    && cp /tmp/_scripts/run-cloudflared.sh /usr/local/bin/run-cloudflared.sh \
    && cp /tmp/_scripts/vnc-setpass.py /opt/vnc-setpass.py \
    && mkdir -p /scripts \
    && cp /tmp/_scripts/analytics.sh /scripts/analytics.sh \
    && cp /tmp/_scripts/dockerd-condition.sh /usr/local/bin/dockerd-condition.sh \
    && cp /tmp/_scripts/backup.sh /opt/backup.sh \
    && cp /tmp/_scripts/restore.sh /opt/restore.sh \
    && cp /tmp/_scripts/snapshot.sh /opt/snapshot.sh \
    && cp /tmp/_scripts/snapshot-restore.sh /opt/snapshot-restore.sh \
    && cp /tmp/_scripts/snapshot-base.sh /opt/snapshot-base.sh \
    && mkdir -p /opt/on-demand-apps /opt/on-demand-icons \
    && cp -r /tmp/_configs/on-demand-apps/. /opt/on-demand-apps/ \
    && cp -r /tmp/_configs/on-demand-icons/. /opt/on-demand-icons/ \
    && cp /tmp/_configs/sudoers/webclaw-app-launcher /etc/sudoers.d/webclaw-app-launcher \
    && mkdir -p /usr/share/icons/WebClaw \
    && cp -r /tmp/_configs/icon-theme/WebClaw/. /usr/share/icons/WebClaw/ \
    && chmod +x \
        /usr/local/bin/theme-switch /usr/local/bin/lang-switch \
        /usr/local/bin/desktop-language-picker /usr/local/bin/desktop-theme-picker \
        /opt/start-dashboard.sh /opt/start-webtty.sh /opt/start-openclaw.sh /opt/start-ssh.sh \
        /usr/local/bin/openclaw-browser /usr/local/bin/code-server-browser \
        /opt/install-hermes.sh /opt/uninstall-hermes.sh /usr/local/bin/hermes-launcher \
        /opt/install-webcode-ai-studio.sh \
        /opt/uninstall-webcode-ai-studio.sh \
        /opt/install-webcode-git-manager.sh \
        /opt/uninstall-webcode-git-manager.sh \
        /opt/install-webclaw-software-manager.sh \
        /opt/uninstall-webclaw-software-manager.sh \
        /opt/start-hermes-dashboard.sh /opt/hermes-browser.sh \
        /usr/local/bin/browser /usr/local/bin/launchpad \
        /usr/local/bin/webclaw-app-launcher /usr/local/bin/webclaw-app-uninstaller \
        /usr/local/bin/webclaw-app-postinstall /usr/local/bin/webclaw-log-prepare \
        /usr/local/bin/update-desktop-icons /usr/local/bin/webclaw-desktop-panel-safe-refresh \
        /usr/local/bin/install-antigravity /usr/local/bin/add-server \
        /usr/local/bin/preinstall-on-demand.sh \
        /usr/local/bin/on-demand-helpers/*.sh \
        /opt/install-qq.sh /opt/uninstall-qq.sh /opt/qq-install-wrapper.sh \
        /opt/install-telegram.sh /opt/uninstall-telegram.sh /opt/telegram-install-wrapper.sh \
        /opt/install-discord.sh /opt/uninstall-discord.sh \
        /opt/startup.sh /opt/init-skills.sh /opt/skills-sync-loop.sh /usr/local/bin/run-cloudflared.sh \
        /scripts/analytics.sh /usr/local/bin/dockerd-condition.sh \
        /opt/backup.sh /opt/restore.sh /opt/snapshot.sh /opt/snapshot-restore.sh /opt/snapshot-base.sh \
    && chmod 0440 /etc/sudoers.d/webclaw-app-launcher \
    && visudo -c -f /etc/sudoers.d/webclaw-app-launcher \
    && ln -sf /usr/local/bin/on-demand-helpers/codex-version-api.sh /usr/local/bin/codex-version-api.sh \
    && ln -sf /usr/local/bin/on-demand-helpers/get-android-studio-version.sh /usr/local/bin/get-android-studio-version \
    && chown root:root /opt/install-hermes.sh /opt/uninstall-hermes.sh \
        /opt/hermes-install-wrapper.sh \
        /opt/start-hermes-dashboard.sh /opt/hermes-browser.sh \
        /opt/install-qq.sh /opt/uninstall-qq.sh /opt/qq-install-wrapper.sh \
        /opt/install-telegram.sh /opt/uninstall-telegram.sh /opt/telegram-install-wrapper.sh \
        /opt/install-discord.sh /opt/uninstall-discord.sh \
        /opt/install-webclaw-software-manager.sh /opt/uninstall-webclaw-software-manager.sh \
    && chmod 755 /opt/install-hermes.sh /opt/uninstall-hermes.sh \
        /opt/hermes-install-wrapper.sh \
        /opt/start-hermes-dashboard.sh /opt/hermes-browser.sh \
        /opt/install-qq.sh /opt/uninstall-qq.sh /opt/qq-install-wrapper.sh \
        /opt/install-telegram.sh /opt/uninstall-telegram.sh /opt/telegram-install-wrapper.sh \
        /opt/install-discord.sh /opt/uninstall-discord.sh \
        /opt/install-webclaw-software-manager.sh /opt/uninstall-webclaw-software-manager.sh \
    && mkdir -p /opt/install-scripts \
    && echo "下载 install-scripts..." \
    && curl -fsSL "https://github.com/qhkly/webclaw-software-manager/archive/refs/heads/main.tar.gz" \
        | tar -xz --strip-components=2 -C /opt/install-scripts/ "webclaw-software-manager-main/scripts/" \
    && echo "install-scripts 下载完成" \
    && chmod +x /opt/install-scripts/*.sh 2>/dev/null || echo "警告: 部分脚本没有执行权限" \
    && chown -R root:root /opt/install-scripts \
    && (curl -fsSL "https://raw.githubusercontent.com/qhkly/webclaw-software-manager/main/preinstall-apps.json" \
        -o /opt/preinstall-apps.json 2>/dev/null || true) \
    && (curl -fsSL "https://raw.githubusercontent.com/qhkly/webclaw-software-manager/main/preinstall-full-apps.json" \
        -o /opt/preinstall-full-apps.json 2>/dev/null || true) \
    && mkdir -p /opt/dashboard-override \
    && chown -R ubuntu:ubuntu /opt/dashboard-override \
    && printf '\n# Theme switch aliases\nalias light-mode="/usr/local/bin/theme-switch light"\nalias dark-mode="/usr/local/bin/theme-switch dark"\n' >> /home/ubuntu/.bashrc \
    && printf '\n# Language switch aliases\nalias chinese="/usr/local/bin/lang-switch zh"\nalias english="/usr/local/bin/lang-switch en"\n' >> /home/ubuntu/.bashrc \
    && printf 'ubuntu ALL=(root) NOPASSWD: /usr/local/bin/lang-switch *\n' > /etc/sudoers.d/webclaw-lang-switch \
    && chmod 0440 /etc/sudoers.d/webclaw-lang-switch \
    && visudo -c -f /etc/sudoers.d/webclaw-lang-switch \
    && mkdir -p /home/ubuntu/.claude/skills \
    && cp -r /opt/skills/* /home/ubuntu/.claude/skills/ \
    && chown -R ubuntu:ubuntu /home/ubuntu/.claude/skills \
    && echo "land007/webclaw" > /.image_name \
    && echo $(date "+%Y-%m-%d_%H:%M:%S") > /.image_time

# ─── 12b. Preinstall required lightweight on-demand apps ─────────────
# cc-switch is part of the base image so the launcher can seed its provider DB
# before the GUI is opened. This only installs the binary; it does not start it.
RUN PREINSTALL_REQUIRED=cc-switch \
    PREINSTALL_ONLY=cc-switch \
    /usr/local/bin/preinstall-on-demand.sh && \
    command -v cc-switch >/dev/null

# ─── 13. Desktop-specific file placement ────────────────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ]; then \
        cp /tmp/_configs/supervisor-audio.conf /etc/supervisor/conf.d/ \
        && cp /tmp/_configs/audio-player.html /opt/noVNC/audio.html \
        && cp /tmp/_configs/audio-bar.js /opt/noVNC/audio-bar.js \
        && cp /tmp/_configs/touch-handler.js /opt/noVNC/touch-handler.js \
        && cp /tmp/_configs/key-remap.js /opt/noVNC/key-remap.js \
        && chmod +x /tmp/_scripts/patch-novnc.sh \
        && /tmp/_scripts/patch-novnc.sh \
        && python3 /tmp/_scripts/install-gnome-panel-labels.py \
        && (gtk-update-icon-cache -f -t /usr/share/icons/WebClaw 2>/dev/null || true) \
        && mkdir -p /usr/share/backgrounds/webclaw /usr/share/gnome-background-properties \
        && cp /tmp/_configs/backgrounds/webclaw-backgrounds.xml /usr/share/gnome-background-properties/webclaw-backgrounds.xml \
        && for background in $(sed -n 's|.*<filename>/usr/share/backgrounds/webclaw/\([^<]*\)</filename>.*|\1|p' /usr/share/gnome-background-properties/webclaw-backgrounds.xml); do \
            cp "/tmp/_configs/backgrounds/${background}" /usr/share/backgrounds/webclaw/; \
        done \
        && python3 /tmp/_scripts/prune-gnome-backgrounds.py \
            /usr/share/gnome-background-properties \
            Province_of_the_south_of_france_by_orbitelambda.jpg \
            Monument_valley_by_orbitelambda.jpg \
        && rm -f \
            /usr/share/backgrounds/Province_of_the_south_of_france_by_orbitelambda.jpg \
            /usr/share/backgrounds/Monument_valley_by_orbitelambda.jpg \
        && cp /tmp/_configs/xsession /opt/xsession \
        && chmod +x /opt/xsession \
        && cp /tmp/_configs/start-xvnc.sh /opt/start-xvnc.sh \
        && cp /tmp/_configs/setup-monitors.sh /opt/setup-monitors.sh \
        && cp /tmp/_configs/compute-total-geometry.py /opt/compute-total-geometry.py \
        && chmod +x /opt/start-xvnc.sh /opt/setup-monitors.sh /opt/compute-total-geometry.py \
        && cp -r /tmp/_configs/desktop-shortcuts/ /opt/ \
        && cp -r /tmp/_configs/desktop-icons/ /opt/ \
        && mkdir -p /etc/xdg/menus/applications-merged /etc/xdg/menus/gnome-flashback-applications-merged \
        && cp /tmp/_configs/gnome-flashback-ai-tools.menu /etc/xdg/menus/applications-merged/ \
        && cp /tmp/_configs/gnome-flashback-ai-tools.menu /etc/xdg/menus/gnome-flashback-applications-merged/ \
        && mkdir -p /usr/share/desktop-directories \
        && cp /tmp/_configs/ai-tools.directory /usr/share/desktop-directories/ \
        && cp /tmp/_configs/gnome-flashback-applications.menu /etc/xdg/menus/gnome-flashback-applications.menu \
        && cp /opt/desktop-shortcuts/*.desktop /usr/share/applications/ \
        && chmod +x /usr/share/applications/*.desktop \
        && cp /opt/desktop-shortcuts/v2rayN.desktop /usr/share/applications/v2rayN.desktop \
        && chmod +x /usr/share/applications/v2rayN.desktop \
        && (update-desktop-database /usr/share/applications 2>/dev/null || true) \
        && cp /tmp/_scripts/audio-ws-server.py /opt/ \
        && cp /tmp/_scripts/audio-ws-wrapper.sh /opt/ \
        && chmod +x /opt/audio-ws-server.py /opt/audio-ws-wrapper.sh \
        && cp /tmp/_configs/clipboard-server.js /opt/clipboard-server.js \
        && cp /tmp/_configs/custom-clipboard-image.js /opt/noVNC/custom-clipboard-image.js \
        && chmod +x /opt/clipboard-server.js \
        && sed -i 's|</body>|<script type="module">import UI from "./app/ui.js";window.UI=UI;</script><script src="custom-clipboard-image.js?v=20260531b"></script></body>|' /opt/noVNC/vnc.html \
        && cp /opt/desktop-shortcuts/hermes-uninstall.desktop /usr/share/applications/ \
        && cp /tmp/_configs/desktop-shortcuts/launchpad.desktop /usr/share/applications/launchpad.desktop \
        && (update-desktop-database /usr/share/applications 2>/dev/null || true); \
    fi \
    && rm -rf /tmp/_configs /tmp/_scripts

# ─── 通过 webclaw-software-manager 预装清单预装 app ──────────────────
RUN if [ "$INSTALL_DESKTOP" = "true" ] \
    && [ -f /opt/preinstall-apps.json ] \
    && [ -x /opt/install-scripts/preinstall.sh ]; then \
        WEBCLAW_DOCKER_BUILD=1 bash /opt/install-scripts/preinstall.sh; \
    fi

# ─── Metadata ───────────────────────────────────────────────────────
ARG WEBCODE_VERSION=dev
LABEL org.opencontainers.image.title="webclaw" \
      org.opencontainers.image.description="OpenClaw by WebClaw with editor, optional desktop, and isolated runtime" \
      org.opencontainers.image.url="https://github.com/land007/webcode" \
      org.opencontainers.image.source="https://github.com/land007/webcode" \
      org.opencontainers.image.vendor="land007" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.logo="https://raw.githubusercontent.com/land007/webclaw/main/images/icon-source.png" \
      org.opencontainers.image.version="${WEBCODE_VERSION:-dev}"

# ─── Environment defaults ───────────────────────────────────────────
ENV MODE=desktop
ENV PASSWORD=
ENV VNC_RESOLUTION=1920x1080
ENV CLEAN_DESKTOP=true

ENTRYPOINT ["/opt/startup.sh"]

#docker build --build-arg INSTALL_DESKTOP=false -t land007/webclaw_lite:latest .
#docker build --build-arg INSTALL_DESKTOP=true -t land007/webclaw:latest .
