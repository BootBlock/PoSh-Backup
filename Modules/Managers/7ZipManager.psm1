# Modules\Managers\7ZipManager.psm1
<#
.SYNOPSIS
    Manages all 7-Zip executable interactions for the PoSh-Backup solution.
    This module now acts as a facade, lazy-loading and re-exporting functions from
    specialised sub-modules located in '.\Modules\Managers\7ZipManager\'.
.DESCRIPTION
    The 7ZipManager module centralises 7-Zip specific logic by orchestrating calls to its sub-modules:
    - 'Discovery.psm1': Handles auto-detection of the 7z.exe path.
    - 'ArgumentBuilder.psm1': Constructs the complex argument list for 7-Zip commands.
    - 'Executor.psm1': Executes 7-Zip for archiving and testing, supporting
      retries, process priority, and CPU affinity.
    - 'Lister.psm1': Lists and parses the contents of an archive file.
    - 'Extractor.psm1': Extracts files from an archive.

    This facade approach allows other parts of PoSh-Backup to interact with a single
    '7ZipManager.psm1' for all 7-Zip related needs, while the underlying logic is
    organised into more focused sub-modules within the '7ZipManager' subdirectory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.3 # FIX: Corrected argument builder call to remove pipeline.
    DateCreated:    17-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Facade for centralised 7-Zip interaction logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    7-Zip (7z.exe) must be installed.
#>

# No eager module imports are needed here. They will be lazy-loaded.

#region --- Exported Functions ---

function Find-SevenZipExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\Discovery.psm1") -Force -ErrorAction Stop
        return Find-SevenZipExecutable @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/Discovery sub-module. Error: $($_.Exception.Message)" }
}

function Get-PoShBackup7ZipArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory, ValueFromPipeline = $false)]
        [string[]]$CurrentJobSourcePathFor7Zip,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\ArgumentBuilder.psm1") -Force -ErrorAction Stop
        return Get-PoShBackup7ZipArgument @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/ArgumentBuilder sub-module. Error: $($_.Exception.Message)" }
}

function Invoke-7ZipOperation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$SevenZipPathExe,
        [array]$SevenZipArguments,
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The plain text password is required by the 7z.exe process. Secure handling and clearing of this variable is managed by the calling functions (PasswordManager, JobExecutor).')]
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword = $null,
        [string]$ProcessPriority = "Normal",
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null,
        [switch]$HideOutput,
        [switch]$IsSimulateMode,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [bool]$TreatWarningsAsSuccess = $false,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\Executor.psm1") -Force -ErrorAction Stop
        return Invoke-7ZipOperation @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/Executor sub-module. Error: $($_.Exception.Message)" }
}

function Test-7ZipArchive {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The plain text password is required by the 7z.exe process. Secure handling and clearing of this variable is managed by the calling functions.')]
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword = $null,
        [string]$ProcessPriority = "Normal",
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null,
        [switch]$HideOutput,
        [switch]$VerifyCRC,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [bool]$TreatWarningsAsSuccess = $false,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\Executor.psm1") -Force -ErrorAction Stop
        return Test-7ZipArchive @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/Executor sub-module. Error: $($_.Exception.Message)" }
}

function Get-7ZipArchiveListing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPathExe,
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The plain text password is required by the 7z.exe process. Secure handling and clearing of this variable is managed by the calling functions.')]
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\Lister.psm1") -Force -ErrorAction Stop
        return Get-7ZipArchiveListing @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/Lister sub-module. Error: $($_.Exception.Message)" }
}

function Invoke-7ZipExtraction {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
        param(
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPathExe,
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $false)]
        [string[]]$FilesToExtract,
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The plain text password is required by the 7z.exe process. Secure handling and clearing of this variable is managed by the calling functions.')]
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword,
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager\Extractor.psm1") -Force -ErrorAction Stop
        return Invoke-7ZipExtraction @PSBoundParameters
    } catch { throw "Could not load the 7ZipManager/Extractor sub-module. Error: $($_.Exception.Message)" }
}

Export-ModuleMember -Function Find-SevenZipExecutable, Get-PoShBackup7ZipArgument, Invoke-7ZipOperation, Test-7ZipArchive, Get-7ZipArchiveListing, Invoke-7ZipExtraction
#endregion
