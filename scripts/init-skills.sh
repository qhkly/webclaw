#!/bin/bash
set -e

echo "[init-skills] Initializing common skills directory..."

# 创建公共 skills 目录
mkdir -p /home/ubuntu/skills

# 为每个工具创建软链接
for tool_dir in .claude .openclaw .codex .gemini; do
    tool_path="/home/ubuntu/$tool_dir"
    skills_link="$tool_path/skills"

    # 确保工具目录存在
    mkdir -p "$tool_path"

    # 如果软链接已存在，先删除
    if [ -L "$skills_link" ]; then
        rm "$skills_link"
    fi

    # 如果是真实目录且非空，备份
    if [ -d "$skills_link" ] && [ ! -L "$skills_link" ]; then
        if [ "$(ls -A $skills_link 2>/dev/null)" ]; then
            backup_dir="$skills_link.backup.$(date +%Y%m%d%H%M%S)"
            echo "[init-skills] Backing up existing $skills_link to $backup_dir"
            mv "$skills_link" "$backup_dir"
        else
            rm -rf "$skills_link"
        fi
    fi

    # 创建软链接
    echo "[init-skills] Creating symlink: $skills_link -> /home/ubuntu/skills"
    ln -s /home/ubuntu/skills "$skills_link"
done

# 设置权限
chown -h ubuntu:ubuntu /home/ubuntu/.claude/skills 2>/dev/null || true
chown -h ubuntu:ubuntu /home/ubuntu/.openclaw/skills 2>/dev/null || true
chown -h ubuntu:ubuntu /home/ubuntu/.codex/skills 2>/dev/null || true
chown -h ubuntu:ubuntu /home/ubuntu/.gemini/skills 2>/dev/null || true
chown ubuntu:ubuntu /home/ubuntu/skills

# ─── 个人技能云同步初始化（设置 SKILLS_REPO_URL 时启用） ──────────────
# 远程部署模式：/home/ubuntu/skills 是云端技能仓库的工作副本，
# 由 /opt/skills-sync-loop.sh 定时双向同步。本地 bind-mount 模式无需此段。
if [ -n "${SKILLS_REPO_URL:-}" ]; then
    echo "[init-skills] Initializing skills cloud sync from ${SKILLS_REPO_URL}"
    SKILLS_DIR=/home/ubuntu/skills
    BRANCH="${SKILLS_BRANCH:-main}"
    AUTH_ARGS=()
    if [ -n "${SKILLS_REPO_TOKEN:-}" ]; then
        BASIC=$(printf 'x-access-token:%s' "$SKILLS_REPO_TOKEN" | base64 | tr -d '\n')
        AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${BASIC}")
    fi
    if [ ! -d "$SKILLS_DIR/.git" ]; then
        if [ -z "$(ls -A "$SKILLS_DIR" 2>/dev/null)" ]; then
            git ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} clone -b "$BRANCH" "$SKILLS_REPO_URL" "$SKILLS_DIR" \
                || echo "[init-skills] WARN: clone failed (云端可能还是空仓库)，将由同步循环重试"
        fi
        if [ ! -d "$SKILLS_DIR/.git" ]; then
            # 目录非空或 clone 失败：原地初始化，先提交本地基线再合并云端，确保不丢文件
            git -C "$SKILLS_DIR" init
            git -C "$SKILLS_DIR" checkout -B "$BRANCH"
            git -C "$SKILLS_DIR" remote add origin "$SKILLS_REPO_URL" 2>/dev/null \
                || git -C "$SKILLS_DIR" remote set-url origin "$SKILLS_REPO_URL"
            git -C "$SKILLS_DIR" add -A
            git -C "$SKILLS_DIR" -c user.name=webclaw -c user.email=skills@webclaw.local \
                commit -m "新增: 初始化容器技能基线" >/dev/null 2>&1 || true
            git ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -C "$SKILLS_DIR" pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 || true
        fi
    fi
    # 提交身份只写入这个仓库的本地配置
    git -C "$SKILLS_DIR" config user.name "${GIT_USER_NAME:-webclaw}" 2>/dev/null || true
    git -C "$SKILLS_DIR" config user.email "${GIT_USER_EMAIL:-skills@webclaw.local}" 2>/dev/null || true
    chown -R ubuntu:ubuntu "$SKILLS_DIR"
fi

echo "[init-skills] Common skills directory initialized successfully"
