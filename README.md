# Codex Sandbox

A Podman development image for the OpenAI Codex CLI, based on `node:24-trixie-slim` (Debian 13). It runs as `codexuser` (UID 10001) in `/workspace` and includes Node.js 24 with npm, TypeScript (`tsc`), Python 3, Git, SSH, ripgrep, jq, curl, and bubblewrap.

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

The script builds `codex-local:latest` for the host architecture (ARM64 or AMD64). It verifies the CLI, non-root user, development tools, offline TypeScript compile and run, and npm tool persistence across sessions. Run this script on the host where Podman is available.

Override the image name or target platform when needed:

```bash
IMAGE_NAME=codex-dev:latest PLATFORM=linux/amd64 ./build-verify-codex.sh
```

Cross-architecture builds need emulation support in your Podman environment. Native builds are preferred.

Security rebuilds always pull the Node 24 base and disable build-layer caching so Debian package updates are applied. The build rejects Node.js versions older than 24.22.1, the October 21, 2026 security release. Existing containers must be recreated from the rebuilt image. PHP is not bundled; PHP installations in custom images or saved project homes require separate updates.

The image uses the slim Debian base and removes apt package lists and npm download caches in their installation layers. Rust and C/C++ toolchains are excluded from the base image; projects can use a custom image when they need them. To measure a rebuilt image and inspect its layers on the host:

```bash
podman image inspect codex-local:latest --format '{{.Size}}'
podman history codex-local:latest
```

The reported size is in bytes; actual savings depend on the architecture and package versions.

## Run

The launcher defaults to `$HOME/projects`, creates it if needed, and mounts it at `/workspace`. Files edited there are saved directly to your host project.

```bash
# From the repository, select a project explicitly.
PROJECT_DIR=/absolute/path/to/project ./codex-sandbox.sh

# Select the current project instead of the default projects directory.
PROJECT_DIR="$PWD" /path/to/codex-sandbox/codex-sandbox.sh
```

The launcher preserves your current directory when it is inside `PROJECT_DIR`.
For example, with the default `$HOME/projects` mount, running `codex-sandbox`
from `$HOME/projects/mac-cleaner` opens Codex in `/workspace/mac-cleaner`.
Nested directories map the same way. From the mount root or a directory outside
the mount, Codex starts in `/workspace`. Paths are resolved through symlinks;
only directories physically inside the project mount are mapped. An explicit
`PROJECT_DIR` uses that directory as the mount root instead.

Arguments are passed directly to Codex:

```bash
./codex-sandbox.sh --help
./codex-sandbox.sh --version
./codex-sandbox.sh exec "Explain this repository"
```

The launcher follows the macOS/Secretive setup: 8 GB memory, 4 CPUs, a read-only root filesystem, temporary writable `/tmp`, a persistent home per project, UID/GID 10001, public DNS, `no-new-privileges`, and disabled SELinux labeling. It adds a TTY only for interactive terminals and preserves stdin for piped commands. `PLATFORM=linux/arm64` can explicitly select the architecture; otherwise Podman uses the image default.

The launcher enables general outbound networking for agent commands in Codex's `workspace-write` sandbox, including GitHub SSH access, subject to managed policy. To disable it for a launch, pass `-c sandbox_workspace_write.network_access=false`. Start a new session to apply launcher changes; no image rebuild is needed.

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

## Project environments

Each session uses a fresh container that is removed on exit with `--rm`. Its home directory is stored in a named Podman volume, so user-installed tools, caches, and home configuration survive. `/tmp` remains temporary. Each launch uses the current `IMAGE_NAME`; rebuilding the image does not erase saved homes.

With the default mount, `~/projects/my-app` and its subdirectories share one home, while `~/projects/another-app` gets a different home. With an explicit `PROJECT_DIR`, that directory defines the home identity, regardless of where you launch. Launching from the default mount root or outside it uses a home for the mount root. Identity uses the canonical host path and a SHA-256 hash: symlink aliases share state, while moving a project creates a new environment. Existing saved state remains available for manual cleanup.

Inside a session, install user tools normally:

```bash
npm install -g prettier
```

The launcher sets npm's global prefix to `$HOME/.local` and puts `$HOME/.local/bin` and `$HOME/.cargo/bin` on `PATH`. For a new home, it creates `.profile` to keep those paths available in Bash login shells; existing profiles are preserved. It creates `.local`, `.npm`, `.cargo`, and `.cache` in the saved home and configures them as additional [Codex workspace-write roots](https://learn.chatgpt.com/docs/config-file/config-reference). Managed policy still applies. An explicit later `-c sandbox_workspace_write.writable_roots=...` replaces that default list. System packages installed with `apt` still require a Containerfile change and image rebuild; the runtime remains non-root with a read-only root filesystem.

Inspect and clean up saved environments from the host:

```bash
codex-sandbox state list
codex-sandbox state remove codex-project-HASH  # Use a full volume name from list.
codex-sandbox state prune
```

`list` shows the project path, volume name, approximate home size, last session start time in UTC, and whether any container references the volume. It runs a disposable, network-disabled container with the home mounted read-only; the configured image must exist locally. Last use is recorded inside the home at session startup; older or modified homes may report unknown or altered timestamps.

`remove` previews a selected home. `prune` previews **all homes without a container reference**, including recently used ones. Both require typing `yes`, cancel on EOF, recheck references before deletion, and never force removal. There is no automatic cleanup or age-based deletion. Containers referencing a home, including stopped containers, prevent removal.

Cleanup deletes the selected home's installed tools, caches, and configuration. It does not delete host project files or the separate `CODEX_VOLUME` containing Codex settings and credentials. Project homes are sensitive too: tools may store tokens there, and saved executables run in future sessions. Homes have no automatic size limit; use `state list` to monitor usage. Concurrent sessions for the same project share the home, so avoid simultaneous tool installations.

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

Rust, Cargo, and C/C++ build tools are installed only when a project needs them. Since sessions run non-root with a read-only root filesystem, use a derived image to add system toolchains. For example, save this as `Containerfile.project`:

```dockerfile
FROM codex-local:latest
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends rustc cargo build-essential \
    && rm -rf /var/lib/apt/lists/*
USER codexuser
```

Keep only the packages the project needs (`build-essential` for C/C++; Rust builds also need a native linker). Build and select the image on the host:

```bash
podman build -t codex-project:latest -f Containerfile.project .
IMAGE_NAME=codex-project:latest PROJECT_DIR="$PWD" /path/to/codex-sandbox/codex-sandbox.sh
```

User-installed tools under the project home persist across sessions. Adding a user-local Rust toolchain alone does not provide a system C/C++ compiler or linker.

npm comes with the Node.js base image, and TypeScript is installed globally through npm. Rebuild the image to pick up these tools. Build verification initializes an npm project and compiles and runs a TypeScript program using the bundled Node.js runtime.

## Shell access

Override the image entrypoint to inspect the environment:

```bash
podman run --rm -it --entrypoint /bin/bash codex-local:latest
```

This shell is temporary and does not mount your project or persistent settings. To verify the bundled tools:

```bash
podman run --rm --entrypoint /bin/sh codex-local:latest \
  -c 'node --version && npm --version && tsc --version'
```

## Troubleshooting

- **Podman unavailable:** install Podman on the host and start its machine if your platform requires one. A sandboxed agent session may not expose the host runtime.
- **Image missing:** run `./build-verify-codex.sh`; use the same `IMAGE_NAME` for build and launch.
- **Permission denied on a project:** check VM shared-folder permissions and ownership for UID 10001. On native Linux, arrange directory permissions for the container user in the engine's UID namespace; the launcher uses your fixed container UID rather than host UID mapping.
- **Namespace or bubblewrap errors:** the launcher uses `no-new-privileges` without `SYS_ADMIN`. Host policies may prevent nested namespaces. Installing bubblewrap alone does not verify that Codex sandboxing works on every host; check the actual Codex workflow on your machine.
- **SSH tunnel errors:** verify Secretive is open, the selected Podman machine is running, and its rootless/rootful mode matches the active engine. Forwarding failures stop launch and trigger cleanup.
- **Compiler or linker missing:** add the required Rust or C/C++ toolchain to a project image as shown above. Native npm dependencies can also require C/C++ build tools.

## Security and maintenance

The launcher uses a read-only root filesystem and `no-new-privileges`. Its project mount remains writable, SELinux labeling is disabled, and its SSH agent can authorize Git operations. Review [SECURITY.md](SECURITY.md) for the trust boundary. The build retains its existing `SYS_ADMIN` build capability; runtime verification uses the read-only settings.

Rebuild to pick up updates; changing the Containerfile does not update an existing image. GitHub Actions checks shell scripts, builds the AMD64 image, compiles and runs a TypeScript program, checks a local npm tool persists across sessions, and checks the launcher and writable project mount. ARM64 and end-to-end authenticated Codex sandbox behavior require host verification.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks. Licensed under the [MIT License](LICENSE).
