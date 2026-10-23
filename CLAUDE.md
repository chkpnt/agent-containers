# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands
- `make all` - Build all containers
- `make claude-code` - Build Claude Code container
- `make openai-codex` - Build OpenAI Codex container
- `make open-code` - Build OpenCode v1 container (old `agent-base`)
- `make open-code-v2` - Build `agent-base:v2` (Ubuntu 26.04, runtime user via `base/entrypoint.sh`) and `open-code:v2`
- `make clean` - Remove Docker images and prune dangling images

## Run Commands
- Claude Code: `docker run -it --rm -v ${HOME}/.config/claude/claude.json:/home/codeuser/.claude.json:rw -v $(pwd):/app:rw claude-code`
- OpenAI Codex: `docker run -it --rm -e OPENAI_API_KEY -v ${HOME}/.config/codex:/home/codeuser/.codex:rw -v $(pwd):/app:rw openai-codex`
- OpenCode v1: `open-code/oc1`; v2 local: `open-code/oc2` (same-path mounts, see `open-code/README.md`)
- OpenCode v2 server: `cd open-code && docker compose --profile gpu|cpu up -d` (needs `.env` from `.env.example`)
- Aider: `docker run -it --rm --user $(id -u):$(id -g) -e OPENAI_API_KEY -e ANTHROPIC_API_KEY -v $(pwd):/app:rw paulgauthier/aider`

## Code Style Guidelines
- Docker-based project with separate containers for different AI assistants
- Use explicit mounting of configuration files with appropriate permissions (700/600)
- Keep API keys and credentials in mounted configuration files, never in code
- Document configuration persistence in README files per tool
- Bash commands should use `$(pwd)` for current directory mounting
- Prioritize security for configuration files containing API keys