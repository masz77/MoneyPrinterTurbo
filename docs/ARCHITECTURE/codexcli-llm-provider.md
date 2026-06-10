# Codex CLI LLM Provider

## Overview

Adds `llm_provider = "codexcli"` so script/keyword generation runs through the locally
installed OpenAI Codex CLI (`codex exec`) using ChatGPT subscription auth instead of a
pay-per-use API key. Auth lives in the host's `~/.codex/auth.json`, which is volume-mounted
into the Docker containers.

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| CLI choice | Codex CLI, not Claude Code | Codex auth is a mountable file (`~/.codex/auth.json`); Claude Code stores OAuth in the macOS Keychain, which cannot be shared into a Linux container |
| Invocation | `codex exec` subprocess with `--output-last-message <tmpfile>`, prompt via stdin | Final message file avoids parsing progress logs from stdout; stdin avoids shell-arg length/quoting issues |
| Sandbox | `--dangerously-bypass-approvals-and-sandbox` only inside containers, `--sandbox read-only` on host | Landlock sandboxing is unavailable inside Docker; the container itself is the isolation boundary. On bare host the read-only sandbox is kept |
| Install method | nodesource Node 22 + `npm i -g @openai/codex` in Dockerfile | Release-binary URLs are arch/naming-volatile; npm package resolves the right platform binary |
| Auth sharing | rw volume mount `~/.codex:/root/.codex` | Codex refreshes tokens and rewrites `auth.json`; a read-only mount would break refresh |

## Key Files

| File | Purpose |
|------|---------|
| `app/services/llm.py` | `codexcli` branch in `_generate_response()` (early-return style, like `pollinations`) |
| `Dockerfile` | Installs Node + `@openai/codex` |
| `docker-compose.yml` | Mounts `${HOME}/.codex` into both `webui` and `api` services |
| `webui/Main.py` | Adds "Codex CLI" to the provider dropdown + helper tips |
| `config.example.toml` | Documents `codexcli_model_name`, `codexcli_timeout` |

## Data Flow

topic → `generate_script()` / `generate_terms()` → `_generate_response()` →
`subprocess.run([codex, "exec", ...], input=prompt)` → final message written to tmpfile →
read + `_normalize_text_response()` → script / search terms.

## Security Considerations

- No API keys stored; auth is the user's existing Codex OAuth token file.
- Sandbox bypass is restricted to container runs (`config.is_running_in_container()`),
  where the container is the boundary. Prompts are app-generated, not user shell input.
- `~/.codex` mount exposes session history to the container; acceptable for a local,
  loopback-only deployment (ports bound to 127.0.0.1 in docker-compose).
