# Modules\PoShBackupValidator\SchemaExecutionEngine.psm1
<#
.SYNOPSIS
    Sub-module for PoShBackupValidator. Contains the core recursive schema validation engine.
.DESCRIPTION
    This module houses the 'Test-SchemaRecursiveInternal' function, which is responsible
    for recursively traversing a configuration object and validating it against a
    provided schema definition.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Core recursive schema validation logic for PoShBackupValidator.
    Prerequisites:  PowerShell 5.1+.
#>

# No direct dependency on Utils.psm1 needed here if all logging is handled by the calling facade.

#region --- Internal Validation Logic (Exported for Facade Use) ---
function Test-SchemaRecursiveInternal {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject,
        [Parameter(Mandatory)]
        [hashtable]$Schema, # The specific part of the schema for the current object
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
        elseif ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema")) {
            if ($null -ne $keyDefinition.Schema -and $keyDefinition.Schema -is [hashtable]) {
                Test-SchemaRecursiveInternal -ConfigObject $configValue -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath"
            } else {
                $ValidationMessages.Value.Add("Schema Error: Sub-schema definition for '$fullKeyPath' is missing or invalid in ConfigSchema.psd1.")
            }
        }
    }

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

Export-ModuleMember -Function Test-SchemaRecursiveInternal
