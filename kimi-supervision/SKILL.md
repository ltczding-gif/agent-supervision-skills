---
name: kimi-supervision
description: Use when the user wants Codex to delegate work to local Kimi Code, supervise its progress, inspect intermediate/native artifacts, continue a native Kimi session, and verify Kimi's results instead of trusting only the flattened final output.
---

# Kimi Supervision

Use this skill when you want Codex to make local `Kimi Code` do work, watch what happened, inspect its reports, and then independently verify the outcome.

This skill is for supervision, not blind delegation.

## What this skill provides

This skill ships self-contained PowerShell scripts:

- `scripts/common.ps1`
- `scripts/kimi-run-once.ps1`
- `scripts/kimi-chat.ps1`
- `scripts/kimi-view-session.ps1`
- `scripts/test-kimi-supervision.ps1`

The optional `agents/openai.yaml` file is metadata for agent environments that support skill display names, descriptions, and implicit invocation policy. The PowerShell scripts do not require it.

These scripts:

- require a locally installed `kimi` CLI
- do not depend on any hard-coded machine-specific bridge directory
- prefer Kimi's native session memory
- start Kimi with thinking mode enabled by default unless you pass `-NoThinking`
- treat think-only or tool-call-only output as intermediate, not as a finished answer
- keep local session artifacts for later inspection
- recover answers from Kimi native files when `kimi --print` returns empty or incomplete stdout
- default to a long native recovery window so Kimi is not judged too early

## State layout

Default state root:

- `%LOCALAPPDATA%\kimi-supervision\`

Override:

- `KIMI_SUPERVISION_HOME`

Fallbacks if environment variables are missing:

- `%USERPROFILE%\.kimi-supervision`
- `C:\kimi-supervision`

Per session, this skill stores:

- `sessions/<name>/transcript.jsonl`
- `sessions/<name>/last-prompt.txt`
- `sessions/<name>/last-response.jsonl`
- `sessions/<name>/last-response.txt`
- `sessions/<name>/session.json`

## Core design

This skill uses:

1. Native Kimi session first
2. Native file recovery second
3. Transcript replay fallback last

Meaning:

- `kimi-chat.ps1` creates or reuses a real Kimi `--session` id
- follow-up calls reuse that same native Kimi session id
- if flattened stdout is empty or incomplete, the script reads Kimi's native `context.jsonl`
- if flattened stdout contains only `[THINK]` or `[TOOL_CALL]` lines, the script still keeps waiting for final answer text
- if native execution or native resume is unavailable, the script can fall back to transcript replay mode

This is important because in this environment `kimi --print` may succeed while emitting little or no useful stdout. The native session files are then the real source of truth.

On top of that transport stack, the current scripts now apply a default supervision harness to every task:

- short contract prompt
- required ending sections
- rules-based result gate
- explicit trust classification in `session.json`

Default required sections:

- `TASK`
- `PLAN`
- `EVIDENCE`
- `CHANGES`
- `VERIFICATION`
- `REMAINING_RISKS`

Important sentinels:

- use `CHANGES: NO_CHANGES` for read-only tasks
- use `VERIFICATION: NOT_RUN (...)` when verification was not run

Result classifications:

- `usable`
- `incomplete`
- `unverified`
- `host_error`
- `handoff_required`

## When to use which script

Use `kimi-run-once.ps1` when:

- the task is one-shot
- you only need one answer
- you do not need to continue the same Kimi conversation later

Use `kimi-chat.ps1` when:

- you want a continuing Kimi conversation
- you want Codex to ask follow-up questions
- you want to supervise progress across multiple turns
- you want to inspect native session artifacts
- the task is tool-heavy, repair-heavy, install-heavy, or likely to produce incomplete flattened output
- you want Codex to wait longer and monitor whether Kimi is still actively running before declaring failure

Use `kimi-view-session.ps1` when:

- you want to inspect what happened after a Kimi run
- `last-response.txt` is empty
- `last-response.txt` is `[NO_TEXT_EXTRACTED]`
- you suspect Kimi is still working
- you want to look at native artifacts directly

## Standard commands

### One-shot

```powershell
& '.\scripts\kimi-run-once.ps1' -Workspace '.' -Message 'Reply only OK'
```

Raw stream-json:

```powershell
& '.\scripts\kimi-run-once.ps1' -Workspace '.' -StreamJson -Message 'Reply only OK'
```

### Start or continue a supervised session

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -Message 'Inspect the repo and report what you will do first.'
```

Reset a session:

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Reset -Workspace '.' -Message 'Start fresh and inspect the local installation.'
```

Increase native recovery wait window:

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -RecoveryWaitMs 300000 -Message 'Repair the local tool, verify it, and report remaining risks.'
```

Default native recovery wait:

- 10 minutes (`600000 ms`)

Force transcript fallback:

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -ForceTranscript -Message 'Read the transcript and continue in fallback mode.'
```

Preview the exact prompt:

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -ShowPrompt -Message 'Inspect only these files.'
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -ShowPrompt -ForceTranscript -Message 'Inspect only these files.'
```

Run the regression harness:

```powershell
& '.\scripts\test-kimi-supervision.ps1'
```

## Thinking mode and model selection

As of the current official Kimi Code CLI docs, there are two official thinking switches:

- `--thinking`
- `--no-thinking`

There is no separate official CLI flag like:

- `--thinking high`
- `--reasoning-effort high`

For this skill, the wrapper behavior is intentionally simple:

1. turn on thinking explicitly
2. do not pass a per-run `--model` override

This skill does step 1 by default:

- `kimi-run-once.ps1` enables `--thinking` unless you pass `-NoThinking`
- `kimi-chat.ps1` enables `--thinking` unless you pass `-NoThinking`

Important:

- this skill does not expose a wrapper-level `-Model` parameter
- this skill should follow the user's local Kimi default model or alias configuration
- if a different model must be used, change local Kimi configuration first rather than hard-coding a model into one wrapper invocation
- do not infer a special "high" model mapping from memory

Recommended commands:

```powershell
& '.\scripts\kimi-run-once.ps1' -Workspace '.' -Message 'Inspect the repo and report only the root cause.'
```

```powershell
& '.\scripts\kimi-chat.ps1' -Session 'demo' -Workspace '.' -Message 'Patch the bug, verify it, and report remaining risks.'
```

If you want to disable thinking for a cheap or fast read-only check:

```powershell
& '.\scripts\kimi-run-once.ps1' -Workspace '.' -NoThinking -Message 'Reply only OK'
```

If you want Kimi itself to default to thinking outside these wrapper scripts, set this in `~/.kimi/config.toml`:

```toml
default_thinking = true
```

If you need to change which model Kimi uses by default, do it in local Kimi configuration, then let these wrapper scripts inherit that configuration without adding an explicit per-run model override.

## CLI self-check before guessing

When an agent is unsure how to invoke Kimi, or a Kimi call behaves unexpectedly, do not guess flags from memory.

Follow this order:

1. run `kimi --help`
2. run the relevant subcommand help, for example `kimi info --help`, `kimi export --help`, `kimi mcp --help`, or `kimi web --help`
3. if the local help output is still not enough, open the documentation URLs printed by `kimi --help`

Current `kimi --help` points to:

- `https://moonshotai.github.io/kimi-cli/`
- `https://moonshotai.github.io/kimi-cli/llms.txt`

Hard rules:

- trust the local `kimi --help` output over stale notes or memory if they conflict
- do not invent unsupported flags like `--thinking high`
- before patching these wrapper scripts, reproduce the problem with the smallest direct `kimi ...` command you can
- if a wrapper script fails but the equivalent direct `kimi` command works, treat that as a wrapper bug, not a Kimi CLI bug
- when prompting Kimi to use the supervision schema, do not treat words like `CHANGES` or `NO_CHANGES` as proof that the task is a write task

High-signal options shown in the current top-level help:

- `--work-dir` / `-w`
- `--add-dir`
- `--session` / `-S`
- `--continue` / `-C`
- `--config`
- `--config-file`
- `--model` / `-m`
- `--thinking` / `--no-thinking`
- `--yolo`
- `--prompt` / `-p`
- `--print`
- `--input-format`
- `--output-format`
- `--agent`
- `--agent-file`
- `--skills-dir`

Top-level commands shown in the current help:

- `login`
- `logout`
- `term`
- `acp`
- `info`
- `export`
- `mcp`
- `vis`
- `web`

Minimum triage bundle when a Kimi invocation looks wrong:

```powershell
kimi --help
kimi --version
kimi info --json
```

Then add the relevant subcommand help, for example:

```powershell
kimi info --help
kimi export --help
```

## Inspection commands

Read flattened latest reply:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View last
```

Read full transcript:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View transcript
```

Read prompt actually sent:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View prompt
```

Read raw stream-json:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View raw
```

Read session metadata:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View meta
```

Read status summary:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View status
```

Read native context directly:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-context
```

Read native wire log directly:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-wire
```

Read latest assistant message from native context:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-last-assistant
```

## How supervision should work

Recommended sequence:

1. Give Kimi a narrow task
2. Inspect `status`
3. Read `last`
4. If output looks incomplete, inspect native files
5. Verify important claims locally
6. Only then answer the user

Do not trust Kimi automatically.

Always verify when Kimi reports:

- versions
- file paths
- diffs
- install status
- command outcomes
- repair success

## How to interpret artifacts

### `last-response.txt`

This is the flattened assistant reply that Codex usually reads first.

It may contain:

- normal text
- `[THINK] ...`
- `[TOOL_CALL] ...`
- `[NO_TEXT_EXTRACTED]`

Important:

- `[NO_TEXT_EXTRACTED]` does not mean Kimi did nothing
- it often means stdout was incomplete or flattening had nothing usable yet

### `session.json`

This file records supervision state, including:

- `mode`
- `kimi_session_id`
- `workspace`
- `last_native_error`
- `native_context_path`
- `native_wire_path`
- `recovery_status`
- `last_context_line_count`
- `last_wire_line_count`
- `last_recovered_at`
- `updated_at`
- `contract_version`
- `required_sections`
- `detected_sections`
- `missing_sections`
- `result_classification`
- `gate_passed`
- `validation_warnings`
- `handoff_reason`
- `output_source`
- `verification_confidence`
- `task_risk_level`
- `completion_claimed`

Interpretation:

- `mode = native`: Kimi native session was used
- `mode = transcript`: transcript replay fallback was used
- `recovery_status = completed`: usable result recovered
- `recovery_status = no_text_but_native_activity`: Kimi native files moved, but no final usable assistant text was confidently recovered
- `recovery_status = timed_out`: recovery wait window expired

Read this as a monitoring file, not just a result file.

Read `status` first when deciding whether to trust a run:

- `result_classification = usable`: output passed the gate
- `result_classification = incomplete`: required structure or evidence is missing
- `result_classification = unverified`: result may be useful, but verification is not strong enough
- `result_classification = host_error`: launcher/runtime/shell failure happened before a trustworthy result was produced
- `result_classification = handoff_required`: high-risk or weakly verified result needs supervisor review

### Native files

Kimi native files live under `~/.kimi/sessions/.../<kimi_session_id>/`.

The most useful files are:

- `context.jsonl`
- `wire.jsonl`

Interpretation:

- `context.jsonl`: source of truth conversation log
- `wire.jsonl`: low-level event stream, useful to tell whether work is still progressing

## Native recovery rules

This skill was specifically built to handle the case where:

- `kimi --print` returns empty stdout
- `kimi --print` returns only partial text
- native context still contains the real answer

When native recovery is needed, the script:

1. captures the pre-run context line count
2. waits for new native activity
3. reads only assistant messages created after that snapshot
4. avoids accidentally reusing an older assistant reply
5. waits for native activity to stop for multiple polls before treating the run as settled

This is a deliberate guard against stale native recovery.

## Failure classification

Do not call a run failed just because `last` looks empty.

Treat it as incomplete first.

Check in this order:

```powershell
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View status
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-last-assistant
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-context
& '.\scripts\kimi-view-session.ps1' -Session 'demo' -View native-wire
```

Signs Kimi may still be working:

- `wire.jsonl` keeps growing
- `context.jsonl` keeps growing
- `native-last-assistant` is still intermediate or obviously incomplete
- `recovery_status` is still `no_text_but_native_activity`
- recent context or wire line counts are still moving

Treat it as a real failure only when:

- native files stop advancing
- no new assistant result appears during the full recovery window
- there is no usable output in `context.jsonl`

Default rule:

- give Kimi at least 10 minutes on substantial tasks before concluding it stopped without useful output

## Escalation rules (from real incidents)

Do not loop forever on the same command shape.

Escalate from retry to diagnosis when the same failure repeats with low-level launcher errors, for example:

- `ResourceUnavailable`
- `Program 'xxx.exe' failed to run ... 找不到指定的模块`
- Node assertion crash during startup (for example `ncrypto::CSPRNG(nullptr, 0)`)
- `UnicodeEncodeError: 'gbk' codec can't encode character` (Windows Chinese locale print crash)

When this happens:

1. stop blind retries
2. mark it as host runtime/shell issue candidate
3. switch to artifact-based verification (`status`, native logs, file checks)
4. if needed, ask user to run one command in their normal terminal for confirmation

This avoids misclassifying a host-shell problem as a Kimi/task failure.

**Hard rule: the same low-level error appearing a second time means stop and diagnose. Do not patch scripts or change environment variables before checking whether context.jsonl already has the answer.**

## Print-layer crash recovery (GBK / UnicodeEncodeError)

This is a confirmed recurring crash pattern on Chinese Windows. kimi.exe (PyInstaller bundle) completes the task successfully but crashes while printing the result because `visualize.py` tries to write a non-GBK character (e.g. `\xa0`) to stdout. The answer is already written to `context.jsonl` before the crash.

**The task is done. Only the print layer failed.**

Follow this decision tree exactly. Do not skip steps.

### Step 1 — Check session status

```powershell
$skillDir = Join-Path $env:USERPROFILE ".agents\skills\kimi-supervision"
& "$skillDir\scripts\kimi-view-session.ps1" -Session '<session-name>' -View status
```

Read `kimi_session_id` from the output.

- If `kimi_session_id` is a real GUID → go to **Step 2A**
- If `kimi_session_id` is null (script crashed before writing session.json) → go to **Step 2B**

### Step 2A — session ID known: use kimi-view-session directly

```powershell
& "$skillDir\scripts\kimi-view-session.ps1" -Session '<session-name>' -View native-last-assistant
```

- If output contains the answer → extract and present to user. Done.
- If output is empty or `[NO_TEXT_EXTRACTED]` → go to **Step 3**.

### Step 2B — session ID lost: find context.jsonl by timestamp

```powershell
Get-ChildItem "$env:USERPROFILE\.kimi\sessions" -Recurse -Filter context.jsonl |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 FullName, Length, LastWriteTime
```

Pick the file modified closest to when the task ran. Then read the last assistant message:

```powershell
$path = "<full path to context.jsonl>"
$lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
$aLines = $lines | Where-Object { $_ -like '*"role":"assistant"*' }
$last = $aLines[-1] | ConvertFrom-Json
$content = if ($last.content -is [array]) {
    ($last.content | Where-Object { $_.type -eq 'text' }).text
} else { $last.content }
Write-Output $content
```

- If `$content` has the answer → extract and present to user. Done.
- If empty → go to **Step 3**.

### Step 3 — nothing in context.jsonl: retry once with narrower prompt

Only reach here if context.jsonl genuinely has no assistant reply. Retry once with a shorter, simpler prompt. If it crashes again with the same GBK error, ask the user to run the script directly from their own PowerShell terminal — the Claude Code execution environment may have a console inheritance issue that does not affect a normal terminal session.

## Environment hygiene before running Kimi

This environment has shown cases where key vars are missing in-process.
Always initialize and verify these before complex runs:

- `SystemRoot`
- `windir`
- `USERPROFILE`
- `HOME`
- `LOCALAPPDATA`
- `APPDATA`

The scripts already call `Initialize-KimiEnvironment`, but if external commands still fail, validate effective values explicitly before deeper debugging.

## Host-shell vs task failure quick test

If you suspect the shell host is the problem, use this decision rule:

1. native artifacts (`context.jsonl`/`wire.jsonl`) show meaningful progress:
   - treat as supervision extraction/host issue, not task failure
2. native artifacts are idle and no output appears:
   - treat as real task failure and resend with narrower scope

This rule is mandatory before declaring "Kimi failed."

## Prompting guidance

Good supervision prompts are:

- narrow
- evidence-oriented
- explicit about whether Kimi may modify files
- explicit about how to report results

Prefer prompts like:

- `Inspect the local OpenClaw installation and determine its version. Only use local metadata or package files. Report the exact file path you used.`
- `Read these two files only and summarize the differences. Do not modify anything.`
- `Patch the bug in X, then report exactly which files you changed and what remains unverified.`

Avoid prompts like:

- `fix everything`
- `inspect the whole machine`
- `figure out what's wrong`

The current scripts already inject a default ending schema, so your prompt can focus on task scope instead of restating the schema every time.

The default schema is:

- `TASK`
- `PLAN`
- `EVIDENCE`
- `CHANGES`
- `VERIFICATION`
- `REMAINING_RISKS`

Use high-risk prompts carefully. If the task touches auth, credentials, config, deletion, irreversible operations, or system-level settings, the harness is expected to escalate weakly verified results to `handoff_required`.

## Kimi CLI dependency

This skill requires a working local `kimi` CLI.

Resolution order:

1. `KIMI_CLI_PATH`
2. `KIMI_EXECUTABLE_PATH`
3. `Get-Command kimi.exe`
4. `%USERPROFILE%\.local\share\kimi-cli\kimi.exe`
5. `%USERPROFILE%\.local\bin\kimi.exe`
6. `Get-Command kimi`
7. `%USERPROFILE%\.local\bin\kimi.cmd`

Health check:

- `kimi info --json`

Direct `kimi.exe` is preferred over the `.cmd` wrapper when both exist, because some PowerShell hosts are less stable when launching the wrapper directly.

## Install and repair

Install:

```powershell
Invoke-RestMethod https://code.kimi.com/install.ps1 | Invoke-Expression
```

Or:

```powershell
uv tool install --python 3.13 kimi-cli
```

Verify:

```powershell
kimi --version
kimi info --json
```

If Kimi exists but still fails:

- ensure `SystemRoot` exists
- ensure `windir` exists
- ensure `USERPROFILE` exists
- ensure `HOME` exists
- reinstall or upgrade: `uv tool upgrade kimi-cli --no-cache`
- set `KIMI_CLI_PATH` if PATH resolution is wrong

This skill's scripts also patch missing Windows environment variables in-process before invoking Kimi.

## Practical anti-loop policy

For install/upgrade/repair tasks:

- Require fixed ending schema (`ROOT_CAUSE`, `CHANGES`, `VERIFICATION`, `REMAINING_RISKS`)
- Limit repeated identical retries; after 2 similar failures, switch to:
  - native artifact inspection
  - direct filesystem validation
  - host-shell diagnosis

If package install partially succeeds (files updated but command runtime broken), report split status explicitly:

- `file state`
- `wrapper/entrypoint state`
- `runtime execution state`

This prevents "all failed" and "all done" misreports.

## Mandatory CLI flag set for non-interactive Kimi runs

These flags are what the bundled scripts use, and the combination is empirically required for substantive tasks (≥1 PDF read, ≥1 multi-step reasoning, anything that produces >100 tokens of output). If you bypass the supervision scripts and call `kimi` via your own subprocess, **use these same flags** or expect loops/timeouts/empty stdout.

