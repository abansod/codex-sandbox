# Repository Guidelines

## Project Structure & Module Organization

This repository builds and launches a Podman development image for the Codex CLI. Files live at the repository root:

- `Containerfile`: image definition and bundled development tools.
- `build-verify-codex.sh`: image build and runtime verification.
- `codex-sandbox.sh`: launcher, project mounts, and SSH agent forwarding.
- `setup.sh`: storage preparation and Zsh wrapper installation.
- `.github/workflows/ci.yml`: static checks and AMD64 container verification.
- `README.md`, `CONTRIBUTING.md`, and `SECURITY.md`: usage, contribution, and security guidance.

There are no separate source, test, or asset directories; verification lives in the build script and CI workflow.

## Build, Test, and Development Commands

Run from the repository root:

```bash
bash -n build-verify-codex.sh codex-sandbox.sh setup.sh
shellcheck build-verify-codex.sh codex-sandbox.sh setup.sh
git diff --check
./build-verify-codex.sh
SSH_MODE=none PROJECT_DIR="$PWD" ./codex-sandbox.sh --version
```

These check Bash syntax, shell lint, whitespace, image construction and bundled tools, and launcher operation. ShellCheck and a running Podman installation are host prerequisites. Image builds require network access but no Codex credentials. Use `./setup.sh --no-shell` to prepare storage and build without editing shell configuration.

## Coding Style & Naming Conventions

Follow `.editorconfig`: UTF-8, LF endings, two-space indentation, and a final newline. Preserve the scripts' Bash strict mode (`set -Eeuo pipefail`), quote variable expansions, and use descriptive lowercase function names. Configuration environment variables use uppercase names such as `PROJECT_DIR` and `IMAGE_NAME`. Follow existing hyphenated script filenames and keep ShellCheck clean.

## Testing Guidelines

There is no dedicated unit-test framework or numeric coverage requirement. Add meaningful verification to `build-verify-codex.sh` when adding tools, and update the README. Test mount changes with a disposable project. CI verifies AMD64; architecture-sensitive changes also need `PLATFORM=linux/arm64 ./build-verify-codex.sh` on a suitable host. Report unavailable runtime checks explicitly.

## Commit & Pull Request Guidelines

Existing commits use short, imperative subjects, such as “Enable outbound networking in workspace-write sandbox.” Keep changes focused. Pull requests should explain the problem, resulting behavior, and validation results; link relevant issues. Document changes to privileges, credentials, mounts, and persistent storage.

## Security & Configuration

Never commit credentials, local Codex settings, or generated build outputs. Treat the persistent Codex volume and forwarded SSH agent as sensitive. Preserve the MIT license and review `SECURITY.md` before changing container permissions.
