Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-KimiSupervisionSkillRoot {
    return Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

function Get-KimiSupervisionStateRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:KIMI_SUPERVISION_HOME)) {
        return $env:KIMI_SUPERVISION_HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "kimi-supervision")
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE ".kimi-supervision")
    }

    return "C:\kimi-supervision"
}

function Get-KimiSupervisionPaths {
    $skillRoot = Get-KimiSupervisionSkillRoot
    $stateRoot = Get-KimiSupervisionStateRoot
    return [pscustomobject]@{
        SkillRoot = $skillRoot
        Scripts   = Join-Path $skillRoot "scripts"
        Agents    = Join-Path $skillRoot "agents"
        StateRoot = $stateRoot
        Sessions  = Join-Path $stateRoot "sessions"
        Logs      = Join-Path $stateRoot "logs"
    }
}

function Ensure-KimiSupervisionLayout {
    $paths = Get-KimiSupervisionPaths
    foreach ($path in @($paths.StateRoot, $paths.Sessions, $paths.Logs)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    return $paths
}

function Initialize-KimiEnvironment {
    $resolvedSystemRoot = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot) -and $env:SystemRoot -notmatch "%" -and (Test-Path $env:SystemRoot)) {
        $env:SystemRoot
    }
    else {
        "C:\Windows"
    }
    [Environment]::SetEnvironmentVariable("SystemRoot", $resolvedSystemRoot, "Process")

    $resolvedWinDir = if (-not [string]::IsNullOrWhiteSpace($env:windir) -and $env:windir -notmatch "%" -and (Test-Path $env:windir)) {
        $env:windir
    }
    else {
        $resolvedSystemRoot
    }
    [Environment]::SetEnvironmentVariable("windir", $resolvedWinDir, "Process")

    $resolvedUserProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and $env:USERPROFILE -notmatch "%" -and (Test-Path $env:USERPROFILE)) {
        $env:USERPROFILE
    }
    else {
        [Environment]::GetFolderPath("UserProfile")
    }
    [Environment]::SetEnvironmentVariable("USERPROFILE", $resolvedUserProfile, "Process")

    if ([string]::IsNullOrWhiteSpace($env:HOME) -or $env:HOME -match "%" -or -not (Test-Path $env:HOME)) {
        [Environment]::SetEnvironmentVariable("HOME", $resolvedUserProfile, "Process")
    }

    $resolvedLocalAppData = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and $env:LOCALAPPDATA -notmatch "%" -and (Test-Path $env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    }
    else {
        Join-Path $resolvedUserProfile "AppData\Local"
    }
    [Environment]::SetEnvironmentVariable("LOCALAPPDATA", $resolvedLocalAppData, "Process")

    $resolvedAppData = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA) -and $env:APPDATA -notmatch "%" -and (Test-Path $env:APPDATA)) {
        $env:APPDATA
    }
    else {
        Join-Path $resolvedUserProfile "AppData\Roaming"
    }
    [Environment]::SetEnvironmentVariable("APPDATA", $resolvedAppData, "Process")

    $expectedComSpec = Join-Path $resolvedSystemRoot "System32\cmd.exe"
    if ([string]::IsNullOrWhiteSpace($env:ComSpec) -or $env:ComSpec -match "%" -or -not (Test-Path $env:ComSpec)) {
        [Environment]::SetEnvironmentVariable("ComSpec", $expectedComSpec, "Process")
    }

    # Fix: Force UTF-8 on Chinese Windows to prevent GBK codec crashes in kimi.exe
    # kimi.exe is a PyInstaller bundle; PYTHONUTF8 env var alone is not always honoured.
    # The reliable fix is to switch the Windows console code page to 65001 (UTF-8),
    # which affects the embedded Python's stdout encoding detection directly.
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "Process")
    [Environment]::SetEnvironmentVariable("PYTHONIOENCODING", "utf-8", "Process")
    try {
        cmd /c "chcp 65001 > nul 2>&1"
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    }
    catch { }
}

function Get-KimiInstallHelp {
    return @"
Kimi CLI was not found or is not healthy.

Install:
- Windows PowerShell: Invoke-RestMethod https://code.kimi.com/install.ps1 | Invoke-Expression
- Or if uv is already installed: uv tool install --python 3.13 kimi-cli

Verify:
- kimi --version
- kimi info --json

If Kimi exists but still fails:
- Ensure SystemRoot and HOME are defined
- Reinstall or upgrade: uv tool upgrade kimi-cli --no-cache
- If you use a custom path, set KIMI_CLI_PATH to the executable
"@
}

function Resolve-KimiCommand {
    $candidates = @()
    $homeDir = Get-KimiHome

    foreach ($name in @("KIMI_CLI_PATH", "KIMI_EXECUTABLE_PATH")) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            $candidates += [Environment]::GetEnvironmentVariable($name)
        }
    }

    try {
        $cmdExe = Get-Command kimi.exe -ErrorAction Stop
        $candidates += $cmdExe.Source
    }
    catch {
    }

    foreach ($knownPath in @(
        (Join-Path $homeDir ".local\share\kimi-cli\kimi.exe"),
        (Join-Path $homeDir ".local\bin\kimi.exe"),
        (Join-Path $homeDir ".local\bin\kimi.cmd")
    )) {
        $candidates += $knownPath
    }

    try {
        $cmd = Get-Command kimi -ErrorAction Stop
        $candidates += $cmd.Source
    }
    catch {
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    throw (Get-KimiInstallHelp)
}

function Assert-KimiHealthy {
    param(
        [string]$KimiCommand
    )

    $null = & $KimiCommand info --json 2>&1
    $exitCode = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0) {
        throw (Get-KimiInstallHelp)
    }
}

function Normalize-Workspace {
    param(
        [string]$Workspace
    )

    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        return (Get-Location).Path
    }

    if (Test-Path $Workspace) {
        return (Resolve-Path $Workspace).Path
    }

    return $Workspace
}

function Get-SafeSessionName {
    param(
        [string]$Name
    )

    $safe = $Name.ToLowerInvariant()
    $safe = [regex]::Replace($safe, "[^a-z0-9\-]+", "-")
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw "Session name resolved to empty value."
    }
    return $safe
}

function Get-SessionPaths {
    param(
        [string]$SessionName
    )

    $paths = Ensure-KimiSupervisionLayout
    $safe = Get-SafeSessionName -Name $SessionName
    $sessionRoot = Join-Path $paths.Sessions $safe
    if (-not (Test-Path $sessionRoot)) {
        New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
    }

    return [pscustomobject]@{
        Name          = $safe
        Root          = $sessionRoot
        Transcript    = Join-Path $sessionRoot "transcript.jsonl"
        LastPrompt    = Join-Path $sessionRoot "last-prompt.txt"
        LastRawJson   = Join-Path $sessionRoot "last-response.jsonl"
        LastText      = Join-Path $sessionRoot "last-response.txt"
        Meta          = Join-Path $sessionRoot "session.json"
    }
}

function Read-JsonLines {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    $items = @()
    foreach ($line in Get-Content $Path) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $items += ($line | ConvertFrom-Json)
        }
    }
    return $items
}

function Append-JsonLine {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Compress -Depth 20
    Add-Content -Path $Path -Value $json
}

function Save-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    Set-Content -Path $Path -Value $Content -NoNewline
}

function Get-KimiContractDefinition {
    $requiredSections = @(
        "TASK"
        "PLAN"
        "EVIDENCE"
        "CHANGES"
        "VERIFICATION"
        "REMAINING_RISKS"
    )

    return [pscustomobject]@{
        Version                  = "2026-04-04"
        RequiredSections         = $requiredSections
        ReadOnlyNoChangesValue   = "NO_CHANGES"
        VerificationNotRunValue  = "NOT_RUN"
    }
}

function New-KimiDefaultSessionMeta {
    $definition = Get-KimiContractDefinition
    return [ordered]@{
        mode                    = "native"
        kimi_session_id         = $null
        workspace               = $null
        last_native_error       = $null
        native_context_path     = $null
        native_wire_path        = $null
        recovery_status         = "not_needed"
        last_context_line_count = 0
        last_wire_line_count    = 0
        last_recovered_at       = $null
        updated_at              = $null
        contract_version        = $definition.Version
        required_sections       = @($definition.RequiredSections)
        detected_sections       = @()
        missing_sections        = @()
        result_classification   = $null
        gate_passed             = $false
        validation_warnings     = @()
        handoff_reason          = $null
        output_source           = $null
        verification_confidence = $null
        task_risk_level         = $null
        completion_claimed      = $false
    }
}

function Merge-KimiMetaValues {
    param(
        [object]$Base,
        [object]$Overlay
    )

    $merged = [ordered]@{}

    if ($null -ne $Base) {
        foreach ($prop in $Base.PSObject.Properties) {
            $merged[$prop.Name] = $prop.Value
        }
    }

    if ($null -ne $Overlay) {
        foreach ($prop in $Overlay.PSObject.Properties) {
            $merged[$prop.Name] = $prop.Value
        }
    }

    return [pscustomobject]$merged
}

function Read-SessionMeta {
    param(
        [string]$Path
    )

    $defaults = [pscustomobject](New-KimiDefaultSessionMeta)
    if (-not (Test-Path $Path)) {
        return $defaults
    }

    $existing = Get-Content $Path | ConvertFrom-Json
    return (Merge-KimiMetaValues -Base $defaults -Overlay $existing)
}

function Write-SessionMeta {
    param(
        [string]$Path,
        [object]$Meta
    )

    $defaults = [pscustomobject](New-KimiDefaultSessionMeta)
    $merged = Merge-KimiMetaValues -Base $defaults -Overlay $Meta
    $merged | ConvertTo-Json -Depth 20 | Set-Content -Path $Path
}

function Get-KimiTaskRiskLevel {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return "normal_write"
    }

    $normalized = $Message.ToLowerInvariant()
    $readOnlySignals = @(
        "do not modify",
        "don't modify",
        "do not change",
        "don't change",
        "read only",
        "read-only",
        "inspect only",
        "summarize",
        "summary only",
        "report only",
        "analyze only",
        "review only",
        "no changes"
    )
    $writeSignalPatterns = @(
        '\bmodif(?:y|ies|ied|ying)\b',
        '\bchange(?:d|ing)?\b',
        '\bedit(?:s|ed|ing)?\b',
        '\bpatch(?:es|ed|ing)?\b',
        '\bfix(?:es|ed|ing)?\b',
        '\bupdate(?:s|d|ing)?\b',
        '\bcreate(?:s|d|ing)?\b',
        '\bwrite(?:s|n|ing)?\b',
        '\bdelete(?:s|d|ing)?\b',
        '\bremove(?:s|d|ing)?\b',
        '\bmove(?:s|d|ing)?\b',
        '\brename(?:s|d|ing)?\b',
        '\binstall(?:s|ed|ing)?\b',
        '\brepair(?:s|ed|ing)?\b',
        '\brefactor(?:s|ed|ing)?\b'
    )
    $highRiskSignals = @(
        "token",
        "api key",
        "auth",
        "authentication",
        "credential",
        "password",
        "secret",
        ".claude",
        "config",
        "profile",
        "registry",
        "path",
        "environment variable",
        "env var",
        "billing",
        "payment",
        "security",
        "production",
        "database",
        "migration",
        "git reset",
        "force push",
        "history rewrite"
    )

    $hasReadOnlySignal = $false
    foreach ($signal in $readOnlySignals) {
        if ($normalized.Contains($signal)) {
            $hasReadOnlySignal = $true
            break
        }
    }

    $writeScanText = $normalized
    foreach ($signal in $readOnlySignals) {
        $escapedSignal = [regex]::Escape($signal)
        $writeScanText = [regex]::Replace($writeScanText, $escapedSignal, " ")
    }

    $hasWriteSignal = $false
    foreach ($pattern in $writeSignalPatterns) {
        if ($writeScanText -match $pattern) {
            $hasWriteSignal = $true
            break
        }
    }

    $hasHighRiskSignal = $false
    foreach ($signal in $highRiskSignals) {
        if ($normalized.Contains($signal)) {
            $hasHighRiskSignal = $true
            break
        }
    }

    if ($hasReadOnlySignal -and -not $hasWriteSignal) {
        return "read_only"
    }

    if ($hasHighRiskSignal) {
        return "high_risk"
    }

    if ($hasWriteSignal) {
        return "normal_write"
    }

    return "read_only"
}

function New-KimiContractPrompt {
    param(
        [string]$UserMessage,
        [string]$Workspace,
        [string]$TaskRiskLevel = "normal_write",
        [string]$Mode = "native",
        [string]$TranscriptText = $null
    )

    $definition = Get-KimiContractDefinition
    $modeNote = switch ($Mode) {
        "transcript" { "This request is running in transcript fallback mode because native Kimi session resume was unavailable." }
        "transcript_salvage" { "This request is running in transcript fallback mode because native Kimi session resume was unavailable." }
        default { "Use the workspace directly and report back to the supervising agent." }
    }

    $transcriptBlock = if ([string]::IsNullOrWhiteSpace($TranscriptText)) {
        ""
    }
    else {
        "Conversation transcript so far:`n$TranscriptText`n`n"
    }

    $schema = ($definition.RequiredSections | ForEach-Object { "${_}:" }) -join "`n"
    return @"
You are Kimi Code working as a subordinate coding agent for another supervising agent.

You are operating on workspace: $Workspace
Execution mode: $Mode
Task risk level: $TaskRiskLevel
$modeNote

Rules:
- Be concise but specific.
- Put evidence before conclusions.
- Do not claim completion without verification.
- If no files were changed, use CHANGES: NO_CHANGES.
- If verification was not run, use NOT_RUN and explain why.
- If task risk is high and verification is limited, say so plainly.
- You are running on Windows. Use PowerShell syntax only. Never use bash syntax (no ls -la, no ||, no head, no grep, no chmod).
- All output text must use ASCII-only characters. Do not output Unicode box-drawing characters, em-dashes, curly quotes, or non-breaking spaces.
- For local file audit tasks: read structured metadata files first (e.g. page-claims.txt) before opening raw HTML or binary files.
- Do not use browser or network tools when the task is local-only.

Use exactly this response schema:
$schema

${transcriptBlock}User request:
$UserMessage
"@
}

