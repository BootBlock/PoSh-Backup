# Modules\Managers\7ZipManager.psm1
<#
.SYNOPSIS
    Manages all 7-Zip executable interactions for the PoSh-Backup solution.
    This module now acts as a facade, importing and re-exporting functions from
    specialised sub-modules located in '.\Modules\Managers\7ZipManager\'.
.DESCRIPTION
    The 7ZipManager module centralises 7-Zip specific logic by orchestrating calls to its sub-modules:
    - 'Discovery.psm1': Handles auto-detection of the 7z.exe path.
    - 'ArgumentBuilder.psm1': Constructs the complex argument list for 7-Zip commands.
    - 'Executor.psm1': Executes 7-Zip for archiving and testing, supporting
      retries, process priority, and CPU affinity.

    This facade approach allows other parts of PoSh-Backup to interact with a single
    '7ZipManager.psm1' for all 7-Zip related needs, while the underlying logic is
    organised into more focused sub-modules within the '7ZipManager' subdirectory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Updated for new sub-module directory and names.
    DateCreated:    17-May-2025
    LastModified:   29-May-2025
    Purpose:        Facade for centralised 7-Zip interaction logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    7-Zip (7z.exe) must be installed.
                    Sub-modules (Discovery.psm1, ArgumentBuilder.psm1, Executor.psm1)
                    must exist in '.\Modules\Managers\7ZipManager\'.
#>

# Explicitly import Utils.psm1 as it might be used by the facade itself or for context.
# $PSScriptRoot here is Modules\Managers.
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "7ZipManager.psm1 (Facade) FATAL: Could not import main Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Sub-Module Imports ---
# $PSScriptRoot here is Modules\Managers
$subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "7ZipManager" # Updated directory name

try {
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "Discovery.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "ArgumentBuilder.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "Executor.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "7ZipManager.psm1 (Facade) FATAL: Could not import one or more required sub-modules from '$subModulesPath'. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Functions ---
# Re-export all public functions from the imported sub-modules.
Export-ModuleMember -Function Find-SevenZipExecutable, Get-PoShBackup7ZipArgument, Invoke-7ZipOperation, Test-7ZipArchive
#endregion
