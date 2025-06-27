# Modules\Managers\7ZipManager\Lister.psm1
<#
.SYNOPSIS
    Sub-module for 7ZipManager. Handles listing the contents of a 7-Zip archive.
.DESCRIPTION
    This module provides the 'Get-7ZipArchiveListing' function, which is responsible
    for executing '7z l -slt' to get a detailed, machine-parsable list of an
    archive's contents. It uses a robust line-by-line parser that correctly handles
    the 7-Zip output format by treating blank lines as record separators.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.6 # Corrected key existence check for ordered dictionaries.
    DateCreated:    06-Jun-2025
    LastModified:   06-Jun-2025
    Purpose:        7-Zip archive listing and parsing logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Exported Functions ---

function Get-7ZipArchiveListing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPathExe,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword, # PSScriptAnalyzer Suppress PSAvoidUsingPlainTextForPassword - Justification: Password is required in plain text for the 7z.exe -p switch. Secure handling and clearing of this variable is managed by the calling functions.

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "7ZipManager/Lister/Get-7ZipArchiveListing: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "7ZipManager/Lister/Get-7ZipArchiveListing: Initialising for archive '$ArchivePath'." -Level "DEBUG"

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        & $LocalWriteLog -Message "7ZipManager/Lister/Get-7ZipArchiveListing: Archive not found at path '$ArchivePath'." -Level "ERROR"
        return $null
    }

    $argumentArray = @(
        "l",
        "-slt",
        $ArchivePath
    )

    if (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) {
        $argumentArray += "-p$PlainTextPassword"
    }

    $outputFromProcess = @()
    $exitCode = 0

    try {
        & $LocalWriteLog -Message "7ZipManager/Lister/Get-7ZipArchiveListing: Executing: & `"$SevenZipPathExe`" $($argumentArray -join ' ')" -Level "DEBUG"
        
        $outputFromProcess = & $SevenZipPathExe $argumentArray 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            $errorMessage = "7-Zip process failed with Exit Code: $exitCode."
            if ($outputFromProcess) {
                $errorMessage += " Output: $($outputFromProcess -join ' ')"
            }
            throw $errorMessage
        }
        
        if ($null -eq $outputFromProcess -or $outputFromProcess.Count -eq 0) {
            throw "7-Zip process completed successfully but produced no output to parse."
        }
        
        # --- FINAL ROBUST PARSER ---
        $fileList = [System.Collections.Generic.List[PSCustomObject]]::new()
        $lines = $outputFromProcess
        
        $startIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '----------') {
                $startIndex = $i + 1
                break
            }
        }

        if ($startIndex -eq -1) {
            throw "Could not find file list separator '----------' in 7-Zip output."
        }

        $currentFileProperties = $null

        for ($i = $startIndex; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            # If the line is NOT blank, we are processing a record.
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                # If we don't have a current object, this line must be the start of one.
                if ($null -eq $currentFileProperties) {
                    $currentFileProperties = [ordered]@{ Path = ''; Size = ''; PackedSize = ''; Modified = ''; Attributes = ''; CRC = ''; Encrypted = ''; Method = ''; Block = '' }
                }
                
                $parts = $line.Split('=', 2)
                if ($parts.Length -eq 2) {
                    $key = $parts[0].Trim()
                    $value = $parts[1].Trim()
                    # --- THIS IS THE CORRECTED LINE ---
                    if ($currentFileProperties.Keys -contains $key) {
                        $currentFileProperties[$key] = $value
                    }
                }
            }
            # If the line IS blank, it's a record separator. Add the completed object to the list.
            else {
                if ($null -ne $currentFileProperties) {
                    $fileList.Add([PSCustomObject]$currentFileProperties)
                    $currentFileProperties = $null # Reset for the next record
                }
            }
        }

        # Add the very last file record after the loop finishes
        if ($null -ne $currentFileProperties -and -not [string]::IsNullOrWhiteSpace($currentFileProperties.Path)) {
            $fileList.Add([PSCustomObject]$currentFileProperties)
        }

        return $fileList
        # --- END FINAL ROBUST PARSER ---

    }
    catch {
        $errorMessage = "7ZipManager/Lister/Get-7ZipArchiveListing: An error occurred while processing archive '$ArchivePath'."
        & $LocalWriteLog -Message $errorMessage -Level "ERROR"
        if ($_.Exception) {
            & $LocalWriteLog -Message "  - Exception Type: $($_.Exception.GetType().FullName)" -Level "ERROR"
            & $LocalWriteLog -Message "  - Exception Message: $($_.Exception.Message)" -Level "ERROR"
        } else {
            & $LocalWriteLog -Message "  - Error Details: $_" -Level "ERROR"
        }
        & $LocalWriteLog -Message "  - Full Exception Details: $_" -Level "DEBUG"
        return $null
    }
}

#endregion

Export-ModuleMember -Function Get-7ZipArchiveListing
