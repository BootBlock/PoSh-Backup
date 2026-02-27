# Modules\Managers\VssManager\Creator.psm1
<#
.SYNOPSIS
    A sub-module for VssManager.psm1. Handles the creation of VSS shadow copies.
.DESCRIPTION
    This module provides the 'New-PoShBackupVssShadowCopy' function, which orchestrates
    the creation of Volume Shadow Copies. It generates a diskshadow script, executes it,
    polls for the shadow copy details, and maps the original paths to their shadow copy
    equivalents. It updates a shared state hashtable with the IDs of any shadows it creates.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Standardised PSCmdletInstance parameter name.
    DateCreated:    26-Jun-2025
    LastModified:   04-Jul-2025
    Purpose:        To isolate the VSS creation logic.
    Prerequisites:  PowerShell 5.1+. Administrator privileges.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\VssManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VssManager\Creator.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- VSS Creation Function ---
function New-PoShBackupVssShadowCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath,
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $true)] [ref]$VssIdHashtableRef # Receives the reference to the state hashtable
    )
    & $Logger -Message "VssManager/Creator/New-PoShBackupVssShadowCopy: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not (Test-AdminPrivilege -Logger $Logger)) {
        $errorMessage = "VSS operations require Administrator privileges, but the script is running in a non-elevated session."
        & $LocalWriteLog -Message $errorMessage -Level "ERROR"
        & $LocalWriteLog -Message "To use VSS, please re-launch PowerShell using the 'Run as Administrator' option." -Level "ADVICE"
        throw $errorMessage
    }

    $currentCallShadowIDs = $VssIdHashtableRef.Value
    & $LocalWriteLog -Message "`n[INFO] VssManager/Creator: Initialising Volume Shadow Copy Service (VSS) operations..." -Level "VSS"
    $mappedShadowPaths = @{}

    $volumesToShadow = $SourcePathsToShadow | ForEach-Object {
        try { (Get-Item -LiteralPath $_ -ErrorAction Stop).PSDrive.Name + ":" } catch { & $LocalWriteLog -Message "[WARNING] VssManager/Creator: Could not determine volume for source path '$_'. It will be skipped for VSS snapshotting." -Level WARNING; $null }
    } | Where-Object {$null -ne $_} | Select-Object -Unique

    if ($volumesToShadow.Count -eq 0) {
        & $LocalWriteLog -Message "[WARNING] VssManager/Creator: No valid volumes determined from source paths to create shadow copies for." -Level WARNING
        return $null
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: A VSS snapshot would be created for volume(s) $($volumesToShadow -join ', ') to allow for backing up open files." -Level SIMULATE
        $SourcePathsToShadow | ForEach-Object {
            $currentSourcePath = $_
            try {
                $vol = (Get-Item -LiteralPath $currentSourcePath -ErrorAction Stop).PSDrive.Name + ":"
                $relativePathSimulated = $currentSourcePath -replace [regex]::Escape($vol), ""
                $simulatedIndex = Get-Random -Minimum 1000 -Maximum 9999
                $mappedShadowPaths[$currentSourcePath] = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopySIMULATED$($simulatedIndex)$relativePathSimulated"
            } catch { $mappedShadowPaths[$currentSourcePath] = "$currentSourcePath (Original Path - VSS Simulation)" }
        }
        return $mappedShadowPaths
    }

    $diskshadowScriptContent = "SET CONTEXT $VSSContextOption`nSET METADATA CACHE `"$MetadataCachePath`"`nSET VERBOSE ON`n$($volumesToShadow | ForEach-Object { "ADD VOLUME $_ ALIAS Vol_$($_ -replace ':','')" })`nCREATE`n"
    $tempDiskshadowScriptFile = (New-TemporaryFile).FullName
    try { $diskshadowScriptContent | Set-Content -Path $tempDiskshadowScriptFile -Encoding UTF8 -ErrorAction Stop }
    catch { & $LocalWriteLog -Message "[ERROR] VssManager/Creator: Failed to write diskshadow script to '$tempDiskshadowScriptFile'. VSS creation aborted. Error: $($_.Exception.Message)" -Level ERROR; return $null }

    if (-not $PSCmdletInstance.ShouldProcess("Volumes: $($volumesToShadow -join ', ')", "Create VSS Shadow Copies (diskshadow.exe)")) {
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    $tempStdOut = (New-TemporaryFile).FullName
    $tempStdErr = (New-TemporaryFile).FullName
    try {
        $process = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempDiskshadowScriptFile`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $tempStdOut -RedirectStandardError $tempStdErr
    }
    finally {
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStdOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStdErr -Force -ErrorAction SilentlyContinue
    }

    if ($process.ExitCode -ne 0) { & $LocalWriteLog -Message "[ERROR] VssManager/Creator: diskshadow.exe failed to create shadow copies. Exit Code: $($process.ExitCode)." -Level ERROR; return $null }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allVolumesSuccessfullyShadowed = $false
    $foundShadowsForThisSpecificCall = @{}

    while ($stopwatch.Elapsed.TotalSeconds -lt $PollingTimeoutSeconds) {
        $cimShadowsThisPoll = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.InstallDate -gt (Get-Date).AddMinutes(-5) }
        if ($null -ne $cimShadowsThisPoll) {
            foreach ($volName in $volumesToShadow) {
                if (-not $foundShadowsForThisSpecificCall.ContainsKey($volName)) {
                    $candidateShadow = $cimShadowsThisPoll | Where-Object { $_.VolumeName -eq $volName -and (-not $currentCallShadowIDs.ContainsValue($_.ID)) } | Sort-Object InstallDate -Descending | Select-Object -First 1
                    if ($null -ne $candidateShadow) {
                        $currentCallShadowIDs[$volName] = $candidateShadow.ID
                        $foundShadowsForThisSpecificCall[$volName] = $candidateShadow.DeviceObject
                    }
                }
            }
        }
        if ($foundShadowsForThisSpecificCall.Keys.Count -eq $volumesToShadow.Count) { $allVolumesSuccessfullyShadowed = $true; break }
        Start-Sleep -Seconds $PollingIntervalSeconds
    }
    $stopwatch.Stop()

    if (-not $allVolumesSuccessfullyShadowed) {
        & $LocalWriteLog -Message "[ERROR] VssManager/Creator: Timed out or failed to find all required shadow copies via CIM." -Level ERROR
        # Cleanup any shadows that *were* created in this failed attempt
        $foundShadowsForThisSpecificCall.Keys | ForEach-Object { $volToClean = $_; if ($currentCallShadowIDs.ContainsKey($volToClean)) { & diskshadow.exe /s "DELETE SHADOWS ID $($currentCallShadowIDs[$volToClean])" } }
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
            }
        } catch { & $LocalWriteLog -Message "[WARNING] VssManager/Creator: Error during VSS mapping for '$originalFullPath': $($_.Exception.Message)." -Level WARNING }
    }

    return $mappedShadowPaths
}
#endregion

Export-ModuleMember -Function New-PoShBackupVssShadowCopy
