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
      to PasswordManager.psm1).
    - Executing any user-defined pre-backup hook scripts (delegates to HookManager.psm1).
    - Managing the creation of Volume Shadow Copies (VSS) if enabled for the job,
      and determining the effective source paths for 7-Zip (delegates to VssManager.psm1).

    The main exported function, Invoke-PoShBackupJobPreProcessing, returns critical
    information needed for the subsequent archiving phase, such as the resolved source
    paths (which might be VSS paths) and the path to any temporary password file.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added SupportsShouldProcess to Invoke-PoShBackupJobPreProcessing.
    DateCreated:    27-May-2025
    LastModified:   27-May-2025
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
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] # Added SupportsShouldProcess
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
        [string]$PSScriptRootForPaths, # Main script's PSScriptRoot
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobPreProcessor/Invoke-PoShBackupJobPreProcessing: Initializing for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $currentJobSourcePathFor7Zip = $EffectiveJobConfig.OriginalSourcePath # Start with original
    $tempPasswordFilePath = $null
    $VSSPathsInUse = $null
    $plainTextPasswordForJob = $null # For secure clearing

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        #region --- Early UNC Path Accessibility Checks ---
        & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: Performing early accessibility checks for configured paths..." -Level INFO
        $sourcePathsToCheck = @()
        if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
            $sourcePathsToCheck = $EffectiveJobConfig.OriginalSourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        } elseif (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.OriginalSourcePath)) {
            $sourcePathsToCheck = @($EffectiveJobConfig.OriginalSourcePath)
        }
        foreach ($individualSourcePath in $sourcePathsToCheck) {
            if ($individualSourcePath -match '^\\\\') {
                $uncPathToTestForSource = $individualSourcePath
                if ($individualSourcePath -match '[\*\?\[]') { $uncPathToTestForSource = Split-Path -LiteralPath $individualSourcePath -Parent }
                if ([string]::IsNullOrWhiteSpace($uncPathToTestForSource) -or ($uncPathToTestForSource -match '^\\\\([^\\]+)$')) {
                    & $LocalWriteLog -Message "[WARNING] JobPreProcessor: Could not determine a valid UNC base directory to test accessibility for source path '$individualSourcePath'. Check skipped." -Level WARNING
                } else {
                    if (-not $IsSimulateMode.IsPresent) {
                        if (-not (Test-Path -LiteralPath $uncPathToTestForSource)) {
                            throw "JobPreProcessor: UNC source path '$individualSourcePath' (base '$uncPathToTestForSource') is inaccessible. Job '$JobName' cannot proceed."
                        } else { & $LocalWriteLog -Message "  - JobPreProcessor: UNC source path '$individualSourcePath' (tested base: '$uncPathToTestForSource') accessibility: PASSED." -Level DEBUG }
                    } else { & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would test accessibility of UNC source path '$individualSourcePath' (base '$uncPathToTestForSource')." -Level SIMULATE }
                }
            }
        }
        if ($EffectiveJobConfig.DestinationDir -match '^\\\\') {
            $uncDestinationBasePathToTest = $null
            if ($EffectiveJobConfig.DestinationDir -match '^(\\\\\\[^\\]+\\[^\\]+)') { $uncDestinationBasePathToTest = $matches[1] }
            if (-not [string]::IsNullOrWhiteSpace($uncDestinationBasePathToTest)) {
                if (-not $IsSimulateMode.IsPresent) {
                    if (-not (Test-Path -LiteralPath $uncDestinationBasePathToTest)) {
                        throw "JobPreProcessor: Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' (from '$($EffectiveJobConfig.DestinationDir)') is inaccessible. Job '$JobName' cannot proceed."
                    } else { & $LocalWriteLog -Message "  - JobPreProcessor: Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' accessibility: PASSED." -Level DEBUG }
                } else { & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would test accessibility of base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest'." -Level SIMULATE }
            } else { & $LocalWriteLog -Message "[WARNING] JobPreProcessor: Could not determine base UNC share for ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Full path creation attempted later." -Level WARNING }
        }
        & $LocalWriteLog -Message "[INFO] JobPreProcessor: Early accessibility checks completed." -Level INFO
        #endregion

        if ([string]::IsNullOrWhiteSpace($EffectiveJobConfig.DestinationDir)) {
            throw "JobPreProcessor: ${destinationDirTerm} for job '$JobName' is not defined. Cannot proceed."
        }
        if (-not (Test-Path -LiteralPath $EffectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] JobPreProcessor: ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($EffectiveJobConfig.DestinationDir, "Create ${destinationDirTerm}")) {
                    try { New-Item -Path $EffectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - ${destinationDirTerm} created successfully." -Level SUCCESS }
                    catch { throw "JobPreProcessor: Failed to create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" }
                }
            } else {
                & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        $isPasswordRequiredOrConfigured = ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $EffectiveJobConfig.UsePassword
        $EffectiveJobConfig.PasswordInUseFor7Zip = $false # Ensure this is part of the effective config being built
        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordParams = @{
                    JobConfigForPassword = $EffectiveJobConfig; JobName = $JobName
                    IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
                }
                # Pass PSCmdlet if Get-PoShBackupArchivePassword supports it (for interactive prompts respecting -Confirm)
                if ((Get-Command Get-PoShBackupArchivePassword).Parameters.ContainsKey('PSCmdlet')) {
                    $passwordParams.PSCmdlet = $PSCmdlet
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams
                $reportData.PasswordSource = $passwordResult.PasswordSource
                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword # Store locally for cleanup
                    $EffectiveJobConfig.PasswordInUseFor7Zip = $true
                    if ($IsSimulateMode.IsPresent) {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_poshbackup_pass.tmp")
                        & $LocalWriteLog -Message "SIMULATE: JobPreProcessor: Would write password (obtained via $($reportData.PasswordSource)) to temporary file '$tempPasswordFilePath' for 7-Zip." -Level SIMULATE
                    } else {
                        if ($PSCmdlet.ShouldProcess("Temporary Password File", "Create and Write Password (details in DEBUG log)")) {
                            $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                            Set-Content -Path $tempPasswordFilePath -Value $plainTextPasswordForJob -Encoding UTF8 -Force -ErrorAction Stop
                            & $LocalWriteLog -Message "   - JobPreProcessor: Password (obtained via $($reportData.PasswordSource)) written to temporary file '$tempPasswordFilePath' for 7-Zip." -Level DEBUG
                        }
                    }
                } elseif ($isPasswordRequiredOrConfigured -and $EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                    throw "JobPreProcessor: Password was required for job '$JobName' via method '$($EffectiveJobConfig.ArchivePasswordMethod)' but could not be obtained or was empty."
                }
            } catch { throw "JobPreProcessor: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" }
        } elseif ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"; $EffectiveJobConfig.PasswordInUseFor7Zip = $false
        }

        Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
            -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
            -IsSimulateMode:$IsSimulateMode -Logger $Logger

        if ($EffectiveJobConfig.JobEnableVSS) {
            & $LocalWriteLog -Message "`n[INFO] JobPreProcessor: VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege -Logger $Logger)) { throw "JobPreProcessor: VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." }
            $vssParams = @{
                SourcePathsToShadow = if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {$EffectiveJobConfig.OriginalSourcePath} else {@($EffectiveJobConfig.OriginalSourcePath)}
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
                } else { if ($VSSPathsInUse.ContainsKey($EffectiveJobConfig.OriginalSourcePath) -and $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] -ne $EffectiveJobConfig.OriginalSourcePath) { $VSSPathsInUse[$EffectiveJobConfig.OriginalSourcePath] } else { $EffectiveJobConfig.OriginalSourcePath } }
                $reportData.VSSShadowPaths = $VSSPathsInUse
            }
        }
        if ($EffectiveJobConfig.JobEnableVSS) {
            $reportData.VSSAttempted = $true; $originalSourcePathsForJob = if ($EffectiveJobConfig.OriginalSourcePath -is [array]) { $EffectiveJobConfig.OriginalSourcePath } else { @($EffectiveJobConfig.OriginalSourcePath) }
            $containsUncPath = $false; $containsLocalPath = $false; $localPathVssUsedSuccessfully = $false
            if ($null -ne $originalSourcePathsForJob) {
                foreach ($originalPathItem in $originalSourcePathsForJob) {
                    if (-not [string]::IsNullOrWhiteSpace($originalPathItem)) {
                        $isUncPathItem = $false; try { if (([uri]$originalPathItem).IsUnc) { $isUncPathItem = $true } } catch { & $LocalWriteLog -Message "JobPreProcessor: Path '$originalPathItem' could not be parsed as URI for UNC check. Assuming local. Error: $($_.Exception.Message)" -Level "DEBUG" }
                        if ($isUncPathItem) { $containsUncPath = $true }
                        else { $containsLocalPath = $true; if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.ContainsKey($originalPathItem) -and $VSSPathsInUse[$originalPathItem] -ne $originalPathItem) { $localPathVssUsedSuccessfully = $true } }
                    }
                }
            }
            if ($IsSimulateMode.IsPresent) { $reportData.VSSStatus = if ($containsLocalPath -and $containsUncPath) { "Simulated (Used for local, Skipped for network)" } elseif ($containsUncPath -and -not $containsLocalPath) { "Simulated (Skipped - All Network Paths)" } elseif ($containsLocalPath) { "Simulated (Used for local paths)" } else { "Simulated (No paths processed for VSS)" } }
            else { if ($containsLocalPath) { $reportData.VSSStatus = if ($localPathVssUsedSuccessfully) { if ($containsUncPath) { "Partially Used (Local success, Network skipped)" } else { "Used Successfully" } } else { if ($containsUncPath) { "Failed (Local VSS failed/skipped, Network skipped)" } else { "Failed (Local VSS failed/skipped)" } } } elseif ($containsUncPath) { $reportData.VSSStatus = "Not Applicable (All Source Paths Network)" } else { $reportData.VSSStatus = "Not Applicable (No Source Paths Specified)" } }
        } else { $reportData.VSSAttempted = $false; $reportData.VSSStatus = "Not Enabled" }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}


        return @{
            Success                     = $true
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
            TempPasswordFilePath        = $tempPasswordFilePath
            VSSPathsInUse               = $VSSPathsInUse
            PlainTextPasswordToClear    = $plainTextPasswordForJob # Pass this back for secure clearing by the caller
            ErrorMessage                = $null
        }

    } catch {
        $errorMessageText = "JobPreProcessor: Error during pre-processing for job '$JobName': $($_.Exception.ToString())"
        & $LocalWriteLog -Message $errorMessageText -Level "ERROR"
        # Ensure any created temp password file is cleaned up if an error occurs within this scope
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp"))) {
            try { Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction SilentlyContinue } catch {}
        }
        # Ensure VSS is cleaned up if an error occurs after VSS creation but before returning VSSPathsInUse
        if ($null -ne $VSSPathsInUse) {
            # Call VssManager's Remove-VSSShadowCopy directly
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode -Logger $Logger # Assumes VssManager is loaded
        }
        return @{
            Success                     = $false
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip # Might be original or partially VSS
            TempPasswordFilePath        = $null # Already attempted cleanup or was not created
            VSSPathsInUse               = $null # Already attempted cleanup
            PlainTextPasswordToClear    = $plainTextPasswordForJob # Still needs clearing if obtained
            ErrorMessage                = $_.Exception.ToString()
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJobPreProcessing
