# common.ps1 — shared helpers for codex-supervision wrappers
# Dot-source: . "$PSScriptRoot\common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 on the PowerShell pipeline so non-ASCII codex output isn't mojibake'd
# on Chinese-locale Windows hosts (kimi-supervision documented the same trap).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $script:OutputEncoding    = [System.Text.UTF8Encoding]::new($false)
} catch { }

function Get-CodexSupervisionHome {
    # Order: explicit override → LOCALAPPDATA default → USERPROFILE fallback → C:\ last resort
    if ($env:CODEX_SUPERVISION_HOME) { return $env:CODEX_SUPERVISION_HOME }
    if ($env:LOCALAPPDATA)           { return (Join-Path $env:LOCALAPPDATA 'codex-supervision') }
    if ($env:USERPROFILE)            { return (Join-Path $env:USERPROFILE '.codex-supervision') }
    return 'C:\codex-supervision'
}

function Initialize-CodexEnvironment {
    foreach ($var in 'SystemRoot', 'windir', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA') {
        if (-not (Get-Item -Path ("env:$var") -ErrorAction SilentlyContinue)) {
            $value = [System.Environment]::GetEnvironmentVariable($var)
            if ($value) { Set-Item -Path ("env:$var") -Value $value }
        }
    }
    if (-not $env:HOME -and $env:USERPROFILE) { $env:HOME = $env:USERPROFILE }
}

function Resolve-CodexPath {
    # Resolve to an actual executable (leaf file), not a directory, function, or alias.
    # Multiple PATH locations can shadow the same name; always pick the first.
    # Use ProviderPath so UNC / extended-length paths land as clean Windows paths.
    if ($env:CODEX_PATH -and (Test-Path -LiteralPath $env:CODEX_PATH -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:CODEX_PATH).ProviderPath
    }
    foreach ($name in 'codex.exe', 'codex.cmd', 'codex') {
        $cmd = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    if ($env:USERPROFILE) {
        $userBin = Join-Path $env:USERPROFILE 'bin\codex.cmd'
        if (Test-Path -LiteralPath $userBin -PathType Leaf) {
            return (Resolve-Path -LiteralPath $userBin).ProviderPath
        }
    }
    return $null
}

function Resolve-CodexInvocation {
    <#
    Return @{ Exe = '<exe path>'; LeadingArgs = @(...); Mode = 'node'|'cmd'|'exe' } or $null.

    PREFERRED: launch node.exe directly with codex.js. This bypasses two layers of .cmd
    wrapping (user-bin/codex.cmd -> npm/codex.cmd -> node + js). The npm-bin shim uses
    `endLocal & goto X 2>NUL || title %COMSPEC% & node ...` which has a documented
    race condition with redirected stdout on Windows — codex actually finishes its task
    (provably: ~/.codex/sessions/.../rollout-*.jsonl records `task_complete` with the
    answer), but the parent's stdout pipe is severed early and `ReadToEndAsync` returns
    empty. Spawning node directly inherits handles cleanly.
    #>
    $node = Get-Command -Name 'node.exe', 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node) {
        $candidates = @()
        if ($env:APPDATA)      { $candidates += (Join-Path $env:APPDATA      'npm\node_modules\@openai\codex\bin\codex.js') }
        if ($env:USERPROFILE)  { $candidates += (Join-Path $env:USERPROFILE  '.npm-global\node_modules\@openai\codex\bin\codex.js') }
        if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\node_modules\@openai\codex\bin\codex.js') }
        foreach ($js in $candidates) {
            if ($js -and (Test-Path -LiteralPath $js -PathType Leaf)) {
                return @{ Exe = $node.Source; LeadingArgs = @($js); Mode = 'node' }
            }
        }
    }

    # Fallback: .cmd or .exe wrapper. Subject to the Windows shim race condition above
    # for long-running jobs with redirected stdio. Use only when codex.js can't be located.
    $codex = Resolve-CodexPath
    if ($codex) {
        $mode = if ($codex -match '\.exe$') { 'exe' } else { 'cmd' }
        return @{ Exe = $codex; LeadingArgs = @(); Mode = $mode }
    }
    return $null
}

function Get-PropOrDefault {
    # Safe property access on PSObject under StrictMode.
    param($Obj, [string]$Name, $Default = '?')
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $Default
}

