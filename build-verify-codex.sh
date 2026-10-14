#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${IMAGE_NAME:-codex-local:latest}"
PLATFORM="${PLATFORM:-linux/arm64}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR}"
CONTAINERFILE="${CONTAINERFILE:-$BUILD_DIR/Containerfile}"

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || error 'Podman is not installed or not on PATH.'
podman info >/dev/null 2>&1 || error 'Podman is not running. Try: podman machine start'
[[ -f "$CONTAINERFILE" ]] || error "Containerfile not found: $CONTAINERFILE"

printf '\n==> Building %s (%s)\n' "$IMAGE_NAME" "$PLATFORM"
# CRITICAL FIX 1: Pass SYS_ADMIN capability to the build engine so internal Bubblewrap installations can map devpts
podman build \
  --pull=always \
  --platform "$PLATFORM" \
  --cap-add=SYS_ADMIN \
  -t "$IMAGE_NAME" \
  -f "$CONTAINERFILE" \
  "$BUILD_DIR"

printf '\n==> Verifying Codex CLI\n'
podman run --rm --platform "$PLATFORM" "$IMAGE_NAME" --version

printf '\n==> Verifying non-root user and essential tools\n'
# CRITICAL FIX 2: Added --cap-add=SYS_ADMIN, --device /dev/ptmx, and --security-opt unmask=ALL to the test block
# This permits the test runtime shell to cleanly handle nested namespace calls
podman run --rm \
  --platform "$PLATFORM" \
  --entrypoint /bin/sh \
  --cap-add=SYS_ADMIN \
  --device /dev/ptmx \
  --security-opt unmask=ALL \
  "$IMAGE_NAME" -ec '
  test "$(id -u)" != 0
  test "$HOME" = /home/codexuser
  test "$CODEX_HOME" = /home/codexuser/.codex
  command -v codex
  command -v node
  command -v git
  command -v ssh
  command -v rg
  printf "User: %s (UID %s)\n" "$(id -un)" "$(id -u)"
  printf "Node: %s\n" "$(node --version)"
  printf "Git: %s\n" "$(git --version)"
'

printf '\nSUCCESS: %s built and verified.\n' "$IMAGE_NAME"
