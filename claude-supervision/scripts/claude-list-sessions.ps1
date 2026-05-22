# claude-list-sessions.ps1 — inspect prior claude-supervision sessions.
#
# Usage examples:
#   & .\claude-list-sessions.ps1                                       # list last 10
#   & .\claude-list-sessions.ps1 -Last 5
#   & .\claude-list-sessions.ps1 -Session '20260522-110000-000-1234-5678-task' -View response

[CmdletBinding()]
param(
    [string]$Session,
    [ValidateSet('meta', 'prompt', 'response', 'stderr')]
    [string]$View = 'meta',
    [int]$Last = 10
)

. "$PSScriptRoot\common.ps1"

$root = Get-ClaudeSupervisionHome
$sessionsDir = Join-Path $root 'sessions'

if (-not (Test-Path -LiteralPath $sessionsDir)) {
    Write-Output "No sessions yet. State root: $root"
    return
}

function Read-AllText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '(file not found)' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

if ($Session) {
    if ($Session -notmatch '^[A-Za-z0-9-]+$' -or $Session -match '\.\.') {
        throw "Invalid session id format: $Session"
    }
    $dir = Join-Path $sessionsDir $Session
    $resolved = try { (Resolve-Path -LiteralPath $dir -ErrorAction Stop).ProviderPath } catch { $null }
    # Append a separator before StartsWith to prevent sibling-prefix attacks
    # (e.g. sessionsDir=C:\X\sessions matching C:\X\sessions-evil\...).
    $sessionsRoot = (Resolve-Path -LiteralPath $sessionsDir).ProviderPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved -or -not $resolved.StartsWith($sessionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Session not found or outside state root: $Session"
    }
    $dir = $resolved
    $file = switch ($View) {
        'meta'     { 'session.json' }
        'prompt'   { 'last-prompt.txt' }
        'response' { 'last-response.txt' }
        'stderr'   { 'stderr.log' }
    }
    Write-Output (Read-AllText (Join-Path $dir $file))
    return
}

$rows = Get-ChildItem -Directory -Path $sessionsDir |
    Sort-Object Name -Descending |
    Select-Object -First $Last |
    ForEach-Object {
        $meta = $null
        $metaPath = Join-Path $_.FullName 'session.json'
        if (Test-Path -LiteralPath $metaPath) {
            try { $meta = ([System.IO.File]::ReadAllText($metaPath)) | ConvertFrom-Json } catch { }
        }
        [pscustomobject]@{
            Id             = $_.Name
            Mode           = Get-PropOrDefault $meta 'mode'
            ExecMode       = Get-PropOrDefault $meta 'exec_mode'
            Exit           = Get-PropOrDefault $meta 'exit_code'
            Classification = Get-PropOrDefault $meta 'result_classification'
            DurationMs     = Get-PropOrDefault $meta 'duration_ms'
            TimedOut       = Get-PropOrDefault $meta 'timed_out'
            Workspace      = Get-PropOrDefault $meta 'workspace'
        }
    }

$rows | Format-Table -AutoSize
Write-Output "State root: $root"
