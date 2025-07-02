# Modules\Targets\GCS\GCS.SettingsValidator.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Handles configuration validation.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupGCSTargetSettingsValidation' function. It is
    responsible for validating the structure and values within the TargetSpecificSettings
    and RemoteRetentionSettings for a GCS target definition.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added ADVICE logging.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the GCS target configuration validation logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupGCSTargetSettingsValidation {
<#
.SYNOPSIS
    Validates the configuration settings for a GCS target instance.
.DESCRIPTION
    This function checks a GCS target definition from the main configuration to ensure
    all required keys are present and have the correct data types. It adds detailed
    error messages to the main validation list if issues are found.
.PARAMETER TargetInstanceConfiguration
    The complete configuration hashtable for a single GCS target instance.
.PARAMETER TargetInstanceName
    The name of the target instance being validated, used for logging and error messages.
.PARAMETER ValidationMessagesListRef
    A reference to a List[string] where any validation error messages will be added.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "GCS.SettingsValidator: Logger active. Validating settings for GCS Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $addValidationError = {
        param($errorMessage, $adviceMessage = $null)
        if (-not ($ValidationMessagesListRef.Value -contains $errorMessage)) { $ValidationMessagesListRef.Value.Add($errorMessage) }
        if ($null -ne $adviceMessage -and -not ($ValidationMessagesListRef.Value -contains $adviceMessage)) { $ValidationMessagesListRef.Value.Add($adviceMessage) }
    }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        & $addValidationError -errorMessage "GCS Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable." -adviceMessage "ADVICE: Please ensure the settings for this target are enclosed in a proper hashtable, e.g., TargetSpecificSettings = @{ ... }"
        return
    }

    if (-not $TargetSpecificSettings.ContainsKey('BucketName') -or -not ($TargetSpecificSettings.BucketName -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.BucketName)) {
        & $addValidationError -errorMessage "GCS Target '$TargetInstanceName': 'BucketName' in 'TargetSpecificSettings' is missing or empty." -adviceMessage "ADVICE: Please specify the name of your Google Cloud Storage bucket."
    }
    if ($TargetSpecificSettings.ContainsKey('ServiceAccountKeyFileSecretName') -and -not ($TargetSpecificSettings.ServiceAccountKeyFileSecretName -is [string])) {
        & $addValidationError -errorMessage "GCS Target '$TargetInstanceName': 'ServiceAccountKeyFileSecretName' must be a string if defined."
    }
    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        & $addValidationError -errorMessage "GCS Target '$TargetInstanceName': 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined."
    }

    if ($null -ne $RemoteRetentionSettings -and $RemoteRetentionSettings.ContainsKey('KeepCount')) {
        if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
            & $addValidationError -errorMessage "GCS Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined."
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupGCSTargetSettingsValidation
