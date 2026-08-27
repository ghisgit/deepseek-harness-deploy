FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bash-completion \
        bubblewrap \
        libatomic1 \
        ca-certificates \
        curl \
        git \
        gnupg \
        gosu \
        sudo \
        jq \
        procps \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The runtime is version-managed by mise (https://mise.jdx.dev): the toolshed
# lives under /mise and its shims prepend PATH, so node/npm/pnpm resolve the
# pinned versions and the agent can install other versions later. DeepSeek
# Harness (dsh) requires Node.js 22.19+ or 24+.
ENV MISE_DATA_DIR="/mise" \
    MISE_CONFIG_DIR="/mise" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_INSTALL_PATH="/usr/local/bin/mise" \
    PATH="/mise/shims:$PATH"
RUN curl -fsSL https://mise.run | sh

# Pin the versions mise manages. DSH_NODE is a minor line (24.x -> latest 24),
# DSH_PNPM matches the upstream repo's pin; both are overwritable at build time.
ARG DSH_NODE=24
ARG DSH_NPM=latest
ARG DSH_PNPM=latest
RUN mise use -g "node@${DSH_NODE}" "npm@${DSH_NPM}" "pnpm@${DSH_PNPM}" \
    && node --version \
    && npm --version \
    && pnpm --version

# `dsh plugin ...` forwards to pnpm, so pnpm must be on PATH (mise shim above).
# Pin npm's global prefix to /usr/local so `dsh` lands at /usr/local/bin/dsh
# (mise's node lives under /mise/installs and its binaries are not on PATH);
# the entrypoint execs /usr/local/bin/dsh.
ARG DSH_VERSION=latest
RUN if [ "${DSH_VERSION}" = "latest" ]; then \
        npm install --global --prefix /usr/local --force @deepseek-ai/dsh@latest; \
    else \
        npm install --global --prefix /usr/local @deepseek-ai/dsh@${DSH_VERSION}; \
    fi \
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
