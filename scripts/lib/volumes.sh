#!/usr/bin/env bash

# Keep this list in sync with the top-level volumes in docker-compose.yml.
WEBCLAW_VOLUME_NAMES=(
    skills-data
    dna-data
    projects
    obsidian-data
    vibe-kanban-data
    code-server-data
    user-data
    openclaw-data
    dsh-data
    chrome-data
    v2rayn-data
    gitconfig
    recordings
    webclaw-config
    ssh-data
    servers-data
    ai-studio-data
)

webclaw_volume_prefix() {
    if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
        printf '%s_' "$COMPOSE_PROJECT_NAME"
        return
    fi

    local dna_volume
    dna_volume="$(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | awk '/_dna-data$/ { print; exit }')"
    if [ -n "$dna_volume" ]; then
        printf '%s' "${dna_volume%dna-data}"
    else
        printf '%s' 'webclaw-docker_'
    fi
}

webclaw_volumes() {
    local prefix name
    prefix="$(webclaw_volume_prefix)"
    for name in "${WEBCLAW_VOLUME_NAMES[@]}"; do
        printf '%s%s\n' "$prefix" "$name"
    done
}
