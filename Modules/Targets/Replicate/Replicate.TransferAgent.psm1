# Modules\Targets\Replicate\Replicate.TransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for Replicate.Target.psm1. Handles the file copy operation.
.DESCRIPTION
    This module provides the 'Start-PoShBackupReplicationCopy' function. It is responsible
    for transferring a single file to a single replication destination using Copy-Item.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the file copy logic for the Replicate target.
    Prerequisites:  PowerShell 5.1+.
#>

function Start-PoShBackupReplicationCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$FullRemoteDestinationPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "Replicate.Target/TransferAgent: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $PSCmdletInstance.ShouldProcess($FullRemoteDestinationPath, "Copy File to Replicate Destination")) {
        return @{ Success = $false; ErrorMessage = "File copy to '$FullRemoteDestinationPath' skipped by user." }
    }

    try {
        & $LocalWriteLog -Message "      - TransferAgent: Copying file '$LocalSourcePath' to '$FullRemoteDestinationPath'..." -Level "DEBUG"
        Copy-Item -LiteralPath $LocalSourcePath -Destination $FullRemoteDestinationPath -Force -ErrorAction Stop
        return @{ Success = $true }
    }
    catch {
        return @{ Success = $false; ErrorMessage = "Failed to copy file to '$FullRemoteDestinationPath'. Error: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Start-PoShBackupReplicationCopy
