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
    PowerShell modules for utility functions, backup operations, password management, and reporting.

    Key Features:
    - Modular Design: Facilitates maintainability and clarity by separating concerns into modules
      (e.g., Utils.psm1, Operations.psm1, Reporting.psm1, PasswordManager.psm1, and specific
      report format modules like ReportingHtml.psm1).
    - External Configuration: All backup jobs, global settings (e.g., 7-Zip path, default VSS state),
      and backup sets are defined in an external '.psd1' configuration file. The script loads
      'Config\Default.psd1' and merges 'Config\User.psd1' (if present) for user-specific overrides.
    - Early 7-Zip Path Validation: Checks for a valid 7-Zip executable path immediately after
      configuration loading and will exit if it cannot be found or auto-detected.
    - Backup Jobs: Define specific source paths, destination directories, archive base names,
      retention policies, 7-Zip parameters (compression level, archive type, exclusions, etc.),
      VSS usage, password protection, reporting options, and other operational settings on a per-job basis.
    - Backup Sets: Group multiple backup jobs to run sequentially using the -RunSet parameter.
      Sets can define an error handling policy (stop on error or continue processing the set).
    - Volume Shadow Copy Service (VSS): Optionally allows backing up files that are open or locked by other
      processes. This feature requires Administrator privileges. VSS context options and polling
      behaviour are configurable.
    - 7-Zip Integration: Leverages the 7-Zip command-line tool for efficient compression and archiving.
      Supports a wide range of 7-Zip parameters, which can be configured globally or per job.
    - Secure Password Handling: If password protection is enabled for a job, the script supports
      multiple methods for securely obtaining the password (interactive prompt, PowerShell
      SecretManagement, encrypted file, or plain text from config [discouraged]). The password is
      passed to 7-Zip securely using a temporary file (-spf switch), avoiding command-line exposure.
      The temporary file is deleted immediately after use.
    - Configurable Archive Naming: Archive filenames include a job-defined base name and a date stamp.
      The date format for this stamp is configurable globally and per job (e.g., "yyyy-MMM-dd", "yyyyMMdd_HHmmss").
      The archive file extension (e.g., .7z, .zip) is also configurable per job, typically matching the chosen 7-Zip archive type.
    - Retry Mechanism: For transient failures during 7-Zip operations (compression or archive testing),
      the script can automatically retry the operation a configurable number of times with a configurable delay.
    - 7-Zip Process Priority: Control the CPU priority of the 7-Zip process (e.g., Idle, BelowNormal,
      Normal, High) to manage system resource impact during backup operations.
    - Script Hooks: Execute custom PowerShell scripts at various stages of a backup job (pre-backup,
      post-backup on success, post-backup on failure, and post-backup always) for extended customisation.
    - Detailed Multi-Format Reports: Generates reports for each processed backup job. HTML reports
      are highly customisable with theming, client-side log filtering/searching, and simulation mode banners.
      Other supported formats include CSV, JSON, XML (CliXml), Plain Text (TXT), and Markdown (MD).
      Report types and output directories are configurable.
    - Extensive Logging: Provides detailed console output with colour-coding for different message levels
      (Info, Warning, Error, Debug, etc.). Optionally logs to per-job text files in a specified directory.
    - Simulation Mode (-Simulate): Allows running the entire backup logic, including VSS creation (if enabled)
      and 7-Zip command generation, without actually creating archives, deleting files, or making other
      file system changes. Ideal for testing configurations and script logic.
    - Configuration Test Mode (-TestConfig): Loads and validates the specified (or default) configuration
      file(s), performs schema checks (if enabled), verifies 7-Zip path, summarises key settings,
      lists defined jobs and sets, and then exits. Useful for pre-flight checks.
    - List Configured Items: Use -ListBackupLocations or -ListBackupSets to quickly display defined
      jobs or sets from the configuration and then exit.
    - Free Space Check: Optionally checks the destination drive for a minimum amount of free space
      before starting a backup job, with options to warn or abort on low space.
    - Archive Integrity Test: Optionally tests newly created archives using 7-Zip's test function
      to verify their integrity.
    - Configurable Exit Pause: The script can pause before exiting based on configuration settings
      (Always, Never, OnFailure, OnWarning, OnFailureOrWarning) or a command-line override,
      allowing time to review console output.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location (job) to process. This name must
    correspond to an entry defined in the 'BackupLocations' section of your configuration file.
    If neither -BackupLocationName nor -RunSet is provided, the script will attempt to run a job
    only if a single backup location is defined in the configuration; otherwise, it will prompt for a choice or exit.

.PARAMETER RunSet
    Optional. The name of a Backup Set to process. Backup Sets are defined in the 'BackupSets'
    section of your configuration file and group multiple backup jobs to be run sequentially.
    If both -RunSet and -BackupLocationName are provided, -RunSet takes precedence.

.PARAMETER ConfigFile
    Optional. Specifies the full path to a PoSh-Backup '.psd1' configuration file.
    If not provided, the script defaults to loading '.\Config\Default.psd1' (relative to its own location)
    and will also attempt to load and merge '.\Config\User.psd1' if it exists.
    Using 'User.psd1' for your customisations is highly recommended.

.PARAMETER Simulate
    Optional. A switch parameter. If present, the script runs in simulation mode.
    It will perform all checks, VSS initialisation (if configured), password retrieval (simulated),
    7-Zip command generation, and log what it *would* do (like creating VSS snapshots, running 7-Zip,
    deleting old files), but will *not* make any actual changes to the file system, create/delete archives,
    or execute 7-Zip for compression/testing. Ideal for verifying configuration and script logic.
    This switch also typically suppresses the end-of-script pause unless overridden by
    -PauseBehaviourCLI "Always" or an equivalent configuration setting.

.PARAMETER TestArchive
    Optional. A switch parameter. If present, this forces an integrity test ('7z t') of newly created
    archives for all processed jobs, overriding the 'TestArchiveAfterCreation' setting from the
    configuration file(s) for the current run.

.PARAMETER UseVSS
    Optional. A switch parameter. If present, this forces the script to attempt using Volume Shadow Copy
    Service (VSS) for all processed jobs, overriding the 'EnableVSS' setting from the configuration
    file(s) for the current run. Requires Administrator privileges to function.

.PARAMETER EnableRetriesCLI
    Optional. A switch parameter. If present, this forces the enabling of the 7-Zip retry mechanism
    (for compression and testing operations) for all processed jobs. This overrides the 'EnableRetries'
    setting from the configuration file(s) for the current run.

.PARAMETER GenerateHtmlReportCLI
    Optional. A switch parameter. If present, this forces the generation of an HTML report for all
    processed jobs. If a job's 'ReportGeneratorType' in the configuration was set to "None" or
    another specific type, this override will ensure an HTML report is generated (or added to the list
    if 'ReportGeneratorType' is an array).

.PARAMETER SevenZipPriorityCLI
    Optional. Allows specifying the 7-Zip process priority directly from the command line, overriding
    the 'DefaultSevenZipProcessPriority' (global) or 'SevenZipProcessPriority' (job-specific)
    settings from the configuration file(s).
    Valid values: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".

.PARAMETER TestConfig
    Optional. A switch parameter. If present, the script will:
    1. Load and merge the specified (or default) configuration file(s).
    2. Perform a comprehensive validation of the entire configuration, including schema checks (if 'EnableAdvancedSchemaValidation' is true in the config).
    3. Check for a valid 7-Zip executable path.
    4. Print a summary of key loaded settings, defined backup locations (jobs), and defined backup sets.
    5. Exit without performing any backup operations.
    This is extremely useful for checking configuration syntax and integrity before deployment or execution.

.PARAMETER ListBackupLocations
    Optional. A switch parameter. If present, the script loads the configuration, lists all defined
    Backup Locations (jobs) along with their source paths, and then exits.
    Takes precedence over normal backup operations, -RunSet, and -BackupLocationName.

.PARAMETER ListBackupSets
    Optional. A switch parameter. If present, the script loads the configuration, lists all defined
    Backup Sets and the job names they contain, and then exits.
    Takes precedence over normal backup operations, -RunSet, and -BackupLocationName.

.PARAMETER PauseBehaviourCLI
    Optional. Controls the script's pause behaviour (displaying "Press any key to continue...") before exiting.
    This command-line parameter overrides the 'PauseBeforeExit' setting from the configuration file(s).
    Valid values (case-insensitive):
    - "True" or "Always": Always pause.
    - "False" or "Never": Never pause.
    - "OnFailure": Pause only if the overall script status is FAILURE.
    - "OnWarning": Pause only if the overall script status is WARNINGS.
    - "OnFailureOrWarning": Pause if the status is FAILURE OR WARNINGS.

.EXAMPLE
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups"
    Runs all backup jobs defined in the "DailyCriticalBackups" backup set, using settings from the
    default configuration files ('Config\Default.psd1' and 'Config\User.psd1').

.EXAMPLE
    .\PoSh-Backup.ps1 -BackupLocationName "WebAppLogs" -UseVSS -Simulate -PauseBehaviourCLI OnFailure
    Simulates backing up the "WebAppLogs" job, forcing VSS usage for this run. The script will
    only pause before exiting if the simulation indicates a failure would have occurred.

.EXAMPLE
    .\PoSh-Backup.ps1 -TestConfig -ConfigFile "C:\PoShBackup\CustomConfig.psd1"
    Loads and validates the configuration from "C:\PoShBackup\CustomConfig.psd1", prints a
    summary of its contents, and then exits. No backups are performed.

.EXAMPLE
    .\PoSh-Backup.ps1 -ListBackupLocations
    Lists all backup jobs defined in the loaded configuration and then exits.

.EXAMPLE
    .\PoSh-Backup.ps1 -ListBackupSets
    Lists all backup sets defined in the loaded configuration and then exits.

.EXAMPLE
    .\PoSh-Backup.ps1 "MyImportantDocs" -GenerateHtmlReportCLI -SevenZipPriorityCLI "Idle"
    Runs the "MyImportantDocs" backup job, ensuring an HTML report is generated for this run,
    and sets the 7-Zip process priority to Idle, overriding any configured priority.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.9.4
    Date:           16-May-2025
    Requires:       PowerShell 5.1 or higher.
                    7-Zip (7z.exe) must be installed and its path correctly specified in the
                    configuration file or auto-detectable by the script.
    Privileges:     Administrator privileges are required for VSS functionality.
    Modules:        This script relies on several PowerShell modules located in the '.\Modules'
                    subdirectory: Utils.psm1, Operations.psm1, Reporting.psm1 (orchestrator),
                    PasswordManager.psm1, and format-specific reporting modules in '.\Modules\Reporting\'
                    (e.g., ReportingHtml.psm1, ReportingCsv.psm1, etc.).
                    Optionally, 'PoShBackupValidator.psm1' can be used for advanced configuration validation.
    Themes:         HTML report themes (CSS files) are located in '.\Config\Themes\'.
    Configuration:  Primary configuration is managed via '.\Config\Default.psd1' (master settings
                    and comments) and '.\Config\User.ps1' (for user-specific overrides).
    Script Name:    PoSh-Backup.ps1

    For detailed setup and advanced configuration options, refer to the README.md file and the
    extensive comments within 'Config\Default.psd1'.
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

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Operations.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting.psm1") -Force -ErrorAction Stop
    Write-Host "[INFO] Core modules Utils.psm1, Operations.psm1, and Reporting.psm1 (orchestrator) loaded." -ForegroundColour $Global:ColourInfo

} catch {
    Write-Host "[FATAL] Failed to import required script modules." -ForegroundColour $Global:ColourError
    Write-Host "Ensure core modules are in '.\Modules\' relative to PoSh-Backup.ps1." -ForegroundColour $Global:ColourError
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColour $Global:ColourError
    exit 10
}

Write-LogMessage "---------------------------------" -Level "NONE"
Write-LogMessage " Starting PoSh Backup Script     " -Level "HEADING"
# Version in this log message is static and reflects the PoSh-Backup.ps1 script version, not the bundler's.
Write-LogMessage " Script Version: v1.9.4 (PSSA: Fixed empty catch blocks, removed trailing whitespace)" -Level "HEADING"
if ($IsSimulateMode) { Write-LogMessage " ***** SIMULATION MODE ACTIVE ***** " -Level "SIMULATE" }
if ($TestConfig.IsPresent) { Write-LogMessage " ***** CONFIGURATION TEST MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupLocations.IsPresent) { Write-LogMessage " ***** LIST BACKUP LOCATIONS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
if ($ListBackupSets.IsPresent) { Write-LogMessage " ***** LIST BACKUP SETS MODE ACTIVE ***** " -Level "CONFIG_TEST" }
Write-LogMessage "---------------------------------" -Level "NONE"
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
            Write-LogMessage "[INFO] User configuration file ('$defaultUserConfigPath') not found." -Level "INFO"
            if ($Host.Name -eq "ConsoleHost" -and -not $TestConfig.IsPresent -and -not $IsSimulateMode `
                -and -not $ListBackupLocations.IsPresent -and -not $ListBackupSets.IsPresent) {
                $choiceTitle = "Create User Configuration?"
                $choiceMessage = "The user-specific configuration file '$($defaultUserConfigFileName)' was not found in '$($defaultConfigDir)'.`nIt is recommended to create this file as it allows you to customise settings without modifying`nthe default file, ensuring your settings are not overwritten by script upgrades.`n`nWould you like to create '$($defaultUserConfigFileName)' now by copying the contents of '$($defaultBaseConfigFileName)'?"
                $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Create '$($defaultUserConfigFileName)' from '$($defaultBaseConfigFileName)'."
                $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Do not create the file. The script will use '$($defaultBaseConfigFileName)' only for this run."
                $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
                $decision = $Host.UI.PromptForChoice($choiceTitle, $choiceMessage, $options, 0)
                if ($decision -eq 0) {
                    try {
                        Copy-Item -LiteralPath $defaultBaseConfigPath -Destination $defaultUserConfigPath -Force -ErrorAction Stop
                        Write-LogMessage "[SUCCESS] '$defaultUserConfigFileName' has been created from '$defaultBaseConfigFileName' in '$defaultConfigDir'." -Level "SUCCESS"
                        Write-LogMessage "          Please edit '$defaultUserConfigFileName' with your desired settings and then re-run PoSh-Backup." -Level "INFO"
                        Write-LogMessage "          Script will now exit." -Level "INFO"
                        $_pauseSettingForUserPsd1Create = Get-ConfigValue -ConfigObject $cliOverrideSettings -Key 'PauseBehaviour' -DefaultValue "Always"
                        if ($_pauseSettingForUserPsd1Create -is [string] -and $_pauseSettingForUserPsd1Create.ToLowerInvariant() -ne "never" -and ($_pauseSettingForUserPsd1Create -isnot [bool] -or $_pauseSettingForUserPsd1Create -ne $false)) {
                           if ($Host.Name -eq "ConsoleHost") { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
                        }
                        exit 0
                    } catch {
                        Write-LogMessage "[ERROR] Failed to copy '$defaultBaseConfigPath' to '$defaultUserConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                        Write-LogMessage "          Please create '$defaultUserConfigFileName' manually if desired. Script will continue with base configuration." -Level "WARNING"
                    }
                } else {
                    Write-LogMessage "[INFO] User chose not to create '$defaultUserConfigFileName'. '$defaultBaseConfigFileName' will be used for this run." -Level "INFO"
                }
            } else {
                 Write-LogMessage "[INFO] Not prompting to create '$defaultUserConfigFileName' (Non-interactive, TestConfig, Simulate, or List mode)." -Level "INFO"
                 Write-LogMessage "       If you wish to have user-specific overrides, please manually copy '$defaultBaseConfigPath' to '$defaultUserConfigPath' and edit it." -Level "INFO"
            }
        } else {
            Write-LogMessage "[WARNING] Base configuration file ('$defaultBaseConfigPath') also not found. Cannot offer to create '$defaultUserConfigPath'." -Level "WARNING"
        }
    }
}

$configResult = Import-AppConfiguration -UserSpecifiedPath $ConfigFile -IsTestConfigMode:(($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent)) -MainScriptPSScriptRoot $PSScriptRoot
if (-not $configResult.IsValid) {
    Write-LogMessage "FATAL: Configuration loading or validation failed. Exiting." -Level "ERROR"
    exit 1
}
$Configuration = $configResult.Configuration
$ActualConfigFile = $configResult.ActualPath

if ($configResult.PSObject.Properties.Name -contains 'UserConfigLoaded') {
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "[INFO] User override configuration from '$($configResult.UserConfigPath)' was successfully loaded and merged." -Level "INFO"
    } elseif (($null -ne $configResult.UserConfigPath) -and (-not $configResult.UserConfigLoaded) -and (Test-Path -LiteralPath $configResult.UserConfigPath -PathType Leaf)) {
        Write-LogMessage "[WARNING] User override configuration '$($configResult.UserConfigPath)' was found but an issue occurred during its loading/merging (check previous messages). Effective configuration may not include user overrides." -Level "WARNING"
    }
}

if ($null -ne $Configuration -and $Configuration -is [hashtable]) {
    $Configuration['_PoShBackup_PSScriptRoot'] = $PSScriptRoot
} else {
    Write-LogMessage "FATAL: Configuration object is not a valid hashtable after loading. Cannot inject PSScriptRoot." -Level "ERROR"
    exit 1
}

if (-not ($ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent -or $TestConfig.IsPresent)) {
    $sevenZipPathFromFinalConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'SevenZipPath' -DefaultValue $null
    if ([string]::IsNullOrWhiteSpace($sevenZipPathFromFinalConfig) -or -not (Test-Path -LiteralPath $sevenZipPathFromFinalConfig -PathType Leaf)) {
        Write-LogMessage "FATAL: 7-Zip executable path ('$sevenZipPathFromFinalConfig') is invalid or not found after configuration loading and auto-detection attempts." -Level "ERROR"
        Write-LogMessage "       Please ensure 'SevenZipPath' is correctly set in your configuration (Default.psd1 or User.psd1)," -Level "ERROR"
        Write-LogMessage "       or that 7z.exe is available in standard Program Files locations or your system PATH for auto-detection." -Level "ERROR"

        $_earlyExitPauseSetting = Get-ConfigValue -ConfigObject $Configuration -Key 'PauseBeforeExit' -DefaultValue "Always"
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
            Write-LogMessage "`nPress any key to exit..." -Level "WARNING"
            try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
            catch { Write-Warning "Failed to read key for pause: $($_.Exception.Message)" }
        }
        exit 3
    } else {
        Write-LogMessage "[INFO] Effective 7-Zip executable path confirmed: '$sevenZipPathFromFinalConfig'" -Level "INFO"
    }
}

if (-not ($ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent)) {
    $Global:GlobalEnableFileLogging = Get-ConfigValue -ConfigObject $Configuration -Key 'EnableFileLogging' -DefaultValue $false
    if ($Global:GlobalEnableFileLogging) {
        $logDirConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'LogDirectory' -DefaultValue "Logs"
        $Global:GlobalLogDirectory = if ([System.IO.Path]::IsPathRooted($logDirConfig)) { $logDirConfig } else { Join-Path -Path $PSScriptRoot -ChildPath $logDirConfig }

        if (-not (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
            try {
                New-Item -Path $Global:GlobalLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-LogMessage "[INFO] Log directory '$Global:GlobalLogDirectory' created." -Level "INFO"
            } catch {
                Write-LogMessage "[WARNING] Failed to create log directory '$Global:GlobalLogDirectory'. File logging may be impacted. Error: $($_.Exception.Message)" -Level "WARNING"
                $Global:GlobalEnableFileLogging = $false
            }
        }
    }
}

if ($ListBackupLocations.IsPresent) {
    Write-LogMessage "`n--- Defined Backup Locations (Jobs) from '$($ActualConfigFile)' ---" -Level "HEADING"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "    (Includes overrides from '$($configResult.UserConfigPath)')" -Level "INFO"
    }
    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-LogMessage ("`n  Job Name      : " + $_.Name) -Level "NONE"
            $sourcePaths = if ($_.Value.Path -is [array]) { ($_.Value.Path | ForEach-Object { "                  `"$_`"" }) -join [Environment]::NewLine } else { "                  `"$($_.Value.Path)`"" }
            Write-LogMessage ("  Source Path(s):`n" + $sourcePaths) -Level "NONE"
            Write-LogMessage ("  Archive Name  : " + (Get-ConfigValue $_.Value 'Name' 'N/A')) -Level "NONE"
            Write-LogMessage ("  Destination   : " + (Get-ConfigValue $_.Value 'DestinationDir' (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A'))) -Level "NONE"
        }
    } else {
        Write-LogMessage "No Backup Locations are defined in the configuration." -Level "WARNING"
    }
    Write-LogMessage "`n--- Listing Complete ---" -Level "HEADING"
    exit 0
}

if ($ListBackupSets.IsPresent) {
    Write-LogMessage "`n--- Defined Backup Sets from '$($ActualConfigFile)' ---" -Level "HEADING"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "    (Includes overrides from '$($configResult.UserConfigPath)')" -Level "INFO"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-LogMessage ("`n  Set Name     : " + $_.Name) -Level "NONE"
            $jobsInSet = if ($_.Value.JobNames -is [array]) { ($_.Value.JobNames | ForEach-Object { "                 $_" }) -join [Environment]::NewLine } else { "                 None listed" }
            Write-LogMessage ("  Jobs in Set  :`n" + $jobsInSet) -Level "NONE"
            Write-LogMessage ("  On Error     : " + (Get-ConfigValue $_.Value 'OnErrorInJob' 'StopSet')) -Level "NONE"
        }
    } else {
        Write-LogMessage "No Backup Sets are defined in the configuration." -Level "WARNING"
    }
    Write-LogMessage "`n--- Listing Complete ---" -Level "HEADING"
    exit 0
}

if ($TestConfig.IsPresent) {
    Write-LogMessage "`n[INFO] --- Configuration Test Mode Summary ---" -Level "CONFIG_TEST"
    Write-LogMessage "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -Level "CONFIG_TEST"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "          (User overrides from '$($configResult.UserConfigPath)' were applied)" -Level "CONFIG_TEST"
    }
    Write-LogMessage "`n  --- Key Global Settings ---" -Level "CONFIG_TEST"
    Write-LogMessage ("    7-Zip Path              : {0}" -f (Get-ConfigValue $Configuration 'SevenZipPath' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default Destination Dir : {0}" -f (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Log Directory           : {0}" -f (Get-ConfigValue $Configuration 'LogDirectory' 'N/A (File Logging Disabled)')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default Report Dir (HTML): {0}" -f (Get-ConfigValue $Configuration 'HtmlReportDirectory' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default VSS Enabled     : {0}" -f (Get-ConfigValue $Configuration 'EnableVSS' $false)) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default Retries Enabled : {0}" -f (Get-ConfigValue $Configuration 'EnableRetries' $false)) -Level "CONFIG_TEST"
    Write-LogMessage ("    Pause Before Exit       : {0}" -f (Get-ConfigValue $Configuration 'PauseBeforeExit' 'OnFailureOrWarning')) -Level "CONFIG_TEST"
    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        Write-LogMessage "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
        foreach ($jobName in ($Configuration.BackupLocations.Keys | Sort-Object)) {
            $jobConf = $Configuration.BackupLocations[$jobName]
            Write-LogMessage ("    Job: {0}" -f $jobName) -Level "CONFIG_TEST" 
            $sourcePaths = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }
            Write-LogMessage ("      Source(s)    : {0}" -f $sourcePaths) -Level "CONFIG_TEST"
            Write-LogMessage ("      Destination  : {0}" -f (Get-ConfigValue $jobConf 'DestinationDir' (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A'))) -Level "CONFIG_TEST"
            Write-LogMessage ("      Archive Name : {0}" -f (Get-ConfigValue $jobConf 'Name' 'N/A')) -Level "CONFIG_TEST"
            Write-LogMessage ("      VSS Enabled  : {0}" -f (Get-ConfigValue $jobConf 'EnableVSS' (Get-ConfigValue $Configuration 'EnableVSS' $false))) -Level "CONFIG_TEST"
            Write-LogMessage ("      Retention    : {0}" -f (Get-ConfigValue $jobConf 'RetentionCount' 'N/A')) -Level "CONFIG_TEST"
        }
    } else {
        Write-LogMessage "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
        Write-LogMessage "    No Backup Locations defined in the configuration." -Level "CONFIG_TEST"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        Write-LogMessage "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
        foreach ($setName in ($Configuration.BackupSets.Keys | Sort-Object)) {
            $setConf = $Configuration.BackupSets[$setName]
            Write-LogMessage ("    Set: {0}" -f $setName) -Level "CONFIG_TEST" 
            $jobsInSet = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }
            Write-LogMessage ("      Jobs in Set  : {0}" -f $jobsInSet) -Level "CONFIG_TEST"
            Write-LogMessage ("      On Error     : {0}" -f (Get-ConfigValue $setConf 'OnErrorInJob' 'StopSet')) -Level "CONFIG_TEST"
        }
    } else {
        Write-LogMessage "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
        Write-LogMessage "    No Backup Sets defined in the configuration." -Level "CONFIG_TEST"
    }
    Write-LogMessage "`n[INFO] --- Configuration Test Mode Finished ---" -Level "CONFIG_TEST"
    exit 0
}

$jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet
if (-not $jobResolutionResult.Success) {
    Write-LogMessage "FATAL: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR"
    exit 1
}
$jobsToProcess = $jobResolutionResult.JobsToRun
$currentSetName = $jobResolutionResult.SetName
$stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy
#endregion

#region --- Main Processing Loop (Iterate through Jobs) ---
$overallSetStatus = "SUCCESS"

foreach ($currentJobName in $jobsToProcess) {
    Write-LogMessage "`n================================================================================" -Level "NONE"
    Write-LogMessage "Processing Job: $currentJobName" -Level "HEADING"
    Write-LogMessage "================================================================================" -Level "NONE"

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
             Write-LogMessage "[INFO] Logging for job '$currentJobName' to file: $($Global:GlobalLogFile)" -Level "INFO"
        } else {
            Write-LogMessage "[WARNING] Log directory is not valid. File logging for job '$currentJobName' will be skipped." -Level "WARNING"
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
        }
        $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams
        $currentJobStatus = $jobResult.Status
    } catch {
        $currentJobStatus = "FAILURE"
        Write-LogMessage "[FATAL] Top-level unhandled exception during Invoke-PoShBackupJob for job '$currentJobName': $($_.Exception.ToString())" -Level "ERROR"
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
    Write-LogMessage "Finished processing job '$currentJobName'. Status: $displayStatusForLog" -Level $displayStatusForLog

    $_jobSpecificReportTypesSetting = Get-ConfigValue -ConfigObject $jobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'ReportGeneratorType' -DefaultValue "HTML")
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
            Write-LogMessage "[INFO] Default reports directory '$defaultJobReportsDir' does not exist. Attempting to create..." -Level "INFO"
            try {
                New-Item -Path $defaultJobReportsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-LogMessage "  - Default reports directory '$defaultJobReportsDir' created successfully." -Level "SUCCESS"
            } catch {
                Write-LogMessage "[WARNING] Failed to create default reports directory '$defaultJobReportsDir'. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING"
            }
        }

        Invoke-ReportGenerator -ReportDirectory $defaultJobReportsDir `
                               -JobName $currentJobName `
                               -ReportData $currentJobReportData `
                               -GlobalConfig $Configuration `
                               -JobConfig $jobConfig
    }

    if ($currentSetName -and $currentJobStatus -eq "FAILURE" -and $stopSetOnError) {
        Write-LogMessage "[ERROR] Job '$currentJobName' in set '$currentSetName' failed (operational status). Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
        break
    }
}
#endregion

#region --- Final Script Summary & Exit ---
$finalScriptEndTime = Get-Date
Write-LogMessage "`n================================================================================" -Level "NONE"
Write-LogMessage "All PoSh Backup Operations Completed" -Level "HEADING"
Write-LogMessage "================================================================================" -Level "NONE"

if ($IsSimulateMode -and $overallSetStatus -ne "FAILURE" -and $overallSetStatus -ne "WARNINGS") {
    $overallSetStatus = "SIMULATED_COMPLETE"
}

Write-LogMessage "Overall Script Status: $overallSetStatus" -Level $overallSetStatus
Write-LogMessage "Script started : $ScriptStartTime" -Level "INFO"
Write-LogMessage "Script ended   : $finalScriptEndTime" -Level "INFO"
Write-LogMessage "Total duration : $($finalScriptEndTime - $ScriptStartTime)" -Level "INFO"

$_pauseDefaultFromScript = "OnFailureOrWarning"
$_pauseSettingFromConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'PauseBeforeExit' -DefaultValue $_pauseDefaultFromScript

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
    Write-LogMessage "[INFO] Pause behaviour explicitly set by CLI to: '$($cliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level "INFO"
}

$shouldPhysicallyPause = $false
switch ($effectivePauseBehaviour) {
    "always"             { $shouldPhysicallyPause = $true }
    "never"              { $shouldPhysicallyPause = $false }
    "onfailure"          { if ($overallSetStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
    "onwarning"          { if ($overallSetStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
    "onfailureorwarning" { if ($overallSetStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
    default {
        Write-LogMessage "[WARNING] Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing (simulating 'Never' behaviour)." -Level "WARNING"
        $shouldPhysicallyPause = $false
    }
}

if ($IsSimulateMode -and $effectivePauseBehaviour -ne "always") {
    $shouldPhysicallyPause = $false
}

if ($shouldPhysicallyPause) {
    Write-LogMessage "`nPress any key to exit..." -Level "WARNING"
    if ($Host.Name -eq "ConsoleHost") {
        try {
            $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
        } catch { Write-Warning "Failed to read key for final pause: $($_.Exception.Message)" }
    } else {
        Write-LogMessage "  (Pause configured for '$effectivePauseBehaviour' and current status '$overallSetStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
    }
}

if ($overallSetStatus -in @("SUCCESS", "SIMULATED_COMPLETE")) { exit 0 }
elseif ($overallSetStatus -eq "WARNINGS") { exit 1 }
else { exit 2 }
#endregion
