# Modules\Targets\UNC.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for UNC (Universal Naming Convention) paths.
    Handles transferring backup archives (including individual volumes and manifest files)
    to network shares and managing retention on those shares.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for UNC path destinations.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "UNC".
    It is now called for each file part of a backup set (volumes, manifest).

    The provider performs the following actions:
    -   Retrieves the target UNC path.
    -   Ensures the final remote destination directory (potentially including a job-specific
        subdirectory) exists.
    -   Copies the specific local archive file (volume part or manifest) to this destination.
    -   If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, it applies a
        count-based retention policy. This policy now correctly identifies all related files
        of a backup instance (all volumes and any manifest) for deletion.
    -   Supports simulation mode.
    -   Returns a status for the individual file transfer.

    A function, 'Invoke-PoShBackupUNCTargetSettingsValidation', validates 'TargetSpecificSettings'.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Updated retention logic for multi-volume and manifest files.
    DateCreated:    19-May-2025
    LastModified:   01-Jun-2025
    Purpose:        UNC Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on the target UNC path.
#>

#region --- Private Helper: Format Bytes ---
function Format-BytesInternal {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion

#region --- Private Helper: Ensure Remote Path Exists ---
function Initialize-RemotePathInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [scriptblock]$Logger,
        [Parameter(Mandatory)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "UNC.Target/Initialize-RemotePathInternal: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        & $LocalWriteLog -Message "  - Ensure-RemotePath: Path '$Path' already exists." -Level "DEBUG"
        return @{ Success = $true }
    }
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Ensure-RemotePath: Would ensure path '$Path' exists (creating if necessary)." -Level "SIMULATE"
        return @{ Success = $true }
    }
    $pathComponents = $Path.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($Path.StartsWith("\\")) {
        if ($pathComponents.Count -lt 2) {
            return @{ Success = $false; ErrorMessage = "Invalid UNC path structure: '$Path'. Needs at least server and share." }
        }
        $baseSharePath = "\\$($pathComponents[0])\$($pathComponents[1])"
        if (-not $PSCmdletInstance.ShouldProcess($baseSharePath, "Test UNC Share Accessibility")) {
            return @{ Success = $false; ErrorMessage = "UNC Share accessibility test for '$baseSharePath' skipped by user." }
        }
        if (-not (Test-Path -LiteralPath $baseSharePath -PathType Container)) {
            return @{ Success = $false; ErrorMessage = "Base UNC share '$baseSharePath' not found or inaccessible." }
        }
        $currentPathToBuild = $baseSharePath
        for ($i = 2; $i -lt $pathComponents.Count; $i++) {
            $currentPathToBuild = Join-Path -Path $currentPathToBuild -ChildPath $pathComponents[$i]
            if (-not (Test-Path -LiteralPath $currentPathToBuild -PathType Container)) {
                if (-not $PSCmdletInstance.ShouldProcess($currentPathToBuild, "Create Remote Directory Component")) {
                    return @{ Success = $false; ErrorMessage = "Directory component creation for '$currentPathToBuild' skipped by user." }
                }
                & $LocalWriteLog -Message "  - Ensure-RemotePath: Creating directory component '$currentPathToBuild'." -Level "INFO"
                try { New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                catch { return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" } }
            }
        }
    } else {
        $currentPathToBuild = ""
        if ($pathComponents[0] -match '^[a-zA-Z]:$') { $currentPathToBuild = $pathComponents[0] + [System.IO.Path]::DirectorySeparatorChar; $startIndex = 1 }
        else { $startIndex = 0 }
        for ($i = $startIndex; $i -lt $pathComponents.Count; $i++) {
            if ($currentPathToBuild -eq "" -and $i -eq 0) { $currentPathToBuild = $pathComponents[$i] }
            else { $currentPathToBuild = Join-Path -Path $currentPathToBuild -ChildPath $pathComponents[$i] }
            if (-not (Test-Path -LiteralPath $currentPathToBuild -PathType Container)) {
                if (-not $PSCmdletInstance.ShouldProcess($currentPathToBuild, "Create Local Directory Component")) {
                    return @{ Success = $false; ErrorMessage = "Directory component creation for '$currentPathToBuild' skipped by user." }
                }
                & $LocalWriteLog -Message "  - Ensure-RemotePath: Creating directory component '$currentPathToBuild'." -Level "INFO"
                try { New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                catch { return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" } }
            }
        }
    }
    return @{ Success = $true }
}
#endregion

#region --- Private Helper: Group Remote Files by Instance ---
function Group-RemoteUNCBackupInstancesInternal {
    param(
        [string]$Directory,
        [string]$BaseNameToMatch, # e.g., "JobName [DateStamp]"
        [string]$PrimaryArchiveExtension, # e.g., ".7z" (the one before .001 or .manifest)
        [scriptblock]$Logger
    )

    # PSSA Appeasement and initial log entry:
    & $Logger -Message "UNC.Target/Group-RemoteUNCBackupInstancesInternal: Logger active. Scanning '$Directory' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Define LocalWriteLog for subsequent use within this function if needed.
    # Based on the previous file content, $LocalWriteLog is used later in this function.
    $LocalWriteLog = { param([string]$Message, [string]$Level = "DEBUG") & $Logger -Message $Message -Level $Level }
   
    $instances = @{}
    $literalBase = [regex]::Escape($BaseNameToMatch)
    $literalExt = [regex]::Escape($PrimaryArchiveExtension)

    # Pattern to identify the core instance name from various file types
    # 1. Volume: (JobName [DateStamp].7z).001 -> $Matches[1] = "JobName [DateStamp].7z"
    # 2. Manifest: (JobName [DateStamp].7z).manifest.algo -> $Matches[1] = "JobName [DateStamp].7z"
    # 3. Single file: (JobName [DateStamp].7z) -> $Matches[1] = "JobName [DateStamp].7z"
    $instancePattern = "^($literalBase$literalExt)(?:\.\d{3,}|\.manifest\.[a-zA-Z0-9]+)?$"

    Get-ChildItem -Path $Directory -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match $instancePattern) {
            $instanceKey = $Matches[1] # This is "JobName [DateStamp].<PrimaryExtension>"
            if (-not $instances.ContainsKey($instanceKey)) {
                # Determine sort time. Prefer .001, then manifest, then the file itself.
                $sortTime = $_.CreationTime
                if ($_.Name -match "$literalExt\.001$") { # If it's the first volume part
                    $sortTime = $_.CreationTime
                } elseif ($instances.ContainsKey($instanceKey) && $instances[$instanceKey].SortTime -ne $_.CreationTime) {
                    # If instance already exists, and this isn't the first part, keep existing sort time unless this is earlier
                    # This logic might need refinement if .001 isn't always the first found/oldest.
                    # For simplicity, we'll use the CreationTime of the first file encountered that forms the instanceKey,
                    # or specifically the .001 file if present.
                    if ($_.CreationTime -lt $instances[$instanceKey].SortTime) {
                        $sortTime = $_.CreationTime
                    } else {
                        $sortTime = $instances[$instanceKey].SortTime
                    }
                }
                $instances[$instanceKey] = @{ SortTime = $sortTime; Files = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
            }
            $instances[$instanceKey].Files.Add($_)
            # Refine SortTime if this is the .001 part and it's earlier than previously assumed sort time
            if ($_.Name -match "$literalExt\.001$") {
                if ($_.CreationTime -lt $instances[$instanceKey].SortTime) {
                    $instances[$instanceKey].SortTime = $_.CreationTime
                }
            }
        }
    }
    & $LocalWriteLog -Message "UNC.Target/Group-RemoteUNCBackupInstancesInternal: Found $($instances.Keys.Count) distinct instances."
    return $instances
}
#endregion

#region --- UNC Target Settings Validation Function ---
function Invoke-PoShBackupUNCTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, 
        [Parameter(Mandatory = $false)] 
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "UNC.Target/Invoke-PoShBackupUNCTargetSettingsValidation: Logger active. Validating settings for UNC Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }
    if (-not $TargetSpecificSettings.ContainsKey('UNCRemotePath') -or -not ($TargetSpecificSettings.UNCRemotePath -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.UNCRemotePath)) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'UNCRemotePath' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.UNCRemotePath'.")
    }
    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.CreateJobNameSubdirectory'.")
    }
}
#endregion

#region --- UNC Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalArchivePath, # Path to the specific local file part (volume or manifest)
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileName, # Name of the specific file part (e.g., archive.7z.001 or archive.manifest)
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName, # Base name of the archive set (e.g., JobName [DateStamp])
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension, # Primary extension (e.g., .7z or .exe)
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig, # Full effective job config
        [Parameter(Mandatory = $true)]
        [long]$LocalArchiveSizeBytes, # Size of the specific $LocalArchivePath file
        [Parameter(Mandatory = $true)]
        [datetime]$LocalArchiveCreationTimestamp, # Creation time of $LocalArchivePath
        [Parameter(Mandatory = $true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet 
    )

    # PSSA Appeasement: Use the Logger, EffectiveJobConfig, LocalArchiveCreationTimestamp, PasswordInUse parameters
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "UNC.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName', Target Instance '$($TargetInstanceConfiguration._TargetInstanceName_)', File '$ArchiveFileName'." -Level "DEBUG" -ErrorAction SilentlyContinue
        & $Logger -Message ("  - UNC.Target Context (PSSA): EffectiveJobConfig.JobName='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $EffectiveJobConfig.JobName, $LocalArchiveCreationTimestamp, $PasswordInUse) -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_ 
    & $LocalWriteLog -Message "`n[INFO] UNC Target: Starting transfer of file '$ArchiveFileName' for Job '$JobName' to Target '$targetNameForLog'." -Level "INFO"

    $result = @{
        Success          = $false
        RemotePath       = $null # This will be the full path of the *specific file* transferred
        ErrorMessage     = $null
        TransferSize     = 0
        TransferDuration = New-TimeSpan
    }

    if (-not $TargetInstanceConfiguration.TargetSpecificSettings.ContainsKey('UNCRemotePath') -or `
            [string]::IsNullOrWhiteSpace($TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath)) {
        $result.ErrorMessage = "UNC Target '$targetNameForLog': 'UNCRemotePath' is missing or empty in TargetSpecificSettings."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        return $result
    }
    $uncRemoteBasePathFromConfig = $TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath.TrimEnd("\/")
    $createJobSubDir = $false 
    if ($TargetInstanceConfiguration.TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory')) {
        if ($TargetInstanceConfiguration.TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean]) {
            $createJobSubDir = $TargetInstanceConfiguration.TargetSpecificSettings.CreateJobNameSubdirectory
        } else {
            & $LocalWriteLog -Message "[WARNING] UNC Target '$targetNameForLog': 'CreateJobNameSubdirectory' in TargetSpecificSettings is not a boolean. Defaulting to `$false." -Level "WARNING"
        }
    }
    $remoteFinalDirectoryForArchiveSet = if ($createJobSubDir) { Join-Path -Path $uncRemoteBasePathFromConfig -ChildPath $JobName } else { $uncRemoteBasePathFromConfig }
    $fullRemoteArchivePathForThisFile = Join-Path -Path $remoteFinalDirectoryForArchiveSet -ChildPath $ArchiveFileName
    $result.RemotePath = $fullRemoteArchivePathForThisFile 

    $credentialsSecretName = $TargetInstanceConfiguration.CredentialsSecretName
    if (-not [string]::IsNullOrWhiteSpace($credentialsSecretName)) {
        & $LocalWriteLog -Message "[INFO] UNC Target '$targetNameForLog': CredentialsSecretName '$credentialsSecretName' specified (Feature placeholder)." -Level "INFO"
    }

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Local source file: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local File Size: $(Format-BytesInternal -Bytes $LocalArchiveSizeBytes)" -Level "DEBUG"
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Remote destination for this file: '$fullRemoteArchivePathForThisFile'" -Level "DEBUG"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would ensure remote directory exists: '$remoteFinalDirectoryForArchiveSet'." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would copy '$LocalArchivePath' to '$fullRemoteArchivePathForThisFile'." -Level "SIMULATE"
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
    } else {
        $ensurePathParams = @{ Path = $remoteFinalDirectoryForArchiveSet; Logger = $Logger; IsSimulateMode = $IsSimulateMode.IsPresent; PSCmdletInstance = $PSCmdlet }
        $ensurePathResult = Initialize-RemotePathInternal @ensurePathParams
        if (-not $ensurePathResult.Success) {
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to ensure remote directory '$remoteFinalDirectoryForArchiveSet' exists. Error: $($ensurePathResult.ErrorMessage)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result
        }
        if (-not $PSCmdlet.ShouldProcess($fullRemoteArchivePathForThisFile, "Copy File to UNC Path")) {
            $result.ErrorMessage = "UNC Target '$targetNameForLog': File copy to '$fullRemoteArchivePathForThisFile' skipped by user (ShouldProcess)."
            & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
            return $result # Return success=$false as operation was skipped by user choice
        }
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Copying file '$ArchiveFileName' from '$LocalArchivePath' to '$fullRemoteArchivePathForThisFile'..." -Level "INFO"
        $copyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Copy-Item -LiteralPath $LocalArchivePath -Destination $fullRemoteArchivePathForThisFile -Force -ErrorAction Stop
            $copyStopwatch.Stop()
            $result.TransferDuration = $copyStopwatch.Elapsed
            $result.Success = $true
            if (Test-Path -LiteralPath $fullRemoteArchivePathForThisFile -PathType Leaf) {
                $result.TransferSize = (Get-Item -LiteralPath $fullRemoteArchivePathForThisFile).Length
            }
            & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': File '$ArchiveFileName' copied successfully. Duration: $($result.TransferDuration)." -Level "SUCCESS"
        } catch {
            $copyStopwatch.Stop()
            $result.TransferDuration = $copyStopwatch.Elapsed
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to copy file '$ArchiveFileName' to '$fullRemoteArchivePathForThisFile'. Error: $($_.Exception.Message)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result
        }
    }

    # Retention logic is now more complex: it needs to identify all files for an *instance*
    # An instance is defined by $ArchiveBaseName (e.g., "JobName [DateStamp]")
    # All files for that instance (JobName [DateStamp].7z.001, .002, ..., .manifest.sha256) must be deleted together.
    # This retention logic should ideally run only *once* per job for this target, after all parts have been transferred.
    # However, the current design calls Invoke-PoShBackupTargetTransfer for each file.
    # For simplicity in this iteration, we will run retention after *each successful file transfer*.
    # This is not perfectly efficient but ensures retention is attempted.
    # A more advanced approach would be for the orchestrator to signal when the last part of a set is transferred.

    if (($result.Success) -and `
            $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings -is [hashtable] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.ContainsKey('KeepCount') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {

        $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Applying remote retention policy (KeepCount: $remoteKeepCount) in directory '$remoteFinalDirectoryForArchiveSet' for instances matching base '$ArchiveBaseName'." -Level "INFO"

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would scan '$remoteFinalDirectoryForArchiveSet' for instances based on '$ArchiveBaseName', group them, sort by date, and delete oldest instances exceeding $remoteKeepCount (all parts + manifest)." -Level "SIMULATE"
        } else {
            try {
                if (-not (Test-Path -LiteralPath $remoteFinalDirectoryForArchiveSet -PathType Container)) {
                    & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Remote directory '$remoteFinalDirectoryForArchiveSet' not found for retention. Skipping remote retention." -Level "WARNING"
                } else {
                    # Use the new helper to group files by instance
                    $allRemoteInstances = Group-RemoteUNCBackupInstancesInternal -Directory $remoteFinalDirectoryForArchiveSet `
                                                                                -BaseNameToMatch $ArchiveBaseName `
                                                                                -PrimaryArchiveExtension $ArchiveExtension `
                                                                                -Logger $Logger
                    
                    if ($allRemoteInstances.Count -gt $remoteKeepCount) {
                        $sortedInstances = $allRemoteInstances.GetEnumerator() | Sort-Object {$_.Value.SortTime} -Descending
                        $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                        
                        & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Found $($allRemoteInstances.Count) remote backup instances. Will attempt to delete $($instancesToDelete.Count) older instance(s)." -Level "INFO"

                        foreach ($instanceEntry in $instancesToDelete) {
                            $instanceKeyToDelete = $instanceEntry.Name # e.g., "JobName [DateStamp].7z"
                            & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Preparing to delete instance '$instanceKeyToDelete' (SortTime: $($instanceEntry.Value.SortTime)). Files:" -Level "WARNING"
                            foreach ($remoteFileToDelete in $instanceEntry.Value.Files) {
                                if (-not $PSCmdlet.ShouldProcess($remoteFileToDelete.FullName, "Delete Remote Archive File/Part (Retention)")) {
                                    & $LocalWriteLog -Message "        - Deletion of '$($remoteFileToDelete.FullName)' skipped by user." -Level "WARNING"
                                    continue
                                }
                                & $LocalWriteLog -Message "        - Deleting: '$($remoteFileToDelete.FullName)'" -Level "WARNING"
                                try {
                                    Remove-Item -LiteralPath $remoteFileToDelete.FullName -Force -ErrorAction Stop
                                    & $LocalWriteLog -Message "          - Status: DELETED (Remote Retention)" -Level "SUCCESS"
                                } catch {
                                    & $LocalWriteLog -Message "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR"
                                    if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "One or more remote retention deletions failed for instance '$instanceKeyToDelete'." }
                                    else { $result.ErrorMessage += " Additionally, one or more remote retention deletions failed for instance '$instanceKeyToDelete'." }
                                    # Don't set $result.Success to $false here for the overall *transfer* if only retention failed for an *older* archive.
                                    # However, this could be a policy decision. For now, transfer success is independent of old retention success.
                                }
                            }
                        }
                    } else {
                        & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Number of existing remote instances ($($allRemoteInstances.Count)) is at or below retention count ($remoteKeepCount). No instances to delete." -Level "INFO"
                    }
                }
            } catch {
                $retentionErrorMsg = "Error during remote retention policy for job '$JobName' in '$remoteFinalDirectoryForArchiveSet'. Error: $($_.Exception.Message)"
                & $LocalWriteLog -Message "[WARNING] UNC Target '$targetNameForLog': $retentionErrorMsg" -Level "WARNING"
                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionErrorMsg }
                else { $result.ErrorMessage += " Additionally, $retentionErrorMsg" }
                # Again, not setting $result.Success to $false for the current transfer if only old retention fails.
            }
        }
    }

    & $LocalWriteLog -Message "[INFO] UNC Target: Finished transfer attempt of file '$ArchiveFileName' for Job '$JobName' to Target '$targetNameForLog'. Success for this file: $($result.Success)." -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupUNCTargetSettingsValidation
