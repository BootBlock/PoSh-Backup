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
    Version:        1.19.0 # Refactored to import Write-LogMessage from Utilities\Logging.psm1.
    DateCreated:    10-May-2025
    LastModified:   04-Jul-2025
    Purpose:        Facade for core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded by the wrapper functions.

# Module-scoped cache to track which sub-modules have been imported in this facade session.
# This is automatically reset whenever Utils.psm1 itself is re-imported, ensuring correctness.
$script:_loaded = @{}

#region --- Facade Functions ---

function Get-ConfigValue {
    [CmdletBinding()]
    param ( [object]$ConfigObject, [string]$Key, [object]$DefaultValue )
    if (-not $script:_loaded['ConfigUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConfigUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-ConfigValue @PSBoundParameters
}

function Get-RequiredConfigValue {
    [CmdletBinding()]
    param( [hashtable]$JobConfig, [hashtable]$GlobalConfig, [string]$JobKey, [string]$GlobalKey )
    if (-not $script:_loaded['ConfigUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConfigUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-RequiredConfigValue @PSBoundParameters
}

function Expand-EnvironmentVariablesInConfig {
    [CmdletBinding()]
    param( [hashtable]$ConfigObject, [string[]]$KeysToExpand, [scriptblock]$Logger )
    if (-not $script:_loaded['ConfigUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConfigUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConfigUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConfigUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Expand-EnvironmentVariablesInConfig @PSBoundParameters
}

function Write-ConsoleBanner {
    [CmdletBinding()]
    param( [string]$NameText, [string]$NameForegroundColor = '$Global:ColourInfo', [string]$ValueText, [string]$ValueForegroundColor = '$Global:ColourValue', [int]$BannerWidth = 50, [string]$BorderForegroundColor = '$Global:ColourBorder', [switch]$CenterText, [switch]$PrependNewLine, [switch]$AppendNewLine )
    if (-not $script:_loaded['ConsoleDisplayUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConsoleDisplayUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
    }
    Write-ConsoleBanner @PSBoundParameters
}

function Write-NameValue {
    param( [string]$name, [string]$value, [Int16]$namePadding = 0, [string]$defaultValue = '-', [string]$nameForegroundColor = "DarkGray", [string]$valueForegroundColor = "Gray" )
    if (-not $script:_loaded['ConsoleDisplayUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConsoleDisplayUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
    }
    Write-NameValue @PSBoundParameters
}

function Start-CancellableCountdown {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param( [int]$DelaySeconds, [string]$ActionDisplayName, [scriptblock]$Logger, [System.Management.Automation.PSCmdlet]$PSCmdletInstance )
    if (-not $PSCmdletInstance.ShouldProcess("Cancellable Countdown (delegated)", "Start")) { return }
    if (-not $script:_loaded['ConsoleDisplayUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['ConsoleDisplayUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the ConsoleDisplayUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Start-CancellableCountdown @PSBoundParameters
}

function Get-PoShBackupSecret {
    [CmdletBinding()]
    [OutputType([object])]
    param( [string]$SecretName, [string]$VaultName, [scriptblock]$Logger, [string]$SecretPurposeForLog = "Credential", [switch]$AsPlainText, [switch]$AsCredential )
    if (-not $script:_loaded['CredentialUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\CredentialUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['CredentialUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the CredentialUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-PoShBackupSecret @PSBoundParameters
}

function Get-ArchiveSizeFormatted {
    [CmdletBinding()]
    param( [string]$PathToArchive, [scriptblock]$Logger )
    if (-not $script:_loaded['FileUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['FileUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-ArchiveSizeFormatted @PSBoundParameters
}

function Format-FileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param( [long]$Bytes )
    if (-not $script:_loaded['FileUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['FileUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Format-FileSize @PSBoundParameters
}

function Get-PoshBackupFileHash {
    [CmdletBinding()]
    param( [string]$FilePath, [ValidateSet("SHA1", "SHA256", "SHA384", "SHA512", "MD5")] [string]$Algorithm, [scriptblock]$Logger )
    if (-not $script:_loaded['FileUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\FileUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['FileUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the FileUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-PoshBackupFileHash @PSBoundParameters
}

function Resolve-PoShBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param( [string]$PathToResolve, [string]$ScriptRoot )
    if (-not $script:_loaded['PathResolver']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\PathResolver.psm1") -Force -ErrorAction Stop; $script:_loaded['PathResolver'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the PathResolver sub-module. Error: $($_.Exception.Message)" }
    }
    return Resolve-PoShBackupPath @PSBoundParameters
}

function Group-BackupInstancesByTimestamp {
    [CmdletBinding()]
    param( [array]$FileObjectList, [string]$ArchiveBaseName, [string]$ArchiveDateFormat, [string]$PrimaryArchiveExtension, [scriptblock]$Logger )
    if (-not $script:_loaded['RetentionUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['RetentionUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the RetentionUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Group-BackupInstancesByTimestamp @PSBoundParameters
}

function Get-ScriptVersionFromContent {
    [CmdletBinding()]
    param( [string]$ScriptContent, [string]$ScriptNameForWarning = "script" )
    if (-not $script:_loaded['StringUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\StringUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['StringUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the StringUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Get-ScriptVersionFromContent @PSBoundParameters
}

function Test-AdminPrivilege {
    [CmdletBinding()]
    param( [scriptblock]$Logger )
    if (-not $script:_loaded['SystemUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['SystemUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Test-AdminPrivilege @PSBoundParameters
}

function Test-DestinationFreeSpace {
    [CmdletBinding()]
    param( [string]$DestDir, [int]$MinRequiredGB, [bool]$ExitOnLow, [switch]$IsSimulateMode, [scriptblock]$Logger )
    if (-not $script:_loaded['SystemUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['SystemUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Test-DestinationFreeSpace @PSBoundParameters
}

function Test-HibernateEnabled {
    [CmdletBinding()]
    param( [scriptblock]$Logger )
    if (-not $script:_loaded['SystemUtils']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\SystemUtils.psm1") -Force -ErrorAction Stop; $script:_loaded['SystemUtils'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the SystemUtils sub-module. Error: $($_.Exception.Message)" }
    }
    return Test-HibernateEnabled @PSBoundParameters
}

function Write-LogMessage {
    [CmdletBinding()]
    param( [string]$Message, [string]$ForegroundColour, [switch]$NoNewLine, [string]$Level = "INFO", [switch]$NoTimestampToLogFile = $false )
    if (-not $script:_loaded['Logging']) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "Utilities\Logging.psm1") -Force -ErrorAction Stop
            $script:_loaded['Logging'] = $true
        } catch { Write-Error "Utils.psm1 Facade: Could not load the Logging sub-module. Error: $($_.Exception.Message)"; return }
    }
    Write-LogMessage @PSBoundParameters
}

function Invoke-PoShBackupUpdateCheckAndApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param( [scriptblock]$Logger, [string]$PSScriptRootForPaths, [System.Management.Automation.PSCmdlet]$PSCmdletInstance )
    if (-not $PSCmdletInstance.ShouldProcess("PoSh-Backup Update Check (delegated)", "Invoke")) { return }
    if (-not $script:_loaded['Update']) {
        try { Import-Module -Name (Join-Path $PSScriptRoot "Utilities\Update.psm1") -Force -ErrorAction Stop; $script:_loaded['Update'] = $true }
        catch { throw "Utils.psm1 Facade: Could not load the Update sub-module. Error: $($_.Exception.Message)" }
    }
    Invoke-PoShBackupUpdateCheckAndApply @PSBoundParameters
}

#endregion

# Corrected and completed list of all functions to export from the facade.
Export-ModuleMember -Function Get-ConfigValue, Get-RequiredConfigValue, Expand-EnvironmentVariablesInConfig, Write-ConsoleBanner, Write-NameValue, Start-CancellableCountdown, Get-PoShBackupSecret, Get-ArchiveSizeFormatted, Format-FileSize, Get-PoshBackupFileHash, Resolve-PoShBackupPath, Group-BackupInstancesByTimestamp, Get-ScriptVersionFromContent, Test-AdminPrivilege, Test-DestinationFreeSpace, Test-HibernateEnabled, Write-LogMessage, Invoke-PoShBackupUpdateCheckAndApply
