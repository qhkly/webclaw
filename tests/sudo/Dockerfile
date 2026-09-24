# sudo 最小权限回归测试镜像：只复刻 Dockerfile.base / Dockerfile 里和 sudo 相关的部分，
# 用仓库里真实的 sudoers、broker、审计脚本。由 test-sudo-hardening.sh 构建运行。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo jq curl ca-certificates libcap2-bin \
    && (id ubuntu >/dev/null 2>&1 && usermod -s /bin/bash ubuntu || useradd -m -s /bin/bash ubuntu) \
    && (gpasswd -d ubuntu sudo >/dev/null 2>&1 || true) \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY configs/sudoers/webclaw-app-launcher /etc/sudoers.d/webclaw-app-launcher
COPY configs/on-demand-apps/ /opt/on-demand-apps/
COPY tests/sudo/manifests/ /opt/on-demand-apps/
COPY scripts/webclaw-app-admin.sh /usr/local/bin/webclaw-app-admin
COPY scripts/webclaw-app-uninstaller.sh /usr/local/bin/webclaw-app-uninstaller
COPY scripts/webclaw-app-postinstall.sh /usr/local/bin/webclaw-app-postinstall
COPY scripts/webclaw-sudoers-audit.sh /usr/local/bin/webclaw-sudoers-audit
COPY scripts/webclaw-apply-user-sudo.sh /usr/local/bin/webclaw-apply-user-sudo
COPY scripts/webclaw-scripts-updater /usr/local/bin/webclaw-scripts-updater
COPY scripts/lang-switch.sh /usr/local/bin/lang-switch
COPY tests/sudo/in-container.sh /opt/test/in-container.sh

# 与 Dockerfile 第 12 步一致：lang-switch 只放行 7 个精确参数；全部 root 所有。
# /opt 下被 sudoers 引用的 custom_script 用桩代替（真实镜像里是对应的安装脚本）。
RUN for code in zh en ja es pt ko de; do \
        printf 'ubuntu ALL=(root) NOPASSWD: /usr/local/bin/lang-switch %s\n' "$code"; \
    done > /etc/sudoers.d/webclaw-lang-switch \
    && chmod 0440 /etc/sudoers.d/webclaw-app-launcher /etc/sudoers.d/webclaw-lang-switch \
    && chmod 755 /usr/local/bin/webclaw-app-admin /usr/local/bin/webclaw-app-uninstaller \
        /usr/local/bin/webclaw-app-postinstall /usr/local/bin/webclaw-sudoers-audit \
        /usr/local/bin/webclaw-apply-user-sudo \
        /usr/local/bin/webclaw-scripts-updater /usr/local/bin/lang-switch /opt/test/in-container.sh \
    && chmod 755 /opt/on-demand-apps && chmod 644 /opt/on-demand-apps/*.json \
    && mkdir -p /opt/install-scripts \
    && for f in $(grep -oE '/opt/[A-Za-z0-9._/-]+\.sh' /etc/sudoers.d/webclaw-app-launcher | sort -u) \
                /opt/install-scripts/evil.sh /opt/install-scripts/install-claude-code.sh; do \
        printf '#!/bin/sh\necho "STUB-RAN %s as $(id -un)"\n' "$f" > "$f"; chmod 755 "$f"; \
    done \
    && mkdir -p /opt/webclaw-test-debs \
    && for spec in webclaw-test-deb:webclaw-test-deb other-pkg-zz:wrong; do \
        pkg="${spec%%:*}"; out="${spec#*:}"; d="$(mktemp -d)"; \
        mkdir -p "$d/DEBIAN" "$d/usr/lib/webclaw-test/$pkg"; echo trusted > "$d/usr/lib/webclaw-test/$pkg/ok"; \
        printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@t>\nDescription: trusted test deb\n' "$pkg" > "$d/DEBIAN/control"; \
        dpkg-deb --build "$d" "/opt/webclaw-test-debs/$out.deb" >/dev/null; rm -rf "$d"; \
    done \
    && chmod 755 /opt/webclaw-test-debs && chmod 644 /opt/webclaw-test-debs/*.deb \
    && printf '#!/bin/sh\ntouch /tmp/webclaw-test-prepared\n' > /usr/local/bin/webclaw-test-prepare \
    && chmod 755 /usr/local/bin/webclaw-test-prepare \
    && chown -R root:root /opt /usr/local/bin /etc/sudoers.d
