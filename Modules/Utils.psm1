# Modules\Utils.psm1
<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    This module now acts as a facade, importing and re-exporting functions from
    more specialised utility modules located in '.\Modules\Utilities\' (including the new
    Update.psm1 for update checking) and the core logging function from
    '.\Modules\Managers\LogManager.psm1'.
.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution,
    promoting code reusability, consistency, and maintainability. By acting as a facade,
    it allows other parts of the PoSh-Backup system to continue importing a single 'Utils.psm1'
    while the underlying utility functions are organised into more focused sub-modules:
    - ConfigUtils.psm1: Handles safe retrieval of configuration values.
    - SystemUtils.psm1: Handles system-level interactions (admin checks, free space).
    - FileUtils.psm1: Handles file-specific operations (size formatting, hashing).
    - StringUtils.psm1: Handles string manipulation and extraction (e.g., version parsing).
    - ConsoleDisplayUtils.psm1: Handles enhanced console output like banners.
    - Update.psm1 (New): Handles checking for and applying updates to PoSh-Backup.
    And the core logging function:
    - LogManager.psm1 (in Modules\Managers\): Handles message logging.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.16.0 # Added Update.psm1 for update checking.
    DateCreated:    10-May-2025
    LastModified:   31-May-2025
    Purpose:        Facade for core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules (ConfigUtils.psm1, SystemUtils.psm1, FileUtils.psm1, StringUtils.psm1,
                    ConsoleDisplayUtils.psm1, Update.psm1) must exist in '.\Modules\Utilities\'.
                    LogManager.psm1 must exist in '.\Modules\Managers\'.
#>

#region --- Sub-Module Imports ---
# $PSScriptRoot here is Modules\
$utilitiesSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Utilities"
$managersSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Managers" # Path to Managers directory

try {
    # Import from Utilities
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "ConfigUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "SystemUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "FileUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "StringUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "CredentialUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $utilitiesSubModulePath -ChildPath "RetentionUtils.psm1") -Force -ErrorAction Stop

    # Update.psm1 is lazy-loaded by ScriptModeHandler.psm1, so it's not imported here directly.
    # However, to make its function available via the Utils facade if ScriptModeHandler *does* load it,
    # we can attempt to get its exported members if the module is already loaded in the session.
    # This is a bit of a workaround for facade pattern with lazy loading.
    # A cleaner way might be for ScriptModeHandler to call Update.psm1 functions directly after its own import.
    # For now, we'll assume ScriptModeHandler handles the direct call after lazy loading Update.psm1.
    # If Invoke-PoShBackupUpdateCheckAndApply needs to be callable from other places *through* Utils.psm1
    # *without* ScriptModeHandler having loaded it first, then Update.psm1 would need to be eagerly loaded here.
    # Given the current design (lazy load in ScriptModeHandler), we will NOT import Update.psm1 here.
    # ScriptModeHandler will be responsible for calling it.
    # We will, however, add its function to the Export-ModuleMember list,
    # so if it *is* loaded into the session by ScriptModeHandler, it *could* be discoverable via Utils.
    # This is a compromise. The primary invocation path is ScriptModeHandler -> Update.psm1 directly.

    # Import Write-LogMessage from LogManager.psm1 in Managers directory
    Import-Module -Name (Join-Path -Path $managersSubModulePath -ChildPath "LogManager.psm1") -Force -Function Write-LogMessage -ErrorAction Stop

}
catch {
    # If any essential sub-module fails to import, Utils.psm1 cannot function correctly.
    Write-Error "Utils.psm1 (Facade) FATAL: Could not import required sub-modules. Error: $($_.Exception.Message)"
    throw # Re-throw to stop further execution of this module loading.
}
#endregion

#region --- Exported Functions ---
# Re-export all functions from the imported utility sub-modules and Write-LogMessage from LogManager.
# Adding Invoke-PoShBackupUpdateCheckAndApply here. If Update.psm1 is loaded by ScriptModeHandler,
# this makes the function discoverable via `Get-Command Utils\Invoke-PoShBackupUpdateCheckAndApply`.
# However, direct calls should still be ScriptModeHandler -> Update.psm1.
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Get-PoShBackupSecret, Test-AdminPrivilege, Test-DestinationFreeSpace, Get-ArchiveSizeFormatted, Get-PoshBackupFileHash, Group-BackupInstancesByTimestamp, Write-ConsoleBanner, Get-ScriptVersionFromContent, Invoke-PoShBackupUpdateCheckAndApply, Expand-EnvironmentVariablesInConfig, Format-FileSize, Get-RequiredConfigValue
#endregion
