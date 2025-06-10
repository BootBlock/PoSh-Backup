# PoSh-Backup.ps1
<#
.SYNOPSIS
    A highly comprehensive PowerShell script for directory and file backups using 7-Zip.
    Features include VSS (Volume Shadow Copy), configurable retries, script execution hooks,
    multi-format reporting, backup sets, 7-Zip process priority control, extensive
    customisation via an external .psd1 configuration file, remote Backup Targets,
    optional post-run system actions (e.g., shutdown, restart), optional
    archive checksum generation and verification, optional Self-Extracting Archive (SFX) creation,
    optional 7-Zip CPU core affinity (with CLI override), optional verification of local
    archives before remote transfer, configurable log file retention, support for
    7-Zip include/exclude list files, backup job chaining/dependencies, multi-volume
    (split) archive creation (with CLI override), an update checking mechanism, the
    ability to pin backups to prevent retention policy deletion, integrated backup
    job scheduling via Windows Task Scheduler, and a global maintenance mode.

.DESCRIPTION
    The PoSh Backup ("PowerShell Backup") script provides an enterprise-grade, modular backup solution.
    It is designed for robustness, extensive configurability, and detailed operational feedback.
    Core logic is managed by this main script, which orchestrates operations performed by dedicated
    PowerShell modules. Initial setup (globals, banner) is handled by 'InitialisationManager.psm1'.
    CLI parameter processing is handled by 'CliManager.psm1'.
    Core setup (module imports, config load, job resolution) is handled by 'CoreSetupManager.psm1'.
    The main job/set processing loop is now handled by 'JobOrchestrator.psm1'.
    Script finalisation (summary, post-run actions, pause, exit) is handled by 'FinalisationManager.psm1'.

    Key Features:
    - Modular Design, External Configuration, Local and Remote Backups, Granular Job Control.
    - Backup Sets, Extensible Backup Target Providers (UNC, Replicate, SFTP, WebDAV).
    - Configurable Local and Remote Retention Policies.
    - VSS, Advanced 7-Zip Integration, Secure Password Protection, Customisable Archive Naming.
    - Automatic Retry Mechanism, CPU Priority Control, Extensible Script Hooks.
    - Multi-Format Reporting (Interactive HTML with filtering/sorting, CSV, JSON, XML, TXT, MD).
    - Comprehensive Logging, Simulation Mode, Configuration Test Mode.
    - Proactive Free Space Check, Archive Integrity Verification (7z t and optional checksums).
    - Flexible 7-Zip Warning Handling, Exit Pause Control.
    - Post-Run System Actions: Optionally perform actions like shutdown, restart, hibernate, etc.,
      after job/set completion, configurable based on status, with delay and CLI override.
    - Archive Checksum Generation & Verification: Optionally generate checksum files (e.g., SHA256)
      for local archives and verify them during archive testing for enhanced integrity.
    - Self-Extracting Archives (SFX): Optionally create Windows self-extracting archives (.exe)
      for easy restoration.
    - 7-Zip CPU Core Affinity: Optionally restrict 7-Zip to specific CPU cores, with validation
      and CLI override.
    - Verify Local Archive Before Transfer: Optionally test the local archive's integrity
      (and checksum if enabled for the job) *before* attempting any remote transfers. If verification fails,
      remote transfers for that job are skipped.
    - Log File Retention: Configurable retention count for generated log files (global, per-job,
      per-set, or CLI override) to prevent indefinite growth of the Logs directory.
    - 7-Zip Include/Exclude List Files: Specify external files containing lists of
      include or exclude patterns for 7-Zip, configurable globally, per-job, per-set, or via CLI.
    - Backup Job Chaining / Dependencies: Define job dependencies so that a job only runs
      after its prerequisite jobs have completed successfully (considering 'TreatSevenZipWarningsAsSuccess').
      Circular dependencies are detected.
    - Multi-Volume (Split) Archives: Optionally split large archives into smaller volumes
      (e.g., "100m", "4g"), configurable per job or via CLI. This will override SFX creation if both are set.
    - Update Checking: Manually check for new versions of PoSh-Backup.
    - Pin Backups: Protect specific backup archives from automatic deletion by retention policies.
      This can be done by pinning an existing archive via `-PinBackup <path>` or by pinning the
      result of the current run via the `-Pin` switch.
    - Integrated Scheduling: Define backup schedules directly in the configuration file. A simple
      `-SyncSchedules` command synchronises these schedules with the Windows Task Scheduler,
      creating, updating, or removing tasks as needed for fully automated "set and forget" backups.
    - Maintenance Mode: A global flag (in config or via an on-disk file) can prevent any new
      backup jobs from starting, useful for system maintenance.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location (job) to process.
    If this job has dependencies, they will be processed first.

.PARAMETER RunSet
    Optional. The name of a Backup Set to process. Jobs within the set will be ordered
    based on any defined dependencies.

.PARAMETER Pin
    Optional. A switch parameter. If present, the backup archive(s) created during this
    specific run will be automatically pinned, protecting them from retention policies.

.PARAMETER ForceRunInMaintenanceMode
    Optional. A switch parameter. If present, forces the backup job/set to run even if
    PoSh-Backup is in maintenance mode (either via config or on-disk flag file).

.PARAMETER ConfigFile
    Optional. Specifies the full path to a PoSh-Backup '.psd1' configuration file.

.PARAMETER Simulate
    Optional. A switch parameter. If present, the script runs in simulation mode.
    Local archive creation, checksum generation, remote transfers, retention actions, log file retention,
    and post-run system actions will be logged but not executed.

.PARAMETER TestArchive
    Optional. A switch parameter. If present, this forces an integrity test of newly created local archives.
    If checksum verification is also enabled for the job, it will be performed as part of this test.
    This is independent of -VerifyLocalArchiveBeforeTransferCLI but may perform similar tests.

.PARAMETER VerifyLocalArchiveBeforeTransferCLI
    Optional. A switch parameter. If present, forces verification of the local archive (including checksum
    if enabled for the job) *before* any remote transfers are attempted. Overrides configuration settings.
    If verification fails, remote transfers for the job are skipped.

.PARAMETER UseVSS
    Optional. A switch parameter. If present, this forces the script to attempt using VSS. Overridden by -SkipVSS.

.PARAMETER SkipVSS
    Optional. A switch parameter. If present, this forces the script to NOT use VSS, overriding any configuration or -UseVSS.

.PARAMETER EnableRetriesCLI
    Optional. A switch parameter. If present, this forces the enabling of the 7-Zip retry mechanism for local archiving. Overridden by -SkipRetriesCLI.

.PARAMETER SkipRetriesCLI
    Optional. A switch parameter. If present, this forces the disabling of the 7-Zip retry mechanism, overriding any configuration or -EnableRetriesCLI.

.PARAMETER GenerateHtmlReportCLI
    Optional. A switch parameter. If present, this forces the generation of an HTML report.

.PARAMETER TreatSevenZipWarningsAsSuccessCLI
    Optional. A switch parameter. If present, this forces 7-Zip exit code 1 (Warning) to be treated as a success for the job status.
    Overrides the 'TreatSevenZipWarningsAsSuccess' setting in the configuration file.

.PARAMETER NotificationProfileNameCLI
    Optional. CLI Override: The name of a notification profile (defined in NotificationProfiles) to use for this run, overriding any configured profile.

.PARAMETER SevenZipPriorityCLI
    Optional. Allows specifying the 7-Zip process priority.
    Valid values: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".

.PARAMETER SevenZipCpuAffinityCLI
    Optional. CLI Override: 7-Zip CPU core affinity (e.g., '0,1' or '0x3'). Overrides config.

.PARAMETER SevenZipIncludeListFileCLI
    Optional. CLI Override: Path to a text file containing 7-Zip include patterns. Overrides all configured include list files.

.PARAMETER SevenZipExcludeListFileCLI
    Optional. CLI Override: Path to a text file containing 7-Zip exclude patterns. Overrides all configured exclude list files.

.PARAMETER LogRetentionCountCLI
    Optional. CLI Override: Number of log files to keep per job name pattern.
    A value of 0 means infinite retention (keep all logs). Overrides all configured log retention counts.

.PARAMETER TestConfig
    Optional. A switch parameter. If present, loads, validates configuration (including job dependencies),
    prints summary, then exits. Post-run system actions will be logged as if they would occur but not executed.

.PARAMETER ListBackupLocations
    Optional. A switch parameter. If present, lists defined Backup Locations (jobs) and exits.

.PARAMETER ListBackupSets
    Optional. A switch parameter. If present, lists defined Backup Sets and exits.

.PARAMETER SyncSchedules
    Optional. A switch parameter. If present, synchronises job schedules from the configuration
    file with the Windows Task Scheduler, creating, updating, or removing tasks as needed, then exits.
    Requires Administrator privileges.

.PARAMETER Maintenance
    Utility switch. Enables or disables maintenance mode by creating or deleting the on-disk
    flag file (defined by 'MaintenanceModeFilePath' in config). Use `$true` to enable, `$false` to disable.

.PARAMETER SkipUserConfigCreation
    Optional. A switch parameter. If present, bypasses the prompt to create 'User.psd1'.

.PARAMETER PauseBehaviourCLI
    Optional. Controls script pause behaviour before exiting.
    Valid values: "True", "False", "Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning".

.PARAMETER PostRunActionCli
    Optional. Specifies a system action to perform after script completion, overriding any configured actions.
    Valid values: "None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock".
    If "None" is specified via CLI, no post-run action will occur, even if configured.

.PARAMETER PostRunActionDelaySecondsCli
    Optional. Specifies the delay in seconds before the CLI-specified PostRunActionCli is executed.
    Defaults to 0 if PostRunActionCli is used but this is not.

.PARAMETER PostRunActionForceCli
    Optional. A switch. If present and PostRunActionCli is "Shutdown" or "Restart", attempts to force the action.

.PARAMETER PostRunActionTriggerOnStatusCli
    Optional. An array of statuses that will trigger the CLI-specified PostRunActionCli.
    Defaults to @("ANY") if PostRunActionCli is used but this is not.
    Valid values: "SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY".

.PARAMETER CheckForUpdate
    Optional. A switch parameter. If present, checks for available updates to PoSh-Backup and exits.

.PARAMETER Version
    Optional. A switch parameter. If present, displays the PoSh-Backup script version and exits.

.PARAMETER Quiet
    Optional. A switch parameter. If present, suppresses all non-essential console output.
    Critical errors will still be displayed.

.PARAMETER PinBackup
    Pin a backup archive to exclude it from retention policies. Provide the full path to the archive file.

.PARAMETER UnpinBackup
    Unpin a backup archive to include it in retention policies again. Provide the full path to the archive file.

.EXAMPLE
    .\PoSh-Backup.ps1 -Maintenance $true
    Enables maintenance mode by creating the '.maintenance' flag file in the script root.

.EXAMPLE
    .\PoSh-Backup.ps1 -Maintenance $false
    Disables maintenance mode by deleting the '.maintenance' flag file.

.EXAMPLE
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups" -ForceRunInMaintenanceMode
    Runs the specified backup set even if maintenance mode is currently active.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.26.1 # Corrected -Maintenance parameter type to [Nullable[bool]].
    Date:           10-Jun-2025
    Requires:       PowerShell 5.1+, 7-Zip. Admin for VSS, some system actions, and scheduling.
    Modules:        Located in '.\Modules\': Utils.psm1 (facade), and sub-directories
                    'Core\', 'Managers\', 'Operations\', 'Reporting\', 'Targets\', 'Utilities\'.
                    Optional: 'PoShBackupValidator.psm1'.
    Configuration:  Via '.\Config\Default.psd1' and '.\Config\User.psd1'.
    Script Name:    PoSh-Backup.ps1
#>

#region --- Script Parameters ---
[CmdletBinding(DefaultParameterSetName = 'Execution')]
param (
    # Execution Parameter Set: For running backups
    [Parameter(ParameterSetName='Execution', Position=0, Mandatory=$false, HelpMessage="Optional. Name of a single backup location to process.")]
    [string]$BackupLocationName,

    [Parameter(ParameterSetName='Execution', Mandatory=$false, HelpMessage="Optional. Name of a Backup Set (defined in config) to process.")]
    [string]$RunSet,

    [Parameter(ParameterSetName='Execution', Mandatory=$false, HelpMessage="Pin the backup archive(s) created during this specific run, protecting them from retention policies.")]
    [switch]$Pin,

    [Parameter(ParameterSetName='Execution', Mandatory=$false, HelpMessage="Forces the backup to run even if maintenance mode is active.")]
    [switch]$ForceRunInMaintenanceMode,

    # Pinning/Utility Parameter Set: For managing existing archives
    [Parameter(ParameterSetName='Pinning', Mandatory=$true, HelpMessage="Pin a backup archive to exclude it from retention policies. Provide the full path to the archive file.")]
    [string]$PinBackup,

    [Parameter(ParameterSetName='Pinning', Mandatory=$true, HelpMessage="Unpin a backup archive to include it in retention policies again. Provide the full path to the archive file.")]
    [string]$UnpinBackup,

    # Parameter Set for listing archive contents
    [Parameter(ParameterSetName='Listing', Mandatory=$true, HelpMessage="List the contents of the specified backup archive file.")]
    [string]$ListArchiveContents,

    # Parameter Set for extracting from an archive
    [Parameter(ParameterSetName='Extraction', Mandatory=$true, HelpMessage="Extracts specific files or folders from an archive. Provide the full path to the archive file.")]
    [string]$ExtractFromArchive,

    [Parameter(ParameterSetName='Extraction', Mandatory=$true, HelpMessage="The destination directory for extracted files.")]
    [string]$ExtractToDirectory,

    [Parameter(ParameterSetName='Extraction', Mandatory=$false, HelpMessage="An array of specific file or folder paths inside the archive to extract.")]
    [string[]]$ItemsToExtract,

    [Parameter(ParameterSetName='Extraction', Mandatory=$false, HelpMessage="A switch. If present, overwrites existing files in the destination without prompting.")]
    [switch]$ForceExtract,

    # Scheduling Parameter Set
    [Parameter(ParameterSetName='Scheduling', Mandatory=$true, HelpMessage="Switch. Synchronises job schedules from config with Windows Task Scheduler and exits.")]
    [switch]$SyncSchedules,

    # Maintenance Mode Parameter Set
    [Parameter(ParameterSetName='Maintenance', Mandatory=$true, HelpMessage="Utility to enable/disable maintenance mode via the on-disk flag file.")]
    [Nullable[bool]]$Maintenance,

    # Parameters available to multiple utility sets (Listing, Extraction)
    [Parameter(ParameterSetName='Listing', Mandatory=$false)]
    [Parameter(ParameterSetName='Extraction', Mandatory=$false, HelpMessage="Specifies the SecretManagement secret name for the password of an encrypted archive for utility operations.")]
    [string]$ArchivePasswordSecretName,

    # Common Parameters (available to all sets)
    [Parameter(Mandatory=$false, HelpMessage="Optional. Path to the .psd1 configuration file. Defaults to '.\\Config\\Default.psd1' (and merges .\\Config\\User.psd1).")]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Run in simulation mode (local archiving, checksums, remote transfers, log retention, and post-run actions simulated).")]
    [switch]$Simulate,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Test local archive integrity after backup (includes checksum verification if enabled). Independent of -VerifyLocalArchiveBeforeTransferCLI.")]
    [switch]$TestArchive,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Verify local archive before remote transfer. Overrides config.")]
    [switch]$VerifyLocalArchiveBeforeTransferCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Attempt to use VSS. Requires Admin. Overridden by -SkipVSS.")]
    [switch]$UseVSS,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Force script to NOT use VSS, overriding config and -UseVSS.")]
    [switch]$SkipVSS,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Enable retry mechanism for 7-Zip (local archiving). Overridden by -SkipRetriesCLI.")]
    [switch]$EnableRetriesCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Force disabling of 7-Zip retry mechanism, overriding config and -EnableRetriesCLI.")]
    [switch]$SkipRetriesCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Forces HTML report generation for processed jobs, or adds HTML if ReportGeneratorType is an array.")]
    [switch]$GenerateHtmlReportCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. If present, forces 7-Zip exit code 1 (Warning) to be treated as success for job status.")]
    [switch]$TreatSevenZipWarningsAsSuccessCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: The name of a notification profile to use for this run, overriding any configured profile.")]
    [string]$NotificationProfileNameCLI,

    [Parameter(Mandatory=$false, HelpMessage="Optional. Set 7-Zip process priority (Idle, BelowNormal, Normal, AboveNormal, High).")]
    [ValidateSet("Idle", "BelowNormal", "Normal", "AboveNormal", "High")]
    [string]$SevenZipPriorityCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: 7-Zip CPU core affinity (e.g., '0,1' or '0x3'). Overrides config.")]
    [string]$SevenZipCpuAffinityCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Path to a text file containing 7-Zip include patterns. Overrides all configured include list files.")]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if (Test-Path -LiteralPath $_ -PathType Leaf) { return $true }
        throw "File not found at path: $_"
    })]
    [string]$SevenZipIncludeListFileCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Path to a text file containing 7-Zip exclude patterns. Overrides all configured exclude list files.")]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if (Test-Path -LiteralPath $_ -PathType Leaf) { return $true }
        throw "File not found at path: $_"
    })]
    [string]$SevenZipExcludeListFileCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Size for splitting archives (e.g., '100m', '4g'). Overrides config. Empty string disables splitting via CLI.")]
    [ValidatePattern('(^$)|(^\d+[kmg]$)')]
    [string]$SplitVolumeSizeCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Number of log files to keep per job name pattern. 0 for infinite. Overrides all config.")]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$LogRetentionCountCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Load and validate the entire configuration file, prints summary, then exit. Post-run actions simulated.")]
    [switch]$TestConfig,

    [Parameter(Mandatory=$false, HelpMessage="Switch. List defined Backup Locations (jobs) and exit.")]
    [switch]$ListBackupLocations,

    [Parameter(Mandatory=$false, HelpMessage="Switch. List defined Backup Sets and exit.")]
    [switch]$ListBackupSets,

    [Parameter(Mandatory=$false, HelpMessage="Switch. If present, skips the prompt to create 'User.psd1' if it's missing, and uses 'Default.psd1' directly.")]
    [switch]$SkipUserConfigCreation,

    [Parameter(Mandatory=$false, HelpMessage="Control script pause behaviour before exiting. Valid values: 'True', 'False', 'Always', 'Never', 'OnFailure', 'OnWarning', 'OnFailureOrWarning'. Overrides config.")]
    [ValidateSet("True", "False", "Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", IgnoreCase=$true)]
    [string]$PauseBehaviourCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: System action after script completion. Overrides ALL config. Valid: None, Shutdown, Restart, Hibernate, LogOff, Sleep, Lock.")]
    [ValidateSet("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock", IgnoreCase=$true)]
    [string]$PostRunActionCli,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Delay in seconds for PostRunActionCli. Default 0.")]
    [int]$PostRunActionDelaySecondsCli = 0,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Force PostRunActionCli (Shutdown/Restart).")]
    [switch]$PostRunActionForceCli,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Status(es) to trigger PostRunActionCli. Default 'ANY'. Valid: SUCCESS, WARNINGS, FAILURE, SIMULATED_COMPLETE, ANY.")]
    [ValidateSet("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY", IgnoreCase=$true)]
    [string[]]$PostRunActionTriggerOnStatusCli = @("ANY"),

    [Parameter(Mandatory=$false, HelpMessage="Switch. Checks for available updates to PoSh-Backup and exits.")]
    [switch]$CheckForUpdate,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Displays the PoSh-Backup script version and exits.")]
    [switch]$Version,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Suppresses all non-essential console output.")]
    [switch]$Quiet
)
#endregion

#region --- Initial Script Setup & Module Import ---
# Set global quiet mode flag immediately after parameter processing
$Global:IsQuietMode = $Quiet.IsPresent

# Import InitialisationManager first to set up globals and display banner
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\InitialisationManager.psm1") -Force -ErrorAction Stop
    Invoke-PoShBackupInitialSetup -MainScriptPath $PSCommandPath
} catch {
    Write-Host "[FATAL] Failed to import or run CRITICAL InitialisationManager.psm1 module." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 11
}

# Now that globals are set, Utils.psm1 (which provides Write-LogMessage) can be imported.
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -Global -ErrorAction Stop
} catch {
    Write-Host "[FATAL] Failed to import CRITICAL Utils.psm1 module." -ForegroundColor $Global:ColourError
    Write-Host "Ensure 'Modules\Utils.psm1' exists relative to PoSh-Backup.ps1." -ForegroundColor $Global:ColourError
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor "DarkRed"
    exit 10
}

$LoggerScriptBlock = ${function:Write-LogMessage}

# --- EARLY EXIT FOR CheckForUpdate ---
if ($CheckForUpdate.IsPresent) {
    Write-ConsoleBanner -NameText "Check for Update" `
                        -NameForegroundColor "Yellow" `
                        -BorderForegroundColor '$Global:ColourBorder' `
                        -CenterText `
    Write-Host
    $updateModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utilities\Update.psm1"
    try {
        if (-not (Test-Path -LiteralPath $updateModulePath -PathType Leaf)) {
            & $LoggerScriptBlock -Message "[ERROR] PoSh-Backup.ps1: Update module (Update.psm1) not found at '$updateModulePath'. Cannot check for updates." -Level "ERROR"
            throw "Update module not found."
        }
        Remove-Module -Name Update -Force -ErrorAction SilentlyContinue
        Import-Module -Name $updateModulePath -Force -ErrorAction Stop
        $updateCheckParams = @{
            Logger                 = $LoggerScriptBlock
            PSScriptRootForPaths   = $PSScriptRoot
            PSCmdletInstance       = $PSCmdlet
        }
        Invoke-PoShBackupUpdateCheckAndApply @updateCheckParams
        exit 0
    } catch {
        & $LoggerScriptBlock -Message "[FATAL] PoSh-Backup.ps1: Error during -CheckForUpdate mode. Error: $($_.Exception.Message)" -Level "ERROR"
        Write-Host "`n[ERROR] Update check failed: $($_.Exception.Message)" -ForegroundColor $Global:ColourError
        if ($Host.Name -eq "ConsoleHost") {
            Write-Host "`nPress any key to exit..." -ForegroundColor $Global:ColourWarning
            try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null } catch {
                & $LoggerScriptBlock -Message "[DEBUG] PoSh-Backup.ps1: Non-critical error during ReadKey for final pause: $($_.Exception.Message)" -Level "DEBUG"
            }
        }
        exit 13
    }
}
# --- END OF EARLY EXIT FOR CheckForUpdate ---

