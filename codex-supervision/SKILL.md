---
name: codex-supervision
description: Use when the user wants Claude to delegate work to the local Codex CLI — code review, adversarial review, or substantive rescue tasks — and then independently verify what Codex did. Works in Claude Desktop (no plugin system required); wraps codex exec as PowerShell scripts and keeps run artifacts on disk.
---

# Codex Supervision

Hand work to the local `codex` CLI and **supervise** the result — read what Codex actually did, inspect artifacts, verify claims, only then answer the user.

Supervision, not blind delegation.

This skill exists because the official `openai/codex-plugin-cc` is a Claude **Code** plugin, and Claude **Desktop** (consumer chat client) does not load plugins. The skill provides the essential capability via PowerShell wrapper scripts the model invokes through its shell tool.

## Requirements

- **PowerShell 7+** (`pwsh.exe`). Uses `ProcessStartInfo.ArgumentList` and `Process.Kill(bool)` which are .NET Core 3+ only — Windows PowerShell 5.1 will not work. `codex-setup.ps1` reports the detected version and refuses to mark `ready=true` on older hosts.
- **Node.js 18.18+** (codex CLI requirement)
- **`codex` CLI 0.128+** on PATH, at `$env:CODEX_PATH`, or at `%USERPROFILE%\bin\codex.cmd`
- **A ChatGPT subscription or OpenAI API key** for codex authentication

## What this skill provides

PowerShell scripts under `scripts/`:

- `common.ps1` — codex resolution, env hygiene, async I/O, timeout, artifact capture
- `codex-setup.ps1` — verify codex CLI version + login + writable state dir
- `codex-review.ps1` — non-interactive code review (normal or adversarial) via `codex exec review`
- `codex-task.ps1` — delegate an arbitrary task to codex (rescue equivalent)
- `codex-list-sessions.ps1` — inspect prior runs

These scripts:
- require a locally installed `codex` CLI on PATH, at `$env:CODEX_PATH`, or at `%USERPROFILE%\bin\codex.cmd`
- read/write UTF-8; set `Console.OutputEncoding` to UTF-8 to survive Chinese-locale Windows
- run codex non-interactively (`codex exec` / `codex exec review`) with async stdout/stderr reads — no pipe-buffer deadlock
- enforce a `-TimeoutSec` and kill codex if it hangs
- pass `-Base` / `-Uncommitted` / `-Title` through to the native review subcommand (codex does the git diff scoping itself)
- default to `read-only` sandbox; only escalate to `workspace-write` with `-Write`, or `danger-full-access` with `-DangerousFullAccess`
- always write `last-prompt.txt`, `last-response.txt`, `stderr.log`, `session.json` to the session dir

## State layout

