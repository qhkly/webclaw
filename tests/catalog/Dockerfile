# runtime catalog 回归测试镜像：用仓库里真实的 broker / updater / launcher / 共享库，
# 外加一个本地 HTTPS 服务（测试 CA 签发、/etc/hosts 劫持固定域名）。由 test-runtime-catalog.sh 构建运行。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo jq curl ca-certificates python3 openssl util-linux unzip \
    && (id ubuntu >/dev/null 2>&1 && usermod -s /bin/bash ubuntu || useradd -m -s /bin/bash ubuntu) \
    && (gpasswd -d ubuntu sudo >/dev/null 2>&1 || true) \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/webclaw-app-admin.sh /usr/local/bin/webclaw-app-admin
COPY scripts/webclaw-catalog-update.sh /usr/local/bin/webclaw-catalog-update
COPY scripts/webclaw-app-launcher.sh /usr/local/bin/webclaw-app-launcher
COPY scripts/webclaw-app-uninstaller.sh /usr/local/bin/webclaw-app-uninstaller
COPY scripts/webclaw-app-postinstall.sh /usr/local/bin/webclaw-app-postinstall
COPY scripts/webclaw-sudoers-audit.sh /usr/local/bin/webclaw-sudoers-audit
COPY scripts/lib/runtime-catalog.sh /usr/local/lib/webclaw/runtime-catalog.sh
COPY scripts/lib/on-demand-core.sh /opt/lib/on-demand-core.sh
COPY configs/on-demand-apps/ /opt/on-demand-apps/
COPY tests/catalog/manifests/ /opt/on-demand-apps/
COPY tests/catalog/in-container.sh /opt/test/in-container.sh
COPY tests/catalog/https-server.py /opt/test/https-server.py

# 与正式镜像一致：sudoers 只放行 broker（本测试不需要其它条目）；updater 不在 sudoers 里。
# 测试 CA + 覆盖所有被劫持域名的服务端证书；zenity 用桩代替（记录调用、吞掉进度输入）。
RUN printf 'ubuntu ALL=(root) NOPASSWD: /usr/local/bin/webclaw-app-admin\n' > /etc/sudoers.d/webclaw-app-launcher \
    && chmod 0440 /etc/sudoers.d/webclaw-app-launcher \
    && chmod 755 /usr/local/bin/webclaw-app-admin /usr/local/bin/webclaw-catalog-update \
        /usr/local/bin/webclaw-app-launcher /usr/local/bin/webclaw-app-uninstaller \
        /usr/local/bin/webclaw-app-postinstall /usr/local/bin/webclaw-sudoers-audit \
        /opt/test/in-container.sh \
    && chmod 644 /usr/local/lib/webclaw/runtime-catalog.sh /opt/lib/on-demand-core.sh \
    && chmod 755 /usr/local/lib/webclaw /opt/lib /opt/on-demand-apps && chmod 644 /opt/on-demand-apps/*.json \
    && install -d -m 755 /var/lib/webclaw /var/lib/webclaw/catalog /var/lib/webclaw/installed \
    && useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin webclaw-unpack \
    && install -d -m 710 -o root -g webclaw-unpack /var/lib/webclaw/unpack \
    && printf '#!/bin/sh\nmkdir -p /opt/ctest-custom\nprintf "#!/bin/sh\\necho CUSTOM-OK\\n" > /opt/ctest-custom/ctest-custom\nchmod 755 /opt/ctest-custom/ctest-custom\necho "ran as $(id -un)" > /opt/ctest-custom/ran\necho run >> /var/log/ctest-custom-runs\n(sleep 300 >/dev/null 2>&1 &)\n' > /opt/ctest-install.sh \
    && printf '#!/bin/sh\nrm -rf /opt/ctest-custom\n' > /opt/ctest-uninstall.sh \
    && chmod 755 /opt/ctest-install.sh /opt/ctest-uninstall.sh \
    && printf '#!/bin/sh\necho "$*" >> /tmp/zenity.log\ncase " $* " in *" --progress "*) cat >/dev/null ;; esac\nexit 0\n' > /usr/local/bin/zenity \
    && chmod 755 /usr/local/bin/zenity \
    && mkdir -p /etc/ctest /home/ubuntu/Desktop && chown ubuntu:ubuntu /home/ubuntu/Desktop \
    && cd /etc/ctest \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=ctest CA" \
        -keyout ca.key -out ca.crt 2>/dev/null \
    && printf 'subjectAltName=DNS:raw.githubusercontent.com,DNS:github.com,DNS:api.github.com,DNS:downloads.ctest.example,DNS:evil.example\n' > san.ext \
    && openssl req -newkey rsa:2048 -nodes -subj "/CN=ctest" -keyout server.key -out server.csr 2>/dev/null \
    && openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile san.ext -out server.crt 2>/dev/null \
    && cp ca.crt /usr/local/share/ca-certificates/ctest-ca.crt && update-ca-certificates >/dev/null \
    && chown -R root:root /opt /usr/local/bin /usr/local/lib /etc/sudoers.d /var/lib/webclaw/catalog /var/lib/webclaw/installed
