# Modules\Managers\CoreSetupManager\DependencyChecker.psm1
<#
.SYNOPSIS
    Handles the context-aware validation of required external PowerShell modules.
.DESCRIPTION
    This sub-module of CoreSetupManager provides a function to check for external
    dependencies (like Posh-SSH or AWS.Tools.S3) only if they are actively required
    by the specific jobs scheduled for the current run. This prevents the script from
    halting due to a missing module if the feature requiring it is not being used.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    17-Jun-2025
    LastModified:   17-Jun-2025
    Purpose:        To centralise the conditional dependency check.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupDependencyCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$JobsToRun
    )

    & $Logger -Message "CoreSetupManager/DependencyChecker/Invoke-PoShBackupDependencyCheck: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "CoreSetupManager/DependencyChecker: Checking for required external PowerShell modules based on jobs to be run..." -Level "DEBUG"

    # Define modules and the condition under which they are required.
    $requiredModules = @(
        @{
            ModuleName  = 'Posh-SSH'
            RequiredFor = 'SFTP Target Provider'
            InstallHint = 'Install-Module Posh-SSH -Scope CurrentUser'
            Condition   = {
                param($Config, $ActiveJobs)
                # This module is only required if a job that is *actually going to run* uses an SFTP target.
                if ($Config.ContainsKey('BackupTargets') -and $Config.BackupTargets -is [hashtable]) {
                    foreach ($jobName in $ActiveJobs) {
                        $jobConf = $Config.BackupLocations[$jobName]
                        if ($jobConf -and $jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                            foreach ($targetName in $jobConf.TargetNames) {
                                if ($Config.BackupTargets.ContainsKey($targetName)) {
                                    $targetDef = $Config.BackupTargets[$targetName]
                                    if ($targetDef -is [hashtable] -and $targetDef.Type -eq 'SFTP') {
                                        return $true # Condition met, check is required.
                                    }
                                }
                            }
                        }
                    }
                }
                return $false # Condition not met, skip check.
            }
        },
        @{
            ModuleName  = 'Microsoft.PowerShell.SecretManagement'
            RequiredFor = 'Archive Passwords or Target/Email Credentials from a vault'
            InstallHint = 'Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser'
            Condition   = {
                param($Config, $ActiveJobs)
                if ($null -eq $ActiveJobs -or $ActiveJobs.Count -eq 0) { return $false }

                # Define all known keys that hold secret names within TargetSpecificSettings or top-level of target
                $targetSecretKeys = @(
                    'CredentialsSecretName', # WebDAV (top-level), UNC (optional top-level)
                    'SFTPPasswordSecretName', # SFTP (in TargetSpecificSettings)
                    'SFTPKeyFileSecretName', # SFTP (in TargetSpecificSettings)
                    'SFTPKeyFilePassphraseSecretName', # SFTP (in TargetSpecificSettings)
                    'AccessKeySecretName', # S3 (in TargetSpecificSettings)
                    'SecretKeySecretName'              # S3 (in TargetSpecificSettings)
                )

                foreach ($jobName in $ActiveJobs) {
                    if (-not $Config.BackupLocations.ContainsKey($jobName)) { continue }
                    $jobConf = $Config.BackupLocations[$jobName]

                    # Condition 1: Job's archive password method is SecretManagement.
                    if ($jobConf.ArchivePasswordMethod -eq 'SecretManagement') { return $true }

                    # Condition 2: Job uses a target that uses any known secret key.
                    if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                        foreach ($targetName in $jobConf.TargetNames) {
                            if ($Config.BackupTargets.ContainsKey($targetName)) {
                                $targetDef = $Config.BackupTargets[$targetName]
                                if ($targetDef -isnot [hashtable]) { continue }
                                
                                # Check for top-level secret keys
                                if ($targetDef.ContainsKey('CredentialsSecretName') -and (-not [string]::IsNullOrWhiteSpace($targetDef.CredentialsSecretName))) { return $true }

                                # Check inside TargetSpecificSettings
                                if ($targetDef.ContainsKey('TargetSpecificSettings') -and $targetDef.TargetSpecificSettings -is [hashtable]) {
                                    $specificSettings = $targetDef.TargetSpecificSettings
                                    foreach ($secretKey in $targetSecretKeys) {
                                        if ($specificSettings.ContainsKey($secretKey) -and (-not [string]::IsNullOrWhiteSpace($specificSettings[$secretKey]))) {
                                            return $true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    # Condition 3: Job uses a notification profile that has a secret defined.
                    $notificationSettings = $jobConf.NotificationSettings
                    if ($notificationSettings -is [hashtable] -and $notificationSettings.Enabled -eq $true -and -not [string]::IsNullOrWhiteSpace($notificationSettings.ProfileName)) {
                        $profileName = $notificationSettings.ProfileName
                        if ($Config.NotificationProfiles.ContainsKey($profileName)) {
                            $notificationProfile = $Config.NotificationProfiles[$profileName]
                            if ($notificationProfile -is [hashtable] -and $notificationProfile.ProviderSettings -is [hashtable]) {
                                if ($notificationProfile.ProviderSettings.ContainsKey('CredentialSecretName') -and (-not [string]::IsNullOrWhiteSpace($notificationProfile.ProviderSettings.CredentialSecretName))) { return $true }
                                if ($notificationProfile.ProviderSettings.ContainsKey('WebhookUrlSecretName') -and (-not [string]::IsNullOrWhiteSpace($notificationProfile.ProviderSettings.WebhookUrlSecretName))) { return $true }
                            }
                        }
                    }
                }
                return $false # No active job triggered the condition.
            }
        },
        @{
            ModuleName  = 'AWS.Tools.S3'
            RequiredFor = 'S3-Compatible Target Provider'
            InstallHint = 'Install-Module AWS.Tools.S3 -Scope CurrentUser'
            Condition   = {
                param($Config, $ActiveJobs)
                # This module is only required if a job that is *actually going to run* uses an S3 target.
                if ($Config.ContainsKey('BackupTargets') -and $Config.BackupTargets -is [hashtable]) {
                    foreach ($jobName in $ActiveJobs) {
                        $jobConf = $Config.BackupLocations[$jobName]
                        if ($jobConf -and $jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array]) {
                            foreach ($targetName in $jobConf.TargetNames) {
                                if ($Config.BackupTargets.ContainsKey($targetName)) {
                                    $targetDef = $Config.BackupTargets[$targetName]
                                    if ($targetDef -is [hashtable] -and $targetDef.Type -eq 'S3') {
                                        return $true # Condition met, check is required.
                                    }
                                }
                            }
                        }
                    }
                }
                return $false # Condition not met, skip check.
            }
        }
    )

    $missingModules = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleInfo in $requiredModules) {
        if (& $moduleInfo.Condition -Config $Configuration -ActiveJobs $JobsToRun) {
            $moduleName = $moduleInfo.ModuleName
            & $LocalWriteLog -Message "  - Condition met for '$($moduleInfo.RequiredFor)'. Checking for module: '$moduleName'." -Level "DEBUG"

            if (-not (Get-Module -Name $moduleName -ListAvailable)) {
                $errorMessage = "Required PowerShell module '$moduleName' is not installed. This module is necessary for the '$($moduleInfo.RequiredFor)' functionality. Please install it by running: $($moduleInfo.InstallHint)"
                $missingModules.Add($errorMessage)
            }
        }
    }

    if ($missingModules.Count -gt 0) {
        $fullErrorMessage = "FATAL: One or more required PowerShell modules are missing for the configured features. Please install them to ensure full functionality.`n"
        $fullErrorMessage += ($missingModules -join "`n")
        throw $fullErrorMessage
    }

    & $LocalWriteLog -Message "CoreSetupManager/DependencyChecker: All conditionally required external modules found." -Level "SUCCESS"
}

Export-ModuleMember -Function Invoke-PoShBackupDependencyCheck
