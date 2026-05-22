param(
    [Parameter(Mandatory = $true)]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$Workspace = ".",

    [switch]$Reset,

    [switch]$ShowPrompt,

    [switch]$ForceTranscript,

    [int]$RecoveryWaitMs = 600000,

    [switch]$NoThinking
)

. (Join-Path $PSScriptRoot "common.ps1")

Initialize-KimiEnvironment
$kimi = Resolve-KimiCommand
Assert-KimiHealthy -KimiCommand $kimi
$workspacePath = Normalize-Workspace -Workspace $Workspace
$sessionPaths = Get-SessionPaths -SessionName $Session
$meta = Read-SessionMeta -Path $sessionPaths.Meta
$taskRiskLevel = Get-KimiTaskRiskLevel -Message $Message

if ($Reset) {
    foreach ($path in @($sessionPaths.Transcript, $sessionPaths.LastPrompt, $sessionPaths.LastRawJson, $sessionPaths.LastText, $sessionPaths.Meta)) {
        if (Test-Path $path) {
            Remove-Item $path -Force
        }
    }
    $meta = Read-SessionMeta -Path $sessionPaths.Meta
}

$transcript = @(Read-JsonLines -Path $sessionPaths.Transcript)
$timestamp = (Get-Date).ToString("s")
$modeUsed = "native"
$nativeError = $null
$kimiSessionId = $meta.kimi_session_id
$previousAssistantText = $null
if ($transcript.Count -gt 0) {
    $lastTranscriptEntry = $transcript[$transcript.Count - 1]
    if ($lastTranscriptEntry.role -eq "assistant" -and -not [string]::IsNullOrWhiteSpace($lastTranscriptEntry.content)) {
        $previousAssistantText = [string]$lastTranscriptEntry.content
    }
}

if ($ShowPrompt) {
    if ($ForceTranscript) {
        $promptPreview = New-TranscriptFallbackPrompt -UserMessage $Message -Transcript $transcript -Workspace $workspacePath -TaskRiskLevel $taskRiskLevel
        Save-TextFile -Path $sessionPaths.LastPrompt -Content $promptPreview
        $promptPreview
        exit 0
    }

    $promptPreview = New-KimiContractPrompt -UserMessage $Message -Workspace $workspacePath -TaskRiskLevel $taskRiskLevel -Mode "native"
    Save-TextFile -Path $sessionPaths.LastPrompt -Content $promptPreview
    $promptPreview
    exit 0
}

