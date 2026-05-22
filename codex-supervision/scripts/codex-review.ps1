# codex-review.ps1 — non-interactive code review via `codex exec review`
# Handles both normal and adversarial review. Uses the native review subcommand
# (which natively understands --base / --uncommitted) so codex does the git diff scoping.
#
# Usage examples:
#   & .\codex-review.ps1 -Workspace .
#   & .\codex-review.ps1 -Workspace . -Base origin/main
#   & .\codex-review.ps1 -Workspace . -Adversarial -Focus 'auth boundary; migration safety'
#   & .\codex-review.ps1 -Workspace . -Adversarial -Focus '...' -Model gpt-5.5 -Effort high
#
# Review a specific commit:
#   & .\codex-review.ps1 -Workspace . -Commit abc1234
#
# Ephemeral (no rollout persisted):
#   & .\codex-review.ps1 -Workspace . -Ephemeral

[CmdletBinding()]
param(
    [string]$Workspace = '.',
    [string]$Base,                       # if set, --base <ref>; else --uncommitted (unless -Commit)
    [string]$Commit,                     # if set, --commit <SHA>; takes precedence over -Base
    [switch]$Adversarial,
    [string]$Focus = '',                 # used only when -Adversarial
    [string]$Model,
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh')]
    [string]$Effort,
    [int]$TimeoutSec = 1800,             # reviews can be long; default 30 min
    [switch]$ShowPrompt,

    # Power flags
    [switch]$Ephemeral                   # don't persist rollout to ~/.codex/sessions
    # Intentionally not exposed:
    # - -Search: codex exec (any subcommand) doesn't accept --search at 0.128.0.
    # - -OutputSchema: codex exec review doesn't accept --output-schema (only plain exec).
    #   For structured-output review, use codex-task.ps1 -OutputSchema with a review-style prompt.
)

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path -LiteralPath $Workspace)) {
    throw "Workspace not found: $Workspace"
}

# Sanitize user-controlled fields used in the adversarial template to defeat
# trivial prompt-injection that tries to close XML role tags.
function Get-SafeText {
    param([string]$Text)
    return ($Text -replace '[<>]', '').Trim()
}

$safeFocus  = if ($Focus)  { Get-SafeText $Focus }  else { '' }
$safeBase   = if ($Base)   { Get-SafeText $Base }   else { '' }
$safeCommit = if ($Commit) { Get-SafeText $Commit } else { '' }
if ($safeCommit -and $safeBase) {
    Write-Warning '-Commit and -Base are mutually exclusive in codex exec review; -Commit takes precedence and -Base is ignored.'
}
$scopeLabel = if ($safeCommit) {
    "changes introduced by commit: $safeCommit"
} elseif ($safeBase) {
    "diff against base ref: $safeBase"
} else {
    "current working tree (uncommitted + staged + untracked)"
}

if ($Adversarial) {
    $focusBlock = if ($safeFocus) { $safeFocus } else { '(no specific focus area provided)' }
    $prompt = @"
<role>
You are Codex performing an adversarial software review.
Your job is to break confidence in the change, not to validate it.
</role>

<task>
Review the repository context as if you are trying to find the strongest reasons this change should not ship yet.
Target: $scopeLabel
User focus: $focusBlock
</task>

<operating_stance>
Default to skepticism.
Assume the change can fail in subtle, high-cost, or user-visible ways until the evidence says otherwise.
Do not give credit for good intent, partial fixes, or likely follow-up work.
If something only works on the happy path, treat that as a real weakness.
</operating_stance>

<attack_surface>
Prioritize failures that are expensive, dangerous, or hard to detect:
- auth, permissions, tenant isolation, trust boundaries
- data loss, corruption, duplication, irreversible state changes
- rollback safety, retries, partial failure, idempotency gaps
- race conditions, ordering assumptions, stale state, re-entrancy
- empty-state, null, timeout, degraded-dependency behavior
- version skew, schema drift, migration hazards, compatibility regressions
- observability gaps that would hide failure or make recovery harder
</attack_surface>

<review_method>
Actively try to disprove the change.
Look for violated invariants, missing guards, unhandled failure paths, and assumptions that stop being true under stress.
Trace how bad inputs, retries, concurrent actions, or partially completed operations move through the code.
If the user supplied a focus area, weight it heavily, but still report any other material issue you can defend.
</review_method>

<finding_bar>
Report only material findings. No style, naming, or speculative concerns without evidence.
Each finding must answer: what can go wrong? why is this code path vulnerable? what is the likely impact? what concrete change reduces the risk?
</finding_bar>

<output_format>
Numbered list, severity-ordered (highest first). For each:
- **#N — <one-line label>** (severity: high | medium | low; confidence: 0.0-1.0)
- File: ``<path>`` lines ``<start>-<end>``
- What can go wrong: ...
- Why this path is vulnerable: ...
- Likely impact: ...
- Concrete recommendation: ...

Conclude with a one-line ship/no-ship verdict:
- ``needs-attention`` if any high-severity finding remains
- ``approve`` only if you cannot defend any substantive adversarial finding
</output_format>

<grounding_rules>
Stay grounded. Every finding must be defensible from the repo context or tool outputs.
Do not invent files, lines, code paths, or runtime behavior. If a conclusion depends on an inference, state that explicitly and keep confidence honest.
</grounding_rules>

<calibration_rules>
Prefer one strong finding over several weak ones. Do not dilute serious issues with filler.
If the change looks safe, say so directly and return no findings.
</calibration_rules>
"@
    $modeLabel = 'adversarial'
    $title = 'Adversarial review'
} else {
    $prompt = @"
Stay strictly in REVIEW MODE. Do not propose to make edits. Do not apply patches.

Scope: $scopeLabel.

Report findings ordered by severity (high -> low). For each finding include:
- file path and line range
- what is wrong
- why it matters (concrete impact)
- a concrete suggestion (do not apply it)

If no material issues exist, say so directly and stop.
"@
    $modeLabel = 'review'
    $title = 'Code review'
}

if ($ShowPrompt) {
    Write-Output $prompt
    return
}

$session = New-CodexSession -Mode $modeLabel -Workspace $Workspace

$execArgs = @{
    Session    = $session
    Mode       = $modeLabel
    Prompt     = $prompt
    ExecMode   = 'review'
    Title      = $title
    Ephemeral  = [bool]$Ephemeral
    TimeoutSec = $TimeoutSec
}
if ($Model)  { $execArgs.Model  = $Model }
if ($Effort) { $execArgs.Effort = $Effort }
# Review scope precedence: -Commit > -Base > default --uncommitted.
if ($Commit) {
    $execArgs.Commit = $Commit
} elseif ($Base) {
    $execArgs.Base = $Base
} else {
    $execArgs.Uncommitted = $true
}

$result = Invoke-CodexExec @execArgs

Write-Output (Format-CodexHeader -Result $result)
Write-Output $result.Stdout
if ($result.Stderr.Trim()) {
    Write-Output ''
    Write-Output '--- stderr (truncated to 4KB) ---'
    if ($result.Stderr.Length -gt 4096) {
        Write-Output ($result.Stderr.Substring(0, 4096) + '... [truncated; see stderr.log]')
    } else {
        Write-Output $result.Stderr
    }
}