Required:
- `--print` — non-interactive Print mode. Implicitly enables `--yolo` (auto-approve all tool actions). Per official docs: "以 Print 模式运行（非交互式），隐式启用 `--yolo`". Without this, kimi waits for interactive approval and the subprocess hangs.
- `--output-format stream-json` — JSONL with one JSON object per line. Per official docs: "用于程序化集成". Each event (assistant turn / tool turn / tool result) is a separate parseable record. The default `text` format is unsafe for non-interactive consumers because (a) Kimi may emit empty stdout when its final answer is mediated through tool-use, and (b) when Kimi loops on tool calls with no terminal answer, `text` mode gives you nothing parseable while `stream-json` gives you the full event log to diagnose.
- `--thinking` (or **omit `--no-thinking`**) — REQUIRED for any task that needs Kimi to plan its own tool-use. **`--no-thinking` is the single highest-impact bug magnet** for non-interactive callers. Without thinking, Kimi loses the ability to know when its tool-use chain has gathered enough information to emit the final answer; it loops on diagnostic commands (e.g. re-reading the same `page_1.txt` 5+ times in succession) until the timeout cuts it off mid-loop, leaving the consumer with `failed_kimi_timeout` or `nonzero_exit` and no usable output.

Recommended:
- `-w <work_dir>` — give Kimi a scratch directory; otherwise it writes scratch files into your CWD.
- `--add-dir <pdf_parent_dir>` — extend workspace scope so Kimi can read input files outside `-w`. **Required when the PDF/data is not under `-w`.**
- `--session <uuid>` — create or resume a specific native session id; lets you find `~/.kimi/sessions/.../<uuid>/context.jsonl` deterministically for native recovery.

Optional / advanced:
- `--final-message-only` — valid only with `--print`; outputs only the final assistant text. Saves stdout bandwidth, but **breaks loop diagnosis** because intermediate events are gone. Use when you trust the run; avoid when debugging.

### Anti-pattern: `--no-thinking` for substantive tasks

This is the single most common reason a Kimi subprocess "fails" without producing output. Symptoms:
- exit code 0 with empty stdout, OR exit code 1 with empty stderr (only "To resume this session: kimi -r ..." in stderr)
- `failed_kimi_timeout` after 5–10 minutes
- Native `context.jsonl` shows ≥ 50 tool calls, the last 5–10 of which are **identical** (same `command` field, same result), and zero assistant `content[].type=="text"` blocks across the run

How to recognize this in `context.jsonl`:
```python
# Pseudocode
if all_tool_calls_in_last_window_are_identical(window=5) and not any_assistant_text_block_seen:
    print("CLASSIFIED: --no-thinking loop pattern. Re-run with --thinking.")
```

The supervision scripts default to `--thinking`. Override with `-NoThinking` only for trivial echo/sanity tasks ("reply OK"), not for real work.

### Anti-pattern: bypassing the supervision scripts via direct `subprocess.run`

If your code calls `kimi` via `subprocess.run([..."kimi", "--print", ...])` directly (Python / Node / etc.), you **lose** all the supervision scripts' protections:
- no native context recovery when stdout is empty
- no GBK encoding salvage on Chinese Windows
- no transcript fallback
- no `session.json` audit trail
- no `recovery_status` / `result_classification`

