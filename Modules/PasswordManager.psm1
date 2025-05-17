<#
.SYNOPSIS
    Handles the retrieval of archive passwords for PoSh-Backup jobs using various configurable
    methods. These methods include interactive prompts (Get-Credential), PowerShell SecretManagement,
    reading from an encrypted SecureString file, or (discouraged) plain text from configuration.

.DESCRIPTION
    This module abstracts the archive password acquisition logic for PoSh-Backup. It provides a
    centralised and secure way to obtain passwords required for encrypting 7-Zip archives.
    By supporting multiple password sources, it caters to different operational needs,
    from interactive user-driven backups to fully automated, scheduled tasks.

    The primary exported function, Get-PoShBackupArchivePassword, determines the configured password
    retrieval method for a given job and executes the appropriate logic. It aims to handle
    passwords securely, for instance by using temporary files when interacting with 7-Zip,
    and by leveraging PowerShell's SecretManagement framework or DPAPI-encrypted files where possible.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Added defensive logger call for PSSA.
    DateCreated:    10-May-2025
    LastModified:   17-May-2025
    Purpose:        Centralised password management for archive encryption within PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    For the 'SecretManagement' method, the 'Microsoft.PowerShell.SecretManagement'
                    module and a configured vault provider (e.g., 'Microsoft.PowerShell.SecretStore')
                    are required on the system executing the backup.
                    For the 'SecureStringFile' method, a valid .clixml file created via Export-CliXml
                    from a SecureString object is needed.
#>

#region --- Private Helper: SecureString to PlainText ---
# This function converts a SecureString object into a plain text string.
# WARNING: This is inherently less secure than keeping the string encrypted.
# It should ONLY be used in memory for the brief moment required to pass the password
# to an external process (like 7-Zip via a temporary file) and the plain text variable
# should be cleared immediately afterwards.
# It uses COM interop (Marshal class) to handle the SecureString securely in memory
# as much as possible during the conversion, converting it to a BSTR (Basic String used by COM),
# then to a .NET string, and finally zeroing out the BSTR memory.
function ConvertTo-PlainTextSecureStringInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$SecureString
    )
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) # Zero out the unmanaged memory
    return $plainText
}
#endregion

#region --- Exported Function ---
function Get-PoShBackupArchivePassword {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Retrieves an archive password for a PoSh-Backup job based on its configured method.
    .DESCRIPTION
        This function centralises all password acquisition logic for PoSh-Backup.
        It reads the 'ArchivePasswordMethod' from the provided job configuration and attempts
        to retrieve the password accordingly. Supported methods include:
        - "Interactive": Prompts the user via Get-Credential.
        - "SecretManagement": Fetches the password from a PowerShell SecretManagement vault.
        - "SecureStringFile": Reads and decrypts a password from an Export-CliXml encrypted file.
        - "PlainText": (Discouraged) Reads the password directly from the configuration.
        - "None": No password is used.
        In simulation mode, actual credential prompts or vault access are skipped, and placeholder
        passwords may be returned for logging purposes.
    .PARAMETER JobConfigForPassword
        A hashtable containing the configuration settings for the specific backup job.
        This hashtable is expected to contain keys relevant to password retrieval, such as:
        'ArchivePasswordMethod', 'CredentialUserNameHint', 'ArchivePasswordSecretName',
        'ArchivePasswordVaultName', 'ArchivePasswordSecureStringPath', 'ArchivePasswordPlainText',
        and the legacy 'UsePassword'.
    .PARAMETER JobName
        The name of the backup job for which the password is being retrieved. Used in log messages
        and interactive prompts.
    .PARAMETER IsSimulateMode
        A switch. If $true, the function simulates password retrieval. For "Interactive" or
        "SecretManagement", it returns a placeholder password string. For "SecureStringFile" or
        "PlainText", it logs that it would use the configured source but may return a placeholder.
        No actual prompts occur, nor are secrets/files accessed in simulation mode.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for consistent logging throughout the password retrieval process.
    .EXAMPLE
        # This function is typically called by Operations.psm1
        # $passwordDetails = Get-PoShBackupArchivePassword -JobConfigForPassword $jobSettings -JobName "MyServerBackup" -Logger ${function:Write-LogMessage}
        # if ($passwordDetails.PlainTextPassword) {
        #   Write-Host "Password obtained from: $($passwordDetails.PasswordSource)"
        # }
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with two keys:
        - 'PlainTextPassword' (string): The retrieved password in plain text if a method other than "None"
          was successful. This will be $null if no password is to be used or if retrieval failed
          (and an error was not thrown). In simulation mode, this might be a placeholder string.
          IMPORTANT: The caller is responsible for securely handling and clearing this plain text password.
        - 'PasswordSource' (string): A descriptive string indicating the method used to obtain the
          password (e.g., "Interactive (Get-Credential)", "SecretManagement", "None (Not Configured)").
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$JobConfigForPassword,

        [Parameter(Mandatory=$true)]
        [string]$JobName,

        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode,

        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line: Logger is functionally used via $LocalWriteLog,
    # but this direct call ensures PSSA sees it explicitly.
    & $Logger -Message "Get-PoShBackupArchivePassword: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $plainTextPassword = $null
    $passwordSource = "None (Initial)" # Default source if no specific method is triggered successfully

    # Determine the password retrieval method from the job's configuration.
    $passwordMethodFromConfig = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $effectivePasswordMethod = $passwordMethodFromConfig.ToString().ToUpperInvariant() # Standardise for switch statement

    & $LocalWriteLog -Message "Password retrieval method for job '$JobName' from config: '$passwordMethodFromConfig' (Effective: '$effectivePasswordMethod')." -Level DEBUG

    # Handle legacy 'UsePassword' setting if no modern method is explicitly "None"
    if ($effectivePasswordMethod -eq "NONE" -and (Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'UsePassword' -DefaultValue $false) -eq $true) {
        & $LocalWriteLog -Message "[INFO] Legacy 'UsePassword = `$true' found with 'ArchivePasswordMethod = None' for job '$JobName'. Defaulting to INTERACTIVE method." -Level INFO
        $effectivePasswordMethod = "INTERACTIVE" # Override to use interactive method
    }

    switch ($effectivePasswordMethod) {
        "INTERACTIVE" {
            $passwordSource = "Interactive (Get-Credential)"
            $userNameHint = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
            & $LocalWriteLog -Message "`n[INFO] Password required for '$JobName'. Method: Interactive prompt." -Level INFO
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would prompt for password interactively for job '$JobName' (username hint: '$userNameHint')." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordInteractive123!" # Placeholder for simulation
            } else {
                $cred = Get-Credential -UserName $userNameHint -Message "Enter password for 7-Zip archive of job: '$JobName'"
                if ($null -ne $cred) {
                    $plainTextPassword = $cred.GetNetworkCredential().Password
                    & $LocalWriteLog -Message "   - Credentials obtained interactively for job '$JobName'." -Level SUCCESS
                } else {
                    # User cancelled Get-Credential prompt
                    & $LocalWriteLog -Message "FATAL: Password entry via Get-Credential was cancelled by the user for job '$JobName'." -Level ERROR
                    throw "Password entry cancelled for job '$JobName'."
                }
            }
        }

        "SECRETMANAGEMENT" {
            $passwordSource = "SecretManagement"
            $secretName = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecretName' -DefaultValue $null
            $secretVault = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordVaultName' -DefaultValue $null # Optional

            if ([string]::IsNullOrWhiteSpace($secretName)) {
                & $LocalWriteLog -Message "FATAL: 'ArchivePasswordMethod' is 'SecretManagement' but 'ArchivePasswordSecretName' is not defined in the configuration for job '$JobName'." -Level ERROR
                throw "ArchivePasswordSecretName not configured for SecretManagement method in job '$JobName'."
            }

            $vaultInfoString = if (-not [string]::IsNullOrWhiteSpace($secretVault)) { " from vault '$secretVault'" } else { " from default vault" }
            & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecretManagement for job '$JobName' (Secret: '$secretName'$vaultInfoString)." -Level INFO

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would attempt to retrieve secret '$secretName'$vaultInfoString from PowerShell SecretManagement." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordSecret123!" # Placeholder for simulation
            } else {
                try {
                    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
                        throw "The PowerShell SecretManagement module (Microsoft.PowerShell.SecretManagement) does not appear to be available or its cmdlets are not found. Please ensure it and a vault provider (e.g., Microsoft.PowerShell.SecretStore) are installed and configured."
                    }
                    $getSecretParams = @{ Name = $secretName; ErrorAction = 'Stop' }
                    if (-not [string]::IsNullOrWhiteSpace($secretVault)) {
                        $getSecretParams.Vault = $secretVault
                    }
                    $secretObject = Get-Secret @getSecretParams

                    if ($null -ne $secretObject) {
                        if ($secretObject.Secret -is [System.Security.SecureString]) {
                            $plainTextPassword = ConvertTo-PlainTextSecureStringInternal -SecureString $secretObject.Secret
                            & $LocalWriteLog -Message "   - Password (SecureString) successfully retrieved from SecretManagement for '$secretName'$vaultInfoString and converted." -Level SUCCESS
                        } elseif ($secretObject.Secret -is [string]) {
                            $plainTextPassword = $secretObject.Secret # If vault stores it as plain text (less common)
                            & $LocalWriteLog -Message "   - Password (plain text string) successfully retrieved from SecretManagement for '$secretName'$vaultInfoString." -Level SUCCESS
                        } else {
                             & $LocalWriteLog -Message "FATAL: Secret '$secretName'$vaultInfoString retrieved, but its content was not a SecureString or a plain String. Type found: $($secretObject.Secret.GetType().FullName)" -Level ERROR
                             throw "Invalid secret type for '$secretName' from SecretManagement."
                        }
                    } else { # Get-Secret returned null, implying secret not found with given name/vault
                        & $LocalWriteLog -Message "FATAL: Secret '$secretName'$vaultInfoString not found or could not be retrieved using Get-Secret (returned null)." -Level ERROR
                        throw "Secret '$secretName' not found or Get-Secret returned null from SecretManagement."
                    }
                } catch {
                    & $LocalWriteLog -Message "FATAL: Failed to retrieve secret '$secretName'$vaultInfoString using SecretManagement. Error: $($_.Exception.Message)" -Level ERROR
                    throw "Failed to retrieve secret for job '$JobName' via SecretManagement: $($_.Exception.Message)" # Re-throw to halt
                }
            }
        }

        "SECURESTRINGFILE" {
            $passwordSource = "SecureStringFile"
            $secureStringPath = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null

            if ([string]::IsNullOrWhiteSpace($secureStringPath)) {
                & $LocalWriteLog -Message "FATAL: 'ArchivePasswordMethod' is 'SecureStringFile' but 'ArchivePasswordSecureStringPath' is not defined in the configuration for job '$JobName'." -Level ERROR
                throw "ArchivePasswordSecureStringPath not configured for SecureStringFile method in job '$JobName'."
            }
            if (-not (Test-Path -LiteralPath $secureStringPath -PathType Leaf)) {
                & $LocalWriteLog -Message "FATAL: SecureStringFile '$secureStringPath' (configured for job '$JobName') not found at the specified path." -Level ERROR
                throw "SecureStringFile not found: '$secureStringPath' for job '$JobName'."
            }

            & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecureStringFile: '$secureStringPath' for job '$JobName'." -Level INFO
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would read and decrypt password from SecureStringFile '$secureStringPath'." -Level SIMULATE
                $plainTextPassword = "SimulatedPasswordFile123!" # Placeholder for simulation
            } else {
                try {
                    $secureString = Import-Clixml -LiteralPath $secureStringPath -ErrorAction Stop
                    if ($secureString -is [System.Security.SecureString]) {
                        $plainTextPassword = ConvertTo-PlainTextSecureStringInternal -SecureString $secureString
                        & $LocalWriteLog -Message "   - Password successfully retrieved from SecureStringFile '$secureStringPath' and converted." -Level SUCCESS
                    } else {
                        & $LocalWriteLog -Message "FATAL: File '$secureStringPath' for job '$JobName' did not contain a valid SecureString object. It contained type: $($secureString.GetType().FullName)" -Level ERROR
                        throw "Invalid content in SecureStringFile: '$secureStringPath'."
                    }
                } catch {
                    & $LocalWriteLog -Message "FATAL: Failed to read or decrypt SecureStringFile '$secureStringPath' for job '$JobName'. Ensure the file was created correctly and is accessible by the current user. Error: $($_.Exception.Message)" -Level ERROR
                    throw "Failed to process SecureStringFile for job '$JobName': $($_.Exception.Message)" # Re-throw to halt
                }
            }
        }

        "PLAINTEXT" {
            $passwordSource = "PlainText (Insecure)"
            $plainTextPassword = Get-ConfigValue -ConfigObject $JobConfigForPassword -Key 'ArchivePasswordPlainText' -DefaultValue $null

            if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
                & $LocalWriteLog -Message "FATAL: 'ArchivePasswordMethod' is 'PlainText' but 'ArchivePasswordPlainText' is empty or not defined in the configuration for job '$JobName'." -Level ERROR
                throw "ArchivePasswordPlainText not configured or is empty for PlainText method in job '$JobName'."
            }
            # This method is inherently insecure.
            & $LocalWriteLog -Message "[SECURITY WARNING] Using PLAIN TEXT password from configuration for job '$JobName'. This is INSECURE and NOT RECOMMENDED for production environments." -Level WARNING
            if ($IsSimulateMode.IsPresent) {
                 & $LocalWriteLog -Message "SIMULATE: Would use plain text password directly from configuration for job '$JobName'." -Level SIMULATE
                 # In simulation, we don't need to assign the actual plain text password again, as it's already in $plainTextPassword.
            }
        }

        "NONE" { # Explicitly configured as "None" or defaulted to it (and UsePassword was not $true)
            $passwordSource = "None (Explicitly Configured or Defaulted)"
            & $LocalWriteLog -Message "  - No archive password will be used for job '$JobName' as per configuration (Method: None)." -Level DEBUG
            # $plainTextPassword remains $null
        }

        Default { # Should only be hit if $effectivePasswordMethod was somehow an unknown value not caught by initial checks
            & $LocalWriteLog -Message "FATAL: Invalid or unrecognised 'ArchivePasswordMethod' ('$($passwordMethodFromConfig)') specified for job '$JobName'. Supported methods: None, Interactive, SecretManagement, SecureStringFile, PlainText." -Level ERROR
            throw "Invalid ArchivePasswordMethod ('$passwordMethodFromConfig') specified for job '$JobName'."
        }
    }

    # Return the plain text password (which will be null if no password method was used or if simulation didn't set one)
    # and the source from which it was (or would have been) obtained.
    return @{ PlainTextPassword = $plainTextPassword; PasswordSource = $passwordSource }
}

Export-ModuleMember -Function Get-PoShBackupArchivePassword
#endregion
