<#
.SYNOPSIS
    Handles the retrieval of archive passwords for PoSh-Backup jobs using various configurable
    methods, such as interactive prompts (Get-Credential), PowerShell SecretManagement,
    reading from an encrypted SecureString file, or (discouraged) plain text from configuration.
.DESCRIPTION
    This module abstracts the password acquisition logic, providing a centralized and secure
    way to obtain passwords needed for encrypting 7-Zip archives. It supports multiple
    password sources to cater to different operational needs, from interactive use to
    fully automated scheduled tasks.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.3 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    10-May-2025
    LastModified:   15-May-2025
    Purpose:        Centralised password management for archive encryption.
    Prerequisites:  PowerShell 5.1+. For 'SecretManagement' method, the
                    Microsoft.PowerShell.SecretManagement module and a configured vault are required.
#>

#region --- Private Helper: SecureString to PlainText ---
# To be used ONLY for passing to 7-Zip temp file and cleared immediately.
# This function converts a SecureString object into a plain text string.
# It uses COM interop (Marshal class) to handle the SecureString securely in memory
# as much as possible, converting it to a BSTR (Basic String used by COM), then to a .NET string,
# and finally zeroing out the BSTR memory.
function ConvertTo-PlainTextSecureStringInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$SecureString
    )
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $plainText
}
#endregion