$result = $null
$nativeContextPath = $null
$nativeWirePath = $null
$nativeContextSnapshot = $null
$nativeRecoveryStatus = "not_needed"
$nativeRecovery = $null
$outputSource = "direct"
$gbkSalvageText = $null
if (-not $ForceTranscript) {
    if ([string]::IsNullOrWhiteSpace($kimiSessionId)) {
        $kimiSessionId = [guid]::NewGuid().ToString()
    }

    if (-not [string]::IsNullOrWhiteSpace($kimiSessionId)) {
        $nativeContextPath = Get-KimiNativeContextPath -SessionId $kimiSessionId
        $nativeWirePath = Get-KimiNativeWirePath -SessionId $kimiSessionId
        $nativeContextSnapshot = Get-KimiNativeContextSnapshot -ContextPath $nativeContextPath
    }

    $nativePrompt = New-KimiContractPrompt -UserMessage $Message -Workspace $workspacePath -TaskRiskLevel $taskRiskLevel -Mode "native"
    $nativeArgs = @("--print", "--output-format", "stream-json", "-w", $workspacePath)
    if (-not $NoThinking) {
        $nativeArgs += "--thinking"
    }
    if (-not [string]::IsNullOrWhiteSpace($kimiSessionId)) {
        $nativeArgs += @("--session", $kimiSessionId)
    }
    $nativeArgs += @("-p", $nativePrompt)
    Save-TextFile -Path $sessionPaths.LastPrompt -Content $nativePrompt
    $result = Invoke-KimiPrint -KimiCommand $kimi -Arguments $nativeArgs

    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($nativeContextPath)) {
            $nativeContextPath = Get-KimiNativeContextPath -SessionId $kimiSessionId
        }
        if ([string]::IsNullOrWhiteSpace($nativeWirePath)) {
            $nativeWirePath = Get-KimiNativeWirePath -SessionId $kimiSessionId
        }

        if ([string]::IsNullOrWhiteSpace($kimiSessionId)) {
            $nativeError = "Native run succeeded but no Kimi session id was discovered for workspace $workspacePath."
        }
    }
    else {
        # GBK salvage: Kimi may have finished but crashed printing output due to Windows
        # console GBK encoding. Try native context.jsonl before falling to transcript mode.
        $isGbkCrash = $result.Text -match "gbk|codec|UnicodeEncodeError"
        if ($isGbkCrash -and -not [string]::IsNullOrWhiteSpace($kimiSessionId)) {
            $beforeLineCount = if ($null -ne $nativeContextSnapshot) { [int]$nativeContextSnapshot.LineCount } else { 0 }
            $gbkRecovery = Wait-KimiLatestAssistantText -SessionId $kimiSessionId -AfterLineCount $beforeLineCount -PreviousAssistantText $previousAssistantText -TimeoutMs 30000
            $gbkSalvageText = Get-KimiSafePropertyValue -Object $gbkRecovery -Name "Text"
            if (-not [string]::IsNullOrWhiteSpace($gbkSalvageText)) {
                $outputSource = "gbk_salvage"
                $recoveredCtx = Get-KimiSafePropertyValue -Object $gbkRecovery -Name "ContextPath"
                $recoveredWire = Get-KimiSafePropertyValue -Object $gbkRecovery -Name "WirePath"
                if (-not [string]::IsNullOrWhiteSpace($recoveredCtx)) { $nativeContextPath = $recoveredCtx }
                if (-not [string]::IsNullOrWhiteSpace($recoveredWire)) { $nativeWirePath = $recoveredWire }
                # Do NOT set $nativeError so transcript fallback is skipped
            }
            else {
                $nativeError = $result.Text
            }
        }
        else {
            $nativeError = $result.Text
        }
    }
}

if ($ForceTranscript -or -not [string]::IsNullOrWhiteSpace($nativeError)) {
    $modeUsed = "transcript"
    $fallbackPrompt = New-TranscriptFallbackPrompt -UserMessage $Message -Transcript $transcript -Workspace $workspacePath -TaskRiskLevel $taskRiskLevel
    Save-TextFile -Path $sessionPaths.LastPrompt -Content $fallbackPrompt
    $fallbackArgs = @("--print", "--output-format", "stream-json", "-w", $workspacePath)
    if (-not $NoThinking) {
        $fallbackArgs += "--thinking"
    }
    $fallbackArgs += @("-p", $fallbackPrompt)
    $result = Invoke-KimiPrint -KimiCommand $kimi -Arguments $fallbackArgs
    if ($result.ExitCode -ne 0) {
        $errorTimestamp = (Get-Date).ToString("s")
        $hostMeta = [pscustomobject]@{
            mode                    = $modeUsed
            kimi_session_id         = $kimiSessionId
            workspace               = $workspacePath
            last_native_error       = if (-not [string]::IsNullOrWhiteSpace($nativeError)) { $nativeError } else { $result.Text }
            native_context_path     = $nativeContextPath
            native_wire_path        = $nativeWirePath
            recovery_status         = "failed"
            last_context_line_count = if ($null -ne $nativeContextSnapshot) { $nativeContextSnapshot.LineCount } else { 0 }
            last_wire_line_count    = 0
            last_recovered_at       = $null
            updated_at              = $errorTimestamp
            task_risk_level         = $taskRiskLevel
            result_classification   = "host_error"
            gate_passed             = $false
            validation_warnings     = @("Kimi CLI returned a non-zero exit code in transcript fallback mode.")
            handoff_reason          = "Transcript fallback failed and requires supervisor intervention."
            output_source           = $null
            verification_confidence = "low"
            completion_claimed      = $false
        }
        Write-SessionMeta -Path $sessionPaths.Meta -Meta $hostMeta
        throw $result.Text
    }
    $outputSource = "transcript_salvage"
}

