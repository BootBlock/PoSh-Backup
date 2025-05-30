# Modules\Core\Operations\JobExecutor.PostJobHookHandler.psm1
<#
.SYNOPSIS
    Handles the execution of post-job hook scripts for a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupPostJobHooks' function, which is responsible
    for executing the user-defined post-backup hook scripts (OnSuccess, OnFailure, Always)
    after the main backup operations for a job have concluded. It constructs the necessary
    parameters for the hook scripts and calls the main HookManager's Invoke-PoShBackupHook function.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    30-May-2025
    LastModified:   30-May-2025
    Purpose:        To modularise post-job hook script execution logic from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Managers\HookManager.psm1.
#>

# Explicitly import HookManager.psm1 from the parent 'Modules\Managers' directory.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\HookManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.PostJobHookHandler.psm1 FATAL: Could not import HookManager.psm1. Error: $($_.Exception.Message)"
    throw
}

function Invoke-PoShBackupPostJobHooks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ReportDataOverallStatus,
        [Parameter(Mandatory = $false)]
        [string]$FinalLocalArchivePath, # Can be $null if archive creation failed
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig, # Contains hook script paths and checksum config
        [Parameter(Mandatory = $true)]
        [hashtable]$ReportData, # Contains TargetTransfers and Checksum details
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobExecutor.PostJobHookHandler/Invoke-PoShBackupPostJobHooks: Initializing for job '$JobName'." -Level "DEBUG"

    $hookArgsForExternalScript = @{
        JobName      = $JobName
        Status       = $ReportDataOverallStatus
        ArchivePath  = $FinalLocalArchivePath
        ConfigFile   = $ActualConfigFile
        SimulateMode = $IsSimulateMode.IsPresent
    }

    if ($ReportData.ContainsKey('TargetTransfers') -and $ReportData.TargetTransfers.Count -gt 0) {
        $hookArgsForExternalScript.TargetTransferResults = $ReportData.TargetTransfers
    }

    if ($EffectiveJobConfig.GenerateArchiveChecksum -and `
        $ReportData.ContainsKey('ArchiveChecksum') -and $ReportData.ArchiveChecksum -ne "N/A" -and `
        $ReportData.ArchiveChecksum -ne "Skipped (Prior failure)" -and `
        $ReportData.ArchiveChecksum -notlike "Error*") {
        
        $hookArgsForExternalScript.ArchiveChecksum = $ReportData.ArchiveChecksum
        if ($ReportData.ContainsKey('ArchiveChecksumAlgorithm')) {
            $hookArgsForExternalScript.ArchiveChecksumAlgorithm = $ReportData.ArchiveChecksumAlgorithm
        }
        if ($ReportData.ContainsKey('ArchiveChecksumFile')) {
            $hookArgsForExternalScript.ArchiveChecksumFile = $ReportData.ArchiveChecksumFile
        }
    }

    if ($ReportDataOverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE")) {
        Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PostBackupScriptOnSuccessPath `
            -HookType "PostBackupOnSuccess" `
            -HookParameters $hookArgsForExternalScript `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger
    }
    else { # Typically "FAILURE" or other non-success/warning states
        Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PostBackupScriptOnFailurePath `
            -HookType "PostBackupOnFailure" `
            -HookParameters $hookArgsForExternalScript `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger
    }

    Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PostBackupScriptAlwaysPath `
        -HookType "PostBackupAlways" `
        -HookParameters $hookArgsForExternalScript `
        -IsSimulateMode:$IsSimulateMode `
        -Logger $Logger
        
    & $LocalWriteLog -Message "JobExecutor.PostJobHookHandler/Invoke-PoShBackupPostJobHooks: Post-job hook execution phase complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupPostJobHooks
