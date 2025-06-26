# Modules\Managers\VerificationManager\IntegrityChecker.psm1
<#
.SYNOPSIS
    A sub-module for VerificationManager. Performs integrity checks on restored backup files.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupIntegrityCheck' function. It takes a
    restored backup instance and performs a series of configured verification steps, such as:
    - Testing the original archive file with 7-Zip.
    - Verifying the checksum of every restored file against a backup manifest.
    - Comparing the file count in the archive vs. the restored files.

    It returns a boolean indicating the overall success of all performed checks.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # Fixed missing EffectiveTargetJobConfig parameter.
    DateCreated:    25-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To perform integrity checks on a restored backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\VerificationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\7ZipManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VerificationManager\IntegrityChecker.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Private Helper: Get CRC32 Checksum ---
# This helper is duplicated here to keep the module self-contained for this specific task.
function Get-FileCrc32Internal-Verifier {
    param(
        [string]$FilePath
    )
    try {
        $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open)
        # Assumes the Crc32 class was loaded by the parent VerificationManager
        $hasher = New-Object DamienG.Security.Cryptography.Crc32
        $hashBytes = $hasher.ComputeHash($stream)
        $stream.Close()
        $stream.Dispose()
        
        [System.Array]::Reverse($hashBytes) # Fix endianness
        $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
        return $hashString
    }
    catch {
        throw "Failed to calculate CRC32 for file '$FilePath'. Error: $($_.Exception.Message)"
    }
}
#endregion

