#!/usr/bin/env bash
# One-time copy of the OpenCode v1 dirs to separate v2 dirs, so v1 (oc1) and
# v2 (oc2 / compose) can run side by side without v2 converting v1's files.
#
#   ~/.config/opencode       -> ~/.config/opencode-v2       (config, commands, skills)
#   ~/.local/share/opencode  -> ~/.local/share/opencode-v2  (sessions, auth)
#   ~/.local/state/opencode  -> ~/.local/state/opencode-v2  (TUI state, history)
#   ~/.cache/opencode-v2     created empty (v1 plugin cache is not reusable)
#
# Refuses to overwrite a non-empty target. Stop all v1 opencode instances
# first so the session database is copied in a consistent state.
set -euo pipefail

die() { echo "migrate-v2: $*" >&2; exit 1; }

PAIRS=(
  "$HOME/.config/opencode:$HOME/.config/opencode-v2"
  "$HOME/.local/share/opencode:$HOME/.local/share/opencode-v2"
  "$HOME/.local/state/opencode:$HOME/.local/state/opencode-v2"
)

for p in "${PAIRS[@]}"; do
  src="${p%%:*}" dst="${p#*:}"
  [ -d "$src" ] || die "source $src does not exist"
  if [ -e "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    die "target $dst exists and is not empty; remove it to re-run"
  fi
done

if pgrep -f '(^|/)opencode( |$)' >/dev/null 2>&1; then
  echo "migrate-v2: an opencode process seems to be running (also checks containers)." >&2
  read -r -p "Continue anyway? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || exit 1
fi

for p in "${PAIRS[@]}"; do
  src="${p%%:*}" dst="${p#*:}"
  echo "copying $src -> $dst"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
done
mkdir -p "$HOME/.cache/opencode-v2"

cat <<'EOF'

Done. v1 dirs are untouched. Next steps (edit ~/.config/opencode-v2, see
https://opencode.ai/v2/docs for the config format):
  - "plugin" -> "plugins": @ex-machina/opencode-anthropic-auth@next,
    @tarquinen/opencode-dcp@latest (>= 3.2), @sveltejs/opencode
  - move MCP secrets to {env:EXA_API_KEY} / {env:FIGMA_CLIENT_SECRET}
  - worktree.directory: ".worktrees"
  - remove v1-only files that v2 ignores (tui.json is migrated to cli.json)
Never point v1 (oc1) at the -v2 dirs.
EOF
