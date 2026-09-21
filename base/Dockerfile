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

RUN mkdir -p /home/node/.npm-global && \
  mkdir -p /home/node/.config && \
  mkdir -p /home/node/.local && \
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

# 6. Bash Configuration
# Add the path export to bashrc so interactive shells pick it up
RUN echo "export PATH=${NPM_CONFIG_PREFIX}/bin:${BUN_INSTALL}/bin:\$PATH" >> /home/node/.bashrc

# 7. Copy config files to the 'node' user's home
COPY --chown=node:node ./.bash_aliases /home/node/.bash_aliases
# Global pnpm config (see pnpm-config.yaml for rationale)
COPY --chown=node:node ./pnpm-config.yaml /home/node/.config/pnpm/config.yaml
RUN echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> /home/node/.bashrc

CMD ["/bin/bash"]
