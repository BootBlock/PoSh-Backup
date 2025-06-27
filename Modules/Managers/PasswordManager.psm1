# Modules\Managers\PasswordManager.psm1
<#
.SYNOPSIS
    Acts as a facade to manage the retrieval of archive passwords for PoSh-Backup jobs
    by delegating to provider-specific sub-modules.
.DESCRIPTION
    This module abstracts the archive password acquisition logic for PoSh-Backup. It provides a
    centralised and secure way to obtain passwords required for encrypting 7-Zip archives.
    The main exported function, Get-PoShBackupArchivePassword, determines the configured password
    retrieval method and calls the appropriate provider sub-module located in the
    '.\PasswordManager\' directory to perform the actual retrieval.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade with provider sub-modules.
    DateCreated:    10-May-2025
    LastModified:   26-Jun-2025
    Purpose:        Facade for centralised password management for archive encryption.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    # Import the utility and provider modules.
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    $providerPath = Join-Path -Path $PSScriptRoot -ChildPath "PasswordManager"
    Import-Module -Name (Join-Path -Path $providerPath -ChildPath "Common.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $providerPath -ChildPath "Interactive.Provider.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $providerPath -ChildPath "SecretManagement.Provider.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $providerPath -ChildPath "SecureStringFile.Provider.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $providerPath -ChildPath "PlainText.Provider.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "PasswordManager.psm1 (Facade) FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function ---
function Get-PoShBackupArchivePassword {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$JobConfigForPassword,
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $false)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "PasswordManager (Facade): Logger active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $plainTextPassword = $null
    $passwordSource = "None (Initial)"

    $passwordMethodFromConfig = Get-RequiredConfigValue -JobConfig $JobConfigForPassword -GlobalConfig $GlobalConfig -JobKey 'ArchivePasswordMethod' -GlobalKey 'DefaultArchivePasswordMethod'
    $effectivePasswordMethod = $passwordMethodFromConfig.ToString().ToUpperInvariant()

    & $LocalWriteLog -Message "PasswordManager (Facade): Password retrieval method for job '$JobName' is '$effectivePasswordMethod'." -Level "DEBUG"

    $usePasswordLegacy = Get-RequiredConfigValue -JobConfig $JobConfigForPassword -GlobalConfig $GlobalConfig -JobKey 'UsePassword' -GlobalKey 'DefaultUsePassword'
    if ($effectivePasswordMethod -eq "NONE" -and $usePasswordLegacy -eq $true) {
        & $LocalWriteLog -Message "[INFO] Legacy 'UsePassword = `$true' found with 'ArchivePasswordMethod = None' for job '$JobName'. Defaulting to INTERACTIVE method." -Level "INFO"
        $effectivePasswordMethod = "INTERACTIVE"
    }

    if ($IsSimulateMode.IsPresent -and $effectivePasswordMethod -ne "NONE") {
        $passwordSource = "Simulated ($effectivePasswordMethod)"
        & $LocalWriteLog -Message "SIMULATE: Would retrieve password for job '$JobName' using method '$effectivePasswordMethod'." -Level "SIMULATE"
        $plainTextPassword = "SimulatedPassword123!"
        return @{ PlainTextPassword = $plainTextPassword; PasswordSource = $passwordSource }
    }

    try {
        switch ($effectivePasswordMethod) {
            "INTERACTIVE" {
                $passwordSource = "Interactive (Get-Credential)"
                $userNameHint = Get-RequiredConfigValue -JobConfig $JobConfigForPassword -GlobalConfig $GlobalConfig -JobKey 'CredentialUserNameHint' -GlobalKey 'DefaultCredentialUserNameHint'
                $plainTextPassword = Get-PoShBackupInteractivePassword -JobName $JobName -UserNameHint $userNameHint -Logger $Logger
            }
            "SECRETMANAGEMENT" {
                $passwordSource = "SecretManagement"
                $secretName = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecretName'
                $secretVault = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordVaultName'
                if ([string]::IsNullOrWhiteSpace($secretName)) { throw "'ArchivePasswordMethod' is 'SecretManagement' but 'ArchivePasswordSecretName' is not defined for job '$JobName'." }
                $plainTextPassword = Get-PoShBackupSecretManagementPassword -SecretName $secretName -VaultName $secretVault -Logger $Logger
            }
            "SECURESTRINGFILE" {
                $passwordSource = "SecureStringFile"
                $secureStringPath = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecureStringPath'
                if ([string]::IsNullOrWhiteSpace($secureStringPath)) { throw "'ArchivePasswordMethod' is 'SecureStringFile' but 'ArchivePasswordSecureStringPath' is not defined for job '$JobName'." }
                $plainTextPassword = Get-PoShBackupSecureStringFilePassword -SecureStringPath $secureStringPath -Logger $Logger
            }
            "PLAINTEXT" {
                $passwordSource = "PlainText (Insecure)"
                $plainTextPasswordFromConfig = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordPlainText'
                $plainTextPassword = Get-PoShBackupPlainTextPassword -PlainTextPassword $plainTextPasswordFromConfig -JobName $JobName -Logger $Logger
            }
            "NONE" {
                $passwordSource = "None (Explicitly Configured or Defaulted)"
                # No action needed, $plainTextPassword remains $null
            }
            default {
                throw "Invalid or unrecognised 'ArchivePasswordMethod' ('$($passwordMethodFromConfig)') specified for job '$JobName'."
            }
        }
    }
    catch {
        # The provider modules will log the detailed error. The facade just needs to re-throw to halt the job.
        throw $_.Exception
    }

    return @{ PlainTextPassword = $plainTextPassword; PasswordSource = $passwordSource }
}
#endregion

Export-ModuleMember -Function Get-PoShBackupArchivePassword
