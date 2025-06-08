# Modules\Managers\7ZipManager\Extractor.psm1
<#
.SYNOPSIS
    Sub-module for 7ZipManager. Handles the extraction of files from a 7-Zip archive.
.DESCRIPTION
    This module provides the 'Invoke-7ZipExtraction' function, which is responsible
    for executing '7z x' (extract with full paths) to restore files from a backup
    archive. It includes parameters for specifying an output directory, handling
    passwords, and managing file overwrite behaviour.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    06-Jun-2025
    LastModified:   06-Jun-2025
    Purpose:        7-Zip archive extraction logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Exported Functions ---

function Invoke-7ZipExtraction {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
        param(
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPathExe,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [string[]]$FilesToExtract,

        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword, # PSScriptAnalyzer Suppress PSAvoidUsingPlainTextForPassword - Justification: Password is required in plain text for the 7z.exe -p switch. Secure handling is managed by the caller.

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Initializing extraction for archive '$ArchivePath'." -Level "DEBUG"

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Archive not found at path '$ArchivePath'." -Level "ERROR"
        return $false
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Output directory not found at '$OutputDirectory'. Attempting to create." -Level "INFO"
        try {
            New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            & $LocalWriteLog -Message "  - Successfully created output directory '$OutputDirectory'." -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Failed to create output directory '$OutputDirectory'. Error: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }

    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add("x") # 'x' extracts with full paths
    $argumentList.Add("`"$ArchivePath`"")

    # Add the output directory switch. It must be formatted as -o"Path" with no space.
    $argumentList.Add("-o`"$OutputDirectory`"")

    # Add the overwrite mode switch
    if ($Force.IsPresent) {
        $argumentList.Add("-aoa") # Overwrite all existing files without prompt
    } else {
        $argumentList.Add("-aos") # Skip extracting existing files
    }

    if (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) {
        $argumentList.Add("-p`"$PlainTextPassword`"")
    }
    
    # Add specific files to extract if provided
    if ($null -ne $FilesToExtract -and $FilesToExtract.Count -gt 0) {
        foreach ($file in $FilesToExtract) {
            $argumentList.Add("`"$file`"")
        }
    }

    $fullCommand = "& `"$SevenZipPathExe`" $($argumentList -join ' ')"
    & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Executing command: $fullCommand" -Level "DEBUG"

    try {
        if (-not $PSCmdlet.ShouldProcess($OutputDirectory, "Extract files from '$ArchivePath'")) {
            & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: Extraction skipped by user (ShouldProcess)." -Level "WARNING"
            return $false
        }

        $output = Invoke-Expression "$fullCommand 2>&1"
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            $errorMessage = "7-Zip failed to extract archive. Exit Code: $exitCode."
            if ($output) {
                $errorMessage += " Output: $($output -join ' ')"
            }
            throw $errorMessage
        }

        & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: 7-Zip process completed successfully." -Level "SUCCESS"
        return $true
    }
    catch {
        & $LocalWriteLog -Message "7ZipManager/Extractor/Invoke-7ZipExtraction: An error occurred during extraction. Error: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

#endregion

Export-ModuleMember -Function Invoke-7ZipExtraction
