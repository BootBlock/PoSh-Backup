# Modules/ConfigManagement/Assets/ConfigSchema.psd1
# PoSh-Backup Configuration Schema
# File: Modules/ConfigManagement/Assets/ConfigSchema.psd1
#
# This file defines the expected structure and constraints for the PoSh-Backup configuration.
# It is loaded by Modules\PoShBackupValidator.psm1 for schema-based validation.
# Version: (Implicit) Updated 20-Jun-2025 (Added Schedule block to VerificationJobs)

@{
    # Top-level global settings
    SevenZipPath                              = @{ Type = 'string'; Required = $true; ValidateScript = { Test-Path -LiteralPath $_ -PathType Leaf } }
    MaintenanceModeEnabled                    = @{ Type = 'boolean'; Required = $false }
    MaintenanceModeFilePath                   = @{ Type = 'string'; Required = $false }
    MaintenanceModeMessage                    = @{ Type = 'string'; Required = $false }
    DefaultDestinationDir                     = @{ Type = 'string'; Required = $false }
    DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
    HideSevenZipOutput                        = @{ Type = 'boolean'; Required = $false }
    PauseBeforeExit                           = @{ Type = 'string'; Required = $false; AllowedValues = @("Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", "True", "False") }
    EnableAdvancedSchemaValidation            = @{ Type = 'boolean'; Required = $false }
    TreatSevenZipWarningsAsSuccess            = @{ Type = 'boolean'; Required = $false }
    RetentionConfirmDelete                    = @{ Type = 'boolean'; Required = $false }
    UserPromptTimeoutSeconds                  = @{ Type = 'int'; Required = $false; Min = 0 }
    EnableFileLogging                         = @{ Type = 'boolean'; Required = $false }
    LogDirectory                              = @{ Type = 'string'; Required = $false }
    DefaultLogRetentionCount                  = @{ Type = 'int'; Required = $false; Min = 0 }
    CompressOldLogs                           = @{ Type = 'boolean'; Required = $false }
    OldLogCompressionFormat                   = @{ Type = 'string'; Required = $false; AllowedValues = @("Zip") }
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
    DefaultReportRetentionCount               = @{ Type = 'int'; Required = $false; Min = 0 }
    CompressOldReports                        = @{ Type = 'boolean'; Required = $false }
    OldReportCompressionFormat                = @{ Type = 'string'; Required = $false; AllowedValues = @("Zip") }

    NotificationProfiles                      = @{
        Type             = 'hashtable'
        Required         = $false
        DynamicKeySchema = @{ # Schema for each named notification profile (e.g., "Office365", "TeamsAlertsChannel")
            Type     = "hashtable"
            Required = $true
            Schema   = @{
                Type             = @{ Type = 'string'; Required = $true; AllowedValues = @("Email", "Webhook", "Desktop") }
                ProviderSettings = @{ Type = 'hashtable'; Required = $true } # Specific validation will be handled by the provider itself.
            }
        }
    }
    DefaultNotificationSettings               = @{
        Type     = 'hashtable'
        Required = $false
        Schema   = @{
            Enabled         = @{ Type = 'boolean'; Required = $false }
            ProfileName     = @{ Type = 'string'; Required = $false }
            ToAddress       = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; Pattern = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' } }
            Subject         = @{ Type = 'string'; Required = $false }
            TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
        }
    }

    EnableVSS                                 = @{ Type = 'boolean'; Required = $false }
    DefaultVSSContextOption                   = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
    VSSMetadataCachePath                      = @{ Type = 'string'; Required = $false }
    VSSPollingTimeoutSeconds                  = @{ Type = 'int'; Required = $false; Min = 1; Max = 3600 }
    VSSPollingIntervalSeconds                 = @{ Type = 'int'; Required = $false; Min = 1; Max = 600 }

    SnapshotProviders                         = @{
        Type             = 'hashtable'
        Required         = $false
        DynamicKeySchema = @{ # Schema for each named snapshot provider (e.g., "LocalHyperV")
            Type     = "hashtable"
            Required = $true
            Schema   = @{
                Type                  = @{ Type = 'string'; Required = $true; AllowedValues = @("HyperV", "VMware") } # Add more as they are developed
                ProviderSpecificSettings = @{ Type = 'hashtable'; Required = $true } # Specific validation handled by provider
                CredentialsSecretName = @{ Type = 'string'; Required = $false }
            }
        }
    }

    EnableRetries                             = @{ Type = 'boolean'; Required = $false }
    MaxRetryAttempts                          = @{ Type = 'int'; Required = $false; Min = 0 }
    RetryDelaySeconds                         = @{ Type = 'int'; Required = $false; Min = 0 }

    DefaultSevenZipProcessPriority            = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }

    MinimumRequiredFreeSpaceGB                = @{ Type = 'int'; Required = $false; Min = 0 }
    ExitOnLowSpaceIfBelowMinimum              = @{ Type = 'boolean'; Required = $false }

    DefaultTestArchiveAfterCreation           = @{ Type = 'boolean'; Required = $false }
    DefaultVerifyLocalArchiveBeforeTransfer   = @{ Type = 'boolean'; Required = $false }

    DefaultArchiveDateFormat                  = @{ Type = 'string'; Required = $false }
    DefaultCreateSFX                          = @{ Type = 'boolean'; Required = $false }
    DefaultSFXModule                          = @{ Type = 'string'; Required = $false; AllowedValues = @("Console", "GUI", "Installer", "Default") }
    DefaultSplitVolumeSize                    = @{ Type = 'string'; Required = $false; Pattern = '(^$)|(^\d+[kmg]$)' }

    DefaultGenerateArchiveChecksum            = @{ Type = 'boolean'; Required = $false }
    DefaultGenerateSplitArchiveManifest       = @{ Type = 'boolean'; Required = $false }
    DefaultChecksumAlgorithm                  = @{ Type = 'string'; Required = $false; AllowedValues = @("SHA1", "SHA256", "SHA384", "SHA512", "MD5") }
    DefaultVerifyArchiveChecksumOnTest        = @{ Type = 'boolean'; Required = $false }

    DefaultThreadCount                        = @{ Type = 'int'; Required = $false; Min = 0 }
    DefaultSevenZipCpuAffinity                = @{ Type = 'string'; Required = $false; Pattern = '^0x[0-9a-fA-F]+$|^(\d+(,\d+)*)?$' }
    DefaultSevenZipIncludeListFile            = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
    DefaultSevenZipExcludeListFile            = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
    DefaultSevenZipTempDirectory              = @{ Type = 'string'; Required = $false }
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
    DefaultFollowSymbolicLinks                = @{ Type = 'boolean'; Required = $false }

    _PoShBackup_PSScriptRoot                  = @{ Type = 'string'; Required = $false } # Internal use by PoSh-Backup.ps1

    BackupTargets                             = @{
        Type             = 'hashtable'
        Required         = $false
        DynamicKeySchema = @{ # Schema for each named target instance (e.g., "MyUNCShare", "MySFTPServer")
            Type     = "hashtable"
            Required = $true
            Schema   = @{
                Type = @{
                    Type          = 'string'
                    Required      = $true
                    AllowedValues = @("UNC", "Replicate", "SFTP", "WebDAV", "S3") # Added S3
                }

                ContinueOnError = @{ Type = 'boolean'; Required = $false } # For Replicate target type

                TargetSpecificSettings = @{
                    Type     = 'object' # This will be validated by the specific target provider's validation function
                    Required = $true
                    # No generic schema here as it depends on 'Type'.
                    # PoShBackupValidator.psm1 will call the appropriate target-specific validator.
                }
                CredentialsSecretName = @{ # Optional, used by providers like SFTP, WebDAV
                    Type     = 'string'
                    Required = $false
                }
                RemoteRetentionSettings = @{ # Optional, structure defined by each provider
                    Type     = 'hashtable'
                    Required = $false
                    # Example for a provider that supports KeepCount:
                    # Schema = @{ KeepCount = @{ Type = 'int'; Required = $true; Min = 1 } }
                    # This will be validated by the specific target provider's validation function if it supports it.
                }
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

    # Section for Automated Backup Verification Jobs
    VerificationJobs = @{
        Type             = 'hashtable'
        Required         = $false
        DynamicKeySchema = @{ # Schema for each named verification job (e.g., "Verify_MyWebApp_Backup")
            Type     = 'hashtable'
            Required = $true
            Schema   = @{
                Enabled                   = @{ Type = 'boolean'; Required = $false }
                TargetJobName             = @{ Type = 'string'; Required = $true }
                ArchivePasswordSecretName = @{ Type = 'string'; Required = $false }
                SandboxPath               = @{ Type = 'string'; Required = $true }
                OnDirtySandbox            = @{ Type = 'string'; Required = $false; AllowedValues = @("Fail", "CleanAndContinue") }
                VerificationSteps         = @{ Type = 'array'; Required = $true; ItemSchema = @{ Type = 'string'; AllowedValues = @("TestArchive", "VerifyChecksums", "CompareFileCount") } }
                TestLatestCount           = @{ Type = 'int'; Required = $false; Min = 1 }
                # --- NEW: Added Schedule block ---
                Schedule                  = @{
                    Type     = 'hashtable'
                    Required = $false
                    Schema   = @{
                        Enabled                 = @{ Type = 'boolean'; Required = $false }
                        Type                    = @{ Type = 'string'; Required = $false; AllowedValues = @("Daily", "Weekly", "Monthly", "Once", "OnLogon", "OnStartup") }
                        Time                    = @{ Type = 'string'; Required = $false; Pattern = '^\d{2}:\d{2}$' }
                        DaysOfWeek              = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday") } }
                        DaysOfMonth             = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'int'; Min = 1; Max = 31 } }
                        MonthsOfYear            = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December") } }
                        RandomDelay             = @{ Type = 'string'; Required = $false; Pattern = '^\d+[smh]$' }
                        RunAsUser               = @{ Type = 'string'; Required = $false; AllowedValues = @("SYSTEM", "Author") }
                        HighestPrivileges       = @{ Type = 'boolean'; Required = $false }
                        WakeToRun               = @{ Type = 'boolean'; Required = $false }
                        AllowStartIfOnBatteries = @{ Type = 'boolean'; Required = $false }
                        StopIfGoingOnBatteries  = @{ Type = 'boolean'; Required = $false }
                        AdditionalArguments     = @{ Type = 'string'; Required = $false }
                    }
                }
            }
        }
    }

    BackupLocations                           = @{
        Type = 'hashtable'; Required = $true
        DynamicKeySchema = @{
            Type = "hashtable"; Required = $true
            Schema = @{
                Name                                      = @{ Type = 'string'; Required = $true }
                Description                               = @{ Type = 'string'; Required = $false }
                Path                                      = @{ Type = 'string_or_array'; Required = $true }
                SourceIsVMName                            = @{ Type = 'boolean'; Required = $false }
                SnapshotProviderName                      = @{ Type = 'string'; Required = $false }
                DestinationDir                            = @{ Type = 'string'; Required = $false }
                Enabled                                   = @{ Type = 'boolean'; Required = $false }
                PinOnCreation                             = @{ Type = 'boolean'; Required = $false }
                LocalRetentionCount                       = @{ Type = 'int'; Required = $false; Min = 0 }
                LogRetentionCount                         = @{ Type = 'int'; Required = $false; Min = 0 }
                TargetNames                               = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } }
                DeleteLocalArchiveAfterSuccessfulTransfer = @{ Type = 'boolean'; Required = $false }
                DeleteToRecycleBin                        = @{ Type = 'boolean'; Required = $false }
                RetentionConfirmDelete                    = @{ Type = 'boolean'; Required = $false }
                TestArchiveBeforeDeletion                 = @{ Type = 'boolean'; Required = $false }
                DependsOnJobs                             = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string' } }
                OnSourcePathNotFound                      = @{ Type = 'string'; Required = $false; AllowedValues = @("FailJob", "WarnAndContinue", "SkipJob") }
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
                SevenZipCpuAffinity                       = @{ Type = 'string'; Required = $false; Pattern = '^0x[0-9a-fA-F]+$|^(\d+(,\d+)*)?$' }
                SevenZipIncludeListFile                   = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
                SevenZipExcludeListFile                   = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
                SevenZipTempDirectory                     = @{ Type = 'string'; Required = $false }
                ReportGeneratorType                       = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") }
                TreatSevenZipWarningsAsSuccess            = @{ Type = 'boolean'; Required = $false }
                FollowSymbolicLinks                       = @{ Type = 'boolean'; Required = $false }
                HtmlReportDirectory                       = @{ Type = 'string'; Required = $false }
                CsvReportDirectory                        = @{ Type = 'string'; Required = $false }
                JsonReportDirectory                       = @{ Type = 'string'; Required = $false }
                XmlReportDirectory                        = @{ Type = 'string'; Required = $false }
                TxtReportDirectory                        = @{ Type = 'string'; Required = $false }
                MdReportDirectory                         = @{ Type = 'string'; Required = $false }
                ArchiveType                               = @{ Type = 'string'; Required = $false }
                ArchiveExtension                          = @{ Type = 'string'; Required = $false }
                CreateSFX                                 = @{ Type = 'boolean'; Required = $false }
                SFXModule                                 = @{ Type = 'string'; Required = $false; AllowedValues = @("Console", "GUI", "Installer", "Default") }
                SplitVolumeSize                           = @{ Type = 'string'; Required = $false; Pattern = '(^$)|(^\d+[kmg]$)' }
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
                VerifyLocalArchiveBeforeTransfer          = @{ Type = 'boolean'; Required = $false }
                GenerateArchiveChecksum                   = @{ Type = 'boolean'; Required = $false }
                GenerateSplitArchiveManifest              = @{ Type = 'boolean'; Required = $false }
                GenerateContentsManifest                  = @{ Type = 'boolean'; Required = $false }
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
                DefaultReportRetentionCount               = @{ Type = 'int'; Required = $false; Min = 0 }
                CompressOldReports                        = @{ Type = 'boolean'; Required = $false }
                OldReportCompressionFormat                = @{ Type = 'string'; Required = $false; AllowedValues = @("Zip") }
                PreBackupScriptPath                       = @{ Type = 'string'; Required = $false }
                PostBackupScriptOnSuccessPath             = @{ Type = 'string'; Required = $false }
                PostBackupScriptOnFailurePath             = @{ Type = 'string'; Required = $false }
                PostBackupScriptAlwaysPath                = @{ Type = 'string'; Required = $false }
                PostLocalArchiveScriptPath                = @{ Type = 'string'; Required = $false }

                NotificationSettings                      = @{
                    Type     = 'hashtable'
                    Required = $false
                    Schema   = @{
                        Enabled         = @{ Type = 'boolean'; Required = $false }
                        ProfileName     = @{ Type = 'string'; Required = $false }
                        ToAddress       = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; Pattern = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' } }
                        Subject         = @{ Type = 'string'; Required = $false }
                        TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
                    }
                }
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
                Schedule                                  = @{ # NEW
                    Type     = 'hashtable'
                    Required = $false
                    Schema   = @{
                        Enabled                 = @{ Type = 'boolean'; Required = $false }
                        Type                    = @{ Type = 'string'; Required = $false; AllowedValues = @("Daily", "Weekly", "Monthly", "Once", "OnLogon", "OnStartup") }
                        Time                    = @{ Type = 'string'; Required = $false; Pattern = '^\d{2}:\d{2}$' }
                        DaysOfWeek              = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday") } }
                        DaysOfMonth             = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'int'; Min = 1; Max = 31 } }
                        MonthsOfYear            = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December") } }
                        RandomDelay             = @{ Type = 'string'; Required = $false; Pattern = '^\d+[smh]$' }
                        RunAsUser               = @{ Type = 'string'; Required = $false; AllowedValues = @("SYSTEM", "Author") }
                        HighestPrivileges       = @{ Type = 'boolean'; Required = $false }
                        WakeToRun               = @{ Type = 'boolean'; Required = $false }
                        AllowStartIfOnBatteries = @{ Type = 'boolean'; Required = $false }
                        StopIfGoingOnBatteries  = @{ Type = 'boolean'; Required = $false }
                        AdditionalArguments     = @{ Type = 'string'; Required = $false }
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
                Description             = @{ Type = 'string'; Required = $false }
                JobNames                = @{ Type = 'array'; Required = $true; ItemSchema = @{ Type = 'string' } }
                OnErrorInJob            = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") }
                DelayBetweenJobsSeconds = @{ Type = 'int'; Required = $false; Min = 0 }
                LogRetentionCount       = @{ Type = 'int'; Required = $false; Min = 0 }
                SevenZipIncludeListFile = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
                SevenZipExcludeListFile = @{ Type = 'string'; Required = $false; ValidateScript = { if ([string]::IsNullOrWhiteSpace($_)) { return $true }; Test-Path -LiteralPath $_ -PathType Leaf } }
                NotificationSettings    = @{
                    Type     = 'hashtable'
                    Required = $false
                    Schema   = @{
                        Enabled         = @{ Type = 'boolean'; Required = $false }
                        ProfileName     = @{ Type = 'string'; Required = $false }
                        ToAddress       = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; Pattern = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' } }
                        Subject         = @{ Type = 'string'; Required = $false }
                        TriggerOnStatus = @{ Type = 'array'; Required = $false; ItemSchema = @{ Type = 'string'; AllowedValues = @("SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY") } }
                    }
                }
                PostRunAction           = @{
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
