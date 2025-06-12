# Modules\Operations\JobPreProcessor.psm1
<#
.SYNOPSIS
    Handles pre-processing steps for a PoSh-Backup job before local archive creation.
.DESCRIPTION
    This module encapsulates operations that must occur before the main archiving
    process begins for a PoSh-Backup job. This includes:
    - Orchestrating infrastructure-level snapshots (e.g., Hyper-V) via the SnapshotManager
      if the job is configured for it. This is the primary method for backing up resources like VMs.
      It can back up an entire VM or specific sub-paths from within the VM's snapshot.
    - Performing early accessibility checks for configured source and destination paths.
    - Validating and, if necessary, creating the local destination (staging) directory.
    - Retrieving the archive password based on the job's configuration (delegates
      to PasswordManager.psm1).
    - Executing any user-defined pre-backup hook scripts (delegates to HookManager.psm1).
    - Managing the creation of Volume Shadow Copies (VSS) if enabled for the job and if
      an infrastructure snapshot provider is not being used.

    The main exported function, Invoke-PoShBackupJobPreProcessing, returns critical
    information needed for the subsequent archiving phase, such as the resolved source
    paths (which might be VSS paths or paths to a mounted snapshot) and the actual plain
    text password if retrieved.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.5 # Renamed snapshot path function call to singular form.
    DateCreated:    27-May-2025
    LastModified:   12-Jun-2025
    Purpose:        To modularise pre-archive creation logic from the main Operations module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 and various Manager modules (Password, Hook, VSS, Snapshot).
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\HookManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\VssManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\SnapshotManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobPreProcessor.psm1 FATAL: Could not import required dependent modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function ---
function Invoke-PoShBackupJobPreProcessing {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobPreProcessor/Invoke-PoShBackupJobPreProcessing: Initializing for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $currentJobSourcePathFor7Zip = $EffectiveJobConfig.OriginalSourcePath
    $VSSPathsInUse = $null
    $snapshotSession = $null # NEW: To hold the session object from the snapshot manager
    $plainTextPasswordForJob = $null
    $preProcessingErrorMessage = $null # To store a specific error message

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        #region --- Early UNC Path Accessibility Checks ---
        & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: Performing early accessibility checks for configured paths..." -Level INFO
        $sourcePathsToCheck = @()
        if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
            $sourcePathsToCheck = $EffectiveJobConfig.OriginalSourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.OriginalSourcePath)) {
            $sourcePathsToCheck = @($EffectiveJobConfig.OriginalSourcePath)
        }
        # If using a snapshot provider for a VM, the source path is a VM name, not a file path to check.
        if ($EffectiveJobConfig.SourceIsVMName -ne $true) {
            foreach ($individualSourcePath in $sourcePathsToCheck) {
                if ($individualSourcePath -match '^\\\\') {
                    $uncPathToTestForSource = $individualSourcePath
                    if ($individualSourcePath -match '[\*\?\[]') { $uncPathToTestForSource = Split-Path -LiteralPath $individualSourcePath -Parent }
                    if ([string]::IsNullOrWhiteSpace($uncPathToTestForSource) -or ($uncPathToTestForSource -match '^\\\\([^\\]+)$')) {
                        & $LocalWriteLog -Message "[WARNING] JobPreProcessor: Could not determine a valid UNC base directory to test accessibility for source path '$individualSourcePath'. Check skipped." -Level WARNING
                    }
                    else {
                        if (-not $IsSimulateMode.IsPresent) {
                            if (-not (Test-Path -LiteralPath $uncPathToTestForSource)) {
                                $preProcessingErrorMessage = "UNC source path '$individualSourcePath' (base '$uncPathToTestForSource') is inaccessible. Job '$JobName' cannot proceed."
                                throw $preProcessingErrorMessage # Throw to be caught by this function's catch block
                            }
                            else { & $LocalWriteLog -Message "  - JobPreProcessor: UNC source path '$individualSourcePath' (tested base: '$uncPathToTestForSource') accessibility: PASSED." -Level DEBUG }
                        }
                        else { & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would test accessibility of UNC source path '$individualSourcePath' (base '$uncPathToTestForSource')." -Level SIMULATE }
                    }
                }
            }
        }
        if ($EffectiveJobConfig.DestinationDir -match '^\\\\') {
            $uncDestinationBasePathToTest = $null
            if ($EffectiveJobConfig.DestinationDir -match '^(\\\\\\[^\\]+\\[^\\]+)') { $uncDestinationBasePathToTest = $matches[1] }
            if (-not [string]::IsNullOrWhiteSpace($uncDestinationBasePathToTest)) {
                if (-not $IsSimulateMode.IsPresent) {
                    if (-not (Test-Path -LiteralPath $uncDestinationBasePathToTest)) {
                        $preProcessingErrorMessage = "Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' (from '$($EffectiveJobConfig.DestinationDir)') is inaccessible. Job '$JobName' cannot proceed."
                        throw $preProcessingErrorMessage
                    }
                    else { & $LocalWriteLog -Message "  - JobPreProcessor: Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' accessibility: PASSED." -Level DEBUG }
                }
                else { & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would test accessibility of base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest'." -Level SIMULATE }
            }
            else { & $LocalWriteLog -Message "[WARNING] JobPreProcessor: Could not determine base UNC share for ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Full path creation attempted later." -Level WARNING }
        }
        & $LocalWriteLog -Message "[INFO] JobPreProcessor: Early accessibility checks completed." -Level INFO
        #endregion

        if ([string]::IsNullOrWhiteSpace($EffectiveJobConfig.DestinationDir)) {
            $preProcessingErrorMessage = "${destinationDirTerm} for job '$JobName' is not defined. Cannot proceed."
            throw $preProcessingErrorMessage
        }
        if (-not (Test-Path -LiteralPath $EffectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] JobPreProcessor: ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($EffectiveJobConfig.DestinationDir, "Create ${destinationDirTerm}")) {
                    try { New-Item -Path $EffectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - ${destinationDirTerm} created successfully." -Level SUCCESS }
                    catch {
                        $preProcessingErrorMessage = "Failed to create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)"
                        throw $preProcessingErrorMessage
                    }
                }
                else {
                    $preProcessingErrorMessage = "${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' creation skipped by user."
                    & $LocalWriteLog -Message "[WARNING] JobPreProcessor: $preProcessingErrorMessage" -Level WARNING
                    return @{ Success = $false; ErrorMessage = $preProcessingErrorMessage; VSSPathsInUse = $null; SnapshotSession = $null; PlainTextPasswordToClear = $null; ActualPlainTextPassword = $plainTextPasswordForJob; CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip }
                }
            }
            else {
                & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        $isPasswordRequiredOrConfigured = ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $EffectiveJobConfig.UsePassword
        $EffectiveJobConfig.PasswordInUseFor7Zip = $false
        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordParams = @{
                    JobConfigForPassword = $EffectiveJobConfig; JobName = $JobName
                    IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
                }
                if ((Get-Command Get-PoShBackupArchivePassword).Parameters.ContainsKey('PSCmdlet')) {
                    $passwordParams.PSCmdlet = $PSCmdlet
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams
                $reportData.PasswordSource = $passwordResult.PasswordSource

                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword
                    $EffectiveJobConfig.PasswordInUseFor7Zip = $true
                }
                elseif ($isPasswordRequiredOrConfigured -and $EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                    $preProcessingErrorMessage = "Password was required for job '$JobName' via method '$($EffectiveJobConfig.ArchivePasswordMethod)' but was not provided or was cancelled."
                    & $LocalWriteLog -Message "[ERROR] JobPreProcessor: $preProcessingErrorMessage" -Level ERROR
                    $reportData.ErrorMessage = $preProcessingErrorMessage
                    return @{ Success = $false; ErrorMessage = $preProcessingErrorMessage; VSSPathsInUse = $null; SnapshotSession = $null; PlainTextPasswordToClear = $null; ActualPlainTextPassword = $plainTextPasswordForJob; CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip }
                }
            }
            catch {
                $preProcessingErrorMessage = "Error during password retrieval process for job '$JobName'. Error: $($_.Exception.Message)"
                throw $preProcessingErrorMessage
            }
        }
        elseif ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"; $EffectiveJobConfig.PasswordInUseFor7Zip = $false
        }

        Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
            -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
            -IsSimulateMode:$IsSimulateMode -Logger $Logger

        if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SnapshotProviderName)) {
            & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: Infrastructure Snapshot Provider '($($EffectiveJobConfig.SnapshotProviderName))' is configured for job '$JobName'." -Level "INFO"
            if ($EffectiveJobConfig.SourceIsVMName -ne $true) {
                throw "Job '$JobName' has a SnapshotProviderName defined but 'SourceIsVMName' is not `$true. This configuration is currently unsupported."
            }
            $snapshotProviderConfig = $GlobalConfig.SnapshotProviders[$EffectiveJobConfig.SnapshotProviderName]
            if ($null -eq $snapshotProviderConfig) {
                throw "Snapshot provider '$($EffectiveJobConfig.SnapshotProviderName)' (for job '$JobName') is not defined in the global 'SnapshotProviders' section."
            }

            $vmName = $null
            $subPaths = [System.Collections.Generic.List[string]]::new()
            if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
                $vmName = $EffectiveJobConfig.OriginalSourcePath[0]
                if ($EffectiveJobConfig.OriginalSourcePath.Count -gt 1) {
                    $EffectiveJobConfig.OriginalSourcePath | Select-Object -Skip 1 | ForEach-Object { $subPaths.Add($_) }
                }
            } else {
                $vmName = $EffectiveJobConfig.OriginalSourcePath
            }

            $snapshotParams = @{
                JobName                 = $JobName
                SnapshotProviderConfig  = $snapshotProviderConfig
                ResourceToSnapshot      = $vmName
                IsSimulateMode          = $IsSimulateMode.IsPresent
                Logger                  = $Logger
                PSCmdlet                = $PSCmdlet
                PSScriptRootForPaths    = $EffectiveJobConfig.GlobalConfigRef['_PoShBackup_PSScriptRoot']
            }
            $snapshotSession = New-PoShBackupSnapshot @snapshotParams
            if ($null -ne $snapshotSession -and $snapshotSession.Success) {
                $getPathsParams = @{ SnapshotSession = $snapshotSession; Logger = $Logger }
                $mountedPaths = Get-PoShBackupSnapshotPath @getPathsParams
                if ($null -ne $mountedPaths -and $mountedPaths.Count -gt 0) {
                    if ($subPaths.Count -gt 0) {
                        & $LocalWriteLog -Message "  - JobPreProcessor: Translating specified sub-paths to snapshot mount points..." -Level "DEBUG"
                        $translatedPaths = [System.Collections.Generic.List[string]]::new()
                        foreach ($subPath in $subPaths) {
                            if ($subPath -match "^([a-zA-Z]):\\(.*)$") {
                                $guestRelativePath = $Matches[2]
                                $hostDriveLetter = ([string]$mountedPaths[0]).TrimEnd(":")
                                $newPath = Join-Path -Path "$($hostDriveLetter):\" -ChildPath $guestRelativePath
                                $translatedPaths.Add($newPath)
                                & $LocalWriteLog -Message "    - Translated '$subPath' -> '$newPath'" -Level "DEBUG"
                            } else {
                                & $LocalWriteLog -Message "[WARNING] JobPreProcessor: Sub-path '$subPath' is not in a recognized format (e.g., 'C:\Path\To\Folder'). It will be ignored." -Level "WARNING"
                            }
                        }
                        $currentJobSourcePathFor7Zip = $translatedPaths
                        $reportData.SnapshotStatus = "Used Successfully (Sub-Paths: $($translatedPaths -join ', '))"
                    } else {
                        $currentJobSourcePathFor7Zip = $mountedPaths
                        $reportData.SnapshotStatus = "Used Successfully (Full Disks: $($mountedPaths -join ', '))"
                    }
                } else {
                    throw "Snapshot session '$($snapshotSession.SessionId)' was created but failed to return any mount paths."
                }
            } else {
                $snapshotError = if ($null -ne $snapshotSession) { $snapshotSession.ErrorMessage } else { "SnapshotManager returned a null session object." }
                throw "Infrastructure snapshot creation failed for job '$JobName'. Reason: $snapshotError"
            }
            $reportData.SnapshotAttempted = $true
        }
        elseif ($EffectiveJobConfig.JobEnableVSS) {
            & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege -Logger $Logger)) {
                $preProcessingErrorMessage = "VSS requires Administrator privileges for job '$JobName', but script is not running as Admin."
                throw $preProcessingErrorMessage
            }
            $vssParams = @{
                SourcePathsToShadow = if ($EffectiveJobConfig.OriginalSourcePath -is [array]) { $EffectiveJobConfig.OriginalSourcePath } else { @($EffectiveJobConfig.OriginalSourcePath) }
                VSSContextOption = $EffectiveJobConfig.JobVSSContextOption; MetadataCachePath = $EffectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $EffectiveJobConfig.VSSPollingTimeoutSeconds; PollingIntervalSeconds = $EffectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
            }
            if ((Get-Command New-VSSShadowCopy).Parameters.ContainsKey('PSCmdlet')) {
                $vssParams.PSCmdlet = $PSCmdlet
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams
            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - JobPreProcessor: VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
                    $EffectiveJobConfig.OriginalSourcePath | ForEach-Object { if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } }
                }
                else { if ($VSSPathsInUse.ContainsKey($EffectiveJobConfig.OriginalSourcePath) -and $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] -ne $EffectiveJobConfig.OriginalSourcePath) { $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] } else { $EffectiveJobConfig.OriginalSourcePath } }
                $reportData.VSSShadowPaths = $VSSPathsInUse
            }
            elseif ($EffectiveJobConfig.JobEnableVSS -and ($null -eq $VSSPathsInUse)) {
                $preProcessingErrorMessage = "VSS shadow copy creation failed for job '$JobName'. Check VSSManager logs."
                & $LocalWriteLog -Message "[ERROR] JobPreProcessor: $preProcessingErrorMessage" -Level ERROR
                $reportData.VSSStatus = "Failed (Creation Error)"
            }
        }

        if ($EffectiveJobConfig.JobEnableVSS -or (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SnapshotProviderName))) {
            $reportData.VSSAttempted = $EffectiveJobConfig.JobEnableVSS
            $reportData.SnapshotAttempted = -not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SnapshotProviderName)
            if ($reportData.SnapshotAttempted) {
                if (-not ($reportData.PSObject.Properties.Name -contains 'SnapshotStatus')) { $reportData.SnapshotStatus = if ($IsSimulateMode.IsPresent) { "Simulated" } else { "Failed or Not Used" } }
            } else {
                if ($IsSimulateMode.IsPresent) { $reportData.VSSStatus = "Simulated" }
                elseif ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                    $allLocalShadowed = $true
                    $originalLocalPaths = @($EffectiveJobConfig.OriginalSourcePath | Where-Object { $_ -notmatch '^\\\\' -and (-not [string]::IsNullOrWhiteSpace($_)) })
                    if ($originalLocalPaths.Count -gt 0) {
                        foreach ($lp in $originalLocalPaths) { if (-not ($VSSPathsInUse.ContainsKey($lp) -and $VSSPathsInUse[$lp] -ne $lp)) { $allLocalShadowed = $false; break } }
                        $reportData.VSSStatus = if ($allLocalShadowed) { "Used Successfully" } else { "Partially Used or Failed for some local paths" }
                    } else { $reportData.VSSStatus = "Not Applicable (No local paths)" }
                }
                elseif (-not ($reportData.PSObject.Properties.Name -contains 'VSSStatus')) { $reportData.VSSStatus = "Failed or Not Used (No shadow paths returned)" }
            }
        } else { $reportData.VSSAttempted = $false; $reportData.VSSStatus = "Not Enabled"; $reportData.SnapshotAttempted = $false; $reportData.SnapshotStatus = "Not Enabled"; }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) { $currentJobSourcePathFor7Zip } else { @($currentJobSourcePathFor7Zip) }


        return @{
            Success                     = $true
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
            VSSPathsInUse               = $VSSPathsInUse
            SnapshotSession             = $snapshotSession
            PlainTextPasswordToClear    = $plainTextPasswordForJob
            ActualPlainTextPassword     = $plainTextPasswordForJob
            ErrorMessage                = $null
        }

    }
    catch {
        $finalErrorMessage = if (-not [string]::IsNullOrWhiteSpace($preProcessingErrorMessage)) { $preProcessingErrorMessage } else { $_.Exception.Message }
        & $LocalWriteLog -Message "[ERROR] JobPreProcessor: Error during pre-processing for job '$JobName': $finalErrorMessage" -Level "ERROR"
        if ($_.Exception.ToString() -ne $finalErrorMessage) {
            & $LocalWriteLog -Message "  Full Exception: $($_.Exception.ToString())" -Level "DEBUG"
        }

        if ($null -ne $VSSPathsInUse) { Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode -Logger $Logger }

        if ($null -ne $snapshotSession) {
            $removeParams = @{
                SnapshotSession = $snapshotSession
                PSCmdlet        = $PSCmdlet
            }
            Remove-PoShBackupSnapshot @removeParams
        }

        return @{
            Success                     = $false
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
            VSSPathsInUse               = $null
            SnapshotSession             = $null
            PlainTextPasswordToClear    = $plainTextPasswordForJob
            ActualPlainTextPassword     = $plainTextPasswordForJob
            ErrorMessage                = $finalErrorMessage
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJobPreProcessing
