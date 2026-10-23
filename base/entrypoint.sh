#!/usr/bin/env bash
# Runtime user setup for agent-base:v2.
#
# The image contains no user-specific data. At start (as root) this script
# creates a user matching the host, so bind mounts at host paths are usable:
#
#   HOST_USER  user name            (default: agent)
#   HOST_UID   numeric uid          (default: 1000)
#   HOST_GID   numeric gid          (default: HOST_UID)
#   HOST_HOME  home directory path  (default: /home/$HOST_USER)
#
# Then it drops privileges with setpriv and execs the command.
# If the container is already started as non-root (e.g. podman
# --userns=keep-id or docker --user), it only execs the command.
set -euo pipefail

log() { echo "entrypoint: $*" >&2; }

if [ "$(id -u)" != 0 ]; then
  exec "$@"
fi

NAME="${HOST_USER:-agent}"
UID_="${HOST_UID:-1000}"
GID_="${HOST_GID:-$UID_}"
HOME_="${HOST_HOME:-/home/$NAME}"

case "$UID_$GID_" in *[!0-9]*|'') log "HOST_UID/HOST_GID must be numeric"; exit 1 ;; esac
if [ "$UID_" = 0 ]; then
  log "refusing to run the agent as root (HOST_UID=0)"; exit 1
fi

# --- group -----------------------------------------------------------------
if GROUP="$(getent group "$GID_" | cut -d: -f1)" && [ -n "$GROUP" ]; then
  :
else
  GROUP="$NAME"
  getent group "$GROUP" >/dev/null && GROUP="${NAME}-grp"
  groupadd -g "$GID_" "$GROUP"
fi

# --- user (idempotent across container restarts) ----------------------------
if getent passwd "$NAME" >/dev/null; then
  usermod -o -u "$UID_" -g "$GID_" -d "$HOME_" -s /bin/bash "$NAME"
elif OLD="$(getent passwd "$UID_" | cut -d: -f1)" && [ -n "$OLD" ]; then
  usermod -l "$NAME" -g "$GID_" -d "$HOME_" -s /bin/bash "$OLD"
else
  useradd -o -M -u "$UID_" -g "$GID_" -d "$HOME_" -s /bin/bash "$NAME"
fi

# --- home --------------------------------------------------------------------
# Docker creates missing parents of bind mounts (~/.config, ~/.local/share,
# ~/.ssh, ...) as root. Hand those to the user, but never touch mount points
# (that would chown host directories).
mkdir -p "$HOME_"
while IFS= read -r -d '' d; do
  mountpoint -q "$d" && continue
  chown "$UID_:$GID_" "$d"
done < <(find "$HOME_" -xdev -maxdepth 4 -type d -user 0 -print0 2>/dev/null)
if [ -d "$HOME_/.ssh" ] && ! mountpoint -q "$HOME_/.ssh"; then
  chmod 700 "$HOME_/.ssh"
fi

as_user() { setpriv --reuid "$UID_" --regid "$GID_" --init-groups -- "$@"; }

# --- docker.sock -------------------------------------------------------------
SOCK=/var/run/docker.sock
if [ -S "$SOCK" ]; then
  SOCK_GID="$(stat -c %g "$SOCK")"
  if [ "$SOCK_GID" = 0 ]; then
    log "docker.sock is owned by gid 0; not granting access (use a docker group on the host)"
  else
    SOCK_GROUP="$(getent group "$SOCK_GID" | cut -d: -f1 || true)"
    if [ -z "$SOCK_GROUP" ]; then
      SOCK_GROUP=docker-host
      groupadd -o -g "$SOCK_GID" "$SOCK_GROUP"
    fi
    usermod -aG "$SOCK_GROUP" "$NAME"
  fi
fi

# --- gh extensions (staged in /opt by the image) -----------------------------
if [ -d /opt/gh-extensions ]; then
  as_user mkdir -p "$HOME_/.local/share/gh/extensions"
  for ext in /opt/gh-extensions/*; do
    dest="$HOME_/.local/share/gh/extensions/$(basename "$ext")"
    [ -e "$dest" ] || as_user ln -s "$ext" "$dest"
  done
fi

# --- pnpm --------------------------------------------------------------------
# Explicit storeDir at the host's default location (mounted at the same path):
# without it pnpm puts a store at the root of the project's mount because the
# home store is on a different mount. Only written if absent, so a mounted
# host config is never overwritten.
PNPM_CFG="$HOME_/.config/pnpm/config.yaml"
if [ ! -e "$PNPM_CFG" ]; then
  as_user mkdir -p "$(dirname "$PNPM_CFG")"
  # shellcheck disable=SC2016 # $1/$2 are expanded by the inner sh
  as_user sh -c '{ cat /etc/agent/pnpm-config.yaml; printf "\nstoreDir: %s\n" "$1"; } > "$2"' \
    _ "$HOME_/.local/share/pnpm/store" "$PNPM_CFG"
fi

# --- environment + drop privileges ------------------------------------------
export HOME="$HOME_" USER="$NAME" LOGNAME="$NAME" SHELL=/bin/bash
# User-level global installs (npm i -g, bun add -g, uv tool) go to ~/.local
# (container-local unless mounted); system tools in /usr/local stay read-only.
export NPM_CONFIG_PREFIX="$HOME_/.local"
export BUN_INSTALL="$HOME_/.bun"
export PATH="$HOME_/.local/bin:$HOME_/.bun/bin:$PATH"

exec setpriv --reuid "$UID_" --regid "$GID_" --init-groups -- "$@"
