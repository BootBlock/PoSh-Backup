# Modules\PoShBackupValidator.psm1
<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    The schema is loaded from an external file: 'Modules\ConfigManagement\Assets\ConfigSchema.psd1'.
    This module now delegates detailed validation for specific Backup Target types to functions
    within the respective target provider modules.

.DESCRIPTION
    This PowerShell module uses a detailed schema definition, loaded from an external .psd1 file,
    to validate a PoSh-Backup configuration object (hashtable). It provides functions to
    recursively validate the configuration against this schema.

    After generic schema validation, it dynamically discovers and invokes type-specific validation
    functions (e.g., 'Invoke-PoShBackupUNCTargetSettingsValidation') from the relevant target
    provider modules (e.g., UNC.Target.psm1) for each defined Backup Target instance.

    The validation process can help detect common configuration errors such as:
    - Typographical errors in setting names.
    - Incorrect data types for setting values.
    - Missing mandatory configuration settings.
    - Use of unsupported or invalid values for specific settings.
    - Incorrect structure or missing required fields in 'BackupTargets' definitions,
      with detailed checks for 'TargetSpecificSettings' now handled by the providers.
    - Incorrect structure or values for 'PostRunAction' and 'Checksum' settings.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.6.2 # Added explicit check for _PoShBackup_PSScriptRoot before target validation.
    DateCreated:    14-May-2025
    LastModified:   28-May-2025
    Purpose:        Optional advanced configuration validation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Schema file 'ConfigSchema.psd1' must exist in 'Modules\ConfigManagement\Assets\'.
                    Target provider modules (e.g., UNC.Target.psm1) must exist in 'Modules\Targets\'
                    and export their respective validation functions.
                    This module is typically invoked by 'ConfigManager.psm1' if schema validation is
                    enabled in the main PoSh-Backup configuration.
#>

#region --- Module-Scoped Schema Loading ---
# Load the schema from the external file.
# $PSScriptRoot for PoShBackupValidator.psm1 is Modules\
$Script:LoadedConfigSchema = $null
$schemaFilePath = Join-Path -Path $PSScriptRoot -ChildPath "ConfigManagement\Assets\ConfigSchema.psd1"

if (Test-Path -LiteralPath $schemaFilePath -PathType Leaf) {
    try {
        $Script:LoadedConfigSchema = Import-PowerShellDataFile -LiteralPath $schemaFilePath -ErrorAction Stop
        if ($null -eq $Script:LoadedConfigSchema -or -not ($Script:LoadedConfigSchema -is [hashtable]) -or $Script:LoadedConfigSchema.Count -eq 0) {
            Write-Error "[PoShBackupValidator.psm1] CRITICAL: Loaded schema from '$schemaFilePath' is null, not a hashtable, or empty. Advanced validation will fail."
            $Script:LoadedConfigSchema = $null # Ensure it's null if loading failed to produce valid content
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
#endregion

#region --- Private Validation Logic ---
function Test-SchemaRecursiveInternal {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject,
        [Parameter(Mandatory)]
        [hashtable]$Schema,
        [Parameter(Mandatory)]
        [ref]$ValidationMessages,
        [string]$CurrentPath = "Configuration"
    )

    if ($null -eq $Schema) {
        $ValidationMessages.Value.Add("Schema Error: The schema definition for path '$CurrentPath' is missing or invalid. Cannot perform validation for this part. This might indicate a problem with ConfigSchema.psd1.")
        return
    }

    if ($ConfigObject -isnot [hashtable] -and $Schema.Type -ne 'array' -and $Schema.Type -ne 'string_or_array' -and $Schema.Type -ne 'object') {
        $ValidationMessages.Value.Add("Configuration path '$CurrentPath' is expected to be a Hashtable (or match schema type), but found type '$($ConfigObject.GetType().Name)'.")
        return
    }

    foreach ($schemaKey in $Schema.Keys) {
        $keyDefinition = $Schema[$schemaKey]
        $fullKeyPath = "$CurrentPath.$schemaKey"

        if ($schemaKey -eq 'DynamicKeySchema') {
            if ($ConfigObject -isnot [hashtable]) {
                $ValidationMessages.Value.Add("Configuration path '$CurrentPath' (expected to contain dynamic keys) is not a Hashtable, but '$($ConfigObject.GetType().Name)'.")
                continue
            }
            $dynamicKeySubSchema = $keyDefinition
            foreach ($itemKeyInConfig in $ConfigObject.Keys) {
                $itemValueFromConfig = $ConfigObject[$itemKeyInConfig]
                if ($null -ne $dynamicKeySubSchema.Schema -and $dynamicKeySubSchema.Schema -is [hashtable]) {
                    Test-SchemaRecursiveInternal -ConfigObject $itemValueFromConfig -Schema $dynamicKeySubSchema.Schema -ValidationMessages $ValidationMessages -CurrentPath "$CurrentPath.$itemKeyInConfig"
                } else {
                    $ValidationMessages.Value.Add("Schema Error: DynamicKeySchema definition for '$CurrentPath' is missing or invalid in ConfigSchema.psd1.")
                }
            }
            continue
        }

        if (-not $ConfigObject.ContainsKey($schemaKey)) {
            if ($keyDefinition.Required -eq $true) {
                $ValidationMessages.Value.Add("Required configuration key '$fullKeyPath' is missing.")
            }
            continue
        }

        $configValue = $ConfigObject[$schemaKey]
        $expectedType = $keyDefinition.Type.ToLowerInvariant()
        $typeMatch = $false
        switch ($expectedType) {
            "string"           { if ($configValue -is [string]) { $typeMatch = $true } }
            "boolean"          { if ($configValue -is [bool]) { $typeMatch = $true } }
            "int"              { if ($configValue -is [int]) { $typeMatch = $true } }
            "hashtable"        { if ($configValue -is [hashtable]) { $typeMatch = $true } }
            "array"            { if ($configValue -is [array]) { $typeMatch = $true } }
            "string_or_array"  { if (($configValue -is [string]) -or ($configValue -is [array])) { $typeMatch = $true } }
            "object"           { $typeMatch = $true } # 'object' type means any type is allowed, specific validation might be handled by ValidateScript or target provider
            default            { $ValidationMessages.Value.Add("Schema Error: Unknown expected type '$($keyDefinition.Type)' defined in schema for '$fullKeyPath'. Contact script developer."); continue }
        }

        if (-not $typeMatch) {
            $ValidationMessages.Value.Add("Type mismatch for configuration key '$fullKeyPath'. Expected type '$($keyDefinition.Type)', but found type '$($configValue.GetType().Name)'.")
            continue
        }

        if ($keyDefinition.ContainsKey("AllowedValues")) {
            $valuesToCheckAgainstAllowed = @()
            if ($configValue -is [array] -and ($expectedType -eq 'string_or_array' -or $expectedType -eq 'array')){
                if ($keyDefinition.ContainsKey("ItemSchema") -and $keyDefinition.ItemSchema.ContainsKey("AllowedValues")) {
                    $valuesToCheckAgainstAllowed = $configValue
                } elseif (-not $keyDefinition.ContainsKey("ItemSchema")) {
                     $valuesToCheckAgainstAllowed = $configValue
                }
            } elseif ($configValue -is [string]) {
                $valuesToCheckAgainstAllowed = @($configValue)
            }

            if($valuesToCheckAgainstAllowed.Count -gt 0) {
                $allowedSchemaValues = if ($keyDefinition.ContainsKey("ItemSchema") -and $keyDefinition.ItemSchema.ContainsKey("AllowedValues")) {
                                           $keyDefinition.ItemSchema.AllowedValues
                                       } else {
                                           $keyDefinition.AllowedValues
                                       }
                $allowedSchemaValues = $allowedSchemaValues | ForEach-Object { $_.ToString().ToLowerInvariant() }

                foreach($valItemInConfig in $valuesToCheckAgainstAllowed){
                    if (($null -ne $valItemInConfig) -and ($valItemInConfig.ToString().ToLowerInvariant() -notin $allowedSchemaValues)) {
                        $ValidationMessages.Value.Add("Invalid value for configuration key '$fullKeyPath': '$valItemInConfig'. Allowed values (case-insensitive) are: $($allowedSchemaValues -join ', ').")
                    }
                }
            }
        }

        if ($expectedType -eq "array" -and $keyDefinition.ContainsKey("ItemSchema") -and -not $keyDefinition.ItemSchema.ContainsKey("AllowedValues")) {
            foreach ($arrayItem in $configValue) {
                $itemSchemaDef = $keyDefinition.ItemSchema
                $itemExpectedType = $itemSchemaDef.Type.ToLowerInvariant()
                $itemTypeMatch = $false
                switch ($itemExpectedType) {
                    "string" { if ($arrayItem -is [string] -and -not ([string]::IsNullOrWhiteSpace($arrayItem)) ) { $itemTypeMatch = $true } }
                    # Add other types as needed for array item validation
                }
                if (-not $itemTypeMatch) {
                    $ValidationMessages.Value.Add("Type mismatch for an item in array '$fullKeyPath'. Expected item type '$($itemSchemaDef.Type)', but found '$($arrayItem.GetType().Name)' or item is empty/whitespace.")
                }
            }
        }

        if ($expectedType -eq "int") {
            if ($keyDefinition.ContainsKey("Min") -and $configValue -lt $keyDefinition.Min) {
                $ValidationMessages.Value.Add("Value for configuration key '$fullKeyPath' ($configValue) is less than the minimum allowed value of $($keyDefinition.Min).")
            }
            if ($keyDefinition.ContainsKey("Max") -and $configValue -gt $keyDefinition.Max) {
                $ValidationMessages.Value.Add("Value for configuration key '$fullKeyPath' ($configValue) is greater than the maximum allowed value of $($keyDefinition.Max).")
            }
        }

        # Execute ValidateScript for keys other than BackupTargets (which is handled by specific validators now)
        if ($schemaKey -ne 'BackupTargets' -and $keyDefinition.ContainsKey("ValidateScript") -and $keyDefinition.ValidateScript -is [scriptblock]) {
            $scriptBlockFromPsd1 = $keyDefinition.ValidateScript
            try {
                $validationResult = Invoke-Command -ScriptBlock $scriptBlockFromPsd1 -ArgumentList $configValue
                if (-not $validationResult) {
                     $ValidationMessages.Value.Add("Custom validation failed for configuration key '$fullKeyPath' with value '$configValue'.")
                }
            } catch {
                 $ValidationMessages.Value.Add("Error executing custom validation script for '$fullKeyPath' on value '$configValue'. Error: $($_.Exception.Message)")
            }
        }

        # Check if the current key's definition specifies a DynamicKeySchema for its children
        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("DynamicKeySchema")) {
            $dynamicKeySubSchemaDefinition = $keyDefinition.DynamicKeySchema
            if ($null -ne $dynamicKeySubSchemaDefinition.Schema -and $dynamicKeySubSchemaDefinition.Schema -is [hashtable]) {
                foreach ($dynamicItemKeyInConfig in $configValue.Keys) {
                    $dynamicItemValueFromConfig = $configValue[$dynamicItemKeyInConfig]
                    Test-SchemaRecursiveInternal -ConfigObject $dynamicItemValueFromConfig -Schema $dynamicKeySubSchemaDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath.$dynamicItemKeyInConfig"
                }
            } else {
                $ValidationMessages.Value.Add("Schema Error: DynamicKeySchema.Schema definition for '$fullKeyPath' is missing or invalid in ConfigSchema.psd1.")
            }
        }
        # Else, if it's a regular nested hashtable with a direct "Schema"
        elseif ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema")) {
            if ($null -ne $keyDefinition.Schema -and $keyDefinition.Schema -is [hashtable]) {
                Test-SchemaRecursiveInternal -ConfigObject $configValue -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath"
            } else {
                $ValidationMessages.Value.Add("Schema Error: Sub-schema definition for '$fullKeyPath' is missing or invalid in ConfigSchema.psd1.")
            }
        }
    } # End foreach ($schemaKey in $Schema.Keys)

    # Check for unknown keys in the current ConfigObject, but only if it's not a level where dynamic keys are expected
    if ($ConfigObject -is [hashtable] -and (-not $Schema.ContainsKey('DynamicKeySchema'))) {
        foreach ($configKeyInObject in $ConfigObject.Keys) {
            if (-not $Schema.ContainsKey($configKeyInObject)) {
                if ($configKeyInObject -ne '_PoShBackup_PSScriptRoot') {
                     $ValidationMessages.Value.Add("Unknown configuration key '$CurrentPath.$configKeyInObject' found. This key is not defined in the schema. Check for typos or if it's a deprecated/unsupported setting.")
                }
            }
        }
    }
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
        [Parameter(Mandatory = $false)] # Logger is now optional for this top-level function
        [scriptblock]$Logger
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            & $Logger -Message $Message -Level $Level
        } # Else, no logging if logger not provided
    }
    # PSSA: Logger parameter used via $LocalWriteLog
    & $LocalWriteLog -Message "PoShBackupValidator/Invoke-PoShBackupConfigValidation: Initializing." -Level "DEBUG"


    if ($null -eq $Script:LoadedConfigSchema) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator cannot perform validation because the configuration schema (ConfigSchema.psd1) failed to load or was not found. Check previous errors from PoShBackupValidator.psm1 loading.")
        return
    }

    # Perform generic schema validation first
    Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:LoadedConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"

    # Perform target-specific validation by calling functions from target provider modules
    if ($ConfigurationToValidate.ContainsKey('BackupTargets') -and $ConfigurationToValidate.BackupTargets -is [hashtable]) {
        $mainScriptPSScriptRoot = $ConfigurationToValidate['_PoShBackup_PSScriptRoot'] 

        # NEW: Explicit check for _PoShBackup_PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($mainScriptPSScriptRoot)) {
            $ValidationMessagesListRef.Value.Add("CRITICAL (PoShBackupValidator): '_PoShBackup_PSScriptRoot' key is missing or empty in the configuration object. Cannot resolve paths for target provider modules. Target-specific validation skipped.")
            return # Cannot proceed with target validation without this.
        }
        if (-not (Test-Path -LiteralPath $mainScriptPSScriptRoot -PathType Container)) {
             $ValidationMessagesListRef.Value.Add("CRITICAL (PoShBackupValidator): '_PoShBackup_PSScriptRoot' path ('$mainScriptPSScriptRoot') does not exist or is not a directory. Cannot resolve paths for target provider modules. Target-specific validation skipped.")
            return
        }


        foreach ($targetName in $ConfigurationToValidate.BackupTargets.Keys) {
            $targetInstance = $ConfigurationToValidate.BackupTargets[$targetName]

            if (-not ($targetInstance -is [hashtable] -and
                      $targetInstance.ContainsKey('Type') -and $targetInstance.Type -is [string] -and
                      (-not ([string]::IsNullOrWhiteSpace($targetInstance.Type))) -and
                      $targetInstance.ContainsKey('TargetSpecificSettings'))) {
                & $LocalWriteLog -Message "PoShBackupValidator: Skipping specific validation for target '$targetName' due to missing Type or TargetSpecificSettings, or incorrect structure. Generic schema errors may apply." -Level "DEBUG"
                continue
            }

            $targetType = $targetInstance.Type
            $targetSettings = $targetInstance.TargetSpecificSettings
            $targetRemoteRetentionSettings = if ($targetInstance.ContainsKey('RemoteRetentionSettings')) { $targetInstance.RemoteRetentionSettings } else { $null } 
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
                    $validationParams = @{
                        TargetSpecificSettings  = $targetSettings
                        TargetInstanceName      = $targetName
                        ValidationMessagesListRef = $ValidationMessagesListRef
                    }
                    
                    if ($null -ne $targetRemoteRetentionSettings -and $validatorCmd.Parameters.ContainsKey('RemoteRetentionSettings')) {
                        $validationParams.RemoteRetentionSettings = $targetRemoteRetentionSettings
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
