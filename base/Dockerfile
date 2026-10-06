FROM node:26-slim

ARG TARGETARCH
# Single source of truth for apt-installed tooling. Override per-build with:
#   docker build --build-arg LOCAL_TOOLS="..." -f base/Dockerfile base
ARG LOCAL_TOOLS="git curl jq ripgrep vim nano make zip unzip ssh-client wget tree imagemagick ca-certificates gnupg procps build-essential python3 python3-pip redis-tools"

# 1. Install System Dependencies (as root)
RUN apt-get update && \
  apt-get install -y --no-install-recommends ${LOCAL_TOOLS} && \
  rm -rf /var/lib/apt/lists/*

# Install also GH that is not in official apt source
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update && apt-get install -y gh \
  && rm -rf /var/lib/apt/lists/*

# Install Bun by copying from the official image
# This installs bun globally to /usr/local/bin so it is available to everyone
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun
# Create the bunx symlink (standard practice)
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx

# Install k6 (load testing) from the official image. It is a static Go binary
# (CGO_ENABLED=0), so the Alpine-built binary runs fine on this Debian base.
# Pinned: bump the tag deliberately (https://github.com/grafana/k6/releases).
COPY --from=grafana/k6:2.3.0 /usr/bin/k6 /usr/local/bin/k6

# Install uv / uvx (Python package & project manager) from the official image.
# Pinned: bump the tag deliberately (https://github.com/astral-sh/uv/releases).
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /uvx /usr/local/bin/

# Install Playwright system dependencies for Chromium (required by agent-browser)
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends chromium chromium-sandbox && \
      rm -rf /var/lib/apt/lists/*; \
    else \
      npx playwright install-deps chromium; \
    fi

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD_ARM64=1

# Corepack (no longer bundled with Node since v25, install manually)
RUN npm install -g corepack && corepack enable

# 2. Configure the existing 'node' user
# The node image usually creates the node user. We ensure it owns the app dir.
# Remap 'node' to the host user's UID/GID so bind-mounted host dirs
# (~/.local/share/opencode, project dirs, ...) are writable inside the container.
# Defaults keep the stock 1000:1000; the Makefile passes `id -u`/`id -g`.
# Must run before `USER node` so all later layers are owned by the new UID.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN set -eux; \
    test "$HOST_UID" != 0 || { echo "HOST_UID=0 not allowed (don't build with sudo)" >&2; exit 1; }; \
    if [ "$(id -u node)" != "$HOST_UID" ] || [ "$(id -g node)" != "$HOST_GID" ]; then \
      groupmod -o -g "$HOST_GID" node; \
      usermod -o -u "$HOST_UID" -g "$HOST_GID" node; \
      chown -R node:node /home/node; \
    fi
WORKDIR /app
RUN chown -R node:node /app

# 3. Switch to 'node' user for config setup
USER node

# 4. Configure NPM global location for the 'node' user
# This allows npm install -g without root permissions
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=$NPM_CONFIG_PREFIX/bin:$PATH

# Configure Bun global location for 'node' user ---
# This ensures 'bun install -g' works without root and saves to the user home
ENV BUN_INSTALL=/home/node/.bun
ENV PATH=$BUN_INSTALL/bin:$PATH

# User-local executables: `uv tool install` targets, plus the stable chromium
# symlink created below for k6.
ENV PATH=/home/node/.local/bin:$PATH

# uv: /app is a bind mount on a different filesystem than ~/.cache/uv, so
# hardlinks fail; copy instead to avoid per-install warnings.
ENV UV_LINK_MODE=copy

RUN mkdir -p /home/node/.npm-global && \
  mkdir -p /home/node/.config && \
  mkdir -p /home/node/.local/bin && \
  mkdir -p /home/node/.bun/bin

# SSH dir must exist and be owned by 'node' before any key files are bind-mounted
# into it; otherwise Docker creates it as root:root and ssh cannot write known_hosts.
# Pre-seed GitHub's host keys so the first non-interactive git/ssh call succeeds.
RUN mkdir -p /home/node/.ssh && \
  chmod 700 /home/node/.ssh && \
  ssh-keyscan -t ed25519,rsa,ecdsa github.com > /home/node/.ssh/known_hosts 2>/dev/null && \
  chmod 600 /home/node/.ssh/known_hosts

# 5. Install agent-browser (headless browser automation CLI for AI agents)
# Downloads Chromium browser to user's cache
RUN npm install -g agent-browser && \
    if [ "$TARGETARCH" != "arm64" ]; then agent-browser install; fi

# Set executable path for runtime (only matters on ARM, harmless on x86 if unset)
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# Point k6's browser module at the Chromium already in this image.
# arm64: apt's /usr/bin/chromium. amd64: the Chrome for Testing build that
# `agent-browser install` downloaded, flattened to
# ~/.agent-browser/browsers/chrome-<version>/chrome (Playwright's
# chrome-linux*/chrome layout is matched too, as a fallback).
# Symlink whichever exists to a stable path so the ENV below never goes stale.
RUN set -eux; \
    if [ -x /usr/bin/chromium ]; then \
      chrome=/usr/bin/chromium; \
    else \
      chrome="$(find /home/node/.agent-browser/browsers /home/node/.cache/ms-playwright \
                  -type f -name chrome -path '*/chrome-*/chrome' 2>/dev/null \
                | sort -V | tail -n 1)"; \
    fi; \
    if [ -z "$chrome" ]; then echo "k6: no Chromium found for K6_BROWSER_EXECUTABLE_PATH" >&2; exit 1; fi; \
    ln -sf "$chrome" /home/node/.local/bin/chromium; \
    /home/node/.local/bin/chromium --version
ENV K6_BROWSER_EXECUTABLE_PATH=/home/node/.local/bin/chromium
ENV K6_BROWSER_HEADLESS=true
# Same as grafana/k6:with-browser: no-sandbox avoids needing SYS_ADMIN in the container
ENV K6_BROWSER_ARGS=no-sandbox

# Sanity-check the copied binaries
RUN k6 version && uv --version && uvx --version

# 6. Install gh CLI extensions
# Installed by hand rather than via `gh extension install`, which is gated
# behind `gh auth login` even for public repos (cli/cli#2680). Release assets
# themselves are public, so a plain download works with no token at build time.
# The manifest.yml mirrors what gh itself writes, so `gh extension list` and
# `gh extension upgrade gh-stack` work at runtime.
# Extensions are per-user: this must run as 'node'.
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64|arm64) asset="linux-$arch" ;; \
      *) echo "gh-stack: unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/github/gh-stack/releases/latest/download/$asset"; \
    tag="$(curl -fsS -o /dev/null -w '%{redirect_url}' "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"; \
    test -n "$tag"; \
    dir="/home/node/.local/share/gh/extensions/gh-stack"; \
    mkdir -p "$dir"; \
    curl -fsSL -o "$dir/gh-stack" "$url"; \
    chmod +x "$dir/gh-stack"; \
    printf 'owner: github\nname: gh-stack\nhost: github.com\ntag: %s\nispinned: false\npath: %s/gh-stack\n' \
      "$tag" "$dir" > "$dir/manifest.yml"; \
    "$dir/gh-stack" --help > /dev/null

# 7. Bash Configuration
# Add the path export to bashrc so interactive shells pick it up
RUN echo "export PATH=/home/node/.local/bin:${NPM_CONFIG_PREFIX}/bin:${BUN_INSTALL}/bin:\$PATH" >> /home/node/.bashrc

# 8. Copy config files to the 'node' user's home
COPY --chown=node:node ./.bash_aliases /home/node/.bash_aliases
# Global pnpm config (see pnpm-config.yaml for rationale)
COPY --chown=node:node ./pnpm-config.yaml /home/node/.config/pnpm/config.yaml
RUN echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> /home/node/.bashrc

CMD ["/bin/bash"]
