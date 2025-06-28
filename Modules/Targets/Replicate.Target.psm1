# Modules\Targets\Replicate.Target.psm1
<#
.SYNOPSIS
    Acts as a facade for the PoSh-Backup Target Provider for replicating a backup
    archive to multiple destinations.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for replicating
    a backup set (which can be a single file, or multiple volume parts plus a manifest)
    to several specified locations.

    It now acts as a facade, orchestrating calls to specialised sub-modules located
    in '.\Replicate\' for each step of the process:
    - Replicate.PathHandler.psm1: Ensures the remote directory structure exists.
    - Replicate.TransferAgent.psm1: Handles the actual file copy.
    - Replicate.RetentionApplicator.psm1: Manages the remote retention policy for each destination.

    The main exported functions are Invoke-PoShBackupTargetTransfer, Test-PoShBackupTargetConnectivity,
    and Invoke-PoShBackupReplicateTargetSettingsValidation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        3.0.0 # CRITICAL FIX: Major refactoring to use correct sub-modules.
    DateCreated:    19-May-2025
    LastModified:   28-Jun-2025
    Purpose:        Replicate Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$replicateSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Replicate"
try {
    # Import the new, correct sub-modules
    Import-Module -Name (Join-Path $replicateSubModulePath "Replicate.PathHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $replicateSubModulePath "Replicate.TransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $replicateSubModulePath "Replicate.RetentionApplicator.psm1") -Force -ErrorAction Stop
    # Import main Utils needed for facade-level functions
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Replicate.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Replicate Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "Replicate.Target/Test-PoShBackupTargetConnectivity: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    & $LocalWriteLog -Message "  - Replicate Target: Testing connectivity for all configured destination paths..." -Level "INFO"

    if (-not ($TargetSpecificSettings -is [array]) -or $TargetSpecificSettings.Count -eq 0) {
        return @{ Success = $false; Message = "TargetSpecificSettings is not a valid, non-empty array of destinations." }
    }

    $allPathsSuccessful = $true
    $messages = [System.Collections.Generic.List[string]]::new()

    $destinationIndex = 0
    foreach ($destination in $TargetSpecificSettings) {
        $destinationIndex++
        $destPath = $destination.Path
        $messagePrefix = "    - Destination $destinationIndex ('$destPath'): "
        
        if (-not $PSCmdlet.ShouldProcess($destPath, "Test Path Accessibility")) {
            $messages.Add("$messagePrefix Test skipped by user.")
            $allPathsSuccessful = $false
            continue
        }

        try {
            if (Test-Path -LiteralPath $destPath -PathType Container -ErrorAction Stop) {
                $messages.Add("$messagePrefix SUCCESS - Path is accessible.")
            }
            else {
                $messages.Add("$messagePrefix FAILED - Path not found or is not a directory.")
                $allPathsSuccessful = $false
            }
        }
        catch {
            $messages.Add("$messagePrefix FAILED - An error occurred while testing path. Error: $($_.Exception.Message)")
            $allPathsSuccessful = $false
        }
    }

    $finalMessage = "Replication Target Health Check: "
    $finalMessage += if ($allPathsSuccessful) { "All $($TargetSpecificSettings.Count) destination paths are accessible." } else { "One or more destination paths are not accessible." }
    $finalMessage += [Environment]::NewLine + ($messages -join [Environment]::NewLine)

    return @{ Success = $allPathsSuccessful; Message = $finalMessage }
}
#endregion

#region --- Replicate Target Settings Validation Function ---
function Invoke-PoShBackupReplicateTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )
    & $Logger -Message "Replicate.Target/Invoke-PoShBackupReplicateTargetSettingsValidation: Logger active for target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    if ($TargetInstanceConfiguration.ContainsKey('ContinueOnError') -and -not ($TargetInstanceConfiguration.ContinueOnError -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'ContinueOnError' must be a boolean (`$true` or `$false`) if defined.")
    }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    if (-not ($TargetSpecificSettings -is [array])) {
        $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' must be an Array.")
        return 
    }
    if ($TargetSpecificSettings.Count -eq 0) { $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': 'TargetSpecificSettings' array is empty.") }

    for ($i = 0; $i -lt $TargetSpecificSettings.Count; $i++) {
        $destConfig = $TargetSpecificSettings[$i]
        if (-not ($destConfig -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Item at index $i is not a Hashtable.")
            continue 
        }
        if (-not $destConfig.ContainsKey('Path') -or -not ($destConfig.Path -is [string]) -or [string]::IsNullOrWhiteSpace($destConfig.Path)) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i is missing 'Path'.")
        }
        if ($destConfig.ContainsKey('CreateJobNameSubdirectory') -and -not ($destConfig.CreateJobNameSubdirectory -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'CreateJobNameSubdirectory' must be a boolean.")
        }
        if ($destConfig.ContainsKey('RetentionSettings')) {
            if (-not ($destConfig.RetentionSettings -is [hashtable])) {
                $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'RetentionSettings' must be a Hashtable.")
            }
            elseif ($destConfig.RetentionSettings.ContainsKey('KeepCount') -and (-not ($destConfig.RetentionSettings.KeepCount -is [int]) -or $destConfig.RetentionSettings.KeepCount -le 0)) {
                $ValidationMessagesListRef.Value.Add("Replicate Target '$TargetInstanceName': Destination at index $i 'RetentionSettings.KeepCount' must be a positive integer.")
            }
        }
    }
}
#endregion

#region --- Replicate Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$JobName,
        [Parameter(Mandatory = $true)] [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)] [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)] [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)] [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] Replicate Target (Facade): Starting replication of file '{0}' for Job '{1}' to Target '{2}'." -f $ArchiveFileName, $JobName, $targetNameForLog) -Level "INFO"

    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allReplicationsForThisFileSucceeded = $true
    $aggregatedErrorMessagesForThisFile = [System.Collections.Generic.List[string]]::new()
    $replicationDetailsListForThisFile = [System.Collections.Generic.List[hashtable]]::new()

    $destinationConfigs = $TargetInstanceConfiguration.TargetSpecificSettings
    $continueOnError = if ($TargetInstanceConfiguration.ContainsKey('ContinueOnError')) { [bool]$TargetInstanceConfiguration.ContinueOnError } else { $false }
    
    $destinationIndex = 0
    foreach ($destConfig in $destinationConfigs) {
        $destinationIndex++
        $singleDestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $currentDestResult = @{ Success = $false; Path = 'N/A'; Error = 'Unknown Error'; Size = 0 }
        
        try {
            $destPathBase = $destConfig.Path.TrimEnd("\/")
            $destCreateJobSubDir = if ($destConfig.ContainsKey('CreateJobNameSubdirectory')) { $destConfig.CreateJobNameSubdirectory } else { $false }
            $destFinalDir = if ($destCreateJobSubDir) { Join-Path -Path $destPathBase -ChildPath $JobName } else { $destPathBase }
            $currentDestResult.Path = Join-Path -Path $destFinalDir -ChildPath $ArchiveFileName

            # 1. Ensure Path Exists
            $ensurePathResult = Set-ReplicateDestinationPath -Path $destFinalDir -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
            if (-not $ensurePathResult.Success) { throw ("Failed to ensure destination directory '$destFinalDir' exists. Error: " + $ensurePathResult.ErrorMessage) }

            # 2. Transfer the file
            $copyResult = Start-PoShBackupReplicationCopy -LocalSourcePath $LocalArchivePath -FullRemoteDestinationPath $currentDestResult.Path -Logger $Logger -PSCmdletInstance $PSCmdlet
            if (-not $copyResult.Success) { throw $copyResult.ErrorMessage }

            $currentDestResult.Success = $true
            $currentDestResult.Size = $LocalArchiveSizeBytes

            # 3. Apply Remote Retention for this destination
            if ($destConfig.ContainsKey('RetentionSettings') -and $destConfig.RetentionSettings -is [hashtable]) {
                Invoke-ReplicateRetentionPolicy -RetentionSettings $destConfig.RetentionSettings -RemoteDirectory $destFinalDir `
                    -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                    -Logger $Logger -PSCmdletInstance $PSCmdlet
            }
        }
        catch {
            $currentDestResult.Success = $false
            $currentDestResult.Error = $_.Exception.Message
        }

        $singleDestStopwatch.Stop(); $currentDestResult.Duration = $singleDestStopwatch.Elapsed
        $replicationDetailsListForThisFile.Add($currentDestResult)

        if (-not $currentDestResult.Success) {
            $allReplicationsForThisFileSucceeded = $false
            $aggregatedErrorMessagesForThisFile.Add("Dest#$($destinationIndex) ('$($destConfig.Path)'): $($currentDestResult.Error)")
            if (-not $continueOnError) {
                & $LocalWriteLog -Message "  - Replicate Target (Facade): Halting further replications for this file as ContinueOnError is false." -Level "WARNING"
                break
            }
        }
    }

    $overallStopwatch.Stop()
    $finalRemotePathDisplay = if ($allReplicationsForThisFileSucceeded) {
        "Replicated to $($replicationDetailsListForThisFile.Count) location(s) successfully."
    } else {
        "One or more replications failed. See details."
    }

    & $LocalWriteLog -Message ("[INFO] Replicate Target (Facade): Finished replication of file '{0}'. Overall Success: {1}." -f $ArchiveFileName, $allReplicationsForThisFileSucceeded) -Level "INFO"

    return @{
        Success            = $allReplicationsForThisFileSucceeded
        RemotePath         = $finalRemotePathDisplay
        ErrorMessage       = if ($aggregatedErrorMessagesForThisFile.Count -gt 0) { $aggregatedErrorMessagesForThisFile -join "; " } else { $null }
        TransferSize       = $LocalArchiveSizeBytes
        TransferDuration   = $overallStopwatch.Elapsed
        ReplicationDetails = $replicationDetailsListForThisFile
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupReplicateTargetSettingsValidation, Test-PoShBackupTargetConnectivity
