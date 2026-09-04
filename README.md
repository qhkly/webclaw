<p align="center">
  <img src="https://raw.githubusercontent.com/land007/webclaw/main/images/icon-source.png" width="120" alt="WebClaw">
</p>

# WebClaw — AI Coding Agent Sandbox for OpenClaw

![GitHub Stars](https://img.shields.io/github/stars/land007/webclaw?style=social)
![License](https://img.shields.io/badge/license-MIT-blue)
![Docker Pulls](https://img.shields.io/docker/pulls/land007/webclaw)
![Platforms](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-blue)

> *WebClaw is an independent third-party product. Not affiliated with OpenClaw.*

**🌐 [Official Website](https://webclaw.qhkly.com)** — Documentation, guides, and downloads

[📦 Repository](https://github.com/land007/webclaw) |
[🚀 Launcher](https://github.com/land007/webclaw-launcher-tauri) |
[🌐 Website](https://webclaw.qhkly.com) |
[🐳 Default Image](https://hub.docker.com/r/land007/webclaw) |
[🪶 Lite Image](https://hub.docker.com/r/land007/webclaw_lite) |
[🧰 Full Image](https://hub.docker.com/r/land007/webclaw_full) |
[🐛 Issues](https://github.com/land007/webclaw/issues)

> **Three editions available:**
> - **[webclaw](https://hub.docker.com/r/land007/webclaw)** — Desktop image: GNOME desktop + code-server + OpenClaw
> - **[webclaw_lite](https://hub.docker.com/r/land007/webclaw_lite)** — Lite image: code-server + OpenClaw, no desktop (faster startup)
> - **[webclaw_full](https://hub.docker.com/r/land007/webclaw_full)** — Desktop image + 4 AI CLIs (Claude / Gemini / Codex / Cursor)

OpenClaw is a powerful open-source AI coding agent, but it needs direct access to your machine. WebClaw runs it inside an isolated Docker container — full Linux environment, zero risk to your real files.

---

## ✨ What's Inside

| Component | Description |
|-----------|-------------|
| 💻 **code-server** | Browser-based VS Code to view and edit code anytime. |
| 📊 **Vibe Kanban** | Visual task board for project management |
| 🤖 **OpenClaw AI** | Self-hosted AI assistant gateway (supports multiple AI providers) |
| 🖥️ **noVNC Desktop** | Full GNOME Flashback Linux desktop accessible via browser |
| 🔒 **Sandboxed** | Complete isolation — AI cannot access your host files |

---

## 🎯 Use Cases

- **🧪 AI Development & Testing**: Experiment with AI tools safely without risking your host system
- **📚 Learning Environment**: Practice Linux, coding, or DevOps — reset instantly with `docker compose down -v`
- **🌐 Remote Development**: Access your full development environment from any device with a browser
- **🔧 Quick Project Sandbox**: Spin up an isolated dev environment for temporary projects

---

## 📊 Comparison

| | WebClaw | Manual Install | Generic Docker Guides |
|---|---|---|---|
| **Setup Time** | ~1 min | 30+ min | Instant |
| **Isolation** | ✅ Full container | ❌ Host system | ✅ Container |
| **AI Safety** | ✅ Sandbox protects host | ❌ AI has host access | ⚠️ Shared environment |
| **Offline Use** | ✅ Fully offline | ✅ | ❌ Requires internet |
| **Data Persistence** | ✅ Docker volumes | ✅ Local files | ⚠️ Needs setup |
| **Linux Desktop** | ✅ Included | ❌ N/A | ❌ N/A |
| **Cost** | Free (your hardware) | Free | Paid tiers |

---

## 🚀 Installation

**📖 For detailed installation guides and documentation, visit [webclaw.qhkly.com](https://webclaw.qhkly.com)**

### Method 1: Desktop App — Download & Run (Easiest) ⭐

No Git or Node.js needed. Just Docker Desktop + a download.

**Step 1 — Install Docker Desktop** (if not already installed):

| Platform | Download |
|----------|----------|
| macOS | [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) |
| Windows | [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) |
| Linux | [Docker Engine](https://docs.docker.com/engine/install/) |

**Step 2 — Download the WebClaw launcher app:**

Visit **[webclaw.qhkly.com](https://webclaw.qhkly.com)** to download the launcher app for your platform, or download from the [**Releases page**](https://github.com/land007/webclaw/releases/latest):

| Platform | File to download |
|----------|-----------------|
| macOS (Apple Silicon / M1+) | `webclaw-launcher-osx-arm64-*.zip` |
| macOS (Intel) | `webclaw-launcher-osx-x64-*.zip` |
| Windows | `webclaw-launcher-win-x64-*.zip` |
| Linux | `webclaw-launcher-linux-x64-*.zip` |

**Step 3 — Unzip and run:**

- **macOS**: Unzip → right-click `webclaw.app` → **Open** (required first time to bypass Gatekeeper)
- **Windows**: Unzip → double-click `webclaw.exe` → click "Run anyway" if SmartScreen appears
- **Linux**: Unzip → run `./webclaw`

The app will guide you through setup with a step-by-step wizard.

---

### Method 2: One-Command Installer (Terminal)

**macOS / Linux**:
```bash
curl -fsSL https://raw.githubusercontent.com/land007/webclaw/main/install.sh | bash
```

**Windows** (PowerShell — **Run as Administrator**):
```powershell
irm https://raw.githubusercontent.com/land007/webclaw/main/install.ps1 | iex
```

---

### Method 3: Docker Only (Servers / Headless)

No GUI needed. Requires [Docker](https://docs.docker.com/engine/install/).

**Option A — Minimal one-liner (simplest) ⚡:**

```bash
docker run -d --name webclaw -p 20000:20000 \
  --shm-size=512m --security-opt seccomp=unconfined \
  -v webclaw-config:/home/ubuntu/.webclaw \
  -v projects:/home/ubuntu/projects \
  land007/webclaw:latest
```

Then open **http://localhost:20000** — log in with `admin` / `changeme`, click ⚙ to configure passwords, tokens, and Git settings. **All configuration persists across restarts** via the `webclaw-config` volume.

**Option B — Using docker compose (recommended for easier management):**

**macOS / Linux / WSL / Git Bash:**
```bash
mkdir -p ~/webcode && cd ~/webcode
curl -fsSL https://raw.githubusercontent.com/land007/webclaw/main/launcher/assets/docker-compose.yml -o docker-compose.yml
docker compose up -d
```

**Option C — Full docker run with all volumes and env vars:**

```bash
docker run -d \
  --name webclaw \
  --restart unless-stopped \
  -p 20000:20000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v webclaw-config:/home/ubuntu/.webclaw \
  -v dna-data:/home/ubuntu/dna \
  -v projects:/home/ubuntu/projects \
  -v vibe-kanban-data:/home/ubuntu/.local/share/vibe-kanban \
  -v code-server-data:/home/ubuntu/.code-server \
  -v user-data:/home/ubuntu/.local/share \
  -v gitconfig:/home/ubuntu/.gitconfig-vol \
  -v openclaw-data:/home/ubuntu/.openclaw \
  -v chrome-data:/home/ubuntu/.config \
  -v recordings:/home/ubuntu/recordings \
  -e MODE=desktop \
  -e AUTH_USER=admin \
  -e AUTH_PASSWORD=changeme \
  -e VNC_PASSWORD=changeme \
  -e VNC_RESOLUTION=1920x1080 \
  --shm-size=512m \
  --security-opt seccomp=unconfined \
  land007/webclaw:latest
```

**Windows PowerShell:**
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\webcode"
Set-Location "$env:USERPROFILE\webcode"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/land007/webclaw/main/launcher/assets/docker-compose.yml" -OutFile docker-compose.yml
docker compose up -d
```

---

## 🌐 Access

After startup, open **http://localhost:20000** — this is the unified dashboard entry point.

| Service | URL | Login |
|---------|-----|-------|
| 🏠 **Dashboard** (main entry) | **http://localhost:20000** | `admin` / `changeme` |
| 💻 IDE (code-server) | http://localhost:20001 | `admin` / `changeme` |
| 📊 Vibe Kanban | http://localhost:20002 | `admin` / `changeme` |
| 🤖 OpenClaw AI | http://localhost:20003 | `admin` / `changeme` |
| 🖥️ noVNC Desktop | http://localhost:20004 | VNC password: `changeme` |
| VNC client app | localhost:20005 | VNC password: `changeme` |

> Default credentials are `admin` / `changeme`. Click the **⚙ settings button** in the dashboard to change passwords, tokens, and Git settings — changes take effect immediately and persist across restarts.

---

## 🔒 Security & Isolation

**Will AI break my computer? No!**

Everything runs inside a **sandboxed Docker container**. Your host computer is completely safe.

- ✅ **AI can't touch your files** — It only sees files inside the container, not your documents, photos, or anything on your real computer
- ✅ **Experiment freely** — Run any code, install anything, break things inside — your computer stays untouched
- ✅ **One-command reset** — Messed up? Run `docker compose down -v` and start fresh in seconds

> 💡 Think of it like a "sandbox computer" running inside your real computer. You can do anything inside the sandbox — it won't affect your real computer at all.

**⚠️ About Docker socket (optional)**

By default, `/var/run/docker.sock` is mounted for Docker-in-Docker capability.
- **Most users**: Keep it — you'll want this feature
- **Security-sensitive use**: Comment it out in `docker-compose.yml` if running untrusted code

---

## ⚙️ Configuration

### Runtime Config Panel (Recommended) ⭐

Open **http://localhost:20000**, log in, and click the **⚙ gear icon** in the top bar. You can change:

- Basic Auth username / password
- VNC password
- OpenClaw API token
- Git username and email
- Cloudflare Tunnel token
- Enable / disable Kanban and OpenClaw services

Changes apply **immediately** (no restart needed) and persist in the `webclaw-config` volume across container restarts.

### Environment Variables (docker-compose / docker run)

Create a `.env` file next to `docker-compose.yml`, or pass `-e` flags to `docker run`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE` | `desktop` | `desktop` (with VNC desktop) or `lite` (no desktop, lighter) |
| `AUTH_USER` | `admin` | Login username for all services |
| `AUTH_PASSWORD` | `changeme` | Login password |
| `VNC_PASSWORD` | `changeme` | VNC desktop password (desktop mode only) |
| `VNC_RESOLUTION` | `1920x1080` | Desktop resolution (desktop mode only) |
| `OPENCLAW_GATEWAY_TOKEN` | `changeme` | Gateway token |
| `GIT_USER_NAME` | — | Git commit username |
| `GIT_USER_EMAIL` | — | Git commit email |
| `CF_TUNNEL_TOKEN` | empty | Cloudflare Tunnel token — enables remote access when set |
| `ENABLE_WEBCODE_STUDIOD` | `false` | AI Studio headless node — lets your local WebCode AI Studio drive this container as a remote Studio. Works in lite/desktop/full; reachable through the existing gateway at `http://<host>:20000/proxy/10010`, no extra port. |
| `AI_STUDIO_PEER_TOKEN` | same as `AUTH_PASSWORD` | Federation token; leave empty to reuse the login password |
| `AI_STUDIO_PEER_SCOPE` | `lan` | Access scope: `lan` or `tunnel` |

> **Note:** If a value is set via both `webclaw-config` volume and environment variable, the volume value takes priority (so runtime changes aren't overwritten on restart).

```bash
cp .env.example .env
# Edit .env, then:
docker compose up -d
```

---

## 🔨 Building from Source

### Build Full Version (with Desktop)

**Full version** includes GNOME desktop, VNC/noVNC, Chinese input (fcitx), browser, code-server, Vibe Kanban, and OpenClaw.

### 🚀 Quick Start (Recommended - Use Pre-built Base Image)

The fastest way to build is using the pre-built base image from Docker Hub:

```bash
# Pull or ensure base image exists (first time only)
docker pull land007/webclaw_base:latest

# Build full version (30-60 seconds, using cached base)
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=latest .

# Build lite version (5-10 seconds, using cached base)
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=latest --build-arg INSTALL_DESKTOP=false .
```

**Benefits:**
- ⚡ **Fast:** Configuration changes take seconds, not minutes
- 💾 **Efficient:** Base Theia image (~2GB) is downloaded once and cached
- 🔄 **Iterative:** Perfect for rapid development on dashboard, configs, scripts

### 🔨 Full Build (Base + Overlay, 10-15 minutes)

Build everything from scratch, including the base Theia image:

```bash
# Clone repository
git clone https://github.com/land007/webclaw.git && cd webclaw

# Step 1: Build base image (10-12 minutes, slowest step)
docker build -f Dockerfile.base -t webcode:base-theia-local .

# Step 2a: Build full version (30-60 seconds)
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=local .

# Step 2b: OR build lite version (5-10 seconds)
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=local --build-arg INSTALL_DESKTOP=false .
```

**Image size:** ~2.5-3 GB (full) / ~1-1.5 GB (lite)

### 🌍 Multi-Arch Build (AMD64 + ARM64)

For production deployment to Docker Hub:

```bash
# Build base image for both architectures
docker buildx build --platform linux/amd64,linux/arm64 \
  -f Dockerfile.base \
  -t land007/webclaw_base:latest \
  --push .

# Build full version
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg WEBCLAW_BASE_VERSION=latest \
  --build-arg INSTALL_DESKTOP=true \
  -t land007/webclaw:latest \
  --push .

# Build lite version
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg WEBCLAW_BASE_VERSION=latest \
  --build-arg INSTALL_DESKTOP=false \
  -t land007/webclaw:latest \
  --push .
```

### Version Comparison

| Feature | Full Version | Lite Version |
|---------|--------------|--------------|
| code-server | ✅ | ✅ |
| Vibe Kanban | ✅ | ❌ |
| OpenClaw AI | ✅ | ✅ |
| Dashboard Proxy | ✅ | ✅ |
| GNOME Desktop | ✅ | ❌ |
| VNC/noVNC | ✅ | ❌ |
| fcitx Chinese Input | ✅ | ❌ |
| Chrome/Chromium | ✅ | ❌ |
| Image Size | ~2.5-3 GB | ~1-1.5 GB |
| Use Case | Full desktop experience | Lightweight development only |

---

## 🖥️ Run Modes

**Desktop mode** (default) — Full GNOME Linux desktop in your browser, with Chinese input (fcitx + Google Pinyin):
```bash
docker compose up -d
```

**Lite mode** — Only code-server + OpenClaw, no desktop (lower resource usage):
```bash
MODE=lite docker compose up -d
```

---

## 🔧 Common Commands

```bash
# Check status
docker compose ps

# View logs
docker compose logs -f

# Stop
docker compose down

# Stop and erase all data (caution!)
docker compose down -v

# Restart a single service
docker exec -it webclaw supervisorctl restart code-server
```

---

## 💾 Data Persistence

Your data survives container restarts and updates — stored in Docker volumes:

| Volume | What's stored |
|--------|---------------|
| `projects` | Your code (`/home/ubuntu/projects`) |
| `code-server-data` | code-server settings and extensions |
| `vibe-kanban-data` | Kanban task data |
| `user-data` | Bash history and user data |
| `openclaw-data` | OpenClaw config and data |
| `gitconfig` | Git identity (`.gitconfig`) |

---

## 🤖 OpenClaw First-Time Setup

After first startup, run this once to complete initialization:
```bash
docker exec -it -u ubuntu webcode openclaw onboard
```
Follow the prompts, then refresh http://localhost:20003.

---
---

# webcode（中文文档）

**提供三个版本：**
- **[webclaw](https://hub.docker.com/r/land007/webclaw)** — 桌面版：GNOME 桌面 + code-server + OpenClaw
- **[webclaw_lite](https://hub.docker.com/r/land007/webclaw_lite)** — 精简版：code-server + OpenClaw，无桌面（启动更快）
- **[webclaw_full](https://hub.docker.com/r/land007/webclaw_full)** — 桌面版 + 4 款 AI CLI（Claude / Gemini / Codex / Cursor）

基于 Docker 的浏览器可访问开发环境，内置 **code-server**、**Vibe Kanban**、**noVNC 桌面**和 **OpenClaw AI**。

---

## ✨ 内置组件

| 组件 | 说明 |
|------|------|
| 💻 **code-server** | 浏览器版 VS Code，随时查看和编辑代码。 |
| 📊 **Vibe Kanban** | 可视化看板任务管理工具 |
| 🤖 **OpenClaw AI** | 自托管 AI 助手网关（支持多种 AI 服务商） |
| 🖥️ **noVNC 桌面** | 通过浏览器访问的完整 GNOME Linux 桌面 |
| 🔒 **沙箱隔离** | 完全隔离 — AI 无法访问你的宿主机文件 |

---

## 🎯 适用场景

- **🧪 AI 开发与测试**：安全地试验各种 AI 工具，无需担心影响宿主机
- **📚 学习环境**：练习 Linux、编程或 DevOps — 用 `docker compose down -v` 一键重置
- **🌐 远程开发**：从任何设备的浏览器访问完整开发环境
- **🔧 临时项目沙盒**：为临时项目快速启动隔离的开发环境

---

## 📊 对比

| | webcode | 本地 VS Code | GitPod / Codespaces |
|---|---|---|---|
| **安装时间** | ~1 分钟 | 30+ 分钟 | 即开 |
| **隔离性** | ✅ 完全容器化 | ❌ 宿主机系统 | ✅ 容器 |
| **AI 安全性** | ✅ 沙箱保护宿主机 | ❌ AI 可访问宿主机 | ⚠️ 共享环境 |
| **离线使用** | ✅ 完全离线 | ✅ | ❌ 需要联网 |
| **数据持久化** | ✅ Docker 卷 | ✅ 本地文件 | ⚠️ 需配置 |
| **Linux 桌面** | ✅ 内置 | ❌ 无 | ❌ 无 |
| **费用** | 免费（自有硬件） | 免费 | 付费档位 |

---

## 🚀 安装方式

**📖 详细安装指南和文档，请访问 [webclaw.qhkly.com](https://webclaw.qhkly.com)**

### 方式一：下载桌面应用（最简单）⭐

不需要安装 Git 或 Node.js，只需安装 Docker Desktop 后下载应用即可。

**第一步 — 安装 Docker Desktop**（已安装可跳过）：

| 平台 | 下载地址 |
|------|---------|
| macOS | [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) |
| Windows | [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) |
| Linux | [Docker Engine](https://docs.docker.com/engine/install/) |

**第二步 — 下载 WebClaw 启动器应用**：

访问 **[webclaw.qhkly.com](https://webclaw.qhkly.com)** 下载启动器应用，或前往 [**Releases 页面**](https://github.com/land007/webclaw/releases/latest)：

| 平台 | 下载文件 |
|------|---------|
| macOS（Apple Silicon / M1 及以上） | `webclaw-launcher-osx-arm64-*.zip` |
| macOS（Intel 芯片） | `webclaw-launcher-osx-x64-*.zip` |
| Windows | `webclaw-launcher-win-x64-*.zip` |
| Linux | `webclaw-launcher-linux-x64-*.zip` |

**第三步 — 解压并运行**：

- **macOS**：解压后右键点击 `webclaw.app` → 选择**打开**（首次运行需要这样操作以绕过系统安全提示）
- **Windows**：解压后双击 `webclaw.exe`，如弹出 SmartScreen 警告，点击"仍要运行"
- **Linux**：解压后运行 `./webclaw`

应用会通过图形向导一步步引导你完成设置。

---

### 方式二：一键命令安装（终端）

**macOS / Linux**：
```bash
curl -fsSL https://raw.githubusercontent.com/land007/webclaw/main/install.sh | bash
```

**Windows**（PowerShell — **需以管理员身份运行**）：
```powershell
irm https://raw.githubusercontent.com/land007/webclaw/main/install.ps1 | iex
```

---

### 方式三：纯 Docker（服务器 / 无图形界面）

不需要图形界面。需要安装 [Docker](https://docs.docker.com/engine/install/)。

**选项 A — 极简一行命令（最简单）⚡：**

```bash
docker run -d --name webclaw -p 20000:20000 \
  --shm-size=512m --security-opt seccomp=unconfined \
  -v webclaw-config:/home/ubuntu/.webclaw \
  -v projects:/home/ubuntu/projects \
  land007/webclaw:latest
```

然后浏览器打开 **http://localhost:20000**，用 `admin` / `changeme` 登录，点击右上角 ⚙ 按钮即可配置密码、Token、Git 等所有设置。**配置自动持久化**，容器重启后依然生效。

**选项 B — 使用 docker compose（推荐，更方便管理）：**

**macOS / Linux / WSL / Git Bash：**
```bash
mkdir -p ~/webcode && cd ~/webcode
curl -fsSL https://raw.githubusercontent.com/land007/webclaw/main/launcher/assets/docker-compose.yml -o docker-compose.yml
docker compose up -d
```

**选项 C — 完整 docker run 命令（指定所有参数）：**

```bash
docker run -d \
  --name webclaw \
  --restart unless-stopped \
  -p 20000:20000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v webclaw-config:/home/ubuntu/.webclaw \
  -v dna-data:/home/ubuntu/dna \
  -v projects:/home/ubuntu/projects \
  -v vibe-kanban-data:/home/ubuntu/.local/share/vibe-kanban \
  -v code-server-data:/home/ubuntu/.code-server \
  -v user-data:/home/ubuntu/.local/share \
  -v gitconfig:/home/ubuntu/.gitconfig-vol \
  -v openclaw-data:/home/ubuntu/.openclaw \
  -v chrome-data:/home/ubuntu/.config \
  -v recordings:/home/ubuntu/recordings \
  -e MODE=desktop \
  -e AUTH_USER=admin \
  -e AUTH_PASSWORD=changeme \
  -e VNC_PASSWORD=changeme \
  -e VNC_RESOLUTION=1920x1080 \
  --shm-size=512m \
  --security-opt seccomp=unconfined \
  land007/webclaw:latest
```

**Windows PowerShell：**
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\webcode"
Set-Location "$env:USERPROFILE\webcode"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/land007/webclaw/main/launcher/assets/docker-compose.yml" -OutFile docker-compose.yml
docker compose up -d
```

---

## 🌐 访问地址

启动后，浏览器打开 **http://localhost:20000** — 这是统一入口仪表盘。

| 服务 | 地址 | 登录账号 |
|------|------|---------|
| 🏠 **仪表盘**（主入口） | **http://localhost:20000** | `admin` / `changeme` |
| 💻 IDE（code-server） | http://localhost:20001 | `admin` / `changeme` |
| 📊 Vibe Kanban | http://localhost:20002 | `admin` / `changeme` |
| 🤖 OpenClaw AI | http://localhost:20003 | `admin` / `changeme` |
| 🖥️ noVNC 桌面 | http://localhost:20004 | VNC 密码：`changeme` |
| VNC 客户端软件 | localhost:20005 | VNC 密码：`changeme` |

> 默认账号密码为 `admin` / `changeme`。点击仪表盘顶部的 **⚙ 齿轮按钮** 可修改密码、Token、Git 信息等，修改**即时生效**且持久保存，无需重启容器。

---

## 🔒 安全性与隔离

**AI 会弄坏我的电脑吗？不会！**

所有操作都在**沙箱化的 Docker 容器**里运行，你的电脑完全安全。

- ✅ **AI 碰不到你的文件** — 它只能看到容器里的文件，碰不到你的文档、照片或电脑上的任何东西
- ✅ **随便折腾没关系** — 运行任何代码、安装任何东西、把容器弄坏 — 你的真实电脑毫发无损
- ✅ **一键恢复** — 搞乱了？运行 `docker compose down -v` 几秒内即可重新开始

> 💡 打个比方：webcode 就像你真实电脑里的一台"沙盒电脑"。你可以在沙盒里为所欲为，完全不会影响你的真实电脑。

**⚠️ 关于 Docker socket（可选）**

默认 `docker-compose.yml` 挂载了 `/var/run/docker.sock`，支持容器内管理其他容器（Docker-in-Docker）。
- **大多数用户**：保持启用 — 通常需要这个功能
- **安全敏感场景**：如果运行不可信代码，可在 `docker-compose.yml` 中注释掉该行

---

## ⚙️ 配置说明

### 运行时配置面板（推荐）⭐

打开 **http://localhost:20000**，登录后点击顶部栏的 **⚙ 齿轮图标**，可修改：

- Basic Auth 用户名 / 密码
- VNC 密码
- OpenClaw API Token
- Git 用户名和邮箱
- Cloudflare Tunnel Token
- 启用 / 禁用看板和 OpenClaw 服务

修改**立即生效**（无需重启服务），并持久保存到 `webclaw-config` 数据卷，容器重启后自动恢复。

### 环境变量（docker-compose / docker run）

在 `docker-compose.yml` 同目录下创建 `.env` 文件，或通过 `docker run -e` 传入：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MODE` | `desktop` | 运行模式：`desktop`（含桌面）或 `lite`（无桌面，更轻量） |
| `AUTH_USER` | `admin` | 登录用户名 |
| `AUTH_PASSWORD` | `changeme` | 登录密码 |
| `VNC_PASSWORD` | `changeme` | VNC 桌面密码（仅 desktop 模式有效） |
| `VNC_RESOLUTION` | `1920x1080` | 桌面分辨率（仅 desktop 模式有效） |
| `OPENCLAW_GATEWAY_TOKEN` | `changeme` | Gateway token |
| `GIT_USER_NAME` | — | Git 提交用户名 |
| `GIT_USER_EMAIL` | — | Git 提交邮箱 |
| `CF_TUNNEL_TOKEN` | 空（不启用）| Cloudflare Tunnel token，设置后自动启用远程访问 |
| `ENABLE_WEBCODE_STUDIOD` | `false` | AI Studio 无头节点，见下方 |
| `AI_STUDIO_PEER_TOKEN` | 同 `AUTH_PASSWORD` | 联邦 token；留空即复用登录密码 |
| `AI_STUDIO_PEER_SCOPE` | `lan` | 接入范围：`lan` 或 `tunnel` |

> **说明：** 如果同时通过 `webclaw-config` 数据卷和环境变量设置了同一项，数据卷中的值优先（运行时修改不会被容器重启覆盖）。

### AI Studio 无头节点（`ENABLE_WEBCODE_STUDIOD`）

容器里预装了 `webcode-studiod`——WebCode AI Studio 的无头引擎。打开之后，你本机的
AI Studio 可以把这个容器当成一台**远程 Studio** 接进去：容器里的工程和会话出现在
本机侧边栏，CLI 进程实际跑在容器里。

三种镜像（lite / desktop / full）**都能用**。它装在 `Dockerfile.base` 里，
而且不链接 tauri、不依赖 X 和 WebKitGTK——这正是它和桌面版按需安装的那个
AppImage（`install-webcode-ai-studio.sh`）的区别，后者只有 desktop / full 用得上。

**不需要额外开端口。** 它监听容器内的 10010，走 dashboard-server 的统一代理
对外露出，用的还是已经映射好的 20000：

```
http://<主机>:20000/proxy/10010
```

在本机 AI Studio 里：`⋯ → 远程 Studio → 接入一台`，地址填上面这行，
token 填 `AUTH_PASSWORD`（或你自己设的 `AI_STUDIO_PEER_TOKEN`）。

```bash
ENABLE_WEBCODE_STUDIOD=true docker compose up -d
```

> **两道门，一把钥匙。** 请求要先过 dashboard-server 的鉴权，再过 studiod 自己的
> peer token，而客户端只能带一个 `Authorization` 头。所以 `AI_STUDIO_PEER_TOKEN`
> 默认就取 `AUTH_PASSWORD`。要把两者分开管，得同时让 dashboard-server 认得新
> token，否则外层先 401，请求根本到不了 studiod。

> **默认关是有意的。** 打开它等于允许外面那台 Studio 在容器里起进程、读写
> `/home/ubuntu`。另外注意：经过本地反向代理之后，studiod 那条「`/mcp` 只对
> loopback 开放」的限制对代理流量不再成立——`/proxy/10010/mcp` 同样能到达。
> 实际风险有限（`/proxy/10001/` 的 code-server 本来就等于容器内一个 shell），
> 但这意味着 **dashboard 的密码就是这条链路唯一的门**，别用默认的 `changeme`。

> **文件与 Git 权限**默认是关的，而且刻意没有环境变量入口。无头容器里要打开，
> 只能改 `AI_STUDIO_DATA_DIR/peers.json`（默认 `/home/ubuntu/.webclaw/ai-studio/peers.json`）
> 里的 `allow_files` / `allow_git`，然后重启该服务。

```bash
cp .env.example .env
# 按需修改 .env，然后：
docker compose up -d
```

---

## 🔨 从源码构建

### 🚀 快速构建（推荐 - 使用预构建基础镜像）

使用 Docker Hub 上的预构建基础镜像，配置修改后只需 5-60 秒重建：

```bash
# 拉取或确保基础镜像存在（首次运行）
docker pull land007/webclaw_base:latest

# 构建完整版（30-60 秒，使用缓存的基础镜像）
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=latest .

# 构建精简版（5-10 秒，使用缓存的基础镜像）
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=latest --build-arg INSTALL_DESKTOP=false .
```

**优势：**
- ⚡ **快速**：配置文件修改只需秒级重建
- 💾 **高效**：基础 Theia 镜像（~2GB）仅下载一次并缓存
- 🔄 **迭代**：非常适合 dashboard、配置文件、脚本的快速开发

### 🔨 完整构建（基础 + 配置层，10-15 分钟）

从零开始构建所有内容，包括基础 Theia 镜像：

```bash
# 克隆仓库
git clone https://github.com/land007/webclaw.git && cd webclaw

# 步骤 1：构建基础镜像（10-12 分钟，最慢的步骤）
docker build -f Dockerfile.base -t webcode:base-theia-local .

# 步骤 2a：构建完整版（30-60 秒）
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=local .

# 步骤 2b：或构建精简版（5-10 秒）
docker build -t webclaw:latest --build-arg WEBCLAW_BASE_VERSION=local --build-arg INSTALL_DESKTOP=false .
```

**镜像大小：** ~2.5-3 GB（完整版） / ~1-1.5 GB（精简版）

### 🌍 多架构构建（AMD64 + ARM64）

用于生产部署到 Docker Hub：

```bash
# 构建基础镜像（两种架构）
docker buildx build --platform linux/amd64,linux/arm64 \
  -f Dockerfile.base \
  -t land007/webclaw_base:latest \
  --push .

# 构建完整版
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg WEBCLAW_BASE_VERSION=latest \
  --build-arg INSTALL_DESKTOP=true \
  -t land007/webclaw:latest \
  --push .

# 构建精简版
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg WEBCLAW_BASE_VERSION=latest \
  --build-arg INSTALL_DESKTOP=false \
  -t land007/webclaw:latest \
  --push .
```

### 构建精简版（无桌面）

**精简版**仅包含 code-server、OpenClaw 和 Dashboard 代理，不包含 VNC、桌面环境、Kanban 和浏览器。

```bash
# 克隆仓库
git clone https://github.com/land007/webclaw.git && cd webclaw

# 本地构建（单架构）
docker build --build-arg INSTALL_DESKTOP=false -t webclaw:latest .

# 多架构构建（amd64 + arm64）
docker buildx build --build-arg INSTALL_DESKTOP=false --platform linux/amd64,linux/arm64 -t land007/webclaw:latest .
```

**镜像大小：** ~1-1.5 GB（比完整版小 50%）

### 版本对比

| 功能 | 完整版 | 精简版 |
|------|--------|--------|
| code-server | ✅ | ✅ |
| Vibe Kanban | ✅ | ❌ |
| OpenClaw AI | ✅ | ✅ |
| Dashboard 代理 | ✅ | ✅ |
| GNOME 桌面 | ✅ | ❌ |
| VNC/noVNC | ✅ | ❌ |
| fcitx 中文输入 | ✅ | ❌ |
| Chrome/Chromium | ✅ | ❌ |
| 镜像大小 | ~2.5-3 GB | ~1-1.5 GB |
| 适用场景 | 完整桌面体验 | 仅需轻量开发 |

---

## 🖥️ 运行模式

**Desktop 模式**（默认）— 完整 GNOME Linux 桌面，通过浏览器访问，支持中文输入（fcitx + Google 拼音）：
```bash
docker compose up -d
```

**Lite 模式** — 仅运行 code-server + OpenClaw，无桌面，资源占用更小：
```bash
MODE=lite docker compose up -d
```

---

## 🔧 常用命令

```bash
# 查看运行状态
docker compose ps

# 查看日志
docker compose logs -f

# 停止
docker compose down

# 停止并清除所有数据（慎用！）
docker compose down -v

# 重启单个服务（以 code-server 为例）
docker exec -it webclaw supervisorctl restart code-server
```

---

## 💾 数据持久化

以下数据存储在 Docker 数据卷中，容器重建后不会丢失：

| 数据卷 | 内容 |
|--------|------|
| `projects` | 你的代码（`/home/ubuntu/projects`） |
| `code-server-data` | code-server 设置与扩展 |
| `vibe-kanban-data` | Kanban 任务数据 |
| `user-data` | bash 历史记录等用户数据 |
| `openclaw-data` | OpenClaw 配置与数据 |
| `gitconfig` | Git 用户信息（`.gitconfig`） |

---

## 🤖 OpenClaw 首次初始化

首次启动后，运行以下命令完成初始化（只需一次）：
```bash
docker exec -it -u ubuntu webcode openclaw onboard
```
按提示完成配置后，刷新 http://localhost:20003 即可使用。

---

## 📖 进阶文档

| 文档 | 内容 |
|---|---|
| [远程服务器运维](docs/远程服务器运维.md) | 把容器当运维基地，用 AI 管理远程 Linux 服务器：装软件、改配置、查日志、管 Docker |
| [按需安装应用](docs/on-demand-apps.md) | 应用中心的工作方式与新增应用 |
| [剪贴板桥接](docs/clipboard-bridge.md) | 容器与宿主机剪贴板同步 |
| [代理隔离](docs/PROXY-ISOLATION.md) | 网络代理的隔离方案 |
