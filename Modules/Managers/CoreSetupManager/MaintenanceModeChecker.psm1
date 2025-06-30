# Modules\Managers\CoreSetupManager\MaintenanceModeChecker.psm1
<#
.SYNOPSIS
    Handles the maintenance mode check for PoSh-Backup.
.DESCRIPTION
    This sub-module of CoreSetupManager is responsible for checking if PoSh-Backup
    should halt execution because maintenance mode is active. It checks both the
    'MaintenanceModeEnabled' setting in the configuration and the existence of the
    on-disk flag file specified by 'MaintenanceModeFilePath'.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added import for Utils.psm1 to resolve missing functions.
    DateCreated:    17-Jun-2025
    LastModified:   17-Jun-2025
    Purpose:        To centralize the maintenance mode check.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\CoreSetupManager
try {
    # Import Utils.psm1 to get access to Get-ConfigValue and Write-ConsoleBanner
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "MaintenanceModeChecker.psm1 FATAL: Could not import required module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Test-PoShBackupMaintenanceMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "CoreSetupManager/MaintenanceModeChecker/Test-PoShBackupMaintenanceMode: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $maintModeEnabledByConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'MaintenanceModeEnabled' -DefaultValue $false
    $maintModeFilePath = Get-ConfigValue -ConfigObject $Configuration -Key 'MaintenanceModeFilePath' -DefaultValue '.\.maintenance'
    
    $scriptRootPath = $Configuration['_PoShBackup_PSScriptRoot']
    $maintModeFileFullPath = Resolve-PoShBackupPath -PathToResolve $maintModeFilePath -ScriptRoot $scriptRootPath
    if ([string]::IsNullOrWhiteSpace($maintModeFileFullPath)) {
        & $Logger -Message "  - [ERROR] MaintenanceModeChecker: Could not resolve the path for the maintenance flag file. Check cannot proceed." -Level "ERROR"
        return $false
    }
    
    & $Logger -Message "CoreSetupManager/MaintenanceModeChecker: Checking for maintenance file at resolved path: '$maintModeFileFullPath'" -Level "DEBUG"
    $maintModeEnabledByFile = Test-Path -LiteralPath $maintModeFileFullPath -PathType Leaf -ErrorAction SilentlyContinue

    if ($maintModeEnabledByConfig -or $maintModeEnabledByFile) {
        $maintModeMessage = Get-ConfigValue -ConfigObject $Configuration -Key 'MaintenanceModeMessage' -DefaultValue "PoSh-Backup is currently in maintenance mode.`n      New backup jobs will not be started."
        $reason = if ($maintModeEnabledByConfig) { "configuration setting 'MaintenanceModeEnabled' is true" } else { "flag file exists at '$maintModeFileFullPath'" }
        
        Write-ConsoleBanner -NameText "Maintenance Mode Active" -ValueText "Execution Halted" -NameForegroundColor "Yellow" -BorderForegroundColor "Yellow"
        & $Logger -Message "`n  $maintModeMessage" -Level "WARNING"
        & $Logger -Message "`nReason: $reason." -Level "INFO"
        & $Logger -Message "To run backups, disable maintenance mode or use the -ForceRunInMaintenanceMode switch." -Level "INFO"
        return $true # Returns true to indicate that maintenance mode is active and script should halt.
    }

    return $false # Maintenance mode is not active.
}

Export-ModuleMember -Function Test-PoShBackupMaintenanceMode
