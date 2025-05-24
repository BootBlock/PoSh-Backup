# Modules\ConfigManager.psm1
<#
.SYNOPSIS
    Acts as a facade module for PoSh-Backup configuration management. It imports and
    re-exports functions from specialized sub-modules located in 'Modules\ConfigManagement\'.
.DESCRIPTION
    The ConfigManager module serves as the primary interface for configuration-related tasks
    within the PoSh-Backup solution. It achieves this by:
    - Importing `ConfigLoader.psm1`: Handles loading, merging, and basic validation of configuration files.
    - Importing `JobResolver.psm1`: Determines which backup jobs/sets to process.
    - Importing `EffectiveConfigBuilder.psm1`: Calculates the final effective settings for individual jobs.

    This facade approach allows the main PoSh-Backup script and other modules to interact with
    a single `ConfigManager.psm1` for all configuration needs, while the underlying logic
    is neatly organised into more focused sub-modules. This enhances maintainability and clarity.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Refactored to use sub-modules from Modules\ConfigManagement\.
    DateCreated:    17-May-2025
    LastModified:   24-May-2025
    Purpose:        Facade for centralised configuration management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules (ConfigLoader.psm1, JobResolver.psm1, EffectiveConfigBuilder.psm1)
                    must exist in the '.\Modules\ConfigManagement\' directory relative to this file.
#>

# $PSScriptRoot here is Modules\
$configManagementSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "ConfigManagement"

try {
    Import-Module -Name (Join-Path -Path $configManagementSubModulePath -ChildPath "ConfigLoader.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configManagementSubModulePath -ChildPath "JobResolver.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configManagementSubModulePath -ChildPath "EffectiveConfigBuilder.psm1") -Force -ErrorAction Stop
}
catch {
    # If any sub-module fails to import, ConfigManager cannot function.
    Write-Error "ConfigManager.psm1 FATAL: Could not import one or more required sub-modules from '$configManagementSubModulePath'. Error: $($_.Exception.Message)"
    throw # Re-throw to stop further execution of this module loading.
}

# Re-export the primary functions from the sub-modules.
# The Merge-DeepHashtable function from ConfigLoader.psm1 is not re-exported as it's considered internal to that module's operation.
Export-ModuleMember -Function Import-AppConfiguration, Get-JobsToProcess, Get-PoShBackupJobEffectiveConfiguration