State root resolution order (first non-empty wins):
1. `$env:CODEX_SUPERVISION_HOME` (explicit override)
2. `%LOCALAPPDATA%\codex-supervision\` (Windows default)
3. `%USERPROFILE%\.codex-supervision\` (fallback)
4. `C:\codex-supervision\` (last resort)

Per session, the skill writes:
- `sessions/<session-id>/last-prompt.txt`
- `sessions/<session-id>/last-response.txt` — final answer (preferred from `codex-answer.txt`, falls back to stdout pipe)
- `sessions/<session-id>/codex-answer.txt` — what codex wrote via `-o <file>` (the authoritative answer source)
- `sessions/<session-id>/stderr.log`
- `sessions/<session-id>/session.json`

`<session-id>` is `YYYYMMDD-HHmmss-fff-<PID>-<rand>-<mode>` (rand = 4-digit). The millisecond + PID + random suffix means two runs in the same process at the same millisecond still get distinct ids.

## When to use which script

| Goal | Script | Sandbox | Notes |
|------|--------|---------|-------|
| First-time check | `codex-setup.ps1` | n/a | Run before anything else, or when codex starts misbehaving |
| Normal code review | `codex-review.ps1` | read-only (builtin) | Uses `codex exec review`; native git scoping |
| Adversarial / skeptical review | `codex-review.ps1 -Adversarial -Focus '...'` | read-only (builtin) | Same script with `-Adversarial`; inline adversarial template |
| Delegate read-only task | `codex-task.ps1 -Message '...'` | read-only | Diagnosis, planning, research |
| Delegate task with edits | `codex-task.ps1 -Write -Message '...'` | workspace-write | Codex may edit files in the workspace |
| Delegate task with full access | `codex-task.ps1 -DangerousFullAccess -Message '...'` | danger-full-access | Warn the user first; rare |
| **Continue prior codex run** | `codex-task.ps1 -ResumeLast -Message '...'` | inherits | Multi-turn — keeps codex's context across calls |
| **Continue specific session** | `codex-task.ps1 -Resume <session-id> -Message '...'` | inherits | Resume by uuid (find via `codex-list-sessions.ps1`) |
| **Structured JSON output** | `codex-task.ps1 -OutputSchema <path> -Message '...'` | read-only | codex enforces a JSON Schema on the final answer (plain exec only) |
| **Sensitive / ephemeral run** | `codex-task.ps1 -Ephemeral -Message '...'` | read-only | Skips `~/.codex/sessions/` rollout persistence (can't be resumed) |
| Inspect prior runs | `codex-list-sessions.ps1` | n/a | List recent or read a specific session's artifacts |

## Standard commands

Set `$skillDir` to wherever you installed this skill. A common Claude location is `$env:USERPROFILE\.claude\skills\codex-supervision`.

### Setup

```powershell
$skillDir = Join-Path $env:USERPROFILE ".claude\skills\codex-supervision"
& (Join-Path $skillDir "scripts\codex-setup.ps1")
```

Prints JSON. `ready: true` means: codex found, logged in, state dir writable.

### Review the current working tree

```powershell
& '...\scripts\codex-review.ps1' -Workspace '.'
```

Review against a base branch:

```powershell
& '...\scripts\codex-review.ps1' -Workspace '.' -Base 'origin/main'
```

Review the changes introduced by a specific commit:

```powershell
& '...\scripts\codex-review.ps1' -Workspace '.' -Commit 'a1b2c3d4'
```

Scope precedence: `-Commit` > `-Base` > default `--uncommitted`.

Adversarial review with focus:

```powershell
& '...\scripts\codex-review.ps1' -Workspace '.' -Adversarial -Focus 'auth boundary; migration safety'
```

Combine flags freely:

```powershell
& '...\scripts\codex-review.ps1' -Workspace '.' -Base 'origin/main' -Adversarial -Focus 'concurrency' -Model 'gpt-5.5' -Effort 'high' -TimeoutSec 1800
```

### Delegate a task

Read-only (diagnosis, planning):

```powershell
& '...\scripts\codex-task.ps1' -Workspace '.' -Message 'Diagnose why test_login_redirect fails intermittently and report root cause + remaining risks.'
```

Write-capable (codex may edit files):

```powershell
& '...\scripts\codex-task.ps1' -Workspace '.' -Write -Message 'Patch the off-by-one in src/foo.py and add a regression test.'
```

Skip the trailing structured-ending schema (when the task is a freeform question):

```powershell
& '...\scripts\codex-task.ps1' -Workspace '.' -NoSchema -Message 'Answer this question without the trailing sections.'
```

### Flag compatibility across codex subcommands

Each `codex exec` subcommand accepts a different flag subset (verified empirically against 0.128.0):

| Flag | `exec` (task) | `exec review` | `exec resume` |
|---|---|---|---|
| `--sandbox` / `--cd` / `--add-dir` | ✓ | — | — |
| `--base` / `--uncommitted` / `--commit` / `--title` | — | ✓ | — |
| `--color` / `--output-schema` | ✓ | — | — |
| `-i` / `--image` | ✓ multi | — | ✓ single |
| `--last` / `--all` | — | — | ✓ |
| `--ephemeral` / `--skip-git-repo-check` / `--model` / `-o` / `--json` / `-c` / `--enable` / `--disable` / `--dangerously-bypass-approvals-and-sandbox` / `--ignore-user-config` / `--ignore-rules` | ✓ | ✓ | ✓ |

**Notably absent from `codex exec` at 0.128.0:** there is **no `--search` flag**. Web search appears only in the top-level interactive `codex` TUI, not in any `exec` subcommand. This wrapper does not expose web search until codex adds it to `exec`.

The wrapper enforces this matrix and emits a `Write-Warning` when an incompatible flag is silently dropped. Practical consequences:

- `-Resume` / `-ResumeLast` inherits sandbox/cwd from the original session — `-Write` / `-DangerousFullAccess` are ignored on resume turns (the wrapper emits a warning).
- `-OutputSchema` works only with `codex-task.ps1` plain runs (NOT review, NOT resume).
- `-Images` works with task (initial + resume turns) but not with review.
- Web search is not exposed: `codex exec` (any subcommand) doesn't accept `--search` at 0.128.0.

### Multi-turn conversations (resume)

codex tracks every non-interactive session in `~/.codex/sessions/`. To keep the conversation going across multiple wrapper calls:

```powershell
# Turn 1 — initial diagnosis
& '...\scripts\codex-task.ps1' -Workspace '.' -Message 'Diagnose the flaky CI step.'

