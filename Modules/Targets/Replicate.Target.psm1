# Modules\Targets\Replicate.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for replicating a backup archive (including individual
    volumes and manifest files) to multiple destinations. Each destination can be a
    local path or a UNC path and can have its own subdirectory creation and
    retention settings.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for replicating
    a backup set (which can be a single file, or multiple volume parts plus a manifest)
    to several specified locations. The core function, 'Invoke-PoShBackupTargetTransfer',
    is called by the RemoteTransferOrchestrator for each file that needs to be replicated.

    The provider performs the following actions for each destination defined in its configuration:
    -   Retrieves the destination path (local or UNC).
    -   Determines if a job-specific subdirectory should be created.
    -   Ensures the final destination directory exists.
    -   Copies the specific local archive file (a volume part or a manifest file) to this destination.
    -   If the 'ContinueOnError' setting for the target is false (default), it will stop processing
        further destinations for the current file after the first failure.
    -   If retention settings (e.g., 'KeepCount') are defined for this specific destination,
        it applies a count-based retention policy. This policy now correctly identifies all
        related files of a backup instance (all volumes and any manifest) for deletion.
    -   Supports simulation mode.
    -   Returns a status for the individual file transfer. Detailed information about each
        individual replication attempt is aggregated by the orchestrator.

    A function, 'Invoke-PoShBackupReplicateTargetSettingsValidation', validates the entire target configuration.
    A new function, 'Test-PoShBackupTargetConnectivity', validates the accessibility of all configured destination paths.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.0 # Refactored to use centralised Format-FileSize utility function.
    DateCreated:    19-May-2025
    LastModified:   23-Jun-2025
    Purpose:        Replicate Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on all configured destination paths.
#>

