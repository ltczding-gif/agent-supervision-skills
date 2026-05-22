param(
    [Parameter(Mandatory = $true)]
    [string]$Session,

    [ValidateSet("transcript", "last", "prompt", "raw", "meta", "native-context", "native-wire", "native-last-assistant", "status")]
    [string]$View = "transcript"
)

. (Join-Path $PSScriptRoot "common.ps1")

Initialize-KimiEnvironment
$sessionPaths = Get-SessionPaths -SessionName $Session
$meta = Read-SessionMeta -Path $sessionPaths.Meta

function Get-MetaValue {
    param(
        [object]$Object,
        [string]$Name
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

switch ($View) {
    "transcript" {
        if (Test-Path $sessionPaths.Transcript) { Get-Content $sessionPaths.Transcript }
    }
    "last" {
        if (Test-Path $sessionPaths.LastText) { Get-Content $sessionPaths.LastText }
    }
    "prompt" {
        if (Test-Path $sessionPaths.LastPrompt) { Get-Content $sessionPaths.LastPrompt }
    }
    "raw" {
        if (Test-Path $sessionPaths.LastRawJson) { Get-Content $sessionPaths.LastRawJson }
    }
    "meta" {
        if (Test-Path $sessionPaths.Meta) { Get-Content $sessionPaths.Meta }
    }
    "native-context" {
        $path = Get-MetaValue -Object $meta -Name "native_context_path"
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            Get-Content $path
        }
    }
    "native-wire" {
        $path = Get-MetaValue -Object $meta -Name "native_wire_path"
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            Get-Content $path
        }
    }
    "native-last-assistant" {
        $path = Get-MetaValue -Object $meta -Name "native_context_path"
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            $entry = Get-KimiLatestAssistantEntryFromContext -ContextPath $path
            if ($null -ne $entry) {
                if (-not [string]::IsNullOrWhiteSpace($entry.Text)) {
                    $entry.Text
                }
                else {
                    $entry.Line
                }
            }
        }
    }
    "status" {
        [pscustomobject]@{
            session                 = $sessionPaths.Name
            mode                    = Get-MetaValue -Object $meta -Name "mode"
            result_classification   = Get-MetaValue -Object $meta -Name "result_classification"
            gate_passed             = Get-MetaValue -Object $meta -Name "gate_passed"
            task_risk_level         = Get-MetaValue -Object $meta -Name "task_risk_level"
            output_source           = Get-MetaValue -Object $meta -Name "output_source"
            missing_sections        = @(Get-MetaValue -Object $meta -Name "missing_sections")
            validation_warnings     = @(Get-MetaValue -Object $meta -Name "validation_warnings")
            handoff_reason          = Get-MetaValue -Object $meta -Name "handoff_reason"
            verification_confidence = Get-MetaValue -Object $meta -Name "verification_confidence"
            recovery_status         = Get-MetaValue -Object $meta -Name "recovery_status"
            kimi_session_id         = Get-MetaValue -Object $meta -Name "kimi_session_id"
            workspace               = Get-MetaValue -Object $meta -Name "workspace"
            native_context_path     = Get-MetaValue -Object $meta -Name "native_context_path"
            native_wire_path        = Get-MetaValue -Object $meta -Name "native_wire_path"
            last_context_line_count = Get-MetaValue -Object $meta -Name "last_context_line_count"
            last_wire_line_count    = Get-MetaValue -Object $meta -Name "last_wire_line_count"
            last_recovered_at       = Get-MetaValue -Object $meta -Name "last_recovered_at"
            last_native_error       = Get-MetaValue -Object $meta -Name "last_native_error"
            updated_at              = Get-MetaValue -Object $meta -Name "updated_at"
        } | ConvertTo-Json -Depth 10
    }
}
