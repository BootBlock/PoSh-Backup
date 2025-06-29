# Modules\PoShBackupValidator.psm1
<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    The schema is loaded from an external file: 'Modules\ConfigManagement\Assets\ConfigSchema.psd1'.
    This module now supports context-aware validation for Backup Targets.

.DESCRIPTION
    This PowerShell module uses a detailed schema definition, loaded from an external .psd1 file,
    to validate a PoSh-Backup configuration object (hashtable).

    After generic schema validation (performed by the sub-module), this facade:
    - Calls 'Test-PoShBackupJobDependencyGraph' from 'JobDependencyManager.psm1' to validate job dependency chains.
    - Dynamically discovers and invokes type-specific validation functions for each defined Backup Target instance.
    - When provided with a list of jobs to run, it will only validate the targets associated with those specific jobs. Otherwise, it validates all defined targets.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.9.1 # BUGFIX: Fixed HashSet.ToArray() call for PowerShell 5.1 compatibility.
    DateCreated:    14-May-2025
    LastModified:   28-Jun-2025
    Purpose:        Optional advanced configuration validation sub-module for PoSh-Backup.
#>

#region --- Module-Scoped Schema Loading & Sub-Module Import ---
$Script:LoadedConfigSchema = $null
$schemaFilePath = Join-Path -Path $PSScriptRoot -ChildPath "ConfigManagement\Assets\ConfigSchema.psd1"

if (Test-Path -LiteralPath $schemaFilePath -PathType Leaf) {
    try {
        $Script:LoadedConfigSchema = Import-PowerShellDataFile -LiteralPath $schemaFilePath -ErrorAction Stop
        if ($null -eq $Script:LoadedConfigSchema -or -not ($Script:LoadedConfigSchema -is [hashtable]) -or $Script:LoadedConfigSchema.Count -eq 0) {
            Write-Error "[PoShBackupValidator.psm1] CRITICAL: Loaded schema from '$schemaFilePath' is null, not a hashtable, or empty. Advanced validation will fail."
            $Script:LoadedConfigSchema = $null
        }
    }
    catch {
        Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to load or parse configuration schema from '$schemaFilePath'. Error: $($_.Exception.Message). Advanced validation will be unavailable or fail."
        $Script:LoadedConfigSchema = $null
    }
}
else {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Configuration schema file not found at '$schemaFilePath'. Advanced validation will be unavailable."
}

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
    $subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "PoShBackupValidator"
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "SchemaExecutionEngine.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to import a required sub-module. Error: $($_.Exception.ToString())"
}
#endregion

#region --- Exported Functions ---
function Invoke-PoShBackupConfigValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigurationToValidate,
        [Parameter(Mandatory)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [string[]]$JobsToRun, # NEW: Optional list of jobs for context-aware validation
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "PoShBackupValidator/Invoke-PoShBackupConfigValidation: Initialising." -Level "DEBUG"

    if ($null -eq $Script:LoadedConfigSchema) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator cannot perform validation because the configuration schema (ConfigSchema.psd1) failed to load or was not found. Check previous errors from PoShBackupValidator.psm1 loading.")
        return
    }

    if (-not (Get-Command Test-SchemaRecursiveInternal -ErrorAction SilentlyContinue)) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator: Core schema validation function 'Test-SchemaRecursiveInternal' not found. Sub-module 'SchemaExecutionEngine.psm1' might have failed to load. Generic schema validation skipped.")
    }
    else {
        Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:LoadedConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
    }


    if ($ConfigurationToValidate.ContainsKey('BackupLocations') -and $ConfigurationToValidate.BackupLocations -is [hashtable] -and (Get-Command Test-PoShBackupJobDependencyGraph -ErrorAction SilentlyContinue)) {
        & $LocalWriteLog -Message "PoShBackupValidator: Performing job dependency validation..." -Level "DEBUG"
        Test-PoShBackupJobDependencyGraph -AllBackupLocations $ConfigurationToValidate.BackupLocations -ValidationMessagesListRef $ValidationMessagesListRef -Logger $Logger
    }

    # --- Context-Aware Target Validation Logic ---
    if ($ConfigurationToValidate.ContainsKey('BackupTargets') -and $ConfigurationToValidate.BackupTargets -is [hashtable]) {
        $mainScriptPSScriptRoot = $ConfigurationToValidate['_PoShBackup_PSScriptRoot']
        if ([string]::IsNullOrWhiteSpace($mainScriptPSScriptRoot) -or (-not (Test-Path -LiteralPath $mainScriptPSScriptRoot -PathType Container))) {
            $ValidationMessagesListRef.Value.Add("CRITICAL (PoShBackupValidator): '_PoShBackup_PSScriptRoot' path is invalid. Cannot resolve paths for target provider modules. Target-specific validation skipped.")
            return
        }

        $targetsToValidate = @()
        if ($PSBoundParameters.ContainsKey('JobsToRun') -and $null -ne $JobsToRun -and $JobsToRun.Count -gt 0) {
            # CONTEXT-AWARE: Validate only the targets used by the jobs being run.
            & $LocalWriteLog -Message "PoShBackupValidator: Performing context-aware validation for targets used by $($JobsToRun.Count) job(s)." -Level "DEBUG"
            $requiredTargetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($jobName in $JobsToRun) {
                if ($ConfigurationToValidate.BackupLocations.ContainsKey($jobName)) {
                    $jobConf = $ConfigurationToValidate.BackupLocations[$jobName]
                    if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                        $jobConf.TargetNames | ForEach-Object { $null = $requiredTargetNames.Add($_) }
                    }
                }
            }
            # THIS IS THE FIX: Convert HashSet to Array in a compatible way
            $targetsToValidate = @($requiredTargetNames)
            & $LocalWriteLog -Message "  - Required targets for this run: $(if($targetsToValidate.Count -gt 0){$targetsToValidate -join ', '}else{'None'})" -Level "DEBUG"
        }
        else {
            # FULL VALIDATION: No specific jobs provided, so validate all defined targets (for -TestConfig).
            & $LocalWriteLog -Message "PoShBackupValidator: No specific jobs provided. Performing full validation on ALL defined targets." -Level "DEBUG"
            $targetsToValidate = @($ConfigurationToValidate.BackupTargets.Keys)
        }

        foreach ($targetName in $targetsToValidate) {
            if (-not $ConfigurationToValidate.BackupTargets.ContainsKey($targetName)) {
                $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Target '$targetName' is referenced by a job but is not defined in the 'BackupTargets' section.")
                continue
            }
            $targetInstance = $ConfigurationToValidate.BackupTargets[$targetName]

            if (-not ($targetInstance -is [hashtable] -and $targetInstance.ContainsKey('Type') -and $targetInstance.Type -is [string] -and (-not [string]::IsNullOrWhiteSpace($targetInstance.Type)))) {
                & $LocalWriteLog -Message "PoShBackupValidator: Skipping specific validation for target '$targetName' due to missing Type or incorrect structure. Generic schema errors may apply." -Level "DEBUG"
                continue
            }

            $targetType = $targetInstance.Type
            $targetProviderModuleName = "$($targetType).Target.psm1"
            $targetProviderModulePath = Join-Path -Path $mainScriptPSScriptRoot -ChildPath "Modules\Targets\$targetProviderModuleName"
            $validationFunctionName = "Invoke-PoShBackup$($targetType)TargetSettingsValidation"

            if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
                $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Target provider module '$targetProviderModuleName' for target '$targetName' not found at '$targetProviderModulePath'. Cannot perform specific validation.")
                continue
            }

            try {
                Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
                $validatorCmd = Get-Command $validationFunctionName -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1", "")) -ErrorAction SilentlyContinue

                if ($validatorCmd) {
                    & $LocalWriteLog -Message "PoShBackupValidator: Invoking specific settings validation for target '$targetName' (Type: '$targetType')." -Level "DEBUG"
                    & $validatorCmd -TargetInstanceConfiguration $targetInstance -TargetInstanceName $targetName -ValidationMessagesListRef $ValidationMessagesListRef -Logger $Logger
                }
                else {
                    $errorMessage = "Validation function '$validationFunctionName' not found in provider module '$targetProviderModuleName' for target '$targetName'."
                    $adviceMessage = "ADVICE: For custom target providers, ensure you have implemented and exported a function named '$validationFunctionName' to perform target-specific settings validation."
                    $ValidationMessagesListRef.Value.Add($errorMessage)
                    # Also log it for immediate feedback during -TestConfig
                    & $LocalWriteLog -Message "[WARNING] PoShBackupValidator: $errorMessage" -Level "WARNING"
                    & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
                }
            }
            catch {
                $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Error loading or executing validation for target '$targetName' (Type: '$targetType'). Module: '$targetProviderModuleName'. Error: $($_.Exception.Message)")
            }
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
