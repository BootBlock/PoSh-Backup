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
        This can be done using the standard `Copy-Item` or, if configured, the more robust
        `robocopy.exe` for resilient network transfers.
    -   If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, it applies a
        count-based retention policy. This policy now correctly identifies all related files
        of a backup instance (all volumes and any manifest) for deletion.
    -   Supports simulation mode.
    -   Returns a status for the individual file transfer.

    A function, 'Invoke-PoShBackupUNCTargetSettingsValidation', validates 'TargetSpecificSettings'.
    A new function, 'Test-PoShBackupTargetConnectivity', validates the accessibility of the UNC path.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.1 # Enhanced -Simulate output to be more descriptive.
    DateCreated:    19-May-2025
    LastModified:   23-Jun-2025
    Purpose:        UNC Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The user/account running PoSh-Backup must have appropriate permissions
                    to read/write/delete on the target UNC path.
                    Robocopy.exe must be available on the system (standard on modern Windows).
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
    & $Logger -Message "UNC.Target/Group-LocalOrUNCBackupInstancesInternal: Logger active. Scanning '$Directory' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Define LocalWriteLog for subsequent use within this function if needed by other parts of it.
    $LocalWriteLog = { param([string]$Message, [string]$Level = "DEBUG") & $Logger -Message $Message -Level $Level }
    
    $instances = @{}
    $literalBase = [regex]::Escape($BaseNameToMatch) # BaseNameToMatch is "JobName [DateStamp]"
    $literalExt = [regex]::Escape($PrimaryArchiveExtension) # PrimaryArchiveExtension is ".7z"

    $fileFilterForInstance = "$BaseNameToMatch*"

    Get-ChildItem -Path $Directory -Filter $fileFilterForInstance -File -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        $instanceKey = $null
        
        $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$"
        $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$"
        $singleFilePattern = "^($literalBase$literalExt)$"
        $sfxFilePattern = "^($literalBase\.[a-zA-Z0-9]+)$"
        $sfxManifestPattern = "^($literalBase\.[a-zA-Z0-9]+)\.manifest\.[a-zA-Z0-9]+$"

        if ($file.Name -match $splitVolumePattern) { $instanceKey = $Matches[1] }
        elseif ($file.Name -match $splitManifestPattern) { $instanceKey = $Matches[1] }
        elseif ($file.Name -match $sfxManifestPattern) { $instanceKey = $Matches[1] }
        elseif ($file.Name -match $singleFilePattern) { $instanceKey = $Matches[1] }
        elseif ($file.Name -match $sfxFilePattern) { $instanceKey = $Matches[1] }
        else {
            if ($file.Name.StartsWith($BaseNameToMatch)) {
                $basePlusExtMatch = $file.Name -match "^($literalBase(\.[^.\s]+)?)"
                if ($basePlusExtMatch) {
                    $potentialKey = $Matches[1]
                    if ($file.Name -match ([regex]::Escape($potentialKey) + "\.\d{3,}") -or `
                            $file.Name -match ([regex]::Escape($potentialKey) + "\.manifest\.[a-zA-Z0-9]+$") -or `
                            $file.Name -eq $potentialKey) {
                        $instanceKey = $potentialKey
                    }
                }
            }
        }

        if ($null -eq $instanceKey) {
            & $LocalWriteLog -Message "UNC.Target/GroupHelper: Could not determine instance key for file '$($file.Name)'. Base: '$BaseNameToMatch', PrimaryExt: '$PrimaryArchiveExtension'. Skipping." -Level "VERBOSE"
            return
        }

        if (-not $instances.ContainsKey($instanceKey)) {
            $instances[$instanceKey] = @{
                SortTime = $file.CreationTime
                Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
        }
        $instances[$instanceKey].Files.Add($file)

        if ($file.Name -match "$literalExt\.001$") {
            if ($file.CreationTime -lt $instances[$instanceKey].SortTime) {
                $instances[$instanceKey].SortTime = $file.CreationTime
            }
        }
    }
    
    foreach ($key in $instances.Keys) {
        if ($instances[$key].Files.Count -gt 0) {
            $firstVolume = $instances[$key].Files | Where-Object { $_.Name -match "$literalExt\.001$" } | Sort-Object CreationTime | Select-Object -First 1
            if ($firstVolume) {
                if ($firstVolume.CreationTime -lt $instances[$key].SortTime) {
                    $instances[$key].SortTime = $firstVolume.CreationTime
                }
            }
            else {
                $earliestFileInGroup = $instances[$key].Files | Sort-Object CreationTime | Select-Object -First 1
                if ($earliestFileInGroup -and $earliestFileInGroup.CreationTime -lt $instances[$key].SortTime) {
                    $instances[$key].SortTime = $earliestFileInGroup.CreationTime
                }
            }
        }
    }

    & $LocalWriteLog -Message "UNC.Target/GroupHelper: Found $($instances.Keys.Count) distinct instances in '$Directory' for base '$BaseNameToMatch'."
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
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "UNC.Target/Test-PoShBackupTargetConnectivity: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    $uncPath = $TargetSpecificSettings.UNCRemotePath
    & $LocalWriteLog -Message "  - UNC Target: Testing connectivity to path '$uncPath'..." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($uncPath, "Test Path Accessibility")) {
        return @{ Success = $false; Message = "Connectivity test skipped by user." }
    }

    try {
        if (Test-Path -LiteralPath $uncPath -PathType Container -ErrorAction Stop) {
            & $LocalWriteLog -Message "    - SUCCESS: Path '$uncPath' is accessible." -Level "SUCCESS"
            return @{ Success = $true; Message = "Path is accessible." }
        }
        else {
            $errorMessage = "Path '$uncPath' was not found or is not a container/directory. Please check the path and permissions."
            & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
            return @{ Success = $false; Message = $errorMessage }
        }
    }
    catch {
        $errorMessage = "An error occurred while testing path '$uncPath'. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
}
#endregion

#region --- UNC Target Settings Validation Function ---
function Invoke-PoShBackupUNCTargetSettingsValidation {
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

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings

    # Use the optional logger parameter if it was provided.
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
    if ($TargetSpecificSettings.ContainsKey('UseRobocopy') -and -not ($TargetSpecificSettings.UseRobocopy -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'UseRobocopy' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.UseRobocopy'.")
    }
    if ($TargetSpecificSettings.ContainsKey('RobocopySettings') -and -not ($TargetSpecificSettings.RobocopySettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'RobocopySettings' in 'TargetSpecificSettings' must be a Hashtable if defined. Path: '$fullPathToSettings.RobocopySettings'.")
    }
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
        [System.Management.Automation.PSCmdlet]$PSCmdlet 
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "UNC.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName', Target Instance '$($TargetInstanceConfiguration._TargetInstanceName_)', File '$ArchiveFileName'." -Level "DEBUG" -ErrorAction SilentlyContinue
        # Corrected this line to use the $JobName parameter directly
        $contextMessage = "  - UNC.Target Context (PSSA): JobName='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $JobName, $LocalArchiveCreationTimestamp, $PasswordInUse
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
    & $LocalWriteLog -Message "`n[INFO] UNC Target: Starting transfer of file '$ArchiveFileName' for Job '$JobName' to Target '$targetNameForLog'." -Level "INFO"

    $result = @{
        Success = $false; RemotePath = $null; ErrorMessage = $null
        TransferSize = 0; TransferDuration = New-TimeSpan; TransferSizeFormatted = "N/A"
    }

    if (-not $TargetInstanceConfiguration.TargetSpecificSettings.ContainsKey('UNCRemotePath') -or `
            [string]::IsNullOrWhiteSpace($TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath)) {
        $result.ErrorMessage = "UNC Target '$targetNameForLog': 'UNCRemotePath' is missing or empty in TargetSpecificSettings."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        return $result
    }
    $uncRemoteBasePathFromConfig = $TargetInstanceConfiguration.TargetSpecificSettings.UNCRemotePath.TrimEnd("\/")
    $createJobSubDir = $TargetInstanceConfiguration.TargetSpecificSettings.CreateJobNameSubdirectory -eq $true
    $remoteFinalDirectoryForArchiveSet = if ($createJobSubDir) { Join-Path -Path $uncRemoteBasePathFromConfig -ChildPath $JobName } else { $uncRemoteBasePathFromConfig }
    $fullRemoteArchivePathForThisFile = Join-Path -Path $remoteFinalDirectoryForArchiveSet -ChildPath $ArchiveFileName
    $result.RemotePath = $fullRemoteArchivePathForThisFile 

    $useRobocopy = $TargetInstanceConfiguration.TargetSpecificSettings.UseRobocopy -eq $true
    $robocopySettings = $TargetInstanceConfiguration.TargetSpecificSettings.RobocopySettings

    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Local source file: '$LocalArchivePath'" -Level "DEBUG"
    & $LocalWriteLog -Message "    - Local File Size: $(Format-BytesInternal -Bytes $LocalArchiveSizeBytes)" -Level "DEBUG"
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Remote destination for this file: '$fullRemoteArchivePathForThisFile'" -Level "DEBUG"
    & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': Transfer method: $(if($useRobocopy){'Robocopy'}else{'Copy-Item'})" -Level "DEBUG"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($IsSimulateMode.IsPresent) {
            $transferMethod = if ($useRobocopy) { 'Robocopy' } else { 'Copy-Item' }
            & $LocalWriteLog -Message "SIMULATE: The destination directory '$remoteFinalDirectoryForArchiveSet' would be created if it does not exist." -Level "SIMULATE"
            & $LocalWriteLog -Message "SIMULATE: The archive file '$LocalArchivePath' would be copied to the UNC path '$fullRemoteArchivePathForThisFile' using $transferMethod." -Level "SIMULATE"
            $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        }
        else {
            $ensurePathResult = Initialize-RemotePathInternal -Path $remoteFinalDirectoryForArchiveSet -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
            if (-not $ensurePathResult.Success) { throw ("Failed to ensure remote directory '$remoteFinalDirectoryForArchiveSet' exists. Error: " + $ensurePathResult.ErrorMessage) }

            if (-not $PSCmdlet.ShouldProcess($fullRemoteArchivePathForThisFile, "Copy File to UNC Path")) {
                throw ("File copy to '$fullRemoteArchivePathForThisFile' skipped by user.")
            }
            
            if ($useRobocopy) {
                & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Copying file '$ArchiveFileName' using Robocopy..." -Level "INFO"
                $roboResult = Invoke-RobocopyTransferInternal -SourceFile $LocalArchivePath -DestinationDirectory $remoteFinalDirectoryForArchiveSet -RobocopySettings $robocopySettings -Logger $Logger
                if (-not $roboResult.Success) { throw $roboResult.ErrorMessage }
            }
            else {
                & $LocalWriteLog -Message "      - UNC Target '$targetNameForLog': Copying file '$ArchiveFileName' using Copy-Item..." -Level "INFO"
                Copy-Item -LiteralPath $LocalArchivePath -Destination $fullRemoteArchivePathForThisFile -Force -ErrorAction Stop
            }
            
            $result.Success = $true
            if (Test-Path -LiteralPath $fullRemoteArchivePathForThisFile -PathType Leaf) {
                $result.TransferSize = (Get-Item -LiteralPath $fullRemoteArchivePathForThisFile).Length
            }
            & $LocalWriteLog -Message ("    - UNC Target '{0}': File '{1}' copied successfully." -f $targetNameForLog, $ArchiveFileName) -Level "SUCCESS"
        }

        if (($result.Success) -and `
                $TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {

            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            $retentionActionMessage = "Applying retention policy (Keep: $remoteKeepCount) to the remote destination '$remoteFinalDirectoryForArchiveSet'."

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: $retentionActionMessage" -Level "SIMULATE"
            }
            else {
                & $LocalWriteLog -Message "  - UNC Target '$targetNameForLog': $retentionActionMessage" -Level "INFO"
                if (Test-Path -LiteralPath $remoteFinalDirectoryForArchiveSet -PathType Container) {
                    $allRemoteInstances = Group-LocalOrUNCBackupInstancesInternal -Directory $remoteFinalDirectoryForArchiveSet `
                        -BaseNameToMatch $ArchiveBaseName `
                        -PrimaryArchiveExtension $ArchiveExtension `
                        -Logger $Logger
                    
                    if ($allRemoteInstances.Count -gt $remoteKeepCount) {
                        $sortedInstances = $allRemoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                        $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                        
                        & $LocalWriteLog -Message ("    - UNC Target '{0}': Found {1} remote backup instances. Will attempt to delete {2} older instance(s)." -f $targetNameForLog, $allRemoteInstances.Count, $instancesToDelete.Count) -Level "INFO"

                        foreach ($instanceEntry in $instancesToDelete) {
                            & $LocalWriteLog "      - UNC Target '$targetNameForLog': Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                            foreach ($remoteFileToDelete in $instanceEntry.Value.Files) {
                                if (-not $PSCmdlet.ShouldProcess($remoteFileToDelete.FullName, "Delete Remote Archive File/Part (Retention)")) {
                                    & $LocalWriteLog "        - Deletion of '$($remoteFileToDelete.FullName)' skipped by user." -Level "WARNING"; continue
                                }
                                & $LocalWriteLog "        - Deleting: '$($remoteFileToDelete.FullName)'" -Level "WARNING"
                                try { Remove-Item -LiteralPath $remoteFileToDelete.FullName -Force -ErrorAction Stop; & $LocalWriteLog "          - Status: DELETED (Remote Retention)" -Level "SUCCESS" }
                                catch { & $LocalWriteLog "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR"; }
                            }
                        }
                    }
                    else { & $LocalWriteLog "    - UNC Target '$targetNameForLog': No old instances to delete based on retention count $remoteKeepCount." -Level "INFO" }
                }
            }
        }
    }
    catch {
        $result.ErrorMessage = "UNC Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-BytesInternal -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] UNC Target: Finished transfer attempt for Job '{0}' to Target '{1}', File '{2}'. Success: {3}." -f $JobName, $targetNameForLog, $ArchiveFileName, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupUNCTargetSettingsValidation, Test-PoShBackupTargetConnectivity
