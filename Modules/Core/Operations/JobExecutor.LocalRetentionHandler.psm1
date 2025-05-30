# Modules\Core\Operations\JobExecutor.LocalRetentionHandler.psm1
<#
.SYNOPSIS
    Handles the execution of the local backup archive retention policy for a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupLocalRetentionExecution' function.
    It encapsulates the logic for applying the local retention policy, including
    loading necessary assemblies for Recycle Bin operations, determining the correct
    archive extension for retention (especially for multi-volume archives), and
    calling the main RetentionManager's Invoke-BackupRetentionPolicy function.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    30-May-2025
    LastModified:   30-May-2025
    Purpose:        To modularise local retention policy execution from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Managers\RetentionManager.psm1.
#>

# Explicitly import RetentionManager.psm1 from the parent 'Modules\Managers' directory.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\RetentionManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.LocalRetentionHandler.psm1 FATAL: Could not import RetentionManager.psm1. Error: $($_.Exception.Message)"
    throw
}

function Invoke-PoShBackupLocalRetentionExecution {
    [CmdletBinding(SupportsShouldProcess=$true)] # ADDED SupportsShouldProcess
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName, # For logging context
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
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
    & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler/Invoke-PoShBackupLocalRetentionExecution: Initializing for job '$JobName'." -Level "DEBUG"

    $vbLoaded = $false
    if ($EffectiveJobConfig.DeleteToRecycleBin) {
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            $vbLoaded = $true
        }
        catch {
            & $LocalWriteLog -Message "[WARNING] JobExecutor.LocalRetentionHandler: Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion for local retention. Error: $($_.Exception.Message)" -Level WARNING
        }
    }

    $extensionForRetention = $EffectiveJobConfig.JobArchiveExtension 
    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
        $extensionForRetention = $EffectiveJobConfig.InternalArchiveExtension
        & $LocalWriteLog -Message "  - JobExecutor.LocalRetentionHandler: Using internal extension '$extensionForRetention' for retention policy due to active volume splitting for job '$JobName'." -Level DEBUG
    }

    $retentionPolicyParams = @{
        DestinationDirectory             = $EffectiveJobConfig.DestinationDir
        ArchiveBaseFileName              = $EffectiveJobConfig.BaseFileName
        ArchiveExtension                 = $extensionForRetention
        RetentionCountToKeep             = $EffectiveJobConfig.LocalRetentionCount
        RetentionConfirmDeleteFromConfig = $EffectiveJobConfig.RetentionConfirmDelete
        SendToRecycleBin                 = $EffectiveJobConfig.DeleteToRecycleBin
        VBAssemblyLoaded                 = $vbLoaded
        IsSimulateMode                   = $IsSimulateMode.IsPresent
        Logger                           = $Logger
        PSCmdlet                         = $PSCmdlet
    }

    if ($PSCmdlet.ShouldProcess("Local Retention Policy for job '$JobName'", "Apply")) {
        Invoke-BackupRetentionPolicy @retentionPolicyParams
    }
    else {
        & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler: Local retention policy for job '$JobName' skipped by user (ShouldProcess)." -Level "WARNING"
    }
    & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler/Invoke-PoShBackupLocalRetentionExecution: Local retention execution phase complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupLocalRetentionExecution
