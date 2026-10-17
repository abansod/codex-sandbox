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
printf '%q ' "$@" >> "$TEST_PODMAN_LOG"
printf '\n' >> "$TEST_PODMAN_LOG"
if [[ "$1" == volume ]]; then
  case "$2" in
    create)
      volume="${!#}"
      mkdir -p "$TEST_PODMAN_STORE/$volume"
      for arg in "$@"; do
        if [[ "$arg" == io.codex-sandbox.project-home=true ]]; then
          touch "$TEST_PODMAN_STORE/$volume/managed"
        fi
        if [[ "$arg" == io.codex-sandbox.project=* ]]; then
          printf '%s\n' "${arg#*=}" > "$TEST_PODMAN_STORE/$volume/project"
        fi
      done
      ;;
    inspect)
      volume="${!#}"
      [[ -d "$TEST_PODMAN_STORE/$volume" ]] || exit 1
      if [[ "$4" == *project-home* ]]; then
        if [[ -f "$TEST_PODMAN_STORE/$volume/managed" ]]; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
      else
        cat "$TEST_PODMAN_STORE/$volume/project"
      fi
      ;;
    ls)
      for directory in "$TEST_PODMAN_STORE"/codex-project-*; do
        [[ -f "$directory/managed" ]] || continue
        printf '%s\n' "${directory##*/}"
      done
      ;;
    rm)
      [[ "${3:-}" != "${TEST_IN_USE:-}" ]] || exit 1
      rm -r -- "$TEST_PODMAN_STORE/$3"
      ;;
  esac
  exit 0
fi
if [[ "$1" == ps ]]; then
  [[ "${TEST_PS_FAIL:-}" != 1 ]] || exit 1
  [[ "${!#}" != "volume=${TEST_IN_USE:-}" ]] || printf 'active-container\n'
  exit 0
fi
[[ "$1" == run ]] || exit 0
if [[ " $* " == *' /state:'* || " $* " == *':/state:ro,nocopy '* ]]; then
  printf 'Size: 4K\nLast session started (UTC): 2026-10-16T00:00:00Z\n'
  exit 0
fi
printf '%s\n' "$@" > "$TEST_RUN_ARGS"
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
export TEST_PODMAN_LOG="$test_dir/podman.log" TEST_PODMAN_STORE="$test_dir/volumes"
export TEST_RUN_ARGS="$test_dir/run.args"
mkdir -p "$TEST_PODMAN_STORE"
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

home_volume() {
  sed -n 's|:/home/codexuser:rw,nocopy$||p' "$TEST_RUN_ARGS"
}
check_workdir "$HOME/projects/mac-cleaner" /workspace/mac-cleaner
first_home=$(home_volume)
check_workdir "$HOME/projects/mac-cleaner/src" /workspace/mac-cleaner/src
[[ "$(home_volume)" == "$first_home" ]]
check_workdir "$test_dir/inside-link" /workspace/mac-cleaner
[[ "$(home_volume)" == "$first_home" ]]
check_workdir "$HOME/projects/app [demo]" '/workspace/app [demo]'
second_home=$(home_volume)
[[ "$second_home" != "$first_home" ]]
PROJECT_DIR="$HOME/projects/mac-cleaner" check_workdir "$HOME/projects/mac-cleaner/src" /workspace/src
[[ "$(home_volume)" == "$first_home" ]]
grep -q '^--rm$' "$TEST_RUN_ARGS"
grep -q '^--read-only$' "$TEST_RUN_ARGS"
grep -q '^NPM_CONFIG_PREFIX=/home/codexuser/.local$' "$TEST_RUN_ARGS"
grep -q '^PATH=/home/codexuser/.local/bin:/home/codexuser/.cargo/bin:' "$TEST_RUN_ARGS"
grep -q '^sandbox_workspace_write.writable_roots=.*.local.*.npm.*.cargo.*.cache' "$TEST_RUN_ARGS"
! grep -q '^/home/codexuser:rw,nosuid' "$TEST_RUN_ARGS"

# State commands work without SSH setup or a project directory and preserve
# credentials, referenced volumes, and anything outside the managed namespace.
SSH_MODE=invalid PROJECT_DIR=/nonexistent bash "$repo_dir/codex-sandbox.sh" state list > "$test_dir/list"
grep -Fq "$first_home" "$test_dir/list"
grep -Fq "$HOME/projects/mac-cleaner" "$test_dir/list"
grep -q 'Size: 4K' "$test_dir/list"
printf 'no\n' | bash "$repo_dir/codex-sandbox.sh" state remove "$second_home" > /dev/null
[[ -d "$TEST_PODMAN_STORE/$second_home" ]]
printf 'yes\n' | TEST_IN_USE="$first_home" bash "$repo_dir/codex-sandbox.sh" state remove "$first_home" > /dev/null
[[ -d "$TEST_PODMAN_STORE/$first_home" ]]
printf 'yes\n' | bash "$repo_dir/codex-sandbox.sh" state remove "$second_home" > /dev/null
[[ ! -d "$TEST_PODMAN_STORE/$second_home" ]]
if bash "$repo_dir/codex-sandbox.sh" state remove codex-home > /dev/null 2>&1; then
  printf 'FAIL: accepted credentials volume for removal\n' >&2
  exit 1
fi
if CODEX_VOLUME="$first_home" bash "$repo_dir/codex-sandbox.sh" state remove "$first_home" > /dev/null 2>&1; then
  printf 'FAIL: accepted configured settings volume for removal\n' >&2
  exit 1
fi
unmanaged_home="codex-project-$(printf '%064d' 0)"
mkdir "$TEST_PODMAN_STORE/$unmanaged_home"
if bash "$repo_dir/codex-sandbox.sh" state remove "$unmanaged_home" > /dev/null 2>&1; then
  printf 'FAIL: accepted an unlabeled volume for removal\n' >&2
  exit 1
fi
if TEST_PS_FAIL=1 bash "$repo_dir/codex-sandbox.sh" state prune > /dev/null 2>&1; then
  printf 'FAIL: ignored failure to check container references\n' >&2
  exit 1
fi
bash "$repo_dir/codex-sandbox.sh" state prune < /dev/null > /dev/null
[[ -d "$TEST_PODMAN_STORE/$first_home" ]]
printf 'yes\n' | TEST_IN_USE="$first_home" bash "$repo_dir/codex-sandbox.sh" state prune > /dev/null
[[ -d "$TEST_PODMAN_STORE/$first_home" ]]
[[ -d "$TEST_PODMAN_STORE/$unmanaged_home" ]]
[[ "$(find "$TEST_PODMAN_STORE" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]]
printf 'Project home and state cleanup checks passed.\n'
