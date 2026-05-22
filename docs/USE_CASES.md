# Use Cases

## Core Thesis

Agent Supervision Skills helps one local agent delegate work to another local CLI agent without turning that delegation into a blind relay.

The project is best understood as a supervision layer:

- it records what was asked
- it records what came back
- it captures stderr and structured session metadata
- it preserves recovery paths when stdout is empty or incomplete
- it gives the supervising agent or human artifacts to inspect before trusting the result

This is not a cloud orchestrator, sandbox, policy engine, or generic multi-agent framework. It is a Windows-first set of PowerShell wrappers for supervising real local CLI handoffs.

## Who It Is For

### Windows-First Agent Tooling Developers

You are building workflows around local CLIs such as Claude Code, Codex, or Kimi Code and need predictable non-interactive execution. These skills provide timeout handling, stdout/stderr capture, session directories, and structured metadata.

### Claude Desktop And Claude Code Power Users

You want one agent environment to consult another model or CLI, especially for code review and rescue tasks. For example, Claude can delegate an adversarial review to Codex, then inspect the result before presenting it.

### Local Multi-Agent Experimenters

You compare multiple agents on the same task and care about repeatability. The saved prompts, responses, and metadata make it easier to compare how different CLIs behaved instead of relying on a chat transcript.

### Batch And Research Workflow Authors

You run long or repeated local jobs where agent output may be empty, delayed, or recoverable only from native files. Kimi-style native recovery and result classification are useful for extraction, review, and triage pipelines.

### Security-Conscious Developers And Teams

You do not want delegated agent output to be trusted automatically. You want local artifacts, narrow workspaces, review-first defaults, and explicit reminders that verification is required.

## Pain Points Solved

### Blind Handoffs

Without supervision, Agent A may simply repeat Agent B's final answer. That is risky when Agent B did not actually inspect the file, did not run the test, or only produced a plausible explanation.

These skills make the handoff inspectable by writing prompts, responses, stderr, and metadata to disk.

### Empty Or Misleading Stdout

Local agent CLIs do not always return useful stdout. Some complete the task but fail to print the final answer; others emit only partial output. The wrappers prefer durable artifacts where possible and document recovery behavior in each skill.

### Windows-Specific Failure Modes

The skills are built around real Windows pain:

- PowerShell 7+ process handling
- Unicode and locale issues
- CLI shim and stdio behavior
- native session file recovery
- local path and artifact management

Windows support is not an afterthought here. It is the primary target.

### Long-Running Or Interrupted Work

Some tasks take minutes, not seconds. Supervision gives the caller a place to look: session metadata, stderr, native logs, and last responses. The Claude skill also includes background lifecycle helpers.

### Review Without Auto-Apply

The review-oriented flows are designed to surface findings first. They should not silently apply fixes just because a delegated agent suggested them.

## Strong Use Cases

### 1. Adversarial Code Review

Use a second agent to review a diff or working tree with a skeptical lens. The supervising agent reads the report, checks whether it is grounded in files or diffs, and then presents findings to the user.

Best fit:

- `codex-supervision/scripts/codex-review.ps1`
- `claude-supervision/scripts/claude-review.ps1`

### 2. Rescue Delegation

When the primary agent is stuck, context-limited, or unsure, delegate a narrow diagnostic task to another CLI. The supervising agent then verifies the proposed path before making changes.

Best fit:

- `claude-supervision/scripts/claude-task.ps1`
- `codex-supervision/scripts/codex-task.ps1`
- `kimi-supervision/scripts/kimi-run-once.ps1`

### 3. Cross-Model Claim Verification

Ask one agent to extract or summarize claims, then ask another to verify those claims against the same source. The saved artifacts make disagreements easier to inspect.

Best fit:

- research note processing
- PDF or document extraction workflows
- evidence mapping tasks

### 4. Background Investigation

Dispatch a long-running Claude investigation in the background, poll logs, and inspect the wrapper's session artifacts before relying on the result.

Best fit:

- `claude-supervision/scripts/claude-bg.ps1`

### 5. Local Batch Pipelines

Use supervised agent calls inside local automation where a script needs to decide whether a run was usable, incomplete, timed out, or recoverable from native files.

Best fit:

- extraction jobs
- local QA gates
- research batch review
- repeated repository triage

### 6. Ephemeral Sensitive Runs

Redirect supervision artifacts to a temporary directory for a sensitive task, inspect the result, then delete the directory when finished.

Best fit:

```powershell
$env:CLAUDE_SUPERVISION_HOME = Join-Path $env:TEMP "claude-supervision"
$env:CODEX_SUPERVISION_HOME = Join-Path $env:TEMP "codex-supervision"
$env:KIMI_SUPERVISION_HOME = Join-Path $env:TEMP "kimi-supervision"
```

### 7. Local Quality Gates

Parse `session.json` after a supervised run and fail a local script if the result classification is not usable or if verification did not run.

Best fit:

- pre-commit style local checks
- local release checks
- human-in-the-loop automation

### 8. Debugging Agent Transport Failures

When a CLI appears to return nothing, inspect stderr, native logs, and recovered response artifacts instead of assuming the model failed.

Best fit:

- Windows stdout issues
- encoding crashes
- incomplete final-message modes
- long-running native sessions

## When Not To Use This

Do not use this project when you need:

- a hosted queue or web dashboard
- a generic cross-platform agent framework
- a sandbox or permission enforcement layer
- a secret manager
- guaranteed correctness of generated code
- automatic application of code review findings
- a single unified abstraction over all target CLIs

The wrappers improve observability and recovery. They do not replace tests, code review, sandboxing, or human judgment.

## Messaging Boundaries

Prefer claims like:

- "Supervision, not blind delegation."
- "Delegate locally, verify before you trust."
- "Windows-first agent handoffs with inspectable artifacts."

Avoid claims like:

- "enterprise-grade security"
- "fully autonomous orchestration"
- "cross-platform agent framework"
- "safe by default for sensitive data"
- "one universal API for all coding agents"

The strength of this project is not breadth. It is disciplined, local, inspectable delegation for people who already use multiple CLI agents and want fewer silent failures.
