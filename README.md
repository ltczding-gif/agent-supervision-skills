# Agent Supervision Skills

Local-first supervision skills for delegating work to another coding agent, collecting its artifacts, and independently verifying the result before trusting it.

This repository packages three standalone skills:

| Skill | Delegates to | Typical caller | Primary use |
| --- | --- | --- | --- |
| `claude-supervision` | Claude Code CLI | Codex, Kimi, scripts, other agents | Ask Claude Code to perform or review work, then inspect its artifacts. |
| `codex-supervision` | Codex CLI | Claude Desktop / Claude Code environments | Ask Codex to review or rescue work from Claude-facing workflows. |
| `kimi-supervision` | Kimi Code CLI | Codex or other local agents | Ask Kimi Code to do local work, recover native output when stdout is incomplete, and classify trust. |

Supervision means the caller does not blindly relay another agent's final text. Each skill writes prompts, responses, stderr, and structured session metadata to disk so a supervising agent can inspect what actually happened.

## Why This Exists

Agent-to-agent handoffs often fail quietly: stdout is empty, the target CLI timed out, a native log contains the real answer, or the delegated agent claims a fix without evidence. These skills add a local supervision layer around those handoffs so the caller can inspect artifacts before trusting the result.

The project is intentionally narrow: it is not a hosted orchestrator or a unified agent API. It is a set of Windows-first PowerShell wrappers for local CLI agents, built around audit trails, recovery paths, and explicit verification.

## Who This Is For

- Windows-first agent-tooling developers who need reliable local CLI delegation.
- Claude Desktop or Claude Code users who want Codex review/rescue workflows without relying on a plugin-only path.
- Local multi-agent power users who compare Claude, Codex, and Kimi on the same task.
- Batch or research workflow authors who need timeout, recovery, and structured artifacts.
- Security-conscious developers who want local, inspectable handoffs instead of blind relays.

See [docs/USE_CASES.md](docs/USE_CASES.md) for detailed personas, pain points, example workflows, and boundaries.

## Repository Layout

```text
.
├── claude-supervision/
│   ├── SKILL.md
│   └── scripts/
├── codex-supervision/
│   ├── SKILL.md
│   └── scripts/
├── kimi-supervision/
│   ├── SKILL.md
│   ├── agents/
│   └── scripts/
├── docs/
│   ├── INSTALLATION.md
│   ├── USE_CASES.md
│   └── SECURITY_MODEL.md
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
├── AGENTS.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── CHANGELOG.md
└── LICENSE
```

Each skill folder is self-contained. You can copy only the folder you need.

## Requirements

These skills are designed and tested for Windows-first local agent workflows.

- Windows with PowerShell 7+ (`pwsh.exe`) is the primary supported environment.
- Other platforms may work only where the target CLI and PowerShell scripts behave compatibly; they are not validated yet.
- A locally installed and authenticated target CLI for the skill you use:
  - `claude-supervision`: Claude Code CLI (`claude`)
  - `codex-supervision`: Codex CLI (`codex`)
  - `kimi-supervision`: Kimi Code CLI (`kimi`)
- Permission to write local session artifacts under the skill's state directory.

The scripts are intentionally local-first and Windows-oriented. They do not provide a hosted service, cloud queue, remote execution environment, or cross-platform compatibility layer.

## Quick Start

Clone or download the repository, then copy the desired skill folder into the skill root used by your agent environment.

For an agent environment that reads from `$env:USERPROFILE\.agents\skills`:

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills"
Copy-Item ".\claude-supervision" (Join-Path $skillRoot "claude-supervision") -Recurse
Copy-Item ".\kimi-supervision" (Join-Path $skillRoot "kimi-supervision") -Recurse
```

For Claude environments that read from `$env:USERPROFILE\.claude\skills`:

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".claude\skills"
Copy-Item ".\codex-supervision" (Join-Path $skillRoot "codex-supervision") -Recurse
```

Then open the target skill's `SKILL.md` and run its setup command.

## Safety Notes

- These wrappers store prompts and outputs on disk. Do not run sensitive tasks unless you are comfortable with local artifact retention.
- Use the `*_SUPERVISION_HOME` environment variables documented in each `SKILL.md` to redirect artifacts to a temporary or private directory.
- Do not commit generated `sessions/`, `artifacts/`, logs, `.env` files, or native CLI history.
- Treat outputs from delegated agents as untrusted until inspected by the supervising agent or human reviewer.

For the fuller threat model, see [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md).

## Contributing

Small, focused improvements are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
