#!/usr/bin/env bash
set -Eeuo pipefail

# Verify real volume ownership and an offline npm installation across sessions.
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir=$(mktemp -d)
test_dir="$(cd -- "$test_dir" && pwd -P)"
export PROJECT_DIR="$test_dir/project" SSH_MODE=none
export CODEX_VOLUME="codex-state-test-${test_dir##*/}"
mkdir -p "$PROJECT_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  project_hash=$(printf '%s' "$PROJECT_DIR" | sha256sum)
else
  project_hash=$(printf '%s' "$PROJECT_DIR" | shasum -a 256)
fi
project_home="codex-project-${project_hash%% *}"
cleanup() {
  podman volume rm "$project_home" "$CODEX_VOLUME" >/dev/null 2>&1 || true
  rm -rf -- "$test_dir"
}
trap cleanup EXIT

bash "$repo_dir/codex-sandbox.sh" --version
home_args=(run --rm --read-only --network none --user 10001:10001
  --security-opt no-new-privileges --security-opt label=disable
  --tmpfs /tmp:rw,nosuid,nodev,size=128m
  --entrypoint /bin/sh
  -v "$project_home:/home/codexuser:rw,nocopy"
  -v "$CODEX_VOLUME:/home/codexuser/.codex:rw"
  -e NPM_CONFIG_PREFIX=/home/codexuser/.local
  -e 'PATH=/home/codexuser/.local/bin:/home/codexuser/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
[[ -z "${PLATFORM:-}" ]] || home_args+=(--platform "$PLATFORM")
podman "${home_args[@]}" "${IMAGE_NAME:-codex-local:latest}" -ec '
  test "$(stat -c %u "$HOME")" = 10001
  test "$(stat -c %a "$HOME")" = 700
  test -s "$HOME/.codex-sandbox-last-used"
  mkdir -p "$HOME/fixture"
  cd "$HOME/fixture"
  printf '\''{"name":"sandbox-state-fixture","version":"1.0.0","bin":{"saved-tool":"cli.js"}}\n'\'' > package.json
  printf '\''#!/usr/bin/env node\nconsole.log("saved tool works");\n'\'' > cli.js
  npm pack --offline --ignore-scripts
  npm install --global --offline --ignore-scripts --no-audit --no-fund ./sandbox-state-fixture-1.0.0.tgz
  saved-tool
  printf "saved settings\n" > "$CODEX_HOME/state-check"
  printf "saved cargo cache\n" > "$HOME/.cargo/state-check"
'

# A new launcher session must reuse the home and the separate Codex volume.
bash "$repo_dir/codex-sandbox.sh" --version
podman "${home_args[@]}" "${IMAGE_NAME:-codex-local:latest}" -ec '
  test "$(saved-tool)" = "saved tool works"
  bash -lc '\''test "$(saved-tool)" = "saved tool works"'\''
  test "$(cat "$CODEX_HOME/state-check")" = "saved settings"
  test "$(cat "$HOME/.cargo/state-check")" = "saved cargo cache"
  test -d "$HOME/.npm"
'
printf 'Project home persistence checks passed.\n'
