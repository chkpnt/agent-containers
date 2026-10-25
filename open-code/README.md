# Open Code

Two images live side by side:

| image          | base            | OpenCode            | launcher | config/state dirs on host          |
|----------------|-----------------|---------------------|----------|------------------------------------|
| `open-code:v1` | `agent-base`    | `opencode-ai` (1.x) | `oc1`    | `~/.config/opencode`, ...          |
| `open-code:v2` | `agent-base:v2` | `@opencode/cli` (2.x) | `oc2`, `docker-compose.yaml` | `~/.config/opencode-v2`, ... |

v1 and v2 must not share config/state (v2 converts it in place, v1 cannot read
it back), hence the separate `*-v2` directories on the host. Inside the
container they are mounted at the default paths, so OpenCode needs no extra
flags.

## Build

```bash
make open-code      # v1 (old base, tag `open-code`; `docker tag open-code open-code:v1`)
make open-code-v2   # v2 -> agent-base:v2, open-code:v2
```

Add apt packages via `LOCAL_TOOLS` in `base/Dockerfile.v2`.

### What is different in the v2 base image

- Ubuntu 26.04 + git from the git-core PPA (recent git, worktree fixes).
- **User agnostic**: nothing user specific is baked in. All tools live in
  system paths (`/usr/local`, `/opt`). `base/entrypoint.sh` creates the user at
  start from `HOST_USER`, `HOST_UID`, `HOST_GID`, `HOST_HOME`
  (default `agent`/1000/`/home/agent`) and drops privileges with `setpriv`.
  Anyone can use the same image.
- If `/var/run/docker.sock` is mounted, the user is added to its group. The
  Docker CLI with the `compose` and `buildx` plugins is in the image.
- `git-lfs` is installed and enabled system-wide (pre-push hooks need it).
- SSH host keys for `SSH_KNOWN_HOSTS` (build arg, default GitHub + Bitbucket)
  are in `/etc/ssh/ssh_known_hosts`.
- Extra CAs: PEM files (one CA per file, `*.crt`/`*.pem`) mounted at
  `/etc/agent/ca-certificates` are trusted by the system store, Node
  (`NODE_EXTRA_CA_CERTS`) and Chromium/agent-browser (user NSS db). Compose
  mounts `AGENT_CA_DIR` (default `open-code/ca-certificates/`, git-ignored),
  `oc2` mounts `OC2_CA_DIR`.
- `npm i -g` / `bun` installs go to `$HOME/.local` / `$HOME/.bun`.
- pnpm `storeDir` defaults to `$HOME/.local/share/pnpm/store` (written to
  `~/.config/pnpm/config.yaml` only if that file does not exist yet).

## Same-path mounts (why)

Everything is mounted at the **same absolute path** as on the host
(`/home/<you>/Projects/foo` is `/home/<you>/Projects/foo` in the container,
not `/app`). This fixes:

- **pnpm**: `node_modules/.modules.yaml` records absolute paths and the store
  location. With `/app` the container used a separate store inside the project
  and host/container kept purging each other's `node_modules`. Same path + same
  store (`~/.local/share/pnpm`) = one install that works on both sides
  (keep node/pnpm majors in sync for native addons).
- **git worktrees**: `.git` files of worktrees contain absolute paths, which
  now resolve on both sides.
- **docker.sock**: `docker run -v $PWD:...` issued by the agent is resolved by
  the host daemon, so paths have to be host paths.

### pnpm global virtual store (on by default)

Projects and the store are different mounts, so hardlinks between them fail
(`EXDEV`) and pnpm silently copies the whole `node_modules` into every
checkout. The image sets `PNPM_CONFIG_VIRTUAL_STORE_TYPE=global` (pnpm >= 11.23):
packages are linked once inside the store and `node_modules` holds only
symlinks, which work across mounts and make new worktrees almost free.
Experimental; to opt out, run the container with
`-e PNPM_CONFIG_VIRTUAL_STORE_TYPE=project`.

pnpm env vars beat both `~/.config/pnpm/config.yaml` and a repo's
`pnpm-workspace.yaml`. See
https://pnpm.io/git-worktrees. The store must be mounted at the same path as on
the host (it is).

### Worktrees in OpenCode

Default worktree location is the OpenCode data dir. To keep worktrees next to
the repo (visible to host tools, same pnpm store), set in the v2 config:

```jsonc
"worktree": { "directory": ".worktrees" }   // relative to the canonical checkout
```

and add `.worktrees/` to the repo's (or global) gitignore.
`worktree.useRelativePaths` is deliberately not enabled: hosts with git < 2.48
cannot read such repos.

## Migrate v1 -> v2

Stop all v1 OpenCode instances, then:

```bash
./open-code/migrate-v2.sh
```

Copies `~/.config/opencode`, `~/.local/share/opencode` (sessions, auth) and
`~/.local/state/opencode` into `*-v2` copies; v1 dirs stay untouched. Then edit
`~/.config/opencode-v2/opencode.json`:

- `plugin` -> `plugins`; V1 plugins do not load in v2. Currently:
  `@tarquinen/opencode-dcp@latest` (>= 3.2.0), `@sveltejs/opencode`,
  `opencode-claude-auth` -> `@ex-machina/opencode-anthropic-auth@next`.
  `opencode plugin add <pkg>` also works.
- Move secrets out of the file: `"x-api-key": "{env:EXA_API_KEY}"`,
  figma `client_secret: "{env:FIGMA_CLIENT_SECRET}"`. `oc2` and compose pass
  these env vars through.
- LSP config is accepted but ignored in v2.
- Docs: https://opencode.ai/v2/docs

## Local use: `oc2`

Copy/symlink `oc1` and `oc2` into `~/.local/bin`.

```bash
oc2                       # TUI in $PWD (private --standalone server)
oc2 --gpu                 # same with --gpus all
oc2 shell [--gpu]         # bash in the same container setup
oc2 remote http://10.8.0.5:4096   # TUI against a running server
oc2 connect myserver      # SSH tunnel to myserver:4096 (127.0.0.1 there), then TUI
oc2 disconnect myserver   # close that tunnel
```

`oc2 connect` keeps one SSH tunnel per host (control socket in
`~/.cache/oc2/`). It stays up after the TUI exits, so several clients can share
it; the next `connect` reuses it. Local port: the first free one from
`OC2_LOCAL_PORT` (14096) upwards, so you can connect to several servers at once.

Per-machine settings in `~/.config/oc2.env` (sourced bash):

```bash
OC2_PROJECTS=$HOME/Projects
OC2_SSH_KEY=$HOME/.ssh/ptaq-agent
OC2_EXTRA_MOUNTS=("$HOME/.config/nvim/nvchad")
OC2_CA_DIR=$HOME/.config/agent-ca  # extra CAs to trust (optional)
OPENCODE_PASSWORD=...            # for remote/connect
OC2_LOCAL_PORT=14096             # first local port tried by connect
EXA_API_KEY=...
```

Mounted: `$OC2_PROJECTS`, `$PWD` (if outside it), the `*-v2` OpenCode dirs,
`~/.local/share/pnpm`, `~/.claude`, `~/.config/gh`, `~/.gitconfig` and `~/.config/git` (read-only), the SSH key, extras.
Missing paths are skipped (Docker would otherwise create them as root).

`oc2` uses `--standalone` on purpose: v2 otherwise discovers/starts a shared
per-user background service via `~/.local/state/opencode/service.json`. With
`--network=host` and shared state a container client could attach to a
service running elsewhere (host or another container) and run tools there.

## Server: `docker-compose.yaml`

One long-running `opencode serve` per server, all projects mounted, clients
attach (TUI from laptop, Android app over VPN).

```bash
cd open-code
cp .env.example .env && $EDITOR .env      # HOST_*, AGENT_SSH_KEY, password, keys
# create host dirs first, otherwise Docker creates them root-owned:
mkdir -p ~/.config/opencode-v2 ~/.local/share/opencode-v2 \
         ~/.local/state/opencode-v2 ~/.cache/opencode-v2 ~/.local/share/pnpm
docker compose --profile gpu up -d        # all GPUs
docker compose --profile cpu up -d        # or without GPUs
docker compose --profile gpu logs -f
```

- Password protected (`OPENCODE_SERVER_PASSWORD`, basic auth user `opencode`).
  Clients read the same value from `OPENCODE_PASSWORD`.
- `BIND_IP=127.0.0.1` (default): reachable only through Caddy (HTTPS) or an
  SSH tunnel. `0.0.0.0` exposes plain HTTP on all interfaces; firewall it.
- `.env` is used for compose interpolation only; the container gets the
  variables listed under `environment:`. Add new `{env:NAME}` secrets there.
  (Passing the whole file leaked `PORT=4096` into the agent's shells, so dev
  servers reading `PORT` collided with OpenCode.)
- Dev servers the agent starts are on the host network. Open them from
  another machine through an SSH tunnel
  (`ssh -N -L 4200:localhost:4200 <server>`): apps that need a secure context
  (Web Crypto, service workers) only get one on `localhost` or HTTPS.

### HTTPS / browser / phone

`caddy` (starts with either profile) serves
`https://<host>:${HTTPS_PORT:-4443}` with `TLS_CERT`/`TLS_KEY` (e.g. a
`*.datera.internal` wildcard) and proxies to the server. Open it, log in as
`opencode` + password, "add to home screen" on the phone.

- Why not plain `http://<host>:4096`: if another app on the same hostname sends
  HSTS, the browser upgrades every port to https and fails with
  `SSL_ERROR_RX_RECORD_TOO_LONG`.
- Devices need the issuing CA installed. The OpenCode Android app may ignore
  user-installed CAs; the browser does not.
