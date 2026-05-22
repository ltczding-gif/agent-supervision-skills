# Installation

Each skill is a normal skill directory containing a `SKILL.md` entry point and supporting scripts. Install only the skill folders you need.

## Install Into `.agents\skills`

Use this for environments that discover skills from `$env:USERPROFILE\.agents\skills`.

```powershell
$repo = "C:\path\to\agent-supervision-skills"
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills"

New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
Copy-Item (Join-Path $repo "claude-supervision") (Join-Path $skillRoot "claude-supervision") -Recurse -Force
Copy-Item (Join-Path $repo "kimi-supervision") (Join-Path $skillRoot "kimi-supervision") -Recurse -Force
```

## Install Into `.claude\skills`

Use this for Claude environments that discover skills from `$env:USERPROFILE\.claude\skills`.

```powershell
$repo = "C:\path\to\agent-supervision-skills"
$skillRoot = Join-Path $env:USERPROFILE ".claude\skills"

New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
Copy-Item (Join-Path $repo "codex-supervision") (Join-Path $skillRoot "codex-supervision") -Recurse -Force
```

## Setup Checks

After installing, run the setup command for the skill you plan to use:

```powershell
& "$env:USERPROFILE\.agents\skills\claude-supervision\scripts\claude-setup.ps1"
& "$env:USERPROFILE\.claude\skills\codex-supervision\scripts\codex-setup.ps1"
& "$env:USERPROFILE\.agents\skills\kimi-supervision\scripts\test-kimi-supervision.ps1"
```

These commands require the corresponding target CLI to be installed and authenticated.

## Artifact Locations

Each skill writes local artifacts such as prompts, responses, stderr logs, and session metadata. See the `State layout` section in each skill's `SKILL.md`.

For sensitive runs, set the matching state-root environment variable to a temporary or private directory:

```powershell
$env:CLAUDE_SUPERVISION_HOME = Join-Path $env:TEMP "claude-supervision"
$env:CODEX_SUPERVISION_HOME = Join-Path $env:TEMP "codex-supervision"
$env:KIMI_SUPERVISION_HOME = Join-Path $env:TEMP "kimi-supervision"
```