#region --- Module Dependencies ---
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Replicate.Target.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
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
    & $Logger -Message "Replicate.Target/Initialize-RemotePathInternal: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
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
    }
    else {
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

#region --- Private Helper: Group Backup Instances for Retention (Local or UNC) ---
function Group-LocalOrUNCBackupInstancesInternal {
    param(
        [string]$Directory,
        [string]$BaseNameToMatch, # e.g., "JobName [DateStamp]" (this is $ArchiveBaseName from Invoke-PoShBackupTargetTransfer)
        [string]$PrimaryArchiveExtension, # e.g., ".7z" (the one before .001 or .manifest)
        [scriptblock]$Logger
    )

    # PSSA Appeasement and initial log entry:
    & $Logger -Message "Replicate.Target/Group-LocalOrUNCBackupInstancesInternal: Logger active. Scanning '$Directory' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Define LocalWriteLog for subsequent use within this function if needed by other parts of it.
    $LocalWriteLog = { param([string]$Message, [string]$Level = "DEBUG") & $Logger -Message $Message -Level $Level }
    
    $instances = @{}
    $literalBase = [regex]::Escape($BaseNameToMatch) # BaseNameToMatch is "JobName [DateStamp]"
    $literalExt = [regex]::Escape($PrimaryArchiveExtension) # PrimaryArchiveExtension is ".7z"

    # Filter for Get-ChildItem should be broad enough to get all parts of an instance based on $BaseNameToMatch
    $fileFilterForInstance = "$BaseNameToMatch*"

    Get-ChildItem -Path $Directory -Filter $fileFilterForInstance -File -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        $instanceKey = $null
        
        # Try to match split volumes: "BaseName.PrimaryExt.NNN"
        $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$"
        # Try to match manifest for split volumes: "BaseName.PrimaryExt.manifest.algo"
        $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$"
        # Try to match single file (could be SFX if PrimaryArchiveExtension is .exe, or standard archive)
        $singleFilePattern = "^($literalBase$literalExt)$"
        # Try to match manifest for single file: "BaseName.ActualExt.manifest.algo"
        # This is tricky if PrimaryArchiveExtension is .7z but actual file is .exe (SFX)
        # Let's use $ArchiveFileName from the main function context if possible, or derive.
        
        if ($file.Name -match $splitVolumePattern) {
            $instanceKey = $Matches[1] # "JobName [DateStamp].<PrimaryExtension>"
        }
        elseif ($file.Name -match $splitManifestPattern) {
            $instanceKey = $Matches[1] # "JobName [DateStamp].<PrimaryExtension>"
        }
        elseif ($file.Name -match "^($literalBase.+?)\.manifest\.[a-zA-Z0-9]+$") {
            # Manifest for a file that might not strictly match PrimaryArchiveExtension (e.g. SFX .exe when Primary is .7z)
            $instanceKey = $Matches[1] # "JobName [DateStamp].exe"
        }
        elseif ($file.Name -match $singleFilePattern) {
            $instanceKey = $Matches[1] # "JobName [DateStamp].<PrimaryExtension>"
        }
        else {
            # Fallback: if it starts with BaseNameToMatch, consider it part of an instance
            # This is less precise but helps catch SFX files where PrimaryArchiveExtension might be different
            if ($file.Name.StartsWith($BaseNameToMatch)) {
                # Attempt to derive a consistent instance key, e.g., "JobName [DateStamp].actualExt"
                $instanceKey = $BaseNameToMatch + $file.Extension 
                if ($file.Extension -eq ($PrimaryArchiveExtension + ".001")) {
                    # if it's like .7z.001
                    $instanceKey = $BaseNameToMatch + $PrimaryArchiveExtension
                }
            }
        }

        if ($null -eq $instanceKey) {
            & $LocalWriteLog -Message "Replicate.Target/GroupHelper: Could not determine instance key for file '$($file.Name)'. Skipping." -Level "VERBOSE"
            return # continue in ForEach-Object
        }

        if (-not $instances.ContainsKey($instanceKey)) {
            $instances[$instanceKey] = @{
                SortTime = $file.CreationTime # Initial sort time
                Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
        }
        $instances[$instanceKey].Files.Add($file)

        # Refine SortTime: if it's a .001 part, its CreationTime is authoritative for the instance.
        if ($file.Name -match "$literalExt\.001$") {
            if ($file.CreationTime -lt $instances[$instanceKey].SortTime) {
                $instances[$instanceKey].SortTime = $file.CreationTime
            }
        }
    }
    
    # Second pass to refine sort times for instances that didn't have a .001 part explicitly found first
    foreach ($key in $instances.Keys) {
        if ($instances[$key].Files.Count -gt 0) {
            $firstVolume = $instances[$key].Files | Where-Object { $_.Name -match "$literalExt\.001$" } | Sort-Object CreationTime | Select-Object -First 1
            if ($firstVolume) {
                if ($firstVolume.CreationTime -lt $instances[$key].SortTime) {
                    $instances[$key].SortTime = $firstVolume.CreationTime
                }
            }
            else {
                # If no .001, use the creation time of the earliest file in the group
                $earliestFileInGroup = $instances[$key].Files | Sort-Object CreationTime | Select-Object -First 1
                if ($earliestFileInGroup -and $earliestFileInGroup.CreationTime -lt $instances[$key].SortTime) {
                    $instances[$key].SortTime = $earliestFileInGroup.CreationTime
                }
            }
        }
    }

    & $LocalWriteLog -Message "Replicate.Target/GroupHelper: Found $($instances.Keys.Count) distinct instances in '$Directory' for base '$BaseNameToMatch'."
    return $instances
}
#endregion

#region --- Private Helper: Build Robocopy Arguments ---
function Build-RobocopyArgumentsInternal {
    param(
        [string]$SourceFile,
        [string]$DestinationDirectory,
        [hashtable]$RobocopySettings
    )

    $sourceDir = Split-Path -Path $SourceFile -Parent
    $fileNameOnly = Split-Path -Path $SourceFile -Leaf
    
    $argumentsList = [System.Collections.Generic.List[string]]::new()
    $argumentsList.Add("`"$sourceDir`"")
    $argumentsList.Add("`"$DestinationDirectory`"")
    $argumentsList.Add("`"$fileNameOnly`"")

    if ($null -eq $RobocopySettings) { $RobocopySettings = @{} }

    # Copy options
    $copyFlags = if ($RobocopySettings.ContainsKey('CopyFlags')) { $RobocopySettings.CopyFlags } else { "DAT" }
    $argumentsList.Add("/COPY:$copyFlags")
    $dirCopyFlags = if ($RobocopySettings.ContainsKey('DirectoryCopyFlags')) { $RobocopySettings.DirectoryCopyFlags } else { "T" }
    $argumentsList.Add("/DCOPY:$dirCopyFlags")

    # Retry options
    $retries = if ($RobocopySettings.ContainsKey('Retries')) { $RobocopySettings.Retries } else { 5 }
    $argumentsList.Add("/R:$retries")
    $waitTime = if ($RobocopySettings.ContainsKey('WaitTime')) { $RobocopySettings.WaitTime } else { 15 }
    $argumentsList.Add("/W:$waitTime")

    # Performance options
    if ($RobocopySettings.ContainsKey('MultiThreadedCount') -and $RobocopySettings.MultiThreadedCount -is [int] -and $RobocopySettings.MultiThreadedCount -gt 0) {
        $argumentsList.Add("/MT:$($RobocopySettings.MultiThreadedCount)")
    }
    if ($RobocopySettings.ContainsKey('InterPacketGap') -and $RobocopySettings.InterPacketGap -is [int] -and $RobocopySettings.InterPacketGap -gt 0) {
        $argumentsList.Add("/IPG:$($RobocopySettings.InterPacketGap)")
    }
    if ($RobocopySettings.ContainsKey('UnbufferedIO') -and $RobocopySettings.UnbufferedIO -eq $true) {
        $argumentsList.Add("/J")
    }

    # Logging options (provider manages the log file itself)
    $argumentsList.Add("/NS")  # No Size
    $argumentsList.Add("/NC")  # No Class
    $argumentsList.Add("/NFL") # No File List
    $argumentsList.Add("/NDL") # No Directory List
    $argumentsList.Add("/NP")  # No Progress
    $argumentsList.Add("/NJH") # No Job Header
    $argumentsList.Add("/NJS") # No Job Summary
    
    if ($RobocopySettings.ContainsKey('Verbose') -and $RobocopySettings.Verbose -eq $true) {
        $argumentsList.Add("/V")
    }

    return $argumentsList.ToArray()
}
#endregion

#region --- Private Helper: Execute Robocopy Transfer ---
function Invoke-RobocopyTransferInternal {
    [CmdletBinding()]
    param(
        [string]$SourceFile,
        [string]$DestinationDirectory,
        [hashtable]$RobocopySettings,
        [scriptblock]$Logger
    )
    # PSSA Appeasement and initial log entry:
    & $Logger -Message "UNC.Target/Invoke-RobocopyTransferInternal: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    try {
        $arguments = Build-RobocopyArgumentsInternal -SourceFile $SourceFile -DestinationDirectory $DestinationDirectory -RobocopySettings $RobocopySettings
        & $LocalWriteLog -Message "      - Robocopy command: robocopy.exe $($arguments -join ' ')" -Level "DEBUG"

        # Corrected Start-Process call: Removed the invalid redirection parameters.
        $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        
        # Robocopy exit codes: < 8 indicates success (or at least no failures).
        # 0 = No errors, no files copied. 1 = Files copied successfully. 2 = Extra files exist. 3 = 1+2.
        # 5 = 1+4 (some mismatches). 7 = 1+2+4.
        # >= 8 indicates at least one failure.
        if ($process.ExitCode -lt 8) {
            return @{ Success = $true; ExitCode = $process.ExitCode }
        }
        else {
            return @{ Success = $false; ExitCode = $process.ExitCode; ErrorMessage = "Robocopy failed with exit code $($process.ExitCode). See system logs for details." }
        }
    }
    catch {
        return @{ Success = $false; ExitCode = -1; ErrorMessage = "Failed to execute Robocopy process. Error: $($_.Exception.Message)" }
    }
}
#endregion

#region --- UNC Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    # PSSA Appeasement: Use the parameter for logging context.
    & $Logger -Message "Replicate.Target/Test-PoShBackupTargetConnectivity: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    & $LocalWriteLog -Message "  - Replicate Target: Testing connectivity for all configured destination paths..." -Level "INFO"

    if (-not ($TargetSpecificSettings -is [array]) -or $TargetSpecificSettings.Count -eq 0) {
        return @{ Success = $false; Message = "TargetSpecificSettings is not a valid, non-empty array of destinations." }
    }

    $allPathsSuccessful = $true
    $messages = [System.Collections.Generic.List[string]]::new()

    $destinationIndex = 0
    foreach ($destination in $TargetSpecificSettings) {
        $destinationIndex++
        $destPath = $destination.Path
        $messagePrefix = "    - Destination $destinationIndex ('$destPath'): "
        
        if (-not $PSCmdlet.ShouldProcess($destPath, "Test Path Accessibility")) {
            $messages.Add("$messagePrefix Test skipped by user.")
            $allPathsSuccessful = $false
            continue
        }

        try {
            if (Test-Path -LiteralPath $destPath -PathType Container -ErrorAction Stop) {
                $messages.Add("$messagePrefix SUCCESS - Path is accessible.")
            }
            else {
                $messages.Add("$messagePrefix FAILED - Path not found or is not a directory.")
                $allPathsSuccessful = $false
            }
        }
        catch {
            $messages.Add("$messagePrefix FAILED - An error occurred while testing path. Error: $($_.Exception.Message)")
            $allPathsSuccessful = $false
        }
    }

    $finalMessage = "Replication Target Health Check: "
    $finalMessage += if ($allPathsSuccessful) { "All $($TargetSpecificSettings.Count) destination paths are accessible." } else { "One or more destination paths are not accessible." }
    $finalMessage += [Environment]::NewLine + ($messages -join [Environment]::NewLine)

    return @{ Success = $allPathsSuccessful; Message = $finalMessage }
}
#endregion

#region --- Replicate Target Settings Validation Function ---
function Invoke-PoShBackupReplicateTargetSettingsValidation {
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

    # Explicit PSSA Appeasement: Directly use the Logger parameter once.
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "Replicate.Target/Invoke-PoShBackupReplicateTargetSettingsValidation: Logger active for target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    # Validate the ContinueOnError setting at the root of the target instance config
    if ($TargetInstanceConfiguration.ContainsKey('ContinueOnError') -and -not ($TargetInstanceConfiguration.ContinueOnError -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'ContinueOnError' must be a boolean (`$true` or `$false`) if defined.")
    }

    # Safely get the TargetSpecificSettings
    if (-not $TargetInstanceConfiguration.ContainsKey('TargetSpecificSettings')) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Required key 'TargetSpecificSettings' is missing.")
        return # Cannot proceed
    }
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    if (-not ($TargetSpecificSettings -is [array])) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' must be an Array of destination configurations, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return 
    }
    if ($TargetSpecificSettings.Count -eq 0) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$fullPathToSettings'.")
    }
    for ($i = 0; $i -lt $TargetSpecificSettings.Count; $i++) {
        $destConfig = $TargetSpecificSettings[$i]
        $destConfigPath = "$fullPathToSettings[$i]"
        if (-not ($destConfig -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'.")
            continue 
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
        }
    }
}
#endregion

#region --- Replicate Target Transfer Function ---
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
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet 
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "Replicate.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName', Target '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG" -ErrorAction SilentlyContinue
        # Corrected this line to use the $JobName parameter directly
        $contextMessage = "  - Replicate.Target Context (PSSA): JobName='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $JobName, $LocalArchiveCreationTimestamp, $PasswordInUse
        & $Logger -Message $contextMessage -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_ 
    & $LocalWriteLog -Message "`n[INFO] Replicate Target: Starting replication of file '$ArchiveFileName' for Job '$JobName' using Target Instance '$targetNameForLog'." -Level "INFO"
    & $LocalWriteLog -Message "  - Replicate Target: Local source file: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local File Size: $(Format-FileSize -Bytes $LocalArchiveSizeBytes)" -Level "DEBUG"
    
    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allReplicationsForThisFileSucceeded = $true # Tracks success for *this specific file* across all its destinations
    $aggregatedErrorMessagesForThisFile = [System.Collections.Generic.List[string]]::new()
    $replicationDetailsListForThisFile = [System.Collections.Generic.List[hashtable]]::new()
    $firstSuccessfulRemotePathForThisFile = $null

    if (-not $TargetInstanceConfiguration.TargetSpecificSettings -is [array] -or $TargetInstanceConfiguration.TargetSpecificSettings.Count -eq 0) {
        $overallStopwatch.Stop()
        $errorMessageText = "Replicate Target '$targetNameForLog': 'TargetSpecificSettings' must be a non-empty array of destination configurations."
        & $LocalWriteLog -Message "[ERROR] $errorMessageText" -Level "ERROR"
        return @{ Success = $false; RemotePath = "Configuration Error"; ErrorMessage = $errorMessageText; TransferSize = 0; TransferDuration = $overallStopwatch.Elapsed; ReplicationDetails = $replicationDetailsListForThisFile }
    }
    $destinationConfigs = $TargetInstanceConfiguration.TargetSpecificSettings
    
    # NEW: Get the ContinueOnError setting. Default to $false (stop on error).
    $continueOnError = if ($TargetInstanceConfiguration.ContainsKey('ContinueOnError')) { [bool]$TargetInstanceConfiguration.ContinueOnError } else { $false }
    & $LocalWriteLog -Message "  - Replicate Target '$targetNameForLog': Policy is to $(if($continueOnError){'CONTINUE'}else{'STOP'}) on destination error." -Level "INFO"
    & $LocalWriteLog -Message "  - Replicate Target '$targetNameForLog': Will attempt to replicate file '$ArchiveFileName' to $($destinationConfigs.Count) destination(s)." -Level "INFO"

    foreach ($destConfig in $destinationConfigs) {
        $singleDestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $currentDestErrorMessage = $null
        $currentDestSuccess = $false
        $currentDestTransferSize = 0
        $currentFullDestArchivePath = "N/A (Path not determined)"

        if (-not ($destConfig -is [hashtable])) {
            $currentDestErrorMessage = "Invalid destination configuration item (not a hashtable) for '$targetNameForLog'."
            & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
            $allReplicationsForThisFileSucceeded = $false; $aggregatedErrorMessagesForThisFile.Add($currentDestErrorMessage); $singleDestStopwatch.Stop()
            $replicationDetailsListForThisFile.Add(@{ Path = "Invalid Config Item"; Status = "Failure"; Error = $currentDestErrorMessage; Size = 0; Duration = $singleDestStopwatch.Elapsed }); continue
        }
        $currentDestPathRaw = $destConfig.Path
        if ([string]::IsNullOrWhiteSpace($currentDestPathRaw)) {
            $currentDestErrorMessage = "Destination 'Path' is missing or empty for '$targetNameForLog'."
            & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
            $allReplicationsForThisFileSucceeded = $false; $aggregatedErrorMessagesForThisFile.Add($currentDestErrorMessage); $singleDestStopwatch.Stop()
            $replicationDetailsListForThisFile.Add(@{ Path = "Missing Path in Config"; Status = "Failure"; Error = $currentDestErrorMessage; Size = 0; Duration = $singleDestStopwatch.Elapsed }); continue
        }
        $currentDestPathBase = $currentDestPathRaw.TrimEnd("\/")
        $currentDestCreateJobSubDir = if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and $destConfig.CreateJobNameSubdirectory -is [boolean]) { $destConfig.CreateJobNameSubdirectory } else { $false }
        $currentDestFinalDir = if ($currentDestCreateJobSubDir) { Join-Path -Path $currentDestPathBase -ChildPath $JobName } else { $currentDestPathBase }
        $currentFullDestArchivePath = Join-Path -Path $currentDestFinalDir -ChildPath $ArchiveFileName 

        & $LocalWriteLog -Message "    - Replicate Target '$targetNameForLog' -> Dest Path Base: '$currentDestPathBase' (Subdir: $currentDestCreateJobSubDir, Final Archive Path for this file: '$currentFullDestArchivePath')" -Level "INFO"

        if ($IsSimulateMode.IsPresent) {
            $simMessage = "SIMULATE: The archive file '$ArchiveFileName' would be replicated to the destination '$currentDestPathBase'."
            if ($currentDestCreateJobSubDir) {
                $simMessage += " A subdirectory for the job ('$JobName') would be created, making the final path '$currentFullDestArchivePath'."
            }
            & $LocalWriteLog -Message $simMessage -Level "SIMULATE"

            if ($destConfig.ContainsKey('RetentionSettings') -and $destConfig.RetentionSettings.KeepCount -gt 0) {
                & $LocalWriteLog -Message "SIMULATE: After replication, the retention policy (Keep: $($destConfig.RetentionSettings.KeepCount)) would be applied to this destination." -Level "SIMULATE"
            }
            $currentDestSuccess = $true; $currentDestTransferSize = $LocalArchiveSizeBytes
            if ($null -eq $firstSuccessfulRemotePathForThisFile) { $firstSuccessfulRemotePathForThisFile = $currentFullDestArchivePath }
        }
        else {
            $ensurePathResult = Initialize-RemotePathInternal -Path $currentDestFinalDir -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
            if (-not $ensurePathResult.Success) {
                $currentDestErrorMessage = "Failed to ensure destination directory '$currentDestFinalDir'. Error: $($ensurePathResult.ErrorMessage)"
                & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
                $allReplicationsForThisFileSucceeded = $false; $aggregatedErrorMessagesForThisFile.Add($currentDestErrorMessage)
            }
            else {
                if (-not $PSCmdlet.ShouldProcess($currentFullDestArchivePath, "Replicate File to Destination")) {
                    $currentDestErrorMessage = "File copy to '$currentFullDestArchivePath' skipped by user."
                    & $LocalWriteLog -Message "[WARNING] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "WARNING"
                    # Not setting $allReplicationsForThisFileSucceeded to $false as it's a user skip, not a failure.
                }
                else {
                    & $LocalWriteLog -Message "      - Replicate Target '$targetNameForLog': Copying file '$ArchiveFileName' to '$currentFullDestArchivePath'..." -Level "INFO"
                    try {
                        Copy-Item -LiteralPath $LocalArchivePath -Destination $currentFullDestArchivePath -Force -ErrorAction Stop
                        $currentDestSuccess = $true
                        if (Test-Path -LiteralPath $currentFullDestArchivePath -PathType Leaf) { $currentDestTransferSize = (Get-Item -LiteralPath $currentFullDestArchivePath).Length }
                        if ($null -eq $firstSuccessfulRemotePathForThisFile) { $firstSuccessfulRemotePathForThisFile = $currentFullDestArchivePath }
                        & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': File '$ArchiveFileName' copied successfully to '$currentFullDestArchivePath'." -Level "SUCCESS"
                    }
                    catch {
                        $currentDestErrorMessage = "Failed to copy file '$ArchiveFileName' to '$currentFullDestArchivePath'. Error: $($_.Exception.Message)"
                        & $LocalWriteLog -Message "[ERROR] Replicate Target '$targetNameForLog': $currentDestErrorMessage" -Level "ERROR"
                        $allReplicationsForThisFileSucceeded = $false; $aggregatedErrorMessagesForThisFile.Add($currentDestErrorMessage)
                    }
                }
            }
        }

        # Retention for this specific destination path
        if ($currentDestSuccess -and $destConfig.ContainsKey('RetentionSettings') -and $destConfig.RetentionSettings -is [hashtable] -and `
                $destConfig.RetentionSettings.ContainsKey('KeepCount') -and $destConfig.RetentionSettings.KeepCount -is [int] -and `
                $destConfig.RetentionSettings.KeepCount -gt 0) {
            $destKeepCount = $destConfig.RetentionSettings.KeepCount
            & $LocalWriteLog -Message "      - Replicate Target '$targetNameForLog': Applying retention (KeepCount: $destKeepCount) in directory '$currentDestFinalDir' for instances matching base '$ArchiveBaseName'." -Level "INFO"
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Replicate Target '$targetNameForLog': Would apply retention in '$currentDestFinalDir' for base '$ArchiveBaseName', keeping $destKeepCount instances." -Level "SIMULATE"
            }
            else {
                try {
                    if (-not (Test-Path -LiteralPath $currentDestFinalDir -PathType Container)) {
                        & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Directory '$currentDestFinalDir' not found for retention. Skipping." -Level "WARNING"
                    }
                    else {
                        $remoteInstancesAtDest = Group-LocalOrUNCBackupInstancesInternal -Directory $currentDestFinalDir -BaseNameToMatch $ArchiveBaseName -PrimaryArchiveExtension $ArchiveExtension -Logger $Logger
                        if ($remoteInstancesAtDest.Count -gt $destKeepCount) {
                            $sortedInstancesAtDest = $remoteInstancesAtDest.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                            $instancesToDeleteAtDest = $sortedInstancesAtDest | Select-Object -Skip $destKeepCount
                            & $LocalWriteLog -Message "        - Replicate Target '$targetNameForLog': Found $($remoteInstancesAtDest.Count) instances at '$currentDestFinalDir'. Will delete $($instancesToDeleteAtDest.Count) older instance(s)." -Level "INFO"
                            foreach ($instanceEntryToDelete in $instancesToDeleteAtDest) {
                                & $LocalWriteLog -Message "          - Replicate Target '$targetNameForLog': Preparing to delete instance '$($instanceEntryToDelete.Name)' (SortTime: $($instanceEntryToDelete.Value.SortTime)) from '$currentDestFinalDir'." -Level "WARNING"
                                foreach ($fileToDeleteInInstance in $instanceEntryToDelete.Value.Files) {
                                    if (-not $PSCmdlet.ShouldProcess($fileToDeleteInInstance.FullName, "Delete Replicated File/Part (Retention)")) {
                                        & $LocalWriteLog -Message "            - Deletion of '$($fileToDeleteInInstance.FullName)' skipped by user." -Level "WARNING"; continue
                                    }
                                    & $LocalWriteLog -Message "            - Deleting: '$($fileToDeleteInInstance.FullName)'" -Level "WARNING"
                                    try { Remove-Item -LiteralPath $fileToDeleteInInstance.FullName -Force -ErrorAction Stop; & $LocalWriteLog "              - Status: DELETED" -Level "SUCCESS" }
                                    catch {
                                        & $LocalWriteLog -Message "              - Status: FAILED! Error: $($_.Exception.Message)" -Level "ERROR"; # A retention failure makes the overall less successful
                                    }
                                }
                            }
                        }
                        else { & $LocalWriteLog "        - Replicate Target '$targetNameForLog': No old instances to delete at '$currentDestFinalDir'." -Level "INFO" }
                    }
                }
                catch {
                    $retError = "Error during retention for '$currentDestFinalDir': $($_.Exception.Message)"
                    & $LocalWriteLog -Message "[WARNING] Replicate Target '$targetNameForLog': $retError" -Level "WARNING"; $aggregatedErrorMessagesForThisFile.Add($retError); # $allReplicationsForThisFileSucceeded = $false
                }
            }
        }
        $singleDestStopwatch.Stop()
        $replicationDetailsListForThisFile.Add(@{ Path = $currentFullDestArchivePath; Status = if ($currentDestSuccess) { "Success" }else { "Failure" }; Error = $currentDestErrorMessage; Size = $currentDestTransferSize; Duration = $singleDestStopwatch.Elapsed })
        if (-not $currentDestSuccess) {
            $allReplicationsForThisFileSucceeded = $false
            if (-not $continueOnError) {
                & $LocalWriteLog -Message "  - Replicate Target '$targetNameForLog': Halting further replications for this file as ContinueOnError is false." -Level "WARNING"
                break # Exit the foreach loop
            }
        }
    } # End foreach $destConfig

    $overallStopwatch.Stop()
    $finalRemotePathDisplayForThisFile = if ($allReplicationsForThisFileSucceeded -and $replicationDetailsListForThisFile.Count -gt 0) {
        if ($replicationDetailsListForThisFile.Count -eq 1) { $firstSuccessfulRemotePathForThisFile }
        else { "Replicated file '$ArchiveFileName' to $($replicationDetailsListForThisFile.Count) locations successfully." }
    }
    elseif ($replicationDetailsListForThisFile.Count -gt 0 -and $null -ne $firstSuccessfulRemotePathForThisFile) {
        "Partially replicated file '$ArchiveFileName' (see details); first success: $firstSuccessfulRemotePathForThisFile"
    }
    else { "Replication of file '$ArchiveFileName' failed or no valid destinations processed." }

    & $LocalWriteLog -Message ("[INFO] Replicate Target: Finished replication of file '{0}' for Job '{1}', Target '{2}'. Overall Success for this file: {3}." -f $ArchiveFileName, $JobName, $targetNameForLog, $allReplicationsForThisFileSucceeded) -Level "INFO"

    return @{
        Success            = $allReplicationsForThisFileSucceeded
        RemotePath         = $finalRemotePathDisplayForThisFile # Path for this specific file, could be a summary string
        ErrorMessage       = if ($aggregatedErrorMessagesForThisFile.Count -gt 0) { $aggregatedErrorMessagesForThisFile -join "; " } else { $null }
        TransferSize       = $LocalArchiveSizeBytes # Size of the source file that was replicated
        TransferDuration   = $overallStopwatch.Elapsed # Total time for this file across all destinations
        ReplicationDetails = $replicationDetailsListForThisFile # Detailed status per destination for this file
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupReplicateTargetSettingsValidation, Test-PoShBackupTargetConnectivity
