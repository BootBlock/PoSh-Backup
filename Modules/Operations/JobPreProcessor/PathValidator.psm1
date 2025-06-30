# Modules\Operations\JobPreProcessor\PathValidator.psm1
<#
.SYNOPSIS
    A sub-module for JobPreProcessor.psm1. Handles validation of source and destination paths.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupPathValidation' function. It is responsible
    for verifying that configured source paths exist and are accessible, applying the
    'OnSourcePathNotFound' policy, and ensuring the local destination directory exists and
    is writable before a backup begins. It also contains a critical safety check to prevent
    the destination from being a sub-path of the source.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Corrected order of operations to create destination before recursive check.
    DateCreated:    26-Jun-2025
    LastModified:   29-Jun-2025
    Purpose:        To isolate path validation logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations\JobPreProcessor
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "PathValidator.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupPathValidation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
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
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "PathValidator: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "PathValidator: Initialising for job '$JobName'." -Level "DEBUG"

    $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

    # --- Step 1: Destination Path Validation (Moved Up) ---
    # This must happen first to ensure the directory exists before we try to resolve its path for the recursive check.
    if ([string]::IsNullOrWhiteSpace($EffectiveJobConfig.DestinationDir)) {
        throw (New-Object System.IO.DirectoryNotFoundException("${destinationDirTerm} for job '$JobName' is not defined. Cannot proceed."))
    }
    if (-not (Test-Path -LiteralPath $EffectiveJobConfig.DestinationDir -PathType Container)) {
        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: The ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' would be created if it did not exist." -Level "SIMULATE"
        } else {
            & $LocalWriteLog -Message "[INFO] PathValidator: ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if ($PSCmdletInstance.ShouldProcess($EffectiveJobConfig.DestinationDir, "Create ${destinationDirTerm}")) {
                try { New-Item -Path $EffectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - ${destinationDirTerm} created successfully." -Level SUCCESS }
                catch { throw (New-Object System.IO.IOException("Failed to create ${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)", $_.Exception)) }
            } else {
                return @{ Status = 'FailJob'; ErrorMessage = "${destinationDirTerm} '$($EffectiveJobConfig.DestinationDir)' creation skipped by user." }
            }
        }
    }

    # --- Step 2: Source Path Validation ---
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: The existence and accessibility of all source paths would be verified." -Level "SIMULATE"
    } else {
        & $LocalWriteLog -Message "`n[DEBUG] PathValidator: Performing source path validation..." -Level "DEBUG"
    }

    $sourcePathsToCheck = @()
    if ($EffectiveJobConfig.OriginalSourcePath -is [array]) {
        $sourcePathsToCheck = $EffectiveJobConfig.OriginalSourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.OriginalSourcePath)) {
        $sourcePathsToCheck = @($EffectiveJobConfig.OriginalSourcePath)
    }

    $validSourcePaths = [System.Collections.Generic.List[string]]::new()
    if ($EffectiveJobConfig.SourceIsVMName -ne $true) {
        $onSourceNotFoundAction = $EffectiveJobConfig.OnSourcePathNotFound.ToUpperInvariant()
        foreach ($path in $sourcePathsToCheck) {
            if ($IsSimulateMode.IsPresent -or (Test-Path -Path $path -ErrorAction SilentlyContinue)) {
                $validSourcePaths.Add($path)
            } else {
                $errorMessage = "Source path '$path' not found or is not accessible for job '$JobName'."
                $adviceMessage = "ADVICE: Please check for typos in your configuration. If it is a network path, ensure the share is online and accessible by the user running the script."
                & $LocalWriteLog -Message "[WARNING] PathValidator: $errorMessage" -Level "WARNING"
                & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"

                switch ($onSourceNotFoundAction) {
                    'FAILJOB' { throw (New-Object System.IO.FileNotFoundException($errorMessage, $path)) }
                    'SKIPJOB' { return @{ Status = 'SkipJob'; ErrorMessage = "Job skipped because source path '$path' was not found and policy is 'SkipJob'." } }
                }
            }
        }
        if ($validSourcePaths.Count -eq 0 -and $sourcePathsToCheck.Count -gt 0) {
            $finalErrorMessage = "Job has no valid source paths to back up after checking all configured paths."
            & $LocalWriteLog -Message "[WARNING] PathValidator: $finalErrorMessage" -Level "WARNING"
            return @{ Status = 'SkipJob'; ErrorMessage = $finalErrorMessage }
        }
    } else {
        $validSourcePaths.AddRange($sourcePathsToCheck) # For VM backups, pass paths through for the SourceResolver
    }
    if (-not $IsSimulateMode.IsPresent) { & $LocalWriteLog -Message "[DEBUG] PathValidator: Source path validation completed." -Level DEBUG }
    
    # --- Step 3: Recursive Path Validation (Moved Down) ---
    # Now that the destination is guaranteed to exist (in non-simulate mode), this check can run safely.
    if (-not $IsSimulateMode.IsPresent -and $EffectiveJobConfig.SourceIsVMName -ne $true) {
        try {
            $resolvedDestPath = (Resolve-Path -LiteralPath $EffectiveJobConfig.DestinationDir -ErrorAction Stop).Path.TrimEnd('\')
            
            foreach ($sourcePath in $sourcePathsToCheck) {
                if (-not (Test-Path -LiteralPath $sourcePath)) { continue }
                
                $resolvedSourcePath = (Resolve-Path -LiteralPath $sourcePath -ErrorAction Stop).Path.TrimEnd('\')

                if ($resolvedDestPath -eq $resolvedSourcePath -or $resolvedDestPath.StartsWith($resolvedSourcePath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $errorMessage = "CRITICAL CONFIGURATION ERROR for job '$JobName': The destination directory ('$resolvedDestPath') cannot be the same as or a sub-directory of a source path ('$resolvedSourcePath')."
                    $adviceMessage = "ADVICE: To prevent a recursive backup loop, please change the 'DestinationDir' for this job to a location outside of any source paths."
                    & $LocalWriteLog -Message $errorMessage -Level "ERROR"
                    & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
                    throw $errorMessage
                }
            }
        }
        catch {
            $errorMessage = "Path validation failed for job '$JobName' while checking for recursive paths. A source or destination path might be invalid. Error: $($_.Exception.Message)"
            & $LocalWriteLog -Message $errorMessage -Level "ERROR"
            throw $errorMessage
        }
    }

    return @{ Status = 'Proceed'; ValidSourcePaths = $validSourcePaths; ErrorMessage = $null }
}

Export-ModuleMember -Function Invoke-PoShBackupPathValidation
