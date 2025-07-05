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
    Version:        1.0.1 # Robust automation, logging, and validation refactor.
    DateCreated:    14-May-2025
    LastModified:   05-Jul-2025
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
    # JobDependencyManager now exports Get-PoShBackupJobDependencyMap and Test-PoShBackupJobDependencyGraph
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
    $subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "PoShBackupValidator"
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "SchemaExecutionEngine.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to import a required sub-module. Error: $($_.Exception.ToString())"
}
#endregion

#region --- Exported Functions ---
function _PoShBackupValidator_ValidateParams {
    <#
    .SYNOPSIS
        Validates required parameters for PoShBackupValidator functions.
    .DESCRIPTION
        Throws if the configuration or validation messages reference is missing. Used internally to ensure required arguments are present before validation logic proceeds.
    .PARAMETER ConfigurationToValidate
        The configuration hashtable to validate.
    .PARAMETER ValidationMessagesListRef
        [ref] to a list that will be populated with validation errors, warnings, and advice messages.
    .NOTES
        Throws if required parameters are missing.
    #>
    param($ConfigurationToValidate, $ValidationMessagesListRef)
    if ($null -eq $ConfigurationToValidate) {
        throw 'ConfigurationToValidate is required.'
    }
    if ($null -eq $ValidationMessagesListRef) {
        throw 'ValidationMessagesListRef is required.'
    }
}

function _PoShBackupValidator_CheckSchema {
    <#
    .SYNOPSIS
        Checks if the provided schema is valid for validation.
    .DESCRIPTION
        Returns $false and adds a critical error message if the schema is missing or invalid. Used internally before running schema-based validation.
    .PARAMETER Schema
        The schema hashtable to check.
    .PARAMETER ValidationMessagesListRef
        [ref] to a list that will be populated with validation errors, warnings, and advice messages.
    .OUTPUTS
        [bool] True if schema is valid, otherwise false.
    #>
    param($Schema, $ValidationMessagesListRef)
    if ($null -eq $Schema -or $Schema -eq '__SCHEMA_MISSING__') {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator cannot perform validation because the configuration schema (ConfigSchema.psd1) failed to load or was not found. Check previous errors from PoShBackupValidator.psm1 loading.")
        return $false
    }
    return $true
}

function _PoShBackupValidator_InternalValidation {
    <#
    .SYNOPSIS
        Performs the core internal validation logic for PoShBackupValidator.
    .DESCRIPTION
        Runs schema validation, job dependency validation, and context-aware target validation. Used internally by Invoke-PoShBackupConfigValidation, but can be injected for testing.
    .PARAMETER ConfigurationToValidate
        The configuration hashtable to validate.
    .PARAMETER ValidationMessagesListRef
        [ref] to a list that will be populated with validation errors, warnings, and advice messages.
    .PARAMETER JobsToRun
        (Optional) Array of job names to restrict validation to only the targets used by these jobs.
    .PARAMETER Logger
        (Optional) Scriptblock logger to receive log messages.
    .PARAMETER schemaToUse
        The schema hashtable to use for validation.
    .NOTES
        Used internally; not intended for direct external use.
    #>
    param($ConfigurationToValidate, $ValidationMessagesListRef, $JobsToRun, $Logger, $schemaToUse)

    if (-not (Get-Command Test-SchemaRecursiveInternal -ErrorAction SilentlyContinue)) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator: Core schema validation function 'Test-SchemaRecursiveInternal' not found. Sub-module 'SchemaExecutionEngine.psm1' might have failed to load. Generic schema validation skipped.")
    }
    else {
        Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $schemaToUse -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
    }


    if ($ConfigurationToValidate.ContainsKey('BackupLocations') -and $ConfigurationToValidate.BackupLocations -is [hashtable] -and (Get-Command Test-PoShBackupJobDependencyGraph -ErrorAction SilentlyContinue)) {
        & $LocalWriteLog -Message "PoShBackupValidator: Performing job dependency validation..." -Level "DEBUG"
        # --- FIX: First, build the dependency map, then pass it to the validator ---
        $dependencyMap = Get-PoShBackupJobDependencyMap -AllBackupLocations $ConfigurationToValidate.BackupLocations
        Test-PoShBackupJobDependencyGraph -AllBackupLocations $ConfigurationToValidate.BackupLocations `
            -DependencyMap $dependencyMap `
            -ValidationMessagesListRef $ValidationMessagesListRef `
            -Logger $Logger
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
                $targetProviderModuleShortName = [System.IO.Path]::GetFileNameWithoutExtension($targetProviderModuleName)
                $validatorCmd = Get-Command $validationFunctionName -Module $targetProviderModuleShortName -ErrorAction SilentlyContinue

                # Removed DEBUG output of validatorCmd type and value for cleaner logs
                if ($validatorCmd -and $validatorCmd -is [System.Management.Automation.CommandInfo]) {
                    try {
                        & $LocalWriteLog -Message "PoShBackupValidator: Invoking specific settings validation for target '$targetName' (Type: '$targetType')." -Level "DEBUG"
                        & $validatorCmd.Name -TargetInstanceConfiguration $targetInstance -TargetInstanceName $targetName -ValidationMessagesListRef $ValidationMessagesListRef -Logger $Logger
                    } catch {
                        Write-Host "[ERROR] Exception during invocation of '$validationFunctionName' for target '$targetName'. Error: $($_.Exception.Message)" -ForegroundColor Red
                        $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Exception during invocation of '$validationFunctionName' for target '$targetName'. Error: $($_.Exception.Message)")
                        & $LocalWriteLog -Message "[ERROR] PoShBackupValidator: Exception during invocation of '$validationFunctionName' for target '$targetName'. Error: $($_.Exception.Message)" -Level "ERROR"
                    }
                }
                else {
                    $errorMessage = "Validation function '$validationFunctionName' not found or not valid in provider module '$targetProviderModuleName' for target '$targetName'."
                    $adviceMessage = "ADVICE: For custom target providers, ensure you have implemented and exported a function named '$validationFunctionName' to perform target-specific settings validation."
                    $ValidationMessagesListRef.Value.Add($errorMessage)
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

<#
.SYNOPSIS
    Validates a PoSh-Backup configuration object against the schema and performs advanced checks.
.DESCRIPTION
    Performs advanced, schema-based validation of a PoSh-Backup configuration hashtable. Checks for required keys, types, allowed values, job dependency integrity, and invokes type-specific validation for each defined Backup Target. Optionally supports context-aware validation for a subset of jobs.
.PARAMETER ConfigurationToValidate
    The configuration hashtable to validate. Must be the merged, effective configuration object.
.PARAMETER ValidationMessagesListRef
    [ref] to a list (e.g., [ref](New-Object System.Collections.Generic.List[string])) that will be populated with validation errors, warnings, and advice messages.
.PARAMETER JobsToRun
    (Optional) Array of job names to restrict validation to only the targets used by these jobs. If omitted, all defined targets are validated.
.PARAMETER Logger
    (Optional) Scriptblock logger to receive log messages. Should accept -Message and -Level parameters.
.PARAMETER Schema
    (Optional) Schema hashtable to use for validation. If omitted, uses the module's loaded schema.
.PARAMETER InternalValidation
    (Optional) Scriptblock to override the internal validation logic (for testing/mocking).
.EXAMPLE
    $messages = New-Object System.Collections.Generic.List[string]
    $messagesRef = [ref]$messages
    Invoke-PoShBackupConfigValidation -ConfigurationToValidate $config -ValidationMessagesListRef $messagesRef
.NOTES
    Returns nothing. All results are communicated via the ValidationMessagesListRef and logger.
#>
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
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        $Schema,
        [Parameter(Mandatory = $false)]
        [scriptblock]$InternalValidation
    )

    # --- GUARD: Ensure ValidationMessagesListRef.Value is always a valid List[string] ---
    if ($null -eq $ValidationMessagesListRef.Value) {
        $ValidationMessagesListRef.Value = [System.Collections.Generic.List[string]]::new()
    }

    _PoShBackupValidator_ValidateParams $ConfigurationToValidate $ValidationMessagesListRef
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "PoShBackupValidator/Invoke-PoShBackupConfigValidation: Initialising." -Level "DEBUG"

    $schemaToUse = if ($PSBoundParameters.ContainsKey('Schema')) { $Schema } else { $Script:LoadedConfigSchema }
    if (-not (_PoShBackupValidator_CheckSchema $schemaToUse $ValidationMessagesListRef)) {
        return
    }
    $internalValidation = if ($PSBoundParameters.ContainsKey('InternalValidation')) { $InternalValidation } else { ${function:_PoShBackupValidator_InternalValidation} }
    & $internalValidation $ConfigurationToValidate $ValidationMessagesListRef $JobsToRun $Logger $schemaToUse
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
