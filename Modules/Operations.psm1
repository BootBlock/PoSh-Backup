<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This includes gathering effective job configurations, handling VSS (Volume Shadow Copy Service)
    creation and cleanup, executing 7-Zip for archiving and testing, applying retention policies,
    and checking destination free space. It also orchestrates password retrieval and hook script execution.

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the workhorse for each backup task, taking a job's configuration and performing all
    necessary steps to create an archive.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Gathers the effective configuration for the job by merging global, job-specific, and
        command-line override settings.
    2.  Validates and, if necessary, creates the destination directory.
    3.  Retrieves the archive password (if configured for the job) using the PasswordManager module.
    4.  Executes any pre-backup hook scripts defined for the job.
    5.  If VSS (Volume Shadow Copy Service) is enabled for the job:
        a. Checks for Administrator privileges (required for VSS).
        b. Creates VSS shadow copies of the source volumes.
        c. Updates source paths to point to the VSS shadow copy paths for the backup.
    6.  Performs a pre-backup check for sufficient free space on the destination drive (if configured).
    7.  Applies the backup retention policy, deleting older archives to make space for the new one,
        adhering to the configured retention count.
    8.  Constructs the 7-Zip command-line arguments based on the effective job configuration,
        including archive type, compression settings, exclusions, and password (if used).
    9.  Executes 7-Zip to create the archive, with support for retries on failure.
    10. Optionally tests the integrity of the newly created archive using 7-Zip.
    11. Cleans up VSS shadow copies (if they were created).
    12. Securely disposes of any temporary password files.
    13. Executes any post-backup hook scripts (on success, on failure, or always).
    14. Returns a status indicating the outcome of the job (Success, Warnings, Failure).

    This module relies on other PoSh-Backup modules like Utils.psm1 (for logging, config retrieval)
    and PasswordManager.psm1, and interacts directly with 7-Zip and the VSS subsystem via diskshadow.exe.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.7.1 # Corrected PSSA Select alias.
    DateCreated:    10-May-2025
    LastModified:   17-May-2025 # Corrected PSSA warning for Select alias.
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed and configured/auto-detectable.
                    Core PoSh-Backup modules: Utils.psm1, PasswordManager.psm1.
                    Administrator privileges are required for VSS functionality.
#>

#region --- Private Helper: Gather Job Configuration ---
# Not exported
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [ref]$JobReportDataRef
    )

    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value

    $effectiveConfig.OriginalSourcePath = $JobConfig.Path
    $effectiveConfig.BaseFileName       = $JobConfig.Name
    $reportData.JobConfiguration        = $JobConfig # Store a snapshot of the raw job config for reporting

    # Resolve various settings by checking job-specific, then global, then CLI overrides where applicable
    $effectiveConfig.DestinationDir = Get-ConfigValue -ConfigObject $JobConfig -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDestinationDir' -DefaultValue $null)
    $effectiveConfig.RetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionCount' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultRetentionCount' -DefaultValue 3)
    if ($effectiveConfig.RetentionCount -lt 0) { $effectiveConfig.RetentionCount = 0 } # Ensure retention is not negative
    $effectiveConfig.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDeleteToRecycleBin' -DefaultValue $false)

    # Password related settings
    $effectiveConfig.ArchivePasswordMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $effectiveConfig.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
    $effectiveConfig.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $effectiveConfig.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $effectiveConfig.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false # Legacy password toggle

    $effectiveConfig.HideSevenZipOutput = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HideSevenZipOutput' -DefaultValue $true

    # Archive format and naming settings
    $effectiveConfig.JobArchiveType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveType' -DefaultValue "-t7z")
    $effectiveConfig.JobArchiveExtension = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveExtension' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveExtension' -DefaultValue ".7z")
    $effectiveConfig.JobArchiveDateFormat = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveDateFormat' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd")

    # 7-Zip compression parameters
    $effectiveConfig.JobCompressionLevel = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionLevel' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionLevel' -DefaultValue "-mx=7")
    $effectiveConfig.JobCompressionMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionMethod' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionMethod' -DefaultValue "-m0=LZMA2")
    $effectiveConfig.JobDictionarySize = Get-ConfigValue -ConfigObject $JobConfig -Key 'DictionarySize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDictionarySize' -DefaultValue "-md=128m")
    $effectiveConfig.JobWordSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'WordSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultWordSize' -DefaultValue "-mfb=64")
    $effectiveConfig.JobSolidBlockSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SolidBlockSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSolidBlockSize' -DefaultValue "-ms=16g")
    $effectiveConfig.JobCompressOpenFiles = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressOpenFiles' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressOpenFiles' -DefaultValue $true)
    $effectiveConfig.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @())

    $_globalConfigThreads  = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 } # Job overrides global, global overrides 7zip default (0)
    $effectiveConfig.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)"} else {"-mmt"} # -mmt alone means auto

    # VSS settings, considering CLI overrides
    $effectiveConfig.JobEnableVSS = if ($CliOverrides.UseVSS) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false) }
    $effectiveConfig.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    $_vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $effectiveConfig.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $effectiveConfig.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $effectiveConfig.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    # Retry settings, considering CLI overrides
    $effectiveConfig.JobEnableRetries = if ($CliOverrides.EnableRetries) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $true) }
    $effectiveConfig.JobMaxRetryAttempts = Get-ConfigValue -ConfigObject $JobConfig -Key 'MaxRetryAttempts' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MaxRetryAttempts' -DefaultValue 3)
    $effectiveConfig.JobRetryDelaySeconds = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetryDelaySeconds' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetryDelaySeconds' -DefaultValue 60)

    # 7-Zip process priority, considering CLI overrides
    $effectiveConfig.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    } else {
        Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipProcessPriority' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipProcessPriority' -DefaultValue "Normal")
    }

    # Archive testing settings, considering CLI overrides
    $effectiveConfig.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'TestArchiveAfterCreation' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultTestArchiveAfterCreation' -DefaultValue $false) }

    # Free space check settings
    $effectiveConfig.JobMinimumRequiredFreeSpaceGB = Get-ConfigValue -ConfigObject $JobConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue 0)
    $effectiveConfig.JobExitOnLowSpace = Get-ConfigValue -ConfigObject $JobConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue $false)

    # Hook script paths
    $effectiveConfig.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    # Populate some initial report data based on these effective settings
    $reportData.SourcePath = if ($effectiveConfig.OriginalSourcePath -is [array]) {$effectiveConfig.OriginalSourcePath} else {@($effectiveConfig.OriginalSourcePath)}
    $reportData.VSSUsed = $effectiveConfig.JobEnableVSS
    $reportData.RetriesEnabled = $effectiveConfig.JobEnableRetries
    $reportData.ArchiveTested = $effectiveConfig.JobTestArchiveAfterCreation # Reflects intent to test, actual test result logged later
    $reportData.SevenZipPriority = $effectiveConfig.JobSevenZipProcessPriority

    $effectiveConfig.GlobalConfigRef = $GlobalConfig # Pass a reference to the global config for any further deep dives if needed

    return $effectiveConfig
}
#endregion

#region --- Private Helper: Construct 7-Zip Arguments ---
# Internal helper to build the argument list for 7z.exe
function Get-PoShBackup7ZipArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory)] [object]$CurrentJobSourcePathFor7Zip, # Can be string or array of strings
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null
    )
    $sevenZipArgs = [System.Collections.Generic.List[string]]::new()
    $sevenZipArgs.Add("a") # Add (archive) command

    # Add configured 7-Zip switches
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobArchiveType)) { $sevenZipArgs.Add($EffectiveConfig.JobArchiveType) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionLevel)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionLevel) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionMethod)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionMethod) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobDictionarySize)) { $sevenZipArgs.Add($EffectiveConfig.JobDictionarySize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobWordSize)) { $sevenZipArgs.Add($EffectiveConfig.JobWordSize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSolidBlockSize)) { $sevenZipArgs.Add($EffectiveConfig.JobSolidBlockSize) }
    if ($EffectiveConfig.JobCompressOpenFiles) { $sevenZipArgs.Add("-ssw") } # Compress shared files
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.ThreadsSetting)) {$sevenZipArgs.Add($EffectiveConfig.ThreadsSetting) } # -mmt or -mmt=N

    # Add default global exclusions (Recycle Bin, System Volume Information)
    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeRecycleBin' -DefaultValue '-x!$RECYCLE.BIN'))
    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeSysVolInfo' -DefaultValue '-x!System Volume Information'))

    # Add job-specific additional exclusions
    if ($EffectiveConfig.JobAdditionalExclusions -is [array] -and $EffectiveConfig.JobAdditionalExclusions.Count -gt 0) {
        $EffectiveConfig.JobAdditionalExclusions | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $exclusion = $_.Trim()
                # Ensure it's a valid 7-Zip exclusion switch if not already prefixed
                if (-not ($exclusion.StartsWith("-x!") -or $exclusion.StartsWith("-xr!") -or $exclusion.StartsWith("-i!") -or $exclusion.StartsWith("-ir!"))) {
                    $exclusion = "-x!$($exclusion)" # Default to exclude switch
                }
                $sevenZipArgs.Add($exclusion)
            }
        }
    }

    # Add password related switches if a password is in use
    if ($EffectiveConfig.PasswordInUseFor7Zip) {
        $sevenZipArgs.Add("-mhe=on") # Encrypt archive headers
        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {
            $sevenZipArgs.Add("-spf`"$TempPasswordFile`"") # Read password from temp file
        } else {
            Write-LogMessage "[WARNING] PasswordInUseFor7Zip is true but no temporary password file was provided to 7-Zip; the archive might not be password-protected as intended." -Level WARNING
        }
    }

    if ([string]::IsNullOrWhiteSpace($FinalArchivePath)) {
        Write-LogMessage "[CRITICAL] Final Archive Path is NULL or EMPTY in Get-PoShBackup7ZipArgument. 7-Zip command will likely fail or use an unexpected name." -Level ERROR
        # This situation should ideally be caught earlier, but it's a critical check here.
    }
    $sevenZipArgs.Add($FinalArchivePath) # The target archive path/name

    # Add source paths to be archived
    if ($CurrentJobSourcePathFor7Zip -is [array]) {
        $CurrentJobSourcePathFor7Zip | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$sevenZipArgs.Add($_)} }
    } elseif (-not [string]::IsNullOrWhiteSpace($CurrentJobSourcePathFor7Zip)) {
        $sevenZipArgs.Add($CurrentJobSourcePathFor7Zip)
    }
    return $sevenZipArgs.ToArray()
}
#endregion

#region --- Main Job Processing Function ---
function Invoke-PoShBackupJob {
    [CmdletBinding(SupportsShouldProcess=$true)]
    <#
    .SYNOPSIS
        Processes a single PoSh-Backup job, handling all operations from configuration gathering to archiving and reporting.
    .DESCRIPTION
        This is the core function for executing an individual backup job. It orchestrates VSS, 7-Zip,
        password management, retention policies, and hook script execution based on the provided
        job configuration and global settings.
    .PARAMETER JobName
        The unique name of the backup job being processed. Used for logging and identification.
    .PARAMETER JobConfig
        A hashtable containing the specific configuration settings for this backup job,
        as defined in the 'BackupLocations' section of the configuration file.
    .PARAMETER GlobalConfig
        A hashtable containing the global configuration settings for the PoSh-Backup script.
    .PARAMETER CliOverrides
        A hashtable containing any command-line parameter overrides that affect job execution
        (e.g., -UseVSS, -TestArchive).
    .PARAMETER PSScriptRootForPaths
        The root path of the main PoSh-Backup.ps1 script. Used for resolving relative paths
        to modules, themes, etc.
    .PARAMETER ActualConfigFile
        The full path to the primary configuration file that was loaded (e.g., Default.psd1 or a user-specified file).
        Passed to hook scripts.
    .PARAMETER JobReportDataRef
        A reference ([ref]) to an ordered hashtable. This function populates this hashtable with
        detailed information about the job's execution, which is then used for generating reports.
    .PARAMETER IsSimulateMode
        A switch. If $true, the function will simulate backup operations without making actual
        file system changes.
    .EXAMPLE
        # This function is typically called internally by PoSh-Backup.ps1
        # Example of how it might be invoked:
        # $reportData = [ordered]@{ JobName = "MyJob" }
        # $jobParams = @{
        #     JobName = "MyJob"
        #     JobConfig = $Configuration.BackupLocations.MyJob
        #     GlobalConfig = $Configuration
        #     CliOverrides = $cliOverrideSettings
        #     PSScriptRootForPaths = $PSScriptRoot
        #     ActualConfigFile = "C:\Path\To\Config.psd1"
        #     JobReportDataRef = ([ref]$reportData)
        #     IsSimulateMode = $false
        # }
        # $result = Invoke-PoShBackupJob @jobParams
        # if ($result.Status -eq "FAILURE") { Write-Error "Job failed!" }
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with a single key 'Status' indicating the outcome of the job:
        "SUCCESS", "WARNINGS", or "FAILURE".
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName,

        [Parameter(Mandatory=$true)]
        [hashtable]$JobConfig,

        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig,

        [Parameter(Mandatory=$true)]
        [hashtable]$CliOverrides,

        [Parameter(Mandatory=$true)]
        [string]$PSScriptRootForPaths,

        [Parameter(Mandatory=$true)]
        [string]$ActualConfigFile,

        [Parameter(Mandatory=$true)]
        [ref]$JobReportDataRef,

        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode
    )

    $currentJobStatus = "SUCCESS" # Assume success until an error or warning occurs
    $tempPasswordFilePath = $null
    $FinalArchivePath = $null
    $VSSPathsInUse = $null # Stores mappings of original paths to VSS shadow paths
    $reportData = $JobReportDataRef.Value # Dereference for easier access
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent # Log if this is a simulation run

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date # Record job start time if not already set
    }

    $plainTextPasswordForJob = $null # Will hold the plain text password temporarily if used

    try {
        # Step 1: Gather all effective configuration settings for this job
        $effectiveJobConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -JobReportDataRef $JobReportDataRef

        Write-LogMessage " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        Write-LogMessage "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        Write-LogMessage "   - Destination Directory  : $($effectiveJobConfig.DestinationDir)"
        Write-LogMessage "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        Write-LogMessage "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod)"
        # Additional key settings could be logged here at DEBUG level if needed

        # Step 2: Validate and create destination directory if it doesn't exist
        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            Write-LogMessage "FATAL: Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            Write-LogMessage "[INFO] Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($effectiveJobConfig.DestinationDir, "Create Directory")) {
                    try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-LogMessage "  - Destination directory created successfully." -Level SUCCESS }
                    catch { Write-LogMessage "FATAL: Failed to create destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR; throw "Failed to create destination directory for job '$JobName'." }
                }
            } else {
                Write-LogMessage "SIMULATE: Would create destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        # Step 3: Retrieve archive password if configured
        $isPasswordRequiredOrConfigured = ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $effectiveJobConfig.UsePassword
        $effectiveJobConfig.PasswordInUseFor7Zip = $false # Flag to indicate if a password will actually be used for 7zip

        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordManagerModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\PasswordManager.psm1"
                if (-not (Test-Path -LiteralPath $passwordManagerModulePath -PathType Leaf)) {
                    throw "PasswordManager.psm1 module not found at '$passwordManagerModulePath'. This module is required for password handling."
                }
                Import-Module -Name $passwordManagerModulePath -Force -ErrorAction Stop

                $passwordParams = @{
                    JobConfigForPassword = $effectiveJobConfig
                    JobName              = $JobName
                    IsSimulateMode       = $IsSimulateMode.IsPresent
                    Logger               = ${function:Write-LogMessage}
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams

                $reportData.PasswordSource = $passwordResult.PasswordSource # Record how the password was obtained (or attempted)

                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword
                    $effectiveJobConfig.PasswordInUseFor7Zip = $true

                    if ($IsSimulateMode.IsPresent) {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_poshbackup_pass.tmp") # Predictable name for simulation log
                        Write-LogMessage "SIMULATE: Would write password (obtained via $($reportData.PasswordSource)) to temporary file '$tempPasswordFilePath' for 7-Zip." -Level SIMULATE
                    } else {
                        if ($PSCmdlet.ShouldProcess("Temporary Password File", "Create and Write Password (details in DEBUG log)")) {
                            $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                            Set-Content -Path $tempPasswordFilePath -Value $plainTextPasswordForJob -Encoding UTF8 -Force -ErrorAction Stop
                            Write-LogMessage "   - Password (obtained via $($reportData.PasswordSource)) written to temporary file '$tempPasswordFilePath' for 7-Zip." -Level DEBUG
                        }
                    }
                } elseif ($isPasswordRequiredOrConfigured -and $effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                     # If a specific method (not "None") was configured but no password resulted, it's a fatal error.
                     Write-LogMessage "FATAL: Password was required for job '$JobName' via method '$($effectiveJobConfig.ArchivePasswordMethod)' but could not be obtained or was empty." -Level ERROR
                     throw "Password unavailable/empty for job '$JobName' using method '$($effectiveJobConfig.ArchivePasswordMethod)'."
                }
            } catch {
                Write-LogMessage "FATAL: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" -Level ERROR
                throw # Re-throw to halt job processing
            }
        } elseif ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"
        }


        # Step 4: Execute Pre-Backup Hook Script
        Invoke-HookScript -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                          -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                          -IsSimulateMode:$IsSimulateMode

        # Step 5: Handle VSS (Volume Shadow Copy Service) if enabled
        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath # Default to original paths
        if ($effectiveJobConfig.JobEnableVSS) {
            Write-LogMessage "`n[INFO] VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege)) {
                Write-LogMessage "FATAL: VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." -Level ERROR
                throw "VSS requires Administrator privileges for job '$JobName'."
            }

            $vssParams = @{
                SourcePathsToShadow = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath} else {@($effectiveJobConfig.OriginalSourcePath)}
                VSSContextOption = $effectiveJobConfig.JobVSSContextOption
                MetadataCachePath = $effectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $effectiveJobConfig.VSSPollingTimeoutSeconds
                PollingIntervalSeconds = $effectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams # This function handles its own ShouldProcess for creation

            if ($null -eq $VSSPathsInUse -or $VSSPathsInUse.Count -eq 0) {
                if (-not $IsSimulateMode.IsPresent) {
                    Write-LogMessage "[ERROR] VSS shadow copy creation failed or returned no usable paths for job '$JobName'. Attempting backup using original source paths." -Level ERROR
                    $reportData.VSSStatus = "Failed to create/map shadows"
                    # Allow fallback to original paths instead of failing the job entirely, but mark status as WARNINGS
                    if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
                } else {
                     Write-LogMessage "SIMULATE: VSS shadow copy creation would have been attempted for job '$JobName'. Simulating use of original paths." -Level SIMULATE
                     $reportData.VSSStatus = "Simulated (No Shadows Created/Needed)"
                }
            } else {
                Write-LogMessage "  - VSS shadow copies successfully created/mapped for job '$JobName'. Using shadow paths for backup." -Level VSS
                # Remap source paths to their VSS shadow equivalents
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object {
                        if ($VSSPathsInUse.ContainsKey($_)) { $VSSPathsInUse[$_] } else { $_ } # Fallback if a specific path within array failed VSS
                    }
                } else {
                    if ($VSSPathsInUse.ContainsKey($effectiveJobConfig.OriginalSourcePath)) { $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] } else { $effectiveJobConfig.OriginalSourcePath }
                }
                $reportData.VSSStatus = if ($IsSimulateMode.IsPresent) { "Simulated (Used)" } else { "Used" }
                $reportData.VSSShadowPaths = $VSSPathsInUse # Log the shadow paths used
            }
        } else {
            $reportData.VSSStatus = "Not Enabled"
        }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}


        # Step 6: Perform Pre-Backup Destination Free Space Check
        Write-LogMessage "`n[INFO] Performing Pre-Backup Operations for job '$JobName'..."
        Write-LogMessage "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})"

        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode)) {
            # Test-DestinationFreeSpace logs appropriate FATAL/WARNING and returns $false if job should stop
            throw "Low disk space condition met and configured to halt job '$JobName'." # This will be caught by the main try/catch
        }

        # Step 7: Determine final archive name and apply retention policy
        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat
        $ArchiveFileName = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)"
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileName
        $reportData.FinalArchivePath = $FinalArchivePath
        Write-LogMessage "`n[INFO] Target Archive for job '$JobName': $FinalArchivePath"

        $vbLoaded = $false # For Recycle Bin functionality
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { Write-LogMessage "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion. Error: $($_.Exception.Message)" -Level WARNING }
        }
        # Invoke-BackupRetentionPolicy handles its own ShouldProcess for deletions
        Invoke-BackupRetentionPolicy -DestinationDirectory $effectiveJobConfig.DestinationDir `
                                     -ArchiveBaseFileName $effectiveJobConfig.BaseFileName `
                                     -ArchiveExtension $effectiveJobConfig.JobArchiveExtension `
                                     -RetentionCountToKeep $effectiveJobConfig.RetentionCount `
                                     -SendToRecycleBin $effectiveJobConfig.DeleteToRecycleBin `
                                     -VBAssemblyLoaded $vbLoaded `
                                     -IsSimulateMode:$IsSimulateMode

        # Step 8 & 9: Construct 7-Zip arguments and execute 7-Zip
        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $effectiveJobConfig `
                                                        -FinalArchivePath $FinalArchivePath `
                                                        -CurrentJobSourcePathFor7Zip $currentJobSourcePathFor7Zip `
                                                        -TempPasswordFile $tempPasswordFilePath

        $sevenZipPathGlobal = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'SevenZipPath' # Already validated by main script
        $zipOpParams = @{
            SevenZipPathExe = $sevenZipPathGlobal
            SevenZipArguments = $sevenZipArgsArray
            ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority
            HideOutput = $effectiveJobConfig.HideSevenZipOutput
            MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts
            RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
            EnableRetries = $effectiveJobConfig.JobEnableRetries
            IsSimulateMode = $IsSimulateMode.IsPresent
        }
        # Invoke-7ZipOperation handles its own ShouldProcess for the 7-Zip execution
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) {$sevenZipResult.ElapsedTime.ToString()} else {"N/A"}
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        $archiveSize = "N/A (Simulated)"
        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
             $archiveSize = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath
        } elseif ($IsSimulateMode.IsPresent) {
            $archiveSize = "0 Bytes (Simulated)" # Default simulated size
        }
        $reportData.ArchiveSizeFormatted = $archiveSize

        # Determine job status based on 7-Zip exit code
        # 0 = No error; 1 = Warning (non-fatal); 2 = Fatal error; 7 = Command line error; 8 = Not enough memory; 255 = User stopped process
        if ($sevenZipResult.ExitCode -eq 0) {
            # CurrentJobStatus remains SUCCESS unless changed by other factors like failed archive test
        } elseif ($sevenZipResult.ExitCode -eq 1) { # 7-Zip Warning
            $currentJobStatus = "WARNINGS"
        } else { # Any other non-zero exit code from 7-Zip is treated as a failure for the job
            $currentJobStatus = "FAILURE"
        }

        # Step 10: Optionally test the archive
        $reportData.ArchiveTested = $effectiveJobConfig.JobTestArchiveAfterCreation # Record if testing was configured
        if ($effectiveJobConfig.JobTestArchiveAfterCreation -and ($currentJobStatus -ne "FAILURE") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
            $testArchiveParams = @{
                SevenZipPathExe = $sevenZipPathGlobal
                ArchivePath = $FinalArchivePath
                TempPasswordFile = $tempPasswordFilePath # Pass if password was used for creation
                ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority
                HideOutput = $effectiveJobConfig.HideSevenZipOutput
                MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts
                RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
                EnableRetries = $effectiveJobConfig.JobEnableRetries
                # IsSimulateMode is implicitly $false here as we only test real archives
            }
            # Test-7ZipArchive handles its own ShouldProcess
            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED"
            } else {
                $reportData.ArchiveTestResult = "FAILED (7-Zip Test Exit Code: $($testResult.ExitCode))"
                if ($currentJobStatus -ne "FAILURE") {$currentJobStatus = "WARNINGS"} # Downgrade to warning if compression was OK but test failed
            }
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade
        } elseif ($effectiveJobConfig.JobTestArchiveAfterCreation) {
             # If testing was configured but couldn't be performed (e.g., archive missing due to prior error, or in simulate mode)
             $reportData.ArchiveTestResult = if($IsSimulateMode.IsPresent){"Not Performed (Simulation Mode)"} else {"Not Performed (Archive Missing or Prior Compression Error)"}
        } else {
            $reportData.ArchiveTestResult = "Not Configured" # Testing was not enabled for this job
        }

    } catch {
        # Catch any exceptions thrown during the main try block
        Write-LogMessage "ERROR during processing of job '$JobName': $($_.Exception.ToString())" -Level ERROR
        $currentJobStatus = "FAILURE" # Ensure status reflects the failure
        $reportData.ErrorMessage = $_.Exception.ToString() # Record the error message for reporting
    } finally {
        # Step 11: Clean up VSS shadow copies
        if ($null -ne $VSSPathsInUse) {
            # Remove-VSSShadowCopy handles its own ShouldProcess
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent
        }

        # Step 12: Securely clear and delete temporary password file
        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordForJob)) {
            try {
                # Overwrite and clear variable from memory (best effort)
                $plainTextPasswordForJob = $null
                Remove-Variable plainTextPasswordForJob -Scope Script -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Write-LogMessage "   - Plain text password for job '$JobName' cleared from Operations module memory." -Level DEBUG
            } catch {
                Write-LogMessage "[WARNING] Exception while clearing plain text password from Operations module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp")) ) { # Don't delete the "simulated" named file

            if ($PSCmdlet.ShouldProcess($tempPasswordFilePath, "Delete Temporary Password File")) {
                try {
                    Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop
                    Write-LogMessage "   - Temporary password file '$tempPasswordFilePath' deleted successfully." -Level DEBUG
                }
                catch {
                    Write-LogMessage "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING"
                }
            }
        }

        # Determine final overall status for reporting
        if ($IsSimulateMode.IsPresent -and $currentJobStatus -ne "FAILURE" -and $currentJobStatus -ne "WARNINGS") {
            # If simulation ran without any simulated errors/warnings, mark as SIMULATED_COMPLETE
            $reportData.OverallStatus = "SIMULATED_COMPLETE"
        } else {
            $reportData.OverallStatus = $currentJobStatus
        }

        # Record script end time and total duration for this job
        $reportData.ScriptEndTime = Get-Date
        if (($reportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and ($null -ne $reportData.ScriptStartTime)) {
            $reportData.TotalDuration = $reportData.ScriptEndTime - $reportData.ScriptStartTime
        } else {
            $reportData.TotalDuration = "N/A (Timing data incomplete)"
        }

        # Step 13: Execute Post-Backup Hook Scripts
        $hookArgsForExternalScript = @{
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $FinalArchivePath;
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent
        }

        if ($reportData.OverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE") ) {
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnSuccessPath -HookType "PostBackupOnSuccess" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        } else { # Implies FAILURE
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnFailurePath -HookType "PostBackupOnFailure" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        }
        Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptAlwaysPath -HookType "PostBackupAlways" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
    }

    return @{ Status = $currentJobStatus } # Return the final status of this job
}
#endregion

#region --- VSS Functions ---
# Module-scoped variable to track VSS shadow IDs created during the current script run (keyed by PID)
# This helps ensure that only shadows created by this specific invocation of PoSh-Backup are targeted for cleanup.
$Script:ScriptRunVSSShadowIDs = @{}

# Creates VSS shadow copies for the specified source paths.
function New-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] # VSS creation is a medium impact operation
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath,
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    $runKey = $PID # Use Process ID to scope shadow IDs for this script run
    if (-not $Script:ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        $Script:ScriptRunVSSShadowIDs[$runKey] = @{} # Initialise hashtable for this PID if not present
    }
    # This specific call's shadow IDs will be stored here to avoid conflicts if New-VSSShadowCopy is called multiple times within one job (though not typical)
    $currentCallShadowIDs = $Script:ScriptRunVSSShadowIDs[$runKey]

    Write-LogMessage "`n[INFO] Initialising Volume Shadow Copy Service (VSS) operations..." -Level "VSS"
    $mappedShadowPaths = @{} # Stores OriginalPath -> ShadowPath mappings

    # Determine unique volumes to shadow based on source paths
    $volumesToShadow = $SourcePathsToShadow | ForEach-Object {
        try { (Get-Item -LiteralPath $_ -ErrorAction Stop).PSDrive.Name + ":" } catch { Write-LogMessage "[WARNING] Could not determine volume for source path '$_'. It will be skipped for VSS snapshotting." -Level WARNING; $null }
    } | Where-Object {$null -ne $_} | Select-Object -Unique

    if ($volumesToShadow.Count -eq 0) {
        Write-LogMessage "[WARNING] No valid volumes could be determined from source paths to create shadow copies for." -Level WARNING
        return $null # No volumes, no VSS action
    }

    # Prepare diskshadow script content
    $diskshadowScriptContent = @"
SET CONTEXT $VSSContextOption
SET METADATA CACHE "$MetadataCachePath"
SET VERBOSE ON
$($volumesToShadow | ForEach-Object { "ADD VOLUME $_ ALIAS Vol_$($_ -replace ':','')" })
CREATE
"@
    $tempDiskshadowScriptFile = Join-Path -Path $env:TEMP -ChildPath "diskshadow_create_backup_$(Get-Random).txt"
    try { $diskshadowScriptContent | Set-Content -Path $tempDiskshadowScriptFile -Encoding UTF8 -ErrorAction Stop }
    catch { Write-LogMessage "[ERROR] Failed to write diskshadow script to temporary file '$tempDiskshadowScriptFile'. VSS creation aborted. Error: $($_.Exception.Message)" -Level ERROR; return $null }

    Write-LogMessage "  - Generated diskshadow script: '$tempDiskshadowScriptFile' (Context: $VSSContextOption, Cache: '$MetadataCachePath')" -Level VSS

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would execute diskshadow with script '$tempDiskshadowScriptFile' to create shadow copies for volumes: $($volumesToShadow -join ', ')" -Level SIMULATE
        # Create plausible simulated shadow paths for reporting/logging consistency
        $SourcePathsToShadow | ForEach-Object {
            $currentSourcePath = $_
            try {
                $vol = (Get-Item -LiteralPath $currentSourcePath -ErrorAction Stop).PSDrive.Name + ":"
                $relativePathSimulated = $currentSourcePath -replace [regex]::Escape($vol), ""
                # Generate a somewhat unique simulated index for the shadow copy path
                $simulatedIndex = [array]::IndexOf($SourcePathsToShadow, $currentSourcePath) + 1
                if ($simulatedIndex -le 0) { $simulatedIndex = Get-Random -Minimum 1000 -Maximum 9999 } # Fallback if IndexOf fails
                $mappedShadowPaths[$currentSourcePath] = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopySIMULATED$($simulatedIndex)$relativePathSimulated"
            } catch {
                 Write-LogMessage "SIMULATE: Could not determine volume for '$currentSourcePath' to create a representative simulated shadow path." -Level SIMULATE
                 $mappedShadowPaths[$currentSourcePath] = "$currentSourcePath (Original Path - VSS Simulation)"
            }
        }
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue # Clean up temp script file
        return $mappedShadowPaths
    }

    if (-not $PSCmdlet.ShouldProcess("Volumes: $($volumesToShadow -join ', ')", "Create VSS Shadow Copies using diskshadow.exe")) {
        Write-LogMessage "  - VSS shadow copy creation skipped by user (ShouldProcess)." -Level WARNING
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-LogMessage "  - Executing diskshadow.exe to create shadow copies. This may take a moment..." -Level VSS
    $process = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempDiskshadowScriptFile`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
    Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue # Clean up temp script file

    if ($process.ExitCode -ne 0) {
        Write-LogMessage "[ERROR] diskshadow.exe failed to create shadow copies. Exit Code: $($process.ExitCode). Check system event logs for VSS errors." -Level ERROR
        return $null # VSS creation failed
    }

    # Note: Changed "Polling WMI" to "Polling CIM" in the log message below
    Write-LogMessage "  - Shadow copy creation command completed by diskshadow. Polling CIM for shadow details (Timeout: ${PollingTimeoutSeconds}s)..." -Level VSS

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allVolumesSuccessfullyShadowed = $false
    $foundShadowsForThisSpecificCall = @{} # Tracks shadows found in this current polling loop for these specific volumes

    while ($stopwatch.Elapsed.TotalSeconds -lt $PollingTimeoutSeconds) {
        # Get recently created shadow copies using CIM
        $cimShadowsThisPoll = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue |
                              Where-Object { $_.InstallDate -gt (Get-Date).AddMinutes(-5) } # Filter for very recent shadows

        if ($null -ne $cimShadowsThisPoll) {
            foreach ($volName in $volumesToShadow) {
                if (-not $foundShadowsForThisSpecificCall.ContainsKey($volName)) { # Only look if not already found for this volume
                    # Find the newest shadow for this volume that isn't already tracked by this script run
                    $candidateShadow = $cimShadowsThisPoll |
                                       Where-Object { $_.VolumeName -eq $volName -and (-not $currentCallShadowIDs.ContainsValue($_.ID)) } |
                                       Sort-Object InstallDate -Descending |
                                       Select-Object -First 1

                    if ($null -ne $candidateShadow) {
                        Write-LogMessage "  - Found shadow via CIM for volume '$volName': Device '$($candidateShadow.DeviceObject)' (ID: $($candidateShadow.ID))" -Level VSS
                        $currentCallShadowIDs[$volName] = $candidateShadow.ID # Store ID for cleanup
                        $foundShadowsForThisSpecificCall[$volName] = $candidateShadow.DeviceObject # Store device path for mapping
                    }
                }
            }
        }

        # Check if all requested volumes have a found shadow in this call
        if ($foundShadowsForThisSpecificCall.Keys.Count -eq $volumesToShadow.Count) {
            $allVolumesSuccessfullyShadowed = $true
            break # All found
        }

        Start-Sleep -Seconds $PollingIntervalSeconds # RESTORED
        Write-LogMessage "  - Polling CIM for shadow copies... ($([math]::Round($stopwatch.Elapsed.TotalSeconds))s / ${PollingTimeoutSeconds}s remaining)" -Level "VSS" -NoTimestampToLogFile ($stopwatch.Elapsed.TotalSeconds -ge $PollingIntervalSeconds) # RESTORED & text updated WMI->CIM
    } # End of while loop

    $stopwatch.Stop()

    if (-not $allVolumesSuccessfullyShadowed) {
        # Note: Changed "via WMI" to "via CIM" in the log message below
        Write-LogMessage "[ERROR] Timed out or failed to find all required shadow copies via CIM after $PollingTimeoutSeconds seconds." -Level ERROR
        # Attempt to clean up any shadows that were successfully created and identified in this failed attempt
        $foundShadowsForThisSpecificCall.Keys | ForEach-Object {
            $volNameToClean = $_
            if ($currentCallShadowIDs.ContainsKey($volNameToClean)) {
                Remove-VSSShadowCopyById -ShadowID $currentCallShadowIDs[$volNameToClean] -IsSimulateMode:$IsSimulateMode # Handles its own ShouldProcess
                $currentCallShadowIDs.Remove($volNameToClean) # Remove from tracked list
            }
        }
        return $null
    }

    # Map original source paths to their VSS shadow paths
    $SourcePathsToShadow | ForEach-Object {
        $originalFullPath = $_
        try {
            $volNameOfPath = (Get-Item -LiteralPath $originalFullPath -ErrorAction Stop).PSDrive.Name + ":"
            if ($foundShadowsForThisSpecificCall.ContainsKey($volNameOfPath)) {
                $shadowDevicePath = $foundShadowsForThisSpecificCall[$volNameOfPath]
                # Construct the full shadow path by appending the relative path part of the original source
                $relativePath = $originalFullPath -replace [regex]::Escape($volNameOfPath), ""
                $mappedShadowPaths[$originalFullPath] = Join-Path -Path $shadowDevicePath -ChildPath $relativePath.TrimStart('\')
                Write-LogMessage "    - Mapped source '$originalFullPath' to VSS shadow path '$($mappedShadowPaths[$originalFullPath])'" -Level VSS
            } else {
                # This case should ideally not be hit if $allVolumesSuccessfullyShadowed is true, but included for robustness
                Write-LogMessage "[WARNING] Could not map source path '$originalFullPath' as its volume shadow ('$volNameOfPath') was not definitively found or mapped in this call, despite overall success." -Level WARNING
            }
        } catch {
            Write-LogMessage "[WARNING] Error during VSS mapping for source path '$originalFullPath': $($_.Exception.Message). This path may not be backed up from VSS." -Level WARNING
        }
    }

    if ($mappedShadowPaths.Count -eq 0 -and $SourcePathsToShadow.Count -gt 0) {
         Write-LogMessage "[ERROR] Failed to map ANY source paths to VSS shadow paths, even though shadow creation command appeared successful. This indicates a critical VSS issue." -Level ERROR
         return $null
    }
    if ($mappedShadowPaths.Count -lt $SourcePathsToShadow.Count) {
        Write-LogMessage "[WARNING] Not all source paths could be mapped to VSS shadow paths. The backup for unmapped paths will use original (live) files." -Level WARNING
    }
    return $mappedShadowPaths
}

# Internal helper to remove a specific VSS shadow by ID.
function Remove-VSSShadowCopyById {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param (
        [Parameter(Mandatory)] [string]$ShadowID,
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    if (-not $PSCmdlet.ShouldProcess("VSS Shadow ID $ShadowID", "Delete using diskshadow.exe")) {
        Write-LogMessage "  - VSS shadow ID $ShadowID deletion skipped by user (ShouldProcess)." -Level WARNING
        return
    }

    Write-LogMessage "  - Attempting cleanup of specific VSS shadow ID: $ShadowID" -Level VSS
    $diskshadowScriptContentSingle = "SET VERBOSE ON`nDELETE SHADOWS ID $ShadowID`n" # Simple script to delete one ID
    $tempScriptPathSingle = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_single_$(Get-Random).txt"
    try { $diskshadowScriptContentSingle | Set-Content -Path $tempScriptPathSingle -Encoding UTF8 -ErrorAction Stop }
    catch { Write-LogMessage "[ERROR] Failed to write single VSS shadow delete script to '$tempScriptPathSingle'. Manual cleanup of ID $ShadowID may be required. Error: $($_.Exception.Message)" -Level ERROR; return}

    if (-not $IsSimulateMode.IsPresent) {
        $procDeleteSingle = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathSingle`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
        if ($procDeleteSingle.ExitCode -ne 0) {
            Write-LogMessage "[WARNING] diskshadow.exe failed to delete specific VSS shadow ID $ShadowID. Exit Code: $($procDeleteSingle.ExitCode). Manual cleanup may be needed." -Level WARNING
        } else {
            Write-LogMessage "    - Successfully initiated deletion of VSS shadow ID $ShadowID." -Level VSS
        }
    } else {
         Write-LogMessage "SIMULATE: Would execute diskshadow.exe to delete VSS shadow ID $ShadowID." -Level SIMULATE
    }
    Remove-Item -LiteralPath $tempScriptPathSingle -Force -ErrorAction SilentlyContinue # Clean up temp script
}

# Removes all VSS shadow copies tracked for the current script run.
function Remove-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    $runKey = $PID
    if (-not $Script:ScriptRunVSSShadowIDs.ContainsKey($runKey) -or $Script:ScriptRunVSSShadowIDs[$runKey].Count -eq 0) {
        Write-LogMessage "`n[INFO] No VSS Shadow IDs recorded for the current script run (PID $runKey) to remove, or they were already cleared." -Level VSS
        return
    }
    $shadowIdMapForRun = $Script:ScriptRunVSSShadowIDs[$runKey]
    Write-LogMessage "`n[INFO] Removing VSS Shadow Copies created during this script run (PID $runKey)..." -Level VSS
    $shadowIdsToRemove = $shadowIdMapForRun.Values | Select-Object -Unique # Get unique shadow IDs to remove

    if ($shadowIdsToRemove.Count -eq 0) {
        Write-LogMessage "  - No unique VSS shadow IDs found in the tracking list for this run to remove." -Level VSS
        $shadowIdMapForRun.Clear() # Clear the map for this run
        return
    }

    if (-not $PSCmdlet.ShouldProcess("VSS Shadow IDs: $($shadowIdsToRemove -join ', ')", "Delete All using diskshadow.exe")) {
        Write-LogMessage "  - VSS shadow copy deletion skipped by user (ShouldProcess) for IDs: $($shadowIdsToRemove -join ', ')." -Level WARNING
        return
    }

    $diskshadowScriptContentAll = "SET VERBOSE ON`n" # Start diskshadow script
    $shadowIdsToRemove | ForEach-Object { $diskshadowScriptContentAll += "DELETE SHADOWS ID $_`n" } # Add delete command for each ID
    $tempScriptPathAll = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_all_$(Get-Random).txt"
    try { $diskshadowScriptContentAll | Set-Content -Path $tempScriptPathAll -Encoding UTF8 -ErrorAction Stop }
    catch { Write-LogMessage "[ERROR] Failed to write diskshadow VSS deletion script to '$tempScriptPathAll'. Manual cleanup of IDs may be required. Error: $($_.Exception.Message)" -Level ERROR; return }

    Write-LogMessage "  - Generated diskshadow VSS deletion script: '$tempScriptPathAll' for IDs: $($shadowIdsToRemove -join ', ')" -Level VSS

    if (-not $IsSimulateMode.IsPresent) {
        Write-LogMessage "  - Executing diskshadow.exe to delete VSS shadow copies..." -Level VSS
        $processDeleteAll = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathAll`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
        if ($processDeleteAll.ExitCode -ne 0) {
            Write-LogMessage "[ERROR] diskshadow.exe failed to delete one or more VSS shadow copies. Exit Code: $($processDeleteAll.ExitCode). Manual cleanup may be needed for ID(s): $($shadowIdsToRemove -join ', ')" -Level ERROR
        } else {
            Write-LogMessage "  - VSS shadow copy deletion process completed successfully via diskshadow." -Level VSS
        }
    } else {
        Write-LogMessage "SIMULATE: Would execute diskshadow.exe to delete VSS shadow IDs: $($shadowIdsToRemove -join ', ')." -Level SIMULATE
    }
    Remove-Item -LiteralPath $tempScriptPathAll -Force -ErrorAction SilentlyContinue # Clean up temp script
    $shadowIdMapForRun.Clear() # Clear the tracked IDs for this run
}
#endregion

#region --- 7-Zip Operations ---
# Invokes a 7-Zip command (archive or test) with support for retries.
function Invoke-7ZipOperation {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] # Archiving can be medium impact
    param(
        [string]$SevenZipPathExe,
        [array]$SevenZipArguments,
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [switch]$IsSimulateMode,
        [int]$MaxRetries = 1, # Default to 1 attempt (no retries) if EnableRetries is false
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false
    )

    $currentTry = 0
    $actualMaxTries = if ($EnableRetries) { [math]::Max(1, $MaxRetries) } else { 1 } # Ensure at least 1 try
    $actualDelaySeconds = if ($EnableRetries -and $actualMaxTries -gt 1) { $RetryDelaySeconds } else { 0 }
    $operationExitCode = -1 # Default to an error state
    $operationElapsedTime = New-TimeSpan -Seconds 0
    $attemptsMade = 0

    # Prepare argument string for display and process execution, ensuring paths with spaces are quoted
    $argumentStringForProcess = ""
    foreach ($argItem in $SevenZipArguments) {
        if ($argItem -match "\s" -and -not (($argItem.StartsWith('"') -and $argItem.EndsWith('"')) -or ($argItem.StartsWith("'") -and $argItem.EndsWith("'")))) {
            $argumentStringForProcess += """$argItem"" " # Add quotes if space and not already quoted
        } else {
            $argumentStringForProcess += "$argItem "
        }
    }
    $argumentStringForProcess = $argumentStringForProcess.TrimEnd()

    while ($currentTry -lt $actualMaxTries) {
        $currentTry++; $attemptsMade = $currentTry

        if ($IsSimulateMode.IsPresent) {
            Write-LogMessage "SIMULATE: 7-Zip Operation (Attempt $currentTry/$actualMaxTries would be): `"$SevenZipPathExe`" $argumentStringForProcess" -Level SIMULATE
            $operationExitCode = 0 # Simulate success for 7-Zip command itself
            $operationElapsedTime = New-TimeSpan -Seconds 0 # Simulate no time taken
            break # Exit loop in simulate mode after logging
        }

        if (-not $PSCmdlet.ShouldProcess("Target: $($SevenZipArguments | Where-Object {$_ -notlike '-*'} | Select-Object -Last 1)", "Execute 7-Zip ($($SevenZipArguments[0]))")) { # MODIFIED HERE
             Write-LogMessage "   - 7-Zip execution (Attempt $currentTry/$actualMaxTries) skipped by user (ShouldProcess)." -Level WARNING
             $operationExitCode = -1000 # Indicate user skip
             break
        }

        Write-LogMessage "   - Attempting 7-Zip execution (Attempt $currentTry/$actualMaxTries)..."
        Write-LogMessage "     Command: `"$SevenZipPathExe`" $argumentStringForProcess" -Level DEBUG

        $validPriorities = "Idle", "BelowNormal", "Normal", "AboveNormal", "High"
        if ([string]::IsNullOrWhiteSpace($ProcessPriority) -or $ProcessPriority -notin $validPriorities) {
            Write-LogMessage "[WARNING] Invalid or empty 7-Zip process priority '$ProcessPriority' specified. Defaulting to 'Normal'." -Level WARNING; $ProcessPriority = "Normal"
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess
            $startInfo.UseShellExecute = $false # Required for stream redirection
            $startInfo.CreateNoWindow = $HideOutput.IsPresent
            $startInfo.WindowStyle = if($HideOutput.IsPresent) { [System.Diagnostics.ProcessWindowStyle]::Hidden } else { [System.Diagnostics.ProcessWindowStyle]::Normal }

            if ($HideOutput.IsPresent) {
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }

            Write-LogMessage "  - Starting 7-Zip process with priority: $ProcessPriority" -Level DEBUG
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority }
            catch { Write-LogMessage "[WARNING] Failed to set 7-Zip process priority to '$ProcessPriority'. Error: $($_.Exception.Message)" -Level WARNING }

            $stdOutput = ""
            $stdError = ""
            $outputTask = $null
            $errorTask = $null

            if ($HideOutput.IsPresent) { # Asynchronously read output streams if hidden
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit() # Wait for the 7-Zip process to complete

            if ($HideOutput.IsPresent) { # Process captured output
                if ($null -ne $outputTask) {
                    try { $stdOutput = $outputTask.GetAwaiter().GetResult() } catch { try { $stdOutput = $process.StandardOutput.ReadToEnd() } catch { Write-LogMessage "    - DEBUG: Fallback ReadToEnd STDOUT for 7-Zip failed: $($_.Exception.Message)" -Level DEBUG } }
                }
                 if ($null -ne $errorTask) {
                    try { $stdError = $errorTask.GetAwaiter().GetResult() } catch { try { $stdError = $process.StandardError.ReadToEnd() } catch { Write-LogMessage "    - DEBUG: Fallback ReadToEnd STDERR for 7-Zip failed: $($_.Exception.Message)" -Level DEBUG } }
                 }

                if (-not [string]::IsNullOrWhiteSpace($stdOutput)) {
                    Write-LogMessage "  - 7-Zip STDOUT (captured as HideSevenZipOutput is true):" -Level DEBUG
                    $stdOutput.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level DEBUG -NoTimestampToLogFile }
                }
                # Always log STDERR if present, as it usually indicates issues.
                if (-not [string]::IsNullOrWhiteSpace($stdError)) {
                    Write-LogMessage "  - 7-Zip STDERR:" -Level ERROR
                    $stdError.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level ERROR -NoTimestampToLogFile }
                }
            }
            $operationExitCode = $process.ExitCode
        } catch {
            Write-LogMessage "[ERROR] Failed to start or manage the 7-Zip process. Error: $($_.Exception.ToString())" -Level ERROR
            $operationExitCode = -999 # Arbitrary code for script-level failure to launch 7-Zip
        } finally {
            $stopwatch.Stop()
            $operationElapsedTime = $stopwatch.Elapsed
            if ($null -ne $process) { $process.Dispose() }
        }

        Write-LogMessage "   - 7-Zip attempt $currentTry finished. Exit Code: $operationExitCode. Elapsed Time: $operationElapsedTime"
        # 7-Zip Exit Codes: 0=No error, 1=Warning (e.g., locked files not archived), 2=Fatal error
        if ($operationExitCode -in @(0,1)) { break } # Success or Warning, stop retrying
        elseif ($currentTry -lt $actualMaxTries) {
            Write-LogMessage "[WARNING] 7-Zip operation failed (Exit Code: $operationExitCode). Retrying in $actualDelaySeconds seconds..." -Level WARNING
            Start-Sleep -Seconds $actualDelaySeconds
        } else {
            Write-LogMessage "[ERROR] 7-Zip operation failed after $actualMaxTries attempt(s) (Final Exit Code: $operationExitCode)." -Level ERROR
        }
    }
    return @{ ExitCode = $operationExitCode; ElapsedTime = $operationElapsedTime; AttemptsMade = $attemptsMade }
}

# Tests a 7-Zip archive for integrity.
function Test-7ZipArchive {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')] # Testing is low impact
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null,
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false
    )
    Write-LogMessage "`n[INFO] Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t") # Test command
    $testArguments.Add($ArchivePath) # Archive to test

    if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and (Test-Path -LiteralPath $TempPasswordFile)) {
        $testArguments.Add("-spf`"$TempPasswordFile`"") # Add password file if provided
    }
    Write-LogMessage "   - Test Command (raw args before Invoke-7ZipOperation internal quoting): `"$SevenZipPathExe`" $($testArguments -join ' ')" -Level DEBUG

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput.IsPresent
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds; EnableRetries = $EnableRetries
        IsSimulateMode = $false # Testing is never simulated in this function
    }
    # Invoke-7ZipOperation handles ShouldProcess for the actual 7-Zip execution
    $result = Invoke-7ZipOperation @invokeParams

    $msg = if ($result.ExitCode -eq 0) { "PASSED" } else { "FAILED (7-Zip Test Exit Code: $($result.ExitCode))" }
    $levelForResult = if ($result.ExitCode -eq 0) { "SUCCESS" } else { "ERROR" }
    Write-LogMessage "  - Archive Test Result for '$ArchivePath': $msg" -Level $levelForResult
    return $result
}
#endregion

#region --- Private Helper: Invoke-VisualBasicFileOperation ---
# Internal helper for Recycle Bin operations using Microsoft.VisualBasic.
function Invoke-VisualBasicFileOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('DeleteFile', 'DeleteDirectory')]
        [string]$Operation,
        [Microsoft.VisualBasic.FileIO.UIOption]$UIOption = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]$RecycleOption = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]$CancelOption = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
    )
    # This Add-Type is here because it's only needed if Recycle Bin is used.
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    } catch {
        Write-LogMessage "[ERROR] Failed to load Microsoft.VisualBasic assembly for Recycle Bin operation. Error: $($_.Exception.Message)" -Level ERROR
        throw "Microsoft.VisualBasic assembly could not be loaded. Recycle Bin operations unavailable."
    }

    switch ($Operation) {
        "DeleteFile"      { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $UIOption, $RecycleOption, $CancelOption) }
        "DeleteDirectory" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $UIOption, $RecycleOption, $CancelOption) }
    }
}
#endregion

#region --- Backup Retention Policy ---
# Applies the retention policy by deleting older backups.
function Invoke-BackupRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')] # Deleting files is high impact
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName,
        [string]$ArchiveExtension, # e.g., ".7z"
        [int]$RetentionCountToKeep,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded, # Indicates if Microsoft.VisualBasic assembly is available
        [switch]$IsSimulateMode
    )
    Write-LogMessage "`n[INFO] Applying Backup Retention Policy for archives matching base name '$ArchiveBaseFileName' and extension '$ArchiveExtension'..."
    Write-LogMessage "   - Destination Directory: $DestinationDirectory"
    Write-LogMessage "   - Configured Total Retention Count (target after current backup completes): $RetentionCountToKeep"

    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        Write-LogMessage "[WARNING] Deletion to Recycle Bin was requested, but the Microsoft.VisualBasic assembly could not be loaded. Falling back to PERMANENT deletion for retention policy." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }
    Write-LogMessage "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    # Construct a wildcard pattern for Get-ChildItem. Escape wildcard characters in the base name itself.
    $literalBaseName = $ArchiveBaseFileName -replace '\*', '`*' -replace '\?', '`?' # Escape PowerShell wildcards
    $filePattern = "$($literalBaseName)*$($ArchiveExtension)" # e.g., "MyBackupName*.7z"

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            Write-LogMessage "   - Retention Policy SKIPPED: Destination directory '$DestinationDirectory' not found." -Level WARNING
            return
        }

        $existingBackups = Get-ChildItem -Path $DestinationDirectory -Filter $filePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending

        if ($RetentionCountToKeep -le 0) { # 0 or negative means keep all (unlimited by count for this pattern)
            Write-LogMessage "   - Retention count is $RetentionCountToKeep; all existing backups matching pattern '$filePattern' will be kept." -Level INFO
            return
        }

        # The number of *old* backups to preserve. The new one being created will make up the 'RetentionCountToKeep'.
        $numberOfOldBackupsToPreserve = $RetentionCountToKeep - 1
        if ($numberOfOldBackupsToPreserve -lt 0) { $numberOfOldBackupsToPreserve = 0 } # Cannot preserve a negative number of old backups

        if (($null -ne $existingBackups) -and ($existingBackups.Count -gt $numberOfOldBackupsToPreserve)) {
            $backupsToDelete = $existingBackups | Select-Object -Skip $numberOfOldBackupsToPreserve
            Write-LogMessage "[INFO] Found $($existingBackups.Count) existing backups matching pattern. Will attempt to delete $($backupsToDelete.Count) older backup(s) to meet retention count of $RetentionCountToKeep (preserving $numberOfOldBackupsToPreserve oldest + current)." -Level INFO

            foreach ($backupFile in $backupsToDelete) {
                $deleteActionMessage = if ($effectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
                if (-not $IsSimulateMode.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($backupFile.FullName, $deleteActionMessage)) {
                        Write-LogMessage "       - Deleting: $($backupFile.FullName) (Created: $($backupFile.CreationTime))" -Level WARNING
                        try {
                            if ($effectiveSendToRecycleBin) {
                                Invoke-VisualBasicFileOperation -Path $backupFile.FullName -Operation "DeleteFile" -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                                Write-LogMessage "         - Status: MOVED TO RECYCLE BIN" -Level SUCCESS
                            } else {
                                Remove-Item -LiteralPath $backupFile.FullName -Force -ErrorAction Stop
                                Write-LogMessage "         - Status: DELETED PERMANENTLY" -Level SUCCESS
                            }
                        } catch {
                            Write-LogMessage "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR
                            # Potentially set overall job status to WARNINGS if retention fails but backup succeeds
                        }
                    } else {
                        Write-LogMessage "       - SKIPPED Deletion (ShouldProcess): $($backupFile.FullName)" -Level INFO
                    }
                } else {
                     Write-LogMessage "       - SIMULATE: Would $deleteActionMessage '$($backupFile.FullName)' (Created: $($backupFile.CreationTime))" -Level SIMULATE
                }
            }
        } elseif ($null -ne $existingBackups) {
            Write-LogMessage "   - Number of existing backups ($($existingBackups.Count)) is already at or below the target number of old backups to preserve ($numberOfOldBackupsToPreserve). No older backups need to be deleted by count." -Level INFO
        } else {
            Write-LogMessage "   - No existing backups found matching pattern '$filePattern' in '$DestinationDirectory'. No retention actions needed." -Level INFO
        }
    } catch {
        Write-LogMessage "[WARNING] An error occurred during the retention policy check for '$ArchiveBaseFileName'. Some old backups might not have been deleted. Error: $($_.Exception.Message)" -Level WARNING
    }
}
#endregion

#region --- Free Space Check ---
# Checks if the destination directory has enough free space.
function Test-DestinationFreeSpace {
    [CmdletBinding()]
    param(
        [string]$DestDir,
        [int]$MinRequiredGB,
        [bool]$ExitOnLow, # If true, a failure of this check will throw, halting the job
        [switch]$IsSimulateMode
    )
    if ($MinRequiredGB -le 0) { return $true } # 0 or less means check is disabled

    Write-LogMessage "`n[INFO] Checking destination free space for '$DestDir'..."
    Write-LogMessage "   - Minimum free space required: $MinRequiredGB GB"

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would check free space on '$DestDir'. Assuming sufficient space for simulation purposes." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            Write-LogMessage "[WARNING] Destination directory '$DestDir' for free space check not found. Skipping this check." -Level WARNING
            return $true # Allow to proceed if dir doesn't exist yet (it might be created later)
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        Write-LogMessage "   - Available free space on drive $($destDrive.Name) (hosting '$DestDir'): $freeSpaceGB GB"

        if ($freeSpaceGB -lt $MinRequiredGB) {
            Write-LogMessage "[WARNING] Low disk space on destination. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                Write-LogMessage "FATAL: Exiting job due to insufficient free disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false # Signal failure to halt the job
            }
        } else {
            Write-LogMessage "   - Free space check: OK (Available: $freeSpaceGB GB, Required: $MinRequiredGB GB)" -Level SUCCESS
        }
    } catch {
        Write-LogMessage "[WARNING] Could not determine free space for destination '$DestDir'. Check skipped. Error: $($_.Exception.Message)" -Level WARNING
    }
    return $true # Default to true if check couldn't be performed or if not exiting on low space
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy, Invoke-7ZipOperation, Test-7ZipArchive, Invoke-BackupRetentionPolicy, Test-DestinationFreeSpace, Invoke-PoShBackupJob
#endregion
