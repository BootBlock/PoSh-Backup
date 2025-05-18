<#
.SYNOPSIS
    A highly comprehensive PowerShell script for directory and file backups using 7-Zip.
    Features include VSS (Volume Shadow Copy), configurable retries, script execution hooks,
    multi-format reporting (HTML, CSV, JSON, etc.), backup sets, 7-Zip process priority control,
    and extensive customisation via an external .psd1 configuration file and PowerShell modules.
    Script name: PoSh-Backup.

.DESCRIPTION
    The PoSh Backup ("PowerShell Backup") script provides an enterprise-grade, modular backup solution.
    It is designed for robustness, extensive configurability, and detailed operational feedback.
    Core logic is managed by the main script, which orchestrates operations performed by dedicated
    PowerShell modules for utility functions, configuration management, backup operations,
    password management, 7-Zip interaction, VSS management, retention policy management, 
    hook script management, and reporting.

    Key Features:
    - Modular Design: Facilitates maintainability and clarity by separating concerns into modules
      (e.g., Utils.psm1, ConfigManager.psm1, Operations.psm1, Reporting.psm1, PasswordManager.psm1,
      7ZipManager.psm1, VssManager.psm1, RetentionManager.psm1, HookManager.psm1, and specific report format modules).
    - External Configuration: All backup jobs, global settings, and backup sets are defined in an
      external '.psd1' configuration file (managed by ConfigManager.psm1).
    - Early 7-Zip Path Validation, Backup Jobs, Backup Sets.
    - Volume Shadow Copy Service (VSS): Managed by VssManager.psm1.
    - 7-Zip Integration: Managed by 7ZipManager.psm1.
    - Secure Password Handling, Configurable Archive Naming.
    - Retention Policies: Managed by RetentionManager.psm1.
    - Retry Mechanism, 7-Zip Process Priority, Script Hooks (managed by HookManager.psm1).
    - Detailed Multi-Format Reports, Extensive Logging.
    - Simulation Mode (-Simulate), Configuration Test Mode (-TestConfig), List Configured Items.
    - Free Space Check, Archive Integrity Test, Configurable Exit Pause.
    - Skip User Config Creation: Bypass prompt to create 'User.psd1'.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location (job) to process.

.PARAMETER RunSet
    Optional. The name of a Backup Set to process.

.PARAMETER ConfigFile
    Optional. Specifies the full path to a PoSh-Backup '.psd1' configuration file.

.PARAMETER Simulate
    Optional. A switch parameter. If present, the script runs in simulation mode.

.PARAMETER TestArchive
    Optional. A switch parameter. If present, this forces an integrity test of newly created archives.

.PARAMETER UseVSS
    Optional. A switch parameter. If present, this forces the script to attempt using VSS.

.PARAMETER EnableRetriesCLI
    Optional. A switch parameter. If present, this forces the enabling of the 7-Zip retry mechanism.

.PARAMETER GenerateHtmlReportCLI
    Optional. A switch parameter. If present, this forces the generation of an HTML report.

.PARAMETER SevenZipPriorityCLI
    Optional. Allows specifying the 7-Zip process priority.
    Valid values: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".

.PARAMETER TestConfig
    Optional. A switch parameter. If present, loads, validates configuration, prints summary, then exits.

.PARAMETER ListBackupLocations
    Optional. A switch parameter. If present, lists defined Backup Locations (jobs) and exits.

.PARAMETER ListBackupSets
    Optional. A switch parameter. If present, lists defined Backup Sets and exits.

.PARAMETER SkipUserConfigCreation
    Optional. A switch parameter. If present, bypasses the prompt to create 'User.psd1'.

.PARAMETER PauseBehaviourCLI
    Optional. Controls script pause behaviour before exiting.
    Valid values: "True", "False", "Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning".

.EXAMPLE
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups"
    Runs all backup jobs defined in the "DailyCriticalBackups" backup set.

.EXAMPLE
    .\PoSh-Backup.ps1 -BackupLocationName "WebAppLogs" -UseVSS -Simulate
    Simulates backing up "WebAppLogs", forcing VSS.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.9.12 # Corrected module import order for Write-LogMessage availability.
    Date:           18-May-2025
    Requires:       PowerShell 5.1+, 7-Zip. Admin for VSS.
    Modules:        Located in '.\Modules\': Utils.psm1, ConfigManager.psm1, Operations.psm1,
                    Reporting.psm1, PasswordManager.psm1, 7ZipManager.psm1, VssManager.psm1,
                    RetentionManager.psm1, HookManager.psm1, and reporting sub-modules in '.\Modules\Reporting\'.
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

    [Parameter(Mandatory=$false, HelpMessage="Switch. Run in simulation mode.")]
    [switch]$Simulate,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Test archive integrity after backup.")]
    [switch]$TestArchive,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Attempt to use VSS. Requires Admin.")]
    [switch]$UseVSS,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Enable retry mechanism for 7-Zip.")]
    [switch]$EnableRetriesCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Forces HTML report generation for processed jobs, or adds HTML if ReportGeneratorType is an array.")]
    [switch]$GenerateHtmlReportCLI,

    [Parameter(Mandatory=$false, HelpMessage="Optional. Set 7-Zip process priority (Idle, BelowNormal, Normal, AboveNormal, High).")]
    [ValidateSet("Idle", "BelowNormal", "Normal", "AboveNormal", "High")]
    [string]$SevenZipPriorityCLI,

    [Parameter(Mandatory=$false, HelpMessage="Switch. Load and validate the entire configuration file, prints summary, then exit.")]
    [switch]$TestConfig,

    [Parameter(Mandatory=$false, HelpMessage="Switch. List defined Backup Locations (jobs) and exit.")]
    [switch]$ListBackupLocations,

    [Parameter(Mandatory=$false, HelpMessage="Switch. List defined Backup Sets and exit.")]
    [switch]$ListBackupSets,

    [Parameter(Mandatory=$false, HelpMessage="Switch. If present, skips the prompt to create 'User.psd1' if it's missing, and uses 'Default.psd1' directly.")]
    [switch]$SkipUserConfigCreation,

    [Parameter(Mandatory=$false, HelpMessage="Control script pause behaviour before exiting. Valid values: 'True', 'False', 'Always', 'Never', 'OnFailure', 'OnWarning', 'OnFailureOrWarning'. Overrides config.")]
    [ValidateSet("True", "False", "Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", IgnoreCase=$true)]
    [string]$PauseBehaviourCLI
)
#endregion

#region --- Initial Script Setup & Module Import ---
$ScriptStartTime                            = Get-Date
$IsSimulateMode                             = $Simulate.IsPresent

$cliOverrideSettings = @{
    UseVSS                  = $UseVSS.IsPresent
    EnableRetries           = $EnableRetriesCLI.IsPresent
    TestArchive             = $TestArchive.IsPresent
    GenerateHtmlReport      = $GenerateHtmlReportCLI.IsPresent
    SevenZipPriority        = if (-not [string]::IsNullOrWhiteSpace($SevenZipPriorityCLI)) { $SevenZipPriorityCLI } else { $null }
    PauseBehaviour          = if ($PSBoundParameters.ContainsKey('PauseBehaviourCLI')) { $PauseBehaviourCLI } else { $null }
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
    "FAILURE"           = $Global:ColourError
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

# CRITICAL: Import Utils.psm1 FIRST to make Write-LogMessage available.
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Host "[FATAL] Failed to import CRITICAL Utils.psm1 module." -ForegroundColor Red
    Write-Host "Ensure 'Modules\Utils.psm1' exists relative to PoSh-Backup.ps1." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 10
}

# Define the logger scriptblock now that Write-LogMessage is available.
$LoggerScriptBlock = ${function:Write-LogMessage}

# Import remaining core modules.
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\ConfigManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Operations.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\VssManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\RetentionManager.psm1") -Force -ErrorAction Stop 
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\HookManager.psm1") -Force -ErrorAction Stop 
    
    & $LoggerScriptBlock -Message "[INFO] Core modules Utils, ConfigManager, Operations, Reporting, 7ZipManager, VssManager, RetentionManager, and HookManager loaded." -Level "INFO" -ForegroundColour $Global:ColourInfo

} catch {
    & $LoggerScriptBlock -Message "[FATAL] Failed to import one or more required script modules." -Level "ERROR"
    & $LoggerScriptBlock -Message "Ensure core modules are in '.\Modules\' relative to PoSh-Backup.ps1." -Level "ERROR"
    & $LoggerScriptBlock -Message "Error details: $($_.Exception.Message)" -Level "ERROR"
    exit 10
}

& $LoggerScriptBlock -Message "---------------------------------" -Level "NONE"
& $LoggerScriptBlock -Message " Starting PoSh Backup Script     " -Level "HEADING"
& $LoggerScriptBlock -Message " Script Version: v1.9.12 (Corrected module import order for Write-LogMessage availability.)" -Level "HEADING" 
if ($IsSimulateMode) { & $LoggerScriptBlock -Message " ***** SIMULATION MODE ACTIVE ***** " -Level "SIMULATE" }
if ($TestConfig.IsPresent) { & $LoggerScriptBlock -Message " ***** CONFIGURATION TEST MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupLocations.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP LOCATIONS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupSets.IsPresent) { & $LoggerScriptBlock -Message " ***** LIST BACKUP SETS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($SkipUserConfigCreation.IsPresent) { & $LoggerScriptBlock -Message " ***** SKIP USER CONFIG CREATION ACTIVE ***** " -Level "INFO" }
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
                        $_pauseBehaviorFromCli = if ($cliOverrideSettings.ContainsKey('PauseBehaviour')) { $cliOverrideSettings.PauseBehaviour } else { "Always" }
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

if (-not ($ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent -or $TestConfig.IsPresent)) {
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
}

if (-not ($ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent)) {
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
}

if ($ListBackupLocations.IsPresent) {
    & $LoggerScriptBlock -Message "`n--- Defined Backup Locations (Jobs) from '$($ActualConfigFile)' ---" -Level "HEADING"
    if ($configResult.UserConfigLoaded) {
        & $LoggerScriptBlock -Message "    (Includes overrides from '$($configResult.UserConfigPath)')" -Level "INFO"
    }
    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
            & $LoggerScriptBlock -Message ("`n  Job Name      : " + $_.Name) -Level "NONE"
            $sourcePaths = if ($_.Value.Path -is [array]) { ($_.Value.Path | ForEach-Object { "                  `"$_`"" }) -join [Environment]::NewLine } else { "                  `"$($_.Value.Path)`"" }
            & $LoggerScriptBlock -Message ("  Source Path(s):`n" + $sourcePaths) -Level "NONE"
            $archiveNameDisplay = if ($_.Value.ContainsKey('Name')) { $_.Value.Name } else { 'N/A' }
            & $LoggerScriptBlock -Message ("  Archive Name  : " + $archiveNameDisplay) -Level "NONE"
            $destDirDisplay = if ($_.Value.ContainsKey('DestinationDir')) { $_.Value.DestinationDir } elseif ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }
            & $LoggerScriptBlock -Message ("  Destination   : " + $destDirDisplay) -Level "NONE"
        }
    } else {
        & $LoggerScriptBlock -Message "No Backup Locations are defined in the configuration." -Level "WARNING"
    }
    & $LoggerScriptBlock -Message "`n--- Listing Complete ---" -Level "HEADING"
    exit 0
}

if ($ListBackupSets.IsPresent) {
    & $LoggerScriptBlock -Message "`n--- Defined Backup Sets from '$($ActualConfigFile)' ---" -Level "HEADING"
    if ($configResult.UserConfigLoaded) {
        & $LoggerScriptBlock -Message "    (Includes overrides from '$($configResult.UserConfigPath)')" -Level "INFO"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
            & $LoggerScriptBlock -Message ("`n  Set Name     : " + $_.Name) -Level "NONE"
            $jobsInSet = if ($_.Value.JobNames -is [array]) { ($_.Value.JobNames | ForEach-Object { "                 $_" }) -join [Environment]::NewLine } else { "                 None listed" }
            & $LoggerScriptBlock -Message ("  Jobs in Set  :`n" + $jobsInSet) -Level "NONE"
            $onErrorDisplay = if ($_.Value.ContainsKey('OnErrorInJob')) { $_.Value.OnErrorInJob } else { 'StopSet' }
            & $LoggerScriptBlock -Message ("  On Error     : " + $onErrorDisplay) -Level "NONE"
        }
    } else {
        & $LoggerScriptBlock -Message "No Backup Sets are defined in the configuration." -Level "WARNING"
    }
    & $LoggerScriptBlock -Message "`n--- Listing Complete ---" -Level "HEADING"
    exit 0
}

if ($TestConfig.IsPresent) {
    & $LoggerScriptBlock -Message "`n[INFO] --- Configuration Test Mode Summary ---" -Level "CONFIG_TEST"
    & $LoggerScriptBlock -Message "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -Level "CONFIG_TEST"
    if ($configResult.UserConfigLoaded) {
        & $LoggerScriptBlock -Message "          (User overrides from '$($configResult.UserConfigPath)' were applied)" -Level "CONFIG_TEST"
    }
    & $LoggerScriptBlock -Message "`n  --- Key Global Settings ---" -Level "CONFIG_TEST"

    $sevenZipPathDisplay = if($Configuration.ContainsKey('SevenZipPath')){ $Configuration.SevenZipPath } else { 'N/A' }
    & $LoggerScriptBlock -Message ("    7-Zip Path              : {0}" -f $sevenZipPathDisplay) -Level "CONFIG_TEST"

    $defaultDestDirDisplay = if($Configuration.ContainsKey('DefaultDestinationDir')){ $Configuration.DefaultDestinationDir } else { 'N/A' }
    & $LoggerScriptBlock -Message ("    Default Destination Dir : {0}" -f $defaultDestDirDisplay) -Level "CONFIG_TEST"

    $logDirDisplay = if($Configuration.ContainsKey('LogDirectory')){ $Configuration.LogDirectory } else { 'N/A (File Logging Disabled)' }
    & $LoggerScriptBlock -Message ("    Log Directory           : {0}" -f $logDirDisplay) -Level "CONFIG_TEST"
    
    $htmlReportDirDisplay = if($Configuration.ContainsKey('HtmlReportDirectory')){ $Configuration.HtmlReportDirectory } else { 'N/A' }
    & $LoggerScriptBlock -Message ("    Default Report Dir (HTML): {0}" -f $htmlReportDirDisplay) -Level "CONFIG_TEST"

    $vssEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableVSS')){ $Configuration.EnableVSS } else { $false }
    & $LoggerScriptBlock -Message ("    Default VSS Enabled     : {0}" -f $vssEnabledDisplayGlobal) -Level "CONFIG_TEST"

    $retriesEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableRetries')){ $Configuration.EnableRetries } else { $false }
    & $LoggerScriptBlock -Message ("    Default Retries Enabled : {0}" -f $retriesEnabledDisplayGlobal) -Level "CONFIG_TEST"

    $pauseExitDisplayGlobal = if($Configuration.ContainsKey('PauseBeforeExit')){ $Configuration.PauseBeforeExit } else { 'OnFailureOrWarning' }
    & $LoggerScriptBlock -Message ("    Pause Before Exit       : {0}" -f $pauseExitDisplayGlobal) -Level "CONFIG_TEST"

    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        & $LoggerScriptBlock -Message "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
        foreach ($jobNameKey in ($Configuration.BackupLocations.Keys | Sort-Object)) { 
            $jobConf = $Configuration.BackupLocations[$jobNameKey]
            & $LoggerScriptBlock -Message ("    Job: {0}" -f $jobNameKey) -Level "CONFIG_TEST" 
            
            $sourcePathsDisplay = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }
            & $LoggerScriptBlock -Message ("      Source(s)    : {0}" -f $sourcePathsDisplay) -Level "CONFIG_TEST"
            
            $destDirDisplayJob = if ($jobConf.ContainsKey('DestinationDir')) { $jobConf.DestinationDir } elseif ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }
            & $LoggerScriptBlock -Message ("      Destination  : {0}" -f $destDirDisplayJob) -Level "CONFIG_TEST"
            
            $archiveNameDisplayJob = if ($jobConf.ContainsKey('Name')) { $jobConf.Name } else { 'N/A' }
            & $LoggerScriptBlock -Message ("      Archive Name : {0}" -f $archiveNameDisplayJob) -Level "CONFIG_TEST"
            
            $vssEnabledDisplayJob = if ($jobConf.ContainsKey('EnableVSS')) { $jobConf.EnableVSS } elseif ($Configuration.ContainsKey('EnableVSS')) { $Configuration.EnableVSS } else { $false }
            & $LoggerScriptBlock -Message ("      VSS Enabled  : {0}" -f $vssEnabledDisplayJob) -Level "CONFIG_TEST"
            
            $retentionDisplayJob = if ($jobConf.ContainsKey('RetentionCount')) { $jobConf.RetentionCount } else { 'N/A' }
            & $LoggerScriptBlock -Message ("      Retention    : {0}" -f $retentionDisplayJob) -Level "CONFIG_TEST"
        }
    } else {
        & $LoggerScriptBlock -Message "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
        & $LoggerScriptBlock -Message "    No Backup Locations defined in the configuration." -Level "CONFIG_TEST"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        & $LoggerScriptBlock -Message "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
        foreach ($setNameKey in ($Configuration.BackupSets.Keys | Sort-Object)) { 
            $setConf = $Configuration.BackupSets[$setNameKey]
            & $LoggerScriptBlock -Message ("    Set: {0}" -f $setNameKey) -Level "CONFIG_TEST" 
            
            $jobsInSetDisplay = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }
            & $LoggerScriptBlock -Message ("      Jobs in Set  : {0}" -f $jobsInSetDisplay) -Level "CONFIG_TEST"
            
            $onErrorDisplaySet = if ($setConf.ContainsKey('OnErrorInJob')) { $setConf.OnErrorInJob } else { 'StopSet' }
            & $LoggerScriptBlock -Message ("      On Error     : {0}" -f $onErrorDisplaySet) -Level "CONFIG_TEST"
        }
    } else {
        & $LoggerScriptBlock -Message "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
        & $LoggerScriptBlock -Message "    No Backup Sets defined in the configuration." -Level "CONFIG_TEST"
    }
    & $LoggerScriptBlock -Message "`n[INFO] --- Configuration Test Mode Finished ---" -Level "CONFIG_TEST"
    exit 0
}

$jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet -Logger $LoggerScriptBlock
if (-not $jobResolutionResult.Success) {
    & $LoggerScriptBlock -Message "FATAL: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR"
    exit 1
}
$jobsToProcess = $jobResolutionResult.JobsToRun
$currentSetName = $jobResolutionResult.SetName
$stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy
#endregion

#region --- Main Processing Loop (Iterate through Jobs) ---
$overallSetStatus = "SUCCESS"

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

    try {
        $invokePoShBackupJobParams = @{
            JobName             = $currentJobName
            JobConfig           = $jobConfig 
            GlobalConfig        = $Configuration 
            CliOverrides        = $cliOverrideSettings
            PSScriptRootForPaths = $PSScriptRoot
            ActualConfigFile    = $ActualConfigFile
            JobReportDataRef    = ([ref]$currentJobReportData)
            IsSimulateMode      = $IsSimulateMode
            Logger              = $LoggerScriptBlock 
        }
        $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams
        $currentJobStatus = $jobResult.Status
    } catch {
        $currentJobStatus = "FAILURE"
        & $LoggerScriptBlock -Message "[FATAL] Top-level unhandled exception during Invoke-PoShBackupJob for job '$currentJobName': $($_.Exception.ToString())" -Level "ERROR"
        $currentJobReportData['ErrorMessage'] = $_.Exception.ToString()
    }

    $currentJobReportData['LogEntries']  = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
    $currentJobReportData['HookScripts'] = if ($null -ne $Global:GlobalJobHookScriptData) { $Global:GlobalJobHookScriptData } else { [System.Collections.Generic.List[object]]::new() }

    if (-not ($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus')) {
        $currentJobReportData.OverallStatus = $currentJobStatus
    }
    $currentJobReportData['ScriptEndTime'] = Get-Date

    if (($currentJobReportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and `
        ($null -ne $currentJobReportData.ScriptStartTime) -and `
        ($null -ne $currentJobReportData.ScriptEndTime)) {
        $currentJobReportData['TotalDuration'] = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
    } else {
        $currentJobReportData['TotalDuration'] = "N/A (Timing data incomplete)"
    }

    if (($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus') -and $currentJobReportData.OverallStatus -eq "FAILURE" -and -not ($currentJobReportData.PSObject.Properties.Name -contains 'ErrorMessage')) {
        $currentJobReportData['ErrorMessage'] = "Job failed; specific error caught by main loop or not recorded by Invoke-PoShBackupJob."
    }

    if ($currentJobStatus -eq "FAILURE") { $overallSetStatus = "FAILURE" }
    elseif ($currentJobStatus -eq "WARNINGS" -and $overallSetStatus -ne "FAILURE") { $overallSetStatus = "WARNINGS" }

    $displayStatusForLog = $currentJobReportData.OverallStatus
    & $LoggerScriptBlock -Message "Finished processing job '$currentJobName'. Status: $displayStatusForLog" -Level $displayStatusForLog

    $_jobSpecificReportTypesSetting = if ($jobConfig.ContainsKey('ReportGeneratorType')) { $jobConfig.ReportGeneratorType } elseif ($Configuration.ContainsKey('ReportGeneratorType')) { $Configuration.ReportGeneratorType } else { "HTML" }
    $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]::new()
    if ($_jobSpecificReportTypesSetting -is [array]) {
        $_jobSpecificReportTypesSetting | ForEach-Object { $_jobReportGeneratorTypesList.Add($_.ToString().ToUpperInvariant()) }
    } else {
        $_jobReportGeneratorTypesList.Add($_jobSpecificReportTypesSetting.ToString().ToUpperInvariant())
    }

    if ($cliOverrideSettings.GenerateHtmlReport) {
        if ("HTML" -notin $_jobReportGeneratorTypesList) {
            $_jobReportGeneratorTypesList.Add("HTML")
        }
        if ($_jobReportGeneratorTypesList.Contains("NONE") -and $_jobReportGeneratorTypesList.Count -gt 1) {
            $_jobReportGeneratorTypesList.Remove("NONE")
        } elseif ($_jobReportGeneratorTypesList.Count -eq 1 -and $_jobReportGeneratorTypesList[0] -eq "NONE") {
            $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]@("HTML")
        }
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

    if ($currentSetName -and $currentJobStatus -eq "FAILURE" -and $stopSetOnError) {
        & $LoggerScriptBlock -Message "[ERROR] Job '$currentJobName' in set '$currentSetName' failed (operational status). Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
        break
    }
}
#endregion

#region --- Final Script Summary & Exit ---
$finalScriptEndTime = Get-Date
& $LoggerScriptBlock -Message "`n================================================================================" -Level "NONE"
& $LoggerScriptBlock -Message "All PoSh Backup Operations Completed" -Level "HEADING"
& $LoggerScriptBlock -Message "================================================================================" -Level "NONE"

if ($IsSimulateMode -and $overallSetStatus -ne "FAILURE" -and $overallSetStatus -ne "WARNINGS") {
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

if ($IsSimulateMode -and $effectivePauseBehaviour -ne "always") {
    $shouldPhysicallyPause = $false
}

if ($shouldPhysicallyPause) {
    & $LoggerScriptBlock -Message "`nPress any key to exit..." -Level "WARNING"
    if ($Host.Name -eq "ConsoleHost") {
        try {
            $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
        } catch { Write-Warning "Failed to read key for final pause: $($_.Exception.Message)" }
    } else {
        & $LoggerScriptBlock -Message "  (Pause configured for '$effectivePauseBehaviour' and current status '$overallSetStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
    }
}

if ($overallSetStatus -in @("SUCCESS", "SIMULATED_COMPLETE")) { exit 0 }
elseif ($overallSetStatus -eq "WARNINGS") { exit 1 }
else { exit 2 }
#endregion
