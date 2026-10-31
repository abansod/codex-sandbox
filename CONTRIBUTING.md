# Contributing

Keep changes focused on the development image, its launcher, or its documentation. Open an issue describing the problem or send a pull request with the change and validation results.

## Local checks

```bash
bash -n build-verify-codex.sh codex-sandbox.sh setup.sh tests/test-launcher.sh tests/test-project-home.sh
shellcheck build-verify-codex.sh codex-sandbox.sh setup.sh tests/test-launcher.sh tests/test-project-home.sh
git diff --check
bash tests/test-launcher.sh
./build-verify-codex.sh
SSH_MODE=none PROJECT_DIR="$PWD" ./codex-sandbox.sh --version
```

ShellCheck and Podman must be installed on the host. The build script needs network access but no Codex credentials. If your environment cannot run containers, report the static checks you ran and leave image verification to CI or a host runtime.

The launcher tests use a fake Podman to check directory mapping, project home identity, and cleanup safeguards. The build script also runs `tests/test-project-home.sh` against real Podman: it installs a small local npm tool offline and verifies it and home data survive another launcher session. That test creates and removes disposable project and settings volumes without using Codex credentials.

When adding a development tool, add it to the Containerfile, update the README, and add a useful check to the build verification script. Test changes to mounted directories using a disposable project. Document changes to privileges, credentials, and persistent storage.

CI builds AMD64. For architecture-sensitive changes, also run `PLATFORM=linux/arm64 ./build-verify-codex.sh` on a suitable host and include the result in your pull request.

Do not commit credentials, local Codex settings, or generated build outputs. Preserve the existing MIT license.
