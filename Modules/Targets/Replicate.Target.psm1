# Modules\Targets\Replicate.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for replicating a backup archive to multiple destinations.
    Each destination can be a local path or a UNC path and can have its own
    subdirectory creation and retention settings.
    Now includes a function for validating its specific TargetSpecificSettings.

.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for replicating
    a single backup archive to several specified locations. The core function,
    'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup operations
    module when a backup job is configured to use a target of type "Replicate".

    The provider performs the following actions for each destination defined in its configuration:
    -   Retrieves the destination path (local or UNC).
    -   Determines if a job-specific subdirectory should be created under that path.
    -   Ensures the final destination directory exists, creating it if necessary.
    -   Copies the local backup archive file to this specific destination.
    -   If retention settings (e.g., 'KeepCount') are defined for this specific destination,
        it applies a count-based retention policy to archives for the current job within
        that destination directory.
    -   Supports simulation mode for all operations.
    -   Returns a consolidated status. The overall success requires all configured replications
        to succeed. Detailed information about each individual replication attempt is also
        returned for comprehensive reporting.

    A new function, 'Invoke-PoShBackupReplicateTargetSettingsValidation', is now included to validate
    the 'TargetSpecificSettings' specific to this Replicate provider. This function is intended to be
    called by the PoShBackupValidator module.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added Invoke-PoShBackupReplicateTargetSettingsValidation function.
    DateCreated:    19-May-2025
    LastModified:   27-May-2025
    Purpose:        Replicate Target Provider for PoSh-Backup, allowing one-to-many archive distribution.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on all configured destination paths.
#>

#region --- Private Helper: Format Bytes ---
# Internal helper function to format byte sizes into human-readable strings (KB, MB, GB).
function Format-BytesInternal-Replicate {
    param(
        [Parameter(Mandatory=$true)]
        [long]$Bytes
    )
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion

#region --- Replicate Target Settings Validation Function ---
function Invoke-PoShBackupReplicateTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$TargetSpecificSettings, # For Replicate, this is an array of destination configs
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, # Expects a [System.Collections.Generic.List[string]]
        [Parameter(Mandatory = $false)] # Optional logger, if needed for complex validation logging
        [scriptblock]$Logger
    )

    # PSSA: Logger parameter used if provided
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "Replicate.Target/Invoke-PoShBackupReplicateTargetSettingsValidation: Validating settings for Replicate Target '$TargetInstanceName'." -Level "DEBUG"
    }

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"

    if (-not ($TargetSpecificSettings -is [array])) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' must be an Array of destination configurations, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return # Cannot proceed if not an array
    }
    if ($TargetSpecificSettings.Count -eq 0) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$fullPathToSettings'.")
    }

    for ($i = 0; $i -lt $TargetSpecificSettings.Count; $i++) {
        $destConfig = $TargetSpecificSettings[$i]
        $destConfigPath = "$fullPathToSettings[$i]"

        if (-not ($destConfig -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'.")
            continue # Skip to next item in the array
        }

        if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i is missing 'Path', or it's not a non-empty string. Path: '$destConfigPath.Path'.")
        }

        if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined. Path: '$destConfigPath.CreateJobNameSubdirectory'.")
        }

        if ($destConfig.ContainsKey('RetentionSettings')) {
            if (-not ($destConfig.RetentionSettings -is [hashtable])) {
                $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'RetentionSettings' must be a Hashtable if defined. Path: '$destConfigPath.RetentionSettings'.")
            }
            elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount')) {
                if (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0) {
                    $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'RetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$destConfigPath.RetentionSettings.KeepCount'.")
                }
            }
            # Add checks for other RetentionSettings keys if they are introduced
        }
    }
}
#endregion

