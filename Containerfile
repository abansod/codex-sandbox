FROM node:24-trixie-slim

USER root

# Added bubblewrap to resolve the path warning and enable secure user-space sandboxing
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      openssh-client \
      curl \
      ca-certificates \
      ripgrep \
      jq \
      python3 \
      bash \
      bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# Override at build time to install a specific Codex CLI release.
ARG CODEX_VERSION=latest
# Clean the download cache in the same layer so it is not stored in the image.
RUN npm install -g "@openai/codex@${CODEX_VERSION}" typescript \
    && npm cache clean --force \
    && rm -rf /root/.npm

# Create non-root user
RUN useradd -m -u 10001 -s /bin/bash codexuser \
    && mkdir -p /workspace /home/codexuser/.codex \
    && chown -R codexuser:codexuser \
       /workspace /home/codexuser

USER codexuser

ENV HOME=/home/codexuser \
    CODEX_HOME=/home/codexuser/.codex

WORKDIR /workspace

ENTRYPOINT ["codex"]
