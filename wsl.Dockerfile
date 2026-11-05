FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

ENV LANG="C.UTF-8" \
    MISE_DATA_DIR="/mise" \
    MISE_CONFIG_DIR="/mise/config" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_STATE_DIR="/mise/state" \
    PATH="/mise/shims:$PATH"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    systemd \
    dbus \
    dbus-user-session \
    libpam-systemd \
    init \
    sudo \
    ca-certificates \
    build-essential \
    git curl tar unzip \
    clangd cmake \
    bubblewrap ripgrep libatomic1 \
    bash-completion vim \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN rm -f /lib/systemd/system/getty@.service \
    /lib/systemd/system/serial-getty@.service

RUN printf '[boot]\nsystemd=true\n\n[user]\ndefault=wsluser\n' > /etc/wsl.conf && \
    chmod 644 /etc/wsl.conf && \
    chown root:root /etc/wsl.conf

RUN groupadd --system mise

RUN useradd -m -s /bin/bash -G mise,sudo wsluser && \
    echo 'wsluser:wsluser' | chpasswd && \
    echo "wsluser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wsluser && \
    chmod 0440 /etc/sudoers.d/wsluser

RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH="/usr/local/bin/mise" sh

RUN install -d -m 2770 -o root -g mise \
    /mise \
    /mise/installs \
    /mise/shims \
    /mise/cache \
    /mise/state \
    /mise/config && \
    chmod g+s /mise

RUN cat >> /etc/profile.d/00-locale.sh.sh <<'EOF'
export LANG="C.UTF-8"
EOF

RUN cat >> /etc/profile.d/90-mise.sh <<'EOF'
export MISE_DATA_DIR="/mise"
export MISE_CONFIG_DIR="/mise/config"
export MISE_CACHE_DIR="/mise/cache"
export MISE_STATE_DIR="/mise/state"
export PATH="/mise/shims:$PATH"
eval "$(mise activate bash)"
EOF

RUN mkdir -p /usr/share/bash-completion/completions && \
    mise completion bash > /usr/share/bash-completion/completions/mise || true && \
    chmod 644 /usr/share/bash-completion/completions/mise

RUN mise use -g node@latest && \
    mise use -g npm:@deepseek-ai/dsh@$(mise ls-remote npm:@deepseek-ai/dsh --prerelease | grep -v alpha | sort -V | tail -1)

RUN chown -R root:mise /mise && \
    chmod -R g+w /mise

USER root
CMD ["/lib/systemd/systemd"]