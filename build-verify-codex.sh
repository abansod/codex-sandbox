#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${IMAGE_NAME:-codex-local:latest}"
if [[ -z "${PLATFORM:-}" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) PLATFORM=linux/arm64 ;;
    x86_64|amd64) PLATFORM=linux/amd64 ;;
    *) printf 'Set PLATFORM for this architecture.\n' >&2; exit 1 ;;
  esac
fi
CODEX_VERSION="${CODEX_VERSION:-latest}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR}"
CONTAINERFILE="${CONTAINERFILE:-$BUILD_DIR/Containerfile}"

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || error 'Podman is not installed or not on PATH.'
podman info >/dev/null 2>&1 || error 'Podman is not running. Try: podman machine start'
[[ -f "$CONTAINERFILE" ]] || error "Containerfile not found: $CONTAINERFILE"

printf '\n==> Building %s (%s)\n' "$IMAGE_NAME" "$PLATFORM"
# Preserve the namespace capability required by the existing build setup.
podman build \
  --pull=always \
  --platform "$PLATFORM" \
  --cap-add=SYS_ADMIN \
  --build-arg "CODEX_VERSION=$CODEX_VERSION" \
  -t "$IMAGE_NAME" \
  -f "$CONTAINERFILE" \
  "$BUILD_DIR"

printf '\n==> Verifying Codex CLI\n'
podman run --rm --platform "$PLATFORM" "$IMAGE_NAME" --version

printf '\n==> Verifying non-root user and essential tools\n'
# Verify tools with the launcher's read-only filesystem and non-root user.
podman run --rm \
  --platform "$PLATFORM" \
  --entrypoint /bin/sh \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --tmpfs /home/codexuser:rw,nosuid,nodev,size=512m,mode=1777 \
  --user 10001:10001 \
  --security-opt no-new-privileges \
  "$IMAGE_NAME" -ec '
  test "$(id -u)" != 0
  test "$HOME" = /home/codexuser
  test "$CODEX_HOME" = /home/codexuser/.codex
  touch "$HOME/.write-check"
  rm "$HOME/.write-check"
  command -v codex
  command -v node
  command -v npm
  command -v tsc
  command -v git
  command -v ssh
  command -v rg
  command -v rustc
  command -v cargo
  printf "User: %s (UID %s)\n" "$(id -un)" "$(id -u)"
  printf "Node: %s\n" "$(node --version)"
  printf "npm: %s\n" "$(npm --version)"
  printf "TypeScript: %s\n" "$(tsc --version)"
  printf "Git: %s\n" "$(git --version)"
  printf "Rust: %s\n" "$(rustc --version)"
  printf "Cargo: %s\n" "$(cargo --version)"
  rust_check_dir=$(mktemp -d)
  trap '\''rm -rf "$rust_check_dir"'\'' EXIT
  cargo new --bin --vcs none "$rust_check_dir/rust-check"
  cargo run --offline --manifest-path "$rust_check_dir/rust-check/Cargo.toml"
  mkdir "$rust_check_dir/typescript-check"
  cd "$rust_check_dir/typescript-check"
  npm init --yes
  printf '\''const message: string = "TypeScript works"; console.log(message);\n'\'' > index.ts
  tsc --strict index.ts
  test "$(node index.js)" = "TypeScript works"
'

printf '\n==> Verifying project home persistence\n'
IMAGE_NAME="$IMAGE_NAME" PLATFORM="$PLATFORM" bash "$SCRIPT_DIR/tests/test-project-home.sh"

printf '\nSUCCESS: %s built and verified.\n' "$IMAGE_NAME"
