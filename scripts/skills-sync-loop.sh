#!/bin/bash
# 个人技能云同步循环：定时把 /home/ubuntu/skills 与云端技能仓库双向同步。
# 设计要点：
#   - 轮询而非 inotify watch（多容器场景 watch 会耗尽宿主机 inotify 实例）
#   - 冲突时双方版本都保留（云端版本另存 *.remote-<时间>），绝不静默覆盖
#   - 令牌只经内存注入 http header，不写入任何磁盘 git 配置
set -u

SKILLS_DIR=/home/ubuntu/skills
BRANCH="${SKILLS_BRANCH:-main}"
INTERVAL="${SKILLS_SYNC_INTERVAL:-300}"

[ -n "${SKILLS_REPO_URL:-}" ] || exit 0

AUTH_ARGS=()
if [ -n "${SKILLS_REPO_TOKEN:-}" ]; then
    BASIC=$(printf 'x-access-token:%s' "$SKILLS_REPO_TOKEN" | base64 | tr -d '\n')
    AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${BASIC}")
fi

# ${AUTH_ARGS[@]+...} 写法兼容空数组 + set -u（老版本 bash 下空数组展开会报 unbound）
g() { git ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -C "$SKILLS_DIR" "$@"; }

rebase_in_progress() {
    [ -d "$SKILLS_DIR/.git/rebase-merge" ] || [ -d "$SKILLS_DIR/.git/rebase-apply" ]
}

# pull --rebase 冲突中 index stage 2 = 云端版本，stage 3(theirs) = 本地提交。
# 云端版本另存，原路径保留本地版本。
resolve_conflicts() {
    local ts file copy
    ts=$(date +%Y%m%d-%H%M%S)
    for _ in $(seq 1 50); do
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            case "$file" in
                *.md) copy="${file%.md}.remote-${ts}.md" ;;
                *)    copy="${file}.remote-${ts}" ;;
            esac
            if git -C "$SKILLS_DIR" show ":2:${file}" > "${SKILLS_DIR}/${copy}" 2>/dev/null; then
                git -C "$SKILLS_DIR" add -- "$copy" 2>/dev/null || true
            else
                rm -f "${SKILLS_DIR}/${copy}"
            fi
            git -C "$SKILLS_DIR" checkout --theirs -- "$file" 2>/dev/null \
                || git -C "$SKILLS_DIR" checkout --ours -- "$file" 2>/dev/null || true
            git -C "$SKILLS_DIR" add -- "$file" 2>/dev/null || true
        done < <(git -C "$SKILLS_DIR" diff --name-only --diff-filter=U)
        GIT_EDITOR=true git -C "$SKILLS_DIR" rebase --continue >/dev/null 2>&1 || true
        rebase_in_progress || return 0
    done
    git -C "$SKILLS_DIR" rebase --abort >/dev/null 2>&1 || true
    echo "[skills-sync] 冲突未能自动合并，本轮跳过（本地内容未受影响）"
    return 1
}

sync_once() {
    [ -d "$SKILLS_DIR/.git" ] || return 0
    git -C "$SKILLS_DIR" add -A >/dev/null 2>&1 || true
    if ! git -C "$SKILLS_DIR" diff --cached --quiet 2>/dev/null; then
        git -C "$SKILLS_DIR" commit -m "新增: 容器同步个人技能 $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1 || true
    fi
    if ! g pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1; then
        if rebase_in_progress; then
            resolve_conflicts || return 0
        fi
        # 云端空仓库 / 网络抖动：留给下一轮重试
    fi
    g push origin "$BRANCH" >/dev/null 2>&1 || true
}

echo "[skills-sync] 启动云同步循环（每 ${INTERVAL}s 一次）"
while true; do
    sync_once
    sleep "$INTERVAL"
done
