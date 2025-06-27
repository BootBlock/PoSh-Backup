# Modules\Targets\UNC.Target.psm1
<#
.SYNOPSIS
    Acts as a facade for the PoSh-Backup Target Provider for UNC paths.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for UNC path destinations.
    It acts as a facade, orchestrating calls to specialised sub-modules for each step of the
    transfer process:
    - UNCPathHandler.psm1: Ensures the remote directory structure exists.
    - UNCTransferAgent.psm1: Handles the actual file copy using Copy-Item or Robocopy.
    - UNCRetentionApplicator.psm1: Manages the remote retention policy.

    The main exported functions are Invoke-PoShBackupTargetTransfer, Test-PoShBackupTargetConnectivity,
    and Invoke-PoShBackupUNCTargetSettingsValidation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.1 # Corrected CmdletBinding and PSSA suppression on facade function.
    DateCreated:    19-May-2025
    LastModified:   27-Jun-2025
    Purpose:        UNC Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$uncSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "UNC"
try {
    Import-Module -Name (Join-Path $uncSubModulePath "UNCPathHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $uncSubModulePath "UNCTransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $uncSubModulePath "UNCRetentionApplicator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "UNC.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- UNC Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "UNC.Target/Test-PoShBackupTargetConnectivity: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    $uncPath = $TargetSpecificSettings.UNCRemotePath
    & $LocalWriteLog -Message "  - UNC Target: Testing connectivity to path '$uncPath'..." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($uncPath, "Test Path Accessibility")) {
        return @{ Success = $false; Message = "Connectivity test skipped by user." }
    }

    try {
        if (Test-Path -LiteralPath $uncPath -PathType Container -ErrorAction Stop) {
            return @{ Success = $true; Message = "Path is accessible." }
        }
        else {
            return @{ Success = $false; Message = "Path not found or is not a container/directory." }
        }
    }
    catch {
        return @{ Success = $false; Message = "An error occurred while testing path. Error: $($_.Exception.Message)" }
    }
}
#endregion

#region --- UNC Target Settings Validation Function ---
function Invoke-PoShBackupUNCTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "UNC.Target/Invoke-PoShBackupUNCTargetSettingsValidation: Logger active for '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    if (-not ($TargetSpecificSettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable."); return }
    if (-not $TargetSpecificSettings.ContainsKey('UNCRemotePath') -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.UNCRemotePath)) { $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'UNCRemotePath' is missing or empty.") }
    if ($TargetSpecificSettings.ContainsKey('UseRobocopy') -and -not ($TargetSpecificSettings.UseRobocopy -is [boolean])) { $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'UseRobocopy' must be a boolean.") }
    if ($TargetSpecificSettings.ContainsKey('RobocopySettings') -and -not ($TargetSpecificSettings.RobocopySettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("UNC Target '$TargetInstanceName': 'RobocopySettings' must be a Hashtable.") }
}
#endregion

#region --- UNC Target Transfer Function ---
<# PSScriptAnalyzer Suppress PSShouldProcess - Justification: This is a facade function that delegates all ShouldProcess calls to its sub-modules (Set-UNCTargetPath, Start-PoShBackupUNCCopy, Invoke-UNCRetentionPolicy). #>
function Invoke-PoShBackupTargetTransfer {
    param(
        [Parameter(Mandatory = $true)] [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$JobName,
        [Parameter(Mandatory = $true)] [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)] [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)] [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)] [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] UNC Target (Facade): Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $uncSettings = $TargetInstanceConfiguration.TargetSpecificSettings
        $uncRemoteBasePath = $uncSettings.UNCRemotePath.TrimEnd("\/")
        $createJobSubDir = if ($uncSettings.ContainsKey('CreateJobNameSubdirectory')) { $uncSettings.CreateJobNameSubdirectory } else { $false }
        $remoteFinalDirectory = if ($createJobSubDir) { Join-Path -Path $uncRemoteBasePath -ChildPath $JobName } else { $uncRemoteBasePath }
        $fullRemoteArchivePath = Join-Path -Path $remoteFinalDirectory -ChildPath $ArchiveFileName
        $result.RemotePath = $fullRemoteArchivePath

        # 1. Ensure Path Exists
        $ensurePathResult = Set-UNCTargetPath -Path $remoteFinalDirectory -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
        if (-not $ensurePathResult.Success) { throw ("Failed to ensure remote directory '$remoteFinalDirectory' exists. Error: " + $ensurePathResult.ErrorMessage) }

        # 2. Transfer the file
        $copyResult = Start-PoShBackupUNCCopy -LocalSourcePath $LocalArchivePath -FullRemoteDestinationPath $fullRemoteArchivePath `
            -UseRobocopy $uncSettings.UseRobocopy -RobocopySettings $uncSettings.RobocopySettings `
            -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $copyResult.Success) { throw $copyResult.ErrorMessage }

        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
        
        # 3. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) {
            Invoke-UNCRetentionPolicy -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                -RemoteDirectory $remoteFinalDirectory `
                -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                -Logger $Logger -PSCmdletInstance $PSCmdlet
        }
    }
    catch {
        $result.ErrorMessage = "UNC Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] UNC Target (Facade): Finished transfer for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupUNCTargetSettingsValidation, Test-PoShBackupTargetConnectivity
