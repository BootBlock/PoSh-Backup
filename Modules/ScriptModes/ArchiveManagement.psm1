# Modules\ScriptModes\ArchiveManagement.psm1
<#
.SYNOPSIS
    Handles archive management script modes for PoSh-Backup, such as listing contents,
    extracting files, and pinning/unpinning archives.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It encapsulates the logic
    for the following command-line switches by lazy-loading the required manager modules:
    - -ListArchiveContents
    - -ExtractFromArchive
    - -PinBackup
    - -UnpinBackup
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load manager dependencies.
    DateCreated:    15-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To handle archive management script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

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
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
            Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\PasswordManager.psm1") -Force -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace($ExtractToDirectoryPath)) { throw "The -ExtractToDirectory parameter is required when using -ExtractFromArchive." }

            $plainTextPasswordForExtract = $null
            if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
                $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
                $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Extraction" -Logger $Logger -GlobalConfig @{}
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
            if ($null -ne $ItemsToExtract -and $ItemsToExtract.Count -gt 0) { $extractParams.FilesToExtract = $ItemsToExtract }
            $success = Invoke-7ZipExtraction @extractParams
            if ($success) { & $LocalWriteLog -Message "Successfully extracted archive '$ExtractFromArchivePath' to '$ExtractToDirectoryPath'." -Level "SUCCESS" }
            else { & $LocalWriteLog -Message "Failed to extract archive '$ExtractFromArchivePath'. Check previous errors." -Level "ERROR" }
        } catch { & $LocalWriteLog -Message "[FATAL] ArchiveManagement: A required module could not be loaded or an error occurred. Error: $($_.Exception.Message)" -Level "ERROR" }
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ListArchiveContentsPath)) {
        & $LocalWriteLog -Message "`n--- List Archive Contents Mode ---" -Level "HEADING"
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
            Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\PasswordManager.psm1") -Force -ErrorAction Stop

            $plainTextPasswordForList = $null
            if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
                $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
                $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Listing" -Logger $Logger -GlobalConfig @{}
                $plainTextPasswordForList = $passwordResult.PlainTextPassword
            }

            $sevenZipPath = $Configuration.SevenZipPath
            $listing = Get-7ZipArchiveListing -SevenZipPathExe $sevenZipPath -ArchivePath $ListArchiveContentsPath -PlainTextPassword $plainTextPasswordForList -Logger $Logger
            if ($null -ne $listing) {
                & $LocalWriteLog -Message "Contents of archive: $ListArchiveContentsPath" -Level "INFO"
                $listing | Format-Table -AutoSize
                & $LocalWriteLog -Message "Found $($listing.Count) files/folders." -Level "SUCCESS"
            } else { & $LocalWriteLog -Message "Failed to list contents for archive: $ListArchiveContentsPath. Check previous errors." -Level "ERROR" }
        } catch { & $LocalWriteLog -Message "[FATAL] ArchiveManagement: A required module could not be loaded or an error occurred. Error: $($_.Exception.Message)" -Level "ERROR" }
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($PinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Pin Backup Archive Mode ---" -Level "HEADING"
        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\Managers\PinManager.psm1") -Force -ErrorAction Stop
            Add-PoShBackupPin -Path $PinBackupPath -Reason $PinReason -Logger $Logger
        } catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\PinManager.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] ArchiveManagement: Could not load the PinManager module. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($UnpinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Unpin Backup Archive Mode ---" -Level "HEADING"
        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\Managers\PinManager.psm1") -Force -ErrorAction Stop
            Remove-PoShBackupPin -Path $UnpinBackupPath -Logger $Logger
        } catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\PinManager.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] ArchiveManagement: Could not load the PinManager module. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
        return $true
    }

    return $false
}

Export-ModuleMember -Function Invoke-PoShBackupArchiveManagementMode
