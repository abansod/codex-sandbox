#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${IMAGE_NAME:-codex-local:latest}"
CODEX_VOLUME="${CODEX_VOLUME:-codex-home}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/projects}"
SECRETIVE_SOCK="${SECRETIVE_SOCK:-$HOME/.secretive/ssh-agent.sock}"
SSH_MODE="${SSH_MODE:-secretive}"
PODMAN_MACHINE="${PODMAN_MACHINE:-podman-machine-default}"
MEMORY="${MEMORY:-8g}"
CPUS="${CPUS:-4}"

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || error 'Podman is not installed or not on PATH.'
podman info >/dev/null 2>&1 || error 'Podman is not running. Try: podman machine start'
podman image exists "$IMAGE_NAME" || error "Image not found: $IMAGE_NAME. Run build-verify-codex.sh first."
[[ "$SSH_MODE" == secretive || "$SSH_MODE" == none ]] || error 'SSH_MODE must be secretive or none.'
if [[ "$SSH_MODE" == secretive ]]; then
  command -v ssh >/dev/null 2>&1 || error 'OpenSSH is required for Secretive forwarding.'
  [[ -S "$SECRETIVE_SOCK" ]] || error "Secretive socket not found: $SECRETIVE_SOCK. Open the Secretive app."
fi
mkdir -p -- "$PROJECT_DIR"
PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd -P)"
if ! podman volume exists "$CODEX_VOLUME"; then
  podman volume create "$CODEX_VOLUME" >/dev/null
fi

run_args=(run --rm -i --memory "$MEMORY" --cpus "$CPUS"
  --read-only
  --tmpfs "/tmp:rw,nosuid,nodev,size=1g"
  --tmpfs "/home/codexuser:rw,nosuid,nodev,size=512m,mode=1777"
  --user 10001:10001
  --dns 8.8.8.8 --dns 1.1.1.1
  --security-opt no-new-privileges --security-opt label=disable
  -v "$CODEX_VOLUME:/home/codexuser/.codex:rw"
  -v "$PROJECT_DIR:/workspace:rw"
  -e HOME=/home/codexuser -e CODEX_HOME=/home/codexuser/.codex
  -w /workspace)
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
podman "${run_args[@]}" "$IMAGE_NAME" \
  -c 'sandbox_workspace_write.network_access=true' \
  "$@"