# Turn 2 — resume the latest session and direct it
& '...\scripts\codex-task.ps1' -Workspace '.' -ResumeLast -Write -Message 'Apply the top fix you proposed and add a regression test.'

# Resume a specific session by uuid (find it via codex-list-sessions or codex resume --all)
& '...\scripts\codex-task.ps1' -Workspace '.' -Resume '019e4af7-7678-70c0-9548-42b927ee2389' -Message '...'
```

Resume keeps codex's context (tool history, prior reasoning, file state assumptions) so follow-up turns are cheap and coherent. The wrapper auto-detects resume mode and skips the appended structured-ending schema (codex already established its own structure in the prior turn).

### Structured JSON output (output-schema)

Pass `-OutputSchema <path>` and codex enforces the schema on its final answer. The answer file (`codex-answer.txt` in the session dir) will contain valid JSON.

Example — define a schema file `triage.json`:

```json
{
  "type": "object",
  "required": ["root_cause", "fix_steps", "confidence"],
  "properties": {
    "root_cause": { "type": "string" },
    "fix_steps": { "type": "array", "items": { "type": "string" } },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
  }
}
```

Then:

```powershell
& '...\scripts\codex-task.ps1' -Workspace '.' -OutputSchema 'triage.json' -Message 'Triage this stack trace and propose fixes.'
```

When `-OutputSchema` is used, the wrapper auto-skips its own text-section schema (the JSON schema replaces it).

### Multimodal input (image attachments)

Pass `-Images @('path1.png', 'path2.jpg')` to attach one or more images to the prompt. Codex's model sees them alongside the text.

```powershell
# Triage a screenshot of an error dialog
& '...\scripts\codex-task.ps1' -Workspace '.' -Images @('C:\screenshots\err.png') -Message 'Read this error dialog and tell me what went wrong + likely next debugging step.'

# Multiple images in one turn (UI before/after comparison)
& '...\scripts\codex-task.ps1' -Workspace '.' -Images @('before.png','after.png') -Message 'Spot the visual regression between these two screenshots.'

# Resume an image-anchored conversation
& '...\scripts\codex-task.ps1' -Workspace '.' -ResumeLast -Images @('detail.png') -Message 'Zoom into this region — does it confirm the hypothesis from the last turn?'
```

Path validation is strict — non-existent files throw before codex is invoked. Codex itself decides if it can read the format (PNG/JPG/etc.).

### Ephemeral runs (no session persistence)

```powershell
& '...\scripts\codex-task.ps1' -Workspace '.' -Ephemeral -Message 'Sensitive content; do not log to codex sessions dir.'
```

`--ephemeral` tells codex not to write to `~/.codex/sessions/`. The skill's own `last-prompt.txt` / `last-response.txt` / `stderr.log` / `session.json` are still written — set `CODEX_SUPERVISION_HOME` to a temp dir if you want those wiped too. Ephemeral runs cannot be resumed (no rollout exists).

### Inspect prior runs

List last N:

```powershell
& '...\scripts\codex-list-sessions.ps1' -Last 10
```

Read a specific session's artifacts:

```powershell
& '...\scripts\codex-list-sessions.ps1' -Session '20260521-141530-873-1234-5678-review' -View response
```

Views: `meta` (session.json), `prompt` (last-prompt.txt), `response` (last-response.txt), `stderr` (stderr.log).

## How supervision should work

When handing work to codex:

1. Frame a **narrow** task — what to do, scope limits, what to report.
2. Choose the right script + mode (review / adversarial / task).
3. Run it and capture stdout.
4. Read `session.json` for `result_classification` and `timed_out`.
5. Independently verify any important claim:
   - if codex says "fixed X", read the diff
   - if codex says "tests pass", run them
   - if codex says "no issues", spot-check at least one risky area
6. Only then answer the user.

Do not trust codex automatically. Always verify when codex reports versions, paths, line numbers, whether tests pass, claims of "no issues", diffs, success of install/repair/migration.

## Don't auto-fix from review output

**Hard rule** (inherited from the official `codex-plugin-cc`):

After presenting review findings, **STOP**. Do not apply fixes. Do not edit files. Do not "while we're at it" any of the issues codex flagged.

Ask the user explicitly: which findings, if any, should I act on?

Auto-applying review fixes is forbidden even when the fix is obvious. The review is for the user to decide on, not for Claude to silently execute.

## How to interpret artifacts

### `last-response.txt`

Codex's stdout via `codex exec`. The thing to show the user.

### `session.json`

Records supervision state:

- `mode` — `review` / `adversarial` / `task`
- `exec_mode` — `plain` (codex exec) / `review` (codex exec review)
- `session_id`, `workspace`, `started_at`, `finished_at`, `duration_ms`
- `codex_version`, `codex_args` (sensitive `-c key=...` values redacted)
- `sandbox` — `read-only` / `workspace-write` / `danger-full-access` / `review-builtin`
- `bypass_approvals` — boolean, true when `-DangerousFullAccess`/`--dangerously-bypass-...` was used
- `model`, `effort`, `review_base`, `review_uncommitted`
- `timeout_sec`, `timed_out`
- `exit_code`, `prompt_chars`, `response_chars`
- `result_classification` — see below

**Read `result_classification` first** when deciding whether to trust the run:

| Value | Meaning |
|-------|---------|
| `usable` | Exit 0, non-empty stdout, no timeout |
| `empty` | Exit 0 but no usable stdout (rare; usually codex internal) |
| `timeout` | Killed because `-TimeoutSec` exceeded |
| `error` | Codex exited non-zero; check `stderr.log` |
| `auth_required` | Login expired or token issue; tell user to run `codex login` |
| `host_error` | Launcher/PATH/encoding failure before codex ran |

### `stderr.log`

Codex's stderr (preamble, progress, errors). Diagnostic; useful when classification is `error` or `timeout`.

## Codex CLI dependency

Resolution order (first match wins):
1. `$env:CODEX_PATH`
2. `Get-Command -CommandType Application codex.exe / codex.cmd / codex`
3. `%USERPROFILE%\bin\codex.cmd`

Install:

```powershell
npm install -g @openai/codex
```

Login:

```powershell
codex login        # interactive; run in a normal terminal
codex login status # check current state
```

## Sandbox modes

| Level | Codex can | Used by |
|-------|-----------|---------|
| `read-only` | Read files only | review, adversarial, task (default), task `-NoSchema` |
| `workspace-write` | Edit files in workspace | task `-Write` |
| `danger-full-access` | Anything | task `-DangerousFullAccess` (warn user) |
| `review-builtin` | n/a — review subcommand is inherently read-only | review, adversarial |

Never pass `-DangerousFullAccess` without explicit user opt-in in this turn.

## Known limitations vs codex-plugin-cc

The official plugin has features this skill does **not** replicate:

- **No background mode in-process.** Wrappers are synchronous; the calling shell tool blocks until codex finishes or `-TimeoutSec` triggers. For long tasks, launch via `Bash(..., run_in_background:true)` or PowerShell `run_in_background`, then poll the session dir with `codex-list-sessions.ps1`.
- **No live `/codex:status`.** During a run there's no progress channel — only after exit can you inspect artifacts. To cancel an in-progress run, kill the child codex process directly (find via `Get-Process codex`).
- **No hooks / `stop-review-gate`.** The plugin's session lifecycle hooks aren't ported. The "don't auto-fix from review" discipline is enforced via SKILL.md instructions instead.

What this skill **does** provide that the plugin's slash commands hide:

- **Native codex resume**: `-Resume <id>` / `-ResumeLast` on `codex-task.ps1` (multi-turn conversations across wrapper calls).
- **Multimodal input**: `-Images <string[]>` attaches PNG/JPG to task and resume turns.
- **Structured output**: `-OutputSchema <path>` enforces a JSON Schema on codex's answer (plain task only).
- **Ephemeral mode**: `-Ephemeral` skips session persistence for sensitive content.
- **Defense-in-depth artifact capture**: `-o <file>` for the answer (bypasses Windows stdio race; see below) + async stderr capture + redacted args + session.json with full metadata.

If you genuinely need background jobs with `/codex:status` semantics, run codex inside Claude Code with the official plugin, or wrap each call in a process-pool harness of your own.

## Windows stdio race (why we use `-o <file>`)

On Windows, the `codex.js` shim → `node` → `spawn(vendor/codex.exe, stdio:"inherit")` chain intermittently drops the entire stdio handle chain back to the parent. Symptom: codex completes the task (its `~/.codex/sessions/.../rollout-*.jsonl` has `task_complete` with the answer), but the parent receives **0 bytes** on both stdout and stderr. The skill bypasses this by passing `-o <session-dir>/codex-answer.txt` and reading the answer from disk instead of the stdout pipe. The stdout pipe is still captured as a fallback (in case `-o` ever stops working in a future codex release), but the file is the authoritative source.

We also pass `--color never` so codex doesn't try to emit ANSI escape codes (which would land in stderr/log and confuse text parsing).

If you ever see classification=`empty` AND `~/.codex/sessions/.../rollout-*-<codex_session_id>.jsonl` contains a `task_complete` event, the stdio race is back — check whether `codex-answer.txt` is empty too. If it is, codex itself failed to write the file (different bug); if it isn't, fix the wrapper's file-read path.

## Anti-patterns

Do **not**:

- Use `-DangerousFullAccess` "to make it work". If sandbox blocks codex, escalate to the user.
- Loop on the same prompt after a non-zero exit without inspecting `stderr.log`.
- Treat empty stdout as success — check `exit_code` and `result_classification`.
- Auto-fix issues from review output (see "Don't auto-fix" above).
- Replace the user's task wording. The wrapper already frames the prompt; pass user text through verbatim inside `<user_task>` ... `</user_task>`.
- Pass `-Write` "to be safe" — read-only is the safer default.

## What Claude should tell the user after using this skill

Structure the answer as:

1. **What you asked codex to do** (one line)
2. **What codex reported** (preserve codex's structure and evidence)
3. **What you verified independently** (file reads, test runs, diff inspection)
4. **The final conclusion** (your judgment, not codex's)

If codex edited files (only possible with `-Write` / `-DangerousFullAccess`), say so explicitly and list the touched files.

If `result_classification` was anything other than `usable`, surface that — don't pretend the run was clean.

For review findings, present them ordered by severity. **Then stop.** Ask the user which to act on.

## Privacy note

`last-prompt.txt`, `last-response.txt`, and `stderr.log` are written verbatim to `$env:LOCALAPPDATA\codex-supervision\sessions\` and are not automatically rotated. If a run involved sensitive content, delete the session directory afterward, or set `CODEX_SUPERVISION_HOME` to an ephemeral location for that run.
