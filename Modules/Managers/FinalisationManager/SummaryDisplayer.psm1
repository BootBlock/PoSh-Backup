# Modules\Managers\FinalisationManager\SummaryDisplayer.psm1
<#
.SYNOPSIS
    A sub-module for FinalisationManager. Handles the display of the final summary.
.DESCRIPTION
    This module provides the 'Show-PoShBackupFinalSummary' function. It is responsible for
    displaying the final completion banner and the script's overall statistics (status,
    start time, end time, total duration) to the console.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the final console summary display logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\FinalisationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SummaryDisplayer.psm1 FATAL: Could not import ConsoleDisplayUtils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Show-PoShBackupFinalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectiveOverallStatus,
        [Parameter(Mandatory = $true)]
        [datetime]$ScriptStartTime,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode
    )

    # --- Completion Banner ---
    $completionBorderColor = '$Global:ColourHeading'
    $completionNameFgColor = '$Global:ColourSuccess'
    
    if ($EffectiveOverallStatus -eq "FAILURE") { $completionBorderColor = '$Global:ColourError'; $completionNameFgColor = '$Global:ColourError' }
    elseif ($EffectiveOverallStatus -eq "WARNINGS") { $completionBorderColor = '$Global:ColourWarning'; $completionNameFgColor = '$Global:ColourWarning' }
    elseif ($IsSimulateMode.IsPresent -and $EffectiveOverallStatus -ne "FAILURE" -and $EffectiveOverallStatus -ne "WARNINGS") {
        $completionBorderColor = '$Global:ColourSimulate'; $completionNameFgColor = '$Global:ColourSimulate'
    }
    
    Write-ConsoleBanner -NameText "All PoSh Backup Operations Completed" `
        -NameForegroundColor $completionNameFgColor `
        -BannerWidth 78 `
        -BorderForegroundColor $completionBorderColor `
        -CenterText `
        -PrependNewLine

    # --- Final Summary Output ---
    $overallScriptStatusForegroundColor = $Global:ColourSuccess
    if ($EffectiveOverallStatus -eq "FAILURE") { $overallScriptStatusForegroundColor = $Global:ColourError }
    elseif ($EffectiveOverallStatus -eq "WARNINGS") { $overallScriptStatusForegroundColor = $Global:ColourWarning }
    elseif ($IsSimulateMode.IsPresent -and $EffectiveOverallStatus -ne "FAILURE" -and $EffectiveOverallStatus -ne "WARNINGS") {
        $overallScriptStatusForegroundColor = $Global:ColourSimulate
    }

    $finalScriptEndTime = Get-Date
    $namePadding = 22
    
    Write-NameValue -name "Overall Script Status" -value $EffectiveOverallStatus -namePadding $namePadding -valueForegroundColor $overallScriptStatusForegroundColor
    Write-NameValue -name "Script started" -value $ScriptStartTime -namePadding $namePadding
    Write-NameValue -name "Script ended" -value $finalScriptEndTime -namePadding $namePadding
    Write-NameValue -name "Total duration" -value ($finalScriptEndTime - $ScriptStartTime) -namePadding $namePadding
    Write-Host
}

Export-ModuleMember -Function Show-PoShBackupFinalSummary
