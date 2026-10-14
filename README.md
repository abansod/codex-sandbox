# Codex Sandbox

A Podman development image for the OpenAI Codex CLI. It runs as `codexuser` (UID 10001) in `/workspace` and includes Node.js 24, Python 3, Rust (`rustc` and `cargo`), C/C++ build tools, Git, SSH, ripgrep, jq, curl, and bubblewrap.

## Requirements

- Bash and Podman on the host.
- A running Podman machine on macOS or Windows (`podman machine init`, then `podman machine start`, if needed).
- Network access to download the base image, Debian packages, and Codex CLI.
- A Codex account or API key to use the CLI. Building and verifying the image does not require authentication.

## Setup

With Podman installed and running, run:

```bash
./setup.sh
```

Setup builds and verifies the image, creates `$HOME/projects` and the `codex-home` volume, then installs a `codex-sandbox` wrapper in `${ZDOTDIR:-$HOME}/.zshrc`. It backs up an existing shell configuration before changing it. Repeated runs replace the managed block; other shell configuration, including your previous function, stays intact. The wrapper at the end takes precedence.

Open a new Zsh terminal, open Secretive, and run `codex-sandbox login --device-auth`. Keep this repository at its current path: the wrapper calls its launcher directly. If you move it, rerun setup.

```bash
./setup.sh --skip-build  # Use the existing image.
./setup.sh --no-shell    # Build and prepare storage without editing .zshrc.
./setup.sh --help
```

Use `ZSHRC=/path/to/.zshrc` to select another shell configuration. Build and storage overrides below also apply to setup. Setup does not save environment overrides; export launcher settings in your shell when you need them on future runs. Setup does not install Podman, start a VM, or authenticate Codex.

## Build

```bash
git clone git@github.com:abansod/codex-sandbox.git
cd codex-sandbox
./build-verify-codex.sh
```

The script builds `codex-local:latest` for the host architecture (ARM64 or AMD64). It verifies the CLI, non-root user, development tools, and an offline Rust compile and run. Run this script on the host where Podman is available.

Override the image name or target platform when needed:

```bash
IMAGE_NAME=codex-dev:latest PLATFORM=linux/amd64 ./build-verify-codex.sh
```

Cross-architecture builds need emulation support in your Podman environment. Native builds are preferred.

## Run

The launcher defaults to `$HOME/projects`, creates it if needed, and mounts it at `/workspace`. Files edited there are saved directly to your host project.

```bash
# From the repository, select a project explicitly.
PROJECT_DIR=/absolute/path/to/project ./codex-sandbox.sh

# Select the current project instead of the default projects directory.
PROJECT_DIR="$PWD" /path/to/codex-sandbox/codex-sandbox.sh
```

Arguments are passed directly to Codex:

```bash
./codex-sandbox.sh --help
./codex-sandbox.sh --version
./codex-sandbox.sh exec "Explain this repository"
```

The launcher follows the macOS/Secretive setup: 8 GB memory, 4 CPUs, a read-only root filesystem, temporary writable `/tmp` and home directories, UID/GID 10001, public DNS, `no-new-privileges`, and disabled SELinux labeling. It adds a TTY only for interactive terminals and preserves stdin for piped commands. `PLATFORM=linux/arm64` can explicitly select the architecture; otherwise Podman uses the image default.

Add a wrapper to `~/.zshrc` (replace the repository path):

```zsh
codex-sandbox() {
  /absolute/path/to/codex-sandbox/codex-sandbox.sh "$@"
}
```

Then use `codex-sandbox` as before. The default settings volume is `codex-home`, matching your existing function.

## Secretive SSH forwarding

Open Secretive before launching. The default socket is `$HOME/.secretive/ssh-agent.sock`. The launcher uses native OpenSSH with connection details from [Podman machine inspect](https://docs.podman.io/en/latest/markdown/podman-machine-inspect.1.html), forwards the agent into a unique VM directory, and closes the tunnel and removes the socket when the container exits. The named machine must be the one serving your active Podman connection.

The socket stays mode 600. Its ownership is mapped to UID 10001 using `podman unshare` for a rootless engine or passwordless `sudo` for a rootful engine. SSH keys stay in Secretive, but code in the container can request signatures through the forwarded agent. Host keys for Git SSH connections persist in the Codex volume; unknown hosts are accepted on first use and changed keys are rejected.

Your host `.gitconfig` is mounted read-only when present. Included config files, credential helpers, or signing programs referenced there must also exist in the image to work.

To run without Secretive or a Podman VM (for example, Linux CI):

```bash
SSH_MODE=none PROJECT_DIR="$PWD" ./codex-sandbox.sh --version
```

Temporary home data, including default Cargo and npm caches, disappears on exit. The project mount and Codex volume persist.

## Sign in

For a container without browser callbacks, use device login:

```bash
./codex-sandbox.sh login --device-auth
./codex-sandbox.sh login status
```

Device login must be enabled in your account or workspace settings. For API key login, export `OPENAI_API_KEY` using your preferred secret manager, then pipe it through stdin:

```bash
printenv OPENAI_API_KEY | ./codex-sandbox.sh login --with-api-key
```

API usage is billed through your OpenAI Platform account. See the [official authentication documentation](https://learn.chatgpt.com/docs/auth) for sign-in options and credential storage.

The launcher persists credentials, settings, and session data in the Podman volume `codex-home`, mounted at `/home/codexuser/.codex`. Use a separate volume for another account or project:

```bash
CODEX_VOLUME=codex-work-home ./codex-sandbox.sh
./codex-sandbox.sh logout
```

Treat the volume as sensitive because it can contain credentials. Container deletion does not delete this volume.

## Configuration

| Variable | Default | Applies to |
| --- | --- | --- |
| `IMAGE_NAME` | `codex-local:latest` | Build and launcher |
| `PLATFORM` | Host architecture for build; image default for run | Build and launcher |
| `CODEX_VERSION` | `latest` | Build |
| `BUILD_DIR` | Build script directory | Build context |
| `CONTAINERFILE` | `$BUILD_DIR/Containerfile` | Build definition |
| `PROJECT_DIR` | `$HOME/projects` | Launcher project mount |
| `CODEX_VOLUME` | `codex-home` | Launcher settings volume |
| `SSH_MODE` | `secretive` (`none` disables forwarding) | Launcher |
| `SECRETIVE_SOCK` | `$HOME/.secretive/ssh-agent.sock` | Launcher |
| `PODMAN_MACHINE` | `podman-machine-default` | SSH forwarding |
| `MEMORY` / `CPUS` | `8g` / `4` | Launcher limits |
| `OPENAI_API_KEY` | Unset | Forwarded by launcher when exported |

To pin Codex, set `CODEX_VERSION` to a published npm release. The Node base image and Debian packages still follow their upstream tags and repositories; this is not a fully reproducible build.

Rust and Cargo come from Debian Bookworm packages. They are not installed through rustup, and may be older than the latest Rust release. Projects requiring a newer toolchain should customize the Containerfile.

## Shell access

Override the image entrypoint to inspect the environment:

```bash
podman run --rm -it --entrypoint /bin/bash codex-local:latest
```

This shell is temporary and does not mount your project or persistent settings. To verify the bundled tools:

```bash
podman run --rm --entrypoint /bin/sh codex-local:latest \
  -c 'rustc --version && cargo --version && node --version'
```

## Troubleshooting

- **Podman unavailable:** install Podman on the host and start its machine if your platform requires one. A sandboxed agent session may not expose the host runtime.
- **Image missing:** run `./build-verify-codex.sh`; use the same `IMAGE_NAME` for build and launch.
- **Permission denied on a project:** check VM shared-folder permissions and ownership for UID 10001. On native Linux, arrange directory permissions for the container user in the engine's UID namespace; the launcher uses your fixed container UID rather than host UID mapping.
- **Namespace or bubblewrap errors:** the launcher uses `no-new-privileges` without `SYS_ADMIN`. Host policies may prevent nested namespaces. Installing bubblewrap alone does not verify that Codex sandboxing works on every host; check the actual Codex workflow on your machine.
- **SSH tunnel errors:** verify Secretive is open, the selected Podman machine is running, and its rootless/rootful mode matches the active engine. Forwarding failures stop launch and trigger cleanup.
- **Rust package requires a newer compiler:** inspect `rustc --version` and customize the image toolchain.

## Security and maintenance

The launcher uses a read-only root filesystem and `no-new-privileges`. Its project mount remains writable, SELinux labeling is disabled, and its SSH agent can authorize Git operations. Review [SECURITY.md](SECURITY.md) for the trust boundary. The build retains its existing `SYS_ADMIN` build capability; runtime verification uses the read-only settings.

Rebuild to pick up updates; changing the Containerfile does not update an existing image. GitHub Actions checks shell scripts, builds the AMD64 image, compiles a Rust program, and checks the launcher and writable project mount. ARM64 and end-to-end authenticated Codex sandbox behavior require host verification.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks. Licensed under the [MIT License](LICENSE).
