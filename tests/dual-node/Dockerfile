# 双 Node 运行时的精简测试镜像：只复刻 Dockerfile.base / Dockerfile 里和 Node 相关的步骤，
# 用的是仓库里真实的脚本，不装桌面 / code-server 等无关组件。由 test-dual-node.sh 构建运行。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils procps sudo \
        libatomic1 \
    && (id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu) \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 系统 Node（同 Dockerfile.base 第 2 步）
ARG NODE_VERSION=22.22.1
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in amd64) NODE_ARCH=x64 ;; arm64) NODE_ARCH=arm64 ;; esac \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/node.tar.xz \
       "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner && rm -f /tmp/node.tar.xz \
    && npm install -g webclaw-dashboard-server@latest

# 用户 Node seed（同 Dockerfile.base 第 5b 步；CLI 只装 Claude Code 以节省时间）
COPY scripts/build-user-node-seed.sh /opt/webclaw/build-user-node-seed.sh
RUN chmod 755 /opt/webclaw/build-user-node-seed.sh \
    && install -d -m 755 /opt/nvm-seed \
    && install -d -o ubuntu -g ubuntu /home/ubuntu/.nvm \
    && /opt/webclaw/build-user-node-seed.sh init \
    && /opt/webclaw/build-user-node-seed.sh install @anthropic-ai/claude-code@latest

# 运行时脚本（同 Dockerfile 第 12 步）
COPY scripts/user-node-env.sh /opt/webclaw/user-node-env.sh
COPY scripts/webclaw-user-node-run.sh /usr/local/bin/webclaw-user-node-run
COPY scripts/webclaw-user-node-update.sh /usr/local/bin/webclaw-user-node-update
COPY scripts/verify-dual-node.sh /usr/local/bin/webclaw-verify-dual-node
COPY scripts/start-dashboard.sh /opt/start-dashboard.sh
COPY scripts/start-webcode-studiod.sh /opt/start-webcode-studiod.sh
COPY tests/dual-node/fake-studiod.sh /usr/local/bin/webcode-studiod
COPY tests/dual-node/in-container.sh /opt/test/in-container.sh
RUN chmod 644 /opt/webclaw/user-node-env.sh \
    && chmod 755 /usr/local/bin/webclaw-user-node-run /usr/local/bin/webclaw-user-node-update \
        /usr/local/bin/webclaw-verify-dual-node /opt/start-dashboard.sh /opt/start-webcode-studiod.sh \
        /usr/local/bin/webcode-studiod /opt/test/in-container.sh \
    && printf '%s\n' '' '# >>> webclaw user node >>>' \
        'export NVM_DIR="$HOME/.nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        '# <<< webclaw user node <<<' >> /home/ubuntu/.bashrc