#region --- Exported Function ---
# Main function to retrieve the archive password based on the configured method.
# It centralizes all password acquisition logic.
function Get-PoShBackupArchivePassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$JobConfigForPassword, # The specific job's configuration hashtable (or a subset containing password keys)

        [Parameter(Mandatory=$true)]
        [string]$JobName, # For logging and user prompts

        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode, # Indicates if the script is in simulation mode

        [Parameter(Mandatory=$true)] # Logger is now mandatory as its PSSA warning is globally excluded
        [scriptblock]$Logger # A scriptblock reference to the main Write-LogMessage function for consistent logging
    )

    # Internal helper to use the passed-in logger.
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $plainTextPassword = $null
    $passwordSource = "None (Initial)" # Default source if no method is triggered

    # Determine the password retrieval method from the job's configuration.
    $passwordMethod = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $passwordMethod = $passwordMethod.ToString().ToUpperInvariant() # Standardize for switch statement

    & $LocalWriteLog -Message "Password method for job '$JobName': '$passwordMethod'." -Level DEBUG

    switch ($passwordMethod) {
        "NONE" {
            # No explicit password method configured.
            # Check for legacy 'UsePassword' setting for backward compatibility.
            # If 'UsePassword = $true' and no modern method is set, default to "INTERACTIVE".
            if ((Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'UsePassword' -DefaultValue $false) -eq $true) {
                & $LocalWriteLog -Message "[INFO] Legacy 'UsePassword = `$true' found with 'ArchivePasswordMethod = None'. Defaulting to INTERACTIVE for job '$JobName'." -Level INFO
                $passwordMethod = "INTERACTIVE"
                # Fallthrough to "INTERACTIVE" case below will now trigger
            } else {
                $passwordSource = "None (Not Configured)"
                & $LocalWriteLog -Message "  - No archive password configured for job '$JobName'." -Level DEBUG
                return @{ PlainTextPassword = $null; PasswordSource = $passwordSource } # Explicitly return, no password
            }
        }

        "INTERACTIVE" {
            $passwordSource = "Interactive (Get-Credential)"
            $userNameHint = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
            & $LocalWriteLog -Message "`n[INFO] Password required for '$JobName' (interactive prompt)." -Level INFO
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would prompt for password interactively for job '$JobName'." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordInteractive123!"
            } else {
                $cred = Get-Credential -UserName $userNameHint -Message "Enter password for 7-Zip backup: '$JobName'"
                if ($null -ne $cred) {
                    $plainTextPassword = $cred.GetNetworkCredential().Password
                    & $LocalWriteLog -Message "   - Credentials obtained interactively." -Level SUCCESS
                } else {
                    & $LocalWriteLog -Message "FATAL: Password entry cancelled for '$JobName'." -Level ERROR; throw "Password entry cancelled for job '$JobName'."
                }
            }
        }

        "SECRETMANAGEMENT" {
            $passwordSource = "SecretManagement"
            $secretName = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecretName' -DefaultValue $null
            $secretVault = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordVaultName' -DefaultValue $null

            if ([string]::IsNullOrWhiteSpace($secretName)) {
                & $LocalWriteLog -Message "FATAL: ArchivePasswordMethod is 'SecretManagement' but 'ArchivePasswordSecretName' is not defined for job '$JobName'." -Level ERROR; throw "ArchivePasswordSecretName not configured for SecretManagement."
            }

            $vaultInfoString = if (-not [string]::IsNullOrWhiteSpace($secretVault)) { " from vault '$secretVault'" } else { "" }
            & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecretManagement for job '$JobName' (Secret: '$secretName'$vaultInfoString)." -Level INFO

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would retrieve secret '$secretName'$vaultInfoString." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordSecret123!"
            } else {
                try {
                    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
                        throw "PowerShell SecretManagement module is not available. Please install it (Install-Module Microsoft.PowerShell.SecretManagement) and a vault module (e.g., Install-Module Microsoft.PowerShell.SecretStore)."
                    }
                    $getSecretParams = @{ Name = $secretName; ErrorAction = 'Stop' }
                    if (-not [string]::IsNullOrWhiteSpace($secretVault)) {
                        $getSecretParams.Vault = $secretVault
                    }
                    $secretObject = Get-Secret @getSecretParams

                    if ($null -ne $secretObject) {
                        if ($secretObject.Secret -is [System.Security.SecureString]) {
                            $plainTextPassword = ConvertTo-PlainTextSecureStringInternal -SecureString $secretObject.Secret
                            & $LocalWriteLog -Message "   - Password successfully retrieved from SecretManagement and converted." -Level SUCCESS
                        } elseif ($secretObject.Secret -is [string]) {
                            $plainTextPassword = $secretObject.Secret
                            & $LocalWriteLog -Message "   - Password (plain text) successfully retrieved from SecretManagement." -Level SUCCESS
                        } else {
                             & $LocalWriteLog -Message "FATAL: Secret '$secretName' retrieved but was not a SecureString or String. Type: $($secretObject.Secret.GetType().Name)" -Level ERROR; throw "Invalid secret type for '$secretName'."
                        }
                    } else {
                        & $LocalWriteLog -Message "FATAL: Secret '$secretName' not found or could not be retrieved (Get-Secret returned null)." -Level ERROR; throw "Secret '$secretName' not found or Get-Secret returned null."
                    }
                } catch {
                    & $LocalWriteLog -Message "FATAL: Failed to retrieve secret '$secretName'$vaultInfoString. Error: $($_.Exception.Message)" -Level ERROR
                    throw "Failed to retrieve secret for job '$JobName': $($_.Exception.Message)"
                }
            }
        }

        "SECURESTRINGFILE" {
            $passwordSource = "SecureStringFile"
            $secureStringPath = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null

            if ([string]::IsNullOrWhiteSpace($secureStringPath)) {
                & $LocalWriteLog -Message "FATAL: ArchivePasswordMethod is 'SecureStringFile' but 'ArchivePasswordSecureStringPath' is not defined for job '$JobName'." -Level ERROR; throw "ArchivePasswordSecureStringPath not configured."
            }
            if (-not (Test-Path -LiteralPath $secureStringPath -PathType Leaf)) {
                & $LocalWriteLog -Message "FATAL: SecureStringFile '$secureStringPath' not found for job '$JobName'." -Level ERROR; throw "SecureStringFile not found: $secureStringPath"
            }

            & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecureStringFile: '$secureStringPath' for job '$JobName'." -Level INFO
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would read and decrypt password from '$secureStringPath'." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordFile123!"
            } else {
                try {
                    $secureString = Import-Clixml -LiteralPath $secureStringPath -ErrorAction Stop
                    if ($secureString -is [System.Security.SecureString]) {
                        $plainTextPassword = ConvertTo-PlainTextSecureStringInternal -SecureString $secureString
                        & $LocalWriteLog -Message "   - Password successfully retrieved from SecureStringFile and converted." -Level SUCCESS
                    } else {
                        & $LocalWriteLog -Message "FATAL: File '$secureStringPath' did not contain a valid SecureString object." -Level ERROR; throw "Invalid content in SecureStringFile: $secureStringPath"
                    }
                } catch {
                    & $LocalWriteLog -Message "FATAL: Failed to read or decrypt SecureStringFile '$secureStringPath'. Error: $($_.Exception.Message)" -Level ERROR
                    throw "Failed to process SecureStringFile for job '$JobName': $($_.Exception.Message)"
                }
            }
        }

        "PLAINTEXT" {
            $passwordSource = "PlainText (Insecure)"
            $plainTextPassword = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordPlainText' -DefaultValue $null

            if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
                & $LocalWriteLog -Message "FATAL: ArchivePasswordMethod is 'PlainText' but 'ArchivePasswordPlainText' is empty or not defined for job '$JobName'." -Level ERROR; throw "ArchivePasswordPlainText not configured."
            }
            & $LocalWriteLog -Message "[WARNING] Using PLAIN TEXT password from configuration for job '$JobName'. This is INSECURE and NOT RECOMMENDED for production." -Level WARNING
            if ($IsSimulateMode.IsPresent) {
                 & $LocalWriteLog -Message "SIMULATE: Would use plain text password from configuration." -Level SIMULATE
            }
        }

        Default {
            if ($passwordMethod -ne "NONE" -and $passwordMethod -ne "INTERACTIVE") {
                & $LocalWriteLog -Message "FATAL: Invalid 'ArchivePasswordMethod' ('$(Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordMethod' -DefaultValue "UNDEFINED")') specified for job '$JobName'." -Level ERROR
                throw "Invalid ArchivePasswordMethod specified."
            } elseif ($passwordMethod -eq "NONE") {
                 $passwordSource = "None (Explicitly or Defaulted)"
                & $LocalWriteLog -Message "  - No archive password to be used for job '$JobName' (Method: None)." -Level DEBUG
            }
        }
    }

    return @{ PlainTextPassword = $plainTextPassword; PasswordSource = $passwordSource }
}

Export-ModuleMember -Function Get-PoShBackupArchivePassword
#endregion
