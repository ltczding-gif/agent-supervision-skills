# Agent Instructions

This repository contains three standalone supervision skills. Treat each skill folder as an independent package unless the user explicitly asks for a cross-skill change.

## Structure

- `claude-supervision/`: wrappers for delegating to Claude Code CLI.
- `codex-supervision/`: wrappers for delegating to Codex CLI.
- `kimi-supervision/`: wrappers for delegating to Kimi Code CLI.
- `docs/`: repository-level installation and security notes.

## Change Rules

- Keep edits surgical.
- Do not change runtime script behavior when the request is only about repository metadata or publishing.
- Use portable paths in documentation: prefer `$env:USERPROFILE`, `$PSScriptRoot`, or relative paths.
- Do not commit generated `sessions/`, `artifacts/`, logs, `.env` files, native CLI histories, or credentials.
- Preserve PowerShell 7 compatibility for scripts.

## Verification

For docs-only or repository metadata changes, at minimum run:

```powershell
git status --short --ignored
rg.exe -n "C:\\Users\\[^\\]+|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer [A-Za-z0-9._~+/=-]{20,}" .
```

For script changes, run the setup or test harness for the affected skill when the target CLI is available and authenticated.