- Serving under a path (`https://host/oc/`) does not work yet: the UI uses
  root-relative URLs, base-path support is unfinished
  ([#28326](https://github.com/anomalyco/opencode/pull/28326)). A subdomain
  routed through an existing proxy works.
- Firewall: `ufw allow in on tun0 to any port 4443`.

### Clients

```bash
oc2 connect myserver                          # SSH tunnel, works with BIND_IP=127.0.0.1
# TUI on the server itself, in the current project:
docker exec -it -u "$(id -u):$(id -g)" -e HOME="$HOME" -w "$PWD" \
  opencode-v2-gpu opencode --server http://127.0.0.1:4096
```

Recreating the container (`docker compose up -d`) kills the server the agent
runs on; do that yourself, not from an agent session. Sessions persist.
- The server starts in `PROJECTS_DIR`. Known bug
  ([#47665](https://github.com/anomalyco/opencode/issues/47665)): a `--server`
  client sends its *local* cwd as project directory; therefore `oc2 remote`
  connects without a directory. Pick the project/session in the TUI.
- `/var/run/docker.sock` is mounted: that is root-equivalent on the host. The
  container limits accidents (wrong paths, `rm -rf`), not a malicious agent.

## Agent workflows (`workflows` profile)

Deterministic agent workflows (e.g. DWA `pnpm wf implement-issue <n>`) run on
[Hatchet](https://docs.hatchet.run). Every agent step is a session on this
server, so you can open it from any OpenCode client and step in.

| Service | Port (loopback) | Public (Caddy, TLS) | Purpose |
| --- | --- | --- | --- |
| `hatchet-lite` | 8888 UI, 7077 gRPC | `https://<PUBLIC_HOST>:4444` | engine + dashboard |
| `hatchet-postgres` | - (compose network) | - | Hatchet database |
| `ntfy` | 2586 | `https://<PUBLIC_HOST>:4445` | push notifications |
| `workflow-worker` | none (dials out) | - | runs the workflows of `WF_WORKER_DIR` |

The worker uses the same image and mounts as the server but is a separate
container: restarting it (new workflow code) does not touch agent sessions.
It talks to the server on `127.0.0.1:${PORT}` and to Hatchet on
`127.0.0.1:7077`. The workflow code lives in the project, not here.

Setup (once):

```bash
# .env: COMPOSE_PROFILES=gpu,workflows, PUBLIC_HOST, HATCHET_DB_PASSWORD,
#       HATCHET_ADMIN_PASSWORD, NTFY_* and WF_WORKER_DIR (see .env.example)
docker run --rm -it binwiederhier/ntfy:v2.34.0 user hash   # -> NTFY_PASSWORD_HASH (single-quoted)
echo "tk_$(openssl rand -hex 32 | head -c 29)"              # -> NTFY_TOKEN
docker compose up -d hatchet-postgres hatchet-lite ntfy caddy
# worker token -> HATCHET_CLIENT_TOKEN in .env
docker exec opencode-v2-hatchet /hatchet-admin token create --config /config \
  --tenant-id 707d0855-80ab-4e1f-a156-f1c4546cbf52 --name workflow-worker --expiresIn 87600h
docker compose up -d workflow-worker
# the server needs HATCHET_* too (to trigger runs from a session); this kills it:
docker compose up -d opencode-gpu
```

- Dashboard: log in with `HATCHET_ADMIN_EMAIL` / `HATCHET_ADMIN_PASSWORD`;
  signup is disabled. Tenant `Default`.
- ntfy Android app: add server `https://<PUBLIC_HOST>:4445` with user
  `NTFY_USER` / `NTFY_PASSWORD`, subscribe to `NTFY_TOPIC`. Anonymous access
  is denied. The phone needs the issuing CA (same as for the web UI).
- `WF_WORKER_DIR`: a checkout of the project that tracks `master` (e.g. a
  worktree `.worktrees/wf-worker`); update it and
  `docker compose restart workflow-worker` to deploy workflow changes.
- Firewall: `ufw allow in on tun0 to any port 4444,4445 proto tcp`.

## GitHub access via a dedicated SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ptaq-agent -C "opencode-agent"
# add ~/.ssh/ptaq-agent.pub to GitHub; set OC2_SSH_KEY / AGENT_SSH_KEY
```

GitHub and Bitbucket host keys are in `/etc/ssh/ssh_known_hosts`. Verify inside:

```bash
ssh -T git@github.com
git fetch origin --dry-run
```

## Docker Sandboxes (`sbx`) - considered, not used

microVM isolation, network policies and credential proxy are better than a
container, but: GPUs only via dedicated VFIO passthrough, no host networking,
user-level OpenCode config is ignored, symlinks outside the workspace (pnpm
store) are not followed. Revisit for untrusted work.

## References

* [Documentation](https://opencode.ai/docs), [v2 docs](https://opencode.ai/v2/docs)
* [GitHub](https://github.com/anomalyco/opencode)
