# Modules\Utils.psm1
<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    This module now acts as a true facade, lazy-loading its specialised utility
    sub-modules on demand. It is now paired with a module manifest (.psd1).
.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution.
    By acting as a facade, it provides wrapper functions that, when called, will dynamically
    import the required sub-module from '.\Modules\Utilities\' and then execute the real function.
    This improves startup performance by ensuring utility collections are only loaded when needed.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.18.2 # FIX: Corrected Write-LogMessage import to prevent recursion.
    DateCreated:    10-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Facade for core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded by the wrapper functions.

#region --- Facade Functions ---

function Get-ConfigValue {
    [CmdletBinding()]
    param ( [object]$ConfigObject, [string]$Key, [object]$DefaultValue )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop
        return Get-ConfigValue @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
}

function Get-RequiredConfigValue {
    [CmdletBinding()]
    param( [hashtable]$JobConfig, [hashtable]$GlobalConfig, [string]$JobKey, [string]$GlobalKey )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop
        return Get-RequiredConfigValue @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
}

function Expand-EnvironmentVariablesInConfig {
    [CmdletBinding()]
    param( [hashtable]$ConfigObject, [string[]]$KeysToExpand, [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop
        return Expand-EnvironmentVariablesInConfig @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
}

function Write-ConsoleBanner {
    [CmdletBinding()]
    param( [string]$NameText, [string]$NameForegroundColor = '$Global:ColourInfo', [string]$ValueText, [string]$ValueForegroundColor = '$Global:ColourValue', [int]$BannerWidth = 50, [string]$BorderForegroundColor = '$Global:ColourBorder', [switch]$CenterText, [switch]$PrependNewLine, [switch]$AppendNewLine )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
        Write-ConsoleBanner @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
}

function Write-NameValue {
    param( [string]$name, [string]$value, [Int16]$namePadding = 0, [string]$defaultValue = '-', [string]$nameForegroundColor = "DarkGray", [string]$valueForegroundColor = "Gray" )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
        Write-NameValue @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
}

function Start-CancellableCountdown {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param( [int]$DelaySeconds, [string]$ActionDisplayName, [scriptblock]$Logger, [System.Management.Automation.PSCmdlet]$PSCmdletInstance )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
        return Start-CancellableCountdown @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
}

function Get-PoShBackupSecret {
    [CmdletBinding()]
    [OutputType([object])]
    param( [string]$SecretName, [string]$VaultName, [scriptblock]$Logger, [string]$SecretPurposeForLog = "Credential", [switch]$AsPlainText, [switch]$AsCredential )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\CredentialUtils.psm1") -Force -ErrorAction Stop
        return Get-PoShBackupSecret @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the CredentialUtils sub-module. Error: $($_.Exception.Message)" }
}

function Get-ArchiveSizeFormatted {
    [CmdletBinding()]
    param( [string]$PathToArchive, [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop
        return Get-ArchiveSizeFormatted @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
}

function Format-FileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param( [long]$Bytes )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop
        return Format-FileSize @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
}

function Get-PoshBackupFileHash {
    [CmdletBinding()]
    param( [string]$FilePath, [ValidateSet("SHA1", "SHA256", "SHA384", "SHA512", "MD5")] [string]$Algorithm, [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop
        return Get-PoshBackupFileHash @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
}

function Resolve-PoShBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param( [string]$PathToResolve, [string]$ScriptRoot )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\PathResolver.psm1") -Force -ErrorAction Stop
        return Resolve-PoShBackupPath @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the PathResolver sub-module. Error: $($_.Exception.Message)" }
}

function Group-BackupInstancesByTimestamp {
    [CmdletBinding()]
    param( [array]$FileObjectList, [string]$ArchiveBaseName, [string]$ArchiveDateFormat, [string]$PrimaryArchiveExtension, [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
        return Group-BackupInstancesByTimestamp @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the RetentionUtils sub-module. Error: $($_.Exception.Message)" }
}

function Get-ScriptVersionFromContent {
    [CmdletBinding()]
    param( [string]$ScriptContent, [string]$ScriptNameForWarning = "script" )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\StringUtils.psm1") -Force -ErrorAction Stop
        return Get-ScriptVersionFromContent @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the StringUtils sub-module. Error: $($_.Exception.Message)" }
}

function Test-AdminPrivilege {
    [CmdletBinding()]
    param( [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
        return Test-AdminPrivilege @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
}

function Test-DestinationFreeSpace {
    [CmdletBinding()]
    param( [string]$DestDir, [int]$MinRequiredGB, [bool]$ExitOnLow, [switch]$IsSimulateMode, [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
        return Test-DestinationFreeSpace @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
}

function Test-HibernateEnabled {
    [CmdletBinding()]
    param( [scriptblock]$Logger )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
        return Test-HibernateEnabled @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
}

function Write-LogMessage {
    [CmdletBinding()]
    param( [string]$Message, [string]$ForegroundColour, [switch]$NoNewLine, [string]$Level = "INFO", [switch]$NoTimestampToLogFile = $false )
    try {
        # *** FIX: Import the actual logger, not the manager facade ***
        Import-Module -Name (Join-Path $PSScriptRoot "Managers\LogManager\Logger.psm1") -Force -ErrorAction Stop
        Write-LogMessage @PSBoundParameters
    } catch { Write-Error "Utils.psm1 Facade: Could not load the Logger sub-module. Error: $($_.Exception.Message)" }
}

function Invoke-PoShBackupUpdateCheckAndApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param( [scriptblock]$Logger, [string]$PSScriptRootForPaths, [System.Management.Automation.PSCmdlet]$PSCmdletInstance )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "Utilities\Update.psm1") -Force -ErrorAction Stop
        Invoke-PoShBackupUpdateCheckAndApply @PSBoundParameters
    } catch { throw "Utils.psm1 Facade: Could not load the Update sub-module. Error: $($_.Exception.Message)" }
}

#endregion

# Corrected and completed list of all functions to export from the facade.
Export-ModuleMember -Function Get-ConfigValue, Get-RequiredConfigValue, Expand-EnvironmentVariablesInConfig, Write-ConsoleBanner, Write-NameValue, Start-CancellableCountdown, Get-PoShBackupSecret, Get-ArchiveSizeFormatted, Format-FileSize, Get-PoshBackupFileHash, Resolve-PoShBackupPath, Group-BackupInstancesByTimestamp, Get-ScriptVersionFromContent, Test-AdminPrivilege, Test-DestinationFreeSpace, Test-HibernateEnabled, Write-LogMessage, Invoke-PoShBackupUpdateCheckAndApply
