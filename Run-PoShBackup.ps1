# Run-PoShBackup.ps1 - Wrapper script to unlock the vault and run a backup set.
# Don't use this if you're not working with a secrets vault that may be locked.

# --- Configuration ---
$PoShBackupScriptPath = "C:\Scripts\PoSh-Backup\PoSh-Backup.ps1"
$VaultCredentialPath  = "C:\Scripts\PoSh-Backup\vault_credential.xml"
$BackupSetToRun       = "Daily_Critical_Backups" # The name of the job or set you want to run

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
    $errorMessage = "FATAL ERROR in wrapper script (Run-PoShBackup.ps1): $($_.Exception.Message)"
    Write-Error $errorMessage
    exit 1 # Exit with an error code
}
finally {
    # Re-lock the vault when the script is done for security
    Write-Host "Locking SecretStore vault."
    Lock-SecretStore
}

exit 0
