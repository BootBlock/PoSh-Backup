# Modules\Managers\VerificationManager\ArchiveRestorer.psm1
<#
.SYNOPSIS
    A sub-module for VerificationManager. Handles the restoration of a backup archive.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupRestoreForVerification' function. It is
    responsible for retrieving the necessary archive password (if any) and then calling
    the 7-Zip Manager's extraction function to restore a backup archive into the
    specified sandbox directory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To restore an archive into the verification sandbox.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\VerificationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\PasswordManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VerificationManager\ArchiveRestorer.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupRestoreForVerification {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The full path to the first part of the archive to restore.
        [Parameter(Mandatory = $true)]
        [string]$ArchiveToRestorePath,

        # The full path to the sandbox directory where the archive will be restored.
        [Parameter(Mandatory = $true)]
        [string]$SandboxPath,

        # The full path to the 7z.exe executable.
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPath,

        # The name of the SecretManagement secret for the archive's password, if any.
        [Parameter(Mandatory = $false)]
        [string]$PasswordSecretName,
        
        # The name of the target backup job, used for logging context.
        [Parameter(Mandatory = $true)]
        [string]$TargetJobName,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        # A reference to the calling cmdlet's $PSCmdlet automatic variable.
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "VerificationManager/ArchiveRestorer: Beginning restore of '$ArchiveToRestorePath'." -Level "DEBUG"
    
    $plainTextPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($PasswordSecretName)) {
        $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $PasswordSecretName }
        $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Verification of '$TargetJobName'" -Logger $Logger -GlobalConfig @{} # GlobalConfig not needed for this method
        $plainTextPassword = $passwordResult.PlainTextPassword
        if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
            & $LocalWriteLog -Message "Verification Restore: Failed to retrieve password from secret '$PasswordSecretName'. Aborting restore." -Level "ERROR"
            return @{ Success = $false; PlainTextPassword = $null }
        }
    }

    & $LocalWriteLog -Message "Verification Restore: Restoring '$ArchiveToRestorePath' to '$SandboxPath'." -Level "INFO"
    
    $restoreSuccess = Invoke-7ZipExtraction -SevenZipPathExe $SevenZipPath `
                                            -ArchivePath $ArchiveToRestorePath `
                                            -OutputDirectory $SandboxPath `
                                            -PlainTextPassword $plainTextPassword `
                                            -Force `
                                            -Logger $Logger `
                                            -PSCmdlet $PSCmdletInstance
    
    if (-not $restoreSuccess) {
        & $LocalWriteLog -Message "Verification Restore: Restore of '$ArchiveToRestorePath' FAILED. Aborting further checks for this instance." -Level "ERROR"
        return @{ Success = $false; PlainTextPassword = $plainTextPassword }
    }

    & $LocalWriteLog -Message "Verification Restore: Restore of '$ArchiveToRestorePath' completed successfully." -Level "SUCCESS"
    return @{ Success = $true; PlainTextPassword = $plainTextPassword }
}

Export-ModuleMember -Function Invoke-PoShBackupRestoreForVerification
