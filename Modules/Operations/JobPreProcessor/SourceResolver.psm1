# Modules\Operations\JobPreProcessor\SourceResolver.psm1
<#
.SYNOPSIS
    A sub-module for JobPreProcessor.psm1. Resolves the final source paths for the backup.
.DESCRIPTION
    This module provides the 'Resolve-PoShBackupSourcePath' function. It contains the
    critical logic for determining the final, stable source path(s) for the backup operation.
    It orchestrates calls to either the SnapshotManager (for infrastructure-level snapshots
    like Hyper-V) or the VssManager (for OS-level Volume Shadow Copies) based on the job's
    configuration. It now lazy-loads these manager modules to improve performance.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load VssManager and SnapshotManager.
    DateCreated:    26-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the snapshot/VSS source resolution logic.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

function Resolve-PoShBackupSourcePath {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string[]]$InitialSourcePaths,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "SourceResolver: Initialising for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $finalSourcePathsFor7Zip = $InitialSourcePaths
    $vssPathsInUse = $null
    $snapshotSession = $null

    # --- Snapshot / VSS Orchestration ---
    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SnapshotProviderName)) {
        & $LocalWriteLog -Message "`n[INFO] SourceResolver: Infrastructure Snapshot Provider '($($EffectiveJobConfig.SnapshotProviderName))' is configured for job '$JobName'." -Level "INFO"
        $reportData.SnapshotAttempted = $true
        if ($EffectiveJobConfig.SourceIsVMName -ne $true) { throw "Job '$JobName' has a SnapshotProviderName defined but 'SourceIsVMName' is not `$true. This configuration is currently unsupported." }

        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\SnapshotManager.psm1") -Force -ErrorAction Stop
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\SnapshotManager.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] SourceResolver: Could not load the SnapshotManager module. Job cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw
        }

        $snapshotProviderConfig = $EffectiveJobConfig.GlobalConfigRef.SnapshotProviders[$EffectiveJobConfig.SnapshotProviderName]
        if ($null -eq $snapshotProviderConfig) { throw "Snapshot provider '$($EffectiveJobConfig.SnapshotProviderName)' (for job '$JobName') is not defined in the global 'SnapshotProviders' section." }

        $vmName = ($InitialSourcePaths | Select-Object -First 1)
        $subPaths = @($InitialSourcePaths | Select-Object -Skip 1)

        $snapshotParams = @{
            JobName                 = $JobName; SnapshotProviderConfig  = $snapshotProviderConfig
            ResourceToSnapshot      = $vmName; IsSimulateMode          = $IsSimulateMode.IsPresent
            Logger                  = $Logger; PSCmdlet                = $PSCmdletInstance
            PSScriptRootForPaths    = $EffectiveJobConfig.GlobalConfigRef['_PoShBackup_PSScriptRoot']
        }
        $snapshotSession = New-PoShBackupSnapshot @snapshotParams
        if ($null -ne $snapshotSession -and $snapshotSession.Success) {
            $mountedPaths = Get-PoShBackupSnapshotPath -SnapshotSession $snapshotSession -Logger $Logger
            if ($null -ne $mountedPaths -and $mountedPaths.Count -gt 0) {
                if ($subPaths.Count -gt 0) {
                    $translatedPaths = [System.Collections.Generic.List[string]]::new()
                    foreach ($subPath in $subPaths) {
                        if ($subPath -match "^([a-zA-Z]):\\(.*)$") {
                            $guestRelativePath = $Matches[2]
                            $hostDriveLetter = ([string]$mountedPaths[0]).TrimEnd(":")
                            $newPath = Join-Path -Path "$($hostDriveLetter):\" -ChildPath $guestRelativePath
                            $translatedPaths.Add($newPath)
                        } else { & $LocalWriteLog -Message "[WARNING] SourceResolver: Sub-path '$subPath' is not in a recognized format (e.g., 'C:\Path'). It will be ignored." -Level "WARNING" }
                    }
                    $finalSourcePathsFor7Zip = $translatedPaths.ToArray()
                    $reportData.SnapshotStatus = "Used Successfully (Sub-Paths: $($finalSourcePathsFor7Zip -join ', '))"
                } else {
                    $finalSourcePathsFor7Zip = $mountedPaths.ToArray()
                    $reportData.SnapshotStatus = "Used Successfully (Full Disks: $($finalSourcePathsFor7Zip -join ', '))"
                }
            } else { throw "Snapshot session '$($snapshotSession.SessionId)' was created but failed to return any mount paths." }
        } else {
            $snapshotError = if ($null -ne $snapshotSession) { $snapshotSession.ErrorMessage } else { "SnapshotManager returned a null session object." }
            throw "Infrastructure snapshot creation failed for job '$JobName'. Reason: $snapshotError"
        }
    }
    elseif ($EffectiveJobConfig.JobEnableVSS) {
        & $LocalWriteLog -Message "`n[INFO] SourceResolver: VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
        $reportData.VSSAttempted = $true

        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\VssManager.psm1") -Force -ErrorAction Stop
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\VssManager.psm1' and its sub-modules exist and are not corrupted."
            & $LocalWriteLog -Message "[FATAL] SourceResolver: Could not load the VssManager module. Job cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw
        }

        if (-not (Test-AdminPrivilege -Logger $Logger)) { throw "VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." }

        $vssParams = @{
            SourcePathsToShadow = $InitialSourcePaths; VSSContextOption = $EffectiveJobConfig.JobVSSContextOption
            MetadataCachePath = $EffectiveJobConfig.VSSMetadataCachePath; PollingTimeoutSeconds = $EffectiveJobConfig.VSSPollingTimeoutSeconds
            PollingIntervalSeconds = $EffectiveJobConfig.VSSPollingIntervalSeconds; IsSimulateMode = $IsSimulateMode.IsPresent
            Logger = $Logger; PSCmdlet = $PSCmdletInstance
        }
        $VSSPathsInUse = New-VSSShadowCopy @vssParams

        if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
            & $LocalWriteLog -Message "  - SourceResolver: VSS shadow copies created/mapped. Using shadow paths for backup." -Level VSS
            $finalSourcePathsFor7Zip = $InitialSourcePaths | ForEach-Object { if ($VSSPathsInUse.ContainsKey($_)) { $VSSPathsInUse[$_] } else { $_ } }
            $reportData.VSSShadowPaths = $VSSPathsInUse
            $reportData.VSSStatus = "Used Successfully"
        } elseif ($EffectiveJobConfig.JobEnableVSS -and ($null -eq $VSSPathsInUse)) {
            $reportData.VSSStatus = "Failed (Creation Error)"
            throw "VSS shadow copy creation failed for job '$JobName'. Check VSSManager logs."
        }
    } else {
        $reportData.VSSAttempted = $false; $reportData.VSSStatus = "Not Enabled"
        $reportData.SnapshotAttempted = $false; $reportData.SnapshotStatus = "Not Enabled"
    }

    $reportData.EffectiveSourcePath = if ($finalSourcePathsFor7Zip -is [array]) { $finalSourcePathsFor7Zip } else { @($finalSourcePathsFor7Zip) }

    return @{
        Success                     = $true
        FinalSourcePathsFor7Zip     = $finalSourcePathsFor7Zip
        VSSPathsToCleanUp           = $vssPathsInUse
        SnapshotSessionToCleanUp    = $snapshotSession
    }
}

Export-ModuleMember -Function Resolve-PoShBackupSourcePath