#region --- Replicate Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LocalArchivePath,
        [Parameter(Mandatory=$true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveFileName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory=$true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory=$true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory=$true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory=$true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory=$true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet # Added for ShouldProcess
    )

    # Defensive PSSA appeasement line: Directly use the $Logger parameter once.
    & $Logger -Message "Replicate.Target/Invoke-PoShBackupTargetTransfer: Logger parameter received for Job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    # PSSA: Logger parameter used via $LocalWriteLog
    & $LocalWriteLog -Message "Replicate.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName', Target '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG"

    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message "`n[INFO] Replicate Target: Starting replication for Job '$JobName' using Target Instance '$targetNameForLog'." -Level "INFO"
    & $LocalWriteLog -Message "  - Replicate Target: Local source archive: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Source Archive Size: $(Format-BytesInternal-Replicate -Bytes $LocalArchiveSizeBytes)" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Source Archive Created: $LocalArchiveCreationTimestamp" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Source Archive Password Protected: $PasswordInUse" -Level "DEBUG"
    # PSSA: Using EffectiveJobConfig
    & $LocalWriteLog -Message "    - Effective Job Name (from EffectiveJobConfig): $($EffectiveJobConfig.JobName)" -Level "DEBUG"


    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allReplicationsSucceeded = $true
    $aggregatedErrorMessages = [System.Collections.Generic.List[string]]::new()
    $replicationDetailsList = [System.Collections.Generic.List[hashtable]]::new()
    $firstSuccessfulRemotePath = $null

    if (-not $TargetInstanceConfiguration.TargetSpecificSettings -is [array] -or $TargetInstanceConfiguration.TargetSpecificSettings.Count -eq 0) {
        $overallStopwatch.Stop()
        $errorMessageText = "Replicate Target '$targetNameForLog': 'TargetSpecificSettings' must be a non-empty array of destination configurations."
        & $LocalWriteLog -Message "[ERROR] $errorMessageText" -Level "ERROR"
        return @{
            Success          = $false
            RemotePath       = "Configuration Error"
            ErrorMessage     = $errorMessageText
            TransferSize     = $LocalArchiveSizeBytes
            TransferDuration = $overallStopwatch.Elapsed
            ReplicationDetails = $replicationDetailsList
        }
    }
    $destinationConfigs = $TargetInstanceConfiguration.TargetSpecificSettings

    & $LocalWriteLog -Message "  - Replicate Target '$targetNameForLog': Will attempt to replicate to $($destinationConfigs.Count) destination(s)." -Level "INFO"

    foreach ($destConfig in $destinationConfigs) {
        $singleDestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Initialize variables for this destination iteration
        $currentDestErrorMessage = $null
        $currentDestSuccess = $false
        $currentDestTransferSize = 0
        $currentFullDestArchivePath = "N/A (Path not determined)" # Default for reporting if path cannot be resolved

        if (-not ($destConfig -is [hashtable])) {
            $currentDestErrorMessage = "Invalid destination configuration item (not a hashtable) within TargetSpecificSettings for '$targetNameForLog'."
            & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
            $allReplicationsSucceeded = $false
            $aggregatedErrorMessages.Add($currentDestErrorMessage)
            $singleDestStopwatch.Stop()
            $replicationDetailsList.Add(@{ Path = "Invalid Config Item"; Status = "Failure"; Error = $currentDestErrorMessage; Size = 0; Duration = $singleDestStopwatch.Elapsed })
            continue
        }

        $currentDestPathRaw = $destConfig.Path
        if ([string]::IsNullOrWhiteSpace($currentDestPathRaw)) {
            $currentDestErrorMessage = "Destination 'Path' is missing or empty in one of the TargetSpecificSettings items for '$targetNameForLog'."
            & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
            $allReplicationsSucceeded = $false
            $aggregatedErrorMessages.Add($currentDestErrorMessage)
            $singleDestStopwatch.Stop()
            $replicationDetailsList.Add(@{ Path = "Missing Path in Config"; Status = "Failure"; Error = $currentDestErrorMessage; Size = 0; Duration = $singleDestStopwatch.Elapsed })
            continue
        }
        $currentDestPathBase = $currentDestPathRaw.TrimEnd("\/")
        $currentDestCreateJobSubDir = if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and $destConfig.CreateJobNameSubdirectory -is [boolean]) {
            $destConfig.CreateJobNameSubdirectory
        } else {
            $false
        }

        $currentDestFinalDir = if ($currentDestCreateJobSubDir) {
            Join-Path -Path $currentDestPathBase -ChildPath $JobName
        } else {
            $currentDestPathBase
        }
        $currentFullDestArchivePath = Join-Path -Path $currentDestFinalDir -ChildPath $ArchiveFileName # This is now correctly set before potential early exit

        & $LocalWriteLog -Message "    - Replicate Target '$targetNameForLog': Processing destination: '$currentDestPathBase' (Subdir: $currentDestCreateJobSubDir, Final Archive Path: '$currentFullDestArchivePath')" -Level "INFO"

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Replicate Target '$targetNameForLog': Would ensure directory exists: '$currentDestFinalDir'." -Level "SIMULATE"
            & $LocalWriteLog -Message "SIMULATE: Replicate Target '$targetNameForLog': Would copy '$LocalArchivePath' to '$currentFullDestArchivePath'." -Level "SIMULATE"
            $currentDestSuccess = $true
            $currentDestTransferSize = $LocalArchiveSizeBytes
            if ($null -eq $firstSuccessfulRemotePath) { $firstSuccessfulRemotePath = $currentFullDestArchivePath }
        } else {
            if (-not $PSCmdlet.ShouldProcess($currentDestFinalDir, "Ensure Destination Directory Exists for Replication")) {
                $currentDestErrorMessage = "Replicate Target '$targetNameForLog': Directory creation/check at '$currentDestFinalDir' skipped by user (ShouldProcess)."
                & $LocalWriteLog -Message "[WARNING] $currentDestErrorMessage" -Level "WARNING"
                $allReplicationsSucceeded = $false
                $aggregatedErrorMessages.Add($currentDestErrorMessage)
            } else {
                if (-not (Test-Path -LiteralPath $currentDestFinalDir -PathType Container)) {
                    & $LocalWriteLog -Message "      - Replicate Target '$targetNameForLog': Destination directory '$currentDestFinalDir' does not exist. Attempting to create." -Level "INFO"
                    try {
                        New-Item -Path $currentDestFinalDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Successfully created destination directory '$currentDestFinalDir'." -Level "SUCCESS"
                    } catch {
                        $currentDestErrorMessage = "Replicate Target '$targetNameForLog': Failed to create destination directory '$currentDestFinalDir'. Error: $($_.Exception.Message)"
                        & $LocalWriteLog -Message "[ERROR] $currentDestErrorMessage" -Level "ERROR"
                        $allReplicationsSucceeded = $false
                        $aggregatedErrorMessages.Add($currentDestErrorMessage)
                    }
                }
            }

            if ($null -eq $currentDestErrorMessage) {
                if (-not $PSCmdlet.ShouldProcess($currentFullDestArchivePath, "Replicate Archive to Destination")) {
                    $currentDestErrorMessage = "Replicate Target '$targetNameForLog': Archive copy to '$currentFullDestArchivePath' skipped by user (ShouldProcess)."
                    & $LocalWriteLog -Message "[WARNING] $currentDestErrorMessage" -Level "WARNING"
                    $allReplicationsSucceeded = $false
                    $aggregatedErrorMessages.Add($currentDestErrorMessage)
                } else {
                    & $LocalWriteLog -Message "      - Replicate Target '$targetNameForLog': Copying archive from '$LocalArchivePath' to '$currentFullDestArchivePath'..." -Level "INFO"
                    try {
                        Copy-Item -LiteralPath $LocalArchivePath -Destination $currentFullDestArchivePath -Force -ErrorAction Stop
                        $currentDestSuccess = $true
                        if (Test-Path -LiteralPath $currentFullDestArchivePath -PathType Leaf) {
                            $currentDestTransferSize = (Get-Item -LiteralPath $currentFullDestArchivePath).Length
                        }
                        if ($null -eq $firstSuccessfulRemotePath) { $firstSuccessfulRemotePath = $currentFullDestArchivePath }
                        & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Archive copied successfully to '$currentFullDestArchivePath'." -Level "SUCCESS"
                    } catch {
                        $currentDestErrorMessage = "Replicate Target '$targetNameForLog': Failed to copy archive to '$currentFullDestArchivePath'. Error: $($_.Exception.Message)"
                        & $LocalWriteLog -Message "[ERROR] $currentDestErrorMessage" -Level "ERROR"
                        $allReplicationsSucceeded = $false
                        $aggregatedErrorMessages.Add($currentDestErrorMessage)
                    }
                }
            }
        }

        if ($currentDestSuccess -and $destConfig.ContainsKey('RetentionSettings') -and $destConfig.RetentionSettings -is [hashtable] -and `
            $destConfig.RetentionSettings.ContainsKey('KeepCount') -and $destConfig.RetentionSettings.KeepCount -is [int] -and `
            $destConfig.RetentionSettings.KeepCount -gt 0) {

            $destKeepCount = $destConfig.RetentionSettings.KeepCount
            & $LocalWriteLog -Message "      - Replicate Target '$targetNameForLog': Applying retention (KeepCount: $destKeepCount) in directory '$currentDestFinalDir'." -Level "INFO"

            $literalBaseNameForDest = $ArchiveBaseName -replace '\*', '`*' -replace '\?', '`?'
            $destFilePattern = "$($literalBaseNameForDest)*$($ArchiveExtension)"

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Replicate Target '$targetNameForLog': Would list files matching '$destFilePattern' in '$currentDestFinalDir' and delete oldest exceeding $destKeepCount." -Level "SIMULATE"
            } else {
                try {
                    if (-not (Test-Path -LiteralPath $currentDestFinalDir -PathType Container)) {
                        & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Directory '$currentDestFinalDir' not found for retention. Skipping retention for this destination." -Level "WARNING"
                    } else {
                        $existingDestBackups = Get-ChildItem -Path $currentDestFinalDir -Filter $destFilePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending
                        if (($null -ne $existingDestBackups) -and ($existingDestBackups.Count -gt $destKeepCount)) {
                            $destBackupsToDelete = $existingDestBackups | Select-Object -Skip $destKeepCount
                            & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Found $($existingDestBackups.Count) archives at '$currentDestFinalDir'. Will attempt to delete $($destBackupsToDelete.Count) older archive(s)." -Level "INFO"
                            foreach ($destBackupFile in $destBackupsToDelete) {
                                if (-not $PSCmdlet.ShouldProcess($destBackupFile.FullName, "Delete Archive (Replication Retention)")) {
                                    & $LocalWriteLog -Message "          - Replicate Target '$targetNameForLog': Deletion of '$($destBackupFile.FullName)' skipped by user (ShouldProcess)." -Level "WARNING"
                                    continue
                                }
                                & $LocalWriteLog -Message "          - Replicate Target '$targetNameForLog': Deleting for retention: '$($destBackupFile.FullName)'" -Level "WARNING"
                                try {
                                    Remove-Item -LiteralPath $destBackupFile.FullName -Force -ErrorAction Stop
                                    & $LocalWriteLog -Message "            - Status: DELETED (Replication Retention)" -Level "SUCCESS"
                                } catch {
                                    $retentionErrorMessageText = "Failed to delete archive '$($destBackupFile.FullName)' for retention. Error: $($_.Exception.Message)"
                                    & $LocalWriteLog -Message "            - Status: FAILED! $retentionErrorMessageText" -Level "ERROR"
                                    $aggregatedErrorMessages.Add("Replicate Target '$targetNameForLog' (dest: '$currentDestPathBase'): $retentionErrorMessageText")
                                    $allReplicationsSucceeded = $false
                                    $currentDestSuccess = $false
                                    if ($null -eq $currentDestErrorMessage) { $currentDestErrorMessage = $retentionErrorMessageText } else { $currentDestErrorMessage += "; $retentionErrorMessageText" }
                                }
                            }
                        } else {
                            & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': No old archives to delete at '$currentDestFinalDir' based on retention count $destKeepCount." -Level "INFO"
                        }
                    }
                } catch {
                    $retentionSetupErrorText = "Error during retention setup for '$currentDestFinalDir'. Error: $($_.Exception.Message)"
                    & $LocalWriteLog -Message "[WARNING] Replicate Target '$targetNameForLog': $retentionSetupErrorText" -Level "WARNING"
                    $aggregatedErrorMessages.Add("Replicate Target '$targetNameForLog' (dest: '$currentDestPathBase'): $retentionSetupErrorText")
                    $allReplicationsSucceeded = $false
                    $currentDestSuccess = $false
                    if ($null -eq $currentDestErrorMessage) { $currentDestErrorMessage = $retentionSetupErrorText } else { $currentDestErrorMessage += "; $retentionSetupErrorText" }
                }
            }
        }
        $singleDestStopwatch.Stop()
        $replicationDetailsList.Add(@{
            Path            = $currentFullDestArchivePath
            Status          = if ($currentDestSuccess) { "Success" } else { "Failure" }
            Error           = $currentDestErrorMessage
            Size            = $currentDestTransferSize
            Duration        = $singleDestStopwatch.Elapsed
        })

        if (-not $currentDestSuccess) {
            $allReplicationsSucceeded = $false
        }
    }

    $overallStopwatch.Stop()
    $finalRemotePathDisplay = if ($allReplicationsSucceeded -and $replicationDetailsList.Count -gt 0) {
        if ($replicationDetailsList.Count -eq 1) {
            $firstSuccessfulRemotePath
        } else {
            "Replicated to $($replicationDetailsList.Count) locations successfully."
        }
    } elseif ($replicationDetailsList.Count -gt 0 -and $null -ne $firstSuccessfulRemotePath) {
        "Partially replicated (see details); first success: $firstSuccessfulRemotePath"
    } else {
        "Replication failed or no valid destinations processed."
    }

    & $LocalWriteLog -Message "[INFO] Replicate Target: Finished all replication attempts for Job '$JobName', Target '$targetNameForLog'. Overall Success: $allReplicationsSucceeded." -Level "INFO"

    return @{
        Success             = $allReplicationsSucceeded
        RemotePath          = $finalRemotePathDisplay
        ErrorMessage        = if ($aggregatedErrorMessages.Count -gt 0) { $aggregatedErrorMessages -join "; " } else { $null }
        TransferSize        = $LocalArchiveSizeBytes
        TransferDuration    = $overallStopwatch.Elapsed
        ReplicationDetails  = $replicationDetailsList
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupReplicateTargetSettingsValidation
