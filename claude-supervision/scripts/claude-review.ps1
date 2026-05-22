# claude-review.ps1 — non-interactive multi-agent code review via `claude ultrareview`.
#
# Wraps `claude ultrareview [target] [--json] [--timeout <minutes>]`. Returns the
# parsed findings to stdout. Does NOT use the `--print` path — `ultrareview` is its
# own dedicated subcommand that runs a cloud-hosted multi-agent review.
#
# Usage examples:
#   & .\claude-review.ps1 -Workspace .                                    # review current branch
#   & .\claude-review.ps1 -Workspace . -Target 1234                       # review PR #1234
#   & .\claude-review.ps1 -Workspace . -Target 'origin/main'              # review against base branch
#   & .\claude-review.ps1 -Workspace . -Json -TimeoutMin 45               # raw JSON payload, 45 min timeout

[CmdletBinding()]
param(
    [string]$Workspace = '.',
    [string]$Target,                       # PR number, PR URL, or base-branch ref
    [switch]$Json,                         # --json: raw bugs.json payload
    [ValidateRange(1, 10080)][int]$TimeoutMin = 30,           # --timeout <minutes>; cap 1 week
    [ValidateRange(1, 86400)][int]$ProcessTimeoutSec          # outer kill timeout (default TimeoutMin*60+60)
)

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path -LiteralPath $Workspace)) { throw "Workspace not found: $Workspace" }

Initialize-ClaudeEnvironment
$claude = Resolve-ClaudePath
if (-not $claude) {
    throw 'claude CLI not found. Run claude-setup.ps1 first.'
}

# Outer kill: ultrareview has its own --timeout; give the wrapper a bit more slack.
if (-not $ProcessTimeoutSec) {
    $ProcessTimeoutSec = [int](($TimeoutMin * 60) + 60)
}

$session = New-ClaudeSession -Mode 'ultrareview' -Workspace $Workspace

# Persist the "prompt" (which is just the invocation metadata for review).
# NOTE: `"x" + (if (...) {...})` is a parse error in PowerShell — `if` is a statement,
# not an expression in concatenation context. Use $(...) subexpressions instead.
$promptDesc = "claude ultrareview$(if ($Target) { " $Target" } else { '' })$(if ($Json) { ' --json' } else { '' }) --timeout $TimeoutMin"
[System.IO.File]::WriteAllText((Join-Path $session.Dir 'last-prompt.txt'), $promptDesc, [System.Text.UTF8Encoding]::new($false))

# Build argv.
$cliArgs = New-Object System.Collections.Generic.List[string]
[void]$cliArgs.Add('ultrareview')
if ($Target) { [void]$cliArgs.Add($Target) }
if ($Json)   { [void]$cliArgs.Add('--json') }
[void]$cliArgs.Add('--timeout'); [void]$cliArgs.Add([string]$TimeoutMin)

$claudeVersion = ((& $claude --version 2>$null) | Out-String).Trim()

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $claude
foreach ($a in $cliArgs) { [void]$psi.ArgumentList.Add($a) }
$psi.WorkingDirectory       = $session.Workspace
$psi.RedirectStandardInput  = $true       # not used, but redirect for consistency
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.Close()
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()

$timeoutMs = [int]([Math]::Min($ProcessTimeoutSec * 1000L, [int]::MaxValue))
$exited = $proc.WaitForExit($timeoutMs)
$timedOut = $false
if (-not $exited) {
    $timedOut = $true
    try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
    try { $proc.WaitForExit(5000) | Out-Null } catch { }
} else {
    try { $proc.WaitForExit() } catch { }
}
try { [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null } catch { }
$sw.Stop()

$stdout = try { if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' } } catch { '' }
$stderr = try { if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' } } catch { '' }
$safeExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }

[System.IO.File]::WriteAllText((Join-Path $session.Dir 'last-response.txt'), $stdout, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $session.Dir 'stderr.log'), $stderr, [System.Text.UTF8Encoding]::new($false))

# ultrareview prints findings to stdout on exit 0; exit 1 = failure (per docs).
# If --json was requested, validate it parses; an unparseable payload promotes
# classification to 'invalid_json' so callers don't silently consume garbage.
$jsonValid = $null
if ($Json -and $stdout.Trim()) {
    try { $stdout | ConvertFrom-Json -ErrorAction Stop | Out-Null; $jsonValid = $true } catch { $jsonValid = $false }
}

$cls = if ($timedOut)                              { 'timeout' }
       elseif ($safeExit -ne 0)                    { 'error' }
       elseif (-not $stdout.Trim())                { 'empty' }
       elseif ($Json -and $jsonValid -eq $false)   { 'invalid_json' }
       else                                        { 'usable' }

$meta = @{
    mode                  = 'ultrareview'
    target                = $Target
    json_mode             = [bool]$Json
    json_parsed_ok        = $jsonValid
    timeout_min           = $TimeoutMin
    process_timeout_sec   = $ProcessTimeoutSec
    claude_version        = $claudeVersion
    cli_args              = $cliArgs.ToArray()
    timed_out             = $timedOut
    exit_code             = $safeExit
    finished_at           = (Get-Date).ToUniversalTime().ToString('o')
    duration_ms           = $sw.ElapsedMilliseconds
    response_chars        = $stdout.Length
    result_classification = $cls
}
Write-SessionMeta -Session $session -Meta $meta

# ---- Output --------------------------------------------------------------
$lines = @(
    "# claude-supervision: ultrareview ($($session.Id))"
    "workspace=$($session.Workspace)"
    "target=$(if ($Target) { $Target } else { '(current branch)' })"
    "exit=$safeExit  classification=$cls  duration_ms=$($sw.ElapsedMilliseconds)  timed_out=$timedOut"
)
if ($Json) { $lines += 'mode=json (raw bugs.json payload)' }
$lines += '---'
Write-Output ($lines -join "`n")
Write-Output $stdout
if ($stderr.Trim()) {
    Write-Output ''
    Write-Output '--- stderr (truncated to 4KB) ---'
    if ($stderr.Length -gt 4096) {
        Write-Output ($stderr.Substring(0, 4096) + '... [truncated; see stderr.log]')
    } else {
        Write-Output $stderr
    }
}
