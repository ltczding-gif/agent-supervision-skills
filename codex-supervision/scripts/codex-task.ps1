# codex-task.ps1 — delegate an arbitrary task to codex (rescue equivalent).
# Usage examples:
#   & .\codex-task.ps1 -Workspace . -Message 'Diagnose the flaky test_login_redirect.'
#   & .\codex-task.ps1 -Workspace . -Write -Message 'Patch the off-by-one in src/foo.py.'
#   & .\codex-task.ps1 -Workspace . -Model gpt-5.3-codex-spark -Effort high -Message '...'
#   & .\codex-task.ps1 -Workspace . -NoSchema -Message 'Just answer my question without the structured ending.'
#
# Multi-turn:
#   & .\codex-task.ps1 -Workspace . -Message 'Diagnose X'              # first turn
#   & .\codex-task.ps1 -Workspace . -ResumeLast -Message 'Apply the top fix'   # continue
#   & .\codex-task.ps1 -Workspace . -Resume <session-id> -Message '...' # explicit resume
#
# Structured JSON output (codex enforces the schema):
#   & .\codex-task.ps1 -Workspace . -OutputSchema 'schemas/triage.json' -Message 'Triage this log'
#
# Ephemeral (no rollout persisted to ~/.codex/sessions, can't be resumed later):
#   & .\codex-task.ps1 -Workspace . -Ephemeral -Message 'Sensitive content...'

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Workspace = '.',
    [string]$Model,
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh')]
    [string]$Effort,
    [string[]]$AddDirs,
    [switch]$Write,
    [switch]$DangerousFullAccess,
    [switch]$NoSchema,
    [int]$TimeoutSec = 1800,             # 30 min default; raise for very long tasks
    [switch]$ShowPrompt,

    # Multi-turn resume
    [string]$Resume,                     # explicit session UUID
    [switch]$ResumeLast,                 # most recent codex session

    # Power flags
    [switch]$Ephemeral,                  # don't persist rollout to ~/.codex/sessions
    [string]$OutputSchema,               # path to JSON Schema file (plain exec only)
    [string[]]$Images                    # image file paths (plain + resume)
)

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path -LiteralPath $Workspace)) {
    throw "Workspace not found: $Workspace"
}
if (-not $Message.Trim()) {
    throw '-Message is required and must be non-empty.'
}
if ($Resume -and $ResumeLast) {
    throw 'Pass EITHER -Resume <session-id> OR -ResumeLast, not both.'
}
# Sandbox flags don't apply on resume — codex inherits from the original session.
# Warn loudly so callers don't believe they have edit access when they may not.
if (($Resume -or $ResumeLast) -and ($Write -or $DangerousFullAccess)) {
    Write-Warning '-Write / -DangerousFullAccess are ignored when resuming: codex inherits the sandbox from the original session. To change sandbox, start a fresh session.'
}
if (($Resume -or $ResumeLast) -and $OutputSchema) {
    Write-Warning '-OutputSchema is ignored when resuming: codex exec resume does not accept --output-schema.'
}

$sandbox = 'read-only'
if ($Write)                { $sandbox = 'workspace-write' }
if ($DangerousFullAccess)  { $sandbox = 'danger-full-access' }

# Wrap user content in an explicit delimiter so a user message that itself contains
# the section headers (TASK:, EVIDENCE:, ...) doesn't fight the appended schema.
# Escape any literal </user_task> in the message so a malicious or careless user
# message can't close the delimiter early and swallow the schema block.
$safeMessage = $Message -replace '</user_task>', '<\/user_task>'
$userBlock = "<user_task>`n$safeMessage`n</user_task>"

# Skip schema when -NoSchema, or when -OutputSchema is set (codex's JSON schema
# enforcement replaces our text-section schema), or for resume turns (mid-conversation,
# the schema would re-introduce structure codex already established).
$skipSchema = $NoSchema -or $OutputSchema -or $Resume -or $ResumeLast

if ($skipSchema) {
    $prompt = $userBlock
} else {
    $prompt = @"
$userBlock

When you are done, end your response with these sections (use these exact section headers, OUTSIDE the <user_task> block above):

TASK: <one-line restatement of what you did>
PLAN: <what you intended to do, in 1-3 bullets>
EVIDENCE: <files read, commands run, test output — concrete>
CHANGES: <list of touched files with one-line description each, or NO_CHANGES>
VERIFICATION: <how you verified the change works, or NOT_RUN (reason)>
REMAINING_RISKS: <what still needs human attention>
"@
}

if ($ShowPrompt) {
    Write-Output $prompt
    return
}

$mode = if ($Resume -or $ResumeLast) { 'task-resume' } else { 'task' }
$session = New-CodexSession -Mode $mode -Workspace $Workspace

$execMode = if ($Resume -or $ResumeLast) { 'resume' } else { 'plain' }

$execArgs = @{
    Session                  = $session
    Mode                     = $mode
    Prompt                   = $prompt
    ExecMode                 = $execMode
    Sandbox                  = $sandbox
    DangerouslyBypassSandbox = [bool]$DangerousFullAccess
    Ephemeral                = [bool]$Ephemeral
    TimeoutSec               = $TimeoutSec
}
if ($Model)        { $execArgs.Model            = $Model }
if ($Effort)       { $execArgs.Effort           = $Effort }
if ($AddDirs)      { $execArgs.AddDirs          = $AddDirs }
if ($Resume)       { $execArgs.ResumeSessionId  = $Resume }
if ($ResumeLast)   { $execArgs.ResumeLast       = $true }
if ($OutputSchema) { $execArgs.OutputSchemaFile = $OutputSchema }
if ($Images)       { $execArgs.Images           = $Images }

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
