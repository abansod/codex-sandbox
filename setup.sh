#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ZSHRC="${ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/projects}"
CODEX_VOLUME="${CODEX_VOLUME:-codex-home}"
skip_build=false
install_shell=true

usage() {
  cat <<'HELP'
Usage: ./setup.sh [--skip-build] [--no-shell] [--help]

Build and verify the image, create project storage, and install codex-sandbox in .zshrc.
  --skip-build  Use an existing image (IMAGE_NAME, default codex-local:latest).
  --no-shell    Leave .zshrc unchanged.

Overrides: ZSHRC, ZDOTDIR, PROJECT_DIR, CODEX_VOLUME, IMAGE_NAME, PLATFORM,
CODEX_VERSION, BUILD_DIR, CONTAINERFILE.
Podman must already be installed and running. Setup does not log you in.
HELP
}
error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --skip-build) skip_build=true ;;
    --no-shell) install_shell=false ;;
    --help|-h) usage; exit 0 ;;
    *) error "Unknown option: $arg (see --help)" ;;
  esac
done

command -v podman >/dev/null 2>&1 || error 'Install Podman before running setup.'
podman info >/dev/null 2>&1 || error 'Podman is not running. Start it with: podman machine start'
if "$skip_build"; then
  podman image exists "${IMAGE_NAME:-codex-local:latest}" || error 'Image not found. Run setup without --skip-build.'
else
  "$SCRIPT_DIR/build-verify-codex.sh"
fi
mkdir -p -- "$PROJECT_DIR"
if ! podman volume exists "$CODEX_VOLUME"; then
  podman volume create "$CODEX_VOLUME" >/dev/null
fi

if "$install_shell"; then
  mkdir -p -- "$(dirname -- "$ZSHRC")"
  [[ ! -e "$ZSHRC" || -f "$ZSHRC" ]] || error "Not a regular file: $ZSHRC"
  temp_file=$(mktemp)
  trap 'rm -f -- "$temp_file"' EXIT
  if [[ -f "$ZSHRC" ]]; then
    # Replace only our marked block, retaining existing functions and other config.
    awk '
      $0 == "# BEGIN codex-sandbox setup" { if (inside) exit 1; inside=1; next }
      $0 == "# END codex-sandbox setup" { if (!inside) exit 1; inside=0; next }
      !inside { print }
      END { if (inside) exit 1 }
    ' "$ZSHRC" > "$temp_file" || error 'Malformed setup block in .zshrc; file left unchanged.'
  fi
  # Single-quote the repository path for both Bash and Zsh, including apostrophes.
  launcher="$SCRIPT_DIR/codex-sandbox.sh"
  launcher="${launcher//\'/\'\\\'\'}"
  {
    printf '# BEGIN codex-sandbox setup\n'
    printf 'codex-sandbox() {\n  '\''%s'\'' "$@"\n}\n' "$launcher"
    printf '# END codex-sandbox setup\n'
  } >> "$temp_file"
  if [[ -f "$ZSHRC" ]] && cmp -s "$ZSHRC" "$temp_file"; then
    printf 'Shell wrapper already installed in %s\n' "$ZSHRC"
  else
    if [[ -f "$ZSHRC" ]]; then
      backup=$(mktemp "${ZSHRC}.backup.XXXXXX")
      cp -p -- "$ZSHRC" "$backup"
      printf 'Shell configuration backup: %s\n' "$backup"
    fi
    cat "$temp_file" > "$ZSHRC"
    printf 'Installed codex-sandbox in %s\n' "$ZSHRC"
  fi
fi

printf '\nSetup complete.\n'
if "$install_shell"; then
  printf 'Open a new Zsh terminal to load codex-sandbox.\n'
fi
if "$install_shell"; then
  printf 'Open Secretive, then run: codex-sandbox login --device-auth\n'
else
  printf 'Open Secretive, then run the launcher: %s/codex-sandbox.sh login --device-auth\n' "$SCRIPT_DIR"
fi
printf 'Custom setup variables are not saved; export them in your shell to use them at launch.\n'
