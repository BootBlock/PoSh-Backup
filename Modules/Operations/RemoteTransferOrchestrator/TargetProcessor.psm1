# Modules\Operations\RemoteTransferOrchestrator\TargetProcessor.psm1
<#
.SYNOPSIS
    A sub-module for RemoteTransferOrchestrator. Processes each remote target for a job.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupTargetProcessing' function. Its responsibility
    is to iterate through the list of configured remote targets for a job. For each target,
    it now starts a parallel thread job to dynamically load the correct provider module
    (e.g., UNC.Target.psm1) and then call that provider's 'Invoke-PoShBackupTargetTransfer'
    function for each file that needs to be transferred. It then waits for all parallel jobs
    to complete and aggregates their results.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.2 # Corrected PSSA warnings for unused parameters in mock PSCmdlet.
    DateCreated:    26-Jun-2025
    LastModified:   29-Jun-2025
    Purpose:        To isolate the target iteration and transfer dispatch logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Internal Helper: Process a Single Target ---
# This function contains the logic to be run inside each parallel thread job.
function Invoke-SingleTargetTransferInternal {
    param(
        [hashtable]$TargetInstanceConfig,
        [System.Collections.Generic.List[object]]$LocalFilesToTransfer,
        [string]$JobName,
        [string]$PSScriptRootForPaths,
        [hashtable]$EffectiveJobConfig,
        [bool]$WhatIfPreference
    )

    # Recreate a mock PSCmdlet object for ShouldProcess within the thread job
    $mockLogger = { param($Message, $Level) Write-Host "[$Level] $Message" } # Simple console logger for thread
    $mockPSCmdlet = [pscustomobject]@{
        ShouldProcess = {
            param($target, $action)
            # If -WhatIf was used, ShouldProcess should always return false to simulate
            if ($WhatIfPreference) {
                $whatIfMessage = "WhatIf: Performing the operation '$action' on target '$target'."
                # We can't use the main logger, so we write to the job's host output stream.
                Write-Host $whatIfMessage
                return $false
            }
            # A full implementation of -Confirm is complex inside a thread job and is omitted for now.
            # The primary goal is to respect -WhatIf / -Simulate.
            return $true
        }
    }

    $targetInstanceName = $TargetInstanceConfig._TargetInstanceName_
    $targetInstanceType = $TargetInstanceConfig.Type
    $targetProviderModuleName = "$($targetInstanceType).Target.psm1"
    $targetProviderModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\Targets\$targetProviderModuleName"

    $fileTransferResults = [System.Collections.Generic.List[hashtable]]::new()
    $allFilesForThisTargetSucceeded = $true

    if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
        $errorMessage = "Target Provider module '$targetProviderModuleName' not found for target '$targetInstanceName'."
        $fileTransferResults.Add(@{
            TargetName = $targetInstanceName; TargetType = $targetInstanceType; Status = "Failure (Provider Not Found)"
            ErrorMessage = $errorMessage
        })
        return @{ Success = $false; FileResults = $fileTransferResults }
    }

    try {
        Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop

        $invokeTargetTransferCmd = Get-Command Invoke-PoShBackupTargetTransfer -ErrorAction Stop
        
        foreach ($fileToTransferInfo in $LocalFilesToTransfer) {
            $transferParams = @{
                LocalArchivePath              = $fileToTransferInfo.FullName
                TargetInstanceConfiguration   = $TargetInstanceConfig
                JobName                       = $JobName
                ArchiveFileName               = $fileToTransferInfo.Name
                ArchiveBaseName               = $EffectiveJobConfig.BaseFileName
                ArchiveExtension              = $EffectiveJobConfig.JobArchiveExtension
                ArchiveDateFormat             = $EffectiveJobConfig.JobArchiveDateFormat
                IsSimulateMode                = $WhatIfPreference # Use this to drive simulation in the provider
                Logger                        = $mockLogger
                EffectiveJobConfig            = $EffectiveJobConfig
                LocalArchiveSizeBytes         = $fileToTransferInfo.Length
                PSCmdlet                      = $mockPSCmdlet
            }
            $transferOutcome = & $invokeTargetTransferCmd @transferParams

            $fileTransferResults.Add($transferOutcome)

            if (-not $transferOutcome.Success) {
                $allFilesForThisTargetSucceeded = $false
                break
            }
        }
    }
    catch {
        $allFilesForThisTargetSucceeded = $false
        $fileTransferResults.Add(@{
            TargetName = $targetInstanceName; TargetType = $targetInstanceType; Status = "Failure (Critical Error)"
            ErrorMessage = "Critical error processing target provider '$targetProviderModuleName'. Error: $($_.Exception.Message)"
        })
    }

    return @{ Success = $allFilesForThisTargetSucceeded; FileResults = $fileTransferResults }
}
#endregion

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
    & $LocalWriteLog -Message "TargetProcessor: Initialising parallel processing for $($EffectiveJobConfig.ResolvedTargetInstances.Count) target(s)." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $allTransfersSuccessfulOverall = $true
    $runningJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

    try {
        # Determine the effective -WhatIf state BEFORE starting the jobs.
        $useWhatIf = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf') -or $IsSimulateMode.IsPresent

        foreach ($targetInstanceConfig in $EffectiveJobConfig.ResolvedTargetInstances) {
            $targetInstanceName = $targetInstanceConfig._TargetInstanceName_
            & $LocalWriteLog -Message "  - TargetProcessor: Starting parallel transfer job for Target Instance: '$targetInstanceName'." -Level "INFO"
            
            $scriptBlock = ${function:Invoke-SingleTargetTransferInternal}
            # Pass simple boolean/string values instead of the complex $PSCmdlet automatic variable.
            $argumentList = @(
                $targetInstanceConfig, $LocalFilesToTransfer, $JobName,
                $PSScriptRootForPaths, $EffectiveJobConfig,
                $useWhatIf
            )

            $job = Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList $argumentList -Name "PoShBackup_Transfer_$($targetInstanceName)"
            $runningJobs.Add($job)
        }

        & $LocalWriteLog -Message "  - TargetProcessor: All $($runningJobs.Count) parallel transfer jobs have been started. Waiting for completion..." -Level "INFO"
        $runningJobs | Wait-Job | Out-Null
        & $LocalWriteLog -Message "  - TargetProcessor: All parallel jobs completed. Collecting results..." -Level "INFO"

        foreach ($job in $runningJobs) {
            $jobResult = Receive-Job -Job $job
            
            if ($job.State -ne 'Completed' -or $null -eq $jobResult) {
                $allTransfersSuccessfulOverall = $false
                $errorMessage = "Parallel transfer job '$($job.Name)' failed with state '$($job.State)'."
                if ($job.Error.Count -gt 0) {
                    $errorMessage += " Error: $($job.Error[0].Exception.Message)"
                }
                & $LocalWriteLog -Message $errorMessage -Level "ERROR"
                $advice = "ADVICE: An unhandled error occurred in a parallel job. This may be due to a missing module dependency in the new thread scope. Ensure all required modules (e.g., Posh-SSH, AWS.Tools.S3) are fully installed and accessible."
                & $LocalWriteLog -Message $advice -Level "ADVICE"
                $reportData.TargetTransfers.Add(@{ TargetName = $job.Name; Status = "Failure (Job Failed)"; ErrorMessage = $errorMessage })
            } else {
                if (-not $jobResult.Success) { $allTransfersSuccessfulOverall = $false }
                
                # Add the detailed file-by-file results to the main report
                foreach($fileResult in $jobResult.FileResults) {
                    $reportData.TargetTransfers.Add($fileResult)
                }
            }
        }
    }
    catch {
        $allTransfersSuccessfulOverall = $false
        & $LocalWriteLog -Message "[ERROR] A critical error occurred while managing parallel transfer jobs: $($_.Exception.Message)" -Level "ERROR"
    }
    finally {
        # Crucial cleanup step
        if ($runningJobs.Count -gt 0) {
            & $LocalWriteLog -Message "  - TargetProcessor: Cleaning up $($runningJobs.Count) job objects." -Level "DEBUG"
            $runningJobs | ForEach-Object { Remove-Job -Job $_ }
        }
    }
    
    return $allTransfersSuccessfulOverall
}

Export-ModuleMember -Function Invoke-PoShBackupTargetProcessing
