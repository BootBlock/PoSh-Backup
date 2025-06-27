# Modules\Operations\JobPreProcessor.psm1
<#
.SYNOPSIS
    Acts as a facade to orchestrate the pre-processing steps for a PoSh-Backup job
    before local archive creation begins.
.DESCRIPTION
    This module encapsulates operations that must occur before the main archiving
    process begins for a PoSh-Backup job. It acts as a facade, calling specialised
    sub-modules in a specific sequence:
    1.  'Invoke-PoShBackupPathValidation' from 'PathValidator.psm1' to check source and
        destination paths.
    2.  'Invoke-PoShBackupCredentialAndHookHandling' from 'CredentialAndHookHandler.psm1'
        to retrieve passwords and run pre-backup hooks.
    3.  'Resolve-PoShBackupSourcePath' from 'SourceResolver.psm1' to orchestrate VSS or
        infrastructure snapshots and determine the final source paths for the backup.

    The main exported function, 'Invoke-PoShBackupJobPreProcessing', returns a detailed
    hashtable containing the outcome of these steps, including the final source paths,
        any retrieved passwords, and any session objects (VSS, Snapshot) that require cleanup.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade.
    DateCreated:    27-May-2025
    LastModified:   26-Jun-2025
    Purpose:        To orchestrate pre-archive creation logic.
    Prerequisites:  PowerShell 5.1+.
                    Depends on sub-modules in '.\JobPreProcessor\'.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations
$subModulePath = Join-Path -Path $PSScriptRoot -ChildPath "JobPreProcessor"
try {
    Import-Module -Name (Join-Path $subModulePath "PathValidator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $subModulePath "CredentialAndHookHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $subModulePath "SourceResolver.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobPreProcessor.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function ---
function Invoke-PoShBackupJobPreProcessing {
    [OutputType([hashtable])]
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

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "JobPreProcessor (Facade): Orchestrating pre-processing for job '$JobName'." -Level "DEBUG"

    $vssPathsToCleanUp = $null
    $snapshotSession = $null
    $plainTextPasswordToClear = $null

    try {
        # --- Step 1: Validate Source and Destination Paths ---
        $pathValidationResult = Invoke-PoShBackupPathValidation -JobName $JobName `
            -EffectiveJobConfig $EffectiveJobConfig `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger `
            -PSCmdletInstance $PSCmdlet

        if ($pathValidationResult.Status -ne 'Proceed') {
            return @{ Success = $true; Status = $pathValidationResult.Status; ErrorMessage = $pathValidationResult.ErrorMessage }
        }
        $validatedSourcePaths = $pathValidationResult.ValidSourcePaths

        # --- Step 2: Handle Credentials and Pre-Backup Hooks ---
        $credAndHookResult = Invoke-PoShBackupCredentialAndHookHandling -JobName $JobName `
            -EffectiveJobConfig $EffectiveJobConfig `
            -JobReportDataRef $JobReportDataRef `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger `
            -ActualConfigFile $ActualConfigFile
        
        $plainTextPasswordToClear = $credAndHookResult.PlainTextPasswordToClear

        # --- Step 3: Resolve Final Source Paths (VSS / Snapshots) ---
        $sourceResolverResult = Resolve-PoShBackupSourcePath -JobName $JobName `
            -EffectiveJobConfig $EffectiveJobConfig `
            -InitialSourcePaths $validatedSourcePaths `
            -JobReportDataRef $JobReportDataRef `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger `
            -PSCmdletInstance $PSCmdlet
        
        # Aggregate cleanup data from the source resolver
        $vssPathsToCleanUp = $sourceResolverResult.VSSPathsToCleanUp
        $snapshotSession = $sourceResolverResult.SnapshotSessionToCleanUp

        # Return the final result for the next stage
        return @{
            Success                     = $true
            Status                      = 'Proceed'
            CurrentJobSourcePathFor7Zip = $sourceResolverResult.FinalSourcePathsFor7Zip
            VSSPathsInUse               = $vssPathsToCleanUp
            SnapshotSession             = $snapshotSession
            PlainTextPasswordToClear    = $plainTextPasswordToClear
            ActualPlainTextPassword     = $plainTextPasswordToClear
            ErrorMessage                = $null
        }
    }
    catch {
        $finalErrorMessage = $_.Exception.Message
        & $LocalWriteLog -Message "[ERROR] JobPreProcessor (Facade): Error during pre-processing for job '$JobName': $finalErrorMessage" -Level "ERROR"
        if ($_.Exception.ToString() -ne $finalErrorMessage) {
            & $LocalWriteLog -Message "  Full Exception: $($_.Exception.ToString())" -Level "DEBUG"
        }

        # Attempt cleanup even on failure
        if ($null -ne $vssPathsToCleanUp) { Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode -Logger $Logger -PSCmdletInstance $PSCmdlet -Force }
        if ($null -ne $snapshotSession) { Remove-PoShBackupSnapshot -SnapshotSession $snapshotSession -PSCmdlet $PSCmdlet -Force }

        return @{
            Success                     = $false
            Status                      = 'FailJob'
            CurrentJobSourcePathFor7Zip = $null
            VSSPathsInUse               = $null
            SnapshotSession             = $null
            PlainTextPasswordToClear    = $plainTextPasswordToClear
            ActualPlainTextPassword     = $plainTextPasswordToClear
            ErrorMessage                = $finalErrorMessage
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJobPreProcessing
