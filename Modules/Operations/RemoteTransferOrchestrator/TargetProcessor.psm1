# Modules\Operations\RemoteTransferOrchestrator\TargetProcessor.psm1
<#
.SYNOPSIS
    A sub-module for RemoteTransferOrchestrator. Processes each remote target for a job.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupTargetProcessing' function. Its responsibility
    is to iterate through the list of configured remote targets for a job. For each target,
    it dynamically loads the correct provider module (e.g., UNC.Target.psm1) and then calls
    that provider's 'Invoke-PoShBackupTargetTransfer' function for each file that needs to be
    transferred. It aggregates the results of these transfers.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Changed parameter type to handle mock objects from simulation.
    DateCreated:    26-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the target iteration and transfer dispatch logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupTargetProcessing {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$LocalFilesToTransfer,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "TargetProcessor: Initialising processing for $($EffectiveJobConfig.ResolvedTargetInstances.Count) target(s)." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $allTransfersSuccessfulOverall = $true

    foreach ($targetInstanceConfig in $EffectiveJobConfig.ResolvedTargetInstances) {
        $targetInstanceName = $targetInstanceConfig._TargetInstanceName_
        $targetInstanceType = $targetInstanceConfig.Type
        & $LocalWriteLog -Message "  - TargetProcessor: Processing Target Instance: '$targetInstanceName' (Type: '$targetInstanceType')." -Level "INFO"

        $targetProviderModuleName = "$($targetInstanceType).Target.psm1"
        $targetProviderModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\Targets\$targetProviderModuleName"

        if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
            $errorMessage = "Target Provider module '$targetProviderModuleName' not found for target '$targetInstanceName'."
            $adviceMessage = "ADVICE: Please ensure the file exists at '$targetProviderModulePath'. If you have removed this file, you may need to restore it from the original project files."
            & $LocalWriteLog -Message "[ERROR] $errorMessage" -Level "ERROR"
            & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
            $reportData.TargetTransfers.Add(@{ TargetName = $targetInstanceName; TargetType = $targetInstanceType; Status = "Failure (Provider Not Found)"; ErrorMessage = $errorMessage })
            $allTransfersSuccessfulOverall = $false; continue
        }

        try {
            Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $invokeTargetTransferCmd = Get-Command Invoke-PoShBackupTargetTransfer -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1", "")) -ErrorAction SilentlyContinue
            if (-not $invokeTargetTransferCmd) { throw "Function 'Invoke-PoShBackupTargetTransfer' not found in provider module '$targetProviderModuleName'." }

            foreach ($fileToTransferInfo in $LocalFilesToTransfer) {
                $transferParams = @{
                    LocalArchivePath              = $fileToTransferInfo.FullName
                    TargetInstanceConfiguration   = $targetInstanceConfig
                    JobName                       = $JobName
                    ArchiveFileName               = $fileToTransferInfo.Name
                    ArchiveBaseName               = $EffectiveJobConfig.BaseFileName
                    ArchiveExtension              = $EffectiveJobConfig.JobArchiveExtension
                    IsSimulateMode                = $IsSimulateMode.IsPresent
                    Logger                        = $Logger
                    EffectiveJobConfig            = $EffectiveJobConfig
                    LocalArchiveSizeBytes         = $fileToTransferInfo.Length
                    PSCmdlet                      = $PSCmdlet
                }
                $transferOutcome = & $invokeTargetTransferCmd @transferParams

                $currentTransferReport = @{
                    TargetName            = $targetInstanceName; TargetType = $targetInstanceType; FileTransferred = $fileToTransferInfo.Name
                    Status                = if ($transferOutcome.Success) { "Success" } else { "Failure" }; RemotePath = $transferOutcome.RemotePath
                    ErrorMessage          = $transferOutcome.ErrorMessage; TransferDuration = if ($null -ne $transferOutcome.TransferDuration) { $transferOutcome.TransferDuration.ToString() } else { "N/A" }
                    TransferSize          = $transferOutcome.TransferSize; TransferSizeFormatted = $transferOutcome.TransferSizeFormatted
                }
                if ($transferOutcome.ContainsKey('ReplicationDetails')) { $currentTransferReport.ReplicationDetails = $transferOutcome.ReplicationDetails }

                $reportData.TargetTransfers.Add($currentTransferReport)

                if (-not $transferOutcome.Success) {
                    $allTransfersSuccessfulOverall = $false
                    & $LocalWriteLog -Message "[ERROR] TargetProcessor: Transfer of file '$($fileToTransferInfo.Name)' to Target '$targetInstanceName' FAILED. Reason: $($transferOutcome.ErrorMessage)" -Level "ERROR"
                    break # Stop transferring other files to this failed target
                }
            }
        }
        catch {
            & $LocalWriteLog -Message "[ERROR] TargetProcessor: Critical error during transfer processing for Target '$targetInstanceName'. Error: $($_.Exception.ToString())" -Level "ERROR"
            $allTransfersSuccessfulOverall = $false
        }

        if (-not $allTransfersSuccessfulOverall) {
             & $LocalWriteLog -Message "  - TargetProcessor: Halting further transfers to other targets for job '$JobName' due to failure with target '$targetInstanceName'." -Level "WARNING"
            break # Stop processing other targets
        }
    }

    return $allTransfersSuccessfulOverall
}

Export-ModuleMember -Function Invoke-PoShBackupTargetProcessing
