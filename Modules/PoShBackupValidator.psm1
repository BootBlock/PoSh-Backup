# Modules\PoShBackupValidator.psm1
<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    The schema is loaded from an external file: 'Modules\ConfigManagement\Assets\ConfigSchema.psd1'.
    This module now delegates detailed validation for specific Backup Target types to functions
    within the respective target provider modules and job dependency validation to JobDependencyManager.
    The core recursive schema validation is handled by the 'SchemaExecutionEngine.psm1' sub-module.

.DESCRIPTION
    This PowerShell module uses a detailed schema definition, loaded from an external .psd1 file,
    to validate a PoSh-Backup configuration object (hashtable). It provides functions to
    recursively validate the configuration against this schema by calling its sub-module.

    After generic schema validation (performed by the sub-module), this facade:
    - Calls 'Test-PoShBackupJobDependencyGraph' from 'JobDependencyManager.psm1' to validate job dependency
      chains (e.g., for circular references or dependencies on non-existent jobs).
    - Dynamically discovers and invokes type-specific validation functions
      (e.g., 'Invoke-PoShBackupUNCTargetSettingsValidation') from the relevant target
      provider modules (e.g., UNC.Target.psm1) for each defined Backup Target instance.
    - It now passes the *entire* target instance configuration to the provider's validation
      function, allowing validation of keys outside the 'TargetSpecificSettings' block.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.8.0 # Refactored to pass the entire target instance to provider validators.
    DateCreated:    14-May-2025
    LastModified:   21-Jun-2025
    Purpose:        Optional advanced configuration validation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Schema file 'ConfigSchema.psd1' must exist in 'Modules\ConfigManagement\Assets\'.
                    Sub-module 'SchemaExecutionEngine.psm1' must exist in 'Modules\PoShBackupValidator\'.
                    Target provider modules (e.g., UNC.Target.psm1) must exist in 'Modules\Targets\'.
                    JobDependencyManager.psm1 must exist in 'Modules\Managers\'.
#>

#region --- Module-Scoped Schema Loading & Sub-Module Import ---
$Script:LoadedConfigSchema = $null
# $PSScriptRoot for PoShBackupValidator.psm1 is Modules\
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

# Import JobDependencyManager for dependency validation
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to import JobDependencyManager.psm1. Job dependency validation will be unavailable. Error: $($_.Exception.ToString())"
}

# Import the SchemaExecutionEngine sub-module
# $PSScriptRoot here is Modules\
$subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "PoShBackupValidator"
try {
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "SchemaExecutionEngine.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to import sub-module 'SchemaExecutionEngine.psm1' from '$subModulesPath'. Core schema validation will fail. Error: $($_.Exception.Message)"
    # If this fails, Test-SchemaRecursiveInternal won't be available.
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

    # Check if Test-SchemaRecursiveInternal (from sub-module) is available
    if (-not (Get-Command Test-SchemaRecursiveInternal -ErrorAction SilentlyContinue)) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator: Core schema validation function 'Test-SchemaRecursiveInternal' not found. Sub-module 'SchemaExecutionEngine.psm1' might have failed to load. Generic schema validation skipped.")
    } else {
        # Perform generic schema validation using the sub-module's function
        Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:LoadedConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
    }


    if ($ConfigurationToValidate.ContainsKey('BackupLocations') -and $ConfigurationToValidate.BackupLocations -is [hashtable] -and (Get-Command Test-PoShBackupJobDependencyGraph -ErrorAction SilentlyContinue)) {
        & $LocalWriteLog -Message "PoShBackupValidator: Performing job dependency validation..." -Level "DEBUG"
        $dependencyParams = @{
            AllBackupLocations       = $ConfigurationToValidate.BackupLocations
            ValidationMessagesListRef = $ValidationMessagesListRef
        }
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            $dependencyParams.Logger = $Logger
        }
        Test-PoShBackupJobDependencyGraph @dependencyParams
    } elseif (-not (Get-Command Test-PoShBackupJobDependencyGraph -ErrorAction SilentlyContinue)) {
        & $LocalWriteLog -Message "PoShBackupValidator: JobDependencyManager module or Test-PoShBackupJobDependencyGraph function not available. Skipping job dependency validation." -Level "WARNING"
    }

    if ($ConfigurationToValidate.ContainsKey('BackupTargets') -and $ConfigurationToValidate.BackupTargets -is [hashtable]) {
        $mainScriptPSScriptRoot = $ConfigurationToValidate['_PoShBackup_PSScriptRoot']

        if ([string]::IsNullOrWhiteSpace($mainScriptPSScriptRoot)) {
            $ValidationMessagesListRef.Value.Add("CRITICAL (PoShBackupValidator): '_PoShBackup_PSScriptRoot' key is missing or empty in the configuration object. Cannot resolve paths for target provider modules. Target-specific validation skipped.")
            return
        }
        if (-not (Test-Path -LiteralPath $mainScriptPSScriptRoot -PathType Container)) {
             $ValidationMessagesListRef.Value.Add("CRITICAL (PoShBackupValidator): '_PoShBackup_PSScriptRoot' path ('$mainScriptPSScriptRoot') does not exist or is not a directory. Cannot resolve paths for target provider modules. Target-specific validation skipped.")
            return
        }

        foreach ($targetName in $ConfigurationToValidate.BackupTargets.Keys) {
            $targetInstance = $ConfigurationToValidate.BackupTargets[$targetName]

            if (-not ($targetInstance -is [hashtable] -and
                      $targetInstance.ContainsKey('Type') -and $targetInstance.Type -is [string] -and
                      (-not ([string]::IsNullOrWhiteSpace($targetInstance.Type))))) {
                & $LocalWriteLog -Message "PoShBackupValidator: Skipping specific validation for target '$targetName' due to missing Type or incorrect structure. Generic schema errors may apply." -Level "DEBUG"
                continue
            }

            $targetType = $targetInstance.Type
            $targetProviderModuleName = "$($targetType).Target.psm1"
            $targetProviderModulePath = Join-Path -Path $mainScriptPSScriptRoot -ChildPath "Modules\Targets\$targetProviderModuleName"
            $validationFunctionName = "Invoke-PoShBackup$($targetType)TargetSettingsValidation"

            if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
                $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Target provider module '$targetProviderModuleName' for type '$targetType' (target instance '$targetName') not found at '$targetProviderModulePath'. Cannot perform specific validation for its settings.")
                continue
            }

            try {
                Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
                $validatorCmd = Get-Command $validationFunctionName -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1","")) -ErrorAction SilentlyContinue

                if ($validatorCmd) {
                    & $LocalWriteLog -Message "PoShBackupValidator: Invoking specific settings validation for target '$targetName' (Type: '$targetType') using function '$validationFunctionName'." -Level "DEBUG"

                    # Pass the ENTIRE target instance configuration to the provider's validator.
                    $validationParams = @{
                        TargetInstanceConfiguration = $targetInstance
                        TargetInstanceName          = $targetName
                        ValidationMessagesListRef   = $ValidationMessagesListRef
                    }

                    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger -and $validatorCmd.Parameters.ContainsKey('Logger')) {
                        $validationParams.Logger = $Logger
                    }

                    & $validatorCmd @validationParams
                } else {
                    $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Validation function '$validationFunctionName' not found in provider module '$targetProviderModuleName' for target instance '$targetName'. Specific settings for this target type cannot be validated by PoShBackupValidator.")
                }
            } catch {
                $ValidationMessagesListRef.Value.Add("PoShBackupValidator: Error loading or executing validation for target '$targetName' (Type: '$targetType'). Module: '$targetProviderModuleName'. Error: $($_.Exception.Message)")
            }
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
