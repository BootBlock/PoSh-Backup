# Modules\Targets\SFTP.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for SFTP (SSH File Transfer Protocol). This module
    now acts as a facade, orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for SFTP destinations.
    It orchestrates the entire transfer and retention process by calling its sub-modules:
    - SFTP.SessionManager.psm1: Handles establishing and closing the Posh-SSH session.
    - SFTP.PathHandler.psm1: Ensures the remote directory structure exists.
    - SFTP.TransferAgent.psm1: Manages the actual file upload.
    - SFTP.RetentionApplicator.psm1: Applies the remote retention policy.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Major refactoring into a facade with sub-modules.
    DateCreated:    22-May-2025
    LastModified:   28-Jun-2025
    Purpose:        SFTP Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+, Posh-SSH module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$sftpSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "SFTP"
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $sftpSubModulePath "SFTP.SessionManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $sftpSubModulePath "SFTP.PathHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $sftpSubModulePath "SFTP.TransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $sftpSubModulePath "SFTP.RetentionApplicator.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SFTP.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- SFTP Target Connectivity Test Function ---
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
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    $sftpServer = $TargetSpecificSettings.SFTPServerAddress
    & $LocalWriteLog -Message "  - SFTP Target: Testing connectivity to server '$sftpServer'..." -Level "INFO"

    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        return @{ Success = $false; Message = "Posh-SSH module is not installed. Please install it using 'Install-Module Posh-SSH'." }
    }
    Import-Module Posh-SSH -ErrorAction SilentlyContinue
    
    $sftpSessionResult = $null
    
    try {
        if (-not $PSCmdlet.ShouldProcess($sftpServer, "Establish SFTP Test Connection")) {
            return @{ Success = $false; Message = "SFTP connection test skipped by user." }
        }

        $sftpSessionResult = New-PoShBackupSftpSession -TargetSpecificSettings $TargetSpecificSettings -Logger $Logger
        if (-not $sftpSessionResult.Success) { throw $sftpSessionResult.ErrorMessage }
        
        & $LocalWriteLog -Message "    - SUCCESS: SFTP session established successfully (Session ID: $($sftpSessionResult.Session.SessionId))." -Level "SUCCESS"

        $remotePath = $TargetSpecificSettings.SFTPRemotePath
        & $LocalWriteLog -Message "  - SFTP Target: Testing remote path '$remotePath'..." -Level "INFO"
        if (Test-SFTPPath -SessionId $sftpSessionResult.Session.SessionId -Path $remotePath) {
            & $LocalWriteLog -Message "    - SUCCESS: Remote path '$remotePath' exists." -Level "SUCCESS"
            return @{ Success = $true; Message = "Connection successful and remote path exists." }
        } else {
            return @{ Success = $false; Message = "Connection successful, but remote path '$remotePath' does not exist." }
        }
    }
    catch {
        $errorMessage = "SFTP connection test failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
    finally {
        if ($null -ne $sftpSessionResult.Session) {
            Close-PoShBackupSftpSession -Session $sftpSessionResult.Session -Logger $Logger
        }
    }
}
#endregion

#region --- SFTP Target Settings Validation Function ---
function Invoke-PoShBackupSFTPTargetSettingsValidation {
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
        & $Logger -Message "SFTP.Target/Invoke-PoShBackupSFTPTargetSettingsValidation: Logger active. Validating settings for SFTP Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }
    
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable.")
        return
    }

    foreach ($sftpKey in @('SFTPServerAddress', 'SFTPRemotePath', 'SFTPUserName')) {
        if (-not $TargetSpecificSettings.ContainsKey($sftpKey) -or -not ($TargetSpecificSettings.$sftpKey -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$sftpKey)) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': '$sftpKey' in 'TargetSpecificSettings' is missing, not a string, or empty.")
        }
    }

    if ($TargetSpecificSettings.ContainsKey('SFTPPort') -and -not ($TargetSpecificSettings.SFTPPort -is [int] -and $TargetSpecificSettings.SFTPPort -gt 0 -and $TargetSpecificSettings.SFTPPort -le 65535)) {
        $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'SFTPPort' in 'TargetSpecificSettings' must be an integer between 1 and 65535 if defined.")
    }

    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount') -and (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0)) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined.")
        }
    }
}
#endregion

#region --- SFTP Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding()]
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
    & $LocalWriteLog -Message ("`n[INFO] SFTP Target (Facade): Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $sftpSessionResult = $null

    try {
        if (-not (Get-Module -Name Posh-SSH -ListAvailable)) { throw "Posh-SSH module is not installed. Please install it using 'Install-Module Posh-SSH'." }
        Import-Module Posh-SSH -ErrorAction SilentlyContinue

        $sftpSettings = $TargetInstanceConfiguration.TargetSpecificSettings
        $createJobSubDir = if ($sftpSettings.ContainsKey('CreateJobNameSubdirectory')) { $sftpSettings.CreateJobNameSubdirectory } else { $false }
        $remoteFinalDirectory = if ($createJobSubDir) { "$($sftpSettings.SFTPRemotePath.TrimEnd('/'))/$JobName" } else { $sftpSettings.SFTPRemotePath.TrimEnd("/") }
        $fullRemoteArchivePath = "$remoteFinalDirectory/$ArchiveFileName"
        $result.RemotePath = $fullRemoteArchivePath

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would establish SFTP session, ensure path '$remoteFinalDirectory' exists, and upload '$ArchiveFileName'." -Level "SIMULATE"
            if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) { & $LocalWriteLog -Message "SIMULATE: After upload, retention policy would be applied." -Level "SIMULATE" }
            $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
            $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
            $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
        }
        
        # 1. Establish Session
        $sftpSessionResult = New-PoShBackupSftpSession -TargetSpecificSettings $sftpSettings -Logger $Logger
        if (-not $sftpSessionResult.Success) { throw $sftpSessionResult.ErrorMessage }
        $sftpSession = $sftpSessionResult.Session

        # 2. Ensure Path Exists
        $pathResult = Set-SFTPTargetPath -SftpSession $sftpSession -RemotePath $remoteFinalDirectory -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $pathResult.Success) { throw $pathResult.ErrorMessage }
        
        # 3. Upload File
        $uploadResult = Start-PoShBackupSftpUpload -SftpSession $sftpSession -LocalSourcePath $LocalArchivePath -FullRemoteDestinationPath $fullRemoteArchivePath -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $uploadResult.Success) { throw $uploadResult.ErrorMessage }
        
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - SFTP Target (Facade): File uploaded successfully.") -Level "SUCCESS"

        # 4. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings -is [hashtable]) {
            Invoke-SFTPRetentionPolicy -SftpSession $sftpSession -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                -RemoteDirectory $remoteFinalDirectory -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension `
                -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat -Logger $Logger -PSCmdletInstance $PSCmdlet
        }
    }
    catch {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        if ($null -ne $sftpSessionResult.Session) {
            Close-PoShBackupSftpSession -Session $sftpSessionResult.Session -Logger $Logger
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] SFTP Target (Facade): Finished transfer attempt for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupSFTPTargetSettingsValidation, Test-PoShBackupTargetConnectivity
