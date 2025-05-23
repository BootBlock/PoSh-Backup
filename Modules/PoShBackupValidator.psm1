# Modules\PoShBackupValidator.psm1
<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    The schema is loaded from an external file: 'Modules\ConfigManagement\Assets\ConfigSchema.psd1'.
    This module now also handles detailed validation for specific Backup Target types.

.DESCRIPTION
    This PowerShell module uses a detailed schema definition, loaded from an external .psd1 file,
    to validate a PoSh-Backup configuration object (hashtable). It provides functions to
    recursively validate the configuration against this schema.

    After generic schema validation, it performs type-specific validation for each defined
    Backup Target instance (e.g., "UNC", "Replicate", "SFTP") using dedicated internal helper functions.

    The validation process can help detect common configuration errors such as:
    - Typographical errors in setting names.
    - Incorrect data types for setting values.
    - Missing mandatory configuration settings.
    - Use of unsupported or invalid values for specific settings.
    - Incorrect structure or missing required fields in 'BackupTargets' definitions,
      including detailed checks for 'TargetSpecificSettings' of known types.
    - Incorrect structure or values for 'PostRunAction' and 'Checksum' settings.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.2 # Removed ValidateScript handling for BackupTargets from Test-SchemaRecursiveInternal.
    DateCreated:    14-May-2025
    LastModified:   24-May-2025
    Purpose:        Optional advanced configuration validation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Schema file 'ConfigSchema.psd1' must exist in 'Modules\ConfigManagement\Assets\'.
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
        } else {
            # Optional: Log success at a verbose/debug level if a logger was available here,
            # but this module doesn't take a logger at module scope.
            # Write-Verbose "[PoShBackupValidator.psm1] Configuration schema loaded successfully from '$schemaFilePath'."
        }
    }
    catch {
        Write-Error "[PoShBackupValidator.psm1] CRITICAL: Failed to load or parse configuration schema from '$schemaFilePath'. Error: $($_.Exception.Message). Advanced validation will be unavailable or fail."
        $Script:LoadedConfigSchema = $null
    }
}
else {
    Write-Error "[PoShBackupValidator.psm1] CRITICAL: Configuration schema file not found at '$schemaFilePath'. Advanced validation will be unavailable."
    # $Script:LoadedConfigSchema remains $null
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
            "object"           { $typeMatch = $true } 
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
                # Simple ValidateScripts (like for SevenZipPath) usually take one $configValue argument.
                # If they need more, this invocation might need adjustment or the scriptblock itself needs to be robust.
                $validationResult = Invoke-Command -ScriptBlock $scriptBlockFromPsd1 -ArgumentList $configValue
                if (-not $validationResult) { # Assuming the script returns $true for pass, $false for fail
                     $ValidationMessages.Value.Add("Custom validation failed for configuration key '$fullKeyPath' with value '$configValue'.")
                }
            } catch {
                 $ValidationMessages.Value.Add("Error executing custom validation script for '$fullKeyPath' on value '$configValue'. Error: $($_.Exception.Message)")
            }
        }

        # ... (after ValidateScript logic for non-BackupTargets keys)

        # Check if the current key's definition specifies a DynamicKeySchema for its children
        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("DynamicKeySchema")) {
            $dynamicKeySubSchemaDefinition = $keyDefinition.DynamicKeySchema
            if ($null -ne $dynamicKeySubSchemaDefinition.Schema -and $dynamicKeySubSchemaDefinition.Schema -is [hashtable]) {
                # $configValue is the hashtable whose keys are dynamic (e.g., $Configuration.BackupTargets)
                # $dynamicKeySubSchemaDefinition.Schema is the schema to apply to each item within $configValue
                foreach ($dynamicItemKeyInConfig in $configValue.Keys) {
                    $dynamicItemValueFromConfig = $configValue[$dynamicItemKeyInConfig]
                    Test-SchemaRecursiveInternal -ConfigObject $dynamicItemValueFromConfig -Schema $dynamicKeySubSchemaDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath.$dynamicItemKeyInConfig"
                }
            } else {
                $ValidationMessages.Value.Add("Schema Error: DynamicKeySchema.Schema definition for '$fullKeyPath' is missing or invalid in ConfigSchema.psd1.")
            }
        }
        # Else, if it's a regular nested hashtable with a direct "Schema"
        elseif ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema")) { # Removed: (-not $keyDefinition.ContainsKey("DynamicKeySchema"))
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
                # Allow internal _PoShBackup_PSScriptRoot key without raising an error
                if ($configKeyInObject -ne '_PoShBackup_PSScriptRoot') { 
                     $ValidationMessages.Value.Add("Unknown configuration key '$CurrentPath.$configKeyInObject' found. This key is not defined in the schema. Check for typos or if it's a deprecated/unsupported setting.")
                }
            }
        }
    }
}
#endregion

#region --- Target-Specific Validation Helpers ---
# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Validate-UNCBackupTargetSettingsInternal] - Justification: Internal helper function for schema validation.
function Validate-UNCBackupTargetSettingsInternal {
    param(
        [object]$Settings,
        [string]$TargetInstanceName,
        [string]$FullPathToSettings, # e.g., Configuration.BackupTargets.MyUNC.TargetSpecificSettings
        [ref]$ValidationMessagesListRef
    )
    if (-not ($Settings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: UNC): 'TargetSpecificSettings' must be a Hashtable, but found type '$($Settings.GetType().Name)'. Path: '$FullPathToSettings'.")
        return
    }
    if (-not ($Settings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: UNC): 'TargetSpecificSettings' must be a Hashtable. Path: '$FullPathToSettings'.")
        return
    }
    if (-not $Settings.ContainsKey('UNCRemotePath') -or -not ($Settings.UNCRemotePath -is [string]) -or [string]::IsNullOrWhiteSpace($Settings.UNCRemotePath)) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: UNC): 'UNCRemotePath' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$FullPathToSettings.UNCRemotePath'.")
    }
    if ($Settings.ContainsKey('CreateJobNameSubdirectory') -and -not ($Settings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: UNC): 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$FullPathToSettings.CreateJobNameSubdirectory'.")
    }
}

# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Validate-ReplicateBackupTargetSettingsInternal] - Justification: Internal helper function for schema validation.
function Validate-ReplicateBackupTargetSettingsInternal {
    param(
        [object]$Settings, # Can be array
        [string]$TargetInstanceName,
        [string]$FullPathToSettings,
        [ref]$ValidationMessagesListRef
    )
    if (-not ($Settings -is [array])) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): 'TargetSpecificSettings' must be an Array of destination configurations. Path: '$FullPathToSettings'.")
        return
    }
    if ($Settings.Count -eq 0) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$FullPathToSettings'.")
    }
    for ($i = 0; $i -lt $Settings.Count; $i++) {
        $destConfig = $Settings[$i]; $destConfigPath = "$FullPathToSettings[$i]"
        if (-not ($destConfig -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'.")
            continue
        }
        if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): Destination at index $i is missing 'Path', or it's not a non-empty string. Path: '$destConfigPath.Path'.")
        }
        if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): Destination at index $i 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined. Path: '$destConfigPath.CreateJobNameSubdirectory'.")
        }
        if ($destConfig.ContainsKey('RetentionSettings')) {
            if (-not ($destConfig.RetentionSettings -is [hashtable])) {
                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): Destination at index $i 'RetentionSettings' must be a Hashtable if defined. Path: '$destConfigPath.RetentionSettings'.")
            }
            elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount')) {
                if (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0) {
                    $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: Replicate): Destination at index $i 'RetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$destConfigPath.RetentionSettings.KeepCount'.")
                }
            }
        }
    }
}

# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Validate-SFTPBackupTargetSettingsInternal] - Justification: Internal helper function for schema validation.
function Validate-SFTPBackupTargetSettingsInternal {
    param(
        [object]$Settings,
        [string]$TargetInstanceName,
        [string]$FullPathToSettings,
        [ref]$ValidationMessagesListRef
    )
    if (-not ($Settings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: SFTP): 'TargetSpecificSettings' must be a Hashtable, but found type '$($Settings.GetType().Name)'. Path: '$FullPathToSettings'.")
        return
    }
    foreach ($sftpKey in @('SFTPServerAddress', 'SFTPRemotePath', 'SFTPUserName')) {
        if (-not $Settings.ContainsKey($sftpKey) -or -not ($Settings.$sftpKey -is [string]) -or [string]::IsNullOrWhiteSpace($Settings.$sftpKey)) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: SFTP): '$sftpKey' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$FullPathToSettings.$sftpKey'.")
        }
    }
    if ($Settings.ContainsKey('SFTPPort') -and -not ($Settings.SFTPPort -is [int] -and $Settings.SFTPPort -gt 0 -and $Settings.SFTPPort -le 65535)) {
        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: SFTP): 'SFTPPort' in 'TargetSpecificSettings' must be an integer between 1 and 65535 if defined. Path: '$FullPathToSettings.SFTPPort'.")
    }
    foreach ($sftpOptionalStringKey in @('SFTPPasswordSecretName', 'SFTPKeyFileSecretName', 'SFTPKeyFilePassphraseSecretName')) {
        if ($Settings.ContainsKey($sftpOptionalStringKey) -and (-not ($Settings.$sftpOptionalStringKey -is [string]) -or [string]::IsNullOrWhiteSpace($Settings.$sftpOptionalStringKey)) ) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: SFTP): '$sftpOptionalStringKey' in 'TargetSpecificSettings' must be a non-empty string if defined. Path: '$FullPathToSettings.$sftpOptionalStringKey'.")
        }
    }
    foreach ($sftpOptionalBoolKey in @('CreateJobNameSubdirectory', 'SkipHostKeyCheck')) {
        if ($Settings.ContainsKey($sftpOptionalBoolKey) -and -not ($Settings.$sftpOptionalBoolKey -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$TargetInstanceName' (Type: SFTP): '$sftpOptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$FullPathToSettings.$sftpOptionalBoolKey'.")
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
        [ref]$ValidationMessagesListRef
    )

    if ($null -eq $Script:LoadedConfigSchema) {
        $ValidationMessagesListRef.Value.Add("CRITICAL: PoShBackupValidator cannot perform validation because the configuration schema (ConfigSchema.psd1) failed to load or was not found. Check previous errors from PoShBackupValidator.psm1 loading.")
        return
    }

    # Perform generic schema validation first
    Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:LoadedConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"

    # Perform target-specific validation for BackupTargets
    if ($ConfigurationToValidate.ContainsKey('BackupTargets') -and $ConfigurationToValidate.BackupTargets -is [hashtable]) {
        foreach ($targetName in $ConfigurationToValidate.BackupTargets.Keys) {
            $targetInstance = $ConfigurationToValidate.BackupTargets[$targetName]

            # Generic schema validation (Test-SchemaRecursiveInternal) should have already ensured:
            # - $targetInstance is a hashtable.
            # - $targetInstance.Type is a string.
            # - $targetInstance.TargetSpecificSettings exists and is an object (hashtable or array).
            # So, we can proceed with type-specific validation if these basic checks passed.
            
            if ($targetInstance -is [hashtable] -and 
                $targetInstance.ContainsKey('Type') -and $targetInstance.Type -is [string] -and 
                (-not ([string]::IsNullOrWhiteSpace($targetInstance.Type))) -and # Ensure Type is not empty string
                $targetInstance.ContainsKey('TargetSpecificSettings')) { 

                $targetType = $targetInstance.Type.ToUpperInvariant()
                $targetSettings = $targetInstance.TargetSpecificSettings 
                $currentPathToTargetSettings = "Configuration.BackupTargets.$targetName.TargetSpecificSettings"
                $currentPathToTargetInstance = "Configuration.BackupTargets.$targetName"

                switch ($targetType) {
                    "UNC" {
                        Validate-UNCBackupTargetSettingsInternal -Settings $targetSettings -TargetInstanceName $targetName -FullPathToSettings $currentPathToTargetSettings -ValidationMessagesListRef $ValidationMessagesListRef
                    }
                    "REPLICATE" {
                        Validate-ReplicateBackupTargetSettingsInternal -Settings $targetSettings -TargetInstanceName $targetName -FullPathToSettings $currentPathToTargetSettings -ValidationMessagesListRef $ValidationMessagesListRef
                    }
                    "SFTP" {
                        Validate-SFTPBackupTargetSettingsInternal -Settings $targetSettings -TargetInstanceName $targetName -FullPathToSettings $currentPathToTargetSettings -ValidationMessagesListRef $ValidationMessagesListRef
                        # Validate RemoteRetentionSettings for SFTP (as it was in the old schema's ValidateScript)
                        if ($targetInstance.ContainsKey('RemoteRetentionSettings')) {
                            $retentionSettings = $targetInstance.RemoteRetentionSettings
                            $retentionPath = "$currentPathToTargetInstance.RemoteRetentionSettings"
                            # Schema ensures RemoteRetentionSettings is a hashtable if it exists.
                            if ($retentionSettings -is [hashtable] -and $retentionSettings.ContainsKey('KeepCount')) {
                                if (-not ($retentionSettings.KeepCount -is [int]) -or $retentionSettings.KeepCount -le 0) {
                                    $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetName' (Type: SFTP): 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$retentionPath.KeepCount'.")
                                }
                            }
                        }
                    }
                    default {
                        # This message is for types that are valid strings but not one of the known, specifically handled types.
                        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetName' has a Type: '$($targetInstance.Type)' for which no specific validation rules are defined in PoShBackupValidator.psm1. Generic schema validation still applies. Path: '$currentPathToTargetInstance.Type'.")
                    }
                }
            }
            # If $targetInstance is not a hashtable, or missing Type (or Type not string/empty), or missing TargetSpecificSettings,
            # Test-SchemaRecursiveInternal (based on ConfigSchema.psd1's DynamicKeySchema for BackupTargets)
            # should have already added relevant error messages to $ValidationMessagesListRef.
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
