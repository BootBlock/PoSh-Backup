# Modules\ScriptModeHandler.psm1
<#
.SYNOPSIS
    Handles informational script modes for PoSh-Backup, such as listing backup locations,
    listing backup sets, testing the configuration, checking for updates, displaying the version,
    or managing backup archive pins, or listing archive contents.
.DESCRIPTION
    This module provides a function, Invoke-PoShBackupScriptMode, which checks if PoSh-Backup
    was invoked with parameters like -ListBackupLocations, -TestConfig, -Version, -PinBackup,
    -UnpinBackup, or -ListArchiveContents.
    If one of these modes is active, this module takes over, performs the requested action
    (e.g., printing a list, testing config, pinning an archive, listing archive contents),
    and then exits the script.
    This keeps the main PoSh-Backup.ps1 script cleaner by offloading this mode-specific logic.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.1 # Added explicit import for 7ZipManager.
    DateCreated:    24-May-2025
    LastModified:   06-Jun-2025
    Purpose:        To handle informational script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function passed via the -Logger parameter.
                    Requires PinManager.psm1, PasswordManager.psm1, and 7ZipManager.psm1 for specific modes.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\PinManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\7ZipManager.psm1") -Force -ErrorAction Stop
}
catch {
    # Don't throw here, as these are only needed for specific modes.
    # The check within the mode logic will handle the missing functions.
    Write-Warning "ScriptModeHandler.psm1: Could not import a manager module. Specific modes may be unavailable. Error: $($_.Exception.Message)"
}
#endregion

#region --- Exported Function: Invoke-PoShBackupScriptMode ---
function Invoke-PoShBackupScriptMode {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Checks for and handles informational script modes.
    .DESCRIPTION
        If one of the specified informational CLI switches is present, this function executes
        the corresponding logic and then exits the script. If no such mode is active, it returns
        a value indicating that the main script should continue.
    .PARAMETER ListArchiveContentsPath
        The path provided to the -ListArchiveContents parameter.
    .PARAMETER ArchivePasswordSecretName
        The secret name for the archive's password, for use with -ListArchiveContents.
    #... (other params) ...
    #>
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitch,

        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitch,

        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,

        [Parameter(Mandatory = $true)]
        [bool]$CheckForUpdateSwitch,

        [Parameter(Mandatory = $true)]
        [bool]$VersionSwitch,

        [Parameter(Mandatory = $false)]
        [string]$PinBackupPath,

        [Parameter(Mandatory = $false)]
        [string]$UnpinBackupPath,

        [Parameter(Mandatory = $false)]
        [string]$ListArchiveContentsPath,

        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordSecretName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $false)] # Only needed if CheckForUpdateSwitch or VersionSwitch is true
        [string]$PSScriptRootForUpdateCheck,

        [Parameter(Mandatory = $false)] # Only needed if CheckForUpdateSwitch is true
        [System.Management.Automation.PSCmdlet]$PSCmdletForUpdateCheck
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "ScriptModeHandler/Invoke-PoShBackupScriptMode: Initializing." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ListArchiveContentsPath)) {
        & $LocalWriteLog -Message "`n--- List Archive Contents Mode ---" -Level "HEADING"
        if (-not (Get-Command Get-7ZipArchiveListing -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "FATAL: Could not find the Get-7ZipArchiveListing command. Ensure 'Modules\Managers\7ZipManager.psm1' and its sub-modules are present and loaded correctly." -Level "ERROR"
            exit 15
        }

        $plainTextPasswordForList = $null
        if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
            if (-not (Get-Command Get-PoShBackupArchivePassword -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "FATAL: Could not find Get-PoShBackupArchivePassword command. Cannot retrieve password for encrypted archive." -Level "ERROR"
                exit 15
            }
            $passwordConfig = @{
                ArchivePasswordMethod     = 'SecretManagement'
                ArchivePasswordSecretName = $ArchivePasswordSecretName
            }
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
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($PinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Pin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Add-PoShBackupPin -ErrorAction SilentlyContinue) {
            Add-PoShBackupPin -Path $PinBackupPath -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Add-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($UnpinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Unpin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Remove-PoShBackupPin -ErrorAction SilentlyContinue) {
            Remove-PoShBackupPin -Path $UnpinBackupPath -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Remove-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        exit 0
    }

    if ($VersionSwitch) {
        $mainScriptPathForVersion = Join-Path -Path $PSScriptRootForUpdateCheck -ChildPath "PoSh-Backup.ps1"
        $scriptVersion = "N/A"
        if (Test-Path -LiteralPath $mainScriptPathForVersion -PathType Leaf) {
            $mainScriptContent = Get-Content -LiteralPath $mainScriptPathForVersion -Raw -ErrorAction SilentlyContinue
            $regexMatch = [regex]::Match($mainScriptContent, '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+){0,2}(?:\.[0-9]+)?)\b')
            if ($regexMatch.Success) {
                $scriptVersion = $regexMatch.Groups[1].Value.Trim()
            }
        }
        Write-Host "PoSh-Backup Version: $scriptVersion"
        exit 0
    }

    if ($CheckForUpdateSwitch) {
        & $LocalWriteLog -Message "`n--- Checking for PoSh-Backup Updates ---" -Level "HEADING"
        $updateModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Utilities\Update.psm1" # Relative to ScriptModeHandler.psm1

        if (-not (Test-Path -LiteralPath $updateModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[ERROR] ScriptModeHandler: Update module (Update.psm1) not found at '$updateModulePath'. Cannot check for updates." -Level "ERROR"
            exit 50 # Specific exit code for missing update module
        }
        try {
            Import-Module -Name $updateModulePath -Force -ErrorAction Stop
            # Invoke-PoShBackupUpdateCheckAndApply is now available
            $updateCheckParams = @{
                Logger                 = $Logger
                PSScriptRootForPaths   = $PSScriptRootForUpdateCheck
                PSCmdletInstance       = $PSCmdletForUpdateCheck
            }
            Invoke-PoShBackupUpdateCheckAndApply @updateCheckParams
        }
        catch {
            & $LocalWriteLog -Message "[ERROR] ScriptModeHandler: Failed to load or execute the Update module. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message "  Please ensure 'Modules\Utilities\Update.psm1' exists and is valid." -Level "ERROR"
        }
        & $LocalWriteLog -Message "`n--- Update Check Finished ---" -Level "HEADING"
        exit 0 # Exit after checking for updates
    }

    if ($ListBackupLocationsSwitch) {
        & $LocalWriteLog -Message "`n--- Defined Backup Locations (Jobs) from '$($ActualConfigFile)' ---" -Level "HEADING"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "    (Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
                & $LocalWriteLog -Message ("`n  Job Name      : " + $_.Name) -Level "NONE"
                $sourcePaths = if ($_.Value.Path -is [array]) { ($_.Value.Path | ForEach-Object { "                  `"$_`"" }) -join [Environment]::NewLine } else { "                  `"$($_.Value.Path)`"" }
                & $LocalWriteLog -Message ("  Source Path(s):`n" + $sourcePaths) -Level "NONE"
                $archiveNameDisplay = if ($_.Value.ContainsKey('Name')) { $_.Value.Name } else { 'N/A (Uses Job Name)' }
                & $LocalWriteLog -Message ("  Archive Name  : " + $archiveNameDisplay) -Level "NONE"
                $destDirDisplay = if ($_.Value.ContainsKey('DestinationDir')) { $_.Value.DestinationDir } elseif ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }
                & $LocalWriteLog -Message ("  Destination   : " + $destDirDisplay) -Level "NONE"
                if ($_.Value.ContainsKey('TargetNames') -and $_.Value.TargetNames -is [array] -and $_.Value.TargetNames.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Remote Targets: " + ($_.Value.TargetNames -join ", ")) -Level "NONE"
                }
            }
        } else {
            & $LocalWriteLog -Message "No Backup Locations are defined in the configuration." -Level "WARNING"
        }
        & $LocalWriteLog -Message "`n--- Listing Complete ---" -Level "HEADING"
        exit 0 # Exit after listing
    }

    if ($ListBackupSetsSwitch) {
        & $LocalWriteLog -Message "`n--- Defined Backup Sets from '$($ActualConfigFile)' ---" -Level "HEADING"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "    (Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
                & $LocalWriteLog -Message ("`n  Set Name     : " + $_.Name) -Level "NONE"
                $jobsInSet = if ($_.Value.JobNames -is [array]) { ($_.Value.JobNames | ForEach-Object { "                 $_" }) -join [Environment]::NewLine } else { "                 None listed" }
                & $LocalWriteLog -Message ("  Jobs in Set  :`n" + $jobsInSet) -Level "NONE"
                $onErrorDisplay = if ($_.Value.ContainsKey('OnErrorInJob')) { $_.Value.OnErrorInJob } else { 'StopSet' }
                & $LocalWriteLog -Message ("  On Error     : " + $onErrorDisplay) -Level "NONE"
            }
        } else {
            & $LocalWriteLog -Message "No Backup Sets are defined in the configuration." -Level "WARNING"
        }
        & $LocalWriteLog -Message "`n--- Listing Complete ---" -Level "HEADING"
        exit 0 # Exit after listing
    }

    if ($TestConfigSwitch) {
        & $LocalWriteLog -Message "`n[INFO] --- Configuration Test Mode Summary ---" -Level "CONFIG_TEST"
        & $LocalWriteLog -Message "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -Level "CONFIG_TEST"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "          (User overrides from '$($ConfigLoadResult.UserConfigPath)' were applied)" -Level "CONFIG_TEST"
        }
        & $LocalWriteLog -Message "`n  --- Key Global Settings ---" -Level "CONFIG_TEST"
        $sevenZipPathDisplay = if($Configuration.ContainsKey('SevenZipPath')){ $Configuration.SevenZipPath } else { 'N/A' }
        & $LocalWriteLog -Message ("    7-Zip Path              : {0}" -f $sevenZipPathDisplay) -Level "CONFIG_TEST"
        $defaultDestDirDisplay = if($Configuration.ContainsKey('DefaultDestinationDir')){ $Configuration.DefaultDestinationDir } else { 'N/A' }
        & $LocalWriteLog -Message ("    Default Staging Dir     : {0}" -f $defaultDestDirDisplay) -Level "CONFIG_TEST"
        $delLocalArchiveDisplay = if($Configuration.ContainsKey('DeleteLocalArchiveAfterSuccessfulTransfer')){ $Configuration.DeleteLocalArchiveAfterSuccessfulTransfer } else { '$true (default)' }
        & $LocalWriteLog -Message ("    Del. Local Post Transfer: {0}" -f $delLocalArchiveDisplay) -Level "CONFIG_TEST"
        $logDirDisplay = if($Configuration.ContainsKey('LogDirectory')){ $Configuration.LogDirectory } else { 'N/A (File Logging Disabled)' }
        & $LocalWriteLog -Message ("    Log Directory           : {0}" -f $logDirDisplay) -Level "CONFIG_TEST"
        $htmlReportDirDisplay = if($Configuration.ContainsKey('HtmlReportDirectory')){ $Configuration.HtmlReportDirectory } else { 'N/A' }
        & $LocalWriteLog -Message ("    Default Report Dir (HTML): {0}" -f $htmlReportDirDisplay) -Level "CONFIG_TEST"
        $vssEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableVSS')){ $Configuration.EnableVSS } else { $false }
        & $LocalWriteLog -Message ("    Default VSS Enabled     : {0}" -f $vssEnabledDisplayGlobal) -Level "CONFIG_TEST"
        $retriesEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableRetries')){ $Configuration.EnableRetries } else { $false }
        & $LocalWriteLog -Message ("    Default Retries Enabled : {0}" -f $retriesEnabledDisplayGlobal) -Level "CONFIG_TEST"
        $treatWarningsAsSuccessDisplayGlobal = if($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')){ $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }
        & $LocalWriteLog -Message ("    Treat 7-Zip Warns as OK : {0}" -f $treatWarningsAsSuccessDisplayGlobal) -Level "CONFIG_TEST"
        $pauseExitDisplayGlobal = if($Configuration.ContainsKey('PauseBeforeExit')){ $Configuration.PauseBeforeExit } else { 'OnFailureOrWarning' }
        & $LocalWriteLog -Message ("    Pause Before Exit       : {0}" -f $pauseExitDisplayGlobal) -Level "CONFIG_TEST"

        if ($Configuration.ContainsKey('BackupTargets') -and $Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Targets ---" -Level "CONFIG_TEST"
            foreach ($targetNameKey in ($Configuration.BackupTargets.Keys | Sort-Object)) {
                $targetConf = $Configuration.BackupTargets[$targetNameKey]
                & $LocalWriteLog -Message ("    Target: {0} (Type: {1})" -f $targetNameKey, $targetConf.Type) -Level "CONFIG_TEST"
                if ($targetConf.TargetSpecificSettings) {
                    $targetConf.TargetSpecificSettings.GetEnumerator() | ForEach-Object {
                        & $LocalWriteLog -Message ("      -> {0} : {1}" -f $_.Name, $_.Value) -Level "CONFIG_TEST"
                    }
                }
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Targets ---`n    (None defined)" -Level "CONFIG_TEST" }

        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
            foreach ($jobNameKey in ($Configuration.BackupLocations.Keys | Sort-Object)) {
                $jobConf = $Configuration.BackupLocations[$jobNameKey]
                & $LocalWriteLog -Message ("    Job: {0}" -f $jobNameKey) -Level "CONFIG_TEST"
                $sourcePathsDisplay = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }; & $LocalWriteLog -Message ("      Source(s)    : {0}" -f $sourcePathsDisplay) -Level "CONFIG_TEST"
                $destDirDisplayJob = if ($jobConf.ContainsKey('DestinationDir')) { $jobConf.DestinationDir } elseif ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }; & $LocalWriteLog -Message ("      Staging Dir  : {0}" -f $destDirDisplayJob) -Level "CONFIG_TEST"
                if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array] -and $jobConf.TargetNames.Count -gt 0) { & $LocalWriteLog -Message ("      Remote Targets: {0}" -f ($jobConf.TargetNames -join ", ")) -Level "CONFIG_TEST" }
                $archiveNameDisplayJob = if ($jobConf.ContainsKey('Name')) { $jobConf.Name } else { 'N/A (Uses Job Name)' }; & $LocalWriteLog -Message ("      Archive Name : {0}" -f $archiveNameDisplayJob) -Level "CONFIG_TEST"
                $vssEnabledDisplayJob = if ($jobConf.ContainsKey('EnableVSS')) { $jobConf.EnableVSS } elseif ($Configuration.ContainsKey('EnableVSS')) { $Configuration.EnableVSS } else { $false }; & $LocalWriteLog -Message ("      VSS Enabled  : {0}" -f $vssEnabledDisplayJob) -Level "CONFIG_TEST"
                $treatWarnDisplayJob = if ($jobConf.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $jobConf.TreatSevenZipWarningsAsSuccess } elseif ($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }; & $LocalWriteLog -Message ("      Treat Warn OK: {0}" -f $treatWarnDisplayJob) -Level "CONFIG_TEST"
                $retentionDisplayJob = if ($jobConf.ContainsKey('LocalRetentionCount')) { $jobConf.LocalRetentionCount } else { 'N/A' }; & $LocalWriteLog -Message ("      LocalRetain  : {0}" -f $retentionDisplayJob) -Level "CONFIG_TEST"
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Locations (Jobs) ---`n    No Backup Locations defined." -Level "CONFIG_TEST" }

        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
            foreach ($setNameKey in ($Configuration.BackupSets.Keys | Sort-Object)) {
                $setConf = $Configuration.BackupSets[$setNameKey]
                & $LocalWriteLog -Message ("    Set: {0}" -f $setNameKey) -Level "CONFIG_TEST"
                $jobsInSetDisplay = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }; & $LocalWriteLog -Message ("      Jobs in Set  : {0}" -f $jobsInSetDisplay) -Level "CONFIG_TEST"
                $onErrorDisplaySet = if ($setConf.ContainsKey('OnErrorInJob')) { $setConf.OnErrorInJob } else { 'StopSet' }; & $LocalWriteLog -Message ("      On Error     : {0}" -f $onErrorDisplaySet) -Level "CONFIG_TEST"
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Sets ---`n    No Backup Sets defined." -Level "CONFIG_TEST" }
        & $LocalWriteLog -Message "`n[INFO] --- Configuration Test Mode Finished ---" -Level "CONFIG_TEST"
        exit 0 # Exit after testing config
    }

    return $false # No informational mode was handled, main script should continue
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupScriptMode
