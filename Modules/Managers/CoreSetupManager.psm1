# Modules\Managers\CoreSetupManager.psm1
<#
.SYNOPSIS
    Manages the core setup phase of PoSh-Backup, including module imports,
    configuration loading, job resolution, and dependency ordering.
.DESCRIPTION
    This module provides a function to handle the main setup tasks after initial
    global variable setup and CLI override processing. It checks for required external
    PowerShell modules (e.g., Posh-SSH, SecretManagement) only if the configuration
    and the specific jobs being run actually require them. It imports necessary PoSh-Backup
    modules, loads and validates the application configuration, handles informational script modes,
    validates essential settings, initialises global logging parameters, and determines
    the final list and order of jobs to be processed.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.5 # Corrected order of operations for all informational/utility modes.
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

#region --- Private Helper Functions ---
function Test-RequiredModulesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$JobsToRun
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "CoreSetupManager/Test-RequiredModulesInternal: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "CoreSetupManager/Test-RequiredModulesInternal: Checking for required external PowerShell modules based on jobs to be run..." -Level "DEBUG"

    # Define modules and the condition under which they are required.
    $requiredModules = @(
        @{
            ModuleName  = 'Posh-SSH'
            RequiredFor = 'SFTP Target Provider'
            InstallHint = 'Install-Module Posh-SSH -Scope CurrentUser'
            Condition   = {
                param($Config, $ActiveJobs)
                # This module is only required if a job that is *actually going to run* uses an SFTP target.
                if ($Config.ContainsKey('BackupTargets') -and $Config.BackupTargets -is [hashtable]) {
                    foreach ($jobName in $ActiveJobs) {
                        $jobConf = $Config.BackupLocations[$jobName]
                        if ($jobConf -and $jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                            foreach ($targetName in $jobConf.TargetNames) {
                                if ($Config.BackupTargets.ContainsKey($targetName)) {
                                    $targetDef = $Config.BackupTargets[$targetName]
                                    if ($targetDef -is [hashtable] -and $targetDef.Type -eq 'SFTP') {
                                        return $true # Condition met, check is required.
                                    }
                                }
                            }
                        }
                    }
                }
                return $false # Condition not met, skip check.
            }
        },
        @{
            ModuleName  = 'Microsoft.PowerShell.SecretManagement'
            RequiredFor = 'Archive Passwords or Target Credentials from a vault'
            InstallHint = 'Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser'
            Condition   = {
                param($Config, $ActiveJobs)
                if ($null -eq $ActiveJobs -or $ActiveJobs.Count -eq 0) { return $false }

                foreach ($jobName in $ActiveJobs) {
                    if (-not $Config.BackupLocations.ContainsKey($jobName)) { continue }
                    $jobConf = $Config.BackupLocations[$jobName]

                    # Condition 1: Job's archive password method is SecretManagement.
                    if ($jobConf.ArchivePasswordMethod -eq 'SecretManagement') {
                        return $true
                    }

                    # Condition 2: Job uses a target that has a CredentialsSecretName defined.
                    if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                        foreach ($targetName in $jobConf.TargetNames) {
                            if ($Config.BackupTargets.ContainsKey($targetName)) {
                                $targetDef = $Config.BackupTargets[$targetName]
                                if ($targetDef -is [hashtable] -and $targetDef.ContainsKey('CredentialsSecretName') -and (-not [string]::IsNullOrWhiteSpace($targetDef.CredentialsSecretName))) {
                                    return $true
                                }
                            }
                        }
                    }
                }
                return $false # No active job triggered the condition.
            }
        }
        # Add other required modules here in the future with their own conditions.
        # --- HOW TO ADD A NEW DEPENDENCY ---
        # To add a check for another module (e.g., a hypothetical 'Az.Storage' for an Azure target),
        # simply add a new hashtable entry to the $requiredModules array above, following this pattern:
        #
        # @{
        #     ModuleName  = 'Az.Storage' # The exact name of the module on the PowerShell Gallery.
        #     RequiredFor = 'Azure Blob Storage Target Provider' # A user-friendly description of the feature.
        #     InstallHint = 'Install-Module Az.Storage -Scope CurrentUser' # The command to install the module.
        #     Condition   = {
        #         param($Config, $ActiveJobs)
        #         # This scriptblock MUST return $true if the dependency check is needed, otherwise $false.
        #         # It should inspect the loaded $Config and the list of $ActiveJobs to make its decision.
        #         #
        #         # Example logic for an 'AzureBlob' target type:
        #         if ($Config.ContainsKey('BackupTargets') -and $Config.BackupTargets -is [hashtable]) {
        #             foreach ($jobName in $ActiveJobs) {
        #                 $jobConf = $Config.BackupLocations[$jobName]
        #                 if ($jobConf -and $jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
        #                     foreach ($targetName in $jobConf.TargetNames) {
        #                         if ($Config.BackupTargets.ContainsKey($targetName)) {
        #                             $targetDef = $Config.BackupTargets[$targetName]
        #                             if ($targetDef -is [hashtable] -and $targetDef.Type -eq 'AzureBlob') {
        #                                 return $true # An active job uses an AzureBlob target, so the check is required.
        #                             }
        #                         }
        #                     }
        #                 }
        #             }
        #         }
        #         return $false # No active job uses an AzureBlob target, so the check is skipped.
        #     }
        # }
    )

    $missingModules = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleInfo in $requiredModules) {
        # Evaluate the condition to see if we need to check for this module.
        if (& $moduleInfo.Condition -Config $Configuration -ActiveJobs $JobsToRun) {
            $moduleName = $moduleInfo.ModuleName
            & $LocalWriteLog -Message "  - Condition met for '$($moduleInfo.RequiredFor)'. Checking for module: '$moduleName'." -Level "DEBUG"
            if (-not (Get-Module -Name $moduleName -ListAvailable)) {
                $errorMessage = "Required PowerShell module '$moduleName' is not installed. This module is necessary for the '$($moduleInfo.RequiredFor)' functionality. Please install it by running: $($moduleInfo.InstallHint)"
                $missingModules.Add($errorMessage)
            }
        }
    }

    if ($missingModules.Count -gt 0) {
        $fullErrorMessage = "FATAL: One or more required PowerShell modules are missing for the configured features. Please install them to ensure full functionality.`n"
        $fullErrorMessage += ($missingModules -join "`n")
        throw $fullErrorMessage
    }

    & $LocalWriteLog -Message "CoreSetupManager/Test-RequiredModulesInternal: All conditionally required external modules found." -Level "SUCCESS"
}
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

    # --- Configuration Loading and Validation ---
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

    # --- Handle Informational Modes FIRST ---
    # This includes Pinning, Listing, etc., which must exit before job resolution is attempted for a backup run.
    Invoke-PoShBackupScriptMode -ListBackupLocationsSwitch $ListBackupLocations.IsPresent `
                                -ListBackupSetsSwitch $ListBackupSets.IsPresent `
                                -TestConfigSwitch $TestConfig.IsPresent `
                                -CheckForUpdateSwitch $false `
                                -VersionSwitch $Version.IsPresent `
                                -PinBackupPath $CliOverrideSettings.PinBackup `
                                -UnpinBackupPath $CliOverrideSettings.UnpinBackup `
                                -ListArchiveContentsPath $CliOverrideSettings.ListArchiveContents `
                                -ArchivePasswordSecretName $CliOverrideSettings.ArchivePasswordSecretName `
                                -Configuration $Configuration `
                                -ActualConfigFile $ActualConfigFile `
                                -ConfigLoadResult $configResult `
                                -Logger $LoggerScriptBlock `
                                -PSScriptRootForUpdateCheck $PSScriptRoot `
                                -PSCmdletForUpdateCheck $PSCmdlet

    # --- Job Resolution ---
    $jobResolutionResult = Get-JobsToProcess -Config $Configuration -SpecifiedJobName $BackupLocationName -SpecifiedSetName $RunSet -Logger $LoggerScriptBlock
    if (-not $jobResolutionResult.Success) {
        & $LoggerScriptBlock -Message "FATAL: CoreSetupManager: Could not determine jobs to process. $($jobResolutionResult.ErrorMessage)" -Level "ERROR"
        throw "Could not determine jobs to process."
    }
    $initialJobsToConsider = $jobResolutionResult.JobsToRun
    $currentSetName = $jobResolutionResult.SetName
    $stopSetOnError = $jobResolutionResult.StopSetOnErrorPolicy
    $setSpecificPostRunAction = $jobResolutionResult.SetPostRunAction

    # --- Check for External Dependencies AFTER config has been loaded AND jobs have been resolved ---
    try {
        Test-RequiredModulesInternal -Logger $LoggerScriptBlock -Configuration $Configuration -JobsToRun $initialJobsToConsider
    }
    catch {
        & $LoggerScriptBlock -Message $_.Exception.Message -Level "ERROR"
        throw # Re-throw to be handled by PoSh-Backup.ps1
    }

    # --- Final Setup Steps ---
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

    # --- Build Final Execution Order ---
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
