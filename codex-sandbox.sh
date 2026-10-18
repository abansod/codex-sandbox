#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${IMAGE_NAME:-codex-local:latest}"
CODEX_VOLUME="${CODEX_VOLUME:-codex-home}"
project_dir_explicit="${PROJECT_DIR+x}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/projects}"
SECRETIVE_SOCK="${SECRETIVE_SOCK:-$HOME/.secretive/ssh-agent.sock}"
SSH_MODE="${SSH_MODE:-secretive}"
PODMAN_MACHINE="${PODMAN_MACHINE:-podman-machine-default}"
MEMORY="${MEMORY:-8g}"
CPUS="${CPUS:-4}"

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || error 'Podman is not installed or not on PATH.'
podman info >/dev/null 2>&1 || error 'Podman is not running. Try: podman machine start'

state_label=io.codex-sandbox.project-home
project_label=io.codex-sandbox.project

state_in_use() {
  local containers
  containers=$(podman ps --all --quiet --filter "volume=$1") || return 2
  [[ -n "$containers" ]]
}

state_managed() {
  [[ "$1" =~ ^codex-project-[a-f0-9]{64}$ ]] || error "Not a project home volume name: $1"
  [[ "$1" != "$CODEX_VOLUME" ]] || error 'Refusing to remove the Codex settings volume.'
  local managed
  managed=$(podman volume inspect --format "{{ index .Labels \"$state_label\" }}" "$1")
  [[ "$managed" == true ]] || error "Not a managed project home: $1"
}

state_details() {
  local volume="$1" project
  project=$(podman volume inspect --format "{{ index .Labels \"$project_label\" }}" "$volume")
  printf '\nVolume: %s\nProject: %s\n' "$volume" "$project"
  # Read metadata inside the engine, including when Podman runs in a remote VM.
  podman run --rm --pull=never --network none --read-only --cap-drop all \
    --security-opt no-new-privileges --security-opt label=disable \
    --user 10001:10001 --entrypoint /bin/sh \
    -v "$volume:/state:ro,nocopy" "$IMAGE_NAME" -ec '
    printf "Size: "
    du -sh /state | cut -f1
    printf "Last session started (UTC): "
    if [ -f /state/.codex-sandbox-last-used ]; then
      cat /state/.codex-sandbox-last-used
    else
      printf "unknown\n"
    fi
  '
}

state_command() {
  local action="${1:-list}" volume status answer volumes
  local candidates=()
  (( $# == 0 )) || shift
  case "$action" in
    list|prune)
      (( $# == 0 )) || error "Usage: codex-sandbox state $action"
      volumes=$(podman volume ls --quiet --filter "label=$state_label=true")
      if [[ -z "$volumes" && "$action" == list ]]; then
        printf 'No saved project homes.\n'
      fi
      while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        [[ "$volume" != "$CODEX_VOLUME" ]] || continue
        state_managed "$volume"
        if state_in_use "$volume"; then
          if [[ "$action" == list ]]; then
            state_details "$volume"
            printf 'Status: referenced by a container\n'
          fi
        else
          status=$?
          (( status == 1 )) || error 'Could not check container references.'
          candidates+=("$volume")
          state_details "$volume"
          printf 'Status: unused\n'
        fi
      done <<< "$volumes"
      [[ "$action" != list ]] || return 0
      ;;
    remove)
      (( $# == 1 )) || error 'Usage: codex-sandbox state remove VOLUME'
      volume="$1"
      state_managed "$volume"
      state_details "$volume"
      candidates+=("$volume")
      ;;
    *) error 'Usage: codex-sandbox state {list|remove VOLUME|prune}' ;;
  esac
  if (( ${#candidates[@]} == 0 )); then
    printf 'No unused project homes to remove.\n'
    return 0
  fi
  printf '\nDelete these %s project home(s), including installed tools and configuration?\n' "${#candidates[@]}"
  printf '  %s\n' "${candidates[@]}"
  printf 'Type yes to delete: '
  if ! IFS= read -r answer || [[ "$answer" != yes ]]; then
    printf 'Cancelled.\n'
    return 0
  fi
  for volume in "${candidates[@]}"; do
    state_managed "$volume"
    if state_in_use "$volume"; then
      printf 'Skipping referenced project home: %s\n' "$volume"
      continue
    else
      status=$?
      (( status == 1 )) || error 'Could not check container references.'
    fi
    # Never force removal: Podman also checks for references at deletion time.
    podman volume rm "$volume"
  done
}

if [[ "${1:-}" == state ]]; then
  shift
  state_command "$@"
  exit 0
fi

podman image exists "$IMAGE_NAME" || error "Image not found: $IMAGE_NAME. Run build-verify-codex.sh first."
[[ "$SSH_MODE" == secretive || "$SSH_MODE" == none ]] || error 'SSH_MODE must be secretive or none.'
if [[ "$SSH_MODE" == secretive ]]; then
  command -v ssh >/dev/null 2>&1 || error 'OpenSSH is required for Secretive forwarding.'
  [[ -S "$SECRETIVE_SOCK" ]] || error "Secretive socket not found: $SECRETIVE_SOCK. Open the Secretive app."
fi
mkdir -p -- "$PROJECT_DIR"
PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd -P)"
# Resolve symlinks on both sides before mapping the host directory into the mount.
launch_dir="$(pwd -P)"
container_workdir=/workspace
project_prefix="${PROJECT_DIR%/}/"
if [[ "$launch_dir" == "$PROJECT_DIR" ]]; then
  container_workdir=/workspace
elif [[ "$launch_dir" == "$project_prefix"* ]]; then
  container_workdir="/workspace/${launch_dir#"$project_prefix"}"
fi

state_project="$PROJECT_DIR"
if [[ -z "$project_dir_explicit" && "$launch_dir" == "$project_prefix"* ]]; then
  project_relative="${launch_dir#"$project_prefix"}"
  state_project="$project_prefix${project_relative%%/*}"
fi
if command -v sha256sum >/dev/null 2>&1; then
  project_hash=$(printf '%s' "$state_project" | sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  project_hash=$(printf '%s' "$state_project" | shasum -a 256)
else
  error 'sha256sum or shasum is required to identify project storage.'
fi
project_home="codex-project-${project_hash%% *}"
[[ "$project_home" != "$CODEX_VOLUME" ]] || error 'CODEX_VOLUME must differ from the project home volume.'
# Use driver ownership options supported by Podman 4.x as well as newer engines.
podman volume create --ignore --opt 'o=uid=10001,gid=10001' \
  --label "$state_label=true" --label "$project_label=$state_project" \
  "$project_home" >/dev/null
state_managed "$project_home"
if ! podman volume exists "$CODEX_VOLUME"; then
  podman volume create "$CODEX_VOLUME" >/dev/null
fi

run_args=(run --rm -i --memory "$MEMORY" --cpus "$CPUS"
  --read-only
  --tmpfs "/tmp:rw,nosuid,nodev,size=1g"
  --user 10001:10001
  --dns 8.8.8.8 --dns 1.1.1.1
  --security-opt no-new-privileges --security-opt label=disable
  -v "$project_home:/home/codexuser:rw,nocopy"
  -v "$CODEX_VOLUME:/home/codexuser/.codex:rw"
  -v "$PROJECT_DIR:/workspace:rw"
  -e HOME=/home/codexuser -e CODEX_HOME=/home/codexuser/.codex
  -e NPM_CONFIG_PREFIX=/home/codexuser/.local
  -e 'PATH=/home/codexuser/.local/bin:/home/codexuser/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  --entrypoint /bin/sh
  -w "$container_workdir")
[[ ! -t 0 || ! -t 1 ]] || run_args+=(-t)
[[ -z "${PLATFORM:-}" ]] || run_args+=(--platform "$PLATFORM")
[[ ! -f "$HOME/.gitconfig" ]] || run_args+=(-v "$HOME/.gitconfig:/home/codexuser/.gitconfig:ro")
[[ -z "${OPENAI_API_KEY:-}" ]] || run_args+=(--env OPENAI_API_KEY)

if [[ "$SSH_MODE" == secretive ]]; then
  identity=$(podman machine inspect "$PODMAN_MACHINE" --format '{{.SSHConfig.IdentityPath}}')
  port=$(podman machine inspect "$PODMAN_MACHINE" --format '{{.SSHConfig.Port}}')
  remote_user=$(podman machine inspect "$PODMAN_MACHINE" --format '{{.SSHConfig.RemoteUsername}}')
  rootful=$(podman machine inspect "$PODMAN_MACHINE" --format '{{.Rootful}}')
  [[ -f "$identity" && "$port" =~ ^[0-9]+$ && -n "$remote_user" ]] || error 'Invalid Podman machine SSH configuration.'
  tunnel_dir=$(mktemp -d /tmp/codex-ssh.XXXXXX)
  vm_dir="/tmp/codex-agent-$$-$RANDOM"
  vm_socket="$vm_dir/agent.sock"
  ssh_args=(-i "$identity" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$tunnel_dir/known_hosts")
  destination="$remote_user@127.0.0.1"
  cleanup() {
    # Expand the locally generated VM path before sending the remote command.
    # shellcheck disable=SC2029
    ssh "${ssh_args[@]}" "$destination" "rm -rf -- '$vm_dir'" >/dev/null 2>&1 || true
    ssh "${ssh_args[@]}" -S "$tunnel_dir/control" -O exit "$destination" >/dev/null 2>&1 || true
    rm -rf -- "$tunnel_dir"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # These VM paths are generated locally from numeric values, not user input.
  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$destination" "mkdir -m 700 -- '$vm_dir' && chmod 711 '$vm_dir'"
  ssh "${ssh_args[@]}" -M -S "$tunnel_dir/control" -fNT \
    -o ExitOnForwardFailure=yes -o StreamLocalBindMask=0177 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -R "$vm_socket:$SECRETIVE_SOCK" "$destination"
  # Set ownership in the same UID namespace used by the container engine.
  if [[ "$rootful" == true ]]; then
    # shellcheck disable=SC2029 # vm_socket must expand on the client.
    ssh "${ssh_args[@]}" "$destination" "sudo -n chown 10001:10001 '$vm_socket'"
  else
    # shellcheck disable=SC2029 # vm_socket must expand on the client.
    ssh "${ssh_args[@]}" "$destination" "podman unshare chown 10001:10001 '$vm_socket'"
  fi
  run_args+=(-v "$vm_socket:/tmp/ssh-agent.sock:ro"
    -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    -e 'GIT_SSH_COMMAND=ssh -o UserKnownHostsFile=/home/codexuser/.codex/known_hosts -o StrictHostKeyChecking=accept-new -o IdentityAgent=/tmp/ssh-agent.sock')
fi

# Do not exec: the EXIT trap must close the SSH tunnel after the container stops.
podman "${run_args[@]}" "$IMAGE_NAME" -ec '
  chmod 700 "$HOME"
  mkdir -p "$HOME/.local/bin" "$HOME/.npm" "$HOME/.cargo/bin" "$HOME/.cache"
  if [ ! -e "$HOME/.profile" ]; then
    printf '\''export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"\n'\'' > "$HOME/.profile"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.codex-sandbox-last-used"
  exec codex "$@"
' codex \
  -c 'sandbox_workspace_write.network_access=true' \
  -c 'sandbox_workspace_write.writable_roots=["/home/codexuser/.local","/home/codexuser/.npm","/home/codexuser/.cargo","/home/codexuser/.cache"]' \
  "$@"
