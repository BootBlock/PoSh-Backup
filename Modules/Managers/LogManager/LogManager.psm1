# Modules\Managers\LogManager.psm1
<#
.SYNOPSIS
    Acts as a facade to provide logging and log file retention functions for PoSh-Backup.
.DESCRIPTION
    The LogManager module serves as the primary interface for all logging-related tasks
    within the PoSh-Backup solution. It achieves this by importing and re-exporting functions
    from specialised sub-modules located in '.\LogManager\':
    - 'Logger.psm1': Provides the core 'Write-LogMessage' function for real-time logging.
    - 'RetentionHandler.psm1': Provides the 'Invoke-PoShBackupLogRetention' function for
      managing the lifecycle of log files.

    This facade approach allows other parts of the PoSh-Backup system to interact with
    a single 'LogManager.psm1' for all logging needs, while the underlying logic
    is organised into more focused sub-modules.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade with sub-modules.
    DateCreated:    27-May-2025
    LastModified:   27-Jun-2025
    Purpose:        Facade for centralised logging and log retention management.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules must exist in '.\Modules\Managers\LogManager\'.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
$logManagerSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "LogManager"
try {
    Import-Module -Name (Join-Path -Path $logManagerSubModulePath -ChildPath "Logger.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $logManagerSubModulePath -ChildPath "RetentionHandler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "LogManager.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Functions ---
# Re-export the primary functions from the sub-modules.
Export-ModuleMember -Function Write-LogMessage, Invoke-PoShBackupLogRetention
#endregion