function Test-IsGitRepo {
    # True if $Path is inside a git working tree (handles subdirs and worktrees).
    # Resets $LASTEXITCODE on exit so a non-repo (git exits 128) doesn't poison
    # the script's final exit code.
    param([Parameter(Mandatory)][string]$Path)
    $git = Get-Command -Name 'git.exe', 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $false }
    $isRepo = $false
    try {
        $out = & $git.Source -C $Path rev-parse --is-inside-work-tree 2>$null
        $isRepo = ($LASTEXITCODE -eq 0 -and ($out | Out-String).Trim() -eq 'true')
    } catch { }
    $global:LASTEXITCODE = 0
    return $isRepo
}

function New-CodexSession {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Workspace
    )
    Initialize-CodexEnvironment
    # Millisecond + PID + random suffix avoids collision across concurrent runs AND
    # sequential calls in the same millisecond within one PowerShell process (where $PID is constant).
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $rand  = (Get-Random -Minimum 1000 -Maximum 9999)
    $id = "$stamp-$PID-$rand-$Mode"
    $root = Get-CodexSupervisionHome
    $dir = Join-Path $root "sessions\$id"
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    } catch {
        throw "host_error: cannot create session dir '$dir' — $($_.Exception.Message). Set CODEX_SUPERVISION_HOME to a writable path."
    }
    [pscustomobject]@{
        Id        = $id
        Dir       = $dir
        Workspace = (Resolve-Path -LiteralPath $Workspace).ProviderPath
        StartedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Write-SessionMeta {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][hashtable]$Meta
    )
    $path = Join-Path $Session.Dir 'session.json'
    $merged = @{
        session_id = $Session.Id
        workspace  = $Session.Workspace
        started_at = $Session.StartedAt
    }
    foreach ($k in $Meta.Keys) { $merged[$k] = $Meta[$k] }
    $json = ($merged | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-RedactedArgs {
    # Best-effort scrub of `-c key=value` pairs whose key name looks sensitive.
    param([Parameter(Mandatory)][string[]]$ArgList)
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $ArgList.Count) {
        $a = $ArgList[$i]
        if ($a -eq '-c' -and ($i + 1) -lt $ArgList.Count) {
            $kv = $ArgList[$i + 1]
            if ($kv -match '^(?i).*(key|token|secret|password).*=' ) {
                $k = ($kv -split '=', 2)[0]
                $out.Add('-c'); $out.Add("$k=<redacted>")
            } else {
                $out.Add('-c'); $out.Add($kv)
            }
            $i += 2
        } else {
            $out.Add($a); $i += 1
        }
    }
    return ,$out.ToArray()
}

function Invoke-CodexExec {
    <#
    Run codex non-interactively. Handles deadlock-safe async I/O, timeout, and artifact capture.

    Two execution modes:
      - 'plain':  `codex exec [--cd ...] [--sandbox ...] [--add-dir ...] ...`
      - 'review': `codex exec review [--base ...] [--uncommitted] [--title ...] ...`
                  (review subcommand does NOT accept --cd/--sandbox/--add-dir;
                  workspace is set via process.WorkingDirectory)
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Prompt,

        [Parameter(Mandatory)][ValidateSet('plain', 'review', 'resume')]
        [string]$ExecMode,

        # plain-mode only
        [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
        [string]$Sandbox = 'read-only',
        [string[]]$AddDirs,

        # review-mode only
        [string]$Base,
        [switch]$Uncommitted,
        [string]$Commit,
        [string]$Title,

        # resume-mode only — pass EITHER ResumeSessionId OR ResumeLast
        [string]$ResumeSessionId,
        [switch]$ResumeLast,

        # common
        [string]$Model,
        [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$Effort,
        [switch]$DangerouslyBypassSandbox,
        [switch]$Ephemeral,        # don't persist session rollout to ~/.codex/sessions
        [string]$OutputSchemaFile, # JSON Schema path (plain exec only)
        [string[]]$Images,         # image file paths (plain + resume only)

        # safety
        [int]$TimeoutSec = 900
    )

    Initialize-CodexEnvironment

    # Persist prompt FIRST so it survives any subsequent error path (codex-not-found,
    # process-start failure, etc.). SKILL.md promises the prompt is always written.
    $promptPath = Join-Path $Session.Dir 'last-prompt.txt'
    [System.IO.File]::WriteAllText($promptPath, $Prompt, [System.Text.UTF8Encoding]::new($false))

    $invocation = Resolve-CodexInvocation
    if (-not $invocation) {
        $meta = @{
            mode                  = $Mode
            exit_code             = -1
            result_classification = 'host_error'
            error                 = 'codex CLI not found. Install via "npm install -g @openai/codex" or set CODEX_PATH.'
        }
        Write-SessionMeta -Session $Session -Meta $meta
        throw $meta.error
    }
    $codex = $invocation.Exe

    $codexVersion = ((& $invocation.Exe @($invocation.LeadingArgs) --version 2>$null) | Out-String).Trim()

    # Each codex exec subcommand accepts a DIFFERENT flag subset. Adding a flag
    # the subcommand doesn't recognize (e.g. --sandbox on `exec resume`, --cd on
    # `exec review`, --output-schema on `exec review`) makes codex exit immediately
    # with "unexpected argument".
    #
    # Authoritative matrix from `codex exec [<sub>] --help` (0.128.0), verified
    # empirically. NOTE: `--search` is NOT on any `codex exec` subcommand — it
    # appears only on top-level `codex` (interactive TUI), so this wrapper cannot
    # enable web search through exec at all.
    #
    #   Flag                                       exec  exec review  exec resume
    #   --cd / --sandbox / --add-dir                Y     -            -
    #   --base / --uncommitted / --title / --commit -     Y            -
    #   --color / --output-schema                   Y     -            -
    #   -i / --image                                Y     -            Y
    #   -c / --enable / --disable                   Y     Y            Y
    #   --model / --ephemeral / --skip-git /        Y     Y            Y
    #     --dangerously-bypass-approvals-and-sandbox /
    #     --ignore-user-config / --ignore-rules /
    #     --json / -o (--output-last-message)
    #   --last / --all                              -     -            Y
    #
    # The build path below enforces this matrix strictly.

    $codexArgs = @('exec')
    switch ($ExecMode) {
        'review' {
            $codexArgs += 'review'
            # Scope precedence: --commit > --base > --uncommitted (codex's own rule).
            if ($Commit) {
                $codexArgs += @('--commit', $Commit)
            } elseif ($Base) {
                $codexArgs += @('--base', $Base)
            } elseif ($Uncommitted) {
                $codexArgs += '--uncommitted'
            }
            if ($Title) { $codexArgs += @('--title', $Title) }
        }
        'resume' {
            $codexArgs += 'resume'
            if ($ResumeLast) {
                $codexArgs += '--last'
            } elseif ($ResumeSessionId) {
                $codexArgs += $ResumeSessionId
            } else {
                throw 'ExecMode=resume requires either -ResumeLast or -ResumeSessionId.'
            }
        }
        'plain' {
            if (-not $DangerouslyBypassSandbox) {
                $codexArgs += @('--sandbox', $Sandbox)
            }
            $codexArgs += @('--cd', $Session.Workspace)
            if ($AddDirs) {
                foreach ($d in $AddDirs) {
                    if (-not $d) { continue }  # skip null/empty array entries
                    $codexArgs += @('--add-dir', $d)
                }
            }
            $codexArgs += @('--color', 'never')
        }
    }

    # Reject combinations that aren't supported by the chosen subcommand.
    if ($AddDirs -and $ExecMode -ne 'plain') {
        Write-Warning "-AddDirs ignored: only 'plain' (codex exec) accepts --add-dir."
    }
    if ($OutputSchemaFile -and $ExecMode -ne 'plain') {
        Write-Warning "-OutputSchema ignored: only 'plain' (codex exec) accepts --output-schema. (Verified against codex 0.128.0; review and resume reject it.)"
    }
    if ($Images -and $ExecMode -eq 'review') {
        Write-Warning "-Images ignored: codex exec review does not accept -i/--image."
    }
    if ($Images -and $ExecMode -eq 'resume' -and $Images.Count -gt 1) {
        Write-Warning "codex exec resume documents single -i/--image; passing $($Images.Count) may be accepted or rejected by codex. If it fails, attach only the first image or start a fresh session."
    }

    # Validate and attach images (supported by plain + resume).
    # Resolve relative paths against -Workspace, not caller's cwd — so callers can
    # do `-Workspace C:\repo -Images '.\shot.png'` without surprises.
    # Use .ProviderPath (not .Path) so UNC / extended-length paths land as clean
    # Windows paths codex.exe can open.
    $resolvedImages = $null
    if ($Images -and $ExecMode -ne 'review') {
        $resolvedImages = New-Object System.Collections.Generic.List[string]
        $workspaceRoot = (Resolve-Path -LiteralPath $Session.Workspace).ProviderPath
        foreach ($img in $Images) {
            if (-not $img) { continue }  # skip null/empty array entries
            $candidate = $img
            $wasRelative = -not [System.IO.Path]::IsPathRooted($img)
            if ($wasRelative) {
                $candidate = Join-Path $Session.Workspace $img
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw "Image not found: $candidate (resolved from '$img')"
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                throw "Image path is a directory, not a file: $candidate"
            }
            $abs = (Resolve-Path -LiteralPath $candidate).ProviderPath
            # Relative paths must stay under -Workspace (no `..\..\` escapes, no
            # sibling-prefix escapes like Workspace=C:\repo + ..\repo2\foo.png).
            # Use Path.GetRelativePath (.NET Core 2+/PS7) and reject any result
            # that starts with `..` or is rooted (different drive/UNC).
            # Absolute -Images paths bypass this check — they're explicit opt-in.
            if ($wasRelative) {
                $rel = [System.IO.Path]::GetRelativePath($workspaceRoot, $abs)
                if ($rel.StartsWith('..') -or [System.IO.Path]::IsPathRooted($rel)) {
                    throw "Image '$img' resolves to '$abs', which is outside -Workspace '$workspaceRoot' (relative path: '$rel'). Pass an absolute path if you really mean to attach this file."
                }
            }
            $codexArgs += @('-i', $abs)
            [void]$resolvedImages.Add($abs)
        }
    }

    # Flags accepted by ALL three subcommands.
    if ($Model)   { $codexArgs += @('--model', $Model) }
    if ($Effort)  { $codexArgs += @('-c', "model_reasoning_effort=`"$Effort`"") }
    if ($DangerouslyBypassSandbox) {
        $codexArgs += '--dangerously-bypass-approvals-and-sandbox'
    }
    if ($Ephemeral) { $codexArgs += '--ephemeral' }
    if (-not (Test-IsGitRepo -Path $Session.Workspace)) {
        $codexArgs += '--skip-git-repo-check'
    }

    # --output-schema is accepted ONLY by plain `codex exec` (verified against 0.128.0;
    # review and resume both reject it with "unexpected argument").
    # Resolve relative paths against -Workspace, and use .ProviderPath for UNC safety.
    $resolvedSchema = $null
    if ($OutputSchemaFile -and $ExecMode -eq 'plain') {
        $schemaCandidate = $OutputSchemaFile
        if (-not [System.IO.Path]::IsPathRooted($OutputSchemaFile)) {
            $schemaCandidate = Join-Path $Session.Workspace $OutputSchemaFile
        }
        if (-not (Test-Path -LiteralPath $schemaCandidate -PathType Leaf)) {
            throw "OutputSchemaFile not found or not a file: $schemaCandidate (resolved from '$OutputSchemaFile')"
        }
        $resolvedSchema = (Resolve-Path -LiteralPath $schemaCandidate).ProviderPath
        $codexArgs += @('--output-schema', $resolvedSchema)
    }

    # CRITICAL: write final answer to a FILE via -o instead of relying on stdout pipe.
    # codex.js → node → spawn(vendor/codex.exe, stdio:"inherit") on Windows intermittently
    # drops the stdio chain entirely — codex's own rollout JSONL records task_complete
    # with the answer, but the parent receives 0 bytes on both stdout and stderr.
    # Writing to a file bypasses the pipe race. All three subcommands accept -o.
    $answerPath = Join-Path $Session.Dir 'codex-answer.txt'
    $codexArgs += @('-o', $answerPath)

    $codexArgs += '-'  # read prompt from stdin

    $stdoutPath = Join-Path $Session.Dir 'last-response.txt'
    $stderrPath = Join-Path $Session.Dir 'stderr.log'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $invocation.Exe
    foreach ($a in $invocation.LeadingArgs) { [void]$psi.ArgumentList.Add($a) }
    foreach ($a in $codexArgs) { [void]$psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory       = $Session.Workspace
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute         = $false
    $psi.StandardOutputEncoding  = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding   = [System.Text.Encoding]::UTF8

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)

    # Drain stdin first so codex can start.
    $proc.StandardInput.Write($Prompt)
    $proc.StandardInput.Close()

    # CRITICAL: async reads on BOTH streams concurrently — sequential ReadToEnd deadlocks
    # if the unread stream's pipe buffer fills.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $timeoutMs = if ($TimeoutSec -le 0) { [int]::MaxValue } else { [int]([Math]::Min($TimeoutSec * 1000L, [int]::MaxValue)) }
    $exited = $proc.WaitForExit($timeoutMs)

    $timedOut = $false
    if (-not $exited) {
        $timedOut = $true
        # Process.Kill(bool) is .NET Core 3+. Fall back to no-arg Kill() if the bool
        # overload is missing — though in practice if Kill(bool) is unavailable,
        # ProcessStartInfo.ArgumentList earlier in this function would have already
        # failed. Kept defensively in case a future polyfill enables 5.1 support.
        try {
            $proc.Kill($true)
        } catch {
            try { $proc.Kill() } catch { }
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    } else {
        try { $proc.WaitForExit() } catch { }
    }

    # Give the async read tasks a brief window to drain after exit/kill — otherwise
    # buffered stdout/stderr is silently dropped.
    try {
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
    } catch { }
    $sw.Stop()

    # IsCompleted is true for success, faulted, AND canceled — wrap GetResult in
    # try/catch so a pipe IOException on hard Kill doesn't crash the wrapper.
    $stdoutPipe = try {
        if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
    } catch { '' }
    $stderr = try {
        if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' }
    } catch { '' }

    # Prefer the file written via -o; fall back to stdout pipe (which on Windows
    # can be intermittently empty even when codex completed).
    $stdoutFromFile = ''
    if (Test-Path -LiteralPath $answerPath) {
        try {
            $stdoutFromFile = [System.IO.File]::ReadAllText($answerPath, [System.Text.UTF8Encoding]::new($false))
        } catch { }
    }
    $stdout = if ($stdoutFromFile.Trim()) { $stdoutFromFile } else { $stdoutPipe }

    [System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($stderrPath, $stderr, [System.Text.UTF8Encoding]::new($false))

    # Classify result.
    $cls = 'usable'
    if ($timedOut) {
        $cls = 'timeout'
    } elseif ($proc.ExitCode -ne 0) {
        $cls = 'error'
        # Broaden auth detection to cover real codex error shapes.
        if ($stderr -match '(?i)(login|unauthorized|not authenticated|please run.*login|\b401\b|\b403\b|credentials.*(expired|invalid)|token.*(refresh|expired)|auth.*(failed|expired))') {
            $cls = 'auth_required'
        }
    } elseif (-not $stdout.Trim()) {
        $cls = 'empty'
    }

    # Sandbox label in session.json reflects what codex actually used, NOT what the
    # caller passed. Resume mode inherits from the original session — don't lie.
    $sandboxLabel = if ($ExecMode -eq 'resume') {
        'inherited'
    } elseif ($DangerouslyBypassSandbox) {
        'danger-full-access'
    } elseif ($ExecMode -eq 'review') {
        'review-builtin'
    } else {
        $Sandbox
    }

    $meta = @{
        mode                  = $Mode
        exec_mode             = $ExecMode
        codex_version         = $codexVersion
        codex_args            = (Get-RedactedArgs -ArgList $codexArgs)
        sandbox               = $sandboxLabel
        bypass_approvals      = [bool]$DangerouslyBypassSandbox
        model                 = $Model
        effort                = $Effort
        review_base           = $Base
        review_uncommitted    = [bool]$Uncommitted
        resume_session_id     = $ResumeSessionId
        resume_last           = [bool]$ResumeLast
        ephemeral             = [bool]$Ephemeral
        # Convenience fields reflect ACTUAL applied state (post per-mode filtering),
        # not what the caller requested — `codex_args` is the authoritative argv.
        output_schema_file    = $resolvedSchema
        image_count           = if ($resolvedImages) { $resolvedImages.Count } else { 0 }
        timeout_sec           = $TimeoutSec
        timed_out             = $timedOut
        exit_code             = $proc.ExitCode
        finished_at           = (Get-Date).ToUniversalTime().ToString('o')
        duration_ms           = $sw.ElapsedMilliseconds
        prompt_chars          = $Prompt.Length
        response_chars        = $stdout.Length
        result_classification = $cls
    }
    Write-SessionMeta -Session $Session -Meta $meta

    [pscustomobject]@{
        Session        = $Session
        Meta           = $meta
        Stdout         = $stdout
        Stderr         = $stderr
        ExitCode       = $proc.ExitCode
        Classification = $cls
        TimedOut       = $timedOut
    }
}

function Format-CodexHeader {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $lines = @(
        "# codex-supervision: $($Result.Meta.mode) ($($Result.Session.Id))"
        "workspace=$($Result.Session.Workspace)"
        "exit=$($Result.ExitCode)  classification=$($Result.Classification)  duration_ms=$($Result.Meta.duration_ms)  timed_out=$($Result.TimedOut)"
    )
    if ($Result.Meta.model)  { $lines += "model=$($Result.Meta.model)" }
    if ($Result.Meta.effort) { $lines += "effort=$($Result.Meta.effort)" }
    $lines += '---'
    return ($lines -join "`n")
}
