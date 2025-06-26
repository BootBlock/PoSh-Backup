# Modules\Operations\LocalArchiveProcessor\ArchiveCreator.psm1
<#
.SYNOPSIS
    A sub-module for LocalArchiveProcessor.psm1. Handles the core 7-Zip archive creation.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupArchiveCreation' function. It is responsible
    for taking the fully resolved configuration and source paths, calling the 7ZipManager
    to build the argument list, and then executing the 7-Zip process to create the physical
    archive file(s). It returns the results of the 7-Zip operation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To isolate the 7-Zip archive creation process.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations\LocalArchiveProcessor
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ArchiveCreator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupArchiveCreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string[]]$CurrentJobSourcePathFor7Zip,
        [Parameter(Mandatory = $true)]
        [string]$FinalArchivePathFor7ZipCommand,
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordPlainText,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "ArchiveCreator: Initialising for job '$($EffectiveJobConfig.BaseFileName)'." -Level "DEBUG"

    # 1. Build the 7-Zip arguments
    $get7ZipArgsParams = @{
        EffectiveConfig             = $EffectiveJobConfig
        FinalArchivePath            = $FinalArchivePathFor7ZipCommand
        CurrentJobSourcePathFor7Zip = $CurrentJobSourcePathFor7Zip
        Logger                      = $Logger
    }
    $sevenZipArgsArray = Get-PoShBackup7ZipArgument @get7ZipArgsParams

    # 2. Sanitise TreatWarningsAsSuccess value before passing it
    $sanitizedTreatWarnings = $false
    $rawValueForWarnings = $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess
    if ($rawValueForWarnings -is [bool]) { $sanitizedTreatWarnings = $rawValueForWarnings }
    elseif ($rawValueForWarnings -is [string] -and $rawValueForWarnings.ToLowerInvariant() -eq 'true') { $sanitizedTreatWarnings = $true }
    elseif ($rawValueForWarnings -is [int] -and $rawValueForWarnings -ne 0) { $sanitizedTreatWarnings = $true }

    # 3. Prepare parameters for the 7-Zip executor
    $sevenZipPathGlobal = $EffectiveJobConfig.GlobalConfigRef.SevenZipPath
    $zipOpParams = @{
        SevenZipPathExe           = $sevenZipPathGlobal
        SevenZipArguments         = $sevenZipArgsArray
        ProcessPriority           = $EffectiveJobConfig.JobSevenZipProcessPriority
        SevenZipCpuAffinityString = $EffectiveJobConfig.JobSevenZipCpuAffinity
        PlainTextPassword         = $ArchivePasswordPlainText
        HideOutput                = $EffectiveJobConfig.HideSevenZipOutput
        MaxRetries                = $EffectiveJobConfig.JobMaxRetryAttempts
        RetryDelaySeconds         = $EffectiveJobConfig.JobRetryDelaySeconds
        EnableRetries             = $EffectiveJobConfig.JobEnableRetries
        TreatWarningsAsSuccess    = $sanitizedTreatWarnings
        IsSimulateMode            = $IsSimulateMode.IsPresent
        Logger                    = $Logger
        PSCmdlet                  = $PSCmdlet
    }

    # 4. Execute the operation
    Write-ConsoleBanner -NameText "Creating Backup for" -ValueText $EffectiveJobConfig.BaseFileName -CenterText -PrependNewLine
    $sevenZipResult = Invoke-7ZipOperation @zipOpParams

    & $LocalWriteLog -Message "ArchiveCreator: 7-Zip process completed with exit code $($sevenZipResult.ExitCode)." -Level "DEBUG"
    return $sevenZipResult
}

Export-ModuleMember -Function Invoke-PoShBackupArchiveCreation
