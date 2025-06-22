# UnlockVaultAndRun-PoShBackup.ps1 - Wrapper script to unlock the vault and run a backup set.
#
# If you're not sure what this is or you don't need the functionality to automatically unlock
# a vault prior to a back up job/set that requires vault access, please use PoSh-Backup.ps1 instead.

# --- Configuration ---
# The backup set or job you want to run
$BackupSetToRun = "Daily_Critical_Backups"

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

    # Define the parameters to pass to PoSh-Backup.ps1
    $poShBackupParams = @{
        RunSet = $BackupSetToRun
        Quiet  = $true # Recommended for scheduled tasks
        ErrorAction = 'Stop'
    }

    # Execute the main PoSh-Backup script
    Write-Host "Executing PoSh-Backup for set: $BackupSetToRun..."
    & $PoShBackupScriptPath @poShBackupParams

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
