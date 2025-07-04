# Modules\Managers\VssManager.psm1
<#
.SYNOPSIS
    Manages Volume Shadow Copy Service (VSS) operations by acting as a facade for
    specialised sub-modules that are loaded on demand.
.DESCRIPTION
    The VssManager module centralises all interactions with the Windows VSS subsystem by
    orchestrating calls to its sub-modules, 'Creator.psm1' and 'Cleanup.psm1'.

    This facade is responsible for:
    - Maintaining the state of created VSS shadow copies for the current script run.
    - Lazy-loading the 'Creator' and 'Cleanup' sub-modules as needed.
    - Exporting the primary functions `New-VSSShadowCopy` and `Remove-VSSShadowCopy`,
      which now wrap the calls to the sub-modules and pass the shared state to them.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.2 # FIX: Added ShouldProcess support to facade functions.
    DateCreated:    17-May-2025
    LastModified:   04-Jul-2025
    Purpose:        Facade for centralised VSS management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Administrator privileges.
#>

#region --- Module-Scoped State Management ---
# This hashtable tracks VSS shadow IDs created during the current script run, keyed by PID.
$Script:VssManager_ScriptRunVSSShadowIDs = @{}
#endregion

#region --- Exported Facade Functions ---

function New-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath,
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    if (-not $PSCmdletInstance.ShouldProcess("VSS Shadow Copy Creation (delegated)", "Create")) { return }

    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        $Script:VssManager_ScriptRunVSSShadowIDs[$runKey] = @{}
    }

    try {
        Import-Module -Name (Join-Path $PSScriptRoot "VssManager\Creator.psm1") -Force -ErrorAction Stop
        return New-PoShBackupVssShadowCopy @PSBoundParameters -VssIdHashtableRef ([ref]$Script:VssManager_ScriptRunVSSShadowIDs[$runKey])
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\VssManager\Creator.psm1' exists and is not corrupted."
        & $Logger -Message "[FATAL] VssManager (Facade): Could not load the Creator sub-module. VSS operations will fail. Error: $($_.Exception.Message)" -Level "ERROR"
        & $Logger -Message $advice -Level "ADVICE"
        throw
    }
}

function Remove-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)] [switch]$Force
    )

    if (-not $PSCmdletInstance.ShouldProcess("VSS Shadow Copy Cleanup (delegated)", "Remove")) { return }

    $runKey = $PID
    if (-not $Script:VssManager_ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        & $Logger -Message "VssManager (Facade): No VSS session state found for PID $runKey. Nothing to clean up." -Level "DEBUG"
        return
    }

    try {
        Import-Module -Name (Join-Path $PSScriptRoot "VssManager\Cleanup.psm1") -Force -ErrorAction Stop
        Remove-PoShBackupVssShadowCopy @PSBoundParameters -VssIdHashtableRef ([ref]$Script:VssManager_ScriptRunVSSShadowIDs[$runKey])
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\VssManager\Cleanup.psm1' exists and is not corrupted."
        & $Logger -Message "[ERROR] VssManager (Facade): Could not load the Cleanup sub-module. VSS cleanup may not have run. Error: $($_.Exception.Message)" -Level "ERROR"
        & $Logger -Message $advice -Level "ADVICE"
        # Do not throw from cleanup
    }
}

#endregion

Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy
