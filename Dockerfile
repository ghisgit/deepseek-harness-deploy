FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion git curl ca-certificates tar unzip vim gosu sudo\
        bubblewrap ripgrep libatomic1 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV MISE_DATA_DIR="/mise/data" \
    MISE_CONFIG_DIR="/mise/config" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_STATE_DIR="/mise/state" \
    PATH="/mise/data/shims:$PATH"
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH="/usr/local/bin/mise" sh

ARG DSH_NODE=24
ARG DSH_VERSION=latest
RUN if [ "${DSH_VERSION}" = "latest" ]; then \
        DSH_VERSION=$(mise ls-remote npm:@deepseek-ai/dsh --prerelease | grep -v alpha | sort -V | tail -1); \
    fi \
    && mise use -g node@${DSH_NODE} npm:@deepseek-ai/dsh@${DSH_VERSION} \
    && rm -rf "${MISE_CACHE_DIR}"

RUN groupadd -o -g 1000 dsh \
    && useradd -o -u 1000 -g 1000 -d /data -s /bin/bash dsh \
    && mkdir -p /data/.dsh \
    && chown -R dsh:dsh /data \
    && usermod -aG sudo dsh \
    && echo "dsh ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/dsh \
    && chmod 0440 /etc/sudoers.d/dsh

ENV HOME=/data \
    DSH_HOME=/data/.dsh

WORKDIR /data

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY dsh-forward.mjs /usr/local/bin/dsh-forward.mjs
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chmod 0644 /usr/local/bin/dsh-forward.mjs

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD sh -c 'port="${DSH_PORT:-3080}"; for host in ${DSH_BIND_IP:-} $(hostname -i 2>/dev/null); do case "$host" in ""|0.0.0.0|::|"[::]") continue ;; *:*) host="[$host]" ;; esac; code=$(curl -s -o /dev/null --max-time 4 --noproxy "*" -w "%{http_code}" "http://$host:$port/" || true); case "$code" in 200|303|401) exit 0 ;; esac; done; exit 1'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["web", "--no-open"]