Save-TextFile -Path $sessionPaths.LastRawJson -Content $result.Text
if (-not [string]::IsNullOrWhiteSpace($gbkSalvageText)) {
    # GBK salvage already recovered clean text - skip stream-json parsing entirely
    $text = $gbkSalvageText
    $nativeRecoveryStatus = "completed"
}
else {
    $text = Convert-KimiStreamToText -Lines $result.Lines
}
if ([string]::IsNullOrWhiteSpace($gbkSalvageText) -and $modeUsed -eq "native" -and ($text -eq "[NO_TEXT_EXTRACTED]" -or [string]::IsNullOrWhiteSpace($text) -or -not (Test-KimiHasFinalText -Text $text))) {
    $afterLineCount = if ($null -ne $nativeContextSnapshot) { [int]$nativeContextSnapshot.LineCount } else { 0 }
    $nativeRecovery = Wait-KimiLatestAssistantText -SessionId $kimiSessionId -AfterLineCount $afterLineCount -PreviousAssistantText $previousAssistantText -TimeoutMs $RecoveryWaitMs -ReadWireFallback
    $nativeRecoveryStatus = Get-KimiSafePropertyValue -Object $nativeRecovery -Name "Status"
    $recoveredContextPath = Get-KimiSafePropertyValue -Object $nativeRecovery -Name "ContextPath"
    $recoveredWirePath = Get-KimiSafePropertyValue -Object $nativeRecovery -Name "WirePath"
    $recoveredText = Get-KimiSafePropertyValue -Object $nativeRecovery -Name "Text"
    if (-not [string]::IsNullOrWhiteSpace($recoveredContextPath)) {
        $nativeContextPath = $recoveredContextPath
    }
    if (-not [string]::IsNullOrWhiteSpace($recoveredWirePath)) {
        $nativeWirePath = $recoveredWirePath
    }
    if (-not [string]::IsNullOrWhiteSpace($recoveredText)) {
        $text = $recoveredText
    }
    $outputSource = "native_recovery"
}
elseif ($modeUsed -eq "native" -and [string]::IsNullOrWhiteSpace($gbkSalvageText)) {
    $nativeRecoveryStatus = "completed"
    $outputSource = "direct"
}
Save-TextFile -Path $sessionPaths.LastText -Content $text

$gateResult = Test-KimiResultGate -Text $text -TaskRiskLevel $taskRiskLevel
$resultClassification = Classify-KimiResult -GateResult $gateResult -TaskRiskLevel $taskRiskLevel
$handoffReason = if ($resultClassification -eq "handoff_required") {
    if (-not [string]::IsNullOrWhiteSpace($gateResult.HandoffReason)) {
        $gateResult.HandoffReason
    }
    else {
        "Result requires supervisor review before it can be trusted."
    }
}
else {
    $null
}

Append-JsonLine -Path $sessionPaths.Transcript -Value ([pscustomobject]@{
    timestamp = $timestamp
    role = "user"
    content = $Message
})
Append-JsonLine -Path $sessionPaths.Transcript -Value ([pscustomobject]@{
    timestamp = $timestamp
    role = "assistant"
    content = $text
})

$newMeta = [pscustomobject]@{
    mode = $modeUsed
    kimi_session_id = $kimiSessionId
    workspace = $workspacePath
    last_native_error = $nativeError
    native_context_path = $nativeContextPath
    native_wire_path = $nativeWirePath
    recovery_status = $nativeRecoveryStatus
    last_context_line_count = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "LineCount" } elseif ($null -ne $nativeContextSnapshot) { $nativeContextSnapshot.LineCount } else { 0 }
    last_wire_line_count = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "WireLineCount" } else { 0 }
    last_recovered_at = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "LastActivityAt" } else { $null }
    updated_at = $timestamp
    contract_version = $gateResult.ContractVersion
    required_sections = @($gateResult.RequiredSections)
    detected_sections = @($gateResult.DetectedSections)
    missing_sections = @($gateResult.MissingSections)
    result_classification = $resultClassification
    gate_passed = $gateResult.GatePassed
    validation_warnings = @($gateResult.Warnings)
    handoff_reason = $handoffReason
    output_source = $outputSource
    verification_confidence = $gateResult.VerificationConfidence
    task_risk_level = $taskRiskLevel
    completion_claimed = $gateResult.CompletionClaimed
}
Write-SessionMeta -Path $sessionPaths.Meta -Meta $newMeta

$text
