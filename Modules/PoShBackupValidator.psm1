<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.

.DESCRIPTION
    This PowerShell module contains a detailed schema definition that mirrors the expected structure
    of a PoSh-Backup configuration file (Default.psd1 / User.psd1). It provides functions to
    recursively validate a loaded configuration object (hashtable) against this internal schema.

    The validation process can help detect common configuration errors such as:
    - Typographical errors in setting names.
    - Incorrect data types for setting values (e.g., string instead of integer).
    - Missing mandatory configuration settings.
    - Use of unsupported or invalid values for specific settings (e.g., an unrecognised VSS context option).

    This module is intended to be optionally enabled via the 'EnableAdvancedSchemaValidation' setting
    within the main PoSh-Backup configuration file. If enabled, the 'Import-AppConfiguration' function
    in 'ConfigManager.psm1' will invoke the validation process.

    The schema itself ($Script:PoShBackup_ConfigSchema) defines properties for each configuration key, including:
    - 'Type': Expected data type (e.g., 'string', 'boolean', 'int', 'hashtable', 'array', 'string_or_array').
    - 'Required': A boolean indicating if the key must be present.
    - 'AllowedValues': An array of permissible string values (case-insensitive) for a key.
    - 'Min'/'Max': For integer types, defines the minimum and maximum allowed values.
    - 'ValidateScript': A scriptblock for custom validation logic (e.g., checking if a path exists for 'SevenZipPath').
    - 'Schema': For 'hashtable' types that have nested structures (like 'BackupLocations' or 'BackupSets'),
      this contains a sub-schema for those nested items.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.3 # Added RetentionConfirmDelete to schema.
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

    # Definition for the 'BackupLocations' hashtable (individual backup jobs)
    BackupLocations = @{
        Type = 'hashtable' # Each job is a key in this hashtable
        Required = $true   # At least one job should typically be defined for the script to be useful
        Schema = @{ # Schema for each individual job definition
            Path                    = @{ Type = 'string_or_array'; Required = $true } # Source path(s)
            Name                    = @{ Type = 'string'; Required = $true }          # Base archive name
            DestinationDir          = @{ Type = 'string'; Required = $false }         # Job-specific destination
            RetentionCount          = @{ Type = 'int'; Required = $false; Min = 0 }   # Job-specific retention
            DeleteToRecycleBin      = @{ Type = 'boolean'; Required = $false }
            RetentionConfirmDelete  = @{ Type = 'boolean'; Required = $false }      # Job-level retention confirmation
            
            # Job-specific password settings
            ArchivePasswordMethod   = @{ Type = 'string'; Required = $false; AllowedValues = @("NONE", "INTERACTIVE", "SECRETMANAGEMENT", "SECURESTRINGFILE", "PLAINTEXT") }
            CredentialUserNameHint  = @{ Type = 'string'; Required = $false }
            ArchivePasswordSecretName = @{ Type = 'string'; Required = $false } 
            ArchivePasswordVaultName  = @{ Type = 'string'; Required = $false } 
            ArchivePasswordSecureStringPath = @{ Type = 'string'; Required = $false } # Path to .clixml
            ArchivePasswordPlainText  = @{ Type = 'string'; Required = $false }     # Highly discouraged
            UsePassword             = @{ Type = 'boolean'; Required = $false }      # Legacy password toggle

            # Job-specific operational settings
            EnableVSS               = @{ Type = 'boolean'; Required = $false }
            VSSContextOption        = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
            SevenZipProcessPriority = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
            ReportGeneratorType     = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") } 
            TreatSevenZipWarningsAsSuccess = @{ Type = 'boolean'; Required = $false } 
            
            # Job-specific report directory overrides
            HtmlReportDirectory     = @{ Type = 'string'; Required = $false }
            CsvReportDirectory      = @{ Type = 'string'; Required = $false }
            JsonReportDirectory             = @{ Type = 'string'; Required = $false }
            XmlReportDirectory              = @{ Type = 'string'; Required = $false }
            TxtReportDirectory              = @{ Type = 'string'; Required = $false }
            MdReportDirectory               = @{ Type = 'string'; Required = $false }

            # Job-specific 7-Zip and archive settings
            ArchiveType             = @{ Type = 'string'; Required = $false }
            ArchiveExtension        = @{ Type = 'string'; Required = $false } # Should start with '.'
            ArchiveDateFormat       = @{ Type = 'string'; Required = $false } # .NET date format
            ThreadsToUse            = @{ Type = 'int'; Required = $false; Min = 0 } # 0 for 7-Zip auto
            CompressionLevel        = @{ Type = 'string'; Required = $false }
            CompressionMethod       = @{ Type = 'string'; Required = $false }
            DictionarySize          = @{ Type = 'string'; Required = $false }
            WordSize                = @{ Type = 'string'; Required = $false }
            SolidBlockSize          = @{ Type = 'string'; Required = $false }
            CompressOpenFiles       = @{ Type = 'boolean'; Required = $false }
            AdditionalExclusions    = @{ Type = 'array'; Required = $false } # Array of 7-Zip exclusion strings

            # Job-specific resource and testing settings
            MinimumRequiredFreeSpaceGB   = @{ Type = 'int'; Required = $false; Min = 0 }
            ExitOnLowSpaceIfBelowMinimum = @{ Type = 'boolean'; Required = $false }
            TestArchiveAfterCreation     = @{ Type = 'boolean'; Required = $false }

            # Job-specific HTML report customisation
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

            # Job-specific hook script paths
            PreBackupScriptPath          = @{ Type = 'string'; Required = $false } # Path to a .ps1 file
            PostBackupScriptOnSuccessPath= @{ Type = 'string'; Required = $false }
            PostBackupScriptOnFailurePath= @{ Type = 'string'; Required = $false }
            PostBackupScriptAlwaysPath   = @{ Type = 'string'; Required = $false }
        }
    }
    # Definition for 'BackupSets' hashtable
    BackupSets = @{
        Type = 'hashtable' # Each set is a key in this hashtable
        Required = $false  # Backup sets are optional
        Schema = @{ # Schema for each individual set definition
            JobNames     = @{ Type = 'array'; Required = $true } # Array of strings (job names from BackupLocations)
            OnErrorInJob = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") } # Policy on job failure within the set
        }
    }
}
#endregion

#region --- Private Validation Logic ---
# Internal recursive function to validate a configuration object against a given schema.
# This function is not exported.
# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Validate-AgainstSchemaRecursiveInternal] - 'Validate' is descriptive for this internal schema helper.
function Validate-AgainstSchemaRecursiveInternal { 
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject, # The configuration (sub-)object to validate
        [Parameter(Mandatory)]
        [hashtable]$Schema,    # The schema definition for this level of the config
        [Parameter(Mandatory)]
        [ref]$ValidationMessages, # List to append validation messages to
        [string]$CurrentPath = "Configuration" # String representing the current path in the config structure for error messages
    )

    # Ensure the configuration object being validated is a hashtable, as expected by the schema structure.
    if (-not ($ConfigObject -is [hashtable])) {
        $ValidationMessages.Value.Add("Configuration path '$CurrentPath' is expected to be a Hashtable, but found type '$($ConfigObject.GetType().Name)'. Schema validation cannot proceed for this path.")
        return
    }

    # Iterate over each key defined in the schema for the current configuration level.
    foreach ($schemaKey in $Schema.Keys) {
        $keyDefinition = $Schema[$schemaKey] # Get the schema definition for this specific key
        $fullKeyPath = "$CurrentPath.$schemaKey" # Construct the full path for logging/error messages

        # Check if a required key is missing from the configuration object.
        if (-not $ConfigObject.ContainsKey($schemaKey)) {
            if ($keyDefinition.Required -eq $true) {
                $ValidationMessages.Value.Add("Required configuration key '$fullKeyPath' is missing.")
            }
            continue # Move to the next schema key if this one is not present (and not required, or error already logged)
        }

        $configValue = $ConfigObject[$schemaKey] # Get the actual value from the configuration
        $expectedType = $keyDefinition.Type.ToLowerInvariant()
        
        # Validate the data type of the configuration value.
        $typeMatch = $false
        switch ($expectedType) {
            "string"           { if ($configValue -is [string]) { $typeMatch = $true } }
            "boolean"          { if ($configValue -is [bool]) { $typeMatch = $true } }
            "int"              { if ($configValue -is [int]) { $typeMatch = $true } }
            "hashtable"        { if ($configValue -is [hashtable]) { $typeMatch = $true } }
            "array"            { if ($configValue -is [array]) { $typeMatch = $true } }
            "string_or_array"  { if (($configValue -is [string]) -or ($configValue -is [array])) { $typeMatch = $true } }
            default            { $ValidationMessages.Value.Add("Schema Error: Unknown expected type '$($keyDefinition.Type)' defined in schema for '$fullKeyPath'. Contact script developer."); continue }
        }

        if (-not $typeMatch) {
            $ValidationMessages.Value.Add("Type mismatch for configuration key '$fullKeyPath'. Expected type '$($keyDefinition.Type)', but found type '$($configValue.GetType().Name)'.")
            continue # Skip further checks for this key if type is wrong
        }

        # Validate against a list of allowed values, if defined in the schema.
        if ($keyDefinition.ContainsKey("AllowedValues")) {
            $valuesToCheckAgainstAllowed = @()
            if ($configValue -is [array] -and $expectedType -eq 'string_or_array'){ 
                $valuesToCheckAgainstAllowed = $configValue # Validate each item in the array
            } elseif ($configValue -is [string]) { # Also handle single strings for string_or_array or string types
                $valuesToCheckAgainstAllowed = @($configValue)
            }

            if($valuesToCheckAgainstAllowed.Count -gt 0) {
                $allowedSchemaValues = $keyDefinition.AllowedValues | ForEach-Object { $_.ToString().ToLowerInvariant() } # Case-insensitive comparison
                foreach($valItemInConfig in $valuesToCheckAgainstAllowed){
                    if (($null -ne $valItemInConfig) -and ($valItemInConfig.ToString().ToLowerInvariant() -notin $allowedSchemaValues)) {
                        $ValidationMessages.Value.Add("Invalid value for configuration key '$fullKeyPath': '$valItemInConfig'. Allowed values (case-insensitive) are: $($keyDefinition.AllowedValues -join ', ').")
                    }
                }
            }
        }

        # Validate Min/Max for integer types.
        if ($expectedType -eq "int") {
            if ($keyDefinition.ContainsKey("Min") -and $configValue -lt $keyDefinition.Min) {
                $ValidationMessages.Value.Add("Value for configuration key '$fullKeyPath' ($configValue) is less than the minimum allowed value of $($keyDefinition.Min).")
            }
            if ($keyDefinition.ContainsKey("Max") -and $configValue -gt $keyDefinition.Max) {
                $ValidationMessages.Value.Add("Value for configuration key '$fullKeyPath' ($configValue) is greater than the maximum allowed value of $($keyDefinition.Max).")
            }
        }

        # Custom validation script (e.g., for path existence).
        if ($keyDefinition.ContainsKey("ValidateScript") -and $keyDefinition.ValidateScript -is [scriptblock]) {
            if (-not ([string]::IsNullOrWhiteSpace($configValue))) { # Only run ValidateScript if value is not empty (e.g. SevenZipPath auto-detection)
                try {
                    if (-not (& $keyDefinition.ValidateScript $configValue)) {
                        $ValidationMessages.Value.Add("Custom validation failed for configuration key '$fullKeyPath' with value '$configValue'. Check constraints (e.g., path existence for SevenZipPath).")
                    }
                } catch {
                     $ValidationMessages.Value.Add("Error executing custom validation script for '$fullKeyPath' on value '$configValue'. Error: $($_.Exception.Message)")
                }
            }
        }

        # Recursively validate nested hashtables if a sub-schema is defined.
        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema")) {
            # If the schema expects specific keys within this hashtable (e.g. individual job names under BackupLocations)
            # we iterate through the *actual* keys present in the config for this hashtable.
            foreach ($itemKeyInConfig in $configValue.Keys) {
                $itemValueFromConfig = $configValue[$itemKeyInConfig]
                # The schema provided for this level applies to *each* item within the configValue hashtable.
                Validate-AgainstSchemaRecursiveInternal -ConfigObject $itemValueFromConfig -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath.$itemKeyInConfig"
            }
        }
    }

    # Check for any keys present in the configuration object that are not defined in the schema (potential typos or unsupported settings).
    $allowUnknownKeysInConfig = $false # Set to $true to allow extra keys not in schema; $false to flag them.
    if (-not $allowUnknownKeysInConfig) {
        foreach ($configKeyInObject in $ConfigObject.Keys) {
            if (-not $Schema.ContainsKey($configKeyInObject)) {
                # Exception: _PoShBackup_PSScriptRoot is internally added and not part of user-facing schema.
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
    <#
    .SYNOPSIS
        Validates a loaded PoSh-Backup configuration hashtable against an internal predefined schema.
    .DESCRIPTION
        This function serves as the entry point for performing advanced schema-based validation
        on a PoSh-Backup configuration object. It calls an internal recursive function that
        traverses the configuration and checks each key and value against the rules defined
        in '$Script:PoShBackup_ConfigSchema'.

        Validation messages (errors or warnings) generated during the process are added to the
        list object provided via the -ValidationMessagesListRef parameter.
    .PARAMETER ConfigurationToValidate
        The PoSh-Backup configuration hashtable (typically loaded from .psd1 files) that needs
        to be validated.
    .PARAMETER ValidationMessagesListRef
        A reference ([ref]) to a System.Collections.Generic.List[string] object. Any validation
        messages generated by the schema check will be added to this list. The calling function
        can then inspect this list to determine if validation passed or failed.
    .EXAMPLE
        $myConfig = Import-PowerShellDataFile -Path ".\Config\Default.psd1"
        $validationErrors = [System.Collections.Generic.List[string]]::new()
        Invoke-PoShBackupConfigValidation -ConfigurationToValidate $myConfig -ValidationMessagesListRef ([ref]$validationErrors)
        if ($validationErrors.Count -gt 0) {
            Write-Warning "Configuration validation failed:"
            $validationErrors | ForEach-Object { Write-Warning "  - $_" }
        } else {
            Write-Host "Configuration validation successful."
        }
    .OUTPUTS
        None. Validation messages are passed back via the -ValidationMessagesListRef parameter.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigurationToValidate,

        [Parameter(Mandatory)]
        [ref]$ValidationMessagesListRef 
    )
    # Start the recursive validation from the root of the configuration.
    Validate-AgainstSchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:PoShBackup_ConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
