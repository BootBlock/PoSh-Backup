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
    - Performing accessibility checks for configured source paths, with configurable behaviour
      for when a path is not found (Fail, Warn, or Skip).
    - Validating and, if necessary, creating the local destination (staging) directory.
    - Retrieving the archive password based on the job's configuration (delegates
      to PasswordManager.psm1).
    - Executing any user-defined pre-backup hook scripts (delegates to HookManager.psm1).
    - Managing the creation of Volume Shadow Copies (VSS) if enabled for the job and if
      an infrastructure snapshot provider is not being used.

    The main exported function, Invoke-PoShBackupJobPreProcessing, returns critical
    information needed for the subsequent archiving phase, such as the resolved source
    paths (which might be VSS paths or paths to a mounted snapshot), the actual plain
    text password if retrieved, and a status indicating how to proceed.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.6 # Fixed fatal error when all source paths are invalid with WarnAndContinue.
    DateCreated:    27-May-2025
    LastModified:   22-Jun-2025
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
    $snapshotSession = $null
    $plainTextPasswordForJob = $null
    $preProcessingErrorMessage = $null

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        #region --- Source Path Validation ---
        & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: Performing source path validation..." -Level INFO
        $sourcePathsToCheck = @()
        if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
            $sourcePathsToCheck = $EffectiveJobConfig.OriginalSourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.OriginalSourcePath)) {
            $sourcePathsToCheck = @($EffectiveJobConfig.OriginalSourcePath)
        }

        if ($EffectiveJobConfig.SourceIsVMName -ne $true) {
            $validSourcePaths = [System.Collections.Generic.List[string]]::new()
            $onSourceNotFoundAction = $EffectiveJobConfig.OnSourcePathNotFound.ToUpperInvariant()
            $shouldSkipJobFlag = $false

            foreach ($path in $sourcePathsToCheck) {
                # Test-Path with the default -Path parameter correctly resolves wildcards.
                # This is the correct way to check if a path, including wildcards, refers to at least one item.
                if ($IsSimulateMode.IsPresent -or (Test-Path -Path $path -ErrorAction SilentlyContinue)) {
                    $validSourcePaths.Add($path)
                } else {
                    $errorMessage = "Source path '$path' not found or no items match the pattern for job '$JobName'."
                    & $LocalWriteLog -Message "[WARNING] JobPreProcessor: $errorMessage" -Level WARNING

                    switch ($onSourceNotFoundAction) {
                        'FAILJOB' {
                            throw (New-Object System.IO.FileNotFoundException($errorMessage, $path))
                        }
                        'SKIPJOB' {
                            $shouldSkipJobFlag = $true
                            $preProcessingErrorMessage = "Job skipped because source path '$path' was not found and policy is 'SkipJob'."
                            break
                        }
                        'WARNANDCONTINUE' {
                            # Logged warning is sufficient, loop continues.
                        }
                    }
                }
            }

            if ($shouldSkipJobFlag) {
                & $LocalWriteLog -Message "[INFO] JobPreProcessor: $preProcessingErrorMessage" -Level "INFO"
                return @{ Success = $true; Status = 'SkipJob'; ErrorMessage = $preProcessingErrorMessage }
            }

            # If ALL source paths were invalid and the policy was 'WarnAndContinue', we should skip the job, not fail.
            if ($validSourcePaths.Count -eq 0 -and $sourcePathsToCheck.Count -gt 0) {
                $finalErrorMessage = "Job has no valid source paths to back up after checking all configured paths."
                & $LocalWriteLog -Message "[WARNING] JobPreProcessor: $finalErrorMessage" -Level "WARNING"
                # Treat this as a "skip" because there is nothing to do.
                return @{ Success = $true; Status = 'SkipJob'; ErrorMessage = $finalErrorMessage }
            }

            $currentJobSourcePathFor7Zip = $validSourcePaths
            $reportData.EffectiveSourcePath = $validSourcePaths
        }
        & $LocalWriteLog -Message "[INFO] JobPreProcessor: Source path validation completed." -Level INFO
        #endregion

        if ([string]::IsNullOrWhiteSpace($EffectiveJobConfig.DestinationDir)) {
            $preProcessingErrorMessage = "${destinationDirTerm} for job '$JobName' is not defined. Cannot proceed."
            throw (New-Object System.IO.DirectoryNotFoundException($preProcessingErrorMessage))
        }
        if (-not (Test-Path -LiteralPath $EffectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] JobPreProcessor: ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($EffectiveJobConfig.DestinationDir, "Create ${destinationDirTerm}")) {
                    try { New-Item -Path $EffectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - ${destinationDirTerm} created successfully." -Level SUCCESS }
                    catch {
                        $preProcessingErrorMessage = "Failed to create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)"
                        throw (New-Object System.IO.IOException($preProcessingErrorMessage, $_.Exception))
                    }
                }
                else {
                    $preProcessingErrorMessage = "${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' creation skipped by user."
                    & $LocalWriteLog -Message "[WARNING] JobPreProcessor: $preProcessingErrorMessage" -Level WARNING
                    return @{ Success = $false; Status = 'FailJob'; ErrorMessage = $preProcessingErrorMessage }
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
                    & $LocalWriteLog -Message "[ERROR] JobPreProcessor: $preProcessingErrorMessage" -Level "ERROR"
                    $reportData.ErrorMessage = $preProcessingErrorMessage
                    return @{ Success = $false; Status = 'FailJob'; ErrorMessage = $preProcessingErrorMessage }
                }
            }
            catch {
                $preProcessingErrorMessage = "Error during password retrieval process for job '$JobName'. Error: $($_.Exception.Message)"
                throw (New-Object System.Security.SecurityException($preProcessingErrorMessage, $_.Exception))
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
                SourcePathsToShadow = if ($currentJobSourcePathFor7Zip -is [array]) { $currentJobSourcePathFor7Zip } else { @($currentJobSourcePathFor7Zip) }
                VSSContextOption = $EffectiveJobConfig.JobVSSContextOption; MetadataCachePath = $EffectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $EffectiveJobConfig.VSSPollingTimeoutSeconds; PollingIntervalSeconds = $EffectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
                PSCmdlet = $PSCmdlet
            }
            
            $VSSPathsInUse = New-VSSShadowCopy @vssParams
            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - JobPreProcessor: VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($currentJobSourcePathFor7Zip -is [array]) {
                    $currentJobSourcePathFor7Zip | ForEach-Object { if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } }
                }
                else { if ($VSSPathsInUse.ContainsKey($currentJobSourcePathFor7Zip) -and $VSSPathsInUse[$currentJobSourcePathFor7Zip] -ne $currentJobSourcePathFor7Zip) { $VSSPathsInUse[$currentJobSourcePathFor7Zip] } else { $currentJobSourcePathFor7Zip } }
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
                    $originalLocalPaths = @($currentJobSourcePathFor7Zip | Where-Object { $_ -notmatch '^\\\\' -and (-not [string]::IsNullOrWhiteSpace($_)) })
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
            Status                      = "Proceed"
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

        if ($null -ne $VSSPathsInUse) { 
            & $LocalWriteLog -Message "DEBUG: JobPreProcessor: In catch block, calling Remove-VSSShadowCopy..." -Level "DEBUG"
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode -Logger $Logger -PSCmdletInstance $PSCmdlet -Force 
        }

        if ($null -ne $snapshotSession) {
            & $LocalWriteLog -Message "DEBUG: JobPreProcessor: In catch block, calling Remove-PoShBackupSnapshot..." -Level "DEBUG"
            $removeParams = @{
                SnapshotSession = $snapshotSession
                PSCmdlet        = $PSCmdlet
                Force           = $true
            }
            Remove-PoShBackupSnapshot @removeParams
        }

        return @{
            Success                     = $false
            Status                      = "FailJob"
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
