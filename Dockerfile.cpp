# ─────────────────────────────────────────────────────────────
#  C++ Development Environment
#  Adds GCC compiler and C++ extensions to webclaw-lite
# ─────────────────────────────────────────────────────────────
FROM land007/webclaw_lite:latest

LABEL org.opencontainers.image.title="webclaw-cpp" \
      org.opencontainers.image.description="WebClaw with C++ development tools and extensions" \
      org.opencontainers.image.source="https://github.com/land007/webclaw"

# ─── Install GCC and C++ development tools ─────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ gdb make cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ─── Install C++ extensions for code-server ────────────────────
RUN mkdir -p /opt/code-server-extensions \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension ms-vscode.cpptools \
         && break || (echo "Retry $i/5 for C/C++ tools (cpptools)..." && sleep 10); \
       done \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension ms-vscode.cmake-tools \
         && break || (echo "Retry $i/5 for CMake Tools..." && sleep 10); \
       done \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension twxs.cmake \
         && break || (echo "Retry $i/5 for CMake (twxs)..." && sleep 10); \
       done \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension danielpinto8zz6.c-cpp-compile-run \
         && break || (echo "Retry $i/5 for C/C++ Compile Run..." && sleep 10); \
       done \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension jeff-hykin.better-cpp-syntax \
         && break || (echo "Retry $i/5 for Better C++ Syntax..." && sleep 10); \
       done \
    && for i in 1 2 3 4 5; do \
         code-server --extensions-dir /opt/code-server-extensions \
             --install-extension GitHub.copilot-chat \
         && break || (echo "Retry $i/5 for GitHub Copilot Chat..." && sleep 10); \
       done \
    && chown -R ubuntu:ubuntu /opt/code-server-extensions

# ─── Set default working directory ─────────────────────────────
WORKDIR /home/ubuntu/projects

#docker build -f Dockerfile.cpp -t land007/webclaw_cpp:latest .
