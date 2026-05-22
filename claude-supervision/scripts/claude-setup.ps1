# claude-setup.ps1 — verify Claude Code CLI is installed, authenticated, state dir writable.
# Usage: & .\claude-setup.ps1

[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

Initialize-ClaudeEnvironment
$claude = Resolve-ClaudePath
$psVersionOk = ($PSVersionTable.PSVersion.Major -ge 7)

$report = [ordered]@{
    claude_found     = [bool]$claude
    claude_path      = $claude
    claude_version   = $null
    auth_status      = 'unknown'
    auth_method      = $null
    auth_email       = $null
    auth_org         = $null
    subscription     = $null
    ps_version       = $PSVersionTable.PSVersion.ToString()
    ps_edition       = $PSVersionTable.PSEdition
    ps_version_ok    = $psVersionOk
    supervision_home = (Get-ClaudeSupervisionHome)
    home_writable    = $false
    ready            = $false
    suggestions      = @()
}

if (-not $claude) {
    $report.suggestions += 'claude CLI not found. Install via: npm install -g @anthropic-ai/claude-code'
    $report.suggestions += 'Or set $env:CLAUDE_CLI_PATH to the executable.'
    $report | ConvertTo-Json -Depth 4
    return
}

if (-not $psVersionOk) {
    $report.suggestions += "PowerShell $($PSVersionTable.PSVersion) detected; requires PS 7+ (ProcessStartInfo.ArgumentList + Process.Kill(bool) are .NET Core 3+). Install via 'winget install Microsoft.PowerShell' and re-run with pwsh."
}

try {
    $ver = & $claude --version 2>&1
    $report.claude_version = (($ver | Out-String) -replace '\s+', ' ').Trim()
} catch {
    $report.suggestions += "claude --version failed: $($_.Exception.Message)"
}

# Authoritative auth probe — Claude CLI exposes `claude auth status` (JSON output,
# exit 0 if logged in, 1 if not). NOTE: drop stderr to $null (don't merge via 2>&1)
# so a progress/warning line from claude CLI doesn't corrupt the JSON parse below.
try {
    $authJson = & $claude auth status 2>$null
    $authText = ($authJson | Out-String).Trim()
    $authObj = $null
    try { $authObj = $authText | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($LASTEXITCODE -eq 0 -and $authObj -and $authObj.loggedIn) {
        $report.auth_status = 'logged-in'
        $report.auth_method = Get-PropOrDefault $authObj 'authMethod' $null
        $report.auth_email  = Get-PropOrDefault $authObj 'email' $null
        $report.auth_org    = Get-PropOrDefault $authObj 'orgName' $null
        $report.subscription = Get-PropOrDefault $authObj 'subscriptionType' $null
    } else {
        $report.auth_status = 'not-logged-in'
        $report.suggestions += 'Run: claude auth login   (or set $env:ANTHROPIC_API_KEY).'
    }
    $global:LASTEXITCODE = 0
} catch {
    $report.auth_status = 'check-failed'
    $report.suggestions += "claude auth status failed: $($_.Exception.Message)"
}

try {
    $supHome = Get-ClaudeSupervisionHome
    New-Item -ItemType Directory -Path $supHome -Force | Out-Null
    $probe = Join-Path $supHome '.write-probe'
    [System.IO.File]::WriteAllText($probe, 'ok')
    Remove-Item $probe -Force
    $report.home_writable = $true
} catch {
    $report.suggestions += "Cannot write to $supHome — set CLAUDE_SUPERVISION_HOME to a writable dir. Error: $($_.Exception.Message)"
}

$report.ready = $report.claude_found `
    -and ($report.auth_status -eq 'logged-in') `
    -and $report.home_writable `
    -and $psVersionOk

$report | ConvertTo-Json -Depth 4
