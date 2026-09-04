# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**WebClaw** is an OpenClaw-first Docker runtime that provides:
- A full GNOME Flashback desktop accessible via VNC/noVNC (browser)
- code-server (browser-based VS Code) on port 10001
- Vibe Kanban (task board) on port 10002
- OpenClaw (self-hosted AI assistant gateway) on port 10003
- noVNC web client on port 10004, TigerVNC on port 10005
- Chinese input support (fcitx + Google Pinyin)
- Docker-in-Docker capability (Docker CLI inside container)

**Port Architecture:**
- **10001-10006**: Internal application ports (actual app listeners)
- **20001-20004**: External access ports via `webclaw-dashboard-server` proxy (with Basic Auth)
- **11001-11004**: Launcher proxy ports (desktop app internal use, no auth)

## Running the Environment

```bash
# Start with desktop mode (default)
docker compose up -d

# Start with lite mode (no VNC desktop, just code-server + OpenClaw)
MODE=lite docker compose up -d

# Custom VNC password and resolution
VNC_PASSWORD=mypassword VNC_RESOLUTION=1280x720 docker compose up -d

# Custom Basic Auth credentials
AUTH_USER=myuser AUTH_PASSWORD=mypassword docker compose up -d
```

**Access points (as configured in docker-compose.yml):**
- code-server: http://localhost:20001 (Basic Auth)
- Vibe Kanban: http://localhost:20002 (Basic Auth)
- OpenClaw gateway: http://localhost:20003 (Basic Auth)
- noVNC browser client: http://localhost:20004 (VNC password)
- VNC client: localhost:20005 (VNC password: `changeme`)

Default Basic Auth credentials: `admin` / `changeme` (configurable via `AUTH_USER` / `AUTH_PASSWORD`)

## Building the Docker Image

### Desktop Version

```bash
# Local build (single architecture, matches your host)
docker build -t webclaw .

# Multi-arch build (amd64 + arm64, matches CI)
docker buildx build --platform linux/amd64,linux/arm64 -t land007/webclaw:latest .

# Multi-arch build with push to registry
docker buildx build --platform linux/amd64,linux/arm64 -t land007/webclaw:latest --push .
```

**Desktop version includes:** GNOME desktop, VNC/noVNC, fcitx Chinese input, Chrome/Chromium browser, code-server, and OpenClaw.

**Image size:** ~2.5-3 GB

### Lite Version (without Desktop)

```bash
# Local build (single architecture)
docker build --build-arg INSTALL_DESKTOP=false -t webclaw:latest .

# Multi-arch build (amd64 + arm64)
docker buildx build --build-arg INSTALL_DESKTOP=false --platform linux/amd64,linux/arm64 -t land007/webclaw:latest .

# Multi-arch build with push
docker buildx build --build-arg INSTALL_DESKTOP=false --platform linux/amd64,linux/arm64 -t land007/webclaw:latest --push .
```

**Lite version includes:** code-server, Vibe Kanban, OpenClaw, Dashboard proxy. **No** VNC, GNOME desktop, fcitx, or browser.

**Image size:** ~1-1.5 GB (50% smaller than full version)

## Architecture

### Dockerfile Layer Order (optimized for cache hits)
1. Base system (locale, sudo, CLI tools)
2. Node.js 22.x
3. **code-server binary download** — cached unless `CODE_SERVER_VERSION` changes
4. Supervisor and shared runtime tools
5. GNOME Flashback, VNC/noVNC, and input methods (desktop variant only)
6. Docker CLI and browser
7. Runtime config and scripts

### Startup Modes (`scripts/startup.sh`)
- **desktop mode**: Runs GNOME via `supervisord.conf` (includes xvnc, desktop, noVNC, code-server, OpenClaw, dashboard)
- **lite mode**: Runs only code-server + OpenClaw + Dashboard via `supervisord-lite.conf` (no VNC/desktop overhead)

### Authentication Architecture
The `webclaw-dashboard-server` Node.js process acts as a unified authentication and proxy gateway:
- **Port 20000**: Dashboard UI with Basic Auth
- **Port 20001**: code-server proxy (Basic Auth → 127.0.0.1:10001)
- **Port 20002**: Vibe Kanban proxy (Basic Auth → 127.0.0.1:10002)
- **Port 20003**: OpenClaw proxy (Bearer token → 127.0.0.1:10003)
- **Port 20004**: noVNC proxy (Basic Auth + path-based routing for /audio, /websockify)

Internal services bind to `127.0.0.1` only. The dashboard proxy listens on `0.0.0.0` and injects authentication headers. noVNC/VNC retain their own VNC password authentication.

### Key Config Files
| File | Purpose |
|------|---------|
| `configs/supervisord.conf` | Main supervisor config (desktop mode) |
| `configs/supervisord-lite.conf` | Lite mode supervisor config |
| `configs/supervisor-code-server.conf` | code-server process (port 10001) |
| `configs/supervisor-vibe-kanban.conf` | Vibe Kanban process (port 10002) |
| `configs/supervisor-openclaw.conf` | OpenClaw gateway process (port 10003, launched via npx) |
| `webclaw-dashboard-server@latest` | Dashboard + proxy server package (ports 20000-20004, handles authentication) |
| `configs/supervisor-dashboard.conf` | Dashboard process configuration |
| `configs/supervisord.conf` | Main supervisor config, includes noVNC (port 10004) and TigerVNC (port 10005) |
| `configs/xsession` | GNOME Flashback session startup script |
| `configs/desktop-shortcuts/` | `.desktop` files for Chrome, code-server, Vibe Kanban on desktop |

### Persistent Volumes (docker-compose.yml)
- `dna-data` → `/home/ubuntu/dna` — project source (DNA); auto-cloned from `DNA_REPO_URL` on first start
- `projects` → `/home/ubuntu/projects` — user code
- `code-server-data` → `/home/ubuntu/.local/share/code-server` — code-server data
- `vibe-kanban-data` → `/home/ubuntu/.local/share/vibe-kanban`
- `user-data` → `/home/ubuntu/.local/share` — includes bash history
- `openclaw-data` → `/home/ubuntu/.openclaw` — OpenClaw config and data
- `gitconfig` → `/home/ubuntu/.gitconfig-vol` — git identity (symlinked to `~/.gitconfig` at startup)
- `/var/run/docker.sock` — Docker socket passthrough

### Self-Evolution / DNA Ecosystem

The container supports a self-evolution model where the AI inside can modify its own source code and spawn new container variants:

- **`/home/ubuntu/dna`** — the robot's DNA: full project source (Dockerfile, configs, scripts). Backed by the `dna-data` named volume so it persists across restarts.
- On startup, `scripts/startup.sh` checks if `/home/ubuntu/dna` is empty and auto-clones from `DNA_REPO_URL`.
- The mounted `/var/run/docker.sock` allows the robot to run `docker build` and `docker run` inside the container, targeting the host Docker daemon.

**Evolution workflow (inside container):**
```bash
# 1. Modify DNA
vim /home/ubuntu/dna/Dockerfile

# 2. Build evolved image
docker build -t webclaw-evolved /home/ubuntu/dna/

# 3. Spawn child robot
docker run -d ... webclaw-evolved

# 4. Contribute back
cd /home/ubuntu/dna && git commit && git push && gh pr create
```

**`DNA_REPO_URL` environment variable** — specifies the git repository to clone as DNA. Defaults to `https://github.com/land007/webcode`. Set to a fork URL to create an independent evolutionary branch:

```bash
DNA_REPO_URL=https://github.com/your-fork/webcode docker compose up -d
```

The ecosystem design: forks evolve independently, and robots can submit PRs back to `land007/webcode`, merging evolutionary improvements into the shared gene pool.

## CI/CD

GitHub Actions (`.github/workflows/`) builds and pushes multi-arch images (`linux/amd64`, `linux/arm64`) to Docker Hub and GitHub Container Registry for `v*` tags. Requires `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets.

## Important Notes

- code-server is installed at `/opt/code-server`.
- When modifying the Dockerfile, keep config file `COPY` instructions near the end to maximize layer cache reuse for the code-server download step.
- OpenClaw and Vibe Kanban are both launched via `npx` at runtime (not pre-installed in the image), so first startup may take longer while packages are fetched. Run `docker exec -it -u ubuntu webcode openclaw onboard` to complete OpenClaw initial configuration.

## Git Commit Message Convention

**All commit messages MUST be written in Chinese.**

When creating commits, follow these guidelines:

- Use clear, descriptive Chinese to explain the change
- Format: `<类型>: <简短描述>` where 类型 can be:
  - `新增`: 添加新功能
  - `修复`: 修复bug
  - `优化`: 性能或代码质量优化
  - `重构`: 代码重构
  - `文档`: 文档更新
  - `配置`: 配置修改

Examples:
```
新增: 添加 code-server 中文语言包支持
修复: 解决 dashboard server 代理跨域问题
优化: 缩小 Docker 镜像大小，移除不必要的依赖
配置: 更新 docker-compose.yml 端口映射
```

Co-authored-by attribution should still use English format:
```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```
