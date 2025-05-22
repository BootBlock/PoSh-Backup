<#
.SYNOPSIS
    Manages Volume Shadow Copy Service (VSS) operations for PoSh-Backup.
    This includes creating shadow copies of volumes, tracking their IDs,
    and ensuring their proper cleanup after backup operations.

.DESCRIPTION
    The VssManager module centralizes all interactions with the Windows VSS subsystem
    via the diskshadow.exe command-line utility. It provides functions to:
    - Create VSS shadow copies for specified source paths, handling unique volume determination
      and diskshadow script generation.
    - Poll for the availability of created shadow copies using CIM.
    - Map original source paths to their corresponding VSS shadow copy paths.
    - Track the IDs of created shadow copies for the current script run to ensure
      only relevant shadows are cleaned up.
    - Remove specific shadow copies by ID or all tracked shadow copies for the run.

    This module relies on utility functions (like Write-LogMessage, Test-AdminPrivilege)
    being made available globally by the main PoSh-Backup script importing Utils.psm1, or by
    passing a logger reference.
    Administrator privileges are required for all VSS operations.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3
    DateCreated:    17-May-2025
    LastModified:   18-May-2025
    Purpose:        Centralised VSS management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Administrator privileges.
                    Core PoSh-Backup module Utils.psm1 (for Write-LogMessage, Test-AdminPrivilege)
                    should be loaded by the parent script, or logger passed explicitly.
#>

# Module-scoped variable to track VSS shadow IDs created during the current script run (keyed by PID)
# This helps ensure that only shadows created by this specific invocation of PoSh-Backup are targeted for cleanup.
$Script:VssManager_ScriptRunVSSShadowIDs = @{} 

#region --- Internal VSS Helper Functions ---

# Internal helper to remove a specific VSS shadow by ID.
# Not exported as it's primarily called by New-VSSShadowCopy for its own error handling,
# or by the main Remove-VSSShadowCopy.
function Remove-VssManagerShadowCopyByIdInternal {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param (
        [Parameter(Mandatory)] [string]$ShadowID,
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Remove-VssManagerShadowCopyByIdInternal: Logger parameter active for ShadowID '$ShadowID'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (-not $PSCmdlet.ShouldProcess("VSS Shadow ID $ShadowID", "Delete using diskshadow.exe")) {
        & $LocalWriteLog -Message "  - VSS shadow ID $ShadowID deletion skipped by user (ShouldProcess)." -Level WARNING
        return
    }

    & $LocalWriteLog -Message "  - VssManager: Attempting cleanup of specific VSS shadow ID: $ShadowID" -Level VSS
    $diskshadowScriptContentSingle = "SET VERBOSE ON`nDELETE SHADOWS ID $ShadowID`n"
    $tempScriptPathSingle = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_single_$(Get-Random).txt"
    try { $diskshadowScriptContentSingle | Set-Content -Path $tempScriptPathSingle -Encoding UTF8 -ErrorAction Stop }
    catch { & $LocalWriteLog -Message "[ERROR] VssManager: Failed to write single VSS shadow delete script to '$tempScriptPathSingle'. Manual cleanup of ID $ShadowID may be required. Error: $($_.Exception.Message)" -Level ERROR; return}

    if (-not $IsSimulateMode.IsPresent) {
        $procDeleteSingle = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathSingle`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
        if ($procDeleteSingle.ExitCode -ne 0) {
            & $LocalWriteLog -Message "[WARNING] VssManager: diskshadow.exe failed to delete specific VSS shadow ID $ShadowID. Exit Code: $($procDeleteSingle.ExitCode). Manual cleanup may be needed." -Level WARNING
        } else {
            & $LocalWriteLog -Message "    - VssManager: Successfully initiated deletion of VSS shadow ID $ShadowID." -Level VSS
        }
    } else {
         & $LocalWriteLog -Message "SIMULATE: VssManager would execute diskshadow.exe to delete VSS shadow ID $ShadowID." -Level SIMULATE
    }
    Remove-Item -LiteralPath $tempScriptPathSingle -Force -ErrorAction SilentlyContinue
}
#endregion

#region --- Exported VSS Functions ---

function New-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    <#
    .SYNOPSIS
        Creates VSS shadow copies for the specified source paths.
    .DESCRIPTION
        This function orchestrates the creation of Volume Shadow Copies for the volumes
        associated with the given source paths. It generates a diskshadow script, executes it,
        polls for the shadow copy details via CIM, and maps the original paths to their
        shadow copy equivalents. It tracks created shadow IDs for later cleanup.
        Requires Administrator privileges.
    .PARAMETER SourcePathsToShadow
        An array of full paths for which VSS shadow copies are desired.
    .PARAMETER VSSContextOption
        The 'SET CONTEXT' option for diskshadow.exe (e.g., "Persistent NoWriters", "Volatile NoWriters").
    .PARAMETER MetadataCachePath
        The path for diskshadow's metadata cache file. Environment variables will be expanded.
    .PARAMETER PollingTimeoutSeconds
        Maximum time in seconds to wait for shadow copies to become available.
    .PARAMETER PollingIntervalSeconds
        How often in seconds to poll for shadow copy availability.
    .PARAMETER IsSimulateMode
        If $true, VSS creation is simulated, and plausible shadow paths are returned.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        A hashtable mapping original source paths to their VSS shadow copy paths if successful.
        Returns $null on failure or if no valid volumes are found.
    .EXAMPLE
        # $shadowMap = New-VSSShadowCopy -SourcePathsToShadow "C:\Data", "D:\Logs" -VSSContextOption "Volatile NoWriters" ... -Logger ${function:Write-LogMessage}
        # if ($shadowMap) { # Use $shadowMap.Values for backup }
    #>
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath, # Already expanded by caller (Operations.psm1)
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "New-VSSShadowCopy: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        $Script:VssManager_ScriptRunVSSShadowIDs[$runKey] = @{}
    }
    $currentCallShadowIDs = $Script:VssManager_ScriptRunVSSShadowIDs[$runKey]

    & $LocalWriteLog -Message "`n[INFO] VssManager: Initialising Volume Shadow Copy Service (VSS) operations..." -Level "VSS"
    $mappedShadowPaths = @{}

    $volumesToShadow = $SourcePathsToShadow | ForEach-Object {
        try { (Get-Item -LiteralPath $_ -ErrorAction Stop).PSDrive.Name + ":" } catch { & $LocalWriteLog -Message "[WARNING] VssManager: Could not determine volume for source path '$_'. It will be skipped for VSS snapshotting." -Level WARNING; $null }
    } | Where-Object {$null -ne $_} | Select-Object -Unique

    if ($volumesToShadow.Count -eq 0) {
        & $LocalWriteLog -Message "[WARNING] VssManager: No valid volumes determined from source paths to create shadow copies for." -Level WARNING
        return $null
    }

    $diskshadowScriptContent = @"
SET CONTEXT $VSSContextOption
SET METADATA CACHE "$MetadataCachePath"
SET VERBOSE ON
$($volumesToShadow | ForEach-Object { "ADD VOLUME $_ ALIAS Vol_$($_ -replace ':','')" })
CREATE
"@
    $tempDiskshadowScriptFile = Join-Path -Path $env:TEMP -ChildPath "diskshadow_create_vss_$(Get-Random).txt"
    try { $diskshadowScriptContent | Set-Content -Path $tempDiskshadowScriptFile -Encoding UTF8 -ErrorAction Stop }
    catch { & $LocalWriteLog -Message "[ERROR] VssManager: Failed to write diskshadow script to '$tempDiskshadowScriptFile'. VSS creation aborted. Error: $($_.Exception.Message)" -Level ERROR; return $null }

    & $LocalWriteLog -Message "  - VssManager: Generated diskshadow script: '$tempDiskshadowScriptFile' (Context: $VSSContextOption, Cache: '$MetadataCachePath')" -Level VSS

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: VssManager would execute diskshadow with script '$tempDiskshadowScriptFile' for volumes: $($volumesToShadow -join ', ')" -Level SIMULATE
        $SourcePathsToShadow | ForEach-Object {
            $currentSourcePath = $_
            try {
                $vol = (Get-Item -LiteralPath $currentSourcePath -ErrorAction Stop).PSDrive.Name + ":"
                $relativePathSimulated = $currentSourcePath -replace [regex]::Escape($vol), ""
                $simulatedIndex = [array]::IndexOf($SourcePathsToShadow, $currentSourcePath) + 1
                if ($simulatedIndex -le 0) { $simulatedIndex = Get-Random -Minimum 1000 -Maximum 9999 }
                $mappedShadowPaths[$currentSourcePath] = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopySIMULATED$($simulatedIndex)$relativePathSimulated"
            } catch {
                 & $LocalWriteLog -Message "SIMULATE: VssManager could not determine volume for '$currentSourcePath' for simulated shadow path." -Level SIMULATE
                 $mappedShadowPaths[$currentSourcePath] = "$currentSourcePath (Original Path - VSS Simulation)"
            }
        }
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $mappedShadowPaths
    }

    if (-not $PSCmdlet.ShouldProcess("Volumes: $($volumesToShadow -join ', ')", "Create VSS Shadow Copies (diskshadow.exe)")) {
        & $LocalWriteLog -Message "  - VssManager: VSS shadow copy creation skipped by user (ShouldProcess)." -Level WARNING
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    & $LocalWriteLog -Message "  - VssManager: Executing diskshadow.exe. This may take a moment..." -Level VSS
    $process = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempDiskshadowScriptFile`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
    Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
        & $LocalWriteLog -Message "[ERROR] VssManager: diskshadow.exe failed to create shadow copies. Exit Code: $($process.ExitCode). Check system event logs." -Level ERROR
        return $null
    }

    & $LocalWriteLog -Message "  - VssManager: Diskshadow command completed. Polling CIM for shadow details (Timeout: ${PollingTimeoutSeconds}s)..." -Level VSS
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allVolumesSuccessfullyShadowed = $false
    $foundShadowsForThisSpecificCall = @{}

    while ($stopwatch.Elapsed.TotalSeconds -lt $PollingTimeoutSeconds) {
        $cimShadowsThisPoll = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue |
                              Where-Object { $_.InstallDate -gt (Get-Date).AddMinutes(-5) }

        if ($null -ne $cimShadowsThisPoll) {
            foreach ($volName in $volumesToShadow) {
                if (-not $foundShadowsForThisSpecificCall.ContainsKey($volName)) {
                    $candidateShadow = $cimShadowsThisPoll |
                                       Where-Object { $_.VolumeName -eq $volName -and (-not $currentCallShadowIDs.ContainsValue($_.ID)) } |
                                       Sort-Object InstallDate -Descending |
                                       Select-Object -First 1
                    if ($null -ne $candidateShadow) {
                        & $LocalWriteLog -Message "  - VssManager: Found shadow via CIM for volume '$volName': Device '$($candidateShadow.DeviceObject)' (ID: $($candidateShadow.ID))" -Level VSS
                        $currentCallShadowIDs[$volName] = $candidateShadow.ID
                        $foundShadowsForThisSpecificCall[$volName] = $candidateShadow.DeviceObject
                    }
                }
            }
        }
        if ($foundShadowsForThisSpecificCall.Keys.Count -eq $volumesToShadow.Count) {
            $allVolumesSuccessfullyShadowed = $true; break
        }
        Start-Sleep -Seconds $PollingIntervalSeconds
        & $LocalWriteLog -Message "  - VssManager: Polling CIM for shadow copies... ($([math]::Round($stopwatch.Elapsed.TotalSeconds))s / ${PollingTimeoutSeconds}s remaining)" -Level "VSS" -NoTimestampToLogFile ($stopwatch.Elapsed.TotalSeconds -ge $PollingIntervalSeconds)
    }
    $stopwatch.Stop()

    if (-not $allVolumesSuccessfullyShadowed) {
        & $LocalWriteLog -Message "[ERROR] VssManager: Timed out or failed to find all required shadow copies via CIM after $PollingTimeoutSeconds seconds." -Level ERROR
        $foundShadowsForThisSpecificCall.Keys | ForEach-Object {
            $volNameToClean = $_
            if ($currentCallShadowIDs.ContainsKey($volNameToClean)) {
                Remove-VssManagerShadowCopyByIdInternal -ShadowID $currentCallShadowIDs[$volNameToClean] -IsSimulateMode:$IsSimulateMode -Logger $Logger # Pass logger
                $currentCallShadowIDs.Remove($volNameToClean)
            }
        }
        return $null
    }

    $SourcePathsToShadow | ForEach-Object {
        $originalFullPath = $_
        try {
            $volNameOfPath = (Get-Item -LiteralPath $originalFullPath -ErrorAction Stop).PSDrive.Name + ":"
            if ($foundShadowsForThisSpecificCall.ContainsKey($volNameOfPath)) {
                $shadowDevicePath = $foundShadowsForThisSpecificCall[$volNameOfPath]
                $relativePath = $originalFullPath -replace [regex]::Escape($volNameOfPath), ""
                $mappedShadowPaths[$originalFullPath] = Join-Path -Path $shadowDevicePath -ChildPath $relativePath.TrimStart('\')
                & $LocalWriteLog -Message "    - VssManager: Mapped source '$originalFullPath' to VSS shadow path '$($mappedShadowPaths[$originalFullPath])'" -Level VSS
            } else {
                & $LocalWriteLog -Message "[WARNING] VssManager: Could not map '$originalFullPath' as its volume shadow ('$volNameOfPath') was not found in this call." -Level WARNING
            }
        } catch {
            & $LocalWriteLog -Message "[WARNING] VssManager: Error during VSS mapping for '$originalFullPath': $($_.Exception.Message)." -Level WARNING
        }
    }
    if ($mappedShadowPaths.Count -eq 0 -and $SourcePathsToShadow.Count -gt 0) {
         & $LocalWriteLog -Message "[ERROR] VssManager: Failed to map ANY source paths to VSS shadow paths. Critical VSS issue." -Level ERROR
         return $null
    }
    if ($mappedShadowPaths.Count -lt $SourcePathsToShadow.Count) {
        & $LocalWriteLog -Message "[WARNING] VssManager: Not all source paths mapped to VSS. Unmapped paths will use original files." -Level WARNING
    }
    return $mappedShadowPaths
}

function Remove-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    <#
    .SYNOPSIS
        Removes all VSS shadow copies tracked for the current PoSh-Backup script run.
    .DESCRIPTION
        This function iterates through the VSS shadow copy IDs that were created and tracked
        by 'New-VSSShadowCopy' during the current script execution (scoped by PID) and
        attempts to delete them using diskshadow.exe. This is crucial for cleanup, especially
        for persistent shadow copies.
    .PARAMETER IsSimulateMode
        If $true, VSS deletion is simulated and logged, but not actually performed.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Remove-VSSShadowCopy -IsSimulateMode:$false -Logger ${function:Write-LogMessage}
    #>
    param(
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Remove-VSSShadowCopy: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey) -or $Script:VssManager_ScriptRunVSSShadowIDs[$runKey].Count -eq 0) {
        & $LocalWriteLog -Message "`n[INFO] VssManager: No VSS Shadow IDs recorded for current run (PID $runKey) to remove, or already cleared." -Level VSS
        return
    }
    $shadowIdMapForRun = $Script:VssManager_ScriptRunVSSShadowIDs[$runKey]
    & $LocalWriteLog -Message "`n[INFO] VssManager: Removing VSS Shadow Copies for this run (PID $runKey)..." -Level VSS
    $shadowIdsToRemove = $shadowIdMapForRun.Values | Select-Object -Unique

    if ($shadowIdsToRemove.Count -eq 0) {
        & $LocalWriteLog -Message "  - VssManager: No unique VSS shadow IDs in tracking list to remove." -Level VSS
        $shadowIdMapForRun.Clear(); return
    }

    if (-not $PSCmdlet.ShouldProcess("VSS Shadow IDs: $($shadowIdsToRemove -join ', ')", "Delete All (diskshadow.exe)")) {
        & $LocalWriteLog -Message "  - VssManager: VSS shadow deletion skipped by user (ShouldProcess) for IDs: $($shadowIdsToRemove -join ', ')." -Level WARNING
        return
    }

    $diskshadowScriptContentAll = "SET VERBOSE ON`n"
    $shadowIdsToRemove | ForEach-Object { $diskshadowScriptContentAll += "DELETE SHADOWS ID $_`n" }
    $tempScriptPathAll = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_all_vss_$(Get-Random).txt"
    try { $diskshadowScriptContentAll | Set-Content -Path $tempScriptPathAll -Encoding UTF8 -ErrorAction Stop }
    catch { & $LocalWriteLog -Message "[ERROR] VssManager: Failed to write VSS deletion script to '$tempScriptPathAll'. Manual cleanup may be needed. Error: $($_.Exception.Message)" -Level ERROR; return }

    & $LocalWriteLog -Message "  - VssManager: Generated diskshadow VSS deletion script: '$tempScriptPathAll' for IDs: $($shadowIdsToRemove -join ', ')" -Level VSS

    if (-not $IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "  - VssManager: Executing diskshadow.exe to delete VSS shadow copies..." -Level VSS
        $processDeleteAll = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathAll`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
        if ($processDeleteAll.ExitCode -ne 0) {
            & $LocalWriteLog -Message "[ERROR] VssManager: diskshadow.exe failed to delete one or more VSS shadows. Exit Code: $($processDeleteAll.ExitCode). Manual cleanup may be needed for ID(s): $($shadowIdsToRemove -join ', ')" -Level ERROR
        } else {
            & $LocalWriteLog -Message "  - VssManager: VSS shadow deletion process completed successfully." -Level VSS
        }
    } else {
        & $LocalWriteLog -Message "SIMULATE: VssManager would execute diskshadow.exe to delete VSS shadow IDs: $($shadowIdsToRemove -join ', ')." -Level SIMULATE
    }
    Remove-Item -LiteralPath $tempScriptPathAll -Force -ErrorAction SilentlyContinue
    $shadowIdMapForRun.Clear()
}
#endregion

Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy
