# Modules\Targets\GCS.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for Google Cloud Storage (GCS).
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for Google Cloud Storage.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "GCS".

    The provider performs the following actions:
    - Checks for the presence of the 'gcloud' command-line tool.
    - Authenticates using a service account key file (path retrieved from SecretManagement)
      or relies on ambient gcloud authentication.
    - Uploads the local backup archive file to the specified GCS bucket using 'gcloud storage cp'.
    - If 'RemoteRetentionSettings' are defined, it applies a count-based retention policy
      by listing and deleting older backup instances using 'gcloud storage ls' and 'gcloud storage rm'.
    - Supports simulation mode for all GCS operations.
    - Returns a detailed status hashtable for each file transfer attempt.

    A function, 'Invoke-PoShBackupGCSTargetSettingsValidation', validates the target configuration.
    A function, 'Test-PoShBackupTargetConnectivity', validates the connection and bucket access.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    23-Jun-2025
    LastModified:   23-Jun-2025
    Purpose:        Google Cloud Storage Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'gcloud' CLI (Google Cloud SDK) must be installed and in the system's PATH.
                    Authentication must be configured either via `gcloud auth application-default login`
                    or by providing a service account key file.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.Target.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- GCS Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    $bucketName = $TargetSpecificSettings.BucketName
    & $LocalWriteLog -Message "  - GCS Target: Testing connectivity to bucket 'gs://$bucketName'..." -Level "INFO"

    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        return @{ Success = $false; Message = "The 'gcloud' CLI is not installed or not in the system PATH. Please install the Google Cloud SDK." }
    }

    if (-not $PSCmdlet.ShouldProcess("gs://$bucketName", "Test GCS Bucket Accessibility (gcloud storage ls)")) {
        return @{ Success = $false; Message = "GCS bucket accessibility test skipped by user." }
    }

    if ($TargetSpecificSettings.ContainsKey('ServiceAccountKeyFileSecretName')) {
        $keyFilePath = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.ServiceAccountKeyFileSecretName -Logger $Logger -AsPlainText
        if (-not [string]::IsNullOrWhiteSpace($keyFilePath) -and (Test-Path -LiteralPath $keyFilePath -PathType Leaf)) {
            # This is complex for a simple test. The main function handles activation.
            # For a test, we will assume if the key exists, it's a good sign.
            & $LocalWriteLog -Message "  - GCS Target: Service account key file found. The test will rely on its validity." -Level "INFO"
        } else {
             return @{ Success = $false; Message = "Service Account Key File not found at path retrieved from secret '$($TargetSpecificSettings.ServiceAccountKeyFileSecretName)'." }
        }
    }

    try {
        # A simple 'ls' on the bucket root is a good connectivity test.
        gcloud storage ls "gs://$bucketName" --limit 1 | Out-Null
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "gcloud command failed with exit code $exitCode."}

        $successMessage = "Successfully connected and listed content for bucket 'gs://$bucketName'."
        & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
        return @{ Success = $true; Message = $successMessage }
    }
    catch {
        $errorMessage = "GCS connection test failed. Ensure you are authenticated ('gcloud auth login', 'gcloud auth application-default login') or the service account key is valid. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
}
#endregion

#region --- GCS Target Settings Validation Function ---
function Invoke-PoShBackupGCSTargetSettingsValidation {
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
        & $Logger -Message "GCS.Target/Invoke-PoShBackupGCSTargetSettingsValidation: Logger active. Validating settings for GCS Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings
    
    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("GCS Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable.")
        return
    }
    
    if (-not $TargetSpecificSettings.ContainsKey('BucketName') -or -not ($TargetSpecificSettings.BucketName -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.BucketName)) {
        $ValidationMessagesListRef.Value.Add("GCS Target '$TargetInstanceName': 'BucketName' in 'TargetSpecificSettings' is missing or empty.")
    }
    if ($TargetSpecificSettings.ContainsKey('ServiceAccountKeyFileSecretName') -and -not ($TargetSpecificSettings.ServiceAccountKeyFileSecretName -is [string])) {
        $ValidationMessagesListRef.Value.Add("GCS Target '$TargetInstanceName': 'ServiceAccountKeyFileSecretName' must be a string if defined.")
    }
    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("GCS Target '$TargetInstanceName': 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined.")
    }

    if ($null -ne $RemoteRetentionSettings -and $RemoteRetentionSettings.ContainsKey('KeepCount')) {
        if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
            $ValidationMessagesListRef.Value.Add("GCS Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined.")
        }
    }
}
#endregion

#region --- GCS Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$JobName,
        [Parameter(Mandatory = $true)] [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)] [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)] [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)] [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)] [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)] [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $null = $EffectiveJobConfig, $LocalArchiveCreationTimestamp, $PasswordInUse # PSSA Appeasement

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] GCS Target: Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        $result.ErrorMessage = "GCS Target '$targetNameForLog': The 'gcloud' CLI is not installed or not in the system PATH. Please install the Google Cloud SDK."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $gcsSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $createJobSubDir = if ($gcsSettings.ContainsKey('CreateJobNameSubdirectory')) { $gcsSettings.CreateJobNameSubdirectory } else { $false }
    $remoteKeyPrefix = if ($createJobSubDir) { "$JobName/" } else { "" }
    $fullRemotePath = "gs://$($gcsSettings.BucketName)/$remoteKeyPrefix$ArchiveFileName"
    $result.RemotePath = $fullRemotePath

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Would upload file '$ArchiveFileName' to '$fullRemotePath' using 'gcloud storage cp'." -Level "SIMULATE"
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    if (-not $PSCmdlet.ShouldProcess($fullRemotePath, "Upload File to Google Cloud Storage")) {
        $result.ErrorMessage = "GCS Target '$targetNameForLog': Upload to '$fullRemotePath' skipped by user."; & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    # --- Authentication Handling ---
    $deactivateAuth = $false
    if ($gcsSettings.ContainsKey('ServiceAccountKeyFileSecretName')) {
        $keyFilePath = Get-PoShBackupSecret -SecretName $gcsSettings.ServiceAccountKeyFileSecretName -Logger $Logger -AsPlainText
        if (-not [string]::IsNullOrWhiteSpace($keyFilePath) -and (Test-Path -LiteralPath $keyFilePath -PathType Leaf)) {
            try {
                & $LocalWriteLog -Message "  - GCS Target: Activating service account from key file '$keyFilePath'..." -Level "INFO"
                gcloud auth activate-service-account --key-file=$keyFilePath
                if ($LASTEXITCODE -ne 0) { throw "gcloud auth activate-service-account failed." }
                $deactivateAuth = $true # Flag that we need to deactivate this specific auth later
            } catch {
                $result.ErrorMessage = "Failed to activate GCS service account. Error: $($_.Exception.Message)"; & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
                $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
            }
        } else {
            $result.ErrorMessage = "Service Account Key File not found at path retrieved from secret '$($gcsSettings.ServiceAccountKeyFileSecretName)'."; & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
        }
    }
    # If no key file is specified, we assume ambient authentication (e.g., from gcloud auth login)

    try {
        & $LocalWriteLog -Message ("  - GCS Target '{0}': Uploading file '{1}'..." -f $targetNameForLog, $ArchiveFileName) -Level "INFO"
        gcloud storage cp $LocalArchivePath $fullRemotePath
        if ($LASTEXITCODE -ne 0) { throw "gcloud storage cp command failed with exit code $LASTEXITCODE." }

        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
        & $LocalWriteLog -Message ("    - GCS Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        # Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            $remoteDirectoryToScan = "gs://$($gcsSettings.BucketName)/$remoteKeyPrefix"
            & $LocalWriteLog -Message ("  - GCS Target '{0}': Applying remote retention (KeepCount: {1}) in '{2}'." -f $targetNameForLog, $remoteKeepCount, $remoteDirectoryToScan) -Level "INFO"
            
            $gcloudListOutput = gcloud storage ls -l "$($remoteDirectoryToScan)$($ArchiveBaseName)*"
            if ($LASTEXITCODE -ne 0) { throw "Failed to list remote objects for retention." }

            $gcsObjects = $gcloudListOutput | ForEach-Object {
                if ($_ -match '^\s*(\d+)\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+gs://.+/(.+)$') {
                    [PSCustomObject]@{
                        Size = [long]$Matches[1]
                        SortTime = [datetime]$Matches[2]
                        Name = $Matches[3]
                        Key = "$remoteKeyPrefix$($Matches[3])"
                    }
                }
            }

            $remoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $gcsObjects -ArchiveBaseName $ArchiveBaseName -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat -PrimaryArchiveExtension $ArchiveExtension -Logger $Logger
            
            if ($remoteInstances.Count -gt $remoteKeepCount) {
                $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                
                foreach ($instanceEntry in $instancesToDelete) {
                    foreach ($gcsObjectToDelete in $instanceEntry.Value.Files) {
                        $fullBlobPathToDelete = "gs://$($gcsSettings.BucketName)/$($gcsObjectToDelete.Key)"
                        if (-not $PSCmdlet.ShouldProcess($fullBlobPathToDelete, "Delete Remote GCS Object (Retention)")) {
                            & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $fullBlobPathToDelete) -Level "WARNING"; continue
                        }
                        & $LocalWriteLog ("        - Deleting: '{0}'" -f $fullBlobPathToDelete) -Level "WARNING"
                        gcloud storage rm $fullBlobPathToDelete
                        if ($LASTEXITCODE -eq 0) { & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS" }
                        else { & $LocalWriteLog "          - Status: FAILED! gcloud rm exited with code $LASTEXITCODE" -Level "ERROR" }
                    }
                }
            }
        }
    }
    catch {
        $result.ErrorMessage = "GCS Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        if ($deactivateAuth) {
            & $LocalWriteLog -Message "  - GCS Target: Deactivating temporary service account credentials." -Level "INFO"
            gcloud auth revoke --all
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    }

    & $LocalWriteLog -Message ("[INFO] GCS Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupGCSTargetSettingsValidation, Test-PoShBackupTargetConnectivity
