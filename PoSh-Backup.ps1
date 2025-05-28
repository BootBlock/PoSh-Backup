<#
.SYNOPSIS
    A highly comprehensive PowerShell script for directory and file backups using 7-Zip.
    Features include VSS (Volume Shadow Copy), configurable retries, script execution hooks,
    multi-format reporting, backup sets, 7-Zip process priority control, extensive
    customisation via an external .psd1 configuration file, remote Backup Targets,
    optional post-run system actions (e.g., shutdown, restart), optional
    archive checksum generation and verification, optional Self-Extracting Archive (SFX) creation,
    optional 7-Zip CPU core affinity (with CLI override), optional verification of local
    archives before remote transfer, configurable log file retention, and support for
    7-Zip include/exclude list files.

.DESCRIPTION
    The PoSh Backup ("PowerShell Backup") script provides an enterprise-grade, modular backup solution.
    It is designed for robustness, extensive configurability, and detailed operational feedback.
    Core logic is managed by this main script, which orchestrates operations performed by dedicated
    PowerShell modules. The main job/set processing loop is now handled by 'JobOrchestrator.psm1'.
    Post-run system action logic is now handled by 'PostRunActionOrchestrator.psm1'.

    Key Features:
    - Modular Design, External Configuration, Local and Remote Backups, Granular Job Control.
    - Backup Sets, Extensible Backup Target Providers (UNC, Replicate, SFTP).
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
    - 7-Zip Include/Exclude List Files (New): Specify external files containing lists of
      include or exclude patterns for 7-Zip, configurable globally, per-job, per-set, or via CLI.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location (job) to process.

.PARAMETER RunSet
    Optional. The name of a Backup Set to process.

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
    Optional. A switch parameter. If present, this forces the script to attempt using VSS.

.PARAMETER EnableRetriesCLI
    Optional. A switch parameter. If present, this forces the enabling of the 7-Zip retry mechanism for local archiving.

.PARAMETER GenerateHtmlReportCLI
    Optional. A switch parameter. If present, this forces the generation of an HTML report.

.PARAMETER TreatSevenZipWarningsAsSuccessCLI
    Optional. A switch parameter. If present, this forces 7-Zip exit code 1 (Warning) to be treated as a success for the job status.
    Overrides the 'TreatSevenZipWarningsAsSuccess' setting in the configuration file.

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
    Optional. A switch parameter. If present, loads, validates configuration, prints summary, then exits.
    Post-run system actions will be logged as if they would occur but not executed.

.PARAMETER ListBackupLocations
    Optional. A switch parameter. If present, lists defined Backup Locations (jobs) and exits.

.PARAMETER ListBackupSets
    Optional. A switch parameter. If present, lists defined Backup Sets and exits.

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

.EXAMPLE
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocs_To_UNC" -SevenZipExcludeListFileCLI "C:\Config\MyGlobalExcludes.txt"
    Runs the "MyDocs_To_UNC" job and uses the specified file for 7-Zip exclusion rules, overriding any
    include/exclude list files defined in the configuration for this job or globally.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.13.3 # Added SevenZipIncludeListFileCLI and SevenZipExcludeListFileCLI parameters.
    Date:           28-May-2025
    Requires:       PowerShell 5.1+, 7-Zip. Admin for VSS and some system actions.
    Modules:        Located in '.\Modules\': Utils.psm1 (facade), and sub-directories
                    'Core\', 'Operations\', 'Reporting\', 'Targets\', 'Utilities\'.
                    Optional: 'PoShBackupValidator.psm1'.
    Configuration:  Via '.\Config\Default.psd1' and '.\Config\User.psd1'.
    Script Name:    PoSh-Backup.ps1
#>

#region --- Script Parameters ---
param (
    [Parameter(Position=0, Mandatory=$false, HelpMessage="Optional. Name of a single backup location to process.")]
    [string]$BackupLocationName,

    [Parameter(Mandatory=$false, HelpMessage="Optional. Name of a Backup Set (defined in config) to process.")]
    [string]$RunSet,

    [Parameter(Mandatory=$false, HelpMessage="Optional. Path to the .psd1 configuration file. Defaults to '.\\Config\\Default.psd1' (and merges .\\Config\\User.psd1).")]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Run in simulation mode (local archiving, checksums, remote transfers, log retention, and post-run actions simulated).")]
    [switch]$Simulate,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Test local archive integrity after backup (includes checksum verification if enabled). Independent of -VerifyLocalArchiveBeforeTransferCLI.")]
    [switch]$TestArchive,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Verify local archive before remote transfer. Overrides config.")]
    [switch]$VerifyLocalArchiveBeforeTransferCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Attempt to use VSS. Requires Admin.")]
    [switch]$UseVSS,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Enable retry mechanism for 7-Zip (local archiving).")]
    [switch]$EnableRetriesCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Forces HTML report generation for processed jobs, or adds HTML if ReportGeneratorType is an array.")]
    [switch]$GenerateHtmlReportCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. If present, forces 7-Zip exit code 1 (Warning) to be treated as success for job status.")]
    [switch]$TreatSevenZipWarningsAsSuccessCLI,

    [Parameter(Mandatory=$false, HelpMessage="Optional. Set 7-Zip process priority (Idle, BelowNormal, Normal, AboveNormal, High).")]
    [ValidateSet("Idle", "BelowNormal", "Normal", "AboveNormal", "High")]
    [string]$SevenZipPriorityCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: 7-Zip CPU core affinity (e.g., '0,1' or '0x3'). Overrides config.")]
    [string]$SevenZipCpuAffinityCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Path to a text file containing 7-Zip include patterns. Overrides all configured include list files.")]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf -IsValid })]
    [string]$SevenZipIncludeListFileCLI,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Path to a text file containing 7-Zip exclude patterns. Overrides all configured exclude list files.")]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf -IsValid })]
    [string]$SevenZipExcludeListFileCLI,

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
    [string[]]$PostRunActionTriggerOnStatusCli = @("ANY")
)
#endregion

#region --- Initial Script Setup & Module Import ---
$ScriptStartTime                            = Get-Date
$IsSimulateMode                             = $Simulate.IsPresent # This is a bool

$cliOverrideSettings = @{
    UseVSS                             = if ($PSBoundParameters.ContainsKey('UseVSS')) { $UseVSS.IsPresent } else { $null }
    EnableRetries                      = if ($PSBoundParameters.ContainsKey('EnableRetriesCLI')) { $EnableRetriesCLI.IsPresent } else { $null }
    TestArchive                        = if ($PSBoundParameters.ContainsKey('TestArchive')) { $TestArchive.IsPresent } else { $null }
    VerifyLocalArchiveBeforeTransferCLI = if ($PSBoundParameters.ContainsKey('VerifyLocalArchiveBeforeTransferCLI')) { $VerifyLocalArchiveBeforeTransferCLI.IsPresent } else { $null }
    GenerateHtmlReport                 = if ($PSBoundParameters.ContainsKey('GenerateHtmlReportCLI')) { $GenerateHtmlReportCLI.IsPresent } else { $null }
    TreatSevenZipWarningsAsSuccess     = if ($PSBoundParameters.ContainsKey('TreatSevenZipWarningsAsSuccessCLI')) { $TreatSevenZipWarningsAsSuccessCLI.IsPresent } else { $null }
    SevenZipPriority                   = if ($PSBoundParameters.ContainsKey('SevenZipPriorityCLI')) { $SevenZipPriorityCLI } else { $null }
    SevenZipCpuAffinity                = if ($PSBoundParameters.ContainsKey('SevenZipCpuAffinityCLI')) { $SevenZipCpuAffinityCLI } else { $null }
    SevenZipIncludeListFile            = if ($PSBoundParameters.ContainsKey('SevenZipIncludeListFileCLI')) { $SevenZipIncludeListFileCLI } else { $null } # NEW
    SevenZipExcludeListFile            = if ($PSBoundParameters.ContainsKey('SevenZipExcludeListFileCLI')) { $SevenZipExcludeListFileCLI } else { $null } # NEW
    LogRetentionCountCLI               = if ($PSBoundParameters.ContainsKey('LogRetentionCountCLI')) { $LogRetentionCountCLI } else { $null }
    PauseBehaviour                     = if ($PSBoundParameters.ContainsKey('PauseBehaviourCLI')) { $PauseBehaviourCLI } else { $null }
    PostRunActionCli                   = if ($PSBoundParameters.ContainsKey('PostRunActionCli')) { $PostRunActionCli } else { $null }
    PostRunActionDelaySecondsCli       = if ($PSBoundParameters.ContainsKey('PostRunActionDelaySecondsCli')) { $PostRunActionDelaySecondsCli } else { $null }
    PostRunActionForceCli              = if ($PSBoundParameters.ContainsKey('PostRunActionForceCli')) { $PostRunActionForceCli.IsPresent } else { $null }
    PostRunActionTriggerOnStatusCli    = if ($PSBoundParameters.ContainsKey('PostRunActionTriggerOnStatusCli')) { $PostRunActionTriggerOnStatusCli } else { $null }
}

# Global colour definitions for Write-LogMessage
$Global:ColourInfo                          = "Cyan"
$Global:ColourSuccess                       = "Green"
$Global:ColourWarning                       = "Yellow"
$Global:ColourError                         = "Red"
$Global:ColourDebug                         = "Gray"
$Global:ColourValue                         = "DarkYellow"
$Global:ColourHeading                       = "White"
$Global:ColourSimulate                      = "Magenta"
$Global:ColourAdmin                         = "Orange"

$Global:StatusToColourMap = @{
    "SUCCESS"           = $Global:ColourSuccess
    "WARNINGS"          = $Global:ColourWarning
    "WARNING"           = $Global:ColourWarning
    "FAILURE"           = $Global:ColourError
    "ERROR"             = $Global:ColourError
    "SIMULATED_COMPLETE"= $Global:ColourSimulate
    "INFO"              = $Global:ColourInfo
    "DEBUG"             = $Global:ColourDebug
    "VSS"               = $Global:ColourAdmin
    "HOOK"              = $Global:ColourDebug
    "CONFIG_TEST"       = $Global:ColourSimulate
    "HEADING"           = $Global:ColourHeading
    "NONE"              = $Host.UI.RawUI.ForegroundColor
    "DEFAULT"           = $Global:ColourInfo
}

# Global variables for per-job logging and hook data, managed by JobOrchestrator.psm1
$Global:GlobalLogFile                       = $null
$Global:GlobalEnableFileLogging             = $false
$Global:GlobalLogDirectory                  = $null
$Global:GlobalJobLogEntries                 = $null
$Global:GlobalJobHookScriptData             = $null

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -Global -ErrorAction Stop
} catch {
    Write-Host "[FATAL] Failed to import CRITICAL Utils.psm1 module." -ForegroundColor Red
    Write-Host "Ensure 'Modules\Utils.psm1' exists relative to PoSh-Backup.ps1." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 10
}
$LoggerScriptBlock = ${function:Write-LogMessage}

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Core\ConfigManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Core\Operations.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Core\JobOrchestrator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\VssManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\RetentionManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\HookManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\SystemStateManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\ScriptModeHandler.psm1") -Force -ErrorAction Stop

    & $LoggerScriptBlock -Message "[INFO] Core modules loaded, including JobOrchestrator and PostRunActionOrchestrator." -Level "INFO"

} catch {
    & $LoggerScriptBlock -Message "[FATAL] Failed to import one or more required script modules." -Level "ERROR"
    & $LoggerScriptBlock -Message "Ensure core modules are in '.\Modules\' (or '.\Modules\Core\') relative to PoSh-Backup.ps1." -Level "ERROR"
    & $LoggerScriptBlock -Message "Error details: $($_.Exception.Message)" -Level "ERROR"
    exit 10
}

