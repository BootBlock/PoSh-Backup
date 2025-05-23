# PoSh-Backup Configuration Schema
# File: Modules\ConfigManagement\Assets\ConfigSchema.psd1
#
# This file defines the expected structure and constraints for the PoSh-Backup configuration.
# It is loaded by Modules\PoShBackupValidator.psm1 for schema-based validation.

@{
    # Top-level global settings
    SevenZipPath                              = @{ Type = 'string'; Required = $true; ValidateScript = { Test-Path -LiteralPath $_ -PathType Leaf } }
    DefaultDestinationDir                     = @{ Type = 'string'; Required = $false }
    DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
    HideSevenZipOutput                        = @{ Type = 'boolean'; Required = $false }
    PauseBeforeExit                           = @{ Type = 'string'; Required = $false; AllowedValues = @("Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", "True", "False") }
    EnableAdvancedSchemaValidation            = @{ Type = 'boolean'; Required = $false }
    TreatSevenZipWarningsAsSuccess            = @{ Type = 'boolean'; Required = $false }
    RetentionConfirmDelete                    = @{ Type = 'boolean'; Required = $false }
    EnableFileLogging                         = @{ Type = 'boolean'; Required = $false }
    LogDirectory                              = @{ Type = 'string'; Required = $false }
    ReportGeneratorType                       = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") }

    HtmlReportDirectory                       = @{ Type = 'string'; Required = $false }
    CsvReportDirectory                        = @{ Type = 'string'; Required = $false }
    JsonReportDirectory                       = @{ Type = 'string'; Required = $false }
    XmlReportDirectory                        = @{ Type = 'string'; Required = $false }
    TxtReportDirectory                        = @{ Type = 'string'; Required = $false }
    MdReportDirectory                         = @{ Type = 'string'; Required = $false }

    HtmlReportTitlePrefix                     = @{ Type = 'string'; Required = $false }
    HtmlReportLogoPath                        = @{ Type = 'string'; Required = $false }
    HtmlReportFaviconPath                     = @{ Type = 'string'; Required = $false }
    HtmlReportCustomCssPath                   = @{ Type = 'string'; Required = $false }
    HtmlReportCompanyName                     = @{ Type = 'string'; Required = $false }
    HtmlReportTheme                           = @{ Type = 'string'; Required = $false }
    HtmlReportOverrideCssVariables            = @{ Type = 'hashtable'; Required = $false }
    HtmlReportShowSummary                     = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowConfiguration               = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowHooks                       = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowLogEntries                  = @{ Type = 'boolean'; Required = $false }

    EnableVSS                                 = @{ Type = 'boolean'; Required = $false }
    DefaultVSSContextOption                   = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
    VSSMetadataCachePath                      = @{ Type = 'string'; Required = $false }
    VSSPollingTimeoutSeconds                  = @{ Type = 'int'; Required = $false; Min = 1; Max = 3600 }
    VSSPollingIntervalSeconds                 = @{ Type = 'int'; Required = $false; Min = 1; Max = 600 }

    EnableRetries                             = @{ Type = 'boolean'; Required = $false }
    MaxRetryAttempts                          = @{ Type = 'int'; Required = $false; Min = 0 }
    RetryDelaySeconds                         = @{ Type = 'int'; Required = $false; Min = 0 }

    DefaultSevenZipProcessPriority            = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }

    MinimumRequiredFreeSpaceGB                = @{ Type = 'int'; Required = $false; Min = 0 }
    ExitOnLowSpaceIfBelowMinimum              = @{ Type = 'boolean'; Required = $false }

    DefaultTestArchiveAfterCreation           = @{ Type = 'boolean'; Required = $false }

    DefaultArchiveDateFormat                  = @{ Type = 'string'; Required = $false }

    DefaultGenerateArchiveChecksum            = @{ Type = 'boolean'; Required = $false }
    DefaultChecksumAlgorithm                  = @{ Type = 'string'; Required = $false; AllowedValues = @("SHA1", "SHA256", "SHA384", "SHA512", "MD5") }
    DefaultVerifyArchiveChecksumOnTest        = @{ Type = 'boolean'; Required = $false }

    DefaultThreadCount                        = @{ Type = 'int'; Required = $false; Min = 0 }
    DefaultArchiveType                        = @{ Type = 'string'; Required = $false }
    DefaultArchiveExtension                   = @{ Type = 'string'; Required = $false }
    DefaultCompressionLevel                   = @{ Type = 'string'; Required = $false }
    DefaultCompressionMethod                  = @{ Type = 'string'; Required = $false }
    DefaultDictionarySize                     = @{ Type = 'string'; Required = $false }
    DefaultWordSize                           = @{ Type = 'string'; Required = $false }
    DefaultSolidBlockSize                     = @{ Type = 'string'; Required = $false }
    DefaultCompressOpenFiles                  = @{ Type = 'boolean'; Required = $false }
    DefaultScriptExcludeRecycleBin            = @{ Type = 'string'; Required = $false }
    DefaultScriptExcludeSysVolInfo            = @{ Type = 'string'; Required = $false }

    _PoShBackup_PSScriptRoot                  = @{ Type = 'string'; Required = $false } # Internal use by PoSh-Backup.ps1

    BackupTargets                             = @{
        Type             = 'hashtable'
        Required         = $false
        DynamicKeySchema = @{
            Type     = "hashtable"
            Required = $true
            Schema   = @{
                Type                    = @{ Type = 'string'; Required = $true } # Type of target (e.g., "UNC", "SFTP")
                TargetSpecificSettings  = @{ Type = 'object'; Required = $true } # Allows any structure, specific validation in PoShBackupValidator.psm1
                CredentialsSecretName   = @{ Type = 'string'; Required = $false }
                RemoteRetentionSettings = @{ Type = 'hashtable'; Required = $false } # Basic check here, specific content validated in PoShBackupValidator.psm1
            }
        }
    }

    PostRunActionDefaults                     = @{
        Type = 'hashtable'; Required = $false
        Schema = @{
            Enabled         = @{ Type = 'boolean'; Required = $false }
            Action          = @{ Type = 'string'; Required = $false; AllowedValues = @("None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock") }
            DelaySeconds    = @{ Type = 'int'; Required = $false; Min = 0 }
            TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
            ForceAction     = @{ Type = 'boolean'; Required = $false }
        }
    }

    BackupLocations                           = @{
        Type = 'hashtable'; Required = $true
        DynamicKeySchema = @{
            Type = "hashtable"; Required = $true
            Schema = @{
                Path                                      = @{ Type = 'string_or_array'; Required = $true }
                Name                                      = @{ Type = 'string'; Required = $true }
                DestinationDir                            = @{ Type = 'string'; Required = $false }
                LocalRetentionCount                       = @{ Type = 'int'; Required = $false; Min = 0 }
                TargetNames                               = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } }
                DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
                DeleteToRecycleBin                        = @{ Type = 'boolean'; Required = $false }
                RetentionConfirmDelete                    = @{ Type = 'boolean'; Required = $false }
                ArchivePasswordMethod                     = @{ Type = 'string'; Required = $false; AllowedValues = @("NONE", "INTERACTIVE", "SECRETMANAGEMENT", "SECURESTRINGFILE", "PLAINTEXT") }
                CredentialUserNameHint                    = @{ Type = 'string'; Required = $false }
                ArchivePasswordSecretName                 = @{ Type = 'string'; Required = $false }
                ArchivePasswordVaultName                  = @{ Type = 'string'; Required = $false }
                ArchivePasswordSecureStringPath           = @{ Type = 'string'; Required = $false }
                ArchivePasswordPlainText                  = @{ Type = 'string'; Required = $false }
                UsePassword                               = @{ Type = 'boolean'; Required = $false }
                EnableVSS                                 = @{ Type = 'boolean'; Required = $false }
                VSSContextOption                          = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
                SevenZipProcessPriority                   = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
                ReportGeneratorType                       = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") }
                TreatSevenZipWarningsAsSuccess            = @{ Type = 'boolean'; Required = $false }
                HtmlReportDirectory                       = @{ Type = 'string'; Required = $false }
                CsvReportDirectory                        = @{ Type = 'string'; Required = $false }
                JsonReportDirectory                       = @{ Type = 'string'; Required = $false }
                XmlReportDirectory                        = @{ Type = 'string'; Required = $false }
                TxtReportDirectory                        = @{ Type = 'string'; Required = $false }
                MdReportDirectory                         = @{ Type = 'string'; Required = $false }
                ArchiveType                               = @{ Type = 'string'; Required = $false }
                ArchiveExtension                          = @{ Type = 'string'; Required = $false }
                ArchiveDateFormat                         = @{ Type = 'string'; Required = $false }
                ThreadsToUse                              = @{ Type = 'int'; Required = $false; Min = 0 }
                CompressionLevel                          = @{ Type = 'string'; Required = $false }
                CompressionMethod                         = @{ Type = 'string'; Required = $false }
                DictionarySize                            = @{ Type = 'string'; Required = $false }
                WordSize                                  = @{ Type = 'string'; Required = $false }
                SolidBlockSize                            = @{ Type = 'string'; Required = $false }
                CompressOpenFiles                         = @{ Type = 'boolean'; Required = $false }
                AdditionalExclusions                      = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } }
                MinimumRequiredFreeSpaceGB                = @{ Type = 'int'; Required = $false; Min = 0 }
                ExitOnLowSpaceIfBelowMinimum              = @{ Type = 'boolean'; Required = $false }
                TestArchiveAfterCreation                  = @{ Type = 'boolean'; Required = $false }
                GenerateArchiveChecksum                   = @{ Type = 'boolean'; Required = $false }
                ChecksumAlgorithm                         = @{ Type = 'string'; Required = $false; AllowedValues = @("SHA1", "SHA256", "SHA384", "SHA512", "MD5") }
                VerifyArchiveChecksumOnTest               = @{ Type = 'boolean'; Required = $false }
                HtmlReportTheme                           = @{ Type = 'string'; Required = $false }
                HtmlReportTitlePrefix                     = @{ Type = 'string'; Required = $false }
                HtmlReportLogoPath                        = @{ Type = 'string'; Required = $false }
                HtmlReportFaviconPath                     = @{ Type = 'string'; Required = $false }
                HtmlReportCustomCssPath                   = @{ Type = 'string'; Required = $false }
                HtmlReportCompanyName                     = @{ Type = 'string'; Required = $false }
                HtmlReportOverrideCssVariables            = @{ Type = 'hashtable'; Required = $false }
                HtmlReportShowSummary                     = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowConfiguration               = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowHooks                       = @{ Type = 'boolean'; Required = $false }
                HtmlReportShowLogEntries                  = @{ Type = 'boolean'; Required = $false }
                PreBackupScriptPath                       = @{ Type = 'string'; Required = $false }
                PostBackupScriptOnSuccessPath             = @{ Type = 'string'; Required = $false }
                PostBackupScriptOnFailurePath             = @{ Type = 'string'; Required = $false }
                PostBackupScriptAlwaysPath                = @{ Type = 'string'; Required = $false }
                PostRunAction                             = @{
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

    BackupSets                                = @{
        Type = 'hashtable'; Required = $false
        DynamicKeySchema = @{
            Type = "hashtable"; Required = $true
            Schema = @{
                JobNames      = @{ Type = 'array'; Required = $true; ItemSchema = @{ Type = 'string' } }
                OnErrorInJob  = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") }
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
