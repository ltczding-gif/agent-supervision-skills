# codex-setup.ps1 — verify codex CLI is installed, authenticated, and the state dir is writable.
# Usage: & .\codex-setup.ps1

[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

Initialize-CodexEnvironment
$invocation = Resolve-CodexInvocation
$codex = if ($invocation) { $invocation.Exe } else { $null }

$psVersionOk = ($PSVersionTable.PSVersion.Major -ge 7)

$report = [ordered]@{
    codex_found      = [bool]$invocation
    codex_path       = $codex
    codex_mode       = if ($invocation) { $invocation.Mode } else { $null }
    codex_leading    = if ($invocation) { $invocation.LeadingArgs } else { @() }
    codex_version    = $null
    login_status     = 'unknown'
    login_detail     = $null
    ps_version       = $PSVersionTable.PSVersion.ToString()
    ps_edition       = $PSVersionTable.PSEdition
    ps_version_ok    = $psVersionOk
    supervision_home = (Get-CodexSupervisionHome)
    home_writable    = $false
    ready            = $false
    suggestions      = @()
}

if (-not $psVersionOk) {
    $report.suggestions += "PowerShell $($PSVersionTable.PSVersion) detected; this skill requires PowerShell 7+ (ProcessStartInfo.ArgumentList and Process.Kill(bool) are .NET Core 3+ features). Install via 'winget install Microsoft.PowerShell' and re-run scripts with pwsh."
}

if (-not $codex) {
    $report.suggestions += 'codex CLI not found. Install via: npm install -g @openai/codex'
    $report.suggestions += 'Or set $env:CODEX_PATH to the executable.'
    $report | ConvertTo-Json -Depth 4
    return
}

try {
    $ver = & $invocation.Exe @($invocation.LeadingArgs) --version 2>&1
    $report.codex_version = (($ver | Out-String) -replace '\s+', ' ').Trim()
} catch {
    $report.suggestions += "codex --version failed: $($_.Exception.Message)"
}

try {
    $loginOut  = & $invocation.Exe @($invocation.LeadingArgs) login status 2>&1
    $loginText = (($loginOut | Out-String) -replace '\s+', ' ').Trim()
    if ($LASTEXITCODE -eq 0 -and $loginText -notmatch '(?i)not (logged in|authenticated)') {
        $report.login_status = 'logged-in'
        $report.login_detail = $loginText
    } else {
        $report.login_status = 'not-logged-in'
        $report.login_detail = $loginText
        $report.suggestions += 'Run: codex login   (interactive; use a terminal)'
    }
} catch {
    $report.login_status = 'check-failed'
    $report.suggestions += "Could not check login: $($_.Exception.Message)"
}

try {
    $supHome = Get-CodexSupervisionHome
    New-Item -ItemType Directory -Path $supHome -Force | Out-Null
    $probe = Join-Path $supHome '.write-probe'
    [System.IO.File]::WriteAllText($probe, 'ok')
    Remove-Item $probe -Force
    $report.home_writable = $true
} catch {
    $report.suggestions += "Cannot write to $supHome — set CODEX_SUPERVISION_HOME to a writable dir. Error: $($_.Exception.Message)"
}

# `ready` reflects concrete state, NOT presence of any informational suggestion.
$report.ready = $report.codex_found `
    -and ($report.login_status -eq 'logged-in') `
    -and $report.home_writable `
    -and $psVersionOk

$report | ConvertTo-Json -Depth 4
