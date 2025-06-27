# Modules\Managers\VssManager.psm1
<#
.SYNOPSIS
    Manages Volume Shadow Copy Service (VSS) operations by acting as a facade for
    specialised sub-modules.
.DESCRIPTION
    The VssManager module centralises all interactions with the Windows VSS subsystem by
    orchestrating calls to its sub-modules, 'Creator.psm1' and 'Cleanup.psm1'.

    This facade is responsible for:
    - Maintaining the state of created VSS shadow copies for the current script run.
    - Importing the sub-modules.
    - Exporting the primary functions `New-VSSShadowCopy` and `Remove-VSSShadowCopy`,
      which now wrap the calls to the sub-modules and pass the shared state to them.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.2 # Added PSSA suppression for ShouldProcess on facade functions.
    DateCreated:    17-May-2025
    LastModified:   27-Jun-2025
    Purpose:        Facade for centralised VSS management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Administrator privileges.
#>

#region --- Module-Scoped State Management ---
# This hashtable tracks VSS shadow IDs created during the current script run, keyed by PID.
$Script:VssManager_ScriptRunVSSShadowIDs = @{}
#endregion

#region --- Sub-Module Imports ---
# $PSScriptRoot here is Modules\Managers
$vssSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "VssManager"
try {
    Import-Module -Name (Join-Path -Path $vssSubModulePath -ChildPath "Creator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $vssSubModulePath -ChildPath "Cleanup.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VssManager.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Facade Functions ---

<# PSScriptAnalyzer Suppress PSShouldProcess - Justification: This is a facade function that delegates the ShouldProcess call to the 'New-PoShBackupVssShadowCopy' function in the sub-module. #>
function New-VSSShadowCopy {
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath,
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    
    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        $Script:VssManager_ScriptRunVSSShadowIDs[$runKey] = @{}
    }
    
    return New-PoShBackupVssShadowCopy @PSBoundParameters -VssIdHashtableRef ([ref]$Script:VssManager_ScriptRunVSSShadowIDs[$runKey])
}

<# PSScriptAnalyzer Suppress PSShouldProcess - Justification: This is a facade function that delegates the ShouldProcess call to the 'Remove-PoShBackupVssShadowCopy' function in the sub-module. #>
function Remove-VSSShadowCopy {
    param(
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)] [switch]$Force
    )
    
    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        & $Logger -Message "VssManager (Facade): No VSS session state found for PID $runKey. Nothing to clean up." -Level "DEBUG"
        return
    }

    Remove-PoShBackupVssShadowCopy @PSBoundParameters -VssIdHashtableRef ([ref]$Script:VssManager_ScriptRunVSSShadowIDs[$runKey])
}

#endregion

Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy
