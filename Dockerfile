FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bash-completion \
        bubblewrap \
        ca-certificates \
        curl \
        git \
        gnupg \
        gosu \
        sudo \
        jq \
        procps \
        ripgrep \
        tar \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DeepSeek Harness (dsh) requires Node.js 22.19+ or 24+. Install the 24.x LTS
# line through NodeSource; the setup script resolves the architecture on its own
# (amd64/arm64), so the same Dockerfile builds both platforms.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version

# `dsh plugin ...` forwards to pnpm, so install it alongside the harness.
# Pin npm's global prefix to /usr/local (NodeSource installs node to /usr/bin,
# which would otherwise place these bins under /usr/bin); the entrypoint execs
# /usr/local/bin/dsh.
ARG DSH_VERSION=latest
RUN npm config set prefix /usr/local \
    && if [ "${DSH_VERSION}" = "latest" ]; then \
        npm install --global --force @deepseek-ai/dsh@latest; \
    else \
        npm install --global @deepseek-ai/dsh@${DSH_VERSION}; \
    fi \
    && npm install --global pnpm \
    && command -v dsh \
    && dsh --version || true

# Bake the dsh user/group (1000:1000, bash shell, home /data) so dev
# containers ("remoteUser": "dsh") and `docker run --user dsh` work out of
# the box. entrypoint.sh still remaps PUID/PGID at runtime, so no build args
# are needed. Passwordless sudo lets the agent escalate when needed.
# The Harness home lives at $DSH_HOME (default $HOME/.dsh), so /data holds it.
RUN groupadd -o -g 1000 dsh \
    && useradd -o -u 1000 -g 1000 -d /data -s /bin/bash dsh \
    && mkdir -p /data/.dsh \
    && chown -R dsh:dsh /data \
    && usermod -aG sudo dsh \
    && echo "dsh ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/dsh \
    && chmod 0440 /etc/sudoers.d/dsh

# No global HOME: gosu resolves the dropped-privileges user's home from
# /etc/passwd (/data), and the entrypoint exports HOME for both of its paths.
ENV DSH_HOME=/data/.dsh

WORKDIR /workspace

# Bake the entrypoint into the image (not a runtime bind mount), so local
# builds ship the entrypoint from the current tree.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -fsS "http://127.0.0.1:${DSH_PORT:-3080}/" > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["web", "--no-open"]
