---
name: claude-supervision
description: Use when the user wants to delegate work to the local Claude Code CLI (`claude --print`, `claude --bg`, `claude ultrareview`) — substantive tasks, multi-turn resume, structured output, multi-agent code review, background sessions — and then independently verify what Claude did. Useful from Codex / Kimi / any agent that wants to hand work to Claude Code and inspect the result. Wraps the CLI as PowerShell scripts with deadlock-safe async I/O, timeout, native JSONL recovery, and on-disk artifacts.
---

# Claude Supervision

Hand work to the local `claude` CLI (Anthropic's Claude Code) and **supervise** the result — read what Claude actually did, inspect artifacts, verify claims, only then answer the user.

Supervision, not blind delegation.

This is the Claude-Code analog of `kimi-supervision` and `codex-supervision`. Use it when you (Codex, another Claude session, a CI script, etc.) want to delegate to Claude Code non-interactively and need the answer + artifacts in a structured place.

## Requirements

- **PowerShell 7+** (`pwsh.exe`). `claude-setup.ps1` refuses to mark `ready=true` on PS 5.1.
- **Claude Code CLI** (`claude` from `@anthropic-ai/claude-code`). Install: `npm install -g @anthropic-ai/claude-code`.
- **Authentication**: `claude auth login` (interactive once), OR `$env:ANTHROPIC_API_KEY` / `$env:ANTHROPIC_AUTH_TOKEN`. Verified by `claude auth status` (JSON output, exit 0=in / 1=out).

## What this skill provides

Scripts under `scripts/`:

- `common.ps1` — claude path resolution, env hygiene, async I/O, timeout, artifact capture, secret-redacted CLI arg recording, **native session JSONL recovery** (reads `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` when stdout is unexpectedly empty)
- `claude-setup.ps1` — `claude auth status` JSON probe + PS 7+ + writable state dir
- `claude-task.ps1` — delegate a task via `claude --print` (foreground, blocking)
- `claude-review.ps1` — multi-agent cloud-hosted review via `claude ultrareview`
- `claude-bg.ps1` — manage background sessions: `--bg` / `agents` / `logs` / `stop` / `respawn` / `rm` / `daemon status`
- `claude-list-sessions.ps1` — inspect this wrapper's own session artifacts

These scripts:
- prefer the native `claude.exe` at `$USERPROFILE\.local\bin\` (no .cmd shim chain → no Windows stdio race like codex)
- read/write UTF-8 throughout; set `Console.OutputEncoding` to UTF-8
- pass the prompt via stdin (no argv length limits, no quoting hell on multi-line/unicode text)
- async stdout/stderr reads with `ReadToEndAsync` (no pipe-buffer deadlock)
- `-TimeoutSec` with hard kill (`Process.Kill($true)` with `Kill()` fallback for older runtimes) and `classification='timeout'`
- always write `last-prompt.txt`, `last-response.txt`, `stderr.log`, `session.json` to the session dir
- session ID format `YYYYMMDD-HHmmss-fff-<PID>-<rand>-<mode>` (no same-millisecond collisions)
- redact secrets in `--settings` / `--mcp-config` / `--agents` / `--json-schema` / `--*-system-prompt` inline JSON before serializing to session.json
- truncate long inline JSON args in `session.json` for readability

## State layout

State root resolution order:
1. `$env:CLAUDE_SUPERVISION_HOME` (override)
2. `%LOCALAPPDATA%\claude-supervision\` (Windows default)
3. `%USERPROFILE%\.claude-supervision\` (fallback)
4. `C:\claude-supervision\` (last resort)

Per session:
- `sessions/<id>/last-prompt.txt`
- `sessions/<id>/last-response.txt` — claude stdout (or recovered from JSONL — see below)
- `sessions/<id>/stderr.log`
- `sessions/<id>/session.json`

**Claude's own session JSONL** lives at `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. The wrapper attempts native recovery from there when `--print` stdout is empty but the process exited 0 (i.e., Claude ran but we didn't capture output via the pipe). `session.json.recovered_from_jsonl: true` records that recovery fired.

## Authoritative CLI flag matrix (Claude Code 2.1.146)

Verified empirically — `claude --help` doesn't list every flag; the docs at <https://code.claude.com/docs/en/cli-reference> are authoritative. Key categories:

| Category | Flags (wrapper exposure) |
|---|---|
| **Subcommands** | `claude --print` (task) / `claude --bg "<msg>"` (background) / `claude ultrareview [target]` (multi-agent review) / `claude auth status` (used by setup) / `claude agents/logs/stop/respawn/rm/daemon` (used by claude-bg.ps1) |
| **Sessions** | `--continue / -c` / `--resume / -r <id>` / `--fork-session` / `--session-id <uuid>` / `--no-session-persistence` / `--from-pr <pr>` |
| **Model & effort** | `--model <name>` / `--effort low\|medium\|high\|xhigh\|max` / `--fallback-model <name>` |
| **Budget** | `--max-budget-usd <n>` / `--max-turns <n>` |
| **Permissions** | `--permission-mode default\|acceptEdits\|auto\|bypassPermissions\|dontAsk\|plan` / `--dangerously-skip-permissions` / `--allow-dangerously-skip-permissions` / `--permission-prompt-tool <mcp-tool>` / `--allowedTools <...>` / `--disallowedTools <...>` / `--tools <list>` / `--add-dir <dir>` |
| **Output formats** | `--output-format text\|json\|stream-json` / `--input-format text\|stream-json` / `--include-hook-events` / `--include-partial-messages` / `--json-schema '<inline-json>'` / `--verbose` |
| **System prompt** | `--system-prompt <text>` / `--system-prompt-file <path>` / `--append-system-prompt <text>` / `--append-system-prompt-file <path>` |
| **Agents** | `--agent <name>` / `--agents '<inline-json>'` |
| **MCP / settings / plugins** | `--mcp-config <path\|json>` / `--strict-mcp-config` / `--settings <path\|json>` / `--setting-sources user,project,local` / `--plugin-dir <path>` (repeatable) / `--plugin-url <url>` (repeatable) |
| **Hooks lifecycle** | `--init` (Setup hooks before session) / `--init-only` (Setup + SessionStart, then exit) / `--maintenance` |
| **Cleanliness** | `--bare` (skip hooks/plugins/CLAUDE.md/auto-memory) / `--disable-slash-commands` / `--exclude-dynamic-system-prompt-sections` |
| **Diagnostics** | `--debug [filter]` / `--debug-file <path>` / `--verbose` |
| **Misc** | `--name <name>` / `--betas <list>` / `--file <id:path>` (file resources) |
| **Skipped (interactive-only)** | `--ide` / `--chrome` / `--remote-control` / `--tmux` / `--worktree` / `--teleport` / `--remote` |

## When to use which script

| Goal | Script | Key flags |
|------|--------|-----------|
| First-time check | `claude-setup.ps1` | (none) |
| Fresh task | `claude-task.ps1 -Message '...'` | `-Model / -Effort / -PermissionMode` |
| Task with edits | `claude-task.ps1 -AcceptEdits -Message '...'` | shortcut for `-PermissionMode acceptEdits` |
| Continue most recent | `claude-task.ps1 -Continue -Message '...'` | reuses session in `-Workspace` |
| Resume specific session | `claude-task.ps1 -Resume <uuid> -Message '...'` | optionally `-ForkSession` |
| Cap cost / turns | `claude-task.ps1 -MaxBudgetUsd 0.50 -MaxTurns 5 -Message '...'` | hard limits |
| Custom system prompt | `claude-task.ps1 -AppendSystemPrompt 'TypeScript only' -Message '...'` | also `-SystemPromptFile`, `-AppendSystemPromptFile` |
| Custom agent | `claude-task.ps1 -Agent code-reviewer -Message '...'` OR `-AgentsFile agents.json` | configure subagents per-run |
| Per-run MCP | `claude-task.ps1 -McpConfig ./linear.json -StrictMcpConfig -Message '...'` | clean MCP scope |
| Per-run plugin | `claude-task.ps1 -PluginDirs ./local-plugin -Message '...'` | load just this plugin |
| Structured JSON output | `claude-task.ps1 -JsonSchemaFile triage.json -OutputFormat json -Message '...'` | enforces schema |
| Live progress stream | `claude-task.ps1 -OutputFormat stream-json -IncludeHookEvents -Message '...'` | JSONL events |
| Clean-room run | `claude-task.ps1 -Bare -Message '...'` | skip hooks/plugins/CLAUDE.md |
| Ephemeral (no rollout) | `claude-task.ps1 -NoSessionPersistence -Message '...'` | don't record to `~/.claude/projects` |
| Background dispatch | `claude-bg.ps1 -Submit '<msg>' -Workspace .` | returns session ID; daemon does the work |
| Poll background | `claude-bg.ps1 -Logs <id>` | recent output |
| List background sessions | `claude-bg.ps1 -List -Workspace .` | JSON table |
| Stop/restart/remove background | `claude-bg.ps1 -Stop\|-Respawn\|-Remove <id>` | lifecycle ops |
| Multi-agent cloud review | `claude-review.ps1 -Workspace . [-Target <pr\|branch>] [-Json]` | wraps `claude ultrareview` |
| Inspect wrapper sessions | `claude-list-sessions.ps1` | local artifact browser |

## Standard recipes

Set `$skillDir` to wherever you installed this skill. A common location is `$env:USERPROFILE\.agents\skills\claude-supervision`.

### Setup

```powershell
$skillDir = Join-Path $env:USERPROFILE ".agents\skills\claude-supervision"
& (Join-Path $skillDir "scripts\claude-setup.ps1")
```

`ready: true` means: CLI found, `claude auth status` returned `loggedIn:true`, state dir writable, PS 7+. Setup output also includes `auth_method`, `auth_email`, `subscription`.

### Fresh task (read-only by default)

```powershell
& '...\claude-task.ps1' -Workspace '.' -Message 'Diagnose why test_login_redirect fails intermittently.'
```

### Task with file edits

```powershell
& '...\claude-task.ps1' -Workspace '.' -AcceptEdits -Message 'Patch the off-by-one in src/foo.py and add a regression test.'
```

### Continue / resume

```powershell
# Continue most recent session in this workspace
& '...\claude-task.ps1' -Workspace '.' -Continue -Message 'Apply the fix you proposed.'

# Resume a specific session UUID
& '...\claude-task.ps1' -Workspace '.' -Resume 'a1b2c3d4-...' -Message 'Add the tests we discussed.'

# Fork: continue from a known-good state without overwriting the original session id
& '...\claude-task.ps1' -Workspace '.' -Resume 'a1b2...' -ForkSession -Message 'Try a different approach.'
```

### System prompt override

```powershell
# Append per-task instructions (preserves default tool guidance + safety rules)
& '...\claude-task.ps1' -Workspace '.' -AppendSystemPrompt 'Always use TypeScript; never use any.' -Message '...'

# Append from file (long rule sets)
& '...\claude-task.ps1' -Workspace '.' -AppendSystemPromptFile './rules/typescript.md' -Message '...'

# Replace entire system prompt (drops default tool guidance — use only for non-coding agents)
& '...\claude-task.ps1' -Workspace '.' -SystemPromptFile './prompts/legal-reviewer.txt' -Message '...'
```

### Subagents

```powershell
# Use a project-defined agent
& '...\claude-task.ps1' -Workspace '.' -Agent code-reviewer -Message 'Review the diff.'

# Define agents inline per-run
$agents = '{"reviewer":{"description":"Reviews code","prompt":"You are a code reviewer","tools":["Read","Grep","Glob"]}}'
& '...\claude-task.ps1' -Workspace '.' -AgentsInline $agents -Message '...'

# Or from a file
& '...\claude-task.ps1' -Workspace '.' -AgentsFile ./team/agents.json -Message '...'
```

### Per-run MCP / settings / plugins

```powershell
# Bring in just the Linear MCP for this task
& '...\claude-task.ps1' -Workspace '.' -McpConfig ./mcp/linear.json -StrictMcpConfig -Message 'Triage open Linear issues.'

# Override settings for this session only
& '...\claude-task.ps1' -Workspace '.' -SettingsFile ./session-settings.json -Message '...'

# Load only user + project settings (skip local overrides)
& '...\claude-task.ps1' -Workspace '.' -SettingSources 'user,project' -Message '...'

# Side-load a plugin without installing it permanently
& '...\claude-task.ps1' -Workspace '.' -PluginDirs './local-plugin','./another-plugin' -Message '...'
```

### Budget control

```powershell
# Cap spend AND turns simultaneously
& '...\claude-task.ps1' -Workspace '.' -MaxBudgetUsd 0.50 -MaxTurns 5 -Model haiku -Message 'Cheap one-shot.'

# Auto-fallback if default model is overloaded
& '...\claude-task.ps1' -Workspace '.' -Model opus -FallbackModel sonnet -Message '...'
```

### Structured JSON output

```powershell
# Schema in a file (wrapper reads it and inlines into --json-schema)
& '...\claude-task.ps1' -Workspace '.' -JsonSchemaFile './triage.json' -OutputFormat json -Message 'Triage this stack trace.'

# Inline schema
& '...\claude-task.ps1' -Workspace '.' -JsonSchemaInline '{"type":"object","required":["verdict"]}' -OutputFormat json -Message '...'
```

### Live progress (stream-json)

```powershell
# Get JSONL events as Claude works (includes assistant turns, tool uses, hook events, partial deltas)
& '...\claude-task.ps1' -Workspace '.' `
    -OutputFormat stream-json -IncludeHookEvents -IncludePartialMessages `
    -Message 'Long-running task with progress updates.'
```

### Clean-room / ephemeral

```powershell
# Skip hooks / plugins / CLAUDE.md / auto-memory (when one of those is suspected of breaking the run)
& '...\claude-task.ps1' -Workspace '.' -Bare -Message 'Repro WITHOUT my custom config.'

# Don't record to ~/.claude/projects
& '...\claude-task.ps1' -Workspace '.' -NoSessionPersistence -Message 'Sensitive content.'

# Disable all skills/commands for this run
& '...\claude-task.ps1' -Workspace '.' -DisableSlashCommands -Message '...'

# Improve prompt-cache reuse across users (moves per-machine fields out of system prompt)
& '...\claude-task.ps1' -Workspace '.' -ExcludeDynamicSystemPromptSections -Message '...'
```

### Diagnostics

```powershell
# Full debug stream
& '...\claude-task.ps1' -Workspace '.' -DebugFilter 'api,hooks' -VerboseOutput -Message '...'

# Write debug log to a file (implicitly enables debug)
& '...\claude-task.ps1' -Workspace '.' -DebugFile 'C:\tmp\claude-debug.log' -Message '...'
```

**Note**: PowerShell auto-adds `-Verbose` and `-Debug` as common parameters on advanced functions (anything with `[CmdletBinding()]` or `[Parameter()]`). The wrapper uses `-VerboseOutput` and `-DebugFilter` to dodge the collision while still mapping to claude CLI's `--verbose` / `--debug [filter]`.

### Background dispatch (the big one — async delegation)

```powershell
# 1. Submit — returns session ID immediately, daemon handles the work
& '...\claude-bg.ps1' -Submit 'Investigate the flaky test_login_redirect across the codebase and propose a fix.' `
    -Workspace . -Agent code-reviewer -Model sonnet -PermissionMode plan -Name 'flaky-login-investigation'
# Output:
# backgrounded · 7c5dcf5d
#   claude agents             list sessions
#   claude attach 7c5dcf5d    open in this terminal
#   claude logs 7c5dcf5d      show recent output
#   claude stop 7c5dcf5d      stop this session

# 2. Poll for progress (non-blocking — returns recent stdout)
& '...\claude-bg.ps1' -Logs 7c5dcf5d

# 3. List all background sessions in this workspace
& '...\claude-bg.ps1' -List -Workspace .

# 4. Daemon health check
& '...\claude-bg.ps1' -DaemonStatus

# 5. Lifecycle
& '...\claude-bg.ps1' -Stop 7c5dcf5d       # gracefully stop
& '...\claude-bg.ps1' -Respawn 7c5dcf5d    # restart with conversation intact
& '...\claude-bg.ps1' -Remove 7c5dcf5d     # remove from list (transcript stays for resume)
```

### Multi-agent cloud review (ultrareview)

```powershell
# Review the current branch
& '...\claude-review.ps1' -Workspace .

# Review a specific PR
& '...\claude-review.ps1' -Workspace . -Target 1234

# Review against a base branch
& '...\claude-review.ps1' -Workspace . -Target 'origin/main'

# Raw bugs.json payload (machine-readable)
& '...\claude-review.ps1' -Workspace . -Target 1234 -Json -TimeoutMin 45
```

### Inspect prior wrapper runs

```powershell
& '...\claude-list-sessions.ps1' -Last 10
& '...\claude-list-sessions.ps1' -Session '20260522-110000-000-1234-5678-task' -View response
```

Views: `meta` / `prompt` / `response` / `stderr`.

## Native session JSONL recovery

The wrapper attempts recovery in this exact case: exit code 0 + non-timeout + stdout empty. It:

1. Computes `~/.claude/projects/<encoded-cwd>/` from `-Workspace`
2. Scans `.jsonl` files; picks the most recently modified within the run window
3. Walks the JSONL backwards, finds the last entry with `type:'assistant'` + `message.content[].type:'text'`
4. Writes the recovered text to `last-response.txt` and sets `session.json.recovered_from_jsonl: true`

The header banner emits `(stdout was empty — answer recovered from ~/.claude/projects/<cwd>/*.jsonl)` when recovery fires.

When recovery fails (no matching JSONL, or no assistant text), classification stays `empty` and you'll need to inspect `~/.claude/projects/<encoded-cwd>/*.jsonl` manually.

## How to interpret artifacts

### `last-response.txt`

Claude's stdout under `--output-format text`, OR text recovered from JSONL.

For `--output-format json` / `--output-format stream-json`, this file contains structured records — parse before displaying.

### `session.json`

Records supervision state. Key fields:

- `mode` — `task` / `task-continue` / `task-resume` / `ultrareview`
- `exec_mode` — `plain` / `continue` / `resume`
- `claude_version`, `cli_args` (secrets redacted, long values truncated)
- `permission_mode`, `skip_permissions`
- `model`, `effort`, `fallback_model`
- `resume_session_id`, `fork_session`, `force_session_uuid`
- `output_format`, `input_format`, `has_json_schema`
- `max_budget_usd`, `max_turns`
- `no_session_persistence`, `bare`, `disable_slash_commands`, `exclude_dynamic_prompt`
- `system_prompt_replaced`, `system_prompt_appended`
- `agent`, `has_agents_inline`
- `mcp_config_count`, `strict_mcp_config`, `plugin_dir_count`, `plugin_url_count`
- `timeout_sec`, `timed_out`
- `exit_code`, `duration_ms`, `prompt_chars`, `response_chars`
- `recovered_from_jsonl`
- `result_classification`

`result_classification` values:

| Value | Meaning |
|-------|---------|
| `usable` | Exit 0, non-empty stdout (possibly recovered), no timeout |
| `empty` | Exit 0 but no usable stdout AND recovery failed |
| `timeout` | Killed because `-TimeoutSec` exceeded |
| `error` | Claude exited non-zero; check `stderr.log` |
| `auth_required` | Login expired / API key invalid |
| `budget_exceeded` | `--max-budget-usd` cap hit |
| `turn_limit` | `--max-turns` cap hit |
| `host_error` | Claude binary not found / launcher failure |

### `stderr.log`

Claude's stderr — diagnostic / progress / hook output. Useful when classification is `error` / `timeout` / `empty`.

## How supervision should work

1. Frame a **narrow** task — what to do, scope limits, what to report.
2. Choose mode (task / review / background) and permission level.
3. Run the script, capture stdout.
4. Read `session.json` for `result_classification`, `timed_out`, `recovered_from_jsonl`.
5. Independently verify any important claim:
   - if Claude says "fixed X", read the diff
   - if Claude says "tests pass", run them yourself
   - if Claude says "no issues", spot-check a risky area
6. Only then answer the user.

## Don't auto-fix from review output

After presenting Claude's review findings, **STOP**. Do not silently apply fixes. Ask the user which findings to act on.

Auto-applying review fixes is forbidden even when obvious. This is the user's decision.

## Permission modes

| Mode | Effect |
|------|--------|
| `default` | Read-only by default; tool uses requiring permission are denied in `--print` mode |
| `acceptEdits` | Auto-accept file edits in workspace |
| `auto` | Auto-accept anything granted by settings (uses `claude auto-mode defaults` classifier) |
| `bypassPermissions` | No permission checks — sandbox the host yourself |
| `dontAsk` | Deny anything that would require approval |
| `plan` | Plan-only — Claude proposes but doesn't execute |
| (wrapper) `-DangerouslySkipPermissions` | `--dangerously-skip-permissions` (full bypass) |
| (wrapper) `-AllowDangerouslySkipPermissions` | `--allow-dangerously-skip-permissions` (adds bypass to Shift+Tab cycle but doesn't start in it; mostly interactive-relevant) |
| (wrapper) `-PermissionPromptTool <mcp-tool>` | Delegate permission prompts to an MCP tool (advanced) |

Pick by intent:
- **Diagnose only** → `default` (wrapper default)
- **Plan only** → `plan`
- **Edit code** → `acceptEdits` (use `-AcceptEdits` shorthand)
- **Fully autonomous** → `bypassPermissions` or `-DangerouslySkipPermissions` (warn the user)

## Anti-patterns

Do **not**:

- Use `-DangerouslySkipPermissions` to "make it work" — escalate to the user.
- Treat empty stdout as failure without checking `recovered_from_jsonl` AND `~/.claude/projects/<encoded-cwd>/*.jsonl` directly.
- Auto-apply review fixes.
- Replace the user's task text. The wrapper already frames the prompt; pass user text through verbatim inside `<user_task>` ... `</user_task>`.
- Pass `-AcceptEdits` "to be safe" — `default` is the safer default.
- Combine `-Resume` / `-Continue` with `-NoSessionPersistence` (this turn won't be recorded; future resume from THIS turn will fail — the wrapper warns).
- Combine `-StrictMcpConfig` with no `-McpConfig` (means NO MCP servers will load — the wrapper warns).
- Mix `--include-hook-events` / `--include-partial-messages` with `--output-format text` (they require `stream-json`; the wrapper drops them with a warning).

## Multimodal (image attachments)

Claude CLI has **no `-i / --image` flag** like codex; multimodal works by referencing absolute paths in the prompt and letting claude's Read tool fetch them as vision blocks. The wrapper accepts `-Images @(...)` for ergonomics:

```powershell
# Single image, relative path (resolved against -Workspace)
& '...\claude-task.ps1' -Workspace '.' -Images 'screenshots\error.png' `
    -Message 'Analyze this screenshot of an error dialog and propose a fix.'

# Multiple images, absolute paths
& '...\claude-task.ps1' -Workspace '.' `
    -Images 'C:\screenshots\before.png','C:\screenshots\after.png' `
    -Message 'Spot the visual regression between these two screenshots.'
```

What the wrapper does:

- **Validates** each path: must exist, be a file, supported extension (`.jpg/.jpeg/.png/.gif/.webp`), warns if > 5 MB (claude vision limit).
- **Resolves relative paths** against `-Workspace`. Rejects `..\..\` escapes via `[System.IO.Path]::GetRelativePath`; absolute paths bypass the check (explicit opt-in).
- **Auto-extends `--add-dir`**: if an image's parent dir is outside `-Workspace`, the wrapper adds it via `--add-dir` so claude can read it.
- **Prepends `<attached_images>`** block to the prompt listing absolute paths + instructs claude to use its Read tool on each (claude is multimodal; the Read tool delivers supported image formats as vision blocks).
- **Records in `session.json`**: `image_count`, `image_paths`, `image_dirs_added`.
- **Hard limit**: > 100 images per request → throw (claude API ceiling).

**Verified empirically** on claude 2.1.146: a wrapper-generated PNG with text "WRAPPER OK 42" was correctly read and transcribed by `claude --print` in 17s with `-Model haiku`. No vision-specific CLI flag needed.

**Known limit**: GitHub issue [#35866](https://github.com/anthropics/claude-code/issues/35866) notes the Read tool is *occasionally* unreliable at delivering image files as vision input. If the model treats the image as a binary blob, retry with a more explicit prompt or fall back to the Anthropic Files API + `--file <id>`.

## In-process custom tools — evaluated, skipped (use a standalone MCP server)

The official `claude-agent-sdk-python` lets users define custom tools in-process (`@tool` decorator + `create_sdk_mcp_server`). This skill does **not** ship an equivalent for PowerShell. Rationale:

| Factor | Verdict |
|---|---|
| **Implementation cost** | ~500-1000 lines: pure-PS MCP stdio JSON-RPC server + scriptblock dispatch + bridge to claude's `--mcp-config` (needs a Python/Node helper because claude expects an executable, not an existing pwsh process) |
| **Performance gain** | Marginal: subprocess spawn for an external MCP server is ~50-200 ms one-time at session start, NOT per-tool-call. Per-call cost is JSON-RPC over stdio (~ms), same as in-process. Model-side latency dwarfs both by orders of magnitude. |
| **Better alternative** | Write a standalone MCP server (50-200 lines in any language) and pass via `-McpConfig <path-or-json>`. The MCP ecosystem already has servers for filesystem, Postgres, Slack, Linear, GitHub, Sentry, etc. |

**Recipe** — give claude a custom tool via standalone MCP:

```powershell
# my-mcp.json:
# {
#   "mcpServers": {
#     "my-tool": {
#       "command": "python",
#       "args": ["C:\\tools\\my_mcp.py"]
#     }
#   }
# }

& '...\claude-task.ps1' -Workspace '.' -McpConfig 'my-mcp.json' -StrictMcpConfig `
    -Message 'Use the my-tool MCP to do X.'
```

For Python tool authors specifically: use `claude-agent-sdk-python` directly — its `@tool` decorator is the right ergonomics for that audience. This skill targets *supervision* (delegate + verify), not in-process Python integration.

## What this skill does NOT expose

- **Interactive-only flags**: `--ide`, `--chrome`, `--remote-control`, `--tmux`, `--worktree`, `--teleport`, `--remote` — these need a TTY or external service.
- **`--channels` (research preview)**: MCP channel notifications. Out of scope until promoted from research preview.
- **`--from-pr`**: PR resume requires a configured GitHub token. Add later if needed.
- **`--init` / `--init-only` / `--maintenance` hook triggers**: Available via the corresponding switches but rarely needed.
- **In-process custom tools**: See evaluation above — use a standalone MCP server via `-McpConfig` instead.

## What to tell the user after using this skill

Structure the answer as:

1. **What you asked Claude to do** (one line)
2. **What Claude reported** (preserve structure and evidence)
3. **What you verified independently** (file reads, test runs, diff inspection)
4. **The final conclusion** (your judgment, not Claude's)

If Claude edited files, list them explicitly. If `result_classification` was anything other than `usable`, surface that — don't pretend the run was clean. If `recovered_from_jsonl` is true, mention that we read the answer from Claude's native log.

## Privacy / data retention

`last-prompt.txt`, `last-response.txt`, and `stderr.log` are written verbatim to `$env:LOCALAPPDATA\claude-supervision\sessions\` (or `CLAUDE_SUPERVISION_HOME`) — not auto-rotated. For sensitive runs:

- Set `CLAUDE_SUPERVISION_HOME` to an ephemeral path.
- Pass `-NoSessionPersistence` (drops Claude's own rollout at `~/.claude/projects`).
- Pass `-Bare` (also drops hooks/plugins that might log).
- After the run, delete the session dir.

For full project cleanup including Claude's own state, use `claude project purge <path>` (see CLI docs).
