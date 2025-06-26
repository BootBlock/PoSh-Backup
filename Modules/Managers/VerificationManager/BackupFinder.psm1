# Modules\Managers\VerificationManager\BackupFinder.psm1
<#
.SYNOPSIS
    A sub-module for VerificationManager. Finds the target backup instances to be verified.
.DESCRIPTION
    This module provides the 'Find-VerificationTargets' function. It is responsible for
    locating the backup job specified in a verification configuration, finding all of its
    backup instances using the RetentionManager's scanner, and returning the most recent
    instances up to the requested count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To find and return the specific backup archives to be verified.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\VerificationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\RetentionManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VerificationManager\BackupFinder.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Find-VerificationTarget {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        # The name of the verification job being processed. Used for logging.
        [Parameter(Mandatory = $true)]
        [string]$VerificationJobName,

        # The specific verification job configuration hashtable.
        [Parameter(Mandatory = $true)]
        [hashtable]$VerificationJobConfig,

        # The complete PoSh-Backup configuration hashtable.
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    $targetJobName = Get-ConfigValue -ConfigObject $VerificationJobConfig -Key 'TargetJobName' -DefaultValue $null
    $testLatestCount = Get-ConfigValue -ConfigObject $VerificationJobConfig -Key 'TestLatestCount' -DefaultValue 1

    if ([string]::IsNullOrWhiteSpace($targetJobName)) {
        & $LocalWriteLog -Message "Verification Job '$VerificationJobName' is misconfigured. 'TargetJobName' is required. Skipping." -Level "ERROR"
        return @()
    }

    $targetBackupJobConfig = Get-ConfigValue -ConfigObject $GlobalConfig.BackupLocations -Key $targetJobName -DefaultValue $null
    if ($null -eq $targetBackupJobConfig) {
        & $LocalWriteLog -Message "Verification Job '$VerificationJobName': Target backup job '$targetJobName' not found in BackupLocations. Skipping." -Level "ERROR"
        return @()
    }

    # Determine the location and properties of the archives to find
    $destDirForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'DestinationDir' -DefaultValue $GlobalConfig.DefaultDestinationDir
    $baseNameForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'Name' -DefaultValue $targetJobName
    $primaryExtForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'ArchiveExtension' -DefaultValue $GlobalConfig.DefaultArchiveExtension
    $dateFormatForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'ArchiveDateFormat' -DefaultValue $GlobalConfig.DefaultArchiveDateFormat

    & $LocalWriteLog -Message "Verification Job '$VerificationJobName': Finding latest $testLatestCount backup(s) for '$targetJobName' in '$destDirForTargetJob'." -Level "INFO"
    
    $allInstances = Find-BackupArchiveInstance -DestinationDirectory $destDirForTargetJob `
        -ArchiveBaseFileName $baseNameForTargetJob `
        -ArchiveExtension $primaryExtForTargetJob `
        -ArchiveDateFormat $dateFormatForTargetJob `
        -Logger $Logger
    
    # We only verify unpinned backups
    $unpinnedInstances = $allInstances.GetEnumerator() | Where-Object { -not $_.Value.Pinned }
    $latestInstancesToTest = $unpinnedInstances | Sort-Object { $_.Value.SortTime } -Descending | Select-Object -First $testLatestCount

    if ($latestInstancesToTest.Count -eq 0) {
        & $LocalWriteLog -Message "Verification Job '$VerificationJobName': No unpinned backup instances found for '$targetJobName'. Nothing to verify." -Level "WARNING"
    }

    return $latestInstancesToTest
}

Export-ModuleMember -Function Find-VerificationTarget
