FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

# Remove apt lists and docs/man pages in this same layer so they never ship
# in the image (a later RUN would only whiteout them and save no space).
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
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The Node runtime is version-managed by mise (https://mise.jdx.dev): the
# toolshed lives under /mise and its shims prepend PATH, so `node` (and the
# npm/npx bundled with it) resolve the pinned version and the agent can
# install other versions later. DeepSeek Harness (dsh) requires Node.js
# 22.19+ or 24+.
ENV MISE_DATA_DIR="/mise" \
    MISE_CONFIG_DIR="/mise" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_INSTALL_PATH="/usr/local/bin/mise" \
    PATH="/mise/shims:$PATH"
RUN curl -fsSL https://mise.run | sh

# Pin the Node major line mise manages (DSH_NODE=24 -> latest 24; overwritable
# at build time). Downloaded tarballs in the mise cache are deleted in this
# same layer so they don't ship in the image.
ARG DSH_NODE=24
RUN mise use -g "node@${DSH_NODE}" \
    && node --version \
    && npm --version \
    && rm -rf "${MISE_CACHE_DIR}"

# `dsh plugin ...` forwards to pnpm, so pnpm must be on PATH. Install it
# globally via npm: the pnpm npm package is ~20MB, while mise's standalone
# pnpm build is ~440MB. Node's bundled npm is used.
ARG DSH_PNPM=latest
# npm's download cache lands in /root/.npm; delete it in this same layer.
RUN npm install --global --prefix /usr/local "pnpm@${DSH_PNPM}" \
    && pnpm --version \
    && rm -rf /root/.npm

# `dsh plugin ...` forwards to pnpm, which is installed globally above.
# Pin npm's global prefix to /usr/local so `dsh` lands at /usr/local/bin/dsh
# (mise's node lives under /mise/installs and its binaries are not on PATH);
# the entrypoint execs /usr/local/bin/dsh.
ARG DSH_VERSION=latest
# ~170MB of npm download cache; delete it in this same layer.
RUN if [ "${DSH_VERSION}" = "latest" ]; then \
        npm install --global --prefix /usr/local --force @deepseek-ai/dsh@latest; \
    else \
        npm install --global --prefix /usr/local @deepseek-ai/dsh@${DSH_VERSION}; \
    fi \
    && command -v dsh \
    && dsh --version || true \
    && rm -rf /root/.npm

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
# builds ship the entrypoint from the current tree. dsh itself always listens
# on loopback; this tiny Node relay accepts the container interface address on
# the same port so the compose publish reaches the harness.
COPY entrypoint.sh /entrypoint.sh
COPY dsh-forward.mjs /usr/local/bin/dsh-forward.mjs
RUN chmod +x /entrypoint.sh \
    && chmod 0644 /usr/local/bin/dsh-forward.mjs

# Probe the forwarder on the container interface (not 127.0.0.1, which would
# still answer if the relay died). Without DSH_BIND_IP the entrypoint binds the
# container's own IPv4, which `hostname -i` reports. The UI answers 401 to an
# unauthenticated request until the browser token is presented, so 200/303/401
# all prove the listener is up; `hostname -i` may return IPv6, hence the
# bracketing.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD sh -c 'port="${DSH_PORT:-3080}"; for host in ${DSH_BIND_IP:-} $(hostname -i 2>/dev/null); do case "$host" in ""|0.0.0.0|::|"[::]") continue ;; *:*) host="[$host]" ;; esac; code=$(curl -s -o /dev/null --max-time 4 --noproxy "*" -w "%{http_code}" "http://$host:$port/" || true); case "$code" in 200|303|401) exit 0 ;; esac; done; exit 1'

ENTRYPOINT ["/entrypoint.sh"]
CMD ["web", "--no-open"]
