# claude-bg.ps1 — manage Claude Code background sessions (--bg / claude agents / logs / stop / etc).
#
# Claude Code has a built-in background-session supervisor: `claude --bg "<task>"` returns
# a session ID immediately and runs the task in a detached daemon. This script wraps the
# full lifecycle so you can dispatch work, poll for completion, fetch output, then clean up
# — analog to codex-plugin-cc's /codex:status / /codex:result / /codex:cancel.
#
# Operations (mutually exclusive — pass exactly one):
#   -Submit <message>  → claude --bg "<message>" [--workspace ... --agent ... --model ...]
#                         Prints the new session ID.
#   -List              → claude agents --json (filtered to --cwd if -Workspace given)
#   -Logs <id>         → claude logs <id>
#   -Attach <id>       → REJECTED — interactive only; not usable from a wrapper.
#                         (Use -Logs to read output instead.)
#   -Stop <id>         → claude stop <id>
#   -Respawn <id>      → claude respawn <id>
#   -Remove <id>       → claude rm <id>
#   -DaemonStatus      → claude daemon status
#
# Usage examples:
#   & .\claude-bg.ps1 -Submit 'Investigate the flaky test_login' -Workspace . -Agent code-reviewer
#   & .\claude-bg.ps1 -List -Workspace .
#   & .\claude-bg.ps1 -Logs 7c5dcf5d
#   & .\claude-bg.ps1 -Stop 7c5dcf5d
#   & .\claude-bg.ps1 -DaemonStatus

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Submit', Mandatory)][string]$Submit,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Logs',     Mandatory)][string]$Logs,
    [Parameter(ParameterSetName = 'Attach',   Mandatory)][string]$Attach,
    [Parameter(ParameterSetName = 'Stop',     Mandatory)][string]$Stop,
    [Parameter(ParameterSetName = 'Respawn',  Mandatory)][string]$Respawn,
    [Parameter(ParameterSetName = 'Remove',   Mandatory)][string]$Remove,
    [Parameter(ParameterSetName = 'DaemonStatus')][switch]$DaemonStatus,

    # Cross-operation safety:
    [int]$TimeoutSec = 60,                        # outer kill timeout for any claude subprocess
    # Submit-only options (forwarded to `claude --bg`).
    [string]$Workspace,                           # restricts -List to this cwd; sets cwd for -Submit
    [string]$Agent,                               # --agent <name>
    [string]$Model,                               # --model <name>
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,
    [ValidateSet('default', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'plan')]
    [string]$PermissionMode,
    [string]$Name,                                # display name
    [string[]]$AddDirs,
    [string[]]$PluginDirs,
    [string[]]$McpConfig,
    [string]$Settings
)

. "$PSScriptRoot\common.ps1"

Initialize-ClaudeEnvironment
$claude = Resolve-ClaudePath
if (-not $claude) { throw 'claude CLI not found. Run claude-setup.ps1 first.' }

function Invoke-Claude {
    # Short claude management call with bounded timeout. A hung daemon, broken
    # daemon socket, or network blip on `claude logs` must not deadlock the wrapper.
    param(
        [Parameter(Mandatory)][string[]]$ArgList,
        [string]$Cwd,
        [int]$InvokeTimeoutSec = 60
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    foreach ($a in $ArgList) { [void]$psi.ArgumentList.Add($a) }
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $timeoutMs = if ($InvokeTimeoutSec -le 0) { [int]::MaxValue } else { [int]([Math]::Min($InvokeTimeoutSec * 1000L, [int]::MaxValue)) }
    $exited = $proc.WaitForExit($timeoutMs)
    $timedOut = $false
    if (-not $exited) {
        $timedOut = $true
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    try { [System.Threading.Tasks.Task]::WaitAll(@($out, $err), 3000) | Out-Null } catch { }
    # Reading ExitCode before HasExited throws; guard.
    $safeExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
    # Pre-compute outputs into variables — PS doesn't accept try/catch as
    # an expression inside hashtable value slots, only in plain assignment RHS.
    $outText = ''
    $errText = ''
    try { if ($out.IsCompleted) { $outText = $out.GetAwaiter().GetResult() } } catch { }
    try { if ($err.IsCompleted) { $errText = $err.GetAwaiter().GetResult() } } catch { }
    return [pscustomobject]@{
        Stdout   = $outText
        Stderr   = $errText
        ExitCode = $safeExit
        TimedOut = $timedOut
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Submit' {
        if (-not $Submit.Trim()) { throw '-Submit requires a non-empty message.' }
        $cwd = if ($Workspace) { (Resolve-Path -LiteralPath $Workspace).ProviderPath } else { (Get-Location).Path }

        $argv = New-Object System.Collections.Generic.List[string]
        [void]$argv.Add('--bg')
        [void]$argv.Add($Submit)
        if ($Agent)          { [void]$argv.Add('--agent');           [void]$argv.Add($Agent) }
        if ($Model)          { [void]$argv.Add('--model');           [void]$argv.Add($Model) }
        if ($Effort)         { [void]$argv.Add('--effort');          [void]$argv.Add($Effort) }
        if ($PermissionMode) { [void]$argv.Add('--permission-mode'); [void]$argv.Add($PermissionMode) }
        if ($Name)           { [void]$argv.Add('--name');            [void]$argv.Add($Name) }
        if ($AddDirs)        { foreach ($d in $AddDirs)    { if ($d) { [void]$argv.Add('--add-dir');    [void]$argv.Add($d) } } }
        if ($PluginDirs)     { foreach ($p in $PluginDirs) { if ($p) { [void]$argv.Add('--plugin-dir'); [void]$argv.Add($p) } } }
        if ($McpConfig)      { foreach ($m in $McpConfig)  { if ($m) { [void]$argv.Add('--mcp-config'); [void]$argv.Add($m) } } }
        if ($Settings)       { [void]$argv.Add('--settings');        [void]$argv.Add($Settings) }

        $r = Invoke-Claude -ArgList $argv.ToArray() -Cwd $cwd -InvokeTimeoutSec $TimeoutSec
        Write-Output "# claude-bg: submit (cwd=$cwd)"
        Write-Output "exit=$($r.ExitCode)"
        Write-Output '---'
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) {
            Write-Output ''
            Write-Output '--- stderr ---'
            Write-Output $r.Stderr
        }
    }
    'List' {
        $argv = New-Object System.Collections.Generic.List[string]
        [void]$argv.Add('agents')
        [void]$argv.Add('--json')
        if ($Workspace) {
            [void]$argv.Add('--cwd')
            [void]$argv.Add((Resolve-Path -LiteralPath $Workspace).ProviderPath)
        }
        $r = Invoke-Claude -ArgList $argv.ToArray() -InvokeTimeoutSec $TimeoutSec
        if ($r.ExitCode -ne 0) {
            Write-Warning "claude agents --json failed (exit $($r.ExitCode)). stderr: $($r.Stderr)"
            Write-Output $r.Stdout
            return
        }
        try {
            $list = $r.Stdout | ConvertFrom-Json -ErrorAction Stop
            if (-not $list) {
                Write-Output 'No background sessions.'
                return
            }
            $list | ForEach-Object {
                [pscustomobject]@{
                    SessionId  = Get-PropOrDefault $_ 'sessionId'
                    Kind       = Get-PropOrDefault $_ 'kind'
                    Pid        = Get-PropOrDefault $_ 'pid'
                    Cwd        = Get-PropOrDefault $_ 'cwd'
                    StartedAt  = Get-PropOrDefault $_ 'startedAt'
                }
            } | Format-Table -AutoSize
        } catch {
            Write-Output $r.Stdout
        }
    }
    'Logs' {
        $r = Invoke-Claude -InvokeTimeoutSec $TimeoutSec -ArgList @('logs', $Logs)
        Write-Output "# claude-bg: logs $Logs (exit=$($r.ExitCode))"
        Write-Output '---'
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) {
            Write-Output ''
            Write-Output '--- stderr ---'
            Write-Output $r.Stderr
        }
    }
    'Attach' {
        # Hard-fail so automated callers don't treat the no-op as success.
        throw "claude attach is INTERACTIVE-ONLY and not usable from a headless wrapper. Use -Logs $Attach to read output instead, or run 'claude attach $Attach' directly in a terminal."
    }
    'Stop' {
        $r = Invoke-Claude -InvokeTimeoutSec $TimeoutSec -ArgList @('stop', $Stop)
        Write-Output "# claude-bg: stop $Stop (exit=$($r.ExitCode))"
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) { Write-Output $r.Stderr }
    }
    'Respawn' {
        $r = Invoke-Claude -InvokeTimeoutSec $TimeoutSec -ArgList @('respawn', $Respawn)
        Write-Output "# claude-bg: respawn $Respawn (exit=$($r.ExitCode))"
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) { Write-Output $r.Stderr }
    }
    'Remove' {
        $r = Invoke-Claude -InvokeTimeoutSec $TimeoutSec -ArgList @('rm', $Remove)
        Write-Output "# claude-bg: rm $Remove (exit=$($r.ExitCode))"
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) { Write-Output $r.Stderr }
    }
    'DaemonStatus' {
        $r = Invoke-Claude -InvokeTimeoutSec $TimeoutSec -ArgList @('daemon', 'status')
        Write-Output "# claude-bg: daemon status (exit=$($r.ExitCode))"
        Write-Output '---'
        Write-Output $r.Stdout
        if ($r.Stderr.Trim()) {
            Write-Output ''
            Write-Output '--- stderr ---'
            Write-Output $r.Stderr
        }
    }
}
