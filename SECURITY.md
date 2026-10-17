# Security

This image is a development environment with a writable host project mount. Code run in the container can modify that project and read credentials supplied to the container or stored in its Codex volume.

The launcher uses a read-only root filesystem, a persistent per-project home volume, a temporary `/tmp` mount, resource limits, UID 10001, and `no-new-privileges`. It disables SELinux labeling for the shared mounts. The build step retains its existing `SYS_ADMIN` capability, but the launcher does not grant it. A writable project mount and forwarded SSH agent remain sensitive resources; these settings do not make the container a hardened boundary for hostile code. Bubblewrap availability is checked through installation, but end-to-end Codex sandbox behavior depends on the host and CLI configuration.

Project homes persist user-installed executables, caches, configuration, and any credentials tools write there. The launcher makes `.local`, `.npm`, `.cargo`, and `.cache` additional writable roots for Codex's workspace-write sandbox, subject to managed policy. Saved `.local/bin` and `.cargo/bin` executables take precedence on PATH. Treat each home as trusted project state; containers are deleted on exit but changes to that home survive. The default mount still exposes sibling projects under `/workspace`; separate homes do not isolate host project files. The separate Codex credentials volume remains shared unless `CODEX_VOLUME` is overridden.

The `state` commands only manage volumes labeled as project homes with the expected hashed names. Destructive commands preview candidates and require confirmation, skip container references, and use non-forced removal. Prune means unreferenced, not old: it may include recently used environments. Cleanup leaves the host project directory and configured Codex settings volume intact. There are no automatic home quotas or retention limits. List reads home size and last-use metadata through a temporary container without networking; timestamps stored in a writable home are informational, not audit records.

Mount only the project you intend to work on. Keep host SSH keys, container runtime sockets, and unrelated directories outside the container unless you deliberately need them. The default launcher mounts the Secretive agent socket and your `.gitconfig`, but not private key files or the container runtime socket. Agent access permits signing requests even though private keys stay on the host. The VM socket is mode 600 with ownership mapped to the container user, and the tunnel is cleaned up on normal exit or handled signals. An uncatchable termination can leave tunnel resources behind until manually removed or the VM is restarted.

Do not put API keys or authentication files in the Containerfile, build arguments, Git, or issue reports. The persistent Codex volume can contain tokens; keep it private and use `./codex-sandbox.sh logout` to clear stored authentication. Review logs before sharing them.

Rebuild regularly to receive upstream updates. This repository does not publish a maintained image registry or guarantee a security update schedule.

To report a vulnerability, use the repository's private vulnerability reporting feature if it is enabled. Otherwise, contact the repository owner privately through their GitHub profile. Do not disclose credentials or exploit details in a public issue.
