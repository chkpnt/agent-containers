# Open Code

## Build Instructions

Use the top level `Makefile` to build this. It builds the shared `agent-base`
image first, then layers this tool on top.

```bash
make open-code
```

You can add more local tools to the container to be installed via `apt-get` by
extending the `LOCAL_TOOLS` list in `base/Dockerfile`, which is the single
source of truth for the shared base image.

## Run Instructions
- Just create the following file, make it executable with `chmod +x` and place it in `~/.local/bin`
- Startup is a bit slow due to container startup time, but taking ~5s startup penalty for safety measures is not so bad.
- I also add the host mapping to host.docker.internal so the container can access your localhost (useful for the agent-browser or similar MCPs to access your apps running on localhost)
- There are 4 volumes, make sure the directories in your $HOME exist and with the correct user privilege (your $UID):
  1. opencode global state - UI state, command history, model preferences, recently opened files
  2. opencode global share - Auth tokens, session data, LSP servers, git snapshots for undo, logs
  3. opencode global config - User configuration: themes, keybindings, custom commands, plugins 
  3. the repo you work - mounted as current PWD when executing `opencode` in your terminal

```bash
#!/usr/bin/env bash

PROJ="$(basename "$(pwd)")"
NAME="open-code-${PROJ}"

exec docker run --rm --tty --interactive \
  --name "$NAME" \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOME/.local/state/opencode:/home/node/.local/state/opencode" \
  -v "$HOME/.local/share/opencode:/home/node/.local/share/opencode" \
  -v "$HOME/.config/opencode:/home/node/.config/opencode" \
  -v "$(pwd):/app:rw" \
  open-code "$@"
```

## GitHub access via a dedicated SSH key

Give the agent its own deploy/user key rather than mounting your whole `~/.ssh`:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ptaq-agent -C "opencode-agent"
# add ~/.ssh/ptaq-agent.pub to GitHub, then mount only that key pair:
  -v "$HOME/.ssh/ptaq-agent:/home/node/.ssh/id_ed25519:ro" \
  -v "$HOME/.ssh/ptaq-agent.pub:/home/node/.ssh/id_ed25519.pub:ro" \
  -v "$HOME/.config/gh:/home/node/.config/gh" \   # optional: gh CLI auth
```

The base image pre-creates `/home/node/.ssh` (owned by `node`, mode 700) with
GitHub's host keys already in `known_hosts`. Without that, Docker would create
the directory as `root:root` when mounting the key files and ssh would fail
with `Failed to add the host to the list of known hosts`.

Verify inside the container:

```bash
ssh -T git@github.com        # expect: Hi <user>! You've successfully authenticated...
git fetch origin --dry-run
```

## References

* [Documentation](https://opencode.ai/docs)
* [Github Repo](https://github.com/sst/opencode)
