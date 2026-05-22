# codex-list-sessions.ps1 — inspect prior codex-supervision sessions.
# Usage examples:
#   & .\codex-list-sessions.ps1                                 # list last 10
#   & .\codex-list-sessions.ps1 -Last 5
#   & .\codex-list-sessions.ps1 -Session 20260521-141530-fff-1234-review -View response
#   & .\codex-list-sessions.ps1 -Session ... -View prompt|response|stderr|meta

[CmdletBinding()]
param(
    [string]$Session,
    [ValidateSet('meta', 'prompt', 'response', 'stderr')]
    [string]$View = 'meta',
    [int]$Last = 10
)

. "$PSScriptRoot\common.ps1"

$root = Get-CodexSupervisionHome
$sessionsDir = Join-Path $root 'sessions'

if (-not (Test-Path -LiteralPath $sessionsDir)) {
    Write-Output "No sessions yet. State root: $root"
    return
}

function Read-AllText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '(file not found)' }
    # ReadAllText preserves trailing newlines; Get-Content -Raw does too in PS7 but the
    # behavior differs by host — use the .NET API directly for consistency.
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

if ($Session) {
    # Defense against path traversal — session IDs match a strict pattern:
    # yyyyMMdd-HHmmss-fff-<PID>-<rand>-<mode>  (mode is letters/dashes only)
    if ($Session -notmatch '^[A-Za-z0-9-]+$' -or $Session -match '\.\.') {
        throw "Invalid session id format: $Session"
    }
    $dir = Join-Path $sessionsDir $Session
    $resolved = try { (Resolve-Path -LiteralPath $dir -ErrorAction Stop).Path } catch { $null }
    if (-not $resolved -or -not $resolved.StartsWith((Resolve-Path -LiteralPath $sessionsDir).Path, [StringComparison]::OrdinalIgnoreCase)) {
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

# List recent sessions.
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
