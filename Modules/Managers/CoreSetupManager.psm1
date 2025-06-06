# Modules\Managers\CoreSetupManager.psm1
<#
.SYNOPSIS
    Manages the core setup phase of PoSh-Backup, including module imports,
    configuration loading, job resolution, and dependency ordering.
.DESCRIPTION
    This module provides a function to handle the main setup tasks after initial
    global variable setup and CLI override processing. It imports necessary PoSh-Backup
    modules, loads and validates the application configuration, handles informational
    script modes (like -TestConfig, -ListBackupLocations), validates essential
    settings like the 7-Zip path, initialises global logging parameters based on
    the configuration, and determines the final list and order of jobs to be processed.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3 # Added -Version switch parameter pass-through.
    DateCreated:    01-Jun-2025
    LastModified:   06-Jun-2025
    Purpose:        To centralise core script setup and configuration/job resolution.
    Prerequisites:  PowerShell 5.1+.
                    Relies on InitialisationManager.psm1 and CliManager.psm1 having been run.
                    Requires various PoSh-Backup core and manager modules to be available for import.
#>

#region --- Module Dependencies ---
# Utils.psm1 is assumed to be globally imported by InitialisationManager.psm1.
# LoggerScriptBlock will be passed in.
#endregion

function Invoke-PoShBackupCoreSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot, # This is the PSScriptRoot of PoSh-Backup.ps1
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,
        [Parameter(Mandatory = $false)]
        [string]$BackupLocationName,
        [Parameter(Mandatory = $false)]
        [string]$RunSet,
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,
        [Parameter(Mandatory = $true)]
        [switch]$Simulate,
        [Parameter(Mandatory = $true)]
        [switch]$TestConfig,
        [Parameter(Mandatory = $true)]
        [switch]$ListBackupLocations,
        [Parameter(Mandatory = $true)]
        [switch]$ListBackupSets,
        [Parameter(Mandatory = $true)]
        [switch]$SkipUserConfigCreation,
        [Parameter(Mandatory = $true)]
        [switch]$Version,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    # --- Import Core and Manager Modules ---
    # Use the passed $PSScriptRoot (from PoSh-Backup.ps1) as the base for all module paths.
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
        Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
        # CliManager and InitialisationManager are loaded by PoSh-Backup.ps1 directly

        $cmdInfo = Get-Command Build-JobExecutionOrder -ErrorAction SilentlyContinue
        if (-not $cmdInfo) {
            & $LoggerScriptBlock -Message "[FATAL] CoreSetupManager: Build-JobExecutionOrder from JobDependencyManager is NOT available after import!" -Level "ERROR"
            throw "Build-JobExecutionOrder function not found."
        }

        & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Core modules loaded." -Level "INFO"
    } catch {
        & $LoggerScriptBlock -Message "[FATAL] CoreSetupManager: Failed to import one or more required script modules." -Level "ERROR"
        & $LoggerScriptBlock -Message "Error details: $($_.Exception.Message)" -Level "ERROR"
        throw # Re-throw to be handled by PoSh-Backup.ps1
    }

    # --- Configuration Loading, Validation & Job Determination ---
    $configLoadParams = @{
        UserSpecifiedPath           = $ConfigFile
        IsTestConfigMode            = [bool](($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent) -or ($Version.IsPresent))
        MainScriptPSScriptRoot      = $PSScriptRoot # Pass the main script's PSScriptRoot
        Logger                      = $LoggerScriptBlock
        SkipUserConfigCreationSwitch = [bool]$SkipUserConfigCreation.IsPresent
        IsSimulateModeSwitch        = [bool]$Simulate.IsPresent
        ListBackupLocationsSwitch   = [bool]$ListBackupLocations.IsPresent
        ListBackupSetsSwitch        = [bool]$ListBackupSets.IsPresent
        CliOverrideSettings         = $CliOverrideSettings
    }
    $configResult = Import-AppConfiguration @configLoadParams

    if (-not $configResult.IsValid) {
        & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: Configuration loading or validation failed. Exiting." -Level "ERROR"
        throw "Configuration loading or validation failed."
    }
    $Configuration = $configResult.Configuration
    $ActualConfigFile = $configResult.ActualPath

    if ($configResult.PSObject.Properties.Name -contains 'UserConfigLoaded') {
        if ($configResult.UserConfigLoaded) {
            & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: User override configuration from '$($configResult.UserConfigPath)' was successfully loaded and merged." -Level "INFO"
        } elseif (($null -ne $configResult.UserConfigPath) -and (-not $configResult.UserConfigLoaded) -and (Test-Path -LiteralPath $configResult.UserConfigPath -PathType Leaf)) {
            & $LoggerScriptBlock -Message "[WARNING] CoreSetupManager: User override configuration '$($configResult.UserConfigPath)' was found but an issue occurred during its loading/merging. Effective configuration may not include user overrides." -Level "WARNING"
        }
    }

    if ($null -ne $Configuration -and $Configuration -is [hashtable]) {
        $Configuration['_PoShBackup_PSScriptRoot'] = $PSScriptRoot # Use the main script's PSScriptRoot
    } else {
        & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: Configuration object is not a valid hashtable after loading. Cannot inject PSScriptRoot." -Level "ERROR"
        throw "Configuration object is not a valid hashtable."
    }

    Invoke-PoShBackupScriptMode -ListBackupLocationsSwitch $ListBackupLocations.IsPresent `
                                -ListBackupSetsSwitch $ListBackupSets.IsPresent `
                                -TestConfigSwitch $TestConfig.IsPresent `
                                -CheckForUpdateSwitch $false `
                                -VersionSwitch $Version.IsPresent `
                                -Configuration $Configuration `
                                -ActualConfigFile $ActualConfigFile `
                                -ConfigLoadResult $configResult `
                                -Logger $LoggerScriptBlock `
                                -PSScriptRootForUpdateCheck $PSScriptRoot `
                                -PSCmdletForUpdateCheck $PSCmdlet

    $sevenZipPathFromFinalConfig = if ($Configuration.ContainsKey('SevenZipPath')) { $Configuration.SevenZipPath } else { $null }
    if ([string]::IsNullOrWhiteSpace($sevenZipPathFromFinalConfig) -or -not (Test-Path -LiteralPath $sevenZipPathFromFinalConfig -PathType Leaf)) {
        & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: 7-Zip executable path ('$sevenZipPathFromFinalConfig') is invalid or not found." -Level "ERROR"
        throw "7-Zip executable path is invalid or not found."
    } else {
        & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Effective 7-Zip executable path confirmed: '$sevenZipPathFromFinalConfig'" -Level "INFO"
    }

    $Global:GlobalEnableFileLogging = if ($Configuration.ContainsKey('EnableFileLogging')) { $Configuration.EnableFileLogging } else { $false }
    if ($Global:GlobalEnableFileLogging) {
        $logDirConfig = if ($Configuration.ContainsKey('LogDirectory')) { $Configuration.LogDirectory } else { "Logs" }
        $Global:GlobalLogDirectory = if ([System.IO.Path]::IsPathRooted($logDirConfig)) { $logDirConfig } else { Join-Path -Path $PSScriptRoot -ChildPath $logDirConfig } # Use main PSScriptRoot
        if (-not (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
            try {
                New-Item -Path $Global:GlobalLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Log directory '$Global:GlobalLogDirectory' created." -Level "INFO"
            } catch {
                & $LoggerScriptBlock -Message "[WARNING] CoreSetupManager: Failed to create log directory '$Global:GlobalLogDirectory'. File logging may be impacted. Error: $($_.Exception.Message)" -Level "WARNING"
                $Global:GlobalEnableFileLogging = $false
            }
        }
    }

    $jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet -Logger $LoggerScriptBlock
    if (-not $jobResolutionResult.Success) {
        & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR"
        throw "Could not determine jobs to process."
    }
    $initialJobsToConsider = $jobResolutionResult.JobsToRun
    $currentSetName = $jobResolutionResult.SetName
    $stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy
    $setSpecificPostRunAction = $jobResolutionResult.SetPostRunAction

    $jobsToProcess = [System.Collections.Generic.List[string]]::new()
    if ($initialJobsToConsider.Count -gt 0) {
        & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Building job execution order considering dependencies..." -Level "INFO"
        $executionOrderResult = Build-JobExecutionOrder -InitialJobsToConsider $initialJobsToConsider `
                                                        -AllBackupLocations $Configuration.BackupLocations `
                                                        -Logger $LoggerScriptBlock
        if (-not $executionOrderResult.Success) {
            & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: Could not build job execution order. Error: $($executionOrderResult.ErrorMessage)" -Level "ERROR"
            throw "Could not build job execution order."
        }
        $jobsToProcess = $executionOrderResult.OrderedJobs
        if ($jobsToProcess.Count -gt 0) {
            & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Final job execution order: $($jobsToProcess -join ', ')" -Level "INFO"
        }
    }

    return @{
        Configuration            = $Configuration
        ActualConfigFile         = $ActualConfigFile
        JobsToProcess            = $jobsToProcess
        CurrentSetName           = $currentSetName
        StopSetOnErrorPolicy     = $stopSetOnError
        SetSpecificPostRunAction = $setSpecificPostRunAction
    }
}

Export-ModuleMember -Function Invoke-PoShBackupCoreSetup
