FROM node:24-bookworm

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

# Install latest stable Codex CLI
RUN npm install -g @openai/codex@latest

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
