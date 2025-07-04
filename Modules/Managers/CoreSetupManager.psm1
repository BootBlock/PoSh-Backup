# Modules\Managers\CoreSetupManager.psm1
<#
.SYNOPSIS
    Acts as a facade to manage the core setup phase of PoSh-Backup. It orchestrates
    module imports required for setup, configuration loading, job resolution, dependency
    ordering, and maintenance mode checks by delegating to specialised sub-modules.
.DESCRIPTION
    This module provides a function to handle the main setup tasks after initial
    global variable setup and CLI override processing. It calls sub-modules located in
    '.\CoreSetupManager\' to handle specific responsibilities:
    - VaultUnlocker.psm1: Unlocks the PowerShell SecretStore vault if a credential file is provided.
    - MaintenanceModeChecker.psm1: Checks if the script should halt due to maintenance mode.
    - JobAndDependencyResolver.psm1: Determines the final, ordered list of jobs to run.
    - DependencyChecker.psm1: Performs context-aware validation of external module dependencies
      based on the resolved job list.

    This facade now directly invokes the advanced configuration validation after resolving
    the job list, allowing for context-aware validation of backup targets. It no longer
    eagerly loads all operational modules; they are now lazy-loaded by their respective callers.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.5.5 # FIX: Use Resolve-Path for robust module importing.
    DateCreated:    01-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate core script setup and configuration/job resolution.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    $subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "CoreSetupManager"
    Import-Module -Name (Resolve-Path (Join-Path $subModulesPath "VaultUnlocker.psm1")).Path -Force -ErrorAction Stop
    Import-Module -Name (Resolve-Path (Join-Path $subModulesPath "MaintenanceModeChecker.psm1")).Path -Force -ErrorAction Stop
    Import-Module -Name (Resolve-Path (Join-Path $subModulesPath "DependencyChecker.psm1")).Path -Force -ErrorAction Stop
    Import-Module -Name (Resolve-Path (Join-Path $subModulesPath "JobAndDependencyResolver.psm1")).Path -Force -ErrorAction Stop
    Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "..\Utils.psm1")).Path -Force -ErrorAction Stop
}
catch {
    Write-Error "CoreSetupManager.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupCoreSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,
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
        [switch]$PreFlightCheck,
        [Parameter(Mandatory = $false)]
        [string]$TestBackupTarget,
        [Parameter(Mandatory = $true)]
        [switch]$ListBackupLocations,
        [Parameter(Mandatory = $true)]
        [switch]$ListBackupSets,
        [Parameter(Mandatory = $false)]
        [switch]$SyncSchedules,
        [Parameter(Mandatory = $false)]
        [switch]$RunVerificationJobs,
        [Parameter(Mandatory = $false)]
        [string]$VerificationJobName,
        [Parameter(Mandatory = $true)]
        [switch]$SkipUserConfigCreation,
        [Parameter(Mandatory = $true)]
        [switch]$Version,
        [Parameter(Mandatory = $true)]
        [switch]$CheckForUpdate,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [switch]$ForceRunInMaintenanceMode,
        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$Maintenance,
        [Parameter(Mandatory = $false)]
        [switch]$SkipJobDependenciesSwitch
    )

    try {
        # --- 1. Import Modules REQUIRED for Setup & Utility Modes ---
        & $LoggerScriptBlock -Message "[DEBUG] CoreSetupManager: Loading modules required for setup phase..." -Level "DEBUG"

        Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "Modules\Core\ConfigManager.psm1")).Path -Force -ErrorAction Stop
        Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "Modules\ScriptModeHandler.psm1")).Path -Force -ErrorAction Stop
        Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "Modules\Managers\JobDependencyManager.psm1")).Path -Force -ErrorAction Stop
        Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "Modules\PoShBackupValidator.psm1")).Path -Force -ErrorAction Stop -WarningAction SilentlyContinue

        & $LoggerScriptBlock -Message "[SUCCESS] CoreSetupManager: Setup-phase modules loaded successfully." -Level "DEBUG"

        # --- 2. Integrated Vault Unlock ---
        if ($CliOverrideSettings.ContainsKey('VaultCredentialPath') -and -not [string]::IsNullOrWhiteSpace($CliOverrideSettings.VaultCredentialPath)) {
            Invoke-PoShBackupVaultUnlock -VaultCredentialPath $CliOverrideSettings.VaultCredentialPath -Logger $LoggerScriptBlock
        }

        # --- 3. Configuration Loading (without full validation yet) ---
        $configLoadParams = @{
            UserSpecifiedPath            = $ConfigFile
            IsTestConfigMode             = [bool](($TestConfig.IsPresent) -or ($ListBackupLocations.IsPresent) -or ($ListBackupSets.IsPresent) -or ($Version.IsPresent) -or ($SyncSchedules.IsPresent) -or ($RunVerificationJobs.IsPresent) -or ($PreFlightCheck.IsPresent) -or (-not [string]::IsNullOrWhiteSpace($CliOverrideSettings.TestBackupTarget)))
            MainScriptPSScriptRoot       = $PSScriptRoot
            Logger                       = $LoggerScriptBlock
            SkipUserConfigCreationSwitch = [bool]$SkipUserConfigCreation.IsPresent
            IsSimulateModeSwitch         = [bool]$Simulate.IsPresent
            ListBackupLocationsSwitch    = [bool]$ListBackupLocations.IsPresent
            ListBackupSetsSwitch         = [bool]$ListBackupSets.IsPresent
            CliOverrideSettings          = $CliOverrideSettings
        }
        $configResult = Import-AppConfiguration @configLoadParams
        if (-not $configResult.IsValid) { throw "Configuration loading or basic validation failed." }
        $Configuration = $configResult.Configuration
        $ActualConfigFile = $configResult.ActualPath

        if ($configResult.PSObject.Properties.Name -contains 'UserConfigLoaded' -and $configResult.UserConfigLoaded) {
            & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: User override configuration from '$($configResult.UserConfigPath)' was successfully loaded and merged." -Level "INFO"
        }
        $Configuration['_PoShBackup_PSScriptRoot'] = $PSScriptRoot

        # --- 4. Handle Script Utility Modes (which may exit before full validation) ---
        $scriptModeParams = @{
            ListBackupLocationsSwitch = $ListBackupLocations.IsPresent; ListBackupSetsSwitch = $ListBackupSets.IsPresent
            TestConfigSwitch = $TestConfig.IsPresent; PreFlightCheckSwitch = $PreFlightCheck.IsPresent
            TestBackupTarget = $TestBackupTarget; RunVerificationJobsSwitch = $RunVerificationJobs.IsPresent
            VerificationJobName = $VerificationJobName; CheckForUpdateSwitch = $CheckForUpdate.IsPresent
            VersionSwitch = $Version.IsPresent; PinBackupPath = $CliOverrideSettings.PinBackup
            UnpinBackupPath = $CliOverrideSettings.UnpinBackup; ListArchiveContentsPath = $CliOverrideSettings.ListArchiveContents
            ArchivePasswordSecretName = $CliOverrideSettings.ArchivePasswordSecretName; ExtractFromArchivePath = $CliOverrideSettings.ExtractFromArchive
            ExtractToDirectoryPath = $CliOverrideSettings.ExtractToDirectory; ItemsToExtract = $CliOverrideSettings.ItemsToExtract
            ForceExtract = ([bool]$CliOverrideSettings.ForceExtract); GetEffectiveConfigJobName = $CliOverrideSettings.GetEffectiveConfig
            ExportDiagnosticPackagePath = $CliOverrideSettings.ExportDiagnosticPackage; CliOverrideSettingsInternal = $CliOverrideSettings
            Configuration = $Configuration; ActualConfigFile = $ActualConfigFile
            ConfigLoadResult = $configResult; Logger = $LoggerScriptBlock; PSCmdletInstance = $PSCmdletInstance
            BackupLocationNameForScope = $BackupLocationName; RunSetForScope = $RunSet
        }
        if ($PSBoundParameters.ContainsKey('Maintenance') -and $null -ne $Maintenance) { $scriptModeParams.MaintenanceSwitchValue = $Maintenance }

        if ($SyncSchedules.IsPresent) {
            Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "Modules\Managers\ScheduleManager.psm1")).Path -Force -ErrorAction Stop
            $syncParams = @{
                Configuration    = $Configuration
                MainScriptRoot   = $PSScriptRoot
                Logger           = $LoggerScriptBlock
                PSCmdletInstance = $PSCmdletInstance
            }
            if ($PSCmdletInstance.MyInvocation.BoundParameters.ContainsKey('Simulate')) {
                $syncParams.IsWhatIfMode = $true
            }
            Sync-PoShBackupSchedule @syncParams
            exit 0
        }

        if (Invoke-PoShBackupScriptMode @scriptModeParams) { exit 0 }

        # --- 5. Check for Maintenance Mode ---
        if (-not $Maintenance.HasValue) {
            if ((Test-PoShBackupMaintenanceMode -Configuration $Configuration -Logger $LoggerScriptBlock) -and (-not $ForceRunInMaintenanceMode.IsPresent)) { exit 0 }
            elseif ($ForceRunInMaintenanceMode.IsPresent) { & $LoggerScriptBlock -Message "[WARNING] The -ForceRunInMaintenanceMode switch was used. Bypassing maintenance mode check." -Level "WARNING" }
        }

        # --- 6. Resolve Job Execution Plan (moved BEFORE validation) ---
        $executionPlanResult = Resolve-PoShBackupJobExecutionPlan -Configuration $Configuration `
            -BackupLocationName $BackupLocationName -RunSet $RunSet -JobsToSkip $CliOverrideSettings.SkipJob `
            -Logger $LoggerScriptBlock -SkipJobDependenciesSwitch:$SkipJobDependenciesSwitch.IsPresent

        # --- 7. Perform Context-Aware Validation and Dependency Checks ---
        if ($Configuration.EnableAdvancedSchemaValidation) {
            $validationMessages = [System.Collections.Generic.List[string]]::new()
            Invoke-PoShBackupConfigValidation -ConfigurationToValidate $Configuration -ValidationMessagesListRef ([ref]$validationMessages) -JobsToRun $executionPlanResult.JobsToProcess -Logger $LoggerScriptBlock
            if ($validationMessages.Count -gt 0) {
                & $LoggerScriptBlock -Message "CoreSetupManager: Advanced configuration validation FAILED with errors/warnings:" -Level "ERROR"
                ($validationMessages | Select-Object -Unique) | ForEach-Object { & $LoggerScriptBlock -Message "  - $_" -Level "ERROR" }
                throw "Advanced configuration validation failed. See logs for details."
            }
        }
        Invoke-PoShBackupDependencyCheck -Logger $LoggerScriptBlock -Configuration $Configuration -JobsToRun $executionPlanResult.JobsToProcess

        # --- 8. Final Setup Steps ---
        $Global:GlobalEnableFileLogging = Get-ConfigValue -ConfigObject $Configuration -Key 'EnableFileLogging' -DefaultValue $false
        if ($Global:GlobalEnableFileLogging) {
            $logDirConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'LogDirectory' -DefaultValue 'Logs'
            $Global:GlobalLogDirectory = Resolve-PoShBackupPath -PathToResolve $logDirConfig -ScriptRoot $PSScriptRoot
            if (-not (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
                try { New-Item -Path $Global:GlobalLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LoggerScriptBlock -Message "[INFO] CoreSetupManager: Log directory '$Global:GlobalLogDirectory' created." -Level "INFO" }
                catch { & $LoggerScriptBlock -Message "[WARNING] CoreSetupManager: Failed to create log directory. File logging may be impacted. Error: $($_.Exception.Message)" -Level "WARNING"; $Global:GlobalEnableFileLogging = $false }
            }
        }

        # --- 9. Return the final execution plan ---
        return @{
            Configuration = $Configuration; ActualConfigFile = $ActualConfigFile
            JobsToProcess = $executionPlanResult.JobsToProcess; CurrentSetName = $executionPlanResult.CurrentSetName
            StopSetOnErrorPolicy = $executionPlanResult.StopSetOnErrorPolicy; SetSpecificPostRunAction = $executionPlanResult.SetSpecificPostRunAction
        }
    }
    catch {
        & $LoggerScriptBlock -Message "[FATAL] CoreSetupManager: A critical error occurred during the setup and validation phase. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

Export-ModuleMember -Function Invoke-PoShBackupCoreSetup