Acceptable patterns for direct subprocess callers:
- (a) Use the supervision scripts via `pwsh -File kimi-chat.ps1 ...` and parse their `last-response.txt` / `session.json` outputs.
- (b) If you must call `kimi` directly, replicate the flag set above (`--print --output-format stream-json --thinking`), and after the subprocess exits, parse the JSONL stdout to recover the final assistant turn (last `role=="assistant"` record's `content[].type=="text"`). Do NOT trust the default `text` format.
- (c) If the consumer needs a specific JSON schema (like the Wave8 D4 runner does), write the prompt to ASK FOR JSON, AND use stream-json output, AND extract the final assistant text from the JSONL, AND `json.loads()` that text. Three layers, all required.

### Loop detection helper (for callers diagnosing failures)

When `context.jsonl` exists but the run "failed":
```powershell
# Count identical tool calls in last N records:
& "$kimiHome\scripts\kimi-view-session.ps1" -Session 'name' -View native-context |
  Select-String -Pattern '"command"' | Select-Object -Last 10
# If 5+ are identical → --no-thinking loop pattern.
```

Or in Python (post-mortem):
```python
import json
records = [json.loads(l) for l in open('context.jsonl', encoding='utf-8') if l.strip()]
tool_cmds = []
for r in records:
    for tc in r.get('tool_calls', []) or []:
        try:
            args = json.loads(tc['function']['arguments'])
            tool_cmds.append(args.get('command') or args.get('path') or '')
        except: pass
last5 = tool_cmds[-5:]
if len(set(last5)) == 1 and len(last5) >= 3:
    print("LOOP PATTERN: last 5 tool calls identical")
```

## Empirical validation (cycle 19, 2026-05-10 / Wave8 LLM-for-CO2RR-Raman)

Real-world failure-and-fix cycle confirming the anti-patterns above:

**Failure**: D4 batch runner (`scripts/run_wave8_a1_batch.py`) called `kimi --print --output-format text --final-message-only --no-thinking` with 300s timeout. On a 1.33 MB Raman spectroscopy PDF (P-03aa42 / Gunathunge 2017), Kimi:
- ran 100 tool calls in `context.jsonl`
- last 5 calls were the **identical** `python -c "with open('page_1.txt'...)" Write-Host '---END---'` command, returning the same successful result each time
- ZERO assistant `content[].type=="text"` blocks ever produced — so `--final-message-only` got nothing to emit
- exit 1 after 5 min with only "To resume this session: kimi -r d8fc770f..." in stderr
- runner classified as `failed_kimi_timeout`; second try with 900s timeout: same loop, same `nonzero_exit`

**Fix verified**: Same prompt + same PDF, with `--print --output-format stream-json --thinking`, 12-min ceiling:
- ran 14 assistant + 13 tool turns total (vs 100+100 in failed run)
- final assistant text block contained valid JSON: `{"source_name":"kimi", "input_contract_satisfied":true, "claims":[8 entries with verbatim PDF excerpts]}`
- exit 0 in <12 min

**End-to-end production verification (cycle 20)**: same patched runner re-run on P-03aa42 in actual D4 batch context produced `kimi_status=success, kimi_claim_count=13, contract_satisfied=true`. Subagent path independently produced 17 claims. `both_satisfied_count=1` (first time both extraction paths succeeded for any paper in this project).

**Diagnosis chain that solved it**:
1. Read `~/.kimi/sessions/<wd_hash>/<session_uuid>/context.jsonl`
2. Histogram last 10 tool calls → noticed identical commands
3. Cross-checked official docs (`kimi --print` + `--output-format` + `--thinking`)
4. Controlled experiment with single flag swap (`--no-thinking` → `--thinking`, `text` → `stream-json`)
5. Verified end-to-end JSON validity standalone, then in production runner

**Lesson hardened into this skill**: the supervision scripts now treat `--thinking` as the default and `-NoThinking` as an explicit opt-out for trivial tasks only. External callers (D4-runner-style direct `subprocess.run`) that omit these flags are explicitly flagged as anti-pattern.

## What Codex should tell the user after using this skill

When you use Kimi for the user, structure your own answer as:

1. what you asked Kimi to do
2. what Kimi reported
3. what you verified independently
4. the final conclusion

If native recovery was needed, mention that explicitly.

If fallback transcript mode was used, mention that explicitly.

If Kimi was still active for a while before settling, mention that too. The supervision story should reflect runtime behavior, not only the last line of output.

## Confirmed behavior in this environment

The current scripts have already been verified to do all of the following:

- one-shot Kimi execution with recovered output
- persistent native Kimi session continuation across multiple turns
- recovery from native `context.jsonl` when flattened stdout is empty
- prevention of stale assistant reuse during native recovery
- long-wait supervision with native activity monitoring instead of immediate failure classification

Example verified pattern:

1. first turn asks Kimi to reply `ALPHA`
2. second turn asks what the previous final reply was
3. Kimi answers `ALPHA` from the same native session

That is the intended behavior of this skill.
