# Modules\Utils.psm1
<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    This module now acts as a facade, importing and re-exporting functions from
    more specialised utility modules located in '.\Modules\Utilities\'.
    It re-exports logging, configuration, system, and file utilities.

.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution,
    promoting code reusability, consistency, and maintainability. By acting as a facade,
    it allows other parts of the PoSh-Backup system to continue importing a single 'Utils.psm1'
    while the underlying utility functions are organised into more focused sub-modules:
    - Logging.psm1: Handles message logging.
    - ConfigUtils.psm1: Handles safe retrieval of configuration values.
    - SystemUtils.psm1: Handles system-level interactions (admin checks, free space).
    - FileUtils.psm1: Handles file-specific operations (size formatting, hashing).

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.13.3
    DateCreated:    10-May-2025
    LastModified:   27-May-2025
    Purpose:        Facade for core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules (Logging.psm1, ConfigUtils.psm1, SystemUtils.psm1, FileUtils.psm1)
                    must exist in '.\Modules\Utilities\'.
#>

#region --- Sub-Module Imports ---
# $PSScriptRoot here is Modules\
$utilitiesSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Utilities"

try {
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "Logging.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "ConfigUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "SystemUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "FileUtils.psm1") -Force -ErrorAction Stop
}
catch {
    # If any essential sub-module fails to import, Utils.psm1 cannot function correctly.
    Write-Error "Utils.psm1 (Facade) FATAL: Could not import required sub-modules from '$utilitiesSubModulePath'. Error: $($_.Exception.Message)"
    throw # Re-throw to stop further execution of this module loading.
}
#endregion

#region --- Get Archive Size Formatted (REMOVED - Now in Modules\Utilities\FileUtils.psm1) ---
# The Get-ArchiveSizeFormatted function definition has been moved.
# It is now imported from FileUtils.psm1 and re-exported.
#endregion

#region --- Get File Hash (REMOVED - Now in Modules\Utilities\FileUtils.psm1) ---
# The Get-PoshBackupFileHash function definition has been moved.
# It is now imported from FileUtils.psm1 and re-exported.
#endregion

#region --- Exported Functions ---
# Re-export all functions from the imported utility sub-modules.
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Test-AdminPrivilege, Test-DestinationFreeSpace, Get-ArchiveSizeFormatted, Get-PoshBackupFileHash
#endregion
