# Modules\Core\Operations\JobExecutor.LocalRetentionHandler.psm1
<#
.SYNOPSIS
    Handles the execution of the local backup archive retention policy for a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupLocalRetentionExecution' function.
    It encapsulates the logic for applying the local retention policy by lazy-loading the
    main RetentionManager. It handles loading necessary assemblies for Recycle Bin operations,
    determines the correct archive extension for retention (especially for multi-volume archives),
    and calls the main RetentionManager's Invoke-BackupRetentionPolicy function.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load RetentionManager.
    DateCreated:    30-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To modularise local retention policy execution from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
#>

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
    & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler/Invoke-PoShBackupLocalRetentionExecution: Initialising for job '$JobName'." -Level "DEBUG"

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
        ArchiveDateFormat                = $EffectiveJobConfig.JobArchiveDateFormat
        RetentionCountToKeep             = $EffectiveJobConfig.LocalRetentionCount
        RetentionConfirmDeleteFromConfig = $EffectiveJobConfig.RetentionConfirmDelete
        SendToRecycleBin                 = $EffectiveJobConfig.DeleteToRecycleBin
        VBAssemblyLoaded                 = $vbLoaded
        IsSimulateMode                   = $IsSimulateMode.IsPresent
        EffectiveJobConfig               = $EffectiveJobConfig
        Logger                           = $Logger
        PSCmdlet                         = $PSCmdlet
    }

    if ($PSCmdlet.ShouldProcess("Local Retention Policy for job '$JobName'", "Apply")) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\RetentionManager.psm1") -Force -ErrorAction Stop
            Invoke-BackupRetentionPolicy @retentionPolicyParams
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\RetentionManager.psm1' and its sub-modules exist and are not corrupted."
            & $LocalWriteLog -Message "[ERROR] LocalRetentionHandler: Could not load or execute the RetentionManager facade. Local retention skipped. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
    }
    else {
        & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler: Local retention policy for job '$JobName' skipped by user (ShouldProcess)." -Level "WARNING"
    }
    & $LocalWriteLog -Message "JobExecutor.LocalRetentionHandler/Invoke-PoShBackupLocalRetentionExecution: Local retention execution phase complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupLocalRetentionExecution
