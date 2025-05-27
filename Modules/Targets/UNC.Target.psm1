# Modules\Targets\UNC.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for UNC (Universal Naming Convention) paths.
    Handles transferring backup archives to network shares and managing retention on those shares.
    Accepts additional metadata about the local archive, such as size and creation time.
    Allows configurable creation of a job-specific subdirectory on the target.
    Now includes a function for validating its specific TargetSpecificSettings.

.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for UNC path destinations.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "UNC".

    The provider performs the following actions:
    -   Retrieves the target UNC path from 'TargetSpecificSettings.UNCRemotePath'.
    -   Reads an optional 'CreateJobNameSubdirectory' boolean from 'TargetSpecificSettings'
        (defaults to $false, meaning archives are placed directly into 'UNCRemotePath').
        If $true, a subdirectory named after the 'JobName' is created under 'UNCRemotePath',
        and archives/retention operate within that subdirectory.
    -   Optionally attempts to use credentials if 'CredentialsSecretName' is specified
        (currently a placeholder for full implementation).
    -   Ensures the final remote destination directory exists, creating it if necessary.
    -   Copies the local backup archive file to the determined remote destination.
    -   Logs information received about the local archive, such as its size, creation time,
        and password protection status.
    -   If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined in the target configuration,
        it applies a count-based retention policy to archives for the current job within the
        final remote destination directory.
    -   Supports simulation mode.
    -   Returns a status hashtable indicating success or failure, the remote path of the transferred archive,
        and any error messages.

    A new function, 'Invoke-PoShBackupUNCTargetSettingsValidation', is now included to validate
    the 'TargetSpecificSettings' specific to this UNC provider. This function is intended to be
    called by the PoShBackupValidator module.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.3 # Added Invoke-PoShBackupUNCTargetSettingsValidation function.
    DateCreated:    19-May-2025
    LastModified:   27-May-2025
    Purpose:        UNC Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on the target UNC path.
#>

#region --- Private Helper: Format Bytes ---
# Internal helper function to format byte sizes into human-readable strings (KB, MB, GB).
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

    # Defensive PSSA appeasement line: Directly use the $Logger parameter once.
    & $Logger -Message "UNC.Target/Initialize-RemotePathInternal: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
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
        # UNC Path
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
                try {
                    New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                catch {
                    return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" }
                }
            }
        }
    }
    else {
        # Local Path
        $currentPathToBuild = ""
        if ($pathComponents[0] -match '^[a-zA-Z]:$') {
            $currentPathToBuild = $pathComponents[0] + [System.IO.Path]::DirectorySeparatorChar
            $startIndex = 1
        }
        else {
            $startIndex = 0
        }

        for ($i = $startIndex; $i -lt $pathComponents.Count; $i++) {
            if ($currentPathToBuild -eq "" -and $i -eq 0) {
                $currentPathToBuild = $pathComponents[$i]
            }
            else {
                $currentPathToBuild = Join-Path -Path $currentPathToBuild -ChildPath $pathComponents[$i]
            }

            if (-not (Test-Path -LiteralPath $currentPathToBuild -PathType Container)) {
                if (-not $PSCmdletInstance.ShouldProcess($currentPathToBuild, "Create Local Directory Component")) {
                    return @{ Success = $false; ErrorMessage = "Directory component creation for '$currentPathToBuild' skipped by user." }
                }
                & $LocalWriteLog -Message "  - Ensure-RemotePath: Creating directory component '$currentPathToBuild'." -Level "INFO"
                try {
                    New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                catch {
                    return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" }
                }
            }
        }
    }
    return @{ Success = $true }
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
        [ref]$ValidationMessagesListRef, # Expects a [System.Collections.Generic.List[string]]
        [Parameter(Mandatory = $false)] # Optional logger, if needed for complex validation logging
        [scriptblock]$Logger
    )

    # PSSA: Logger parameter used if provided
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "UNC.Target/Invoke-PoShBackupUNCTargetSettingsValidation: Validating settings for UNC Target '$TargetInstanceName'." -Level "DEBUG"
    }

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return # Cannot proceed if the main settings block is not a hashtable
    }

    if (-not $TargetSpecificSettings.ContainsKey('UNCRemotePath') -or -not ($TargetSpecificSettings.UNCRemotePath -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.UNCRemotePath)) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'UNCRemotePath' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.UNCRemotePath'.")
    }

    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.CreateJobNameSubdirectory'.")
    }
    # Add any other UNC-specific validations here if needed in the future.
}
#endregion

#region --- UNC Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet # Added for ShouldProcess
    )

    # Defensive PSSA appeasement line
    & $Logger -Message "UNC.Target/Invoke-PoShBackupTargetTransfer: Logger parameter active for Job '$JobName', Target Instance '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_ # Get the friendly name
    & $LocalWriteLog -Message "`n[INFO] UNC Target: Starting transfer for Job '$JobName' to Target '$targetNameForLog'." -Level "INFO"

    $result = @{
        Success          = $false
        RemotePath       = $null
        ErrorMessage     = $null
        TransferSize     = 0
        TransferDuration = New-TimeSpan
    }

    # --- Validate Target Specific Settings ---
    if (-not $TargetInstanceConfiguration.TargetSpecificSettings.ContainsKey('UNCRemotePath') -or `
            [string]::IsNullOrWhiteSpace($TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath)) {
        $result.ErrorMessage = "UNC Target '$targetNameForLog': 'UNCRemotePath' is missing or empty in TargetSpecificSettings."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        return $result
    }
    $uncRemoteBasePathFromConfig = $TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath.TrimEnd("\/")

    # --- Determine final remote directory based on CreateJobNameSubdirectory setting ---
    $createJobSubDir = $false # Default to placing archive directly in UNCRemotePath
    if ($TargetInstanceConfiguration.TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory')) {
        if ($TargetInstanceConfiguration.TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean]) {
            $createJobSubDir = $TargetInstanceConfiguration.TargetSpecificSettings.CreateJobNameSubdirectory
        }
        else {
            & $LocalWriteLog -Message "[WARNING] UNC Target '$targetNameForLog': 'CreateJobNameSubdirectory' in TargetSpecificSettings is not a boolean. Defaulting to `$false (no job subdirectory will be created)." -Level "WARNING"
        }
    }
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Configured to create job-specific subdirectory: $createJobSubDir." -Level "DEBUG"

    $remoteFinalDirectoryForArchiveAndRetention = ""
    if ($createJobSubDir) {
        $remoteFinalDirectoryForArchiveAndRetention = Join-Path -Path $uncRemoteBasePathFromConfig -ChildPath $JobName
    }
    else {
        $remoteFinalDirectoryForArchiveAndRetention = $uncRemoteBasePathFromConfig
    }

    $fullRemoteArchivePath = Join-Path -Path $remoteFinalDirectoryForArchiveAndRetention -ChildPath $ArchiveFileName
    $result.RemotePath = $fullRemoteArchivePath # Store the intended final path in the result

    # --- Credentials Handling (Placeholder for V1) ---
    $credentialsSecretName = $TargetInstanceConfiguration.CredentialsSecretName
    if (-not [string]::IsNullOrWhiteSpace($credentialsSecretName)) {
        & $LocalWriteLog -Message "[INFO] UNC Target '$targetNameForLog': CredentialsSecretName '$credentialsSecretName' is specified. (Full credentialed access using this secret is a future enhancement; current operation will use the executing user's context)." -Level "INFO"
    }

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Local archive source: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Size (Bytes): $LocalArchiveSizeBytes ($(Format-BytesInternal -Bytes $LocalArchiveSizeBytes))" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Created: $LocalArchiveCreationTimestamp" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Password Protected: $PasswordInUse" -Level "DEBUG"
    $jobBaseFileNameFromConfig = if ($EffectiveJobConfig.ContainsKey('BaseFileName')) { $EffectiveJobConfig.BaseFileName } else { 'N/A' }
    & $LocalWriteLog -Message "    - Job BaseFileName (from EffectiveJobConfig for this job): $jobBaseFileNameFromConfig" -Level "DEBUG"

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Final remote directory for archive & retention operations: '$remoteFinalDirectoryForArchiveAndRetention'" -Level "DEBUG"
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Full remote archive destination path: '$fullRemoteArchivePath'" -Level "DEBUG"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would ensure remote directory exists: '$remoteFinalDirectoryForArchiveAndRetention'." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would copy '$LocalArchivePath' to '$fullRemoteArchivePath'." -Level "SIMULATE"
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
    }
    else {
        $ensurePathParams = @{
            Path             = $remoteFinalDirectoryForArchiveAndRetention
            Logger           = $Logger
            IsSimulateMode   = $IsSimulateMode.IsPresent
            PSCmdletInstance = $PSCmdlet
        }
        $ensurePathResult = Initialize-RemotePathInternal @ensurePathParams

        if (-not $ensurePathResult.Success) {
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to ensure remote directory '$remoteFinalDirectoryForArchiveAndRetention' exists. Error: $($ensurePathResult.ErrorMessage)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result
        }

        if (-not $PSCmdlet.ShouldProcess($fullRemoteArchivePath, "Copy Archive to UNC Path")) {
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Archive copy to '$fullRemoteArchivePath' skipped by user (ShouldProcess)."
            & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
            return $result
        }
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Copying archive from '$LocalArchivePath' to '$fullRemoteArchivePath'..." -Level "INFO"
        $copyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Copy-Item -LiteralPath $LocalArchivePath -Destination $fullRemoteArchivePath -Force -ErrorAction Stop
            $copyStopwatch.Stop()
            $result.TransferDuration = $copyStopwatch.Elapsed
            $result.Success = $true
            if (Test-Path -LiteralPath $fullRemoteArchivePath -PathType Leaf) {
                $result.TransferSize = (Get-Item -LiteralPath $fullRemoteArchivePath).Length
            }
            & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Archive copied successfully. Duration: $($result.TransferDuration)." -Level "SUCCESS"
        }
        catch {
            $copyStopwatch.Stop()
            $result.TransferDuration = $copyStopwatch.Elapsed
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to copy archive to '$fullRemoteArchivePath'. Error: $($_.Exception.Message)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result
        }
    }

    if (($result.Success) -and `
            $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings -is [hashtable] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.ContainsKey('KeepCount') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {

        $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Applying remote retention policy (KeepCount: $remoteKeepCount) in directory '$remoteFinalDirectoryForArchiveAndRetention'." -Level "INFO"

        $literalBaseNameForRemote = $ArchiveBaseName -replace '\*', '`*' -replace '\?', '`?'
        $remoteFilePattern = "$($literalBaseNameForRemote)*$($ArchiveExtension)"

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would list files matching '$remoteFilePattern' in '$remoteFinalDirectoryForArchiveAndRetention' and delete oldest exceeding $remoteKeepCount." -Level "SIMULATE"
        }
        else {
            try {
                if (-not (Test-Path -LiteralPath $remoteFinalDirectoryForArchiveAndRetention -PathType Container)) {
                    & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Remote directory '$remoteFinalDirectoryForArchiveAndRetention' not found for retention. Skipping remote retention for this cycle." -Level "WARNING"
                }
                else {
                    $existingRemoteBackups = Get-ChildItem -Path $remoteFinalDirectoryForArchiveAndRetention -Filter $remoteFilePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending

                    if (($null -ne $existingRemoteBackups) -and ($existingRemoteBackups.Count -gt $remoteKeepCount)) {
                        $remoteBackupsToDelete = $existingRemoteBackups | Select-Object -Skip $remoteKeepCount
                        & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Found $($existingRemoteBackups.Count) remote archives matching pattern. Will attempt to delete $($remoteBackupsToDelete.Count) older archive(s) to meet remote retention count ($remoteKeepCount)." -Level "INFO"

                        foreach ($remoteBackupFile in $remoteBackupsToDelete) {
                            if (-not $PSCmdlet.ShouldProcess($remoteBackupFile.FullName, "Delete Remote Archive (Retention)")) {
                                & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Deletion of remote archive '$($remoteBackupFile.FullName)' skipped by user (ShouldProcess)." -Level "WARNING"
                                continue
                            }
                            & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Deleting remote archive for retention: '$($remoteBackupFile.FullName)' (Created: $($remoteBackupFile.CreationTime))" -Level "WARNING"
                            try {
                                Remove-Item -LiteralPath $remoteBackupFile.FullName -Force -ErrorAction Stop
                                & $LocalWriteLog -Message "        - Status: DELETED (Remote Retention)" -Level "SUCCESS"
                            }
                            catch {
                                & $LocalWriteLog -Message "        - Status: FAILED to delete remote archive! Error: $($_.Exception.Message)" -Level "ERROR"
                                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "One or more remote retention deletions failed." }
                                else { $result.ErrorMessage += " Additionally, one or more remote retention deletions failed." }
                                $result.Success = $false
                            }
                        }
                    }
                    else {
                        & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Number of existing remote archives ($($existingRemoteBackups.Count)) is at or below remote retention count ($remoteKeepCount). No remote archives to delete." -Level "INFO"
                    }
                }
            }
            catch {
                & $LocalWriteLog -Message "[WARNING] UNC Target '$targetNameForLog': Error during remote retention policy for job '$JobName' in '$remoteFinalDirectoryForArchiveAndRetention'. Error: $($_.Exception.Message)" -Level "WARNING"
                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "Error during remote retention: $($_.Exception.Message)" }
                else { $result.ErrorMessage += " Additionally, error during remote retention: $($_.Exception.Message)" }
                $result.Success = $false
            }
        }
    }
    elseif (($result.Success) -and $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) {
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': RemoteRetentionSettings found but KeepCount is invalid or not greater than 0. Remote retention skipped for this target instance." -Level "INFO"
    }

    & $LocalWriteLog -Message "[INFO] UNC Target: Finished transfer attempt for Job '$JobName' to Target '$targetNameForLog'. Overall Success for this Target: $($result.Success)." -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupUNCTargetSettingsValidation
