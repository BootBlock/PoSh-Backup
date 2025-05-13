<#
.SYNOPSIS
    A highly comprehensive PowerShell script for directory backups using 7-Zip, featuring VSS,
    retries, script hooks, HTML reports, backup sets, process priority, and extensive
    configuration via an external .psd1 file and modules. Script name: PoSh-Backup.

.DESCRIPTION
    This PoSh Backup ("PowerShell Backup") script provides an enterprise-grade backup solution, organised using
    PowerShell modules for maintainability and clarity. It is designed to be robust, configurable, and provide
    detailed feedback on backup operations.

    Key Features:
    - Modular Design: Core logic is split into the main script and dedicated modules for Utility functions,
      Backup Operations, and Reporting.
    - External Configuration: All backup jobs, global settings, and backup sets are defined in an
      external .psd1 configuration file (default: Config\Default.psd1). User-specific overrides can
      be placed in Config\User.psd1. If User.psd1 is not found, the script may offer to create it.
    - Backup Jobs: Define specific sources, destination, archive names, retention policies, 7-Zip parameters,
      and other operational settings on a per-job basis.
    - Backup Sets: Group multiple backup jobs to run sequentially with the -RunSet parameter. Sets can define
      an error handling policy (stop on error or continue).
    - Volume Shadow Copy Service (VSS): Allows backing up files that are open or locked by other
      processes (requires Administrator privileges). VSS context is configurable, and shadow copy
      creation uses a reliable polling mechanism. The VSS metadata cache path is also configurable.
    - 7-Zip Integration: Leverages 7-Zip for efficient compression. Supports various 7-Zip parameters
      including archive type, compression level, method, dictionary/word/solid block sizes, thread count,
      and exclusions.
    - Secure Password Handling: If password protection is enabled for a job, the script prompts for
      credentials and passes the password to 7-Zip securely using a temporary file (-spf switch),
      avoiding command-line exposure. The temporary file is deleted immediately. This will be improved later.
    - Configurable Archive Naming: Archive filenames include a base name and a date stamp. The date
      format for this stamp is configurable globally and per job (e.g., "yyyy-MMM-dd", "yyyyMMdd_HHmmss").
      The archive file extension (e.g., .7z, .zip) is also configurable per job to match the chosen 7-Zip archive type.
    - Retry Mechanism: For transient failures during 7-Zip operations (compression or testing), the script
      can automatically retry the operation a configurable number of times with a configurable delay.
    - 7-Zip Process Priority: Control the CPU priority of the 7-Zip process (e.g., Idle, BelowNormal,
      Normal, High) to manage system resource impact during backups.
    - Script Hooks: Execute custom PowerShell scripts at various stages of a backup job.
    - Detailed HTML Reports: Generates a comprehensive HTML report for each processed backup job.
      Report appearance (title, logo, company name, theme, CSS variable overrides, visible sections) is highly customisable.
      Uses robust HTML encoding for XSS protection. CSS for themes is externalised to Config\Themes relative to this main script.
    - Extensive Logging: Provides detailed console output with colour-coding for different message levels.
      Optionally logs to per-job text files.
    - Simulation Mode (-Simulate): Runs through the backup logic without making actual changes.
    - Configuration Test Mode (-TestConfig): Validates the configuration file, provides a summary of loaded settings, and exits.
    - List Configured Items: Use -ListBackupLocations or -ListBackupSets to display defined jobs/sets and exit.
    - Free Space Check: Optionally checks for minimum required free space.
    - Archive Integrity Test: Optionally tests newly created archives.
    - Configurable Exit Pause: Script can pause before exiting based on settings: Always, Never, OnFailure,
      OnWarning, or OnFailureOrWarning. CLI override available.

.PARAMETER BackupLocationName
    Optional. The friendly name (key) of a single backup location/job defined in the 'BackupLocations'
    section of the configuration file to process. If neither -BackupLocationName nor -RunSet is provided,
    the script will attempt to run the job if only one is defined in the configuration.

.PARAMETER RunSet
    Optional. The name of a Backup Set (defined in the 'BackupSets' section of the configuration file)
    to process. A Backup Set groups multiple backup jobs to be run sequentially.
    This parameter takes precedence over -BackupLocationName if both are provided.

.PARAMETER ConfigFile
    Optional. Specifies the full path to the .psd1 configuration file.
    If not provided, the script defaults to looking for '.\Config\Default.psd1' relative to its own location,
    and will also attempt to load and merge '.\Config\User.psd1' if it exists (or offer to create it).

.PARAMETER Simulate
    Optional. A switch parameter. If present, the script runs in simulation mode. It will perform all
    checks, log what it *would* do (like creating VSS snapshots, running 7-Zip, deleting old files),
    but will not make any actual changes to the file system or create/delete archives.
    Ideal for testing configuration and logic. This switch also suppresses the end-of-script pause 
    unless overridden by -PauseBehaviourCLI "Always" or an equivalent config setting.

.PARAMETER TestArchive
    Optional. A switch parameter. If present, this forces the integrity test of newly created archives
    for all processed jobs, overriding the 'TestArchiveAfterCreation' setting from the configuration file.

.PARAMETER UseVSS
    Optional. A switch parameter. If present, this forces the script to attempt using Volume Shadow Copy
    Service (VSS) for all processed jobs, overriding the 'EnableVSS' setting from the configuration file.
    Requires Administrator privileges.

.PARAMETER EnableRetriesCLI
    Optional. A switch parameter. If present, this forces the enabling of the 7-Zip retry mechanism
    for all processed jobs, overriding the 'EnableRetries' setting from the configuration file.

.PARAMETER GenerateHtmlReportCLI
    Optional. A switch parameter. If present, this forces the generation of an HTML report for all
    processed jobs. If a job's 'ReportGeneratorType' in the configuration was set to "None", this
    override will change it to "HTML" for that run.

.PARAMETER SevenZipPriorityCLI
    Optional. Allows specifying the 7-Zip process priority directly from the command line, overriding
    the configuration. Valid values: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".

.PARAMETER TestConfig
    Optional. A switch parameter. If present, the script will load and perform a comprehensive validation
    of the entire specified configuration file (structure, required keys, valid values for certain settings),
    print any validation errors and a summary of loaded settings, and then exit without performing any backup operations.
    Useful for checking configuration syntax and integrity before deployment.

.PARAMETER ListBackupLocations
    Optional. A switch parameter. If present, the script loads the configuration, lists all defined
    Backup Locations (jobs) and their source paths, and then exits. Takes precedence over normal backup operations.

.PARAMETER ListBackupSets
    Optional. A switch parameter. If present, the script loads the configuration, lists all defined
    Backup Sets and the jobs they contain, and then exits. Takes precedence over normal backup operations.

.PARAMETER PauseBehaviourCLI
    Optional. Controls script pause behaviour before exiting. Overrides the 'PauseBeforeExit' from config.
    Valid values (case-insensitive): "True" (same as "Always"), "False" (same as "Never"),
    "Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning".

.EXAMPLE
    .\PoSh-Backup.ps1 -RunSet "DailyCritical"
    Runs all backup jobs defined in the "DailyCritical" backup set using the default configuration (Default.psd1 + User.psd1 if present).

.EXAMPLE
    .\PoSh-Backup.ps1 "ProjectAlpha" -UseVSS -Simulate -PauseBehaviourCLI OnFailure
    Simulates backing up the "ProjectAlpha" job, forcing VSS usage. Pauses only if simulation indicates failure.

.EXAMPLE
    .\PoSh-Backup.ps1 -TestConfig -ConfigFile "C:\PoShBackup\CustomConfig.psd1"
    Loads and validates "C:\PoShBackup\CustomConfig.psd1", prints a summary, and then exits. (User.psd1 is not loaded/created in this specific case).

.EXAMPLE
    .\PoSh-Backup.ps1 -ListBackupLocations
    Lists all defined backup jobs from the configuration and exits.

.EXAMPLE
    .\PoSh-Backup.ps1 -ListBackupSets -ConfigFile ".\Config\BranchOffice.psd1"
    Lists all defined backup sets from ".\Config\BranchOffice.psd1" and exits.

.NOTES
    Author:         [Joe Cox] with tons of Gemini AI to see how well it does (e.g. blame it for any issues, ahem)
    Version:        1.6 (Added debugging for simulation banner)
    Date:           15-May-2025
    Requires:       PowerShell 5.1 or higher.
                    7-Zip (7z.exe) must be installed and its path correctly specified in the configuration.
    Privileges:     Administrator privileges are required for VSS functionality.
    Modules:        Utils.psm1, Operations.psm1, Reporting.psm1 must be in a '.\Modules\' directory
                    relative to this script, or in a standard PowerShell module path ($env:PSModulePath).
    Themes:         HTML report themes (Base.css, Light.css, Dark.css, etc.) are expected in a
                    '.\Config\Themes\' directory relative to this script.
    Configuration:  See the example Config\Default.psd1 for detailed configuration options.
                    User-specific overrides can be placed in Config\User.psd1.
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

    [Parameter(Mandatory=$false, HelpMessage="Switch. Forces HTML report generation for processed jobs.")]
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

# Define Global Console Colours
$Global:ColourInfo                          = "Cyan"
$Global:ColourSuccess                       = "Green"
$Global:ColourWarning                       = "Yellow"
$Global:ColourError                         = "Red"
$Global:ColourDebug                         = "Gray"
$Global:ColourValue                         = "DarkYellow"
$Global:ColourHeading                       = "White"
$Global:ColourSimulate                      = "Magenta"
$Global:ColourAdmin                         = "Orange"

# Mapping for script status to console colour for summary messages
$Global:StatusToColourMap = @{
    "SUCCESS"           = $Global:ColourSuccess
    "WARNINGS"          = $Global:ColourWarning
    "FAILURE"           = $Global:ColourError
    "SIMULATED_COMPLETE"= $Global:ColourSimulate # Added for overall status
    "DEFAULT"           = $Global:ColourInfo # Fallback for unknown statuses
}

# Global variables for per-job data collection and logging state
$Global:GlobalLogFile                       = $null 
$Global:GlobalEnableFileLogging             = $false 
$Global:GlobalLogDirectory                  = $null 
$Global:GlobalJobLogEntries                 = $null # List of log entry objects for current job's HTML report
$Global:GlobalJobHookScriptData             = $null # List of hook script execution data for current job's HTML report

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Operations.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting.psm1") -Force -ErrorAction Stop 
    Write-Host "[INFO] Modules Utils.psm1, Operations.psm1, and Reporting.psm1 loaded (or reloaded)." -ForegroundColour $Global:ColourInfo
    
} catch {
    Write-Host "[FATAL] Failed to import required script modules." -ForegroundColour $Global:ColourError
    Write-Host "Ensure 'Utils.psm1', 'Operations.psm1', and 'Reporting.psm1' are in the '.\Modules\' directory relative to the main script." -ForegroundColour $Global:ColourError
    Write-Host "Make sure 'Config\Themes' directory with CSS files (Base.css, etc.) exists if HTML reporting is used." -ForegroundColour $Global:ColourError
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColour $Global:ColourError
    exit 10 # Critical error, cannot proceed
}

# Initial log messages (not part of per-job HTML report logs)
Write-LogMessage "---------------------------------" -ForegroundColour $Global:ColourHeading -Level "NONE"
Write-LogMessage " Starting PoSh Backup Script     " -ForegroundColour $Global:ColourHeading -Level "NONE" 
Write-LogMessage " Script Version: v1.6 (Debug Sim Banner)" -ForegroundColour $Global:ColourHeading -Level "NONE" 
if ($IsSimulateMode) { Write-LogMessage " ***** SIMULATION MODE ACTIVE ***** " -ForegroundColour $Global:ColourSimulate -Level "SIMULATE" }
if ($TestConfig.IsPresent) { Write-LogMessage " ***** CONFIGURATION TEST MODE ACTIVE ***** " -ForegroundColour $Global:ColourSimulate -Level "CONFIG_TEST" } 
if ($ListBackupLocations.IsPresent) { Write-LogMessage " ***** LIST BACKUP LOCATIONS MODE ACTIVE ***** " -ForegroundColour $Global:ColourSimulate -Level "CONFIG_TEST" } 
if ($ListBackupSets.IsPresent) { Write-LogMessage " ***** LIST BACKUP SETS MODE ACTIVE ***** " -ForegroundColour $Global:ColourSimulate -Level "CONFIG_TEST" } 
Write-LogMessage "---------------------------------" -ForegroundColour $Global:ColourHeading -Level "NONE"
#endregion

#region --- Configuration Loading, Validation & Job Determination ---

# Define paths for default configuration files (needed for pre-check)
$defaultConfigDir = Join-Path -Path $PSScriptRoot -ChildPath "Config"
$defaultBaseConfigFileName = "Default.psd1"
$defaultUserConfigFileName = "User.psd1"

$defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
$defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

# Check for User.psd1 and offer to create if it's missing AND no -ConfigFile is specified
if (-not $PSBoundParameters.ContainsKey('ConfigFile')) { # Only if using default config loading
    if (-not (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $defaultBaseConfigPath -PathType Leaf) {
            Write-LogMessage "[INFO] User configuration file ('$defaultUserConfigPath') not found." -Level "INFO"
            # Only prompt in interactive console sessions
            if ($Host.Name -eq "ConsoleHost" -and -not $TestConfig.IsPresent -and -not $IsSimulateMode `
                -and -not $ListBackupLocations.IsPresent -and -not $ListBackupSets.IsPresent) { # Also don't prompt if just listing
                $choiceTitle = "Create User Configuration?"
                $choiceMessage = "The user-specific configuration file '$($defaultUserConfigFileName)' was not found in '$($defaultConfigDir)'.`nIt is recommended to create this file as it allows you to customize settings without modifying`nthe default file, ensuring your settings are not overwritten by script upgrades.`n`nWould you like to create '$($defaultUserConfigFileName)' now by copying the contents of '$($defaultBaseConfigFileName)'?"
                $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Create '$($defaultUserConfigFileName)' from '$($defaultBaseConfigFileName)'."
                $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Do not create the file. The script will use '$($defaultBaseConfigFileName)' only for this run."
                $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
                $decision = $Host.UI.PromptForChoice($choiceTitle, $choiceMessage, $options, 0)

                if ($decision -eq 0) { # User selected Yes
                    try {
                        Copy-Item -LiteralPath $defaultBaseConfigPath -Destination $defaultUserConfigPath -Force -ErrorAction Stop
                        Write-LogMessage "[SUCCESS] '$defaultUserConfigFileName' has been created from '$defaultBaseConfigFileName' in '$defaultConfigDir'." -Level "SUCCESS" -ForegroundColour $Global:ColourSuccess
                        Write-LogMessage "          Please edit '$defaultUserConfigFileName' with your desired settings and then re-run PoSh-Backup." -Level "INFO" -ForegroundColour $Global:ColourInfo
                        Write-LogMessage "          Script will now exit." -Level "INFO"
                        # Pause briefly so user can see the message before exit, unless PauseBehaviour is Never
                        $_pauseSettingForUserPsd1Create = Get-ConfigValue -ConfigObject $cliOverrideSettings -Key 'PauseBehaviour' -DefaultValue "Always" # Default to pause
                        if ($_pauseSettingForUserPsd1Create -is [string] -and $_pauseSettingForUserPsd1Create.ToLowerInvariant() -ne "never" -and ($_pauseSettingForUserPsd1Create -isnot [bool] -or $_pauseSettingForUserPsd1Create -ne $false)) {
                           if ($Host.Name -eq "ConsoleHost") { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
                        }
                        exit 0 # Exit after creating the file
                    } catch {
                        Write-LogMessage "[ERROR] Failed to copy '$defaultBaseConfigPath' to '$defaultUserConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
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

# Load application configuration using helper from Utils.psm1
$configResult = Import-AppConfiguration -UserSpecifiedPath $ConfigFile -IsTestConfigMode:(($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent)) -MainScriptPSScriptRoot $PSScriptRoot
if (-not $configResult.IsValid) {
    Write-LogMessage "FATAL: Configuration loading or validation failed. Exiting." -Level "ERROR" -ForegroundColour $Global:ColourError
    exit 1 # Exit code for configuration error
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
    Write-LogMessage "FATAL: Configuration object is not a valid hashtable after loading. Cannot inject PSScriptRoot." -Level "ERROR" -ForegroundColour $Global:ColourError
    exit 1
}

if (-not ($ListBackupLocations.IsPresent -or $ListBackupSets.IsPresent)) {
    $Global:GlobalEnableFileLogging = Get-ConfigValue -ConfigObject $Configuration -Key 'EnableFileLogging' -DefaultValue $false
    if ($Global:GlobalEnableFileLogging) {
        $logDirConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'LogDirectory' -DefaultValue "Logs" 
        $Global:GlobalLogDirectory = if ([System.IO.Path]::IsPathRooted($logDirConfig)) { $logDirConfig } else { Join-Path -Path $PSScriptRoot -ChildPath $logDirConfig }
        
        if (-not (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
            try {
                New-Item -Path $Global:GlobalLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-LogMessage "[INFO] Log directory '$Global:GlobalLogDirectory' created."
            } catch {
                Write-LogMessage "[WARNING] Failed to create log directory '$Global:GlobalLogDirectory'. File logging may be impacted. Error: $($_.Exception.Message)" -Level "WARNING"
                $Global:GlobalEnableFileLogging = $false 
            }
        }
    }
}

if ($ListBackupLocations.IsPresent) {
    Write-LogMessage "`n--- Defined Backup Locations (Jobs) from '$($ActualConfigFile)' ---" -ForegroundColour $Global:ColourHeading -Level "NONE"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "    (Includes overrides from '$($configResult.UserConfigPath)')" -ForegroundColour $Global:ColourInfo -Level "NONE"
    }
    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Host ("`n  Job Name      : " + $_.Name) -ForegroundColor $Global:ColourValue
            $sourcePaths = if ($_.Value.Path -is [array]) { ($_.Value.Path | ForEach-Object { "                  `"$_`"" }) -join [Environment]::NewLine } else { "                  `"$($_.Value.Path)`"" }
            Write-Host ("  Source Path(s):`n" + $sourcePaths)
            Write-Host ("  Archive Name  : " + (Get-ConfigValue $_.Value 'Name' 'N/A'))
            Write-Host ("  Destination   : " + (Get-ConfigValue $_.Value 'DestinationDir' (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A')))
        }
    } else {
        Write-LogMessage "No Backup Locations are defined in the configuration." -ForegroundColour $Global:ColourWarning -Level "NONE"
    }
    Write-LogMessage "`n--- Listing Complete ---" -ForegroundColour $Global:ColourHeading -Level "NONE"
    exit 0
}

if ($ListBackupSets.IsPresent) {
    Write-LogMessage "`n--- Defined Backup Sets from '$($ActualConfigFile)' ---" -ForegroundColour $Global:ColourHeading -Level "NONE"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "    (Includes overrides from '$($configResult.UserConfigPath)')" -ForegroundColour $Global:ColourInfo -Level "NONE"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Host ("`n  Set Name     : " + $_.Name) -ForegroundColor $Global:ColourValue
            $jobsInSet = if ($_.Value.JobNames -is [array]) { ($_.Value.JobNames | ForEach-Object { "                 $_" }) -join [Environment]::NewLine } else { "                 None listed" }
            Write-Host ("  Jobs in Set  :`n" + $jobsInSet)
            Write-Host ("  On Error     : " + (Get-ConfigValue $_.Value 'OnErrorInJob' 'StopSet'))
        }
    } else {
        Write-LogMessage "No Backup Sets are defined in the configuration." -ForegroundColour $Global:ColourWarning -Level "NONE"
    }
    Write-LogMessage "`n--- Listing Complete ---" -ForegroundColour $Global:ColourHeading -Level "NONE"
    exit 0
}

if ($TestConfig.IsPresent) {
    Write-LogMessage "`n[INFO] --- Configuration Test Mode Summary ---" -ForegroundColour $Global:ColourHeading -Level "CONFIG_TEST"
    Write-LogMessage "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -ForegroundColour $Global:ColourSuccess -Level "CONFIG_TEST"
    if ($configResult.UserConfigLoaded) {
        Write-LogMessage "          (User overrides from '$($configResult.UserConfigPath)' were applied)" -ForegroundColour $Global:ColourSuccess -Level "CONFIG_TEST"
    }
    Write-LogMessage "`n  --- Key Global Settings ---" -ForegroundColour $Global:ColourInfo -Level "CONFIG_TEST"
    Write-LogMessage ("    7-Zip Path              : {0}" -f (Get-ConfigValue $Configuration 'SevenZipPath' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default Destination Dir : {0}" -f (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Log Directory           : {0}" -f (Get-ConfigValue $Configuration 'LogDirectory' 'N/A (File Logging Disabled)')) -Level "CONFIG_TEST"
    Write-LogMessage ("    HTML Report Directory   : {0}" -f (Get-ConfigValue $Configuration 'HtmlReportDirectory' 'N/A')) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default VSS Enabled     : {0}" -f (Get-ConfigValue $Configuration 'EnableVSS' $false)) -Level "CONFIG_TEST"
    Write-LogMessage ("    Default Retries Enabled : {0}" -f (Get-ConfigValue $Configuration 'EnableRetries' $false)) -Level "CONFIG_TEST"
    Write-LogMessage ("    Pause Before Exit       : {0}" -f (Get-ConfigValue $Configuration 'PauseBeforeExit' 'OnFailureOrWarning')) -Level "CONFIG_TEST"
    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        Write-LogMessage "`n  --- Defined Backup Locations (Jobs) ---" -ForegroundColour $Global:ColourInfo -Level "CONFIG_TEST"
        foreach ($jobName in ($Configuration.BackupLocations.Keys | Sort-Object)) {
            $jobConf = $Configuration.BackupLocations[$jobName]
            Write-LogMessage ("    Job: {0}" -f $jobName) -ForegroundColour $Global:ColourValue -Level "CONFIG_TEST"
            $sourcePaths = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }
            Write-LogMessage ("      Source(s)    : {0}" -f $sourcePaths) -Level "CONFIG_TEST"
            Write-LogMessage ("      Destination  : {0}" -f (Get-ConfigValue $jobConf 'DestinationDir' (Get-ConfigValue $Configuration 'DefaultDestinationDir' 'N/A'))) -Level "CONFIG_TEST"
            Write-LogMessage ("      Archive Name : {0}" -f (Get-ConfigValue $jobConf 'Name' 'N/A')) -Level "CONFIG_TEST"
            Write-LogMessage ("      VSS Enabled  : {0}" -f (Get-ConfigValue $jobConf 'EnableVSS' (Get-ConfigValue $Configuration 'EnableVSS' $false))) -Level "CONFIG_TEST"
            Write-LogMessage ("      Retention    : {0}" -f (Get-ConfigValue $jobConf 'RetentionCount' 'N/A')) -Level "CONFIG_TEST"
        }
    } else {
        Write-LogMessage "`n  --- Defined Backup Locations (Jobs) ---" -ForegroundColour $Global:ColourInfo -Level "CONFIG_TEST"
        Write-LogMessage "    No Backup Locations defined in the configuration." -Level "CONFIG_TEST"
    }
    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        Write-LogMessage "`n  --- Defined Backup Sets ---" -ForegroundColour $Global:ColourInfo -Level "CONFIG_TEST"
        foreach ($setName in ($Configuration.BackupSets.Keys | Sort-Object)) {
            $setConf = $Configuration.BackupSets[$setName]
            Write-LogMessage ("    Set: {0}" -f $setName) -ForegroundColour $Global:ColourValue -Level "CONFIG_TEST"
            $jobsInSet = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }
            Write-LogMessage ("      Jobs in Set  : {0}" -f $jobsInSet) -Level "CONFIG_TEST"
            Write-LogMessage ("      On Error     : {0}" -f (Get-ConfigValue $setConf 'OnErrorInJob' 'StopSet')) -Level "CONFIG_TEST"
        }
    } else {
        Write-LogMessage "`n  --- Defined Backup Sets ---" -ForegroundColour $Global:ColourInfo -Level "CONFIG_TEST"
        Write-LogMessage "    No Backup Sets defined in the configuration." -Level "CONFIG_TEST"
    }
    Write-LogMessage "`n[INFO] --- Configuration Test Mode Finished ---" -ForegroundColour $Global:ColourHeading -Level "CONFIG_TEST"
    exit 0 
}

$jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet
if (-not $jobResolutionResult.Success) {
    Write-LogMessage "FATAL: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR" -ForegroundColour $Global:ColourError
    exit 1 
}
$jobsToProcess = $jobResolutionResult.JobsToRun
$currentSetName = $jobResolutionResult.SetName          
$stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy 
#endregion

#region --- Main Processing Loop (Iterate through Jobs) ---
$overallSetStatus = "SUCCESS" 

foreach ($currentJobName in $jobsToProcess) {
    Write-LogMessage "`n================================================================================" -ForegroundColour $Global:ColourHeading -Level "NONE"
    Write-LogMessage "Processing Job: $currentJobName" -ForegroundColour $Global:ColourHeading 
    Write-LogMessage "================================================================================" -ForegroundColour $Global:ColourHeading -Level "NONE"

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
             Write-LogMessage "[INFO] Logging for job '$currentJobName' to file: $($Global:GlobalLogFile)" 
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
            IsSimulateMode      = $IsSimulateMode # Pass the script's $IsSimulateMode
        }
        $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams        
        $currentJobStatus = $jobResult.Status
    } catch {
        $currentJobStatus = "FAILURE"
        Write-LogMessage "[FATAL] Top-level unhandled exception during Invoke-PoShBackupJob for job '$currentJobName': $($_.Exception.ToString())" -Level ERROR -ForegroundColour $Global:ColourError
        $currentJobReportData['ErrorMessage'] = $_.Exception.ToString()
    }
    
    $currentJobReportData['LogEntries']  = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
    $currentJobReportData['HookScripts'] = if ($null -ne $Global:GlobalJobHookScriptData) { $Global:GlobalJobHookScriptData } else { [System.Collections.Generic.List[object]]::new() }
    
    $currentJobReportData['OverallStatus'] = $currentJobStatus 
    $currentJobReportData['ScriptEndTime'] = Get-Date        
    
    if (($currentJobReportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and `
        ($null -ne $currentJobReportData.ScriptStartTime) -and `
        ($null -ne $currentJobReportData.ScriptEndTime)) {
        $currentJobReportData['TotalDuration'] = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
    } else { 
        $currentJobReportData['TotalDuration'] = "N/A (Timing data incomplete)"
    }
    if ($currentJobStatus -eq "FAILURE" -and -not ($currentJobReportData.PSObject.Properties.Name -contains 'ErrorMessage')) {
        $currentJobReportData['ErrorMessage'] = "Job failed; specific error caught by main loop or not recorded by Invoke-PoShBackupJob."
    }

    if ($currentJobStatus -eq "FAILURE") { $overallSetStatus = "FAILURE" }
    elseif ($currentJobStatus -eq "WARNINGS" -and $overallSetStatus -ne "FAILURE") { $overallSetStatus = "WARNINGS" }
    elseif ($currentJobStatus -eq "SIMULATED_COMPLETE" -and $overallSetStatus -eq "SUCCESS") { $overallSetStatus = "SIMULATED_COMPLETE" }
    
    $statusColour = $Global:StatusToColourMap[$currentJobStatus] 
    if (-not $statusColour) { $statusColour = $Global:StatusToColourMap["DEFAULT"] } 
    Write-LogMessage "Finished processing job '$currentJobName'. Status: $currentJobStatus" -ForegroundColour $statusColour
    
    $JobReportGeneratorTypeCurrent = Get-ConfigValue -ConfigObject $jobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'ReportGeneratorType' -DefaultValue "HTML")
    if ($cliOverrideSettings.GenerateHtmlReport) { 
        $JobReportGeneratorTypeCurrent = "HTML" 
    }
    
    if ($JobReportGeneratorTypeCurrent -eq "HTML") {
        $JobHtmlReportDirectoryCurrent = Get-ConfigValue -ConfigObject $jobConfig -Key 'HtmlReportDirectory' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'HtmlReportDirectory' -DefaultValue (Join-Path -Path $PSScriptRoot -ChildPath "Reports"))
        
        if (-not (Test-Path -LiteralPath $JobHtmlReportDirectoryCurrent -PathType Container)) {
            Write-LogMessage "[INFO] HTML Report directory '$JobHtmlReportDirectoryCurrent' for job '$currentJobName' does not exist. Attempting to create..." -Level "INFO"
            try {
                New-Item -Path $JobHtmlReportDirectoryCurrent -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-LogMessage "  - HTML Report directory '$JobHtmlReportDirectoryCurrent' created successfully." -ForegroundColour $Global:ColourSuccess
            } catch {
                Write-LogMessage "[WARNING] Failed to create HTML Report directory '$JobHtmlReportDirectoryCurrent'. HTML report for job '$currentJobName' might be skipped. Error: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        
        Invoke-HtmlReport -ReportDirectory $JobHtmlReportDirectoryCurrent `
                          -JobName $currentJobName `
                          -ReportData $currentJobReportData `
                          -GlobalConfig $Configuration `
                          -JobConfig $jobConfig 
    } elseif ($JobReportGeneratorTypeCurrent -ne "None") { 
        Write-LogMessage "[WARNING] ReportGeneratorType '$JobReportGeneratorTypeCurrent' for job '$currentJobName' is not currently supported by this script version. Skipping report generation." -Level "WARNING"
    }

    if ($currentSetName -and $currentJobStatus -eq "FAILURE" -and $stopSetOnError) {
        Write-LogMessage "[ERROR] Job '$currentJobName' in set '$currentSetName' failed. Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR" -ForegroundColour $Global:ColourError
        break 
    }
} 
#endregion

#region --- Final Script Summary & Exit ---
$finalScriptEndTime = Get-Date
Write-LogMessage "`n================================================================================" -ForegroundColour $Global:ColourHeading -Level "NONE"
Write-LogMessage "All PoSh Backup Operations Completed" -ForegroundColour $Global:ColourHeading 
Write-LogMessage "================================================================================" -ForegroundColour $Global:ColourHeading -Level "NONE"

$finalStatusColour = $Global:StatusToColourMap[$overallSetStatus] 
if (-not $finalStatusColour) { $finalStatusColour = $Global:StatusToColourMap["DEFAULT"] } 
Write-LogMessage "Overall Script Status: $overallSetStatus" -ForegroundColour $finalStatusColour
Write-LogMessage "Script started : $ScriptStartTime"
Write-LogMessage "Script ended   : $finalScriptEndTime"
Write-LogMessage "Total duration : $($finalScriptEndTime - $ScriptStartTime)"

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
    Write-LogMessage "[INFO] Pause behaviour explicitly set by CLI to: '$($cliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level INFO
}

$shouldPhysicallyPause = $false
switch ($effectivePauseBehaviour) {
    "always"             { $shouldPhysicallyPause = $true }
    "never"              { $shouldPhysicallyPause = $false }
    "onfailure"          { if ($overallSetStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
    "onwarning"          { if ($overallSetStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
    "onfailureorwarning" { if ($overallSetStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
    default { 
        Write-LogMessage "[WARNING] Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing (simulating 'Never' behaviour)." -Level WARNING
        $shouldPhysicallyPause = $false 
    }
}

# Don't pause if $IsSimulateMode is true, UNLESS pause is explicitly "Always"
if ($IsSimulateMode -and $effectivePauseBehaviour -ne "always") {
    $shouldPhysicallyPause = $false
}


if ($shouldPhysicallyPause) { 
    Write-LogMessage "`nPress any key to exit..." -ForegroundColour $Global:ColourWarning -Level "NONE"
    if ($Host.Name -eq "ConsoleHost") { 
        try { 
            $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null 
        } catch {} 
    } else {
        Write-LogMessage "  (Pause configured for '$effectivePauseBehaviour' and current status '$overallSetStatus', but not running in ConsoleHost: $($Host.Name).)" -Level INFO
    }
}

if ($IsSimulateMode) { exit 0 } 
elseif ($overallSetStatus -eq "SIMULATED_COMPLETE") { exit 0 } # Treat successful simulation as exit 0
elseif ($overallSetStatus -eq "SUCCESS") { exit 0 }
elseif ($overallSetStatus -eq "WARNINGS") { exit 1 } 
else { exit 2 } # FAILURE or any other unhandled status
#endregion