function Get-KimiCanonicalSectionName {
    param(
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $normalized = $Candidate.ToUpperInvariant()
    $normalized = [regex]::Replace($normalized, "[^A-Z0-9]+", "_")
    $normalized = $normalized.Trim("_")

    switch ($normalized) {
        "TASK" { return "TASK" }
        "PLAN" { return "PLAN" }
        "EVIDENCE" { return "EVIDENCE" }
        "CHANGES" { return "CHANGES" }
        "VERIFICATION" { return "VERIFICATION" }
        "REMAINING_RISKS" { return "REMAINING_RISKS" }
        "REMAINING_RISK" { return "REMAINING_RISKS" }
        default { return $null }
    }
}

function Get-KimiDetectedSections {
    param(
        [string]$Text
    )

    $definition = Get-KimiContractDefinition
    $buffers = [ordered]@{}
    foreach ($section in $definition.RequiredSections) {
        $buffers[$section] = New-Object System.Collections.Generic.List[string]
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]$buffers
    }

    $currentSection = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        $candidateName = $null
        $inlineContent = $null

        if ($trimmed -match '^(?:#{1,6}\s*)?(?:\*\*|__|`)?(?<name>[A-Za-z][A-Za-z _-]*[A-Za-z])(?:\*\*|__|`)?\s*:\s*(?<inline>.*)$') {
            $candidateName = $matches.name
            $inlineContent = $matches.inline
        }
        elseif ($trimmed -match '^(?:#{1,6}\s*)(?:\*\*|__|`)?(?<name>[A-Za-z][A-Za-z _-]*[A-Za-z])(?:\*\*|__|`)?\s*$') {
            $candidateName = $matches.name
            $inlineContent = $null
        }
        elseif ($trimmed -match '^(?:\*\*|__|`)?(?<name>[A-Za-z][A-Za-z _-]*[A-Za-z])(?:\*\*|__|`)?\s*$') {
            $candidateName = $matches.name
            $inlineContent = $null
        }

        $canonicalName = Get-KimiCanonicalSectionName -Candidate $candidateName
        if (-not [string]::IsNullOrWhiteSpace($canonicalName)) {
            $currentSection = $canonicalName
            if (-not [string]::IsNullOrWhiteSpace($inlineContent)) {
                $buffers[$canonicalName].Add($inlineContent.Trim())
            }
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($currentSection)) {
            $buffers[$currentSection].Add($line)
        }
    }

    $result = [ordered]@{}
    foreach ($section in $definition.RequiredSections) {
        $result[$section] = (($buffers[$section] -join "`n").Trim())
    }
    return [pscustomobject]$result
}

function Get-KimiMissingSections {
    param(
        [object]$Sections
    )

    $definition = Get-KimiContractDefinition
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($section in $definition.RequiredSections) {
        $value = Get-KimiSafePropertyValue -Object $Sections -Name $section
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            $missing.Add($section)
        }
    }
    return @($missing)
}

function Test-KimiResultGate {
    param(
        [string]$Text,
        [string]$TaskRiskLevel = "normal_write"
    )

    $definition = Get-KimiContractDefinition
    $sections = Get-KimiDetectedSections -Text $Text
    $missingSections = @(Get-KimiMissingSections -Sections $sections)
    $warnings = New-Object System.Collections.Generic.List[string]
    $hardFailures = New-Object System.Collections.Generic.List[string]

    $taskSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "TASK")
    $planSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "PLAN")
    $evidenceSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "EVIDENCE")
    $changesSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "CHANGES")
    $verificationSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "VERIFICATION")
    $riskSection = [string](Get-KimiSafePropertyValue -Object $sections -Name "REMAINING_RISKS")

    $evidenceNone = $evidenceSection -match '(?is)^NONE\b'
    $noChanges = $changesSection -match '(?is)^NO_CHANGES\b'
    $verificationNotRun = $verificationSection -match '(?is)^NOT_RUN\b'
    $readOnlyAnalysisWithoutVerification = ($TaskRiskLevel -eq "read_only" -and $noChanges -and $verificationNotRun)
    $completionClaimed = $Text -match '(?im)\b(fixed|resolved|completed|done|successful(?:ly)?|patched|修复|完成|已完成)\b'
    $changesClaimed = -not [string]::IsNullOrWhiteSpace($changesSection) -and -not $noChanges
    $hasConcreteChangeDetail = $changesSection -match '(?i)([A-Za-z]:\\|[/\\][^ \r\n]+|[A-Za-z0-9._-]+\.[A-Za-z0-9]{1,6})'
    $verificationLooksWeak = (-not $verificationNotRun) -and (
        $verificationSection.Length -lt 20 -or
        $verificationSection -match '(?is)^(done|verified|checked|ok|passed)(?:\s*[.!]?\s*)$'
    )
    $risksClaimNone = $riskSection -match '(?is)^(NONE|NO(?:\s+KNOWN)?\s+RISKS?|N/?A|无|没有|无风险)\b'

    foreach ($missing in $missingSections) {
        $hardFailures.Add("Missing required section: $missing")
    }

    if ($completionClaimed -and ($evidenceNone -or [string]::IsNullOrWhiteSpace($evidenceSection))) {
        $hardFailures.Add("Completion was claimed without usable evidence.")
    }

    if ($changesClaimed -and -not $hasConcreteChangeDetail) {
        $hardFailures.Add("Changes were claimed without concrete file or path detail.")
    }

    if ($completionClaimed -and [string]::IsNullOrWhiteSpace($verificationSection)) {
        $hardFailures.Add("Completion was claimed without a verification section.")
    }

    if ($risksClaimNone -and ($verificationLooksWeak -or ($verificationNotRun -and -not $readOnlyAnalysisWithoutVerification))) {
        $hardFailures.Add("Remaining risks were reported as none despite weak or missing verification.")
    }

    if ($noChanges -and $Text -match '(?im)\b(modified|updated|changed|patched|edited|created|deleted|removed|renamed)\b.+\.[A-Za-z0-9]{1,6}\b') {
        $hardFailures.Add("Output claims NO_CHANGES but also describes changed files.")
    }

    if ($verificationNotRun -and $completionClaimed -and -not $readOnlyAnalysisWithoutVerification) {
        $warnings.Add("Completion was claimed even though verification was marked NOT_RUN.")
    }

    if ($planSection.Length -lt 20) {
        $warnings.Add("PLAN section is terse and may be too vague.")
    }

    if (-not $evidenceNone -and $evidenceSection.Length -lt 20) {
        $warnings.Add("EVIDENCE section is terse and may lack concrete support.")
    }

    if ($verificationLooksWeak) {
        $warnings.Add("VERIFICATION section is present but method detail is weak.")
    }

    if ($riskSection.Length -lt 15 -and -not $risksClaimNone) {
        $warnings.Add("REMAINING_RISKS section is terse and may understate uncertainty.")
    }

    $gatePassed = ($hardFailures.Count -eq 0)
    $suggestedClassification = if (-not $gatePassed) {
        "incomplete"
    }
    elseif ($TaskRiskLevel -eq "high_risk" -and ($warnings.Count -gt 0 -or $verificationNotRun)) {
        "handoff_required"
    }
    elseif (
        ($changesClaimed -and ($warnings.Count -gt 0 -or $verificationNotRun)) -or
        ($completionClaimed -and ($warnings.Count -gt 0 -or ($verificationNotRun -and -not $readOnlyAnalysisWithoutVerification)))
    ) {
        "unverified"
    }
    else {
        "usable"
    }

    $handoffReason = if ($TaskRiskLevel -eq "high_risk" -and $suggestedClassification -ne "usable") {
        "High-risk task requires stronger verification before it can be trusted."
    }
    else {
        $null
    }

    $verificationConfidence = if (-not $gatePassed) {
        "low"
    }
    elseif ($verificationNotRun) {
        if ($TaskRiskLevel -eq "read_only") { "medium" } else { "low" }
    }
    elseif ($warnings.Count -eq 0) {
        "high"
    }
    else {
        "medium"
    }

    return [pscustomobject]@{
        ContractVersion         = $definition.Version
        RequiredSections        = @($definition.RequiredSections)
        Sections                = $sections
        DetectedSections        = @($definition.RequiredSections | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-KimiSafePropertyValue -Object $sections -Name $_)) })
        MissingSections         = @($missingSections)
        HardFailures            = @($hardFailures)
        Warnings                = @($warnings)
        GatePassed              = $gatePassed
        CompletionClaimed       = $completionClaimed
        VerificationConfidence  = $verificationConfidence
        SuggestedClassification = $suggestedClassification
        HandoffReason           = $handoffReason
    }
}

function Classify-KimiResult {
    param(
        [object]$GateResult,
        [string]$TaskRiskLevel = "normal_write",
        [switch]$HostError
    )

    if ($HostError) {
        return "host_error"
    }

    if ($null -eq $GateResult) {
        return "incomplete"
    }

    if ($TaskRiskLevel -eq "high_risk" -and $GateResult.SuggestedClassification -ne "usable") {
        return "handoff_required"
    }

    return [string]$GateResult.SuggestedClassification
}

function New-TranscriptFallbackPrompt {
    param(
        [string]$UserMessage,
        [object[]]$Transcript,
        [string]$Workspace,
        [string]$TaskRiskLevel = "normal_write"
    )

    $historyLines = @()
    foreach ($entry in $Transcript) {
        $historyLines += ("{0}: {1}" -f $entry.role, $entry.content)
    }
    $historyText = if ($historyLines.Count -gt 0) { $historyLines -join "`n" } else { "(empty)" }

    return (New-KimiContractPrompt -UserMessage $UserMessage -Workspace $Workspace -TaskRiskLevel $TaskRiskLevel -Mode "transcript" -TranscriptText $historyText)
}

function Convert-KimiStreamToText {
    param(
        [string[]]$Lines
    )

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            $parts.Add($line)
            continue
        }

        $objPropertyNames = @($obj.PSObject.Properties.Name)

        if ($objPropertyNames -contains "content" -and $null -ne $obj.content) {
            foreach ($item in $obj.content) {
                $itemPropertyNames = @($item.PSObject.Properties.Name)

                if (($itemPropertyNames -contains "type") -and $item.type -eq "text" -and ($itemPropertyNames -contains "text") -and -not [string]::IsNullOrWhiteSpace($item.text)) {
                    $parts.Add($item.text)
                    continue
                }

                if (($itemPropertyNames -contains "type") -and $item.type -eq "think" -and ($itemPropertyNames -contains "think") -and -not [string]::IsNullOrWhiteSpace($item.think)) {
                    $parts.Add((Format-KimiTaggedMultilineText -Tag "[THINK]" -Text ([string]$item.think)))
                    continue
                }

                if (($itemPropertyNames -contains "type") -and $item.type -eq "toolCall") {
                    $toolName = if ($itemPropertyNames -contains "name") { [string]$item.name } else { "unknown" }
                    $parts.Add("[TOOL_CALL] $toolName")
                    continue
                }
            }
        }

        if ($objPropertyNames -contains "tool_calls" -and $null -ne $obj.tool_calls) {
            foreach ($toolCall in $obj.tool_calls) {
                $toolPropertyNames = @($toolCall.PSObject.Properties.Name)
                if (($toolPropertyNames -contains "function") -and $null -ne $toolCall.function) {
                    $functionPropertyNames = @($toolCall.function.PSObject.Properties.Name)
                    $toolName = if ($functionPropertyNames -contains "name") { [string]$toolCall.function.name } else { "unknown" }
                    $parts.Add("[TOOL_CALL] $toolName")
                }
            }
        }
    }

    $result = ($parts -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($result)) {
        return "[NO_TEXT_EXTRACTED]"
    }
    return $result
}

function Format-KimiTaggedMultilineText {
    param(
        [string]$Tag,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return $Text
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Tag
    }

    $taggedLines = @(
        $Text -split "`r?`n" |
        ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) {
                $Tag
            }
            else {
                "$Tag $_"
            }
        }
    )

    return ($taggedLines -join "`n")
}

function Test-KimiHasFinalText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $meaningfulLines = @(
        $Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -ne "[NO_TEXT_EXTRACTED]" -and
            $_ -notmatch '^\[THINK\](?:\s|$)' -and
            $_ -notmatch '^\[TOOL_CALL\](?:\s|$)'
        }
    )

    return ($meaningfulLines.Count -gt 0)
}

function Get-KimiHome {
    return $env:USERPROFILE
}

function Get-KimiJsonPath {
    return (Join-Path (Get-KimiHome) ".kimi\kimi.json")
}

function Get-KimiSessionsRoot {
    return (Join-Path (Get-KimiHome) ".kimi\sessions")
}

function Get-KimiLastSessionIdForWorkspace {
    param(
        [string]$Workspace
    )

    $kimiJson = Get-KimiJsonPath
    if (-not (Test-Path $kimiJson)) {
        return $null
    }

    $json = Get-Content $kimiJson | ConvertFrom-Json
    foreach ($entry in $json.work_dirs) {
        if ($entry.path -ieq $Workspace -and -not [string]::IsNullOrWhiteSpace($entry.last_session_id)) {
            return [string]$entry.last_session_id
        }
    }

    return $null
}

function Get-KimiNativeSessionDirectory {
    param(
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $null
    }

    $sessionsRoot = Get-KimiSessionsRoot
    if (-not (Test-Path $sessionsRoot)) {
        return $null
    }

    $match = Get-ChildItem -Path $sessionsRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $SessionId } |
        Select-Object -First 1

    if ($null -eq $match) {
        return $null
    }

    return $match.FullName
}

function Get-KimiNativeContextPath {
    param(
        [string]$SessionId
    )

    $sessionDir = Get-KimiNativeSessionDirectory -SessionId $SessionId
    if ([string]::IsNullOrWhiteSpace($sessionDir)) {
        return $null
    }

    $contextPath = Join-Path $sessionDir "context.jsonl"
    if (-not (Test-Path $contextPath)) {
        return $null
    }

    return $contextPath
}

function Get-KimiNativeWirePath {
    param(
        [string]$SessionId
    )

    $sessionDir = Get-KimiNativeSessionDirectory -SessionId $SessionId
    if ([string]::IsNullOrWhiteSpace($sessionDir)) {
        return $null
    }

    $wirePath = Join-Path $sessionDir "wire.jsonl"
    if (-not (Test-Path $wirePath)) {
        return $null
    }

    return $wirePath
}

function Get-KimiNativeFileSnapshot {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return [pscustomobject]@{
            Exists = $false
            LineCount = 0
            LastWriteTimeUtc = $null
        }
    }

    $item = Get-Item -LiteralPath $Path
    $lines = @(Get-Content -Path $Path)
    return [pscustomobject]@{
        Exists = $true
        LineCount = $lines.Count
        LastWriteTimeUtc = $item.LastWriteTimeUtc
    }
}

function Get-KimiNativeContextSnapshot {
    param(
        [string]$ContextPath
    )

    return Get-KimiNativeFileSnapshot -Path $ContextPath
}

function Convert-KimiContentValueToText {
    param(
        [object]$Content
    )

    if ($null -eq $Content) {
        return $null
    }

    if ($Content -is [string]) {
        $textValue = $Content.Trim()
        if (-not [string]::IsNullOrWhiteSpace($textValue)) {
            return $textValue
        }
        return $null
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $parts.Add($item.Trim())
            }
            continue
        }

        $itemPropertyNames = @($item.PSObject.Properties.Name)
        if (($itemPropertyNames -contains "type") -and $item.type -eq "text" -and ($itemPropertyNames -contains "text") -and -not [string]::IsNullOrWhiteSpace($item.text)) {
            $parts.Add([string]$item.text)
            continue
        }

        if (($itemPropertyNames -contains "type") -and $item.type -eq "think" -and ($itemPropertyNames -contains "think") -and -not [string]::IsNullOrWhiteSpace($item.think)) {
            $parts.Add((Format-KimiTaggedMultilineText -Tag "[THINK]" -Text ([string]$item.think)))
            continue
        }

        if (($itemPropertyNames -contains "type") -and $item.type -eq "toolCall") {
            $toolName = if ($itemPropertyNames -contains "name") { [string]$item.name } else { "unknown" }
            $parts.Add("[TOOL_CALL] $toolName")
            continue
        }
    }

    $result = ($parts -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }
    return $result
}

function Get-KimiLatestAssistantTextFromContext {
    param(
        [string]$ContextPath,
        [int]$AfterLineCount = 0,
        [bool]$FallbackToWholeFile = $true
    )

    if ([string]::IsNullOrWhiteSpace($ContextPath) -or -not (Test-Path $ContextPath)) {
        return $null
    }

    $lines = @(Get-Content -Path $ContextPath)
    if ($lines.Count -eq 0) {
        return $null
    }

    $startIndex = [Math]::Max(0, $AfterLineCount)
    $candidateLines = if ($startIndex -lt $lines.Count) { $lines[$startIndex..($lines.Count - 1)] } else { @() }

    $lineSets = @($candidateLines)
    if ($FallbackToWholeFile) {
        $lineSets += ,$lines
    }

    foreach ($lineSet in $lineSets) {
        $lineArray = @($lineSet)
        for ($i = $lineArray.Count - 1; $i -ge 0; $i--) {
            $line = $lineArray[$i]
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ($entry.role -ne "assistant") {
                continue
            }

            $text = Convert-KimiContentValueToText -Content $entry.content
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
    }

    return $null
}

function Get-KimiLatestAssistantEntryFromContext {
    param(
        [string]$ContextPath
    )

    if ([string]::IsNullOrWhiteSpace($ContextPath) -or -not (Test-Path $ContextPath)) {
        return $null
    }

    $lines = @(Get-Content -Path $ContextPath)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($entry.role -ne "assistant") {
            continue
        }

        $text = Convert-KimiContentValueToText -Content $entry.content
        return [pscustomobject]@{
            Line = $line
            Entry = $entry
            Text = $text
        }
    }

    return $null
}

function Get-KimiSafePropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Wait-KimiLatestAssistantText {
    param(
        [string]$SessionId,
        [int]$AfterLineCount = 0,
        [string]$PreviousAssistantText = $null,
        [int]$TimeoutMs = 600000,
        [int]$PollMs = 5000,
        [int]$StablePollCount = 6,
        [switch]$ReadWireFallback
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $contextPath = $null
    $wirePath = $null
    $lastContextLineCount = [Math]::Max(0, $AfterLineCount)
    $lastWireLineCount = 0
    $lastActivityAt = $null
    $hadActivity = $false
    $stablePolls = 0

    do {
        $contextPath = Get-KimiNativeContextPath -SessionId $SessionId
        $wirePath = if ($ReadWireFallback) { Get-KimiNativeWirePath -SessionId $SessionId } else { $null }
        $snapshot = Get-KimiNativeContextSnapshot -ContextPath $contextPath
        $wireSnapshot = Get-KimiNativeFileSnapshot -Path $wirePath
        $text = Get-KimiLatestAssistantTextFromContext -ContextPath $contextPath -AfterLineCount $AfterLineCount -FallbackToWholeFile:$false
        $hasFinalText = Test-KimiHasFinalText -Text $text
        $hasNewLines = $snapshot.Exists -and ($snapshot.LineCount -gt $AfterLineCount)
        $isDifferentFromPrevious = -not [string]::IsNullOrWhiteSpace($text) -and ($text -ne $PreviousAssistantText)
        $contextAdvanced = $snapshot.Exists -and ($snapshot.LineCount -gt $lastContextLineCount)
        $wireAdvanced = $wireSnapshot.Exists -and ($wireSnapshot.LineCount -gt $lastWireLineCount)
        $hasActivity = $contextAdvanced -or $wireAdvanced

        if ($hasFinalText -and ($hasNewLines -or $isDifferentFromPrevious)) {
            return [pscustomobject]@{
                Status = "completed"
                ContextPath = $contextPath
                WirePath = $wirePath
                Text = $text
                LineCount = $snapshot.LineCount
                WireLineCount = $wireSnapshot.LineCount
                HadActivity = $hadActivity -or $hasActivity
                LastActivityAt = if ($lastActivityAt) { $lastActivityAt.ToString("o") } else { (Get-Date).ToString("o") }
            }
        }

        if ($hasActivity) {
            $hadActivity = $true
            $lastActivityAt = Get-Date
            $stablePolls = 0
        }
        else {
            $stablePolls++
        }

        $lastContextLineCount = $snapshot.LineCount
        $lastWireLineCount = $wireSnapshot.LineCount

        if ($hadActivity -and $stablePolls -ge $StablePollCount) {
            $latestText = Get-KimiLatestAssistantTextFromContext -ContextPath $contextPath -AfterLineCount $AfterLineCount -FallbackToWholeFile:$false
            $latestHasFinalText = (Test-KimiHasFinalText -Text $latestText) -and ($latestText -ne $PreviousAssistantText)
            return [pscustomobject]@{
                Status = if ($latestHasFinalText) { "completed" } else { "no_text_but_native_activity" }
                ContextPath = $contextPath
                WirePath = $wirePath
                Text = if ($latestHasFinalText) { $latestText } else { $null }
                LineCount = $snapshot.LineCount
                WireLineCount = $wireSnapshot.LineCount
                HadActivity = $hadActivity
                LastActivityAt = if ($lastActivityAt) { $lastActivityAt.ToString("o") } else { $null }
            }
        }

        Start-Sleep -Milliseconds $PollMs
    } while ((Get-Date) -lt $deadline)

    $latestText = Get-KimiLatestAssistantTextFromContext -ContextPath $contextPath -AfterLineCount $AfterLineCount -FallbackToWholeFile:$false
    $latestHasFinalText = (Test-KimiHasFinalText -Text $latestText) -and ($latestText -ne $PreviousAssistantText)
    return [pscustomobject]@{
        Status = if ($latestHasFinalText) { "completed" } elseif ($hadActivity) { "no_text_but_native_activity" } else { "timed_out" }
        ContextPath = (Get-KimiNativeContextPath -SessionId $SessionId)
        WirePath = if ($ReadWireFallback) { Get-KimiNativeWirePath -SessionId $SessionId } else { $null }
        Text = if ($latestHasFinalText) { $latestText } else { $null }
        LineCount = $lastContextLineCount
        WireLineCount = $lastWireLineCount
        HadActivity = $hadActivity
        LastActivityAt = if ($lastActivityAt) { $lastActivityAt.ToString("o") } else { $null }
    }
}

function Invoke-KimiPrint {
    param(
        [string]$KimiCommand,
        [string[]]$Arguments
    )

    $rawLines = & $KimiCommand @Arguments 2>&1
    $exitCode = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = @($rawLines)
        Text     = (@($rawLines) -join "`n")
    }
}
