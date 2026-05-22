# claude-task.ps1 — delegate a task to Claude Code via `claude --print`.
#
# Common usage:
#   & .\claude-task.ps1 -Workspace . -Message 'Diagnose why test_login fails.'
#   & .\claude-task.ps1 -Workspace . -AcceptEdits -Message 'Patch the off-by-one in src/foo.py.'
#   & .\claude-task.ps1 -Workspace . -Continue -Message 'Keep going from the last turn.'
#   & .\claude-task.ps1 -Workspace . -Resume <uuid> -Message 'Apply your proposed fix.'
#
# Power user:
#   & .\claude-task.ps1 -Workspace . -Model sonnet -Effort high -FallbackModel haiku ...
#   & .\claude-task.ps1 -Workspace . -MaxTurns 5 -MaxBudgetUsd 0.50 -Message '...'
#   & .\claude-task.ps1 -Workspace . -SystemPromptFile ./review-system.txt -Message '...'
#   & .\claude-task.ps1 -Workspace . -AppendSystemPrompt 'Always use TypeScript.' -Message '...'
#   & .\claude-task.ps1 -Workspace . -Agent code-reviewer -Message '...'
#   & .\claude-task.ps1 -Workspace . -AgentsFile ./agents.json -Message '...'
#   & .\claude-task.ps1 -Workspace . -McpConfig ./linear-mcp.json -StrictMcpConfig -Message '...'
#   & .\claude-task.ps1 -Workspace . -Settings ./session-settings.json -Message '...'
#   & .\claude-task.ps1 -Workspace . -PluginDirs ./local-plugin -Message '...'
#   & .\claude-task.ps1 -Workspace . -JsonSchemaFile ./triage.json -OutputFormat json -Message '...'
#   & .\claude-task.ps1 -Workspace . -OutputFormat stream-json -IncludeHookEvents -Message '...'

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Workspace = '.',

    # ---- Continue / resume ----
    [switch]$Continue,
    [string]$Resume,
    [switch]$ForkSession,

    # ---- Model / effort / budget ----
    [string]$Model,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,
    [string]$FallbackModel,
    [double]$MaxBudgetUsd,
    [int]$MaxTurns,

    # ---- Permissions / tools ----
    [ValidateSet('default', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'plan')]
    [string]$PermissionMode = 'default',
    [switch]$AcceptEdits,
    [switch]$DangerouslySkipPermissions,
    [switch]$AllowDangerouslySkipPermissions,
    [string]$PermissionPromptTool,
    [string[]]$AllowedTools,
    [string[]]$DisallowedTools,
    [string]$ToolsSpec,
    [string[]]$AddDirs,

    # ---- Output ----
    [ValidateSet('text', 'json', 'stream-json')]
    [string]$OutputFormat = 'text',
    [ValidateSet('text', 'stream-json')]
    [string]$InputFormat,
    [switch]$IncludeHookEvents,
    [switch]$IncludePartialMessages,
    [string]$JsonSchemaFile,
    [string]$JsonSchemaInline,
    [switch]$VerboseOutput,                                       # claude --verbose (renamed to avoid CmdletBinding -Verbose collision)

    # ---- System prompt ----
    [string]$SystemPrompt,
    [string]$SystemPromptFile,
    [string]$AppendSystemPrompt,
    [string]$AppendSystemPromptFile,

    # ---- Agents ----
    [string]$Agent,
    [string]$AgentsInline,
    [string]$AgentsFile,

    # ---- MCP / settings / plugins ----
    [string[]]$McpConfig,
    [switch]$StrictMcpConfig,
    [string]$Settings,
    [string]$SettingsFile,
    [string]$SettingSources,
    [string[]]$PluginDirs,
    [string[]]$PluginUrls,

    # ---- Hooks lifecycle ----
    [switch]$Init,
    [switch]$InitOnly,
    [switch]$Maintenance,

    # ---- Persistence / cleanliness ----
    [switch]$NoSessionPersistence,
    [switch]$Bare,
    [switch]$DisableSlashCommands,
    [switch]$ExcludeDynamicSystemPromptSections,
    [string]$Name,
    [string]$ForceSessionUuid,
    [string[]]$Betas,

    # ---- Diagnostics ----
    [string]$DebugFilter,                                         # claude --debug [filter] (renamed to avoid CmdletBinding -Debug collision)
    [string]$DebugFile,

    # ---- File resources ----
    [string[]]$Files,

    # ---- Multimodal (images) ----
    # Paths to PNG/JPG/GIF/WebP files. The wrapper validates each path, resolves
    # relative paths against -Workspace, auto-extends --add-dir to cover parent
    # dirs, and prepends a structured <attached_images> block to the prompt so
    # claude reads them via its Read tool (claude CLI has no -i flag).
    [string[]]$Images,

    # ---- Schema gating ----
    [switch]$NoSchema,
    [int]$TimeoutSec = 1800,
    [switch]$ShowPrompt
)

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path -LiteralPath $Workspace)) { throw "Workspace not found: $Workspace" }
if (-not $Message.Trim())                     { throw '-Message is required and must be non-empty.' }

if ($Continue -and $Resume) {
    throw 'Pass EITHER -Continue OR -Resume <id>, not both.'
}

if ($AcceptEdits -and $PSBoundParameters.ContainsKey('PermissionMode') -and $PermissionMode -ne 'acceptEdits') {
    Write-Warning "-AcceptEdits and -PermissionMode '$PermissionMode' both given; -AcceptEdits wins."
}
if ($AcceptEdits) { $PermissionMode = 'acceptEdits' }

# Permission flag precedence: -DangerouslySkipPermissions wins over everything because
# Invoke-ClaudeCli skips --permission-mode entirely when --dangerously-skip-permissions
# is passed. Warn so the caller isn't surprised.
if ($DangerouslySkipPermissions -and ($AcceptEdits -or ($PSBoundParameters.ContainsKey('PermissionMode') -and $PermissionMode -ne 'default'))) {
    Write-Warning "-DangerouslySkipPermissions overrides -AcceptEdits / -PermissionMode '$PermissionMode'. Claude will run with NO permission checks."
}

# -ForceSessionUuid only makes sense for fresh (plain) runs.
if ($ForceSessionUuid -and ($Continue -or $Resume)) {
    throw '-ForceSessionUuid only applies to fresh (plain) sessions; cannot combine with -Continue / -Resume.'
}

# Negative budget caps are user errors — refuse silently dropping them.
if ($PSBoundParameters.ContainsKey('MaxBudgetUsd') -and $MaxBudgetUsd -le 0) {
    Write-Warning "-MaxBudgetUsd '$MaxBudgetUsd' is <= 0 and will be silently ignored by the wrapper. Set a positive value or omit the flag."
}
if ($PSBoundParameters.ContainsKey('MaxTurns') -and $MaxTurns -le 0) {
    Write-Warning "-MaxTurns '$MaxTurns' is <= 0 and will be silently ignored. Set a positive value or omit the flag."
}

# Wrap user message in delimiter + structured ending.
$safeMessage = $Message -replace '</user_task>', '<\/user_task>'
$userBlock = "<user_task>`n$safeMessage`n</user_task>"

if ($NoSchema -or $JsonSchemaFile -or $JsonSchemaInline) {
    # Skip our schema if a JSON Schema is in play — they'd fight each other.
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

$execMode = if ($Resume) { 'resume' } elseif ($Continue) { 'continue' } else { 'plain' }
$modeLabel = if ($execMode -eq 'plain') { 'task' } else { "task-$execMode" }
$session = New-ClaudeSession -Mode $modeLabel -Workspace $Workspace

# Build splat. Use $PSBoundParameters.ContainsKey() for nullable types (int/double).
$invArgs = @{
    Session                            = $session
    Mode                               = $modeLabel
    Prompt                             = $prompt
    ExecMode                           = $execMode
    PermissionMode                     = $PermissionMode
    DangerouslySkipPermissions         = [bool]$DangerouslySkipPermissions
    AllowDangerouslySkipPermissions    = [bool]$AllowDangerouslySkipPermissions
    OutputFormat                       = $OutputFormat
    TimeoutSec                         = $TimeoutSec
    NoSessionPersistence               = [bool]$NoSessionPersistence
    Bare                               = [bool]$Bare
    DisableSlashCommands               = [bool]$DisableSlashCommands
    ExcludeDynamicSystemPromptSections = [bool]$ExcludeDynamicSystemPromptSections
    Init                               = [bool]$Init
    InitOnly                           = [bool]$InitOnly
    Maintenance                        = [bool]$Maintenance
    StrictMcpConfig                    = [bool]$StrictMcpConfig
    VerboseOutput                      = [bool]$VerboseOutput
    IncludeHookEvents                  = [bool]$IncludeHookEvents
    IncludePartialMessages             = [bool]$IncludePartialMessages
}
if ($Resume)                 { $invArgs.ResumeSessionId      = $Resume }
if ($ForkSession)            { $invArgs.ForkSession          = $true }
if ($Model)                  { $invArgs.Model                = $Model }
if ($Effort)                 { $invArgs.Effort               = $Effort }
if ($FallbackModel)          { $invArgs.FallbackModel        = $FallbackModel }
if ($PSBoundParameters.ContainsKey('MaxBudgetUsd')) { $invArgs.MaxBudgetUsd = $MaxBudgetUsd }
if ($PSBoundParameters.ContainsKey('MaxTurns'))     { $invArgs.MaxTurns     = $MaxTurns }
if ($PermissionPromptTool)   { $invArgs.PermissionPromptTool = $PermissionPromptTool }
if ($AllowedTools)           { $invArgs.AllowedTools         = $AllowedTools }
if ($DisallowedTools)        { $invArgs.DisallowedTools      = $DisallowedTools }
if ($PSBoundParameters.ContainsKey('ToolsSpec')) { $invArgs.ToolsSpec = $ToolsSpec }
if ($AddDirs)                { $invArgs.AddDirs              = $AddDirs }
if ($InputFormat)            { $invArgs.InputFormat          = $InputFormat }
if ($JsonSchemaFile)         { $invArgs.JsonSchemaFile       = $JsonSchemaFile }
if ($JsonSchemaInline)       { $invArgs.JsonSchemaInline     = $JsonSchemaInline }
if ($SystemPrompt)           { $invArgs.SystemPrompt         = $SystemPrompt }
if ($SystemPromptFile)       { $invArgs.SystemPromptFile     = $SystemPromptFile }
if ($AppendSystemPrompt)     { $invArgs.AppendSystemPrompt   = $AppendSystemPrompt }
if ($AppendSystemPromptFile) { $invArgs.AppendSystemPromptFile = $AppendSystemPromptFile }
if ($Agent)                  { $invArgs.Agent                = $Agent }
if ($AgentsInline)           { $invArgs.AgentsInline         = $AgentsInline }
if ($AgentsFile)             { $invArgs.AgentsFile           = $AgentsFile }
if ($McpConfig)              { $invArgs.McpConfig            = $McpConfig }
if ($Settings)               { $invArgs.Settings             = $Settings }
if ($SettingsFile)           { $invArgs.SettingsFile         = $SettingsFile }
if ($SettingSources)         { $invArgs.SettingSources       = $SettingSources }
if ($PluginDirs)             { $invArgs.PluginDirs           = $PluginDirs }
if ($PluginUrls)             { $invArgs.PluginUrls           = $PluginUrls }
if ($Name)                   { $invArgs.Name                 = $Name }
if ($ForceSessionUuid)       { $invArgs.ForceSessionUuid     = $ForceSessionUuid }
if ($Betas)                  { $invArgs.Betas                = $Betas }
if ($PSBoundParameters.ContainsKey('DebugFilter')) { $invArgs.DebugFilter = $DebugFilter }
if ($DebugFile)              { $invArgs.DebugFile            = $DebugFile }
if ($Files)                  { $invArgs.Files                = $Files }
if ($Images)                 { $invArgs.Images               = $Images }

$result = Invoke-ClaudeCli @invArgs

Write-Output (Format-ClaudeHeader -Result $result)
Write-Output $result.Stdout
Resolve-ClaudeStreamOutput -Result $result
