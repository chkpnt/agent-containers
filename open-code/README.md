# Open Code

Two images live side by side:

| image          | base            | OpenCode            | launcher | config/state dirs on host          |
|----------------|-----------------|---------------------|----------|------------------------------------|
| `open-code:v1` | `agent-base`    | `opencode-ai` (1.x) | `oc1`    | `~/.config/opencode`, ...          |
| `open-code:v2` | `agent-base:v2` | `@opencode/cli` (2.x) | `oc2`, `compose.yaml` | `~/.config/opencode-v2`, ... |

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
- If `/var/run/docker.sock` is mounted, the user is added to its group.
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

### pnpm global virtual store (optional, per repo)

Makes new worktrees almost free (`node_modules` = symlinks into the shared
store). Experimental; add to the repo's `pnpm-workspace.yaml`:

```yaml
virtualStoreType: global        # pnpm >= 11.23 (older: enableGlobalVirtualStore: true)
```

See https://pnpm.io/git-worktrees. Symlinks are relative, so the store must be
mounted at the same path too (it is).

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
```

Per-machine settings in `~/.config/oc2.env` (sourced bash):

```bash
OC2_PROJECTS=$HOME/Projects
OC2_SSH_KEY=$HOME/.ssh/ptaq-agent
OC2_EXTRA_MOUNTS=("$HOME/.config/nvim/nvchad")
OPENCODE_SERVER_PASSWORD=...     # for remote/connect
EXA_API_KEY=...
```

Mounted: `$OC2_PROJECTS`, `$PWD` (if outside it), the `*-v2` OpenCode dirs,
`~/.local/share/pnpm`, `~/.claude`, `~/.config/gh`, the SSH key, extras.
Missing paths are skipped (Docker would otherwise create them as root).

`oc2` uses `--standalone` on purpose: v2 otherwise discovers/starts a shared
per-user background service via `~/.local/state/opencode/service.json`. With
`--network=host` and shared state a container client could attach to a
service running elsewhere (host or another container) and run tools there.

## Server: `compose.yaml`

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
- `BIND_IP=0.0.0.0` exposes the port on all interfaces: firewall it to the VPN
  (e.g. `ufw allow in on tun0 to any port 4096`) or set `BIND_IP` to the
  VPN IP / `127.0.0.1` and use `oc2 connect`.
- The server starts in `PROJECTS_DIR`. Known bug
  ([#47665](https://github.com/anomalyco/opencode/issues/47665)): a `--server`
  client sends its *local* cwd as project directory; therefore `oc2 remote`
  connects without a directory. Pick the project/session in the TUI.
- `/var/run/docker.sock` is mounted: that is root-equivalent on the host. The
  container limits accidents (wrong paths, `rm -rf`), not a malicious agent.

## GitHub access via a dedicated SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ptaq-agent -C "opencode-agent"
# add ~/.ssh/ptaq-agent.pub to GitHub; set OC2_SSH_KEY / AGENT_SSH_KEY
```

GitHub host keys are in `/etc/ssh/ssh_known_hosts`. Verify inside:

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