$ScriptStartTime                            = Get-Date
$IsSimulateMode                             = $Simulate.IsPresent
#endregion

#region --- CLI Override Processing & Core Setup ---
$cliOverrideSettings = $null
$Configuration = $null
$ActualConfigFile = $null
$jobsToProcess = [System.Collections.Generic.List[string]]::new()
$currentSetName = $null
$stopSetOnError = $true
$setSpecificPostRunAction = $null

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\CliManager.psm1") -Force -ErrorAction Stop
    $cliOverrideSettings = Get-PoShBackupCliOverride -BoundParameters $PSBoundParameters

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\CoreSetupManager.psm1") -Force -ErrorAction Stop
    $coreSetupResult = Invoke-PoShBackupCoreSetup -LoggerScriptBlock $LoggerScriptBlock `
                                                -PSScriptRoot $PSScriptRoot `
                                                -CliOverrideSettings $cliOverrideSettings `
                                                -BackupLocationName $BackupLocationName `
                                                -RunSet $RunSet `
                                                -ConfigFile $ConfigFile `
                                                -Simulate:$Simulate.IsPresent `
                                                -TestConfig:$TestConfig.IsPresent `
                                                -ListBackupLocations:$ListBackupLocations.IsPresent `
                                                -ListBackupSets:$ListBackupSets.IsPresent `
                                                -SyncSchedules:$SyncSchedules.IsPresent `
                                                -SkipUserConfigCreation:$SkipUserConfigCreation.IsPresent `
                                                -Version:$Version.IsPresent `
                                                -PSCmdlet $PSCmdlet `
                                                -ForceRunInMaintenanceMode:$ForceRunInMaintenanceMode.IsPresent `
                                                -Maintenance:$Maintenance

    $Configuration = $coreSetupResult.Configuration
    $ActualConfigFile = $coreSetupResult.ActualConfigFile
    $jobsToProcess = $coreSetupResult.JobsToProcess
    $currentSetName = $coreSetupResult.CurrentSetName
    $stopSetOnError = $coreSetupResult.StopSetOnErrorPolicy
    $setSpecificPostRunAction = $coreSetupResult.SetSpecificPostRunAction

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Core\JobOrchestrator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\FinalisationManager.psm1") -Force -ErrorAction Stop

} catch {
    if ($null -ne $LoggerScriptBlock) {
        & $LoggerScriptBlock -Message "[FATAL] PoSh-Backup.ps1: Critical error during CLI processing or core setup phase. Error: $($_.Exception.Message)" -Level "ERROR"
    } else {
        Write-Host "[FATAL] PoSh-Backup.ps1: Critical error during CLI processing or core setup phase. Logger not available. Error: $($_.Exception.Message)" -ForegroundColor $Global:ColourError
    }
    if ($Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to exit..." -ForegroundColor $Global:ColourWarning
        try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null } catch {
            # Log non-critical error during final pause attempt
            if ($null -ne $LoggerScriptBlock) {
                & $LoggerScriptBlock -Message "[DEBUG] PoSh-Backup.ps1: Non-critical error during ReadKey for final pause: $($_.Exception.Message)" -Level "DEBUG"
            }
        }
    }
    exit 12
}
#endregion

#region --- Main Processing (Delegated to JobOrchestrator.psm1) ---
$overallSetStatus = "SUCCESS"
$jobSpecificPostRunActionForNonSetRun = $null

if ($jobsToProcess.Count -gt 0) {
    $runParams = @{
        JobsToProcess            = $jobsToProcess
        CurrentSetName           = $currentSetName
        StopSetOnErrorPolicy     = $stopSetOnError
        SetSpecificPostRunAction = $setSpecificPostRunAction
        Configuration            = $Configuration
        PSScriptRootForPaths     = $PSScriptRoot
        ActualConfigFile         = $ActualConfigFile
        IsSimulateMode           = $IsSimulateMode
        Logger                   = $LoggerScriptBlock
        PSCmdlet                 = $PSCmdlet
        CliOverrideSettings      = $cliOverrideSettings
    }
    $orchestratorResult = Invoke-PoShBackupRun @runParams
    try {
        Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -ErrorAction Stop
    } catch {
        & $LoggerScriptBlock -Message "[FATAL PoSh-Backup.ps1] Failed to re-import Utils.psm1 locally. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    $overallSetStatus = $orchestratorResult.OverallSetStatus
    $jobSpecificPostRunActionForNonSetRun = $orchestratorResult.JobSpecificPostRunActionForNonSet
} else {
    & $LoggerScriptBlock -Message "[INFO] No jobs were processed (either none specified or dependency analysis resulted in an empty list)." -Level "INFO"
}
#endregion

#region --- Final Script Summary & Exit (Delegated to FinalisationManager.psm1) ---
Invoke-PoShBackupFinalisation -OverallSetStatus $overallSetStatus `
                              -ScriptStartTime $ScriptStartTime `
                              -IsSimulateMode:$IsSimulateMode `
                              -TestConfigIsPresent:$TestConfig.IsPresent `
                              -CliOverrideSettings $cliOverrideSettings `
                              -SetSpecificPostRunAction $setSpecificPostRunAction `
                              -JobSpecificPostRunActionForNonSetRun $jobSpecificPostRunActionForNonSetRun `
                              -Configuration $Configuration `
                              -LoggerScriptBlock $LoggerScriptBlock `
                              -PSCmdletInstance $PSCmdlet `
                              -CurrentSetNameForLog $currentSetName `
                              -JobNameForLog $(if ($jobsToProcess.Count -eq 1 -and (-not $currentSetName)) { $jobsToProcess[0] } else { $null }) `
                              -JobsToProcessCount $jobsToProcess.Count
# The Invoke-PoShBackupFinalisation function will call exit internally.
#endregion
