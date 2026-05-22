param(
    [switch]$SkipRealKimi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

function New-TestFailure {
    param(
        [string]$Message
    )

    throw $Message
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        New-TestFailure -Message $Message
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        New-TestFailure -Message "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

function New-TestNativeSession {
    param(
        [string[]]$ContextLines,
        [string[]]$WireLines = @()
    )

    $sessionId = [guid]::NewGuid().ToString()
    $parentDir = Join-Path (Get-KimiSessionsRoot) "__regression__"
    $sessionDir = Join-Path $parentDir $sessionId
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

    if ($ContextLines.Count -gt 0) {
        Set-Content -Path (Join-Path $sessionDir "context.jsonl") -Value $ContextLines
    }

    if ($WireLines.Count -gt 0) {
        Set-Content -Path (Join-Path $sessionDir "wire.jsonl") -Value $WireLines
    }

    return [pscustomobject]@{
        SessionId = $sessionId
        SessionDir = $sessionDir
    }
}

function Remove-TestNativeSession {
    param(
        [string]$SessionDir
    )

    if (-not [string]::IsNullOrWhiteSpace($SessionDir) -and (Test-Path $SessionDir)) {
        Remove-Item -LiteralPath $SessionDir -Recurse -Force
    }
}

function Get-TestStateRoot {
    param(
        [string]$Name
    )

    return (Join-Path $env:TEMP ("kimi-supervision-regression-{0}-{1}" -f $Name, ([guid]::NewGuid().ToString("N"))))
}

function Get-SessionMetaPath {
    param(
        [string]$StateRoot,
        [string]$SessionName
    )

    return (Join-Path $StateRoot ("sessions\{0}\session.json" -f $SessionName.ToLowerInvariant()))
}

function Get-SessionTextPath {
    param(
        [string]$StateRoot,
        [string]$SessionName
    )

    return (Join-Path $StateRoot ("sessions\{0}\last-response.txt" -f $SessionName.ToLowerInvariant()))
}

function Invoke-WithStateRoot {
    param(
        [string]$StateRoot,
        [scriptblock]$Body
    )

    $savedStateRoot = $env:KIMI_SUPERVISION_HOME
    try {
        $env:KIMI_SUPERVISION_HOME = $StateRoot
        & $Body
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($savedStateRoot)) {
            Remove-Item Env:KIMI_SUPERVISION_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:KIMI_SUPERVISION_HOME = $savedStateRoot
        }
    }
}

function Get-TaskValueFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lines = $Text -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -match '^TASK:\s*(.+)$') {
            return $matches[1].Trim()
        }
    }

    return $null
}

Initialize-KimiEnvironment

$results = New-Object System.Collections.Generic.List[object]
$testWorkspace = Join-Path $env:TEMP "Kimi Supervision Regression Workspace"
New-Item -ItemType Directory -Path $testWorkspace -Force | Out-Null
Set-Content -Path (Join-Path $testWorkspace "README.txt") -Value "Regression workspace for kimi-supervision tests."

function Run-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    $startedAt = Get-Date
    try {
        & $Body
        $results.Add([pscustomobject]@{
            Name = $Name
            Status = "PASS"
            Detail = ""
            DurationSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            Name = $Name
            Status = "FAIL"
            Detail = $_.Exception.Message
            DurationSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
        })
    }
}

Run-Test -Name "single-line think-only stays intermediate" -Body {
    $fixture = New-TestNativeSession -ContextLines @('{"role":"assistant","content":[{"type":"think","think":"Let me read files first."}]}') -WireLines @("wire")
    try {
        $result = Wait-KimiLatestAssistantText -SessionId $fixture.SessionId -AfterLineCount 0 -TimeoutMs 250 -PollMs 50 -StablePollCount 1 -ReadWireFallback
        Assert-Equal -Actual $result.Status -Expected "no_text_but_native_activity" -Message "Think-only reply should stay intermediate."
        Assert-True -Condition ($null -eq $result.Text) -Message "Think-only reply should not expose recovered final text."
    }
    finally {
        Remove-TestNativeSession -SessionDir $fixture.SessionDir
    }
}

Run-Test -Name "multi-line think-only stays intermediate" -Body {
    $content = @([pscustomobject]@{ type = "think"; think = "First line`nSecond line" })
    $text = Convert-KimiContentValueToText -Content $content
    Assert-True -Condition (-not (Test-KimiHasFinalText -Text $text)) -Message "Multi-line think-only text must not count as final text."
}

Run-Test -Name "tool-call-only stays intermediate" -Body {
    $fixture = New-TestNativeSession -ContextLines @('{"role":"assistant","content":[{"type":"toolCall","name":"ReadFile"}]}') -WireLines @("wire")
    try {
        $result = Wait-KimiLatestAssistantText -SessionId $fixture.SessionId -AfterLineCount 0 -TimeoutMs 250 -PollMs 50 -StablePollCount 1 -ReadWireFallback
        Assert-Equal -Actual $result.Status -Expected "no_text_but_native_activity" -Message "Tool-call-only reply should stay intermediate."
        Assert-True -Condition ($null -eq $result.Text) -Message "Tool-call-only reply should not expose recovered final text."
    }
    finally {
        Remove-TestNativeSession -SessionDir $fixture.SessionDir
    }
}

Run-Test -Name "timeout does not reuse stale assistant text" -Body {
    $oldText = "TASK: Old answer`nPLAN: old`nEVIDENCE: old`nCHANGES: NO_CHANGES`nVERIFICATION: NOT_RUN (old)`nREMAINING_RISKS: old"
    $contextLine = ([pscustomobject]@{
        role = "assistant"
        content = @(
            [pscustomobject]@{
                type = "text"
                text = $oldText
            }
        )
    } | ConvertTo-Json -Compress -Depth 5)
    $fixture = New-TestNativeSession -ContextLines @($contextLine)
    try {
        $result = Wait-KimiLatestAssistantText -SessionId $fixture.SessionId -AfterLineCount 1 -PreviousAssistantText $oldText -TimeoutMs 250 -PollMs 50 -StablePollCount 1
        Assert-Equal -Actual $result.Status -Expected "timed_out" -Message "Timeout path must not reuse a stale assistant message."
        Assert-True -Condition ($null -eq $result.Text) -Message "Timeout path should not return stale assistant text."
    }
    finally {
        Remove-TestNativeSession -SessionDir $fixture.SessionDir
    }
}

Run-Test -Name "mixed think and final text completes" -Body {
    $fixture = New-TestNativeSession -ContextLines @('{"role":"assistant","content":[{"type":"think","think":"Let me read files first.`nStill thinking"},{"type":"text","text":"TASK: Review files`nPLAN: Inspect repo`nEVIDENCE: saw file x`nCHANGES: NO_CHANGES`nVERIFICATION: NOT_RUN (read-only)`nREMAINING_RISKS: Need human review"}]}') -WireLines @("wire")
    try {
        $result = Wait-KimiLatestAssistantText -SessionId $fixture.SessionId -AfterLineCount 0 -TimeoutMs 250 -PollMs 50 -StablePollCount 1 -ReadWireFallback
        Assert-Equal -Actual $result.Status -Expected "completed" -Message "Mixed think+final reply should complete."
        Assert-True -Condition ($result.Text -match '(?m)^TASK:') -Message "Recovered text should contain the final structured answer."
    }
    finally {
        Remove-TestNativeSession -SessionDir $fixture.SessionDir
    }
}

Run-Test -Name "environment self-heals missing vars" -Body {
    $saved = @{
        SystemRoot = $env:SystemRoot
        windir = $env:windir
        USERPROFILE = $env:USERPROFILE
        HOME = $env:HOME
        LOCALAPPDATA = $env:LOCALAPPDATA
        APPDATA = $env:APPDATA
        ComSpec = $env:ComSpec
    }

    try {
        $env:SystemRoot = ""
        $env:windir = ""
        $env:USERPROFILE = ""
        $env:HOME = ""
        $env:LOCALAPPDATA = ""
        $env:APPDATA = ""
        $env:ComSpec = ""
        Initialize-KimiEnvironment
        foreach ($name in @("SystemRoot", "windir", "USERPROFILE", "HOME", "LOCALAPPDATA", "APPDATA", "ComSpec")) {
            $value = [Environment]::GetEnvironmentVariable($name, "Process")
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($value)) -Message "$name should be restored by Initialize-KimiEnvironment."
        }
    }
    finally {
        foreach ($entry in $saved.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
            if ($null -eq $entry.Value) {
                Remove-Item ("Env:{0}" -f $entry.Key) -ErrorAction SilentlyContinue
            }
            else {
                Set-Item ("Env:{0}" -f $entry.Key) -Value $entry.Value
            }
        }
    }
}

Run-Test -Name "custom state root is honored" -Body {
    $customRoot = Get-TestStateRoot -Name "state-root"
    $savedStateRoot = $env:KIMI_SUPERVISION_HOME
    try {
        $env:KIMI_SUPERVISION_HOME = $customRoot
        $paths = Get-SessionPaths -SessionName "regression-custom-root"
        Assert-True -Condition ($paths.Root.StartsWith($customRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message "Session root should live under custom state root."
        Assert-True -Condition (Test-Path $paths.Root) -Message "Session directory should be created under custom state root."
    }
    finally {
        if (Test-Path $customRoot) {
            Remove-Item -LiteralPath $customRoot -Recurse -Force
        }
        if ([string]::IsNullOrWhiteSpace($savedStateRoot)) {
            Remove-Item Env:KIMI_SUPERVISION_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:KIMI_SUPERVISION_HOME = $savedStateRoot
        }
    }
}

if (-not $SkipRealKimi) {
    $kimi = Resolve-KimiCommand
    Assert-KimiHealthy -KimiCommand $kimi

    Run-Test -Name "real run-once succeeds in workspace with spaces" -Body {
        $stateRoot = Get-TestStateRoot -Name "real-run-once"
        $scriptPath = Join-Path $PSScriptRoot "kimi-run-once.ps1"
        try {
            $null = Invoke-WithStateRoot -StateRoot $stateRoot -Body {
                & $scriptPath -Workspace $testWorkspace -Message "This is a read-only smoke test for the supervision wrapper. Reply using exactly these sections: TASK, PLAN, EVIDENCE, CHANGES, VERIFICATION, REMAINING_RISKS. Put RUN_ONCE_OK in TASK. Use CHANGES: NO_CHANGES. Use VERIFICATION: NOT_RUN (read-only smoke test)."
            }
            $meta = Get-Content -Raw (Get-SessionMetaPath -StateRoot $stateRoot -SessionName "run-once-latest") | ConvertFrom-Json
            $text = Get-Content -Raw (Get-SessionTextPath -StateRoot $stateRoot -SessionName "run-once-latest")
            Assert-Equal -Actual $meta.result_classification -Expected "usable" -Message "Run-once metadata should be usable."
            Assert-Equal -Actual $meta.task_risk_level -Expected "read_only" -Message "Run-once metadata should classify the test as read-only."
            Assert-True -Condition ($text -match 'TASK:\s*RUN_ONCE_OK') -Message "Run-once reply should preserve the requested TASK token."
        }
        finally {
            if (Test-Path $stateRoot) {
                Remove-Item -LiteralPath $stateRoot -Recurse -Force
            }
        }
    }

    Run-Test -Name "real chat continuation remembers prior final answer" -Body {
        $stateRoot = Get-TestStateRoot -Name "real-chat"
        $scriptPath = Join-Path $PSScriptRoot "kimi-chat.ps1"
        $sessionName = ("regression-chat-{0}" -f ([guid]::NewGuid().ToString("N").Substring(0, 8)))
        $marker = "MARKER-" + ([guid]::NewGuid().ToString("N").Substring(0, 8)).ToUpperInvariant()
        try {
            $null = Invoke-WithStateRoot -StateRoot $stateRoot -Body {
                & $scriptPath -Session $sessionName -Workspace $testWorkspace -Message "This is a read-only continuation test. Reply using exactly these sections: TASK, PLAN, EVIDENCE, CHANGES, VERIFICATION, REMAINING_RISKS. Put $marker in TASK and nowhere else. Use CHANGES: NO_CHANGES. Use VERIFICATION: NOT_RUN (continuation test)."
            }

            $reply2 = Invoke-WithStateRoot -StateRoot $stateRoot -Body {
                & $scriptPath -Session $sessionName -Workspace $testWorkspace -Message "Using the same session, report the previous final TASK marker from your last answer. Reply using exactly these sections: TASK, PLAN, EVIDENCE, CHANGES, VERIFICATION, REMAINING_RISKS. Put only the previous marker in TASK. Use CHANGES: NO_CHANGES. Use VERIFICATION: NOT_RUN (continuation test)."
            }

            $meta = Get-Content -Raw (Get-SessionMetaPath -StateRoot $stateRoot -SessionName $sessionName) | ConvertFrom-Json
            $taskValue = Get-TaskValueFromText -Text ([string]$reply2)
            Assert-Equal -Actual $meta.result_classification -Expected "usable" -Message "Continuation metadata should be usable."
            Assert-Equal -Actual $taskValue -Expected $marker -Message "Second turn should recover the first-turn TASK marker."
        }
        finally {
            if (Test-Path $stateRoot) {
                Remove-Item -LiteralPath $stateRoot -Recurse -Force
            }
        }
    }

    Run-Test -Name "real transcript fallback remains usable" -Body {
        $stateRoot = Get-TestStateRoot -Name "real-transcript"
        $scriptPath = Join-Path $PSScriptRoot "kimi-chat.ps1"
        $sessionName = ("regression-transcript-{0}" -f ([guid]::NewGuid().ToString("N").Substring(0, 8)))
        $marker = "TRANSCRIPT-" + ([guid]::NewGuid().ToString("N").Substring(0, 8)).ToUpperInvariant()
        try {
            $null = Invoke-WithStateRoot -StateRoot $stateRoot -Body {
                & $scriptPath -Session $sessionName -Workspace $testWorkspace -Message "This is a transcript fallback setup turn. Reply using exactly these sections: TASK, PLAN, EVIDENCE, CHANGES, VERIFICATION, REMAINING_RISKS. Put $marker in TASK and nowhere else. Use CHANGES: NO_CHANGES. Use VERIFICATION: NOT_RUN (transcript setup)."
            }

            $reply2 = Invoke-WithStateRoot -StateRoot $stateRoot -Body {
                & $scriptPath -Session $sessionName -Workspace $testWorkspace -ForceTranscript -Message "Read the saved transcript and report the previous TASK marker from the transcript. Reply using exactly these sections: TASK, PLAN, EVIDENCE, CHANGES, VERIFICATION, REMAINING_RISKS. Put only the previous marker in TASK. Use CHANGES: NO_CHANGES. Use VERIFICATION: NOT_RUN (transcript fallback review)."
            }

            $meta = Get-Content -Raw (Get-SessionMetaPath -StateRoot $stateRoot -SessionName $sessionName) | ConvertFrom-Json
            $taskValue = Get-TaskValueFromText -Text ([string]$reply2)
            Assert-Equal -Actual $meta.mode -Expected "transcript" -Message "Transcript fallback should record transcript mode."
            Assert-Equal -Actual $meta.result_classification -Expected "usable" -Message "Transcript fallback metadata should be usable."
            Assert-Equal -Actual $taskValue -Expected $marker -Message "Transcript fallback should recover the previous TASK marker."
        }
        finally {
            if (Test-Path $stateRoot) {
                Remove-Item -LiteralPath $stateRoot -Recurse -Force
            }
        }
    }
}

$failed = @($results | Where-Object { $_.Status -eq "FAIL" })
$results | Sort-Object Name | Format-Table -AutoSize

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED TEST DETAILS:"
    foreach ($failure in $failed) {
        Write-Host ("- {0}: {1}" -f $failure.Name, $failure.Detail)
    }
    exit 1
}

Write-Host ""
Write-Host ("PASS: {0} tests" -f $results.Count)
