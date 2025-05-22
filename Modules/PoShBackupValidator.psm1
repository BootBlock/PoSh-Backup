<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    Includes schema validation for "UNC" and "Replicate" Backup Target configurations.

.DESCRIPTION
    This PowerShell module contains a detailed schema definition that mirrors the expected structure
    of a PoSh-Backup configuration file (Default.psd1 / User.psd1). It provides functions to
    recursively validate a loaded configuration object (hashtable) against this internal schema.

    The validation process can help detect common configuration errors such as:
    - Typographical errors in setting names.
    - Incorrect data types for setting values (e.g., string instead of integer).
    - Missing mandatory configuration settings.
    - Use of unsupported or invalid values for specific settings.
    - Incorrect structure or missing required fields in 'BackupTargets' definitions,
      including for UNC targets ('CreateJobNameSubdirectory') and "Replicate"
      target type (validating its array of destination settings). The base 'TargetSpecificSettings'
      type is 'object' to allow flexibility, with type-specific validation in a ValidateScript.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.3 # Confirmed TargetSpecificSettings base type as 'object' for provider flexibility.
    DateCreated:    14-May-2025
    LastModified:   19-May-2025
    Purpose:        Optional advanced configuration validation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    This module is typically invoked by 'ConfigManager.psm1' if schema validation is
                    enabled in the main PoSh-Backup configuration.
#>

#region --- Module-Scoped Schema Definition ---
# This extensive hashtable defines the expected structure and constraints for the PoSh-Backup configuration.
# It is used by the validation functions to check the integrity of a loaded configuration.
$Script:PoShBackup_ConfigSchema = @{
    # Top-level global settings
    SevenZipPath                    = @{ Type = 'string'; Required = $true; ValidateScript = { Test-Path -LiteralPath $_ -PathType Leaf } } # Must be a valid file path if not empty (auto-detection handles empty)
    DefaultDestinationDir           = @{ Type = 'string'; Required = $false } # Optional, jobs can override
    DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false } # New global setting
    HideSevenZipOutput              = @{ Type = 'boolean'; Required = $false }
    PauseBeforeExit                 = @{ Type = 'string'; Required = $false; AllowedValues = @("Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", "True", "False") } # Case-insensitive check for these values
    EnableAdvancedSchemaValidation  = @{ Type = 'boolean'; Required = $false } # Controls if this validator module is used
    TreatSevenZipWarningsAsSuccess  = @{ Type = 'boolean'; Required = $false } 
    RetentionConfirmDelete          = @{ Type = 'boolean'; Required = $false } # New global setting for retention confirmation
    EnableFileLogging               = @{ Type = 'boolean'; Required = $false }
    LogDirectory                    = @{ Type = 'string'; Required = $false } 
    ReportGeneratorType             = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") } # Can be single string or array of these
    
    # Report directory settings (global defaults)
    HtmlReportDirectory             = @{ Type = 'string'; Required = $false }
    CsvReportDirectory              = @{ Type = 'string'; Required = $false }
    JsonReportDirectory             = @{ Type = 'string'; Required = $false }
    XmlReportDirectory              = @{ Type = 'string'; Required = $false }
    TxtReportDirectory              = @{ Type = 'string'; Required = $false }
    MdReportDirectory               = @{ Type = 'string'; Required = $false }

    # HTML report specific settings (global defaults)
    HtmlReportTitlePrefix           = @{ Type = 'string'; Required = $false }
    HtmlReportLogoPath              = @{ Type = 'string'; Required = $false } # Path to a logo file
    HtmlReportFaviconPath           = @{ Type = 'string'; Required = $false } 
    HtmlReportCustomCssPath         = @{ Type = 'string'; Required = $false } # Path to a custom CSS file
    HtmlReportCompanyName           = @{ Type = 'string'; Required = $false }
    HtmlReportTheme                 = @{ Type = 'string'; Required = $false } # Name of a theme CSS file (e.g., "Dark", "Light")
    HtmlReportOverrideCssVariables  = @{ Type = 'hashtable'; Required = $false } # For overriding theme CSS variables
    HtmlReportShowSummary           = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowConfiguration     = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowHooks             = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowLogEntries        = @{ Type = 'boolean'; Required = $false }

    # VSS settings (global defaults)
    EnableVSS                       = @{ Type = 'boolean'; Required = $false }
    DefaultVSSContextOption         = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
    VSSMetadataCachePath            = @{ Type = 'string'; Required = $false } # Path string, environment variables are expanded by Utils.psm1
    VSSPollingTimeoutSeconds        = @{ Type = 'int'; Required = $false; Min = 1; Max = 3600 } # Reasonable timeout range
    VSSPollingIntervalSeconds       = @{ Type = 'int'; Required = $false; Min = 1; Max = 600 }  # Reasonable polling interval

    # Retry mechanism settings (global defaults)
    EnableRetries                   = @{ Type = 'boolean'; Required = $false }
    MaxRetryAttempts                = @{ Type = 'int'; Required = $false; Min = 0 } # 0 means one attempt, no retries
    RetryDelaySeconds               = @{ Type = 'int'; Required = $false; Min = 0 }

    # 7-Zip process priority (global default)
    DefaultSevenZipProcessPriority  = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
    
    # Destination free space check (global defaults)
    MinimumRequiredFreeSpaceGB      = @{ Type = 'int'; Required = $false; Min = 0 } # 0 disables the check
    ExitOnLowSpaceIfBelowMinimum    = @{ Type = 'boolean'; Required = $false }

    # Archive integrity test (global default)
    DefaultTestArchiveAfterCreation = @{ Type = 'boolean'; Required = $false }

    # Archive filename settings (global defaults)
    DefaultArchiveDateFormat        = @{ Type = 'string'; Required = $false } # Valid .NET date format string
    
    # 7-Zip parameter defaults (global)
    DefaultThreadCount              = @{ Type = 'int'; Required = $false; Min = 0 } # 0 for 7-Zip auto
    DefaultArchiveType              = @{ Type = 'string'; Required = $false } # e.g., "-t7z", "-tzip"
    DefaultArchiveExtension         = @{ Type = 'string'; Required = $false } # e.g., ".7z", ".zip"
    DefaultCompressionLevel         = @{ Type = 'string'; Required = $false } # e.g., "-mx=7"
    DefaultCompressionMethod        = @{ Type = 'string'; Required = $false } # e.g., "-m0=LZMA2"
    DefaultDictionarySize           = @{ Type = 'string'; Required = $false } # e.g., "-md=128m"
    DefaultWordSize                 = @{ Type = 'string'; Required = $false } # e.g., "-mfb=64"
    DefaultSolidBlockSize           = @{ Type = 'string'; Required = $false } # e.g., "-ms=16g"
    DefaultCompressOpenFiles        = @{ Type = 'boolean'; Required = $false } # For -ssw switch
    DefaultScriptExcludeRecycleBin  = @{ Type = 'string'; Required = $false } # Exclusion string for 7-Zip
    DefaultScriptExcludeSysVolInfo  = @{ Type = 'string'; Required = $false } # Exclusion string for 7-Zip
    
    _PoShBackup_PSScriptRoot        = @{ Type = 'string'; Required = $false } # Internal: Added by main script, not user-configurable

    # --- NEW: Definition for 'BackupTargets' global hashtable ---
    BackupTargets = @{
        Type = 'hashtable'      # BackupTargets itself is a hashtable
        Required = $false       # Optional; if not present, no remote targets can be used.
        DynamicKeySchema = @{   # Schema for each named target instance (e.g., "MyUNC", "MyS3Bucket")
            Type = "hashtable"  # Each target instance is a hashtable
            Required = $true    # If a target instance is defined, it must have content.
            Schema = @{         # Schema for the keys within a single target instance
                Type = @{ Type = 'string'; Required = $true } # E.g., "UNC", "FTP", "S3"
                TargetSpecificSettings = @{ Type = 'object'; Required = $true } # Allow any object type, ValidateScript will handle specifics
                CredentialsSecretName  = @{ Type = 'string'; Required = $false } # Optional common setting for targets needing auth
                RemoteRetentionSettings= @{ Type = 'hashtable'; Required = $false } # Optional provider-specific retention
            }
        }
        # Custom validation for known target types within TargetSpecificSettings
        ValidateScript = {
            param($BackupTargetsHashtable, [ref]$ValidationMessagesListRef, [string]$CurrentPathForTarget) 
            $isValidOverall = $true
            foreach ($targetInstanceNameKey in $BackupTargetsHashtable.Keys) {
                $targetInstanceValue = $BackupTargetsHashtable[$targetInstanceNameKey]
                if ($targetInstanceValue -is [hashtable] -and $targetInstanceValue.ContainsKey('Type') -and $targetInstanceValue.Type -is [string] -and $targetInstanceValue.ContainsKey('TargetSpecificSettings')) {
                    $instanceType = $targetInstanceValue.Type.ToUpperInvariant()
                    $instanceSettings = $targetInstanceValue.TargetSpecificSettings
                    $instancePath = "$CurrentPathForTarget.$targetInstanceNameKey.TargetSpecificSettings" # Base path for settings of this instance

                    if ($instanceType -eq "UNC") {
                        if (-not ($instanceSettings -is [hashtable])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'TargetSpecificSettings' must be a Hashtable. Path: '$instancePath'.")
                            $isValidOverall = $false
                            continue # Skip further checks for this malformed UNC instance
                        }
                        if (-not $instanceSettings.ContainsKey('UNCRemotePath') -or -not ($instanceSettings.UNCRemotePath -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.UNCRemotePath)) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'UNCRemotePath' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$instancePath.UNCRemotePath'.")
                            $isValidOverall = $false
                        }
                        if ($instanceSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($instanceSettings.CreateJobNameSubdirectory -is [boolean])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$instancePath.CreateJobNameSubdirectory'.")
                            $isValidOverall = $false
                        }
                    } elseif ($instanceType -eq "REPLICATE") { # VALIDATION FOR REPLICATE TYPE
                        if (-not ($instanceSettings -is [array])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): 'TargetSpecificSettings' must be an Array of destination configurations. Path: '$instancePath'.")
                            $isValidOverall = $false
                            continue # Skip further checks for this malformed Replicate instance
                        }
                        if ($instanceSettings.Count -eq 0) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$instancePath'.")
                            $isValidOverall = $false
                        }
                        for ($i = 0; $i -lt $instanceSettings.Count; $i++) {
                            $destConfig = $instanceSettings[$i]
                            $destConfigPath = "$instancePath[$i]" # Path to the current destination config in the array
                            if (-not ($destConfig -is [hashtable])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'.")
                                $isValidOverall = $false; continue # Move to next item in array
                            }
                            # Validate 'Path' for each destination
                            if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i is missing 'Path', or it's not a non-empty string. Path: '$destConfigPath.Path'.")
                                $isValidOverall = $false
                            }
                            # Validate 'CreateJobNameSubdirectory' for each destination (optional boolean)
                            if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined. Path: '$destConfigPath.CreateJobNameSubdirectory'.")
                                $isValidOverall = $false
                            }
                            # Validate 'RetentionSettings' for each destination (optional hashtable)
                            if ($destConfig.ContainsKey('RetentionSettings')) {
                                if (-not ($destConfig.RetentionSettings -is [hashtable])) {
                                    $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings' must be a Hashtable if defined. Path: '$destConfigPath.RetentionSettings'.")
                                    $isValidOverall = $false
                                } elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount')) { # If RetentionSettings is a hashtable, check KeepCount
                                    if (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0) {
                                        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$destConfigPath.RetentionSettings.KeepCount'.")
                                        $isValidOverall = $false
                                    }
                                }
                            }
                        }
                    }
                    # Add 'elseif ($instanceType -eq "OTHER_TYPE") { # Add validation for other known types here }'
                }
            }
            return $isValidOverall 
        }
    }

    # Definition for the 'BackupLocations' hashtable (individual backup jobs)
    BackupLocations = @{
        Type = 'hashtable' 
        Required = $true   
        DynamicKeySchema = @{ # Schema for each individual job definition (dynamic key is the job name)
            Type = "hashtable"
            Required = $true
            Schema = @{ 
                Path                    = @{ Type = 'string_or_array'; Required = $true } 
                Name                    = @{ Type = 'string'; Required = $true }        
                DestinationDir          = @{ Type = 'string'; Required = $false }       
                LocalRetentionCount     = @{ Type = 'int'; Required = $false; Min = 0 } # RENAMED from RetentionCount
                TargetNames             = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } } # NEW: Array of strings
                DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false } # NEW: Job-specific override
                DeleteToRecycleBin      = @{ Type = 'boolean'; Required = $false }
                RetentionConfirmDelete  = @{ Type = 'boolean'; Required = $false }      
                
                ArchivePasswordMethod   = @{ Type = 'string'; Required = $false; AllowedValues = @("NONE", "INTERACTIVE", "SECRETMANAGEMENT", "SECURESTRINGFILE", "PLAINTEXT") }
                CredentialUserNameHint  = @{ Type = 'string'; Required = $false }
                ArchivePasswordSecretName = @{ Type = 'string'; Required = $false } 
                ArchivePasswordVaultName  = @{ Type = 'string'; Required = $false } 
                ArchivePasswordSecureStringPath = @{ Type = 'string'; Required = $false } 
                ArchivePasswordPlainText  = @{ Type = 'string'; Required = $false }     
                UsePassword             = @{ Type = 'boolean'; Required = $false }      

                EnableVSS               = @{ Type = 'boolean'; Required = $false }
                VSSContextOption        = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
                SevenZipProcessPriority = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
                ReportGeneratorType     = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") } 
                TreatSevenZipWarningsAsSuccess = @{ Type = 'boolean'; Required = $false } 
                
                HtmlReportDirectory     = @{ Type = 'string'; Required = $false }
                CsvReportDirectory      = @{ Type = 'string'; Required = $false }
                JsonReportDirectory     = @{ Type = 'string'; Required = $false }
                XmlReportDirectory      = @{ Type = 'string'; Required = $false }
                TxtReportDirectory      = @{ Type = 'string'; Required = $false }
                MdReportDirectory       = @{ Type = 'string'; Required = $false }

                ArchiveType             = @{ Type = 'string'; Required = $false }
                ArchiveExtension        = @{ Type = 'string'; Required = $false } 
                ArchiveDateFormat       = @{ Type = 'string'; Required = $false } 
                ThreadsToUse            = @{ Type = 'int'; Required = $false; Min = 0 } 
                CompressionLevel        = @{ Type = 'string'; Required = $false }
                CompressionMethod       = @{ Type = 'string'; Required = $false }
                DictionarySize          = @{ Type = 'string'; Required = $false }
                WordSize                = @{ Type = 'string'; Required = $false }
                SolidBlockSize          = @{ Type = 'string'; Required = $false }
                CompressOpenFiles       = @{ Type = 'boolean'; Required = $false }
                AdditionalExclusions    = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'} }

                MinimumRequiredFreeSpaceGB   = @{ Type = 'int'; Required = $false; Min = 0 }
                ExitOnLowSpaceIfBelowMinimum = @{ Type = 'boolean'; Required = $false }
                TestArchiveAfterCreation     = @{ Type = 'boolean'; Required = $false }

                HtmlReportTheme              = @{ Type = 'string'; Required = $false }
                HtmlReportTitlePrefix        = @{ Type = 'string'; Required = $false }
                HtmlReportLogoPath           = @{ Type = 'string'; Required = $false }
                HtmlReportFaviconPath        = @{ Type = 'string'; Required = $false } 
                HtmlReportCustomCssPath      = @{ Type = 'string'; Required = $false }
                HtmlReportCompanyName        = @{ Type = 'string'; Required = $false }
                HtmlReportOverrideCssVariables = @{ Type = 'hashtable'; Required = $false }
                HtmlReportShowSummary        = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowConfiguration  = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowHooks          = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowLogEntries     = @{ Type = 'boolean'; Required = $false }

                PreBackupScriptPath          = @{ Type = 'string'; Required = $false } 
                PostBackupScriptOnSuccessPath= @{ Type = 'string'; Required = $false }
                PostBackupScriptOnFailurePath= @{ Type = 'string'; Required = $false }
                PostBackupScriptAlwaysPath   = @{ Type = 'string'; Required = $false }
            }
        }
    }

    BackupSets = @{
        Type = 'hashtable' 
        Required = $false  
        DynamicKeySchema = @{ 
            Type = "hashtable"
            Required = $true
            Schema = @{ 
                JobNames     = @{ Type = 'array'; Required = $true; ItemSchema = @{ Type = 'string'} }
                OnErrorInJob = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") } 
            }
        }
    }
}
#endregion

#region --- Private Validation Logic ---
# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Validate-AgainstSchemaRecursiveInternal] - 'Validate' is descriptive for this internal schema helper.
function Validate-AgainstSchemaRecursiveInternal { 
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject, 
        [Parameter(Mandatory)]
        [hashtable]$Schema,    
        [Parameter(Mandatory)]
        [ref]$ValidationMessages, 
        [string]$CurrentPath = "Configuration" 
    )

    if ($ConfigObject -isnot [hashtable] -and $Schema.Type -ne 'array') { 
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
                Validate-AgainstSchemaRecursiveInternal -ConfigObject $itemValueFromConfig -Schema $dynamicKeySubSchema.Schema -ValidationMessages $ValidationMessages -CurrentPath "$CurrentPath.$itemKeyInConfig"
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
            "object"           { $typeMatch = $true } # For 'object' type, we assume type match and let ValidateScript handle specifics
            default            { $ValidationMessages.Value.Add("Schema Error: Unknown expected type '$($keyDefinition.Type)' defined in schema for '$fullKeyPath'. Contact script developer."); continue }
        }

        if (-not $typeMatch) {
            $ValidationMessages.Value.Add("Type mismatch for configuration key '$fullKeyPath'. Expected type '$($keyDefinition.Type)', but found type '$($configValue.GetType().Name)'.")
            continue 
        }

        if ($keyDefinition.ContainsKey("AllowedValues")) {
            $valuesToCheckAgainstAllowed = @()
            if ($configValue -is [array] -and ($expectedType -eq 'string_or_array' -or $expectedType -eq 'array')){ 
                $valuesToCheckAgainstAllowed = $configValue 
            } elseif ($configValue -is [string]) { 
                $valuesToCheckAgainstAllowed = @($configValue)
            }

            if($valuesToCheckAgainstAllowed.Count -gt 0) {
                $allowedSchemaValues = $keyDefinition.AllowedValues | ForEach-Object { $_.ToString().ToLowerInvariant() } 
                foreach($valItemInConfig in $valuesToCheckAgainstAllowed){
                    if (($null -ne $valItemInConfig) -and ($valItemInConfig.ToString().ToLowerInvariant() -notin $allowedSchemaValues)) {
                        $ValidationMessages.Value.Add("Invalid value for configuration key '$fullKeyPath': '$valItemInConfig'. Allowed values (case-insensitive) are: $($keyDefinition.AllowedValues -join ', ').")
                    }
                }
            }
        }
        
        if ($expectedType -eq "array" -and $keyDefinition.ContainsKey("ItemSchema")) {
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

        if ($keyDefinition.ContainsKey("ValidateScript") -and $keyDefinition.ValidateScript -is [scriptblock]) {
            if (-not ([string]::IsNullOrWhiteSpace($configValue)) -or ($configValue -is [hashtable]) -or ($configValue -is [array]) ) { 
                try {
                    if ($keyDefinition.Type -eq 'hashtable' -and $schemaKey -eq 'BackupTargets') { 
                        if (-not (& $keyDefinition.ValidateScript $configValue $ValidationMessages "$fullKeyPath")) {
                            # Validation script should add messages directly.
                        }
                    } elseif ($keyDefinition.Type -eq 'object' -and $schemaKey -eq 'TargetSpecificSettings') { 
                        # This case might not be needed if ValidateScript for BackupTargets handles everything.
                        # However, if we wanted a specific ValidateScript AT the TargetSpecificSettings level (which we don't currently have),
                        # it would go here. The current ValidateScript is on BackupTargets itself.
                    } elseif (-not (& $keyDefinition.ValidateScript $configValue)) {
                        $ValidationMessages.Value.Add("Custom validation failed for configuration key '$fullKeyPath' with value '$configValue'. Check constraints (e.g., path existence for SevenZipPath).")
                    }
                } catch {
                     $ValidationMessages.Value.Add("Error executing custom validation script for '$fullKeyPath' on value '$configValue'. Error: $($_.Exception.Message)")
                }
            }
        }

        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema") -and (-not $keyDefinition.ContainsKey("DynamicKeySchema"))) {
            Validate-AgainstSchemaRecursiveInternal -ConfigObject $configValue -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath"
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

#region --- Exported Functions ---
function Invoke-PoShBackupConfigValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigurationToValidate,
        [Parameter(Mandatory)]
        [ref]$ValidationMessagesListRef 
    )
    Validate-AgainstSchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:PoShBackup_ConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
