# Contributing

Thanks for improving these local-agent supervision skills.

## Ground Rules

- Keep changes small and directly tied to one skill or one repository-level concern.
- Preserve local-first behavior. Do not add hosted services, telemetry, or network dependencies without an explicit design discussion.
- Do not commit generated session artifacts, logs, screenshots, native CLI histories, tokens, or `.env` files.
- Prefer portable examples that use `$env:USERPROFILE`, `$PSScriptRoot`, or relative paths instead of machine-specific absolute paths.

## Development Workflow

1. Fork or branch from `main`.
2. Make a focused change.
3. Run the checks that match the change.
4. Open a pull request using the template.

## Suggested Checks

For repository metadata or documentation-only changes:

```powershell
git status --short --ignored
rg.exe -n "C:\\Users\\[^\\]+|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer [A-Za-z0-9._~+/=-]{20,}" .
```

For skill script changes, run the relevant setup or harness when the target CLI is installed and authenticated:

```powershell
& .\claude-supervision\scripts\claude-setup.ps1
& .\codex-supervision\scripts\codex-setup.ps1
& .\kimi-supervision\scripts\test-kimi-supervision.ps1
```

If a CLI-specific check cannot be run, say why in the pull request.

## Pull Request Checklist

- The change is scoped and easy to review.
- New examples avoid personal paths and secrets.
- Generated artifacts remain ignored.
- Relevant setup or regression checks are listed in the PR.
- Security-sensitive behavior is documented in `SECURITY.md` or `docs/SECURITY_MODEL.md`.
