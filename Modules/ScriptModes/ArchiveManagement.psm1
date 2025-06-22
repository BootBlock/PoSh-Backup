# Modules\ScriptModes\ArchiveManagement.psm1
<#
.SYNOPSIS
    Handles archive management script modes for PoSh-Backup, such as listing contents,
    extracting files, and pinning/unpinning archives.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It encapsulates the logic
    for the following command-line switches:
    - -ListArchiveContents
    - -ExtractFromArchive
    - -PinBackup
    - -UnpinBackup
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    15-Jun-2025
    LastModified:   15-Jun-2025
    Purpose:        To handle archive management script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Managers\PinManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\ArchiveManagement.psm1: Could not import a manager module. Specific modes may be unavailable. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupArchiveManagementMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$PinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$PinReason,
        [Parameter(Mandatory = $false)]
        [string]$UnpinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$ListArchiveContentsPath,
        [Parameter(Mandatory = $false)]
        [string]$ExtractFromArchivePath,
        [Parameter(Mandatory = $false)]
        [string]$ExtractToDirectoryPath,
        [Parameter(Mandatory = $false)]
        [string[]]$ItemsToExtract,
        [Parameter(Mandatory = $false)]
        [bool]$ForceExtract,
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordSecretName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExtractFromArchivePath)) {
        & $LocalWriteLog -Message "`n--- Extract Archive Contents Mode ---" -Level "HEADING"
        if (-not (Get-Command Invoke-7ZipExtraction -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "FATAL: Could not find the Invoke-7ZipExtraction command. Ensure 'Modules\Managers\7ZipManager\Extractor.psm1' is present and loaded correctly." -Level "ERROR"
            return $true # Handled
        }
        if ([string]::IsNullOrWhiteSpace($ExtractToDirectoryPath)) {
            & $LocalWriteLog -Message "FATAL: The -ExtractToDirectory parameter is required when using -ExtractFromArchive." -Level "ERROR"
            return $true # Handled
        }

        $plainTextPasswordForExtract = $null
        if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
            if (-not (Get-Command Get-PoShBackupArchivePassword -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "FATAL: Could not find Get-PoShBackupArchivePassword command. Cannot retrieve password for encrypted archive." -Level "ERROR"
                return $true # Handled
            }
            $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
            $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Extraction" -Logger $Logger
            $plainTextPasswordForExtract = $passwordResult.PlainTextPassword
        }

        $sevenZipPath = $Configuration.SevenZipPath
        $extractParams = @{
            SevenZipPathExe  = $sevenZipPath
            ArchivePath      = $ExtractFromArchivePath
            OutputDirectory  = $ExtractToDirectoryPath
            PlainTextPassword = $plainTextPasswordForExtract
            Force            = [bool]$ForceExtract
            Logger           = $Logger
            PSCmdlet         = $PSCmdletInstance
        }
        if ($null -ne $ItemsToExtract -and $ItemsToExtract.Count -gt 0) {
            $extractParams.FilesToExtract = $ItemsToExtract
        }

        $success = Invoke-7ZipExtraction @extractParams

        if ($success) {
            & $LocalWriteLog -Message "Successfully extracted archive '$ExtractFromArchivePath' to '$ExtractToDirectoryPath'." -Level "SUCCESS"
        } else {
            & $LocalWriteLog -Message "Failed to extract archive '$ExtractFromArchivePath'. Check previous errors." -Level "ERROR"
        }
        return $true # Handled
    }

    if (-not [string]::IsNullOrWhiteSpace($ListArchiveContentsPath)) {
        & $LocalWriteLog -Message "`n--- List Archive Contents Mode ---" -Level "HEADING"
        if (-not (Get-Command Get-7ZipArchiveListing -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "FATAL: Could not find the Get-7ZipArchiveListing command. Ensure 'Modules\Managers\7ZipManager\Lister.psm1' is present and loaded correctly." -Level "ERROR"
            return $true # Handled
        }

        $plainTextPasswordForList = $null
        if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
            if (-not (Get-Command Get-PoShBackupArchivePassword -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "FATAL: Could not find Get-PoShBackupArchivePassword command. Cannot retrieve password for encrypted archive." -Level "ERROR"
                return $true # Handled
            }
            $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
            $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Listing" -Logger $Logger
            $plainTextPasswordForList = $passwordResult.PlainTextPassword
        }

        $sevenZipPath = $Configuration.SevenZipPath
        $listing = Get-7ZipArchiveListing -SevenZipPathExe $sevenZipPath -ArchivePath $ListArchiveContentsPath -PlainTextPassword $plainTextPasswordForList -Logger $Logger

        if ($null -ne $listing) {
            & $LocalWriteLog -Message "Contents of archive: $ListArchiveContentsPath" -Level "INFO"
            $listing | Format-Table -AutoSize
            & $LocalWriteLog -Message "Found $($listing.Count) files/folders." -Level "SUCCESS"
        } else {
            & $LocalWriteLog -Message "Failed to list contents for archive: $ListArchiveContentsPath. Check previous errors." -Level "ERROR"
        }
        return $true # Handled
    }

    if (-not [string]::IsNullOrWhiteSpace($PinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Pin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Add-PoShBackupPin -ErrorAction SilentlyContinue) {
            Add-PoShBackupPin -Path $PinBackupPath -Reason $PinReason -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Add-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        return $true # Handled
    }

    if (-not [string]::IsNullOrWhiteSpace($UnpinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Unpin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Remove-PoShBackupPin -ErrorAction SilentlyContinue) {
            Remove-PoShBackupPin -Path $UnpinBackupPath -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Remove-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        return $true # Handled
    }

    return $false # No archive management mode was handled
}

Export-ModuleMember -Function Invoke-PoShBackupArchiveManagementMode
