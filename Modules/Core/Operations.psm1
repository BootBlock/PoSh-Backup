# Modules\Core\Operations.psm1
<#
.SYNOPSIS
    Manages the core backup operations for a single PoSh-Backup job within the PoSh-Backup solution.
    This module now acts as a facade, orchestrating calls to sub-modules for pre-processing,
    local archive processing, and remote target transfers.
    The main job execution logic resides in '.\Operations\JobExecutor.psm1'.

.DESCRIPTION
    The Operations module facade centralises the invocation of the job processing lifecycle.
    It imports and re-exports the primary 'Invoke-PoShBackupJob' function from its
    sub-module 'Modules\Core\Operations\JobExecutor.psm1'.

    This facade approach simplifies how other parts of the PoSh-Backup system (like JobOrchestrator)
    interact with the job execution logic, while the detailed implementation is managed by
    the JobExecutor sub-module and its own dependencies (JobPreProcessor, LocalArchiveProcessor,
    RemoteTransferOrchestrator).

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.22.0 # Refactored to facade for JobExecutor.psm1.
    DateCreated:    10-May-2025
    LastModified:   30-May-2025
    Purpose:        Facade for individual backup job execution logic.
    Prerequisites:  PowerShell 5.1+.
                    Sub-module 'JobExecutor.psm1' must exist in '.\Modules\Core\Operations\'.
#>

# Explicitly import Utils.psm1 as it might be used by the facade itself or for context.
# $PSScriptRoot here refers to the directory of Operations.psm1 (Modules\Core).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Operations.psm1 (Facade in Core) FATAL: Could not import main Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Sub-Module Import ---
# $PSScriptRoot here is Modules\Core
$subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "Operations" # Path to Modules\Core\Operations

try {
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "JobExecutor.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Operations.psm1 (Facade in Core) FATAL: Could not import required sub-module 'JobExecutor.psm1' from '$subModulesPath'. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Functions ---
# Re-export the primary function from the JobExecutor sub-module.
Export-ModuleMember -Function Invoke-PoShBackupJob
#endregion
