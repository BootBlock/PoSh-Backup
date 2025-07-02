# Modules\Managers\PasswordManager.psm1
<#
.SYNOPSIS
    Acts as a facade to manage the retrieval of archive passwords for PoSh-Backup jobs
    by lazy-loading and delegating to provider-specific sub-modules.
.DESCRIPTION
    This module abstracts the archive password acquisition logic for PoSh-Backup. It provides a
    centralised and secure way to obtain passwords required for encrypting 7-Zip archives.
    The main exported function, Get-PoShBackupArchivePassword, determines the configured password
    retrieval method and lazy-loads the appropriate provider sub-module from the
    '.\PasswordManager\' directory to perform the actual retrieval.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load provider sub-modules.
    DateCreated:    10-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Facade for centralised password management for archive encryption.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

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
                try {
                    Import-Module -Name (Join-Path $PSScriptRoot "PasswordManager\Interactive.Provider.psm1") -Force -ErrorAction Stop
                    $passwordSource = "Interactive (Get-Credential)"
                    $userNameHint = Get-RequiredConfigValue -JobConfig $JobConfigForPassword -GlobalConfig $GlobalConfig -JobKey 'CredentialUserNameHint' -GlobalKey 'DefaultCredentialUserNameHint'
                    $plainTextPassword = Get-PoShBackupInteractivePassword -JobName $JobName -UserNameHint $userNameHint -Logger $Logger
                } catch { throw "Could not load or execute the Interactive password provider. Error: $($_.Exception.Message)" }
            }
            "SECRETMANAGEMENT" {
                try {
                    Import-Module -Name (Join-Path $PSScriptRoot "PasswordManager\SecretManagement.Provider.psm1") -Force -ErrorAction Stop
                    $passwordSource = "SecretManagement"
                    $secretName = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecretName'
                    $secretVault = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordVaultName'
                    if ([string]::IsNullOrWhiteSpace($secretName)) { throw "'ArchivePasswordMethod' is 'SecretManagement' but 'ArchivePasswordSecretName' is not defined for job '$JobName'." }
                    $plainTextPassword = Get-PoShBackupSecretManagementPassword -SecretName $secretName -VaultName $secretVault -Logger $Logger
                } catch { throw "Could not load or execute the SecretManagement password provider. Error: $($_.Exception.Message)" }
            }
            "SECURESTRINGFILE" {
                try {
                    Import-Module -Name (Join-Path $PSScriptRoot "PasswordManager\SecureStringFile.Provider.psm1") -Force -ErrorAction Stop
                    $passwordSource = "SecureStringFile"
                    $secureStringPath = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecureStringPath'
                    if ([string]::IsNullOrWhiteSpace($secureStringPath)) { throw "'ArchivePasswordMethod' is 'SecureStringFile' but 'ArchivePasswordSecureStringPath' is not defined for job '$JobName'." }
                    $plainTextPassword = Get-PoShBackupSecureStringFilePassword -SecureStringPath $secureStringPath -Logger $Logger
                } catch { throw "Could not load or execute the SecureStringFile password provider. Error: $($_.Exception.Message)" }
            }
            "PLAINTEXT" {
                try {
                    Import-Module -Name (Join-Path $PSScriptRoot "PasswordManager\PlainText.Provider.psm1") -Force -ErrorAction Stop
                    $passwordSource = "PlainText (Insecure)"
                    $plainTextPasswordFromConfig = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordPlainText'
                    $plainTextPassword = Get-PoShBackupPlainTextPassword -PlainTextPassword $plainTextPasswordFromConfig -JobName $JobName -Logger $Logger
                } catch { throw "Could not load or execute the PlainText password provider. Error: $($_.Exception.Message)" }
            }
            "NONE" {
                $passwordSource = "None (Explicitly Configured or Defaulted)"
            }
            default {
                throw "Invalid or unrecognised 'ArchivePasswordMethod' ('$($passwordMethodFromConfig)') specified for job '$JobName'."
            }
        }
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\PasswordManager\' and its sub-modules exist and are not corrupted."
        & $LocalWriteLog -Message "[FATAL] PasswordManager (Facade): $_.Exception.Message" -Level "ERROR"
        & $LocalWriteLog -Message $advice -Level "ADVICE"
        throw $_.Exception
    }

    return @{ PlainTextPassword = $plainTextPassword; PasswordSource = $passwordSource }
}
#endregion

Export-ModuleMember -Function Get-PoShBackupArchivePassword
