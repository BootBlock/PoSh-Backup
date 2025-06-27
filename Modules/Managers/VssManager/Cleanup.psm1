# Modules\Managers\VssManager\Cleanup.psm1
<#
.SYNOPSIS
    A sub-module for VssManager.psm1. Handles the cleanup of VSS shadow copies.
.DESCRIPTION
    This module provides the 'Remove-PoShBackupVssShadowCopy' function. It reads the
    shared state hashtable (managed by the parent VssManager facade) to identify all
    VSS shadow copies created during the current script run and removes them using
    diskshadow.exe. This ensures a clean state after the backup operation completes.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To isolate the VSS cleanup logic.
    Prerequisites:  PowerShell 5.1+. Administrator privileges.
#>

#region --- VSS Cleanup Function ---
function Remove-PoShBackupVssShadowCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $true)]
        [ref]$VssIdHashtableRef,
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    & $Logger -Message "VssManager/Cleanup/Remove-PoShBackupVssShadowCopy: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $shadowIdMapForRun = $VssIdHashtableRef.Value
    if ($null -eq $shadowIdMapForRun -or $shadowIdMapForRun.Count -eq 0) {
        & $LocalWriteLog -Message "`n[INFO] VssManager/Cleanup: No VSS Shadow IDs recorded for current run to remove, or already cleared." -Level "VSS"
        return
    }

    & $LocalWriteLog -Message "`n[INFO] VssManager/Cleanup: Removing VSS Shadow Copies for this run..." -Level "VSS"
    $shadowIdsToRemove = $shadowIdMapForRun.Values | Select-Object -Unique

    if ($shadowIdsToRemove.Count -eq 0) {
        & $LocalWriteLog -Message "  - VssManager/Cleanup: No unique VSS shadow IDs in tracking list to remove." -Level "VSS"
        $shadowIdMapForRun.Clear(); return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: The VSS snapshot(s) created for this job (IDs: $($shadowIdsToRemove -join ', ')) would be deleted to clean up the system." -Level "SIMULATE"
        return
    }

    if (-not $Force.IsPresent -and -not $PSCmdletInstance.ShouldProcess("VSS Shadow IDs: $($shadowIdsToRemove -join ', ')", "Delete All (diskshadow.exe)")) {
        & $LocalWriteLog -Message "  - VssManager/Cleanup: VSS shadow deletion skipped by user (ShouldProcess) for IDs: $($shadowIdsToRemove -join ', ')." -Level "WARNING"
        return
    }

    $diskshadowScriptContentAll = "SET VERBOSE ON`n"
    $shadowIdsToRemove | ForEach-Object { $diskshadowScriptContentAll += "DELETE SHADOWS ID $_`n" }
    $tempScriptPathAll = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_all_vss_$(Get-Random).txt"
    try { $diskshadowScriptContentAll | Set-Content -Path $tempScriptPathAll -Encoding UTF8 -ErrorAction Stop }
    catch { & $LocalWriteLog -Message "[ERROR] VssManager/Cleanup: Failed to write VSS deletion script to '$tempScriptPathAll'. Manual cleanup may be needed. Error: $($_.Exception.Message)" -Level "ERROR"; return }

    & $LocalWriteLog -Message "  - VssManager/Cleanup: Executing diskshadow.exe to delete VSS shadow copies..." -Level "VSS"
    $processDeleteAll = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathAll`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
    if ($processDeleteAll.ExitCode -ne 0) {
        & $LocalWriteLog -Message "[ERROR] VssManager/Cleanup: diskshadow.exe failed to delete one or more VSS shadows. Exit Code: $($processDeleteAll.ExitCode). Manual cleanup may be needed for ID(s): $($shadowIdsToRemove -join ', ')" -Level "ERROR"
    }
    else {
        & $LocalWriteLog -Message "  - VssManager/Cleanup: VSS shadow deletion process completed successfully." -Level "VSS"
    }
    Remove-Item -LiteralPath $tempScriptPathAll -Force -ErrorAction SilentlyContinue
    $shadowIdMapForRun.Clear()
}
#endregion

Export-ModuleMember -Function Remove-PoShBackupVssShadowCopy
