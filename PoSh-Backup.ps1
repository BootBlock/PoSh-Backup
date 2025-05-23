<#
.SYNOPSIS
    A highly comprehensive PowerShell script for directory and file backups using 7-Zip.
    Features include VSS (Volume Shadow Copy), configurable retries, script execution hooks,
    multi-format reporting, backup sets, 7-Zip process priority control, extensive
    customisation via an external .psd1 configuration file, remote Backup Targets,
    optional post-run system state actions (e.g., shutdown, restart), and optional
    archive checksum generation and verification.

.DESCRIPTION
    The PoSh Backup ("PowerShell Backup") script provides an enterprise-grade, modular backup solution.
    It is designed for robustness, extensive configurability, and detailed operational feedback.
    Core logic is managed by the main script, which orchestrates operations performed by dedicated
    PowerShell modules for utility functions, configuration management, backup operations,
    password management, 7-Zip interaction, VSS management, retention policy management,
    hook script management, system state management, and script mode handling.

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
    - NEW: Post-Run System Actions: Optionally perform actions like shutdown, restart, hibernate, etc.,
      after job/set completion, configurable based on status, with delay and CLI override.
    - NEW: Archive Checksum Generation & Verification: Optionally generate checksum files (e.g., SHA256)
      for local archives and verify them during archive testing for enhanced integrity.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location (job) to process.

.PARAMETER RunSet
    Optional. The name of a Backup Set to process.

.PARAMETER ConfigFile
    Optional. Specifies the full path to a PoSh-Backup '.psd1' configuration file.

.PARAMETER Simulate
    Optional. A switch parameter. If present, the script runs in simulation mode.
    Local archive creation, checksum generation, remote transfers, retention actions, and post-run system actions
    will be logged but not executed.

.PARAMETER TestArchive
    Optional. A switch parameter. If present, this forces an integrity test of newly created local archives.
    If checksum verification is also enabled for the job, it will be performed as part of this test.

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
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocs_To_UNC"
    Runs the "MyDocs_To_UNC" job. If this job has a PostRunAction configured (e.g., Shutdown on SUCCESS),
    and the job is successful, the shutdown sequence will initiate after the job's hooks.
    If checksum generation is enabled for this job, a checksum file will be created alongside the archive.

.EXAMPLE
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups" -PostRunActionCli "Hibernate" -PostRunActionDelaySecondsCli 60
    Runs all jobs in the "DailyCriticalBackups" set. After the entire set completes, the system will
    attempt to hibernate after a 60-second cancellable delay, regardless of the set's or jobs'
    configured PostRunAction settings, and regardless of the set's final status (due to default CLI trigger "ANY").

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.11.5 # Modularised informational script modes.
    Date:           24-May-2025
    Requires:       PowerShell 5.1+, 7-Zip. Admin for VSS and some system actions.
    Modules:        Located in '.\Modules\': Utils.psm1, ConfigManager.psm1, Operations.psm1,
                    Reporting.psm1, PasswordManager.psm1, 7ZipManager.psm1, VssManager.psm1,
                    RetentionManager.psm1, HookManager.psm1, SystemStateManager.psm1,
                    ScriptModeHandler.psm1, and reporting sub-modules in '.\Modules\Reporting\'.
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

    [Parameter(Mandatory=$false, HelpMessage="Switch. Run in simulation mode (local archiving, checksums, remote transfers, and post-run actions simulated).")]
    [switch]$Simulate,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Test local archive integrity after backup (includes checksum verification if enabled).")]
    [switch]$TestArchive,

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

    # NEW CLI Parameters for Post-Run Action Override
    [Parameter(Mandatory=$false, HelpMessage="CLI Override: System action after script completion. Overrides ALL config. Valid: None, Shutdown, Restart, Hibernate, LogOff, Sleep, Lock.")]
    [ValidateSet("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock", IgnoreCase=$true)]
    [string]$PostRunActionCli,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Delay in seconds for PostRunActionCli. Default 0.")]
    [int]$PostRunActionDelaySecondsCli = 0, # Default to 0 if -PostRunActionCli is used but this isn't

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Force PostRunActionCli (Shutdown/Restart).")]
    [switch]$PostRunActionForceCli,

    [Parameter(Mandatory=$false, HelpMessage="CLI Override: Status(es) to trigger PostRunActionCli. Default 'ANY'. Valid: SUCCESS, WARNINGS, FAILURE, SIMULATED_COMPLETE, ANY.")]
    [ValidateSet("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY", IgnoreCase=$true)]
    [string[]]$PostRunActionTriggerOnStatusCli = @("ANY") # Default to ANY if -PostRunActionCli is used
)
#endregion

#region --- Initial Script Setup & Module Import ---
$ScriptStartTime                            = Get-Date
$IsSimulateMode                             = $Simulate.IsPresent

$cliOverrideSettings = @{
    UseVSS                             = if ($PSBoundParameters.ContainsKey('UseVSS')) { $UseVSS.IsPresent } else { $null }
    EnableRetries                      = if ($PSBoundParameters.ContainsKey('EnableRetriesCLI')) { $EnableRetriesCLI.IsPresent } else { $null }
    TestArchive                        = if ($PSBoundParameters.ContainsKey('TestArchive')) { $TestArchive.IsPresent } else { $null }
    GenerateHtmlReport                 = if ($PSBoundParameters.ContainsKey('GenerateHtmlReportCLI')) { $GenerateHtmlReportCLI.IsPresent } else { $null }
    TreatSevenZipWarningsAsSuccess     = if ($PSBoundParameters.ContainsKey('TreatSevenZipWarningsAsSuccessCLI')) { $TreatSevenZipWarningsAsSuccessCLI.IsPresent } else { $null }
    SevenZipPriority                   = if ($PSBoundParameters.ContainsKey('SevenZipPriorityCLI')) { $SevenZipPriorityCLI } else { $null }
    PauseBehaviour                     = if ($PSBoundParameters.ContainsKey('PauseBehaviourCLI')) { $PauseBehaviourCLI } else { $null }
    # Store CLI PostRunAction overrides
    PostRunActionCli                   = if ($PSBoundParameters.ContainsKey('PostRunActionCli')) { $PostRunActionCli } else { $null }
    PostRunActionDelaySecondsCli       = if ($PSBoundParameters.ContainsKey('PostRunActionDelaySecondsCli')) { $PostRunActionDelaySecondsCli } else { $null } 
    PostRunActionForceCli              = if ($PSBoundParameters.ContainsKey('PostRunActionForceCli')) { $PostRunActionForceCli.IsPresent } else { $null }
    PostRunActionTriggerOnStatusCli    = if ($PSBoundParameters.ContainsKey('PostRunActionTriggerOnStatusCli')) { $PostRunActionTriggerOnStatusCli } else { $null } 
}

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

$Global:GlobalLogFile                       = $null 
$Global:GlobalEnableFileLogging             = $false 
$Global:GlobalLogDirectory                  = $null 
$Global:GlobalJobLogEntries                 = $null 
$Global:GlobalJobHookScriptData             = $null 

try {
    # Import Utils.psm1 with -Global scope to ensure its functions are widely available
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -Global -ErrorAction Stop
} catch {
    Write-Host "[FATAL] Failed to import CRITICAL Utils.psm1 module." -ForegroundColor Red
    Write-Host "Ensure 'Modules\Utils.psm1' exists relative to PoSh-Backup.ps1." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 10 
}

$LoggerScriptBlock = ${function:Write-LogMessage}

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\ConfigManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Operations.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\VssManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\RetentionManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\HookManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\SystemStateManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\ScriptModeHandler.psm1") -Force -ErrorAction Stop # NEW
    
    & $LoggerScriptBlock -Message "[INFO] Core modules loaded, including SystemStateManager and ScriptModeHandler." -Level "INFO"

} catch {
    & $LoggerScriptBlock -Message "[FATAL] Failed to import one or more required script modules." -Level "ERROR"
    & $LoggerScriptBlock -Message "Ensure core modules are in '.\Modules\' relative to PoSh-Backup.ps1." -Level "ERROR"
    & $LoggerScriptBlock -Message "Error details: $($_.Exception.Message)" -Level "ERROR"
    exit 10 
}

& $LoggerScriptBlock -Message "---------------------------------" -Level "NONE"
& $LoggerScriptBlock -Message " Starting PoSh Backup Script     " -Level "HEADING"
& $LoggerScriptBlock -Message " Script Version: v1.11.5 (Modularised informational script modes)" -Level "HEADING" 
if ($IsSimulateMode) { & $LoggerScriptBlock -Message " ***** SIMULATION MODE ACTIVE ***** " -Level "SIMULATE" }
if ($TestConfig.IsPresent) { & $LoggerScriptBlock -Message " ***** CONFIGURATION TEST MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupLocations.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP LOCATIONS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupSets.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP SETS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($SkipUserConfigCreation.IsPresent) { & $LoggerScriptBlock -Message " ***** SKIP USER CONFIG CREATION ACTIVE ***** " -Level "INFO" }
if ($cliOverrideSettings.TreatSevenZipWarningsAsSuccess -eq $true) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Treating 7-Zip warnings as success. ***** " -Level "INFO" }
if ($cliOverrideSettings.PostRunActionCli) { & $LoggerScriptBlock -Message " ***** CLI OVERRIDE: Post-Run Action specified: $($cliOverrideSettings.PostRunActionCli) ***** " -Level "INFO" }
& $LoggerScriptBlock -Message "---------------------------------" -Level "NONE"
#endregion

#region --- Configuration Loading, Validation & Job Determination ---

$defaultConfigDir = Join-Path -Path $PSScriptRoot -ChildPath "Config"
$defaultBaseConfigFileName = "Default.psd1"
$defaultUserConfigFileName = "User.psd1"
$defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
$defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

if (-not $PSBoundParameters.ContainsKey('ConfigFile')) { 
    if (-not (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $defaultBaseConfigPath -PathType Leaf) {
            & $LoggerScriptBlock -Message "[INFO] User configuration file ('$defaultUserConfigPath') not found." -Level "INFO"
            if ($Host.Name -eq "ConsoleHost" -and `
                -not $TestConfig.IsPresent -and `
                -not $IsSimulateMode -and `
                -not $ListBackupLocations.IsPresent -and `
                -not $ListBackupSets.IsPresent -and `
                -not $SkipUserConfigCreation.IsPresent) { 
                $choiceTitle = "Create User Configuration?"
                $choiceMessage = "The user-specific configuration file '$($defaultUserConfigFileName)' was not found in '$($defaultConfigDir)'.`nIt is recommended to create this file as it allows you to customise settings without modifying`nthe default file, ensuring your settings are not overwritten by script upgrades.`n`nWould you like to create '$($defaultUserConfigFileName)' now by copying the contents of '$($defaultBaseConfigFileName)'?"
                $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Create '$($defaultUserConfigFileName)' from '$($defaultBaseConfigFileName)'."
                $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Do not create the file. The script will use '$($defaultBaseConfigFileName)' only for this run."
                $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
                $decision = $Host.UI.PromptForChoice($choiceTitle, $choiceMessage, $options, 0)
                if ($decision -eq 0) { 
                    try {
                        Copy-Item -LiteralPath $defaultBaseConfigPath -Destination $defaultUserConfigPath -Force -ErrorAction Stop
                        & $LoggerScriptBlock -Message "[SUCCESS] '$defaultUserConfigFileName' has been created from '$defaultBaseConfigFileName' in '$defaultConfigDir'." -Level "SUCCESS"
                        & $LoggerScriptBlock -Message "          Please edit '$defaultUserConfigFileName' with your desired settings and then re-run PoSh-Backup." -Level "INFO"
                        & $LoggerScriptBlock -Message "          Script will now exit." -Level "INFO"
                        $_pauseBehaviorFromCli = if ($cliOverrideSettings.PauseBehaviour) { $cliOverrideSettings.PauseBehaviour } else { "Always" } 
                        if ($_pauseBehaviorFromCli -is [string] -and $_pauseBehaviorFromCli.ToLowerInvariant() -ne "never" -and ($_pauseBehaviorFromCli -isnot [bool] -or $_pauseBehaviorFromCli -ne $false)) {
                           if ($Host.Name -eq "ConsoleHost") { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
                        }
                        exit 0
                    } catch {
                        & $LoggerScriptBlock -Message "[ERROR] Failed to copy '$defaultBaseConfigPath' to '$defaultUserConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                        & $LoggerScriptBlock -Message "          Please create '$defaultUserConfigFileName' manually if desired. Script will continue with base configuration." -Level "WARNING"
                    }
                } else { 
                    & $LoggerScriptBlock -Message "[INFO] User chose not to create '$defaultUserConfigFileName'. '$defaultBaseConfigFileName' will be used for this run." -Level "INFO"
                }
            } else { 
                 if ($SkipUserConfigCreation.IsPresent) {
                     & $LoggerScriptBlock -Message "[INFO] Skipping User.psd1 creation prompt as -SkipUserConfigCreation was specified. '$defaultBaseConfigFileName' will be used if '$defaultUserConfigFileName' is not found." -Level "INFO"
                 } elseif ($Host.Name -ne "ConsoleHost" -or $TestConfig.IsPresent -or $IsSimulateMode -or $ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent) {
                     & $LoggerScriptBlock -Message "[INFO] Not prompting to create '$defaultUserConfigFileName' (Non-interactive, TestConfig, Simulate, or List mode)." -Level "INFO"
                 }
                 & $LoggerScriptBlock -Message "       If you wish to have user-specific overrides, please manually copy '$defaultBaseConfigPath' to '$defaultUserConfigPath' and edit it." -Level "INFO"
            }
        } else { 
            & $LoggerScriptBlock -Message "[WARNING] Base configuration file ('$defaultBaseConfigPath') also not found. Cannot offer to create '$defaultUserConfigPath'." -Level "WARNING"
        }
    }
}

$configResult = Import-AppConfiguration -UserSpecifiedPath $ConfigFile `
                                         -IsTestConfigMode:(($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent)) `
                                         -MainScriptPSScriptRoot $PSScriptRoot `
                                         -Logger $LoggerScriptBlock 
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

# --- Invoke Script Mode Handler ---
# This function will exit the script if -ListBackupLocations, -ListBackupSets, or -TestConfig is active.
Invoke-PoShBackupScriptMode -ListBackupLocationsSwitch $ListBackupLocations.IsPresent `
                            -ListBackupSetsSwitch $ListBackupSets.IsPresent `
                            -TestConfigSwitch $TestConfig.IsPresent `
                            -Configuration $Configuration `
                            -ActualConfigFile $ActualConfigFile `
                            -ConfigLoadResult $configResult `
                            -Logger $LoggerScriptBlock
# If the script reaches here, it means no informational mode was handled, and we proceed to normal backup operations.


# --- 7-Zip Path and Log Directory Setup (only if not in an informational mode that would have exited) ---
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

#region --- Main Processing Loop (Iterate through Jobs) ---
$overallSetStatus = "SUCCESS" 
$jobSpecificPostRunAction = $null 

foreach ($currentJobName in $jobsToProcess) {
    & $LoggerScriptBlock -Message "`n================================================================================" -Level "NONE"
    & $LoggerScriptBlock -Message "Processing Job: $currentJobName" -Level "HEADING"
    & $LoggerScriptBlock -Message "================================================================================" -Level "NONE"

    $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
    $Global:GlobalJobHookScriptData = [System.Collections.Generic.List[object]]::new()

    $currentJobReportData = [ordered]@{ JobName = $currentJobName }
    $currentJobReportData['ScriptStartTime'] = Get-Date 

    $Global:GlobalLogFile = $null 
    if ($Global:GlobalEnableFileLogging) {
        $logDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $safeJobNameForFile = $currentJobName -replace '[^a-zA-Z0-9_-]', '_' 
        if (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory) -and (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
             $Global:GlobalLogFile = Join-Path -Path $Global:GlobalLogDirectory -ChildPath "$($safeJobNameForFile)_$($logDate).log"
             & $LoggerScriptBlock -Message "[INFO] Logging for job '$currentJobName' to file: $($Global:GlobalLogFile)" -Level "INFO"
        } else {
            & $LoggerScriptBlock -Message "[WARNING] Log directory is not valid. File logging for job '$currentJobName' will be skipped." -Level "WARNING"
        }
    }

    $jobConfig = $Configuration.BackupLocations[$currentJobName] 
    $jobSucceeded = $false 
    $effectiveJobConfigForThisJob = $null 

    try {
        # Parameters for Get-PoShBackupJobEffectiveConfiguration
        $effectiveConfigParams = @{
            JobConfig            = $jobConfig 
            GlobalConfig         = $Configuration 
            CliOverrides         = $cliOverrideSettings
            JobReportDataRef     = ([ref]$currentJobReportData) 
            Logger               = $LoggerScriptBlock 
            # IsSimulateMode is NOT passed to Get-PoShBackupJobEffectiveConfiguration
        }
        $effectiveJobConfigForThisJob = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams
        
        # Parameters for Invoke-PoShBackupJob (includes IsSimulateMode)
        $invokePoShBackupJobParams = @{
            JobName              = $currentJobName
            JobConfig            = $effectiveJobConfigForThisJob # Pass the resolved effective config
            GlobalConfig         = $Configuration 
            PSScriptRootForPaths = $PSScriptRoot 
            ActualConfigFile     = $ActualConfigFile
            JobReportDataRef     = ([ref]$currentJobReportData) 
            IsSimulateMode       = $IsSimulateMode # Invoke-PoShBackupJob DOES take this
            Logger               = $LoggerScriptBlock 
            PSCmdlet             = $PSCmdlet # Pass $PSCmdlet for ShouldProcess in Operations
        }
        $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams
        $currentJobIndividualStatus = $jobResult.Status 
        $jobSucceeded = ($currentJobIndividualStatus -eq "SUCCESS" -or $currentJobIndividualStatus -eq "SIMULATED_COMPLETE")

        if (-not $currentSetName) {
            $jobSpecificPostRunAction = $effectiveJobConfigForThisJob.PostRunAction
        }

    } catch {
        $currentJobIndividualStatus = "FAILURE" 
        & $LoggerScriptBlock -Message "[FATAL] Top-level unhandled exception during Invoke-PoShBackupJob for job '$currentJobName': $($_.Exception.ToString())" -Level "ERROR"
        $currentJobReportData['ErrorMessage'] = $_.Exception.ToString()
    }

    $currentJobReportData['LogEntries']  = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
    $currentJobReportData['HookScripts'] = if ($null -ne $Global:GlobalJobHookScriptData) { $Global:GlobalJobHookScriptData } else { [System.Collections.Generic.List[object]]::new() }

    if (-not ($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus')) {
        $currentJobReportData.OverallStatus = $currentJobIndividualStatus
    }
    $currentJobReportData['ScriptEndTime'] = Get-Date
    if (($currentJobReportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and `
        ($null -ne $currentJobReportData.ScriptStartTime) -and `
        ($null -ne $currentJobReportData.ScriptEndTime)) {
        $currentJobReportData['TotalDuration'] = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
        $currentJobReportData['TotalDurationSeconds'] = ($currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime).TotalSeconds
    } else {
        $currentJobReportData['TotalDuration'] = "N/A (Timing data incomplete)"
        $currentJobReportData['TotalDurationSeconds'] = 0
    }
    if (($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus') -and $currentJobReportData.OverallStatus -eq "FAILURE" -and -not ($currentJobReportData.PSObject.Properties.Name -contains 'ErrorMessage')) {
        $currentJobReportData['ErrorMessage'] = "Job failed; specific error caught by main loop or not recorded by Invoke-PoShBackupJob."
    }

    if ($currentJobIndividualStatus -eq "FAILURE") { $overallSetStatus = "FAILURE" }
    elseif ($currentJobIndividualStatus -eq "WARNINGS" -and $overallSetStatus -ne "FAILURE") { $overallSetStatus = "WARNINGS" }

    $displayStatusForLog = $currentJobReportData.OverallStatus
    & $LoggerScriptBlock -Message "Finished processing job '$currentJobName'. Status: $displayStatusForLog" -Level $displayStatusForLog

    $_jobSpecificReportTypesSetting = if ($jobConfig.ContainsKey('ReportGeneratorType')) { $jobConfig.ReportGeneratorType } elseif ($Configuration.ContainsKey('ReportGeneratorType')) { $Configuration.ReportGeneratorType } else { "HTML" }
    $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]::new()
    if ($_jobSpecificReportTypesSetting -is [array]) {
        $_jobSpecificReportTypesSetting | ForEach-Object { $_jobReportGeneratorTypesList.Add($_.ToString().ToUpperInvariant()) }
    } else {
        $_jobReportGeneratorTypesList.Add($_jobSpecificReportTypesSetting.ToString().ToUpperInvariant())
    }
    if ($cliOverrideSettings.GenerateHtmlReport -eq $true) { 
        if ("HTML" -notin $_jobReportGeneratorTypesList) { $_jobReportGeneratorTypesList.Add("HTML") }
        if ($_jobReportGeneratorTypesList.Contains("NONE") -and $_jobReportGeneratorTypesList.Count -gt 1) { $_jobReportGeneratorTypesList.Remove("NONE") } 
        elseif ($_jobReportGeneratorTypesList.Count -eq 1 -and $_jobReportGeneratorTypesList[0] -eq "NONE") { $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]@("HTML") }
    }
    $_finalJobReportTypes = $_jobReportGeneratorTypesList | Select-Object -Unique
    $_activeReportTypesForJob = $_finalJobReportTypes | Where-Object { $_ -ne "NONE" }

    if ($_activeReportTypesForJob.Count -gt 0) {
        $defaultJobReportsDir = Join-Path -Path $PSScriptRoot -ChildPath "Reports" 
        if (-not (Test-Path -LiteralPath $defaultJobReportsDir -PathType Container)) {
            & $LoggerScriptBlock -Message "[INFO] Default reports directory '$defaultJobReportsDir' does not exist. Attempting to create..." -Level "INFO"
            try {
                New-Item -Path $defaultJobReportsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                & $LoggerScriptBlock -Message "  - Default reports directory '$defaultJobReportsDir' created successfully." -Level "SUCCESS"
            } catch {
                & $LoggerScriptBlock -Message "[WARNING] Failed to create default reports directory '$defaultJobReportsDir'. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        Invoke-ReportGenerator -ReportDirectory $defaultJobReportsDir `
                               -JobName $currentJobName `
                               -ReportData $currentJobReportData `
                               -GlobalConfig $Configuration `
                               -JobConfig $jobConfig `
                               -Logger $LoggerScriptBlock 
    }

    if ($currentSetName -and (-not $jobSucceeded) -and $stopSetOnError) {
        & $LoggerScriptBlock -Message "[ERROR] Job '$currentJobName' in set '$currentSetName' failed (operational status: $currentJobIndividualStatus). Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
        break 
    }
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
    # If in Simulate or TestConfig mode, only pause if 'always' is explicitly set.
    # This was the previous behaviour for TestConfig, extending to Simulate for consistency.
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

# --- Post-Run System Action Logic ---
$finalPostRunActionSettings = $null
$actionSource = "None" 

if ($null -ne $cliOverrideSettings.PostRunActionCli) {
    $finalPostRunActionSettings = @{
        Enabled         = ($cliOverrideSettings.PostRunActionCli.ToLowerInvariant() -ne "none")
        Action          = $cliOverrideSettings.PostRunActionCli
        DelaySeconds    = if ($null -ne $cliOverrideSettings.PostRunActionDelaySecondsCli) { $cliOverrideSettings.PostRunActionDelaySecondsCli } else { 0 }
        TriggerOnStatus = if ($null -ne $cliOverrideSettings.PostRunActionTriggerOnStatusCli) { @($cliOverrideSettings.PostRunActionTriggerOnStatusCli) } else { @("ANY") }
        ForceAction     = if ($null -ne $cliOverrideSettings.PostRunActionForceCli) { $cliOverrideSettings.PostRunActionForceCli } else { $false }
    }
    $actionSource = "CLI Override"
} elseif ($null -ne $setSpecificPostRunAction) {
    $finalPostRunActionSettings = $setSpecificPostRunAction
    $actionSource = "Backup Set '$currentSetName'"
} elseif ($null -ne $jobSpecificPostRunAction) { 
    $finalPostRunActionSettings = $jobSpecificPostRunAction
    $actionSource = "Job '$($jobsToProcess[0])'"
} else {
    $globalDefaultsPRA = Get-ConfigValue -ConfigObject $Configuration -Key 'PostRunActionDefaults' -DefaultValue @{}
    if ($null -ne $globalDefaultsPRA -and $globalDefaultsPRA.ContainsKey('Enabled') -and $globalDefaultsPRA.Enabled) {
        $finalPostRunActionSettings = $globalDefaultsPRA
        $actionSource = "Global Defaults"
    }
}

if ($null -ne $finalPostRunActionSettings -and `
    $finalPostRunActionSettings.ContainsKey('Enabled') -and $finalPostRunActionSettings.Enabled -eq $true -and `
    $finalPostRunActionSettings.ContainsKey('Action') -and $finalPostRunActionSettings.Action.ToLowerInvariant() -ne "none") {
    
    $triggerStatuses = @($finalPostRunActionSettings.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
    $effectiveOverallStatusForTrigger = $overallSetStatus.ToUpperInvariant()
    if ($TestConfig.IsPresent) { $effectiveOverallStatusForTrigger = "SIMULATED_COMPLETE" } 

    if ($triggerStatuses -contains "ANY" -or $effectiveOverallStatusForTrigger -in $triggerStatuses) {
        # Action will be attempted or simulated
        if ($actionSource -ne "None") {
            & $LoggerScriptBlock -Message "[INFO] Post-Run Action: Using settings from $($actionSource)." -Level "INFO"
        }
        & $LoggerScriptBlock -Message "[INFO] Post-Run Action: Conditions met for action '$($finalPostRunActionSettings.Action)' (Source: $actionSource, Triggered by Status: $effectiveOverallStatusForTrigger)." -Level "INFO"
        
        $systemActionParams = @{
            Action          = $finalPostRunActionSettings.Action
            DelaySeconds    = $finalPostRunActionSettings.DelaySeconds
            ForceAction     = $finalPostRunActionSettings.ForceAction
            IsSimulateMode  = ($IsSimulateMode.IsPresent -or $TestConfig.IsPresent) 
            Logger          = $LoggerScriptBlock
            PSCmdletInstance = $PSCmdlet 
        }
        Invoke-SystemStateAction @systemActionParams
    }
    # If not triggered by status, no INFO/DEBUG log will be generated about it.
}
# If the above 'if' condition is false (no action configured, or disabled, or action is "None"),
# then no logging related to Post-Run Actions occurs at all.
# --- END Post-Run System Action Logic ---


if ($overallSetStatus -in @("SUCCESS", "SIMULATED_COMPLETE")) { exit 0 }
elseif ($overallSetStatus -eq "WARNINGS") { exit 1 } 
else { exit 2 } 
#endregion