& $LoggerScriptBlock -Message "---------------------------------" -Level "NONE"
& $LoggerScriptBlock -Message " Starting PoSh Backup Script     " -Level "HEADING"
& $LoggerScriptBlock -Message " Script Version: v1.13.3 (Added 7-Zip include/exclude list file CLI parameters)" -Level "HEADING"
if ($IsSimulateMode) { & $LoggerScriptBlock -Message " ***** SIMULATION MODE ACTIVE ***** " -Level "SIMULATE" }
if ($TestConfig.IsPresent) { & $LoggerScriptBlock -Message " ***** CONFIGURATION TEST MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupLocations.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP LOCATIONS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupSets.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP SETS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($SkipUserConfigCreation.IsPresent) { & $LoggerScriptBlock -Message " ***** SKIP USER CONFIG CREATION ACTIVE ***** " -Level "INFO" }
if ($cliOverrideSettings.TreatSevenZipWarningsAsSuccess -eq $true) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Treating 7-Zip warnings as success. ***** " -Level "INFO" }
if ($cliOverrideSettings.SevenZipCpuAffinity) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: 7-Zip CPU Affinity specified: $($cliOverrideSettings.SevenZipCpuAffinity) ***** " -Level "INFO" }
if ($cliOverrideSettings.SevenZipIncludeListFile) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: 7-Zip Include List File specified: $($cliOverrideSettings.SevenZipIncludeListFile) ***** " -Level "INFO" } # NEW
if ($cliOverrideSettings.SevenZipExcludeListFile) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: 7-Zip Exclude List File specified: $($cliOverrideSettings.SevenZipExcludeListFile) ***** " -Level "INFO" } # NEW
if ($cliOverrideSettings.VerifyLocalArchiveBeforeTransferCLI -eq $true) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Verify Local Archive Before Transfer ENABLED. ***** " -Level "INFO" }
if ($null -ne $cliOverrideSettings.LogRetentionCountCLI) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Log Retention Count specified: $($cliOverrideSettings.LogRetentionCountCLI) ***** " -Level "INFO" }
if ($cliOverrideSettings.PostRunActionCli) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Post-Run Action specified: $($cliOverrideSettings.PostRunActionCli) ***** " -Level "INFO" }
& $LoggerScriptBlock -Message "---------------------------------" -Level "NONE"
#endregion

#region --- Configuration Loading, Validation & Job Determination ---

$configLoadParams = @{
    UserSpecifiedPath           = $ConfigFile
    IsTestConfigMode            = [bool](($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent))
    MainScriptPSScriptRoot      = $PSScriptRoot
    Logger                      = $LoggerScriptBlock
    SkipUserConfigCreationSwitch = [bool]$SkipUserConfigCreation.IsPresent
    IsSimulateModeSwitch        = [bool]$Simulate.IsPresent 
    ListBackupLocationsSwitch   = [bool]$ListBackupLocations.IsPresent
    ListBackupSetsSwitch        = [bool]$ListBackupSets.IsPresent
    CliOverrideSettings         = $cliOverrideSettings
}
$configResult = Import-AppConfiguration @configLoadParams

if (-not $configResult.IsValid) {
    & $LoggerScriptBlock -Message "FATAL: Configuration loading or validation failed. Exiting." -Level "ERROR"
    exit 1
}
$Configuration = $configResult.Configuration
$ActualConfigFile = $configResult.ActualPath

if ($configResult.PSObject.Properties.Name -contains 'UserConfigLoaded') {
    if ($configResult.UserConfigLoaded) {
        & $LoggerScriptBlock -Message "[INFO] User override configuration from '$($configResult.UserConfigPath)' was successfully loaded and merged." -Level "INFO"
    } elseif (($null -ne $configResult.UserConfigPath) -and (-not $configResult.UserConfigLoaded) -and (Test-Path -LiteralPath $configResult.UserConfigPath -PathType Leaf)) {
        & $LoggerScriptBlock -Message "[WARNING] User override configuration '$($configResult.UserConfigPath)' was found but an issue occurred during its loading/merging (check previous messages). Effective configuration may not include user overrides." -Level "WARNING"
    }
}

if ($null -ne $Configuration -and $Configuration -is [hashtable]) {
    $Configuration['_PoShBackup_PSScriptRoot'] = $PSScriptRoot
} else {
    & $LoggerScriptBlock -Message "FATAL: Configuration object is not a valid hashtable after loading. Cannot inject PSScriptRoot." -Level "ERROR"
    exit 1
}

Invoke-PoShBackupScriptMode -ListBackupLocationsSwitch $ListBackupLocations.IsPresent `
                            -ListBackupSetsSwitch $ListBackupSets.IsPresent `
                            -TestConfigSwitch $TestConfig.IsPresent `
                            -Configuration $Configuration `
                            -ActualConfigFile $ActualConfigFile `
                            -ConfigLoadResult $configResult `
                            -Logger $LoggerScriptBlock

$sevenZipPathFromFinalConfig = if ($Configuration.ContainsKey('SevenZipPath')) { $Configuration.SevenZipPath } else { $null }
if ([string]::IsNullOrWhiteSpace($sevenZipPathFromFinalConfig) -or -not (Test-Path -LiteralPath $sevenZipPathFromFinalConfig -PathType Leaf)) {
    & $LoggerScriptBlock -Message "FATAL: 7-Zip executable path ('$sevenZipPathFromFinalConfig') is invalid or not found after configuration loading and auto-detection attempts." -Level "ERROR"
    & $LoggerScriptBlock -Message "       Please ensure 'SevenZipPath' is correctly set in your configuration (Default.psd1 or User.psd1)," -Level "ERROR"
    & $LoggerScriptBlock -Message "       or that 7z.exe is available in standard Program Files locations or your system PATH for auto-detection." -Level "ERROR"

    $_earlyExitPauseSetting = if ($Configuration.ContainsKey('PauseBeforeExit')) { $Configuration.PauseBeforeExit } else { "Always" }
    $_shouldEarlyExitPause = $false
    if ($_earlyExitPauseSetting -is [bool]) {
        $_shouldEarlyExitPause = $_earlyExitPauseSetting
    } elseif ($_earlyExitPauseSetting -is [string]) {
        if ($_earlyExitPauseSetting.ToLowerInvariant() -in @("always", "onfailure", "onfailureorwarning", "true")) { $_shouldEarlyExitPause = $true }
    }
    if ($cliOverrideSettings.PauseBehaviour) {
        if ($cliOverrideSettings.PauseBehaviour.ToLowerInvariant() -in @("always", "onfailure", "onfailureorwarning", "true")) { $_shouldEarlyExitPause = $true }
        elseif ($cliOverrideSettings.PauseBehaviour.ToLowerInvariant() -in @("never", "false")) { $_shouldEarlyExitPause = $false }
    }

    if ($_shouldEarlyExitPause -and ($Host.Name -eq "ConsoleHost")) {
        & $LoggerScriptBlock -Message "`nPress any key to exit..." -Level "WARNING"
        try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
        catch { Write-Warning "Failed to read key for pause: $($_.Exception.Message)" }
    }
    exit 3
} else {
    & $LoggerScriptBlock -Message "[INFO] Effective 7-Zip executable path confirmed: '$sevenZipPathFromFinalConfig'" -Level "INFO"
}

$Global:GlobalEnableFileLogging = if ($Configuration.ContainsKey('EnableFileLogging')) { $Configuration.EnableFileLogging } else { $false }
if ($Global:GlobalEnableFileLogging) {
    $logDirConfig = if ($Configuration.ContainsKey('LogDirectory')) { $Configuration.LogDirectory } else { "Logs" }
    $Global:GlobalLogDirectory = if ([System.IO.Path]::IsPathRooted($logDirConfig)) { $logDirConfig } else { Join-Path -Path $PSScriptRoot -ChildPath $logDirConfig }

    if (-not (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
        try {
            New-Item -Path $Global:GlobalLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            & $LoggerScriptBlock -Message "[INFO] Log directory '$Global:GlobalLogDirectory' created." -Level "INFO"
        } catch {
            & $LoggerScriptBlock -Message "[WARNING] Failed to create log directory '$Global:GlobalLogDirectory'. File logging may be impacted. Error: $($_.Exception.Message)" -Level "WARNING"
            $Global:GlobalEnableFileLogging = $false
        }
    }
}

$jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet -Logger $LoggerScriptBlock
if (-not $jobResolutionResult.Success) {
    & $LoggerScriptBlock -Message "FATAL: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR"
    exit 1
}
$jobsToProcess = $jobResolutionResult.JobsToRun
$currentSetName = $jobResolutionResult.SetName
$stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy
$setSpecificPostRunAction = $jobResolutionResult.SetPostRunAction
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
    & $LoggerScriptBlock -Message "[INFO] No jobs were processed." -Level "INFO"
}
#endregion

#region --- Final Script Summary & Exit ---
$finalScriptEndTime = Get-Date
& $LoggerScriptBlock -Message "`n================================================================================" -Level "NONE"
& $LoggerScriptBlock -Message "All PoSh Backup Operations Completed" -Level "HEADING"
& $LoggerScriptBlock -Message "================================================================================" -Level "NONE"

if ($IsSimulateMode.IsPresent -and $overallSetStatus -ne "FAILURE" -and $overallSetStatus -ne "WARNINGS") {
    $overallSetStatus = "SIMULATED_COMPLETE"
}

& $LoggerScriptBlock -Message "Overall Script Status: $overallSetStatus" -Level $overallSetStatus
& $LoggerScriptBlock -Message "Script started : $ScriptStartTime" -Level "INFO"
& $LoggerScriptBlock -Message "Script ended   : $finalScriptEndTime" -Level "INFO"
& $LoggerScriptBlock -Message "Total duration : $($finalScriptEndTime - $ScriptStartTime)" -Level "INFO"

# --- Post-Run Action Handling (Delegated to PostRunActionOrchestrator.psm1) ---
$postRunParams = @{
    OverallStatus                     = $overallSetStatus
    CliOverrideSettings               = $cliOverrideSettings
    SetSpecificPostRunAction          = $setSpecificPostRunAction
    JobSpecificPostRunActionForNonSet = $jobSpecificPostRunActionForNonSetRun
    GlobalConfig                      = $Configuration
    IsSimulateMode                    = [bool]$Simulate.IsPresent 
    TestConfigIsPresent               = [bool]$TestConfig.IsPresent   
    Logger                            = $LoggerScriptBlock
    PSCmdletInstance                  = $PSCmdlet
    CurrentSetNameForLog              = $currentSetName
    JobNameForLog                     = if ($jobsToProcess.Count -eq 1 -and (-not $currentSetName)) { $jobsToProcess[0] } else { $null }
}
Invoke-PoShBackupPostRunActionHandler @postRunParams
# --- End Post-Run Action Handling ---

$_pauseDefaultFromScript = "OnFailureOrWarning"
$_pauseSettingFromConfig = if ($Configuration.ContainsKey('PauseBeforeExit')) { $Configuration.PauseBeforeExit } else { $_pauseDefaultFromScript }
$normalizedPauseConfigValue = ""
if ($_pauseSettingFromConfig -is [bool]) {
    $normalizedPauseConfigValue = if ($_pauseSettingFromConfig) { "always" } else { "never" }
} elseif ($null -ne $_pauseSettingFromConfig -and $_pauseSettingFromConfig -is [string]) {
    $normalizedPauseConfigValue = $_pauseSettingFromConfig.ToLowerInvariant()
} else {
    $normalizedPauseConfigValue = $_pauseDefaultFromScript.ToLowerInvariant()
}
$effectivePauseBehaviour = $normalizedPauseConfigValue
if ($null -ne $cliOverrideSettings.PauseBehaviour) {
    $effectivePauseBehaviour = $cliOverrideSettings.PauseBehaviour.ToLowerInvariant()
    if ($effectivePauseBehaviour -eq "true") { $effectivePauseBehaviour = "always" }
    if ($effectivePauseBehaviour -eq "false") { $effectivePauseBehaviour = "never" }
    & $LoggerScriptBlock -Message "[INFO] Pause behaviour explicitly set by CLI to: '$($cliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level "INFO"
}

$shouldPhysicallyPause = $false
switch ($effectivePauseBehaviour) {
    "always"             { $shouldPhysicallyPause = $true }
    "never"              { $shouldPhysicallyPause = $false }
    "onfailure"          { if ($overallSetStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
    "onwarning"          { if ($overallSetStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
    "onfailureorwarning" { if ($overallSetStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
    default {
        & $LoggerScriptBlock -Message "[WARNING] Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing (simulating 'Never' behaviour)." -Level "WARNING"
        $shouldPhysicallyPause = $false
    }
}
if (($IsSimulateMode.IsPresent -or $TestConfig.IsPresent) -and $effectivePauseBehaviour -ne "always") {
    $shouldPhysicallyPause = $false
}


if ($shouldPhysicallyPause) {
    & $LoggerScriptBlock -Message "`nPress any key to exit..." -Level "WARNING"
    if ($Host.Name -eq "ConsoleHost") {
        try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
        catch { Write-Warning "Failed to read key for final pause: $($_.Exception.Message)" }
    } else {
        & $LoggerScriptBlock -Message "  (Pause configured for '$effectivePauseBehaviour' and current status '$overallSetStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
    }
}

if ($overallSetStatus -in @("SUCCESS", "SIMULATED_COMPLETE")) { exit 0 }
elseif ($overallSetStatus -eq "WARNINGS") { exit 1 }
else { exit 2 }
#endregion
