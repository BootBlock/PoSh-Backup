# Modules\Managers\CliManager.psm1
<#
.SYNOPSIS
    Manages Command-Line Interface (CLI) parameter processing for PoSh-Backup.
.DESCRIPTION
    This module provides functions to interpret the CLI parameters passed to
    PoSh-Backup.ps1 and construct a standardised hashtable of override settings.
    This helps to decouple CLI argument handling from the main script's core logic.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added extraction and all other utility parameters.
    DateCreated:    01-Jun-2025
    LastModified:   06-Jun-2025
    Purpose:        To centralise CLI parameter processing.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupCliOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BoundParameters # Expecting $PSBoundParameters or $MyInvocation.BoundParameters from the caller
    )

    # Note: This function assumes that the keys used here (e.g., 'UseVSS', 'EnableRetriesCLI')
    # match the parameter names defined in the main PoSh-Backup.ps1 script's param block.

    $cliOverrideSettings = @{}

    # Switch parameters: Value will be $true if present, $null otherwise.
    $cliOverrideSettings.UseVSS                              = if ($BoundParameters.ContainsKey('UseVSS')) { $true } else { $null }
    $cliOverrideSettings.SkipVSS                             = if ($BoundParameters.ContainsKey('SkipVSS')) { $true } else { $null }
    $cliOverrideSettings.EnableRetries                       = if ($BoundParameters.ContainsKey('EnableRetriesCLI')) { $true } else { $null }
    $cliOverrideSettings.SkipRetries                         = if ($BoundParameters.ContainsKey('SkipRetriesCLI')) { $true } else { $null }
    $cliOverrideSettings.TestArchive                         = if ($BoundParameters.ContainsKey('TestArchive')) { $true } else { $null }
    $cliOverrideSettings.VerifyLocalArchiveBeforeTransferCLI = if ($BoundParameters.ContainsKey('VerifyLocalArchiveBeforeTransferCLI')) { $true } else { $null }
    $cliOverrideSettings.GenerateHtmlReport                  = if ($BoundParameters.ContainsKey('GenerateHtmlReportCLI')) { $true } else { $null }
    $cliOverrideSettings.TreatSevenZipWarningsAsSuccess      = if ($BoundParameters.ContainsKey('TreatSevenZipWarningsAsSuccessCLI')) { $true } else { $null }
    $cliOverrideSettings.PostRunActionForceCli               = if ($BoundParameters.ContainsKey('PostRunActionForceCli')) { $true } else { $null }
    $cliOverrideSettings.PinOnCreationCLI                    = if ($BoundParameters.ContainsKey('Pin')) { $true } else { $null }
    $cliOverrideSettings.ForceExtract                        = if ($BoundParameters.ContainsKey('ForceExtract')) { $true } else { $null }

    # Parameters that take arguments: Value will be the argument, or $null if not present.
    # Default values for these are handled by the param block in the main PoSh-Backup.ps1 script.
    $cliOverrideSettings.SevenZipPriority                    = if ($BoundParameters.ContainsKey('SevenZipPriorityCLI')) { $BoundParameters['SevenZipPriorityCLI'] } else { $null }
    $cliOverrideSettings.SevenZipCpuAffinity                 = if ($BoundParameters.ContainsKey('SevenZipCpuAffinityCLI')) { $BoundParameters['SevenZipCpuAffinityCLI'] } else { $null }
    $cliOverrideSettings.SevenZipIncludeListFile             = if ($BoundParameters.ContainsKey('SevenZipIncludeListFileCLI')) { $BoundParameters['SevenZipIncludeListFileCLI'] } else { $null }
    $cliOverrideSettings.SevenZipExcludeListFile             = if ($BoundParameters.ContainsKey('SevenZipExcludeListFileCLI')) { $BoundParameters['SevenZipExcludeListFileCLI'] } else { $null }
    $cliOverrideSettings.SplitVolumeSizeCLI                  = if ($BoundParameters.ContainsKey('SplitVolumeSizeCLI')) { $BoundParameters['SplitVolumeSizeCLI'] } else { $null }
    $cliOverrideSettings.LogRetentionCountCLI                = if ($BoundParameters.ContainsKey('LogRetentionCountCLI')) { $BoundParameters['LogRetentionCountCLI'] } else { $null }
    $cliOverrideSettings.PauseBehaviour                      = if ($BoundParameters.ContainsKey('PauseBehaviourCLI')) { $BoundParameters['PauseBehaviourCLI'] } else { $null }
    $cliOverrideSettings.PostRunActionCli                    = if ($BoundParameters.ContainsKey('PostRunActionCli')) { $BoundParameters['PostRunActionCli'] } else { $null }
    $cliOverrideSettings.PostRunActionDelaySecondsCli        = if ($BoundParameters.ContainsKey('PostRunActionDelaySecondsCli')) { $BoundParameters['PostRunActionDelaySecondsCli'] } else { $null }
    $cliOverrideSettings.PostRunActionTriggerOnStatusCli     = if ($BoundParameters.ContainsKey('PostRunActionTriggerOnStatusCli')) { $BoundParameters['PostRunActionTriggerOnStatusCli'] } else { $null }

    # Utility Mode Parameters
    $cliOverrideSettings.PinBackup                           = if ($BoundParameters.ContainsKey('PinBackup')) { $BoundParameters['PinBackup'] } else { $null }
    $cliOverrideSettings.UnpinBackup                         = if ($BoundParameters.ContainsKey('UnpinBackup')) { $BoundParameters['UnpinBackup'] } else { $null }
    $cliOverrideSettings.ListArchiveContents                 = if ($BoundParameters.ContainsKey('ListArchiveContents')) { $BoundParameters['ListArchiveContents'] } else { $null }
    $cliOverrideSettings.ArchivePasswordSecretName           = if ($BoundParameters.ContainsKey('ArchivePasswordSecretName')) { $BoundParameters['ArchivePasswordSecretName'] } else { $null }
    $cliOverrideSettings.ExtractFromArchive                  = if ($BoundParameters.ContainsKey('ExtractFromArchive')) { $BoundParameters['ExtractFromArchive'] } else { $null }
    $cliOverrideSettings.ExtractToDirectory                  = if ($BoundParameters.ContainsKey('ExtractToDirectory')) { $BoundParameters['ExtractToDirectory'] } else { $null }
    $cliOverrideSettings.ItemsToExtract                      = if ($BoundParameters.ContainsKey('ItemsToExtract')) { $BoundParameters['ItemsToExtract'] } else { $null }

    return $cliOverrideSettings
}

Export-ModuleMember -Function Get-PoShBackupCliOverride
