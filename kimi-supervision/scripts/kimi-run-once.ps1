param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$Workspace = ".",

    [switch]$StreamJson,

    [switch]$NoThinking
)

. (Join-Path $PSScriptRoot "common.ps1")

Initialize-KimiEnvironment
$kimi = Resolve-KimiCommand
Assert-KimiHealthy -KimiCommand $kimi
$workspacePath = Normalize-Workspace -Workspace $Workspace
$kimiSessionId = [guid]::NewGuid().ToString()
$taskRiskLevel = Get-KimiTaskRiskLevel -Message $Message
$sessionPaths = Get-SessionPaths -SessionName "run-once-latest"
$timestamp = (Get-Date).ToString("s")
$prompt = New-KimiContractPrompt -UserMessage $Message -Workspace $workspacePath -TaskRiskLevel $taskRiskLevel -Mode "native"
$outputSource = "direct"
$nativeRecovery = $null
$nativeRecoveryStatus = "not_needed"

$arguments = @("--print", "--output-format", "stream-json", "-w", $workspacePath)
if (-not $NoThinking) {
    $arguments += "--thinking"
}
$arguments += @("--session", $kimiSessionId, "-p", $prompt)
Save-TextFile -Path $sessionPaths.LastPrompt -Content $prompt

$result = Invoke-KimiPrint -KimiCommand $kimi -Arguments $arguments
Save-TextFile -Path $sessionPaths.LastRawJson -Content $result.Text
if ($result.ExitCode -ne 0) {
    # GBK salvage: Kimi may have finished the task but crashed during stdout printing
    # due to a non-GBK character in its own output (Windows console encoding bug).
    # Before declaring host_error, attempt to recover the answer from native context.jsonl.
    $isGbkCrash = $result.Text -match "gbk|codec|UnicodeEncodeError"
    $gbkSalvageText = $null
    if ($isGbkCrash -and -not [string]::IsNullOrWhiteSpace($kimiSessionId)) {
        $gbkRecovery = Wait-KimiLatestAssistantText -SessionId $kimiSessionId -AfterLineCount 0 -TimeoutMs 30000
        $gbkSalvageText = Get-KimiSafePropertyValue -Object $gbkRecovery -Name "Text"
        if (-not [string]::IsNullOrWhiteSpace($gbkSalvageText)) {
            $outputSource = "gbk_salvage"
        }
    }
    if ([string]::IsNullOrWhiteSpace($gbkSalvageText)) {
        $hostMeta = [pscustomobject]@{
            mode                    = "native"
            kimi_session_id         = $kimiSessionId
            workspace               = $workspacePath
            last_native_error       = $result.Text
            recovery_status         = "failed"
            updated_at              = $timestamp
            task_risk_level         = $taskRiskLevel
            result_classification   = "host_error"
            gate_passed             = $false
            validation_warnings     = @("Kimi CLI returned a non-zero exit code in run-once mode.")
            handoff_reason          = "Run-once execution failed and requires supervisor intervention."
            output_source           = $null
            verification_confidence = "low"
            completion_claimed      = $false
        }
        Write-SessionMeta -Path $sessionPaths.Meta -Meta $hostMeta
        throw $result.Text
    }
    $nativeRecoveryStatus = "completed"
    $text = $gbkSalvageText
}
else {
    $text = Convert-KimiStreamToText -Lines $result.Lines
    if ($text -eq "[NO_TEXT_EXTRACTED]" -or [string]::IsNullOrWhiteSpace($text) -or -not (Test-KimiHasFinalText -Text $text)) {
        $nativeRecovery = Wait-KimiLatestAssistantText -SessionId $kimiSessionId -AfterLineCount 0
        $nativeRecoveryStatus = Get-KimiSafePropertyValue -Object $nativeRecovery -Name "Status"
        if (-not [string]::IsNullOrWhiteSpace($nativeRecovery.Text)) {
            $text = $nativeRecovery.Text
        }
        $outputSource = "native_recovery"
    }
}

Save-TextFile -Path $sessionPaths.LastText -Content $text
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

$runOnceMeta = [pscustomobject]@{
    mode                    = "native"
    kimi_session_id         = $kimiSessionId
    workspace               = $workspacePath
    last_native_error       = $null
    native_context_path     = Get-KimiNativeContextPath -SessionId $kimiSessionId
    native_wire_path        = Get-KimiNativeWirePath -SessionId $kimiSessionId
    recovery_status         = $nativeRecoveryStatus
    last_context_line_count = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "LineCount" } else { 0 }
    last_wire_line_count    = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "WireLineCount" } else { 0 }
    last_recovered_at       = if ($null -ne $nativeRecovery) { Get-KimiSafePropertyValue -Object $nativeRecovery -Name "LastActivityAt" } else { $null }
    updated_at              = $timestamp
    contract_version        = $gateResult.ContractVersion
    required_sections       = @($gateResult.RequiredSections)
    detected_sections       = @($gateResult.DetectedSections)
    missing_sections        = @($gateResult.MissingSections)
    result_classification   = $resultClassification
    gate_passed             = $gateResult.GatePassed
    validation_warnings     = @($gateResult.Warnings)
    handoff_reason          = $handoffReason
    output_source           = $outputSource
    verification_confidence = $gateResult.VerificationConfidence
    task_risk_level         = $taskRiskLevel
    completion_claimed      = $gateResult.CompletionClaimed
}
Write-SessionMeta -Path $sessionPaths.Meta -Meta $runOnceMeta

if ($StreamJson) {
    $result.Text
}
else {
    $text
}
