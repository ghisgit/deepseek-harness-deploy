#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DSH_USER="${DSH_USER:-dsh}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_PORT="${DSH_PORT:-3080}"
LOOPBACK_HOST="127.0.0.1"
FORWARD_SCRIPT="/usr/local/bin/dsh-forward.mjs"

log() { printf 'dsh-entrypoint: %s\n' "$*"; }
warn() { printf 'dsh-entrypoint: warning: %s\n' "$*" >&2; }

# The Harness home must exist before its ownership is fixed.
mkdir -p "$DSH_HOME"

# Map the runtime uid/gid and fix ownership before anything else runs, so
# every later step (mise install, relay, dsh) sees the final permissions.
# This needs root; `docker run --user` starts skip it because they already
# run as the target user.
if [ "$(id -u)" = "0" ]; then
    if ! getent group "$PGID" > /dev/null 2>&1; then
        if getent group "$DSH_USER" > /dev/null 2>&1; then
            groupmod -o -g "$PGID" "$DSH_USER" 2>/dev/null || true
        else
            groupadd -o -g "$PGID" "$DSH_USER"
        fi
    fi

    if id "$DSH_USER" > /dev/null 2>&1; then
        usermod -o -u "$PUID" -g "$PGID" "$DSH_USER" 2>/dev/null || true
    else
        useradd -o -u "$PUID" -g "$PGID" -d "$HOME" -s /bin/bash "$DSH_USER"
    fi

    # The recursive home chown also covers $DSH_HOME (a mount under it) and
    # any project mounts, matching the previous deployment's ownership
    # behaviour. /mise holds the toolchain written as root at build time.
    chown -R "$PUID:$PGID" "$HOME" 2>/dev/null || \
        warn "chown failed for some paths under $HOME (read-only mounts?)"
    chown -R "$PUID:$PGID" /mise 2>/dev/null || \
        warn "could not chown /mise (read-only?)"
fi

# HOME and the working directory come from the image (ENV HOME=/data,
# WORKDIR /data); this script only prepares the Harness home inside it.
export DSH_HOME

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Bracket IPv6 literals for use as a trusted authority.
authority_form() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

is_loopback() {
    case "$1" in
        127.*|::1|"[::1]"|::ffff:127.*) return 0 ;;
        *) return 1 ;;
    esac
}

case "$DSH_PORT" in
    ''|*[!0-9]*)
        warn "DSH_PORT='$DSH_PORT' is not a number; using 3080"
        DSH_PORT=3080
        ;;
esac
if [ "$DSH_PORT" -lt 1 ] || [ "$DSH_PORT" -gt 65535 ]; then
    warn "DSH_PORT=$DSH_PORT is out of range; using 3080"
    DSH_PORT=3080
fi

# Extra /api browser-trust authorities from DSH_TRUSTED_HOSTS (comma
# separated, `host` or `host:port`). Loopback authorities are always trusted
# by dsh itself, and the forwarder's own address is added below.
TRUSTED_HOSTS=()
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
    IFS=',' read -r -a trusted_raw <<< "$DSH_TRUSTED_HOSTS"
    for host in "${trusted_raw[@]}"; do
        host="$(trim "$host")"
        [ -n "$host" ] || continue
        duplicate=""
        for existing in "${TRUSTED_HOSTS[@]}"; do
            if [ "$existing" = "$host" ]; then
                duplicate=1
                break
            fi
        done
        [ -n "$duplicate" ] || TRUSTED_HOSTS+=("$host")
    done
    unset trusted_raw host
fi

detect_bind_ip() {
    local ip=""
    if command -v node >/dev/null 2>&1; then
        ip="$(node -e 'const os = require("node:os"); for (const addrs of Object.values(os.networkInterfaces())) { for (const addr of addrs || []) { if (addr.family === "IPv4" && !addr.internal) { process.stdout.write(addr.address); process.exit(0); } } }' 2>/dev/null || true)"
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^::1$' | grep -v '^$' | head -n 1 || true)"
    fi
    printf '%s' "$ip"
}

resolve_bind_ip() {
    local candidate
    candidate="$(trim "${DSH_BIND_IP:-}")"
    case "$candidate" in
        0.0.0.0|::|"[::]")
            warn "DSH_BIND_IP=$candidate is a wildcard address; use one concrete local address (auto-detecting instead)"
            candidate=""
            ;;
    esac
    if [ -z "$candidate" ]; then
        candidate="$(detect_bind_ip)"
    fi
    if [ -z "$candidate" ]; then
        warn "could not detect a non-loopback interface; dsh will listen on 127.0.0.1 only and the published port will not reach it"
        candidate="$LOOPBACK_HOST"
    fi
    printf '%s' "$candidate"
}

FORWARD_ENABLED=0
BIND_IP=""
WEB_COMMAND=()

# The Harness home is an operator-owned layer: this script never creates,
# rewrites or moves files in it.
if [ "${1:-}" = "web" ]; then
    BIND_IP="$(resolve_bind_ip)"

    ALL_TRUSTED=()
    if is_loopback "$BIND_IP"; then
        warn "bind address $BIND_IP is loopback; dsh will listen there without a forwarder, so the published port will not reach it"
    else
        # dsh itself stays on loopback; the forwarder accepts the container
        # address on the same port, so add that authority for direct access.
        FORWARD_ENABLED=1
        ALL_TRUSTED+=("$(authority_form "$BIND_IP")")
    fi
    for host in "${TRUSTED_HOSTS[@]}"; do
        duplicate=0
        for existing in "${ALL_TRUSTED[@]}"; do
            if [ "$existing" = "$host" ]; then
                duplicate=1
                break
            fi
        done
        [ "$duplicate" = 1 ] || ALL_TRUSTED+=("$host")
    done

    WEB_COMMAND=(web --host "$LOOPBACK_HOST" --port "$DSH_PORT")
    for host in "${ALL_TRUSTED[@]}"; do
        WEB_COMMAND+=(--trusted-host "$host")
    done
    WEB_COMMAND+=("${@:2}")
    set -- "${WEB_COMMAND[@]}"

    if [ "$FORWARD_ENABLED" = "1" ]; then
        log "web: dsh on $LOOPBACK_HOST:$DSH_PORT, forwarding $BIND_IP:$DSH_PORT -> $LOOPBACK_HOST:$DSH_PORT"
    else
        log "web: dsh on $LOOPBACK_HOST:$DSH_PORT (forwarder disabled)"
    fi
fi

# Start the transparent TCP forwarder on the container interface. dsh never
# binds the network: the compose publish reaches this relay, and the relay
# dials dsh's loopback listener on the same port.
launch_forwarder() {
    [ "$FORWARD_ENABLED" = "1" ] || return 0
    if [ ! -r "$FORWARD_SCRIPT" ]; then
        warn "forwarder script $FORWARD_SCRIPT is missing; the published port will not reach dsh"
        return 0
    fi
    if [ "$(id -u)" = "0" ]; then
        gosu "$PUID:$PGID" node "$FORWARD_SCRIPT" "$BIND_IP" "$DSH_PORT" "$LOOPBACK_HOST" "$DSH_PORT" &
    else
        node "$FORWARD_SCRIPT" "$BIND_IP" "$DSH_PORT" "$LOOPBACK_HOST" "$DSH_PORT" &
    fi
    local forward_pid=$!
    sleep 0.5
    if ! kill -0 "$forward_pid" 2>/dev/null; then
        warn "forwarder exited during startup; the published port will not reach dsh"
    fi
}

if [ "$(id -u)" != "0" ]; then
    # Already running as the target user: ensure the mise toolchain is present
    # (idempotent; skips tools already installed under /mise/data).
    mise install >/dev/null 2>&1 || echo "warning: mise install failed; continuing"
    launch_forwarder
    exec dsh "$@"
fi

# Install any mise-managed tool missing from /mise/config/config.toml
# (node by default). Idempotent: skips tools already installed under
# /mise/data. A failure only warns so the harness still tries to boot.
gosu "$PUID:$PGID" mise install >/dev/null 2>&1 || \
    echo "warning: mise install failed; continuing"

launch_forwarder

exec gosu "$PUID:$PGID" /usr/local/bin/dsh "$@"
