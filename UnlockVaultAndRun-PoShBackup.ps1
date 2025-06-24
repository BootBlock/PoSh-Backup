<#
.SYNOPSIS
    A wrapper script to unlock the PowerShell SecretStore vault and then run PoSh-Backup.ps1
    with any provided parameters passed through.
.DESCRIPTION
    This script is designed for automated or scheduled execution of PoSh-Backup in environments where the
    PowerShell SecretStore vault may be locked (e.g., after a period of inactivity or in a new session).

    It performs the following sequence of operations:
    1.  Imports the Microsoft.PowerShell.SecretStore module.
    2.  Imports a securely stored PSCredential object from an XML file. This credential file contains the
        password for the SecretStore vault and must be created beforehand by the user.
    3.  Unlocks the SecretStore vault for the current session.
    4.  Executes the main PoSh-Backup.ps1 script, passing along any parameters it received.
    5.  Upon completion (or failure), it securely re-locks the SecretStore vault.

    This script no longer uses hardcoded job/set names. All parameters are passed directly to PoSh-Backup.ps1.
.PARAMETER ArgumentsToPass
    All arguments provided to this script will be passed directly to PoSh-Backup.ps1.
    For example, -RunSet, -BackupLocationName, -Quiet, -Simulate, etc.
.EXAMPLE
    # Run the "DailyCritical" backup set in quiet mode.
    .\UnlockVaultAndRun-PoShBackup.ps1 -RunSet "DailyCritical" -Quiet

.EXAMPLE
    # Run a single job named "MyDocs" and simulate the run.
    .\UnlockVaultAndRun-PoShBackup.ps1 -BackupLocationName "MyDocs" -Simulate

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Parameterised to pass all arguments through to PoSh-Backup.ps1.
    DateCreated:    21-Jun-2025
    LastModified:   23-Jun-2025
    Prerequisites:  - A configured Microsoft.PowerShell.SecretStore vault.
                    - A vault credential file (e.g., 'vault_credential.xml') created by the same user account
                      that will run this script, using a command like:
                      `Get-Credential | Export-CliXml -Path ".\vault_credential.xml"`
                    - The main PoSh-Backup.ps1 script and this wrapper script should be in the same directory.
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    # This parameter captures all unbound arguments and passes them to the target script.
    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$ArgumentsToPass
)

# --- Configuration ---
# Define paths relative to this wrapper script's location
$scriptDirectory = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$PoShBackupScriptPath = Join-Path -Path $scriptDirectory -ChildPath "PoSh-Backup.ps1"
$VaultCredentialPath  = Join-Path -Path $scriptDirectory -ChildPath "vault_credential.xml"

# --- Script Body ---
try {
    # Import the vault provider module
    Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop

    # Import the credential and get the vault password
    $credential = Import-CliXml -Path $VaultCredentialPath
    $vaultPassword = $credential.GetNetworkCredential().Password

    # Unlock the vault for this session
    Write-Host "Unlocking SecretStore vault for automated run..."
    Unlock-SecretStore -Password $vaultPassword

    # Execute the main PoSh-Backup script, splatting the passthrough arguments
    Write-Host "Executing PoSh-Backup with arguments: $($ArgumentsToPass -join ' ')"
    & $PoShBackupScriptPath @ArgumentsToPass

    Write-Host "PoSh-Backup execution finished."

}
catch {
    $errorMessage = "FATAL ERROR in wrapper script (UnlockVaultAndRun-PoShBackup.ps1): $($_.Exception.Message)"
    Write-Error $errorMessage
    exit 1 # Exit with an error code
}
finally {
    # Re-lock the vault when the script is done for security
    Write-Host "Locking SecretStore vault."
    Lock-SecretStore
}

exit 0
