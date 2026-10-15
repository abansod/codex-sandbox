#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the real launcher with disposable host paths and a fake Podman.
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home/projects/mac-cleaner/src" \
  "$test_dir/home/projects/app [demo]" "$test_dir/home/projects-other" \
  "$test_dir/outside"
ln -s "$test_dir/home/projects/mac-cleaner" "$test_dir/inside-link"
ln -s "$test_dir/outside" "$test_dir/home/projects/outside-link"
cat > "$test_dir/bin/podman" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == run ]] || exit 0
while (( $# )); do
  if [[ "$1" == -w ]]; then
    printf '%s\n' "$2"
    exit 0
  fi
  shift
done
exit 1
MOCK
chmod +x "$test_dir/bin/podman"
export PATH="$test_dir/bin:$PATH" HOME="$test_dir/home" SSH_MODE=none
unset PROJECT_DIR

check_workdir() {
  local directory="$1" expected="$2" actual
  actual=$(cd -- "$directory" && bash "$repo_dir/codex-sandbox.sh" --version)
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$directory" "$expected" "$actual" >&2
    exit 1
  fi
}

check_workdir "$HOME/projects" /workspace
check_workdir "$HOME/projects/mac-cleaner" /workspace/mac-cleaner
check_workdir "$HOME/projects/mac-cleaner/src" /workspace/mac-cleaner/src
check_workdir "$HOME/projects/app [demo]" '/workspace/app [demo]'
check_workdir "$HOME/projects-other" /workspace
check_workdir "$test_dir/outside" /workspace
check_workdir "$test_dir/inside-link" /workspace/mac-cleaner
check_workdir "$HOME/projects/outside-link" /workspace
PROJECT_DIR="$HOME/projects/" check_workdir "$HOME/projects/mac-cleaner" /workspace/mac-cleaner
PROJECT_DIR="$test_dir/inside-link" check_workdir "$HOME/projects/mac-cleaner/src" /workspace/src
PROJECT_DIR=.. check_workdir "$HOME/projects/mac-cleaner/src" /workspace/src
PROJECT_DIR=/ check_workdir /tmp /workspace/tmp
printf 'Launcher working-directory checks passed.\n'
