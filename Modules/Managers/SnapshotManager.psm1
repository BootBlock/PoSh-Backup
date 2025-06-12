# Modules\Managers\SnapshotManager.psm1
<#
.SYNOPSIS
    Manages infrastructure-level snapshot operations (e.g., Hyper-V, VMware) for PoSh-Backup.
    This module acts as a facade, dispatching calls to specific snapshot provider modules.
.DESCRIPTION
    The SnapshotManager module orchestrates the creation, mounting, and cleanup of
    infrastructure-level snapshots for application-consistent backups. It is designed to be
    the single point of contact for the main backup job processor when snapshot operations
    are required.

    Based on the job's configuration, this manager will:
    1.  Dynamically load the appropriate snapshot provider module (e.g., from 'Modules\SnapshotProviders\HyperV.Snapshot.psm1').
    2.  Invoke the provider's function to create a snapshot of a specified resource (like a VM).
    3.  Invoke the provider's function to get the path(s) to the data within the created snapshot.
    4.  Invoke the provider's function to clean up (unmount and remove) the snapshot after the backup is complete.

    This facade approach allows PoSh-Backup to support various snapshot technologies in a pluggable manner.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.5 # Switched to Global scope for session tracking to fix cleanup.
    DateCreated:    10-Jun-2025
    LastModified:   12-Jun-2025
    Purpose:        Facade for infrastructure snapshot management.
    Prerequisites:  PowerShell 5.1+.
                    Specific snapshot provider modules must exist in '.\Modules\SnapshotProviders\'.
                    Dependencies of those providers (e.g., Hyper-V PowerShell module) must be installed.
#>

#region --- Module-Scoped Variables ---
# This will track active snapshot sessions for the current run, keyed by a unique identifier.
# The value will contain the session object returned by the provider AND the loaded provider module itself.
# Using Global scope is essential here because different modules (JobPreProcessor and SnapshotCleanupHandler)
# will import this manager, creating different script scopes. A global variable ensures they all
# access the SAME session hashtable for the entire PoSh-Backup run.
if (-not $Global:PoShBackup_SnapshotManager_ActiveSessions) {
    $Global:PoShBackup_SnapshotManager_ActiveSessions = @{}
}
#endregion

#region --- Exported Functions ---

function New-PoShBackupSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$SnapshotProviderConfig,
        [Parameter(Mandatory = $true)]
        [string]$ResourceToSnapshot,
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
    & $LocalWriteLog -Message "SnapshotManager: Initializing new snapshot process for job '$JobName'." -Level "DEBUG"

    $providerType = $SnapshotProviderConfig.Type
    if ([string]::IsNullOrWhiteSpace($providerType)) {
        & $LocalWriteLog -Message "SnapshotManager: Snapshot provider configuration for job '$JobName' is missing a 'Type'. Cannot proceed." -Level "ERROR"
        return $null
    }

    if (-not $PSCmdlet.ShouldProcess($ResourceToSnapshot, "Create Snapshot (via provider '$providerType')")) {
        & $LocalWriteLog -Message "SnapshotManager: Snapshot creation for resource '$ResourceToSnapshot' skipped by user." -Level "WARNING"
        return $null
    }

    $providerModuleName = "$($providerType).Snapshot.psm1"
    $providerModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\SnapshotProviders\$providerModuleName"
    $invokeFunctionName = "New-PoShBackupSnapshotInternal"

    if (-not (Test-Path -LiteralPath $providerModulePath -PathType Leaf)) {
        & $LocalWriteLog -Message "SnapshotManager: Snapshot provider module '$providerModuleName' for type '$providerType' not found at '$providerModulePath'. Cannot create snapshot." -Level "ERROR"
        return $null
    }

    try {
        $providerModule = Import-Module -Name $providerModulePath -Force -PassThru -ErrorAction Stop
        $providerFunctionCmd = Get-Command $invokeFunctionName -Module $providerModule -ErrorAction SilentlyContinue

        if ($providerFunctionCmd) {
            & $LocalWriteLog -Message "SnapshotManager: Invoking snapshot creation for resource '$ResourceToSnapshot' via provider '$providerType'." -Level "INFO"

            $providerParams = @{
                JobName                  = $JobName
                ResourceToSnapshot       = $ResourceToSnapshot
                ProviderSettings         = $SnapshotProviderConfig.ProviderSpecificSettings
                CredentialsSecretName    = $SnapshotProviderConfig.CredentialsSecretName
                IsSimulateMode           = $IsSimulateMode.IsPresent
                Logger                   = $Logger
                PSCmdlet                 = $PSCmdlet
            }

            $snapshotSession = & $providerFunctionCmd @providerParams

            if ($null -ne $snapshotSession -and $snapshotSession.Success) {
                $sessionId = $snapshotSession.SessionId
                $Global:PoShBackup_SnapshotManager_ActiveSessions[$sessionId] = @{
                    SessionInfo        = $snapshotSession
                    ProviderModuleName = $providerModule.Name
                    ProviderModulePath = $providerModule.Path
                }
                & $LocalWriteLog -Message "SnapshotManager: Successfully created snapshot session '$sessionId' for job '$JobName'." -Level "SUCCESS"
                return $snapshotSession
            }
            else {
                $errorMessage = if ($null -ne $snapshotSession) { $snapshotSession.ErrorMessage } else { "Provider returned null." }
                & $LocalWriteLog -Message "SnapshotManager: Snapshot creation failed for job '$JobName'. Reason: $errorMessage" -Level "ERROR"
                return $null
            }
        }
        else {
            & $LocalWriteLog -Message "SnapshotManager: Provider '$providerType' is missing the required function '$invokeFunctionName'." -Level "ERROR"
            return $null
        }
    }
    catch {
        & $LocalWriteLog -Message "SnapshotManager: A critical error occurred while loading or invoking the '$providerType' snapshot provider. Error: $($_.Exception.ToString())" -Level "ERROR"
        return $null
    }
}

function Get-PoShBackupSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SnapshotSession,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    $sessionId = $SnapshotSession.SessionId
    if (-not $Global:PoShBackup_SnapshotManager_ActiveSessions.ContainsKey($sessionId)) {
        Write-Error "SnapshotManager: Cannot get snapshot paths. No active session found for ID '$sessionId'."
        return $null
    }

    $sessionData = $Global:PoShBackup_SnapshotManager_ActiveSessions[$sessionId]
    $providerModule = $sessionData.ProviderModule
    $invokeFunctionName = "Get-PoShBackupSnapshotPathsInternal"
    $providerFunctionCmd = Get-Command $invokeFunctionName -Module $providerModule -ErrorAction SilentlyContinue

    if ($providerFunctionCmd) {
        return & $providerFunctionCmd -SnapshotSession $SnapshotSession -Logger $Logger
    }
    else {
        Write-Error "SnapshotManager: Active provider module for session '$sessionId' is missing the required function '$invokeFunctionName'."
        return $null
    }
}

function Remove-PoShBackupSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SnapshotSession,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    $sessionId = $SnapshotSession.SessionId
    if (-not $Global:PoShBackup_SnapshotManager_ActiveSessions.ContainsKey($sessionId)) {
        Write-Warning "SnapshotManager: Cannot remove snapshot. No active session found for ID '$sessionId'. It may have already been cleaned up."
        return
    }

    $sessionData = $Global:PoShBackup_SnapshotManager_ActiveSessions[$sessionId]
    $providerModulePath = $sessionData.ProviderModulePath
    if ([string]::IsNullOrWhiteSpace($providerModulePath) -or -not (Test-Path -LiteralPath $providerModulePath)) {
        Write-Error "SnapshotManager: Could not find provider module path '$providerModulePath' stored in session '$sessionId'. Cannot perform cleanup."
        return
    }
    $providerModule = Import-Module -Name $providerModulePath -Force -PassThru
    $providerType = $providerModule.Name
    
    if (-not $PSCmdlet.ShouldProcess($sessionId, "Remove Snapshot (via provider '$providerType')")) {
        Write-Warning "SnapshotManager: Snapshot removal for session '$sessionId' skipped by user."
        return
    }

    $invokeFunctionName = "Remove-PoShBackupSnapshotInternal"
    $providerFunctionCmd = Get-Command $invokeFunctionName -Module $providerModule -ErrorAction SilentlyContinue

    if ($providerFunctionCmd) {
        & $providerFunctionCmd -SnapshotSession $SnapshotSession -PSCmdlet $PSCmdlet
    }
    else {
        Write-Error "SnapshotManager: Active provider module for session '$sessionId' is missing the required function '$invokeFunctionName'."
    }

    $Global:PoShBackup_SnapshotManager_ActiveSessions.Remove($sessionId)
}

#endregion

Export-ModuleMember -Function New-PoShBackupSnapshot, Get-PoShBackupSnapshotPath, Remove-PoShBackupSnapshot
