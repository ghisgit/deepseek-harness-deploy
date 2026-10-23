# DeepSeek Harness — Docker Compose deployment

Debian-based Docker deployment of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
running in web mode, with persistent data on the host.

DeepSeek Harness is DeepSeek's open-source agent harness: an architecture where everything is a plugin,
powered by [Cordis](https://github.com/cordiverse/cordis). The image builds the Node.js CLI
(`@deepseek-ai/dsh`) and runs `dsh web`, serving the web UI on port `3080` by default.

> **Developer preview.** DeepSeek Harness is iterating rapidly and introduces
> compatibility-breaking changes. Pin `DSH_VERSION` to a specific release for
> stable upgrades/rollbacks.

## Directory layout

| Local path | Container path | Purpose |
|---|---|---|
| `dsh/` | `/data/.dsh` | The Harness home: profiles, `cordis.patch.yml` (operator layer), `settings.yaml`, `.credentials.yaml`, `.env`, `storages`, `.agent-presets` |
| `data/` | file-by-file mounts (see below) | other project files you want available in the container home |
| `entrypoint.sh` | `/entrypoint.sh` (baked into the image) | maps `PUID`/`PGID`, fixes ownership, binds dsh on loopback and relays the container interface to it, drops privileges |
| `dsh-forward.mjs` | `/usr/local/bin/dsh-forward.mjs` (baked into the image) | transparent TCP relay from the container interface to dsh's loopback listener |

The container home is `/data` and is also the default working directory; only
the Harness home (`/data/.dsh`, mounted from `dsh/`) is persisted. The old
host-side `workspace/` directory is left untouched but is no longer mounted.

## Security

The web UI ships **without TLS or authentication**, and DeepSeek Harness agents
**execute arbitrary code** in the container home (the session working
directory). The compose file therefore publishes
**only on the host loopback** by default (`127.0.0.1:3080`):

- For a purely local/SSH-forwarded setup, keep `BIND_ADDRESS=127.0.0.1`.
- To expose it to a trusted network, set `BIND_ADDRESS=0.0.0.0` and front it with
  a real reverse proxy (TLS + auth). Without one, agent code execution is reachable
  by anyone who can connect.

dsh itself never binds the network: `entrypoint.sh` starts it on loopback and
runs a small TCP relay on the container's own interface, so the compose publish
reaches the harness (see [Networking](#networking)). The relay is the
network-facing listener, so other containers on the same Docker network can
reach the UI through it — the previous all-interfaces bind had the same
exposure; only `BIND_ADDRESS` controls host/network publishing. The `/api`
browser-trust fence still requires a loopback `Host` or a named
`DSH_TRUSTED_HOSTS` authority.

## Getting started

1. (Optional) Copy and adjust the environment file:

   ```sh
   cp .env.example .env
   ```

   `.env` is optional — sensible defaults apply when it is absent. If present,
   set `PUID`/`PGID` to match your host user (`id -u` / `id -g`) so persisted
   files keep the right ownership.

   Note: the optional `env_file` requires Docker Compose v2.24+.

2. Start:

   ```sh
   docker compose up -d
   ```

   By default this pulls the prebuilt image from GHCR (see below). To build
   the image locally instead, copy `docker-compose.override.example.yml` to
   `docker-compose.override.yml` — its template includes the build block and
   tags the result with a separate local name (`deepseek-harness-deploy:local`,
   see `DSH_LOCAL_IMAGE`), so it is never confused with the cloud image.

3. Open `http://127.0.0.1:3080` (the first visit needs the browser token printed
   at startup — see [Networking](#networking)).

4. Configure the model: open **Settings → Models**, enter a
   [DeepSeek API key](https://platform.deepseek.com/), and save it. The key is
   stored in `$DSH_HOME/.credentials.yaml`. (You can also pass
   `DEEPSEEK_API_KEY` in the container environment.)

5. Choose a workspace: click **Choose workspace** and add the container's
   `/data` home (or a directory you mounted under it, such as
   `/data/deepseek-harness-deploy`).

The container healthcheck probes the relay on the container interface; the
status is shown as `(healthy)` in `docker ps`. An unauthenticated request
answers `401` until the browser token is presented, and the healthcheck counts
that as healthy because it proves the relay → dsh path works.

## Networking

Two constraints drive this setup:

- dsh 0.2.1 rejects wildcard bind addresses (`0.0.0.0`), and dsh 0.2.0 cannot
  bind a concrete interface at all — so dsh always listens on `127.0.0.1`
  inside the container via `dsh web --host 127.0.0.1 --port $DSH_PORT`.
- Docker's port publish targets the **container address**, so it cannot reach a
  loopback-only listener.

`entrypoint.sh` therefore starts `dsh-forward.mjs`, a transparent TCP relay, on
the container's own IPv4 address (`DSH_BIND_IP`, auto-detected by default) at
the same port, forwarding to `127.0.0.1:$DSH_PORT`. HTTP, WebSocket upgrades and
keep-alive connections pass through unchanged, and the browser's `Host` header
still reaches dsh, so the `/api` browser-trust fence keeps working:

- loopback authorities (`localhost`, `127.0.0.1`, `[::1]`) are trusted by dsh
  automatically;
- the relay's own address is added automatically, so direct access to the
  container IP works;
- anything else a browser uses must be listed in `DSH_TRUSTED_HOSTS`
  (comma-separated, `host` or `host:port`).

The healthcheck probes the relay address rather than loopback, so a dead relay
turns the container unhealthy; restart it to bring the relay back.

The startup log prints the token URL as `http://127.0.0.1:$DSH_PORT/?token=...`,
which is directly usable through the default host-loopback publish:

```sh
docker compose logs dsh | grep 'dsh web:'
```

For LAN access (`BIND_ADDRESS=0.0.0.0`), keep the token query and substitute the
host name/IP you reach the published port through, and add that authority to
`DSH_TRUSTED_HOSTS`:

```sh
DSH_TRUSTED_HOSTS=my-workstation.example.local,10.0.0.5:3080
```

`entrypoint.sh` never creates, rewrites or moves `$DSH_HOME/cordis.patch.yml`;
it is purely an operator layer. If you upgraded from an image that generated
it with `webserver.host: 0.0.0.0`, delete that file (or its webserver row)
before starting: it overrides the `dsh web` bind flags, and dsh 0.2.1 rejects
the wildcard host. Put custom rows in
`$DSH_HOME/profiles/web/cordis.patch.yml` instead.

Rollback to a 0.2.0 image is safe: its entrypoint regenerates the `0.0.0.0`
patch when `cordis.patch.yml` is absent. The new entrypoint never touches that
file, so delete a stale patch before rolling forward again.

## Persisting files into the container home (`/data`)

dsh runs with `HOME=/data` and `DSH_HOME=/data/.dsh`. The local `data/`
directory is used to persist other project files into the container home
directory, such as `.gitconfig` or `.ssh`.

Do **not** mount the whole `data/` directory over `/data` — it would shadow the
container home. Mount individual files instead, via `docker-compose.override.yml`
(so `docker-compose.yml` stays untouched — Compose auto-merges the override).

Start from the tracked template:

```sh
cp docker-compose.override.example.yml docker-compose.override.yml
```

```yaml
services:
  dsh:
    volumes:
      - ./data/.gitconfig:/data/.gitconfig:ro
```

Add one volume line per file. Drop the `:ro` suffix for files the container
must be able to write.

`docker-compose.override.yml` is git-ignored (it references personal files such
as `data/.gitconfig`, which are not tracked), so adjust it locally. Create the
source file in `data/` first — the bind mount fails to start if it does not
exist.

Files in `data/` are committed to git (only `.gitkeep` is tracked by default),
while runtime state under `dsh/` is git-ignored.

## Adding plugins

Out-of-tree plugins are installed per profile with the dsh plugin command
(which forwards to pnpm, bundled in the image):

```sh
docker compose exec dsh dsh plugin --profile web add <package-or-git-spec>
```

Restart the service afterwards so the profile's bundle set is picked up:

```sh
docker compose restart dsh
```

## Toolchain (mise)

The Node.js runtime is managed by [mise](https://mise.jdx.dev), which installs
it under `/mise/data` (installs and `shims/`) with its config in
`/mise/config` and its download cache in `/mise/cache`. Version-pinned shims
are exposed on `PATH` from `/mise/data/shims` (`npm` and `npx` ride along with
the Node distribution). `pnpm` — which `dsh plugin` forwards to — is installed
globally via `npm` instead of mise: mise's standalone pnpm build is ~440MB, the
npm package ~20MB, and this keeps the image small. The web UI runs on the
version of Node that dsh requires (see `DSH_NODE`). Inside the container the
agent can install a different Node version (or any npm package) with
`mise install` / `mise use` / `npm install -g`; `/mise` is writable by the
container user.

## Baked-in user and sudo

The image ships a default `dsh` user (UID/GID `1000`, bash shell, `HOME=/data`)
that is a member of the `sudo` group with passwordless sudo
(`/etc/sudoers.d/dsh`, `NOPASSWD: ALL`). This makes devcontainers
(`"remoteUser": "dsh"`) and `docker run --user dsh` work out of the box, and
lets the agent escalate with `sudo` when needed.

At startup the entrypoint still remaps the user/group to `PUID`/`PGID`
(defaulting to `1000`) so persisted files on the host keep the right
ownership — no build args required.

## Prebuilt images (GHCR)

GitHub Actions publishes multi-arch images (`linux/amd64`, `linux/arm64`) to
`ghcr.io/ghisgit/deepseek-harness-deploy`. Tags:

| Tag | Meaning |
|---|---|
| `latest` | Most recent build |
| `<version>` (e.g. `0.1.1-rc.2`) | Pinned dsh release; stable for rollbacks |
| `sha-<short>` | Exact git commit the image was built from |

When builds run:

- on every push to `main`
- manually via **Run workflow**, optionally pinning `DSH_VERSION`
- daily at 02:00 UTC — skipped when the resolved dsh version is already
  published

Pull a specific version manually:

```sh
docker pull ghcr.io/ghisgit/deepseek-harness-deploy:<version>
```

## Developing with VS Code (Dev Containers)

The repo ships a `.devcontainer/devcontainer.json` that attaches VS Code to
the same compose project used for deployment — same image, volumes, and
`.env` settings.

Prerequisites:

- [VS Code](https://code.visualstudio.com/) with the
  [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
  extension
- Docker Compose v2.24+ (for the optional `env_file`, as above)

Usage:

1. (Optional) Create `.env` as described in [Getting started](#getting-started).
2. Open this folder in VS Code and run **Dev Containers: Reopen in Container**
   from the command palette (`F1`).

What you get:

- A shell/editor session in `/data` (the container home) as the baked `dsh`
  user, with passwordless `sudo` available; the example override mounts this
  repository at `/data/deepseek-harness-deploy`.
- The running dsh web server is reachable directly at
  `http://localhost:${PORT:-3080}` via compose's own port publishing — no
  VS Code port forwarding needed.
- Your `docker-compose.override.yml` is applied too — Dev Containers does not
  load it automatically, so it is referenced explicitly in
  `.devcontainer/devcontainer.json`. The file is git-ignored; a cross-platform
  `initializeCommand` (shell script on Linux/macOS hosts, `.cmd` batch file on
  Windows) creates an empty stub on a fresh clone so the dev container opens
  out of the box.
- UID/GID mapping is handled by `PUID`/`PGID` exactly as in normal operation;
  Dev Containers' own UID rewrite is disabled to avoid double remapping.

Note: stopping the dev container (e.g. **Dev Containers: Stop Container**)
stops the web server too — it is the same service.

## Configuration (`.env`)

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3080` | Web server port (host:container) |
| `DSH_VERSION` | `latest` | dsh version for local image builds, e.g. `0.1.1-rc.2` |
| `DSH_NODE` | `24` | mise-managed Node.js major line (e.g. `24`) |
| `DSH_PNPM` | `latest` | pnpm version, installed globally via npm |
| `DSH_LOCAL_IMAGE` | `deepseek-harness-deploy:local` | Image tag for local builds (distinct from the `ghcr.io/ghisgit/deepseek-harness-deploy:latest` cloud image) |
| `BIND_ADDRESS` | `127.0.0.1` | Host address to publish; `0.0.0.0` exposes the harness to the network |
| `DSH_BIND_IP` | *(auto: container IPv4)* | Non-loopback address the in-container relay listens on; set for multi-homed containers |
| `DSH_TRUSTED_HOSTS` | *(empty)* | Extra `/api` browser-trust authorities (comma-separated) |
| `PUID` / `PGID` | `1000` | Host user/group id the container runs as |
| `DATA_DIR` | `./dsh` | Host directory holding the Harness home (mounted at `/data/.dsh`) |
| `DEEPSEEK_API_KEY` | *(empty)* | Provider key; also configurable in the web UI |

## License

DeepSeek Harness is MIT-licensed by DeepSeek AI; see upstream
[LICENSE](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE).
Third-party dependencies and their licenses are disclosed in the upstream
[THIRD_PARTY_NOTICES.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/THIRD_PARTY_NOTICES.md).
