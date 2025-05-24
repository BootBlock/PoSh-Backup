# Modules\PoShBackupValidator.psm1
<#
.SYNOPSIS
    (Optional Module) Provides advanced, schema-based validation for PoSh-Backup configuration files.
    It checks for correct data structure, data types, presence of required keys, and adherence
    to allowed values, helping to ensure configuration integrity before a backup job is run.
    Includes schema validation for "UNC", "Replicate", and "SFTP" Backup Target configurations,
    new PostRunAction settings, and new Checksum settings.

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
      including for UNC, "Replicate", and "SFTP" target types. The base 'TargetSpecificSettings'
      type is 'object' to allow flexibility, with type-specific validation in a ValidateScript.
    - Incorrect structure or values for the new 'PostRunAction' settings at global, job, and set levels.
    - Incorrect structure or values for the new 'Checksum' settings at global and job levels.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.6 # Added schema validation for Checksum settings.
    DateCreated:    14-May-2025
    LastModified:   24-May-2025
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
    SevenZipPath                    = @{ Type = 'string'; Required = $true; ValidateScript = { Test-Path -LiteralPath $_ -PathType Leaf } }
    DefaultDestinationDir           = @{ Type = 'string'; Required = $false }
    DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
    HideSevenZipOutput              = @{ Type = 'boolean'; Required = $false }
    PauseBeforeExit                 = @{ Type = 'string'; Required = $false; AllowedValues = @("Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", "True", "False") }
    EnableAdvancedSchemaValidation  = @{ Type = 'boolean'; Required = $false }
    TreatSevenZipWarningsAsSuccess  = @{ Type = 'boolean'; Required = $false }
    RetentionConfirmDelete          = @{ Type = 'boolean'; Required = $false }
    EnableFileLogging               = @{ Type = 'boolean'; Required = $false }
    LogDirectory                    = @{ Type = 'string'; Required = $false }
    ReportGeneratorType             = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") }

    HtmlReportDirectory             = @{ Type = 'string'; Required = $false }
    CsvReportDirectory              = @{ Type = 'string'; Required = $false }
    JsonReportDirectory             = @{ Type = 'string'; Required = $false }
    XmlReportDirectory              = @{ Type = 'string'; Required = $false }
    TxtReportDirectory              = @{ Type = 'string'; Required = $false }
    MdReportDirectory               = @{ Type = 'string'; Required = $false }

    HtmlReportTitlePrefix           = @{ Type = 'string'; Required = $false }
    HtmlReportLogoPath              = @{ Type = 'string'; Required = $false }
    HtmlReportFaviconPath           = @{ Type = 'string'; Required = $false }
    HtmlReportCustomCssPath         = @{ Type = 'string'; Required = $false }
    HtmlReportCompanyName           = @{ Type = 'string'; Required = $false }
    HtmlReportTheme                 = @{ Type = 'string'; Required = $false }
    HtmlReportOverrideCssVariables  = @{ Type = 'hashtable'; Required = $false }
    HtmlReportShowSummary           = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowConfiguration     = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowHooks             = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowLogEntries        = @{ Type = 'boolean'; Required = $false }

    EnableVSS                       = @{ Type = 'boolean'; Required = $false }
    DefaultVSSContextOption         = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
    VSSMetadataCachePath            = @{ Type = 'string'; Required = $false }
    VSSPollingTimeoutSeconds        = @{ Type = 'int'; Required = $false; Min = 1; Max = 3600 }
    VSSPollingIntervalSeconds       = @{ Type = 'int'; Required = $false; Min = 1; Max = 600 }

    EnableRetries                   = @{ Type = 'boolean'; Required = $false }
    MaxRetryAttempts                = @{ Type = 'int'; Required = $false; Min = 0 }
    RetryDelaySeconds               = @{ Type = 'int'; Required = $false; Min = 0 }

    DefaultSevenZipProcessPriority  = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }

    MinimumRequiredFreeSpaceGB      = @{ Type = 'int'; Required = $false; Min = 0 }
    ExitOnLowSpaceIfBelowMinimum    = @{ Type = 'boolean'; Required = $false }

    DefaultTestArchiveAfterCreation = @{ Type = 'boolean'; Required = $false }

    DefaultArchiveDateFormat        = @{ Type = 'string'; Required = $false }

    # NEW Global Checksum Settings
    DefaultGenerateArchiveChecksum      = @{ Type = 'boolean'; Required = $false }
    DefaultChecksumAlgorithm            = @{ Type = 'string'; Required = $false; AllowedValues = @("SHA1", "SHA256", "SHA384", "SHA512", "MD5") }
    DefaultVerifyArchiveChecksumOnTest  = @{ Type = 'boolean'; Required = $false }

    DefaultThreadCount              = @{ Type = 'int'; Required = $false; Min = 0 }
    DefaultArchiveType              = @{ Type = 'string'; Required = $false }
    DefaultArchiveExtension         = @{ Type = 'string'; Required = $false }
    DefaultCompressionLevel         = @{ Type = 'string'; Required = $false }
    DefaultCompressionMethod        = @{ Type = 'string'; Required = $false }
    DefaultDictionarySize           = @{ Type = 'string'; Required = $false }
    DefaultWordSize                 = @{ Type = 'string'; Required = $false }
    DefaultSolidBlockSize           = @{ Type = 'string'; Required = $false }
    DefaultCompressOpenFiles        = @{ Type = 'boolean'; Required = $false }
    DefaultScriptExcludeRecycleBin  = @{ Type = 'string'; Required = $false }
    DefaultScriptExcludeSysVolInfo  = @{ Type = 'string'; Required = $false }

    _PoShBackup_PSScriptRoot        = @{ Type = 'string'; Required = $false }

    BackupTargets = @{
        Type = 'hashtable'
        Required = $false
        DynamicKeySchema = @{
            Type = "hashtable"
            Required = $true
            Schema = @{
                Type = @{ Type = 'string'; Required = $true }
                TargetSpecificSettings = @{ Type = 'object'; Required = $true } # Type 'object' allows flexibility for different providers
                CredentialsSecretName  = @{ Type = 'string'; Required = $false }
                RemoteRetentionSettings= @{ Type = 'hashtable'; Required = $false }
            }
        }
        ValidateScript = {
            param($BackupTargetsHashtable, [ref]$ValidationMessagesListRef, [string]$CurrentPathForTarget)
            $isValidOverall = $true
            foreach ($targetInstanceNameKey in $BackupTargetsHashtable.Keys) {
                $targetInstanceValue = $BackupTargetsHashtable[$targetInstanceNameKey]
                if ($targetInstanceValue -is [hashtable] -and $targetInstanceValue.ContainsKey('Type') -and $targetInstanceValue.Type -is [string] -and $targetInstanceValue.ContainsKey('TargetSpecificSettings')) {
                    $instanceType = $targetInstanceValue.Type.ToUpperInvariant()
                    $instanceSettings = $targetInstanceValue.TargetSpecificSettings
                    $instancePath = "$CurrentPathForTarget.$targetInstanceNameKey.TargetSpecificSettings"

                    if ($instanceType -eq "UNC") {
                        if (-not ($instanceSettings -is [hashtable])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'TargetSpecificSettings' must be a Hashtable. Path: '$instancePath'.")
                            $isValidOverall = $false
                            continue
                        }
                        if (-not $instanceSettings.ContainsKey('UNCRemotePath') -or -not ($instanceSettings.UNCRemotePath -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.UNCRemotePath)) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'UNCRemotePath' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$instancePath.UNCRemotePath'.")
                            $isValidOverall = $false
                        }
                        if ($instanceSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($instanceSettings.CreateJobNameSubdirectory -is [boolean])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: UNC): 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$instancePath.CreateJobNameSubdirectory'.")
                            $isValidOverall = $false
                        }
                    } elseif ($instanceType -eq "REPLICATE") {
                        if (-not ($instanceSettings -is [array])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): 'TargetSpecificSettings' must be an Array of destination configurations. Path: '$instancePath'.")
                            $isValidOverall = $false
                            continue
                        }
                        if ($instanceSettings.Count -eq 0) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$instancePath'.")
                            $isValidOverall = $false
                        }
                        for ($i = 0; $i -lt $instanceSettings.Count; $i++) {
                            $destConfig = $instanceSettings[$i]
                            $destConfigPath = "$instancePath[$i]"
                            if (-not ($destConfig -is [hashtable])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'.")
                                $isValidOverall = $false; continue
                            }
                            if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i is missing 'Path', or it's not a non-empty string. Path: '$destConfigPath.Path'.")
                                $isValidOverall = $false
                            }
                            if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined. Path: '$destConfigPath.CreateJobNameSubdirectory'.")
                                $isValidOverall = $false
                            }
                            if ($destConfig.ContainsKey('RetentionSettings')) {
                                if (-not ($destConfig.RetentionSettings -is [hashtable])) {
                                    $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings' must be a Hashtable if defined. Path: '$destConfigPath.RetentionSettings'.")
                                    $isValidOverall = $false
                                } elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount')) {
                                    if (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0) {
                                        $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$destConfigPath.RetentionSettings.KeepCount'.")
                                        $isValidOverall = $false
                                    }
                                }
                            }
                        }
                    } elseif ($instanceType -eq "SFTP") { 
                        if (-not ($instanceSettings -is [hashtable])) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'TargetSpecificSettings' must be a Hashtable. Path: '$instancePath'.")
                            $isValidOverall = $false
                            continue
                        }
                        # Mandatory SFTP settings
                        foreach ($sftpKey in @('SFTPServerAddress', 'SFTPRemotePath', 'SFTPUserName')) {
                            if (-not $instanceSettings.ContainsKey($sftpKey) -or -not ($instanceSettings.$sftpKey -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.$sftpKey)) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpKey' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$instancePath.$sftpKey'.")
                                $isValidOverall = $false
                            }
                        }
                        # Optional SFTP settings with type checks
                        if ($instanceSettings.ContainsKey('SFTPPort') -and -not ($instanceSettings.SFTPPort -is [int] -and $instanceSettings.SFTPPort -gt 0 -and $instanceSettings.SFTPPort -le 65535)) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'SFTPPort' in 'TargetSpecificSettings' must be an integer between 1 and 65535 if defined. Path: '$instancePath.SFTPPort'.")
                            $isValidOverall = $false
                        }
                        foreach ($sftpOptionalStringKey in @('SFTPPasswordSecretName', 'SFTPKeyFileSecretName', 'SFTPKeyFilePassphraseSecretName')) {
                            if ($instanceSettings.ContainsKey($sftpOptionalStringKey) -and (-not ($instanceSettings.$sftpOptionalStringKey -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.$sftpOptionalStringKey)) ) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpOptionalStringKey' in 'TargetSpecificSettings' must be a non-empty string if defined. Path: '$instancePath.$sftpOptionalStringKey'.")
                                $isValidOverall = $false
                            }
                        }
                        foreach ($sftpOptionalBoolKey in @('CreateJobNameSubdirectory', 'SkipHostKeyCheck')) {
                            if ($instanceSettings.ContainsKey($sftpOptionalBoolKey) -and -not ($instanceSettings.$sftpOptionalBoolKey -is [boolean])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpOptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$instancePath.$sftpOptionalBoolKey'.")
                                $isValidOverall = $false
                            }
                        }
                        # Validate RemoteRetentionSettings for SFTP if present
                        if ($targetInstanceValue.ContainsKey('RemoteRetentionSettings')) {
                            $retentionSettings = $targetInstanceValue.RemoteRetentionSettings
                            if (-not ($retentionSettings -is [hashtable])) {
                                $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$CurrentPathForTarget.$targetInstanceNameKey.RemoteRetentionSettings'.")
                                $isValidOverall = $false
                            } elseif ($retentionSettings.ContainsKey('KeepCount')) {
                                if (-not ($retentionSettings.KeepCount -is [int]) -or $retentionSettings.KeepCount -le 0) {
                                    $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$CurrentPathForTarget.$targetInstanceNameKey.RemoteRetentionSettings.KeepCount'.")
                                    $isValidOverall = $false
                                }
                            }
                        }
                    }
                    # Add other target type validations here as 'elseif' blocks
                }
            }
            return $isValidOverall
        }
    }

    PostRunActionDefaults = @{
        Type = 'hashtable'
        Required = $false
        Schema = @{
            Enabled         = @{ Type = 'boolean'; Required = $false }
            Action          = @{ Type = 'string'; Required = $false; AllowedValues = @("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock") }
            DelaySeconds    = @{ Type = 'int'; Required = $false; Min = 0 }
            TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
            ForceAction     = @{ Type = 'boolean'; Required = $false }
        }
    }

    BackupLocations = @{
        Type = 'hashtable'
        Required = $true
        DynamicKeySchema = @{
            Type = "hashtable"
            Required = $true
            Schema = @{
                Path                    = @{ Type = 'string_or_array'; Required = $true }
                Name                    = @{ Type = 'string'; Required = $true }
                DestinationDir          = @{ Type = 'string'; Required = $false }
                LocalRetentionCount     = @{ Type = 'int'; Required = $false; Min = 0 }
                TargetNames             = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } }
                DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
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

                # NEW Job-level Checksum Settings
                GenerateArchiveChecksum     = @{ Type = 'boolean'; Required = $false }
                ChecksumAlgorithm           = @{ Type = 'string'; Required = $false; AllowedValues = @("SHA1", "SHA256", "SHA384", "SHA512", "MD5") }
                VerifyArchiveChecksumOnTest = @{ Type = 'boolean'; Required = $false }

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

                PostRunAction = @{
                    Type = 'hashtable'
                    Required = $false
                    Schema = @{
                        Enabled         = @{ Type = 'boolean'; Required = $false }
                        Action          = @{ Type = 'string'; Required = $false; AllowedValues = @("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock") }
                        DelaySeconds    = @{ Type = 'int'; Required = $false; Min = 0 }
                        TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
                        ForceAction     = @{ Type = 'boolean'; Required = $false }
                    }
                }
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

                PostRunAction = @{
                    Type = 'hashtable'
                    Required = $false
                    Schema = @{
                        Enabled         = @{ Type = 'boolean'; Required = $false }
                        Action          = @{ Type = 'string'; Required = $false; AllowedValues = @("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock") }
                        DelaySeconds    = @{ Type = 'int'; Required = $false; Min = 0 }
                        TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
                        ForceAction     = @{ Type = 'boolean'; Required = $false }
                    }
                }
            }
        }
    }
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
                Test-SchemaRecursiveInternal -ConfigObject $itemValueFromConfig -Schema $dynamicKeySubSchema.Schema -ValidationMessages $ValidationMessages -CurrentPath "$CurrentPath.$itemKeyInConfig"
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
                 # If the schema expects an array and the config value is an array, check each item.
                if ($keyDefinition.ContainsKey("ItemSchema") -and $keyDefinition.ItemSchema.ContainsKey("AllowedValues")) {
                    $valuesToCheckAgainstAllowed = $configValue
                } elseif (-not $keyDefinition.ContainsKey("ItemSchema")) { # If no ItemSchema, it's an array of simple types with AllowedValues at the array level (less common)
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

        if ($expectedType -eq "array" -and $keyDefinition.ContainsKey("ItemSchema") -and -not $keyDefinition.ItemSchema.ContainsKey("AllowedValues")) { # Check ItemSchema type if not already handled by AllowedValues
            foreach ($arrayItem in $configValue) {
                $itemSchemaDef = $keyDefinition.ItemSchema
                $itemExpectedType = $itemSchemaDef.Type.ToLowerInvariant()
                $itemTypeMatch = $false
                switch ($itemExpectedType) {
                    "string" { if ($arrayItem -is [string] -and -not ([string]::IsNullOrWhiteSpace($arrayItem)) ) { $itemTypeMatch = $true } }
                    # Add other simple item types if needed for arrays
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
                    } elseif (-not (& $keyDefinition.ValidateScript $configValue)) {
                        $ValidationMessages.Value.Add("Custom validation failed for configuration key '$fullKeyPath' with value '$configValue'. Check constraints (e.g., path existence for SevenZipPath).")
                    }
                } catch {
                     $ValidationMessages.Value.Add("Error executing custom validation script for '$fullKeyPath' on value '$configValue'. Error: $($_.Exception.Message)")
                }
            }
        }

        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema") -and (-not $keyDefinition.ContainsKey("DynamicKeySchema"))) {
            Test-SchemaRecursiveInternal -ConfigObject $configValue -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath"
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
    Test-SchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:PoShBackup_ConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
