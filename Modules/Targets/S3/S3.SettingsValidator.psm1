# Modules\Targets\S3\S3.SettingsValidator.psm1
<#
.SYNOPSIS
    A sub-module for S3.Target.psm1. Handles configuration validation.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupS3TargetSettingsValidation' function. It is
    responsible for validating the structure and values within the TargetSpecificSettings
    and RemoteRetentionSettings for an S3 target definition.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the S3 target configuration validation logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupS3TargetSettingsValidation {
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
        & $Logger -Message "S3.SettingsValidator: Logger active. Validating settings for S3 Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }

    if ($TargetSpecificSettings.ContainsKey('ServiceUrl') -and -not ($TargetSpecificSettings.ServiceUrl -is [string])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'ServiceUrl' in 'TargetSpecificSettings' must be a string if defined. Path: '$fullPathToSettings.ServiceUrl'.")
    }

    foreach ($s3Key in @('Region', 'BucketName', 'AccessKeySecretName', 'SecretKeySecretName')) {
        if (-not $TargetSpecificSettings.ContainsKey($s3Key) -or -not ($TargetSpecificSettings.$s3Key -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$s3Key)) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': '$s3Key' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.$s3Key'.")
        }
    }

    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.CreateJobNameSubdirectory'.")
    }

    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupS3TargetSettingsValidation
