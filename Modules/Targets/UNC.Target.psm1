<#
.SYNOPSIS
    PoSh-Backup Target Provider for UNC (Universal Naming Convention) paths.
    Handles transferring backup archives to network shares and managing retention on those shares.
    Accepts additional metadata about the local archive, such as size and creation time.
    Allows configurable creation of a job-specific subdirectory on the target.

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

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.2
    DateCreated:    19-May-2025
    LastModified:   19-May-2025
    Purpose:        UNC Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on the target UNC path.
                    For credentialed access (future enhancement), PowerShell SecretManagement would be required.
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

#region --- UNC Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    <#
    .SYNOPSIS
        Transfers a local backup archive to a UNC path and manages remote retention.
    .DESCRIPTION
        This is the main exported function for the UNC target provider. It handles the copying
        of the local archive to the specified UNC remote path and applies any configured
        remote retention policy. The creation of a job-specific subdirectory on the remote
        target is controllable via the 'CreateJobNameSubdirectory' setting.
        It receives and logs additional metadata about the local archive.
    .PARAMETER LocalArchivePath
        The full path to the local backup archive file that needs to be transferred.
    .PARAMETER TargetInstanceConfiguration
        A hashtable containing the full configuration for this specific UNC target instance,
        as defined in the global 'BackupTargets' section. Expected keys include:
        - 'Type' (string, should be "UNC")
        - 'TargetSpecificSettings' (hashtable, must contain 'UNCRemotePath', optionally 'CreateJobNameSubdirectory')
        - Optional: 'CredentialsSecretName' (string)
        - Optional: 'RemoteRetentionSettings' (hashtable, e.g., @{ KeepCount = 5 })
        - '_TargetInstanceName_' (string, added by ConfigManager for logging)
    .PARAMETER JobName
        The name of the overall backup job being processed. Used for creating subdirectories
        on the remote share (if enabled) and for scoping remote retention.
    .PARAMETER ArchiveFileName
        The filename (leaf part) of the archive being transferred (e.g., "MyData_2025-05-19.7z").
    .PARAMETER ArchiveBaseName
        The base name of the archive, without the date stamp or extension (e.g., "MyData").
        Used for matching files during remote retention.
    .PARAMETER ArchiveExtension
        The extension of the archive file, including the dot (e.g., ".7z").
        Used for matching files during remote retention.
    .PARAMETER IsSimulateMode
        A switch. If $true, transfer and deletion operations are simulated and logged but not executed.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
    .PARAMETER EffectiveJobConfig
        The fully resolved effective configuration hashtable for the current PoSh-Backup job.
        This is logged for diagnostic purposes by this provider.
    .PARAMETER LocalArchiveSizeBytes
        The size of the local archive in bytes. This is logged by the provider.
    .PARAMETER LocalArchiveCreationTimestamp
        The creation timestamp of the local archive. This is logged by the provider.
    .PARAMETER PasswordInUse
        A boolean indicating if the local archive was password protected. This is logged by the provider.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with the following keys:
        - Success (boolean): $true if the transfer (and remote retention, if applicable) was successful or simulated successfully.
        - RemotePath (string): The full UNC path to where the archive was (or would have been) copied.
        - ErrorMessage (string): An error message if an operation failed.
        - TransferSize (long): Size of the transferred file in bytes. 0 in simulation (unless file exists for size check) or if transfer failed before copy.
        - TransferDuration (System.TimeSpan): Duration of the file copy operation.
    #>
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
        [bool]$PasswordInUse
    )

    # Defensive PSSA appeasement line
    & $Logger -Message "UNC.Target/Invoke-PoShBackupTargetTransfer: Logger parameter active for Job '$JobName', Target Instance '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
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
        # Future implementation:
        # 1. Import PasswordManager.psm1 or a generic secret retrieval utility.
        # 2. Call a function to get a PSCredential object using $credentialsSecretName.
        # 3. If successful, use these credentials. This might involve:
        #    a. New-PSDrive to map the UNC path if Copy-Item struggles with -Credential for UNC.
        #    b. Using Copy-Item -Credential (if supported and reliable for UNC paths in the target PS version).
        #    c. Invoking robocopy.exe with /user: /pass: parameters (less ideal due to external exe).
        # For now, we proceed assuming direct access rights for the executing user.
    }

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Local archive source: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Size (Bytes): $LocalArchiveSizeBytes ($(Format-BytesInternal -Bytes $LocalArchiveSizeBytes))" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Created: $LocalArchiveCreationTimestamp" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local Archive Password Protected: $PasswordInUse" -Level "DEBUG"
    $jobBaseFileNameFromConfig = if ($EffectiveJobConfig.ContainsKey('BaseFileName')) { $EffectiveJobConfig.BaseFileName } else { 'N/A' } # Accessing EffectiveJobConfig
    & $LocalWriteLog -Message "    - Job BaseFileName (from EffectiveJobConfig for this job): $jobBaseFileNameFromConfig" -Level "DEBUG"

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Final remote directory for archive & retention operations: '$remoteFinalDirectoryForArchiveAndRetention'" -Level "DEBUG"
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Full remote archive destination path: '$fullRemoteArchivePath'" -Level "DEBUG"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would ensure remote directory exists: '$remoteFinalDirectoryForArchiveAndRetention'." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: UNC Target '$targetNameForLog': Would copy '$LocalArchivePath' to '$fullRemoteArchivePath'." -Level "SIMULATE"
        $result.Success = $true
        # Use the passed LocalArchiveSizeBytes for simulated transfer size
        $result.TransferSize = $LocalArchiveSizeBytes
    }
    else {
        # Ensure the final remote directory exists using the robust helper
        $ensurePathParams = @{
            Path             = $remoteFinalDirectoryForArchiveAndRetention
            Logger           = $Logger
            IsSimulateMode   = $IsSimulateMode.IsPresent # Will be $false here as this block is inside 'else' for IsSimulateMode
            PSCmdletInstance = $PSCmdlet # Pass the automatic variable for ShouldProcess
        }
        $ensurePathResult = Initialize-RemotePathInternal @ensurePathParams
    
        if (-not $ensurePathResult.Success) {
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to ensure remote directory '$remoteFinalDirectoryForArchiveAndRetention' exists. Error: $($ensurePathResult.ErrorMessage)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result
        }

        # Perform the copy to the full remote archive path
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
                # Verify file exists at destination before getting size
                $result.TransferSize = (Get-Item -LiteralPath $fullRemoteArchivePath).Length
            }
            & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Archive copied successfully. Duration: $($result.TransferDuration)." -Level "SUCCESS"
        }
        catch {
            $copyStopwatch.Stop()
            $result.TransferDuration = $copyStopwatch.Elapsed # Record duration even on failure
            $result.ErrorMessage = "UNC Target '$targetNameForLog': Failed to copy archive to '$fullRemoteArchivePath'. Error: $($_.Exception.Message)"
            & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
            return $result # Transfer failed, return immediately
        }
    } # End of NOT IsSimulateMode block

    # --- Remote Retention (if configured for this target instance and transfer was successful or simulated successfully) ---
    # Remote retention operates within $remoteFinalDirectoryForArchiveAndRetention
    if (($result.Success) -and `
            $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings -is [hashtable] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.ContainsKey('KeepCount') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
        
        $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Applying remote retention policy (KeepCount: $remoteKeepCount) in directory '$remoteFinalDirectoryForArchiveAndRetention'." -Level "INFO"

        # Pattern for finding archives of THIS job in the final remote directory
        $literalBaseNameForRemote = $ArchiveBaseName -replace '\*', '`*' -replace '\?', '`?' # Escape wildcards in base name
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
                            & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Deleting remote archive for retention: '$($remoteBackupFile.FullName)' (Created: $($remoteBackupFile.CreationTime))" -Level "WARNING" # Log as warning because it's a deletion
                            try {
                                Remove-Item -LiteralPath $remoteBackupFile.FullName -Force -ErrorAction Stop
                                & $LocalWriteLog -Message "        - Status: DELETED (Remote Retention)" -Level "SUCCESS"
                            }
                            catch {
                                & $LocalWriteLog -Message "        - Status: FAILED to delete remote archive! Error: $($_.Exception.Message)" -Level "ERROR"
                                # Non-fatal for the overall transfer if copy succeeded, but mark overall result as problematic.
                                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "One or more remote retention deletions failed." }
                                else { $result.ErrorMessage += " Additionally, one or more remote retention deletions failed." }
                                $result.Success = $false # If retention fails, the overall target operation is not fully successful.
                            }
                        }
                    }
                    else {
                        & $LocalWriteLog -Message "    - UNC Target '$targetNameForLog': Number of existing remote archives ($($existingRemoteBackups.Count)) is at or below remote retention count ($remoteKeepCount). No remote archives to delete." -Level "INFO"
                    }
                }
            }
            catch {
                # Catch block for Get-ChildItem or other errors during remote retention setup
                & $LocalWriteLog -Message "[WARNING] UNC Target '$targetNameForLog': Error during remote retention policy for job '$JobName' in '$remoteFinalDirectoryForArchiveAndRetention'. Error: $($_.Exception.Message)" -Level "WARNING"
                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "Error during remote retention: $($_.Exception.Message)" }
                else { $result.ErrorMessage += " Additionally, error during remote retention: $($_.Exception.Message)" }
                $result.Success = $false # Mark overall success as false if retention encounters an exception
            }
        }
    }
    elseif (($result.Success) -and $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) {
        # This case handles if RemoteRetentionSettings exists but is not properly configured (e.g., missing KeepCount or KeepCount not > 0)
        & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': RemoteRetentionSettings found but KeepCount is invalid or not greater than 0. Remote retention skipped for this target instance." -Level "INFO"
    }

    & $LocalWriteLog -Message "[INFO] UNC Target: Finished transfer attempt for Job '$JobName' to Target '$targetNameForLog'. Overall Success for this Target: $($result.Success)." -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer
