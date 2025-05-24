# PoSh-Backup Configuration Schema
# File: Modules\ConfigManagement\Assets\ConfigSchema.psd1
#
# This file defines the expected structure and constraints for the PoSh-Backup configuration.
# It is loaded by Modules\PoShBackupValidator.psm1 for schema-based validation.

@{
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

    _PoShBackup_PSScriptRoot        = @{ Type = 'string'; Required = $false } # Internal use by PoSh-Backup.ps1

    BackupTargets = @{
        Type = 'hashtable'
        Required = $false
        DynamicKeySchema = @{
            Type = "hashtable"
            Required = $true
            Schema = @{
                Type = @{ Type = 'string'; Required = $true }
                TargetSpecificSettings = @{ Type = 'object'; Required = $true } 
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
                            $isValidOverall = $false; continue
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
                            $isValidOverall = $false; continue
                        }
                        if ($instanceSettings.Count -eq 0) {
                            $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): 'TargetSpecificSettings' array is empty. At least one destination configuration is required. Path: '$instancePath'.")
                            $isValidOverall = $false
                        }
                        for ($i = 0; $i -lt $instanceSettings.Count; $i++) {
                            $destConfig = $instanceSettings[$i]; $destConfigPath = "$instancePath[$i]"
                            if (-not ($destConfig -is [hashtable])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Item at index $i in 'TargetSpecificSettings' is not a Hashtable. Path: '$destConfigPath'."); $isValidOverall = $false; continue }
                            if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i is missing 'Path', or it's not a non-empty string. Path: '$destConfigPath.Path'."); $isValidOverall = $false }
                            if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined. Path: '$destConfigPath.CreateJobNameSubdirectory'."); $isValidOverall = $false }
                            if ($destConfig.ContainsKey('RetentionSettings')) {
                                if (-not ($destConfig.RetentionSettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings' must be a Hashtable if defined. Path: '$destConfigPath.RetentionSettings'."); $isValidOverall = $false }
                                elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount')) { if (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: Replicate): Destination at index $i 'RetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$destConfigPath.RetentionSettings.KeepCount'."); $isValidOverall = $false } }
                            }
                        }
                    } elseif ($instanceType -eq "SFTP") { 
                        if (-not ($instanceSettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'TargetSpecificSettings' must be a Hashtable. Path: '$instancePath'."); $isValidOverall = $false; continue }
                        foreach ($sftpKey in @('SFTPServerAddress', 'SFTPRemotePath', 'SFTPUserName')) { if (-not $instanceSettings.ContainsKey($sftpKey) -or -not ($instanceSettings.$sftpKey -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.$sftpKey)) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpKey' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$instancePath.$sftpKey'."); $isValidOverall = $false } }
                        if ($instanceSettings.ContainsKey('SFTPPort') -and -not ($instanceSettings.SFTPPort -is [int] -and $instanceSettings.SFTPPort -gt 0 -and $instanceSettings.SFTPPort -le 65535)) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'SFTPPort' in 'TargetSpecificSettings' must be an integer between 1 and 65535 if defined. Path: '$instancePath.SFTPPort'."); $isValidOverall = $false }
                        foreach ($sftpOptionalStringKey in @('SFTPPasswordSecretName', 'SFTPKeyFileSecretName', 'SFTPKeyFilePassphraseSecretName')) { if ($instanceSettings.ContainsKey($sftpOptionalStringKey) -and (-not ($instanceSettings.$sftpOptionalStringKey -is [string]) -or [string]::IsNullOrWhiteSpace($instanceSettings.$sftpOptionalStringKey)) ) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpOptionalStringKey' in 'TargetSpecificSettings' must be a non-empty string if defined. Path: '$instancePath.$sftpOptionalStringKey'."); $isValidOverall = $false } }
                        foreach ($sftpOptionalBoolKey in @('CreateJobNameSubdirectory', 'SkipHostKeyCheck')) { if ($instanceSettings.ContainsKey($sftpOptionalBoolKey) -and -not ($instanceSettings.$sftpOptionalBoolKey -is [boolean])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): '$sftpOptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$instancePath.$sftpOptionalBoolKey'."); $isValidOverall = $false } }
                        if ($targetInstanceValue.ContainsKey('RemoteRetentionSettings')) {
                            $retentionSettings = $targetInstanceValue.RemoteRetentionSettings
                            if (-not ($retentionSettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$CurrentPathForTarget.$targetInstanceNameKey.RemoteRetentionSettings'."); $isValidOverall = $false }
                            elseif ($retentionSettings.ContainsKey('KeepCount')) { if (-not ($retentionSettings.KeepCount -is [int]) -or $retentionSettings.KeepCount -le 0) { $ValidationMessagesListRef.Value.Add("BackupTarget instance '$targetInstanceNameKey' (Type: SFTP): 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$CurrentPathForTarget.$targetInstanceNameKey.RemoteRetentionSettings.KeepCount'."); $isValidOverall = $false } }
                        }
                    }
                }
            }
            return $isValidOverall
        }
    }

    PostRunActionDefaults = @{
        Type = 'hashtable'; Required = $false
        Schema = @{
            Enabled         = @{ Type = 'boolean'; Required = $false }
            Action          = @{ Type = 'string'; Required = $false; AllowedValues = @("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock") }
            DelaySeconds    = @{ Type = 'int'; Required = $false; Min = 0 }
            TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
            ForceAction     = @{ Type = 'boolean'; Required = $false }
        }
    }

    BackupLocations = @{
        Type = 'hashtable'; Required = $true
        DynamicKeySchema = @{
            Type = "hashtable"; Required = $true
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
                    Type = 'hashtable'; Required = $false
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
        Type = 'hashtable'; Required = $false
        DynamicKeySchema = @{
            Type = "hashtable"; Required = $true
            Schema = @{
                JobNames     = @{ Type = 'array'; Required = $true; ItemSchema = @{ Type = 'string'} }
                OnErrorInJob = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") }
                PostRunAction = @{
                    Type = 'hashtable'; Required = $false
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
