# Modules\Operations\JobPreProcessor.psm1
<#
.SYNOPSIS
    Handles pre-processing steps for a PoSh-Backup job before local archive creation.
.DESCRIPTION
    This module encapsulates operations that must occur before the main archiving
    process begins for a PoSh-Backup job. This includes:
    - Performing early accessibility checks for configured source and destination paths,
      especially UNC paths.
    - Validating and, if necessary, creating the local destination (staging) directory.
    - Retrieving the archive password based on the job's configuration (delegates
      to PasswordManager.psm1). If password retrieval fails for an expected method
      (e.g., user cancels interactive prompt), it now gracefully sets an error
      and returns a failure status rather than throwing a raw exception.
    - Executing any user-defined pre-backup hook scripts (delegates to HookManager.psm1).
    - Managing the creation of Volume Shadow Copies (VSS) if enabled for the job,
      and determining the effective source paths for 7-Zip (delegates to VssManager.psm1).

    The main exported function, Invoke-PoShBackupJobPreProcessing, returns critical
    information needed for the subsequent archiving phase, such as the resolved source
    paths (which might be VSS paths) and the actual plain text password if retrieved.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3 # Gemini is incredibly thick and totally made up a 7-ZIP feature that doesn't exist
    DateCreated:    27-May-2025
    LastModified:   28-May-2025
    Purpose:        To modularise pre-archive creation logic from the main Operations module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1, PasswordManager.psm1, HookManager.psm1,
                    and VssManager.psm1 from the parent 'Modules' directory or 'Modules\Managers'.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\HookManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\VssManager.psm1") -Force -ErrorAction Stop
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
                    # User chose No for ShouldProcess
                    $preProcessingErrorMessage = "${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' creation skipped by user."
                    # This is a deliberate stop, so we should indicate failure to proceed.
                    & $LocalWriteLog -Message "[WARNING] JobPreProcessor: $preProcessingErrorMessage" -Level WARNING
                    return @{ Success = $false; ErrorMessage = $preProcessingErrorMessage; VSSPathsInUse = $null; PlainTextPasswordToClear = $null; ActualPlainTextPassword = $plainTextPasswordForJob; CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip }
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
                    # MODIFIED: Graceful handling instead of throw
                    $preProcessingErrorMessage = "Password was required for job '$JobName' via method '$($EffectiveJobConfig.ArchivePasswordMethod)' but was not provided or was cancelled."
                    & $LocalWriteLog -Message "[ERROR] JobPreProcessor: $preProcessingErrorMessage" -Level ERROR
                    $reportData.ErrorMessage = $preProcessingErrorMessage
                    return @{ Success = $false; ErrorMessage = $preProcessingErrorMessage; VSSPathsInUse = $null; PlainTextPasswordToClear = $null; ActualPlainTextPassword = $plainTextPasswordForJob; CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip }
                }
            }
            catch { 
                # Catch errors from Get-PoShBackupArchivePassword (e.g., secret not found, file not found)
                $preProcessingErrorMessage = "Error during password retrieval process for job '$JobName'. Error: $($_.Exception.Message)"
                throw $preProcessingErrorMessage # Re-throw to be caught by the main catch block of this function
            }
        }
        elseif ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"; $EffectiveJobConfig.PasswordInUseFor7Zip = $false
        }

        Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
            -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
            -IsSimulateMode:$IsSimulateMode -Logger $Logger

        if ($EffectiveJobConfig.JobEnableVSS) {
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
            $VSSPathsInUse = New-VSSShadowCopy @vssParams # This can return $null or a map
            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - JobPreProcessor: VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
                    $EffectiveJobConfig.OriginalSourcePath | ForEach-Object { if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } }
                }
                else { if ($VSSPathsInUse.ContainsKey($EffectiveJobConfig.OriginalSourcePath) -and $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] -ne $EffectiveJobConfig.OriginalSourcePath) { $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] } else { $EffectiveJobConfig.OriginalSourcePath } }
                $reportData.VSSShadowPaths = $VSSPathsInUse
            }
            elseif ($EffectiveJobConfig.JobEnableVSS -and ($null -eq $VSSPathsInUse)) {
                # VSS was enabled but New-VSSShadowCopy returned null (failure)
                $preProcessingErrorMessage = "VSS shadow copy creation failed for job '$JobName'. Check VSSManager logs."
                # Do not throw here, allow job to proceed with original paths but log error.
                # Operations.psm1 will use original paths if VSSPathsInUse is null.
                & $LocalWriteLog -Message "[ERROR] JobPreProcessor: $preProcessingErrorMessage" -Level ERROR
                # Set VSSStatus to reflect failure
                $reportData.VSSStatus = "Failed (Creation Error)"
            }
        }
        # Update VSSStatus in reportData
        if ($EffectiveJobConfig.JobEnableVSS) {
            $reportData.VSSAttempted = $true
            if ($IsSimulateMode.IsPresent) { 
                $reportData.VSSStatus = "Simulated" # Simplified for simulation
            }
            elseif ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                # Check if all local paths were successfully shadowed
                $allLocalShadowed = $true
                $originalLocalPaths = @($EffectiveJobConfig.OriginalSourcePath | Where-Object { $_ -notmatch '^\\\\' -and (-not [string]::IsNullOrWhiteSpace($_)) })
                if ($originalLocalPaths.Count -gt 0) {
                    foreach ($lp in $originalLocalPaths) {
                        if (-not ($VSSPathsInUse.ContainsKey($lp) -and $VSSPathsInUse[$lp] -ne $lp)) {
                            $allLocalShadowed = $false; break
                        }
                    }
                    $reportData.VSSStatus = if ($allLocalShadowed) { "Used Successfully" } else { "Partially Used or Failed for some local paths" }
                }
                else {
                    # No local paths to shadow
                    $reportData.VSSStatus = "Not Applicable (No local paths)"
                }
            }
            elseif (-not $reportData.ContainsKey("VSSStatus")) {
                # If not already set to Failed by earlier VSS error
                $reportData.VSSStatus = "Failed or Not Used (No shadow paths returned)"
            }
        }
        else { 
            $reportData.VSSAttempted = $false
            $reportData.VSSStatus = "Not Enabled"
        }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) { $currentJobSourcePathFor7Zip } else { @($currentJobSourcePathFor7Zip) }


        return @{
            Success                     = $true
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
            VSSPathsInUse               = $VSSPathsInUse
            PlainTextPasswordToClear    = $plainTextPasswordForJob 
            ActualPlainTextPassword     = $plainTextPasswordForJob
            ErrorMessage                = $null
        }

    }
    catch {
        # This main catch block now handles exceptions from path checks, dir creation, VSS admin check, or re-thrown password errors.
        $finalErrorMessage = if (-not [string]::IsNullOrWhiteSpace($preProcessingErrorMessage)) { $preProcessingErrorMessage } else { $_.Exception.Message }
        & $LocalWriteLog -Message "[ERROR] JobPreProcessor: Error during pre-processing for job '$JobName': $finalErrorMessage" -Level "ERROR"
        if ($_.Exception.ToString() -ne $finalErrorMessage) {
            # Log full exception if different
            & $LocalWriteLog -Message "  Full Exception: $($_.Exception.ToString())" -Level "DEBUG"
        }
        
        if ($null -ne $VSSPathsInUse) {
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode -Logger $Logger 
        }
        return @{
            Success                     = $false
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip 
            VSSPathsInUse               = $null 
            PlainTextPasswordToClear    = $plainTextPasswordForJob 
            ActualPlainTextPassword     = $plainTextPasswordForJob
            ErrorMessage                = $finalErrorMessage
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJobPreProcessing
