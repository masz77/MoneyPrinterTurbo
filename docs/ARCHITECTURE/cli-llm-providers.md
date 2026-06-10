# CLI LLM Providers (codexcli + claudecli)

## Overview

Adds two swap-in LLM providers that run script/keyword generation through a locally
installed coding-agent CLI using **subscription auth instead of a pay-per-use API key**:

- `llm_provider = "codexcli"` → OpenAI Codex CLI (`codex exec`), auth from `~/.codex/auth.json`
- `llm_provider = "claudecli"` → Claude Code CLI (`claude -p`), auth from `CLAUDE_CODE_OAUTH_TOKEN`

The default provider remains `codexcli`. Both branches live in `_generate_response()` in
`app/services/llm.py` and return early (like the `pollinations` branch), bypassing the
API-key validation that the other providers require.

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Why two CLIs | Offer codexcli **and** claudecli as interchangeable providers | Lets a user pick whichever subscription they already have; default stays codexcli |
| codexcli auth sharing | rw volume mount `~/.codex:/root/.codex` | Codex stores OAuth in a plain file and refreshes/rewrites `auth.json`; a file mount works and a read-only mount would break token refresh |
| claudecli auth sharing | env var `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), supplied via `.env`, injected through compose `x-common-env` | Claude Code stores OAuth in the macOS Keychain, which **cannot** be mounted into a Linux container. The official headless path is a long-lived token from `claude setup-token` passed via env. On the host, normal `claude` login is used |
| codexcli invocation | `codex exec --skip-git-repo-check --output-last-message <tmpfile>`, prompt via stdin (`-`) | Final-message file avoids parsing progress logs from stdout; `--skip-git-repo-check` lets it run from the temp dir; stdin avoids arg length/quoting issues |
| claudecli invocation | `claude -p --output-format text`, optional `--model`, prompt via stdin | `-p` is non-interactive print mode; `text` output is read directly from stdout (no message file needed); stdin avoids arg length/quoting issues |
| codexcli sandbox | `--dangerously-bypass-approvals-and-sandbox` inside containers, `--sandbox read-only` on host | Landlock sandboxing is unavailable inside Docker; the container is the isolation boundary. On bare host the read-only sandbox is kept. (claudecli takes no sandbox flag) |
| Working directory | both subprocesses run with `cwd=tempfile.gettempdir()` | `codex exec` reads `AGENTS.md` and `claude -p` reads `CLAUDE.md` / `.claude/` from the cwd; running in the repo would silently inject project context into generated video scripts |
| Cross-platform encoding | both subprocess calls set `encoding="utf-8"` (`errors="replace"`) | Avoids mojibake/decode errors on Windows where the default console encoding is not UTF-8 |
| Install method | nodesource Node 22 + `npm i -g @openai/codex@0.139.0 @anthropic-ai/claude-code@2.1.170` in Dockerfile | npm resolves the right platform binary (arm64/amd64); release-asset URLs are arch/naming-volatile and 404 across versions |
| Pinned versions | both CLIs pinned to exact versions | The code depends on specific flags (`codex exec --output-last-message`, `claude -p --output-format`); pinning to a container-verified version prevents a future CLI release from silently breaking the integration |

## Key Files

| File | Purpose |
|------|---------|
| `app/services/llm.py` | `codexcli` and `claudecli` branches in `_generate_response()`; also fixes a pre-existing `generate_terms` bug (returns `[]` instead of an error string) |
| `Dockerfile` | Installs Node 22 + both pinned CLIs (`@openai/codex@0.139.0`, `@anthropic-ai/claude-code@2.1.170`) |
| `docker-compose.yml` | `x-common-volumes` mounts `~/.codex`; `x-common-env` injects `CLAUDE_CODE_OAUTH_TOKEN`; both applied to `webui` and `api` |
| `webui/Main.py` | Adds "Codex CLI" and "Claude CLI" to the provider dropdown + per-provider helper tips |
| `config.example.toml` | Documents `codexcli_*` and `claudecli_*` keys (`*_model_name`, `*_bin`, `*_timeout`) |
| `.gitignore` | Ignores `.env` so the Claude OAuth token is never committed |

## Data Flow

```
topic → generate_script() / generate_terms() → _generate_response()
  ├─ codexcli  → subprocess.run([codex, exec, --output-last-message <tmp>, "-"], input=prompt, cwd=tmpdir)
  │              → read tmpfile → _normalize_text_response()
  └─ claudecli → subprocess.run([claude, -p, --output-format text], input=prompt, cwd=tmpdir)
                 → read stdout → _normalize_text_response()
→ script / search terms
```

Both branches resolve the binary from config (`*_bin`) or `PATH`, apply an optional model
name, and enforce a `*_timeout` (default 180s) to keep the WebUI from hanging forever.

## Security Considerations

- **No API keys.** codexcli reuses the user's existing Codex OAuth token file; claudecli
  uses a subscription OAuth token.
- **Token never in the compose file.** `CLAUDE_CODE_OAUTH_TOKEN` is read from a gitignored
  `.env` next to `docker-compose.yml` (`${CLAUDE_CODE_OAUTH_TOKEN:-}`), not hardcoded.
- **cwd isolation.** Running both CLIs from a temp dir prevents `AGENTS.md` / `CLAUDE.md` /
  `.claude/` from being read into the prompt, which would both leak repo context and
  corrupt generated scripts.
- **Sandbox bypass scoped to containers.** codexcli only passes
  `--dangerously-bypass-approvals-and-sandbox` when `config.is_running_in_container()`,
  where the container is the boundary. Prompts are app-generated (they do embed the
  user-supplied `video_subject`), and the temp cwd plus narrow mounts limit the writable surface.
- **Local-only exposure.** The `~/.codex` mount exposes session state to the container;
  acceptable for a loopback-only deployment (ports bound to `127.0.0.1` in docker-compose).