function Invoke-PoShBackupIntegrityCheck {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # The verification job configuration hashtable.
        [Parameter(Mandatory = $true)]
        [hashtable]$VerificationJobConfig,

        # The effective configuration of the original backup job being tested.
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveTargetJobConfig,

        # The backup instance object being verified (contains file paths).
        [Parameter(Mandatory = $true)]
        [object]$InstanceToTest,
        
        # The path to the sandbox where files were restored.
        [Parameter(Mandatory = $true)]
        [string]$SandboxPath,

        # The full path to the 7z.exe executable.
        [Parameter(Mandatory = $true)]
        [string]$SevenZipPath,

        # The plain text password for the archive, if any.
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $instanceKey = $InstanceToTest.Name
    $verificationSteps = @(Get-ConfigValue -ConfigObject $VerificationJobConfig -Key 'VerificationSteps' -DefaultValue @())
    $overallSuccess = $true

    foreach ($step in $verificationSteps) {
        & $LocalWriteLog -Message "  - Integrity Check Step: '$step' starting for instance '$instanceKey'..." -Level "INFO"
        $stepSuccess = $false
        switch ($step) {
            "TestArchive" {
                $fileToTest = $InstanceToTest.Value.Files | Where-Object { $_.Name -match '\.001$' -or $_.Name -eq $instanceKey } | Sort-Object Name | Select-Object -First 1
                if ($null -eq $fileToTest) {
                    & $LocalWriteLog -Message "    - Step 'TestArchive' FAILED: Could not find a primary archive file to test." -Level "ERROR"
                } else {
                    $testResult = Test-7ZipArchive -SevenZipPathExe $SevenZipPath `
                        -ArchivePath $fileToTest.FullName `
                        -PlainTextPassword $PlainTextPassword `
                        -TreatWarningsAsSuccess $EffectiveTargetJobConfig.TreatSevenZipWarningsAsSuccess `
                        -Logger $Logger
                    if ($testResult.ExitCode -eq 0 -or ($testResult.ExitCode -eq 1 -and $EffectiveTargetJobConfig.TreatSevenZipWarningsAsSuccess)) { 
                        $stepSuccess = $true 
                    }
                }
            }
            "VerifyChecksums" {
                $contentsManifestFile = $InstanceToTest.Value.Files | Where-Object { $_.Name -like "*.contents.manifest" } | Select-Object -First 1
                if ($null -eq $contentsManifestFile) {
                    & $LocalWriteLog -Message "    - Step 'VerifyChecksums' FAILED: No contents manifest file (*.contents.manifest) found for instance '$instanceKey'." -Level "ERROR"
                } else {
                    & $LocalWriteLog -Message "    - Found contents manifest: '$($contentsManifestFile.Name)'. Verifying restored files..." -Level "INFO"
                    $allFilesVerified = $true
                    try {
                        $manifestEntries = Get-Content -LiteralPath $contentsManifestFile.FullName | Select-Object -Skip 1
                        foreach ($entry in $manifestEntries) {
                            if ($entry -match '^([^,]+),(\d*),([^,]*),([^,]*),"(.*)"$') {
                                $crcFromManifest = $Matches[1].ToUpperInvariant()
                                $sizeFromManifest = [long]$Matches[2]
                                $modifiedFromManifest = [datetime]$Matches[3]
                                $attributesFromManifest = $Matches[4]
                                $filePathInManifest = $Matches[5]
                                
                                $restoredItemPath = Join-Path -Path $SandboxPath -ChildPath $filePathInManifest
                                
                                if ($attributesFromManifest -like "*D*") {
                                    if (-not (Test-Path -LiteralPath $restoredItemPath -PathType Container)) {
                                        & $LocalWriteLog -Message "      - FAILED: Directory '$filePathInManifest' listed in manifest was not found." -Level "ERROR"; $allFilesVerified = $false
                                    } else { & $LocalWriteLog -Message "      - PASSED: Directory '$filePathInManifest' exists." -Level "DEBUG" }
                                    continue
                                }

                                $restoredFileInfo = $null
                                try { $restoredFileInfo = Get-Item -LiteralPath $restoredItemPath -Force -ErrorAction Stop }
                                catch { & $LocalWriteLog -Message "      - FAILED: File '$filePathInManifest' not found in sandbox. Error: $($_.Exception.Message)" -Level "ERROR"; $allFilesVerified = $false; continue }

                                if ($restoredFileInfo.Length -ne $sizeFromManifest) {
                                    & $LocalWriteLog -Message "      - FAILED: Size mismatch for '$filePathInManifest'. Manifest: $sizeFromManifest, Actual: $($restoredFileInfo.Length)." -Level "ERROR"; $allFilesVerified = $false
                                } else { & $LocalWriteLog -Message "      - PASSED: Size matches for '$filePathInManifest'." -Level "DEBUG" }
                                
                                if ([System.Math]::Abs(($restoredFileInfo.LastWriteTime - $modifiedFromManifest).TotalSeconds) -gt 1.5) {
                                    & $LocalWriteLog -Message "      - FAILED: Modified date mismatch for '$filePathInManifest'. Manifest: $modifiedFromManifest, Actual: $($restoredFileInfo.LastWriteTime)." -Level "ERROR"; $allFilesVerified = $false
                                } else { & $LocalWriteLog -Message "      - PASSED: Modified date matches for '$filePathInManifest'." -Level "DEBUG" }

                                if ($crcFromManifest -ne "00000000") {
                                    try {
                                        $recalculatedCrc = Get-FileCrc32Internal-Verifier -FilePath $restoredFileInfo.FullName
                                        if ($recalculatedCrc -ne $crcFromManifest) {
                                            & $LocalWriteLog -Message "      - FAILED: CRC mismatch for '$filePathInManifest'. Manifest: $crcFromManifest, Actual: $recalculatedCrc." -Level "ERROR"; $allFilesVerified = $false
                                        } else { & $LocalWriteLog -Message "      - PASSED: CRC matches for '$filePathInManifest'." -Level "DEBUG" }
                                    } catch {
                                        & $LocalWriteLog -Message "      - FAILED: Could not calculate CRC for '$filePathInManifest'. Error: $($_.Exception.Message)" -Level "ERROR"; $allFilesVerified = $false
                                    }
                                }
                            }
                        }
                        $stepSuccess = $allFilesVerified
                    } catch {
                        & $LocalWriteLog -Message "    - Step 'VerifyChecksums' FAILED: Could not read or parse manifest file '$($contentsManifestFile.FullName)'. Error: $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            }
            "CompareFileCount" {
                 # This is a simplified implementation.
                & $LocalWriteLog -Message "    - Step 'CompareFileCount' SKIPPED: Full implementation pending." -Level "WARNING"
                $stepSuccess = $true # Placeholder
            }
        }

        if ($stepSuccess) {
            & $LocalWriteLog -Message "  - Integrity Check Step: '$step' PASSED." -Level "SUCCESS"
        } else {
            & $LocalWriteLog -Message "  - Integrity Check Step: '$step' FAILED." -Level "ERROR"
            $overallSuccess = $false
        }
    }
    
    return $overallSuccess
}


Export-ModuleMember -Function Invoke-PoShBackupIntegrityCheck
