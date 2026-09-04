#!/usr/bin/env bash
# Static regression checks for on-demand application manifests and installers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$ROOT_DIR/configs/on-demand-apps"
LAUNCHER="$ROOT_DIR/scripts/webclaw-app-launcher.sh"
PREINSTALL="$ROOT_DIR/scripts/preinstall-on-demand.sh"
KNOWN_METHODS=(apt github_release appimage direct_download cursor_api custom_script tarball r2_download)
failures=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

command -v jq >/dev/null || { echo 'FAIL: jq is required' >&2; exit 1; }

manifest_count=0
for manifest in "$MANIFEST_DIR"/*.json; do
    manifest_count=$((manifest_count + 1))
    if ! jq -e . "$manifest" >/dev/null; then
        fail "$(basename "$manifest"): invalid JSON"
        continue
    fi
    for field in id name binary install_method; do
        jq -e --arg field "$field" '.[$field] | strings | length > 0' "$manifest" >/dev/null \
            || fail "$(basename "$manifest"): missing required field $field"
    done
    method="$(jq -r '.install_method // empty' "$manifest")"
    if [ -n "$method" ] && ! printf '%s\n' "${KNOWN_METHODS[@]}" | grep -qx "$method"; then
        fail "$(basename "$manifest"): unsupported install_method $method"
    fi
    for field in icon install_script install_wrapper uninstall_script; do
        path="$(jq -r --arg field "$field" '.[$field] // empty' "$manifest")"
        [ -z "$path" ] && continue
        case "$path" in
            /opt/on-demand-icons/*) repo_path="$ROOT_DIR/configs/on-demand-icons/${path##*/}" ;;
            /opt/desktop-icons/*) repo_path="$ROOT_DIR/configs/desktop-icons/${path##*/}" ;;
            /opt/*.sh) repo_path="$ROOT_DIR/configs/${path##*/}"; [ -e "$repo_path" ] || repo_path="$ROOT_DIR/scripts/${path##*/}" ;;
            *) continue ;;
        esac
        [ -e "$repo_path" ] || fail "$(basename "$manifest"): $field target missing: $path"
    done
done

launcher_methods=()
preinstall_methods=()
for method in "${KNOWN_METHODS[@]}"; do
    grep -Eq "^[[:space:]]*$method\\)" "$LAUNCHER" && launcher_methods+=("$method")
    grep -Eq "^[[:space:]]*$method\\)" "$PREINSTALL" && preinstall_methods+=("$method")
done

launcher_set="$(printf '%s\n' "${launcher_methods[@]}" | sort)"
preinstall_set="$(printf '%s\n' "${preinstall_methods[@]}" | sort)"
if [ "$launcher_set" != "$preinstall_set" ]; then
    fail "launcher/preinstall install_method sets differ"
    diff -u <(printf '%s\n' "$launcher_set") <(printf '%s\n' "$preinstall_set") || true
fi

if [ "$failures" -gt 0 ]; then
    printf '%d manifest(s) checked; %d failure(s)\n' "$manifest_count" "$failures" >&2
    exit 1
fi
printf 'PASS: %d manifests; installer methods: %s\n' "$manifest_count" "${launcher_methods[*]}"
