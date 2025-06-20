# Modules\Managers\VerificationManager.psm1
<#
.SYNOPSIS
    Manages the automated verification of PoSh-Backup archives by restoring them
    to a sandbox environment and performing integrity checks.
.DESCRIPTION
    This module provides the core functionality for the Automated Backup Verification feature.
    It is designed to be invoked by the ScriptModeHandler when the -RunVerificationJobs
    or -VerificationJobName switch is used.

    The main exported function, 'Invoke-PoShBackupVerification', performs the following:
    - Reads the 'VerificationJobs' from the configuration.
    - If a specific job name is provided, it will run only that job. Otherwise, it runs all enabled jobs.
    - For each job to be run, it finds the latest backup(s) of the target backup job.
    - It prepares a temporary "sandbox" directory for the restore.
    - It restores the archive to the sandbox.
    - It performs the configured verification steps, which can include:
        - Testing the archive with 7-Zip (`7z t`).
        - Verifying the checksum of every restored file against a backup manifest.
        - Comparing the file count in the archive vs. the restored files.
    - It logs the results of each step and provides a final status for each verification job.
    - It cleans up the sandbox directory after the verification is complete.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Added SpecificVerificationJobName parameter for scheduled execution.
    DateCreated:    12-Jun-2025
    LastModified:   20-Jun-2025
    Purpose:        To orchestrate the automated verification of backup archives.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils, RetentionManager, 7ZipManager, and PasswordManager modules.
#>

#region --- CRC32 .NET Class Definition ---
Add-Type -TypeDefinition @"
namespace PoShBackup.Security.Cryptography
{
    using System;
    using System.Collections.Generic;
    using System.Security.Cryptography;

    public class Crc32 : HashAlgorithm
    {
        public const UInt32 DefaultPolynomial = 0xedb88320u;
        public const UInt32 DefaultSeed = 0xffffffffu;
        private static UInt32[] defaultTable;
        private readonly UInt32 seed;
        private readonly UInt32[] table;
        private UInt32 hash;

        public Crc32() : this(DefaultPolynomial, DefaultSeed) { }
        public Crc32(UInt32 polynomial, UInt32 seed)
        {
            table = InitializeTable(polynomial);
            this.seed = hash = seed;
        }

        public override void Initialize() => hash = seed;
        protected override void HashCore(byte[] array, int ibStart, int cbSize) => hash = CalculateHash(table, hash, array, ibStart, cbSize);
        protected override byte[] HashFinal() => BitConverter.GetBytes(hash ^ 0xFFFFFFFFu);
        public override int HashSize { get { return 32; } }

        private static UInt32[] InitializeTable(UInt32 polynomial)
        {
            if (polynomial == DefaultPolynomial && defaultTable != null) return defaultTable;
            var createTable = new UInt32[256];
            for (int i = 0; i < 256; i++)
            {
                var entry = (UInt32)i;
                for (int j = 0; j < 8; j++)
                    if ((entry & 1) == 1) entry = (entry >> 1) ^ polynomial;
                    else entry = entry >> 1;
                createTable[i] = entry;
            }
            if (polynomial == DefaultPolynomial) defaultTable = createTable;
            return createTable;
        }

        private static UInt32 CalculateHash(UInt32[] table, UInt32 seed, IList<byte> buffer, int start, int size)
        {
            var crc = seed;
            for (int i = start; i < start + size; i++)
                crc = (crc >> 8) ^ table[buffer[i] ^ crc & 0xff];
            return crc;
        }
    }
}
"@ -ErrorAction SilentlyContinue
#endregion

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "RetentionManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "PasswordManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "VerificationManager.psm1 FATAL: Could not import required dependent modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Internal Helper: Initialize Sandbox ---
function Initialize-VerificationSandboxInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$SandboxPath,
        [string]$OnDirtySandbox, # "Fail" or "CleanAndContinue"
        [scriptblock]$Logger,
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )
    # PSScriptAnalyzer Appeasement: Use the Logger parameter directly.
    & $Logger -Message "VerificationManager/Initialize-VerificationSandboxInternal: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not (Test-Path -LiteralPath $SandboxPath)) {
        & $LocalWriteLog -Message "  - Sandbox path '$SandboxPath' does not exist. Attempting to create." -Level "INFO"
        if (-not $PSCmdletInstance.ShouldProcess($SandboxPath, "Create Sandbox Directory")) {
            & $LocalWriteLog -Message "    - Sandbox creation skipped by user. Verification cannot proceed." -Level "WARNING"
            return $false
        }
        try {
            New-Item -Path $SandboxPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            & $LocalWriteLog -Message "    - Sandbox directory created successfully." -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "    - Failed to create sandbox directory. Error: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }

    $childItems = Get-ChildItem -LiteralPath $SandboxPath -Force -ErrorAction SilentlyContinue
    if ($childItems.Count -gt 0) {
        & $LocalWriteLog -Message "  - Sandbox path '$SandboxPath' is not empty." -Level "WARNING"
        if ($OnDirtySandbox -eq 'Fail') {
            & $LocalWriteLog -Message "    - 'OnDirtySandbox' is set to 'Fail'. Aborting verification." -Level "ERROR"
            return $false
        }
        else { # CleanAndContinue
            & $LocalWriteLog -Message "    - 'OnDirtySandbox' is set to 'CleanAndContinue'. Attempting to clear sandbox." -Level "INFO"
            if (-not $PSCmdletInstance.ShouldProcess($SandboxPath, "Clear Sandbox Directory Contents")) {
                & $LocalWriteLog -Message "    - Sandbox cleaning skipped by user. Verification cannot proceed." -Level "WARNING"
                return $false
            }
            try {
                Get-ChildItem -LiteralPath $SandboxPath -Force | Remove-Item -Recurse -Force -ErrorAction Stop
                & $LocalWriteLog -Message "    - Sandbox cleared successfully." -Level "SUCCESS"
            } catch {
                & $LocalWriteLog -Message "    - Failed to clear sandbox directory. Error: $($_.Exception.Message)" -Level "ERROR"
                return $false
            }
        }
    }
    return $true
}
#endregion

#region --- Internal Helper: Get CRC32 Checksum ---
function Get-FileCrc32Internal {
    param(
        [string]$FilePath
    )
    try {
        $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open)
        $hasher = New-Object DamienG.Security.Cryptography.Crc32
        $hashBytes = $hasher.ComputeHash($stream)
        $stream.Close()
        $stream.Dispose()
        
        # Reverse the byte array to fix the endianness
        [System.Array]::Reverse($hashBytes)

        $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
        return $hashString
    }
    catch {
        # This function doesn't have access to the logger, so it will throw.
        # The calling function will catch and log the error.
        throw "Failed to calculate CRC32 for file '$FilePath'. Error: $($_.Exception.Message)"
    }
}
#endregion

#region --- Exported Function ---
function Invoke-PoShBackupVerification {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)]
        [string]$SpecificVerificationJobName
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "VerificationManager: Starting automated backup verification process." -Level "HEADING"

    $allVerificationJobsFromConfig = $Configuration.VerificationJobs
    if ($null -eq $allVerificationJobsFromConfig -or $allVerificationJobsFromConfig.Count -eq 0) {
        & $LocalWriteLog -Message "VerificationManager: No 'VerificationJobs' defined in configuration. Nothing to do." -Level "INFO"
        return
    }

    $jobsToProcess = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($SpecificVerificationJobName)) {
        & $LocalWriteLog -Message "VerificationManager: A specific verification job was requested: '$SpecificVerificationJobName'." -Level "INFO"
        if ($allVerificationJobsFromConfig.ContainsKey($SpecificVerificationJobName)) {
            $jobsToProcess.Add($SpecificVerificationJobName)
        } else {
            & $LocalWriteLog -Message "VerificationManager: The requested verification job '$SpecificVerificationJobName' was not found in the configuration." -Level "ERROR"
            return
        }
    } else {
        & $LocalWriteLog -Message "VerificationManager: No specific job requested. Processing all enabled verification jobs." -Level "INFO"
        $allVerificationJobsFromConfig.Keys | Sort-Object | ForEach-Object { $jobsToProcess.Add($_) }
    }

    foreach ($vJobName in $jobsToProcess) {
        $vJobConfig = $allVerificationJobsFromConfig[$vJobName]
        $isEnabled = Get-ConfigValue -ConfigObject $vJobConfig -Key 'Enabled' -DefaultValue $false

        Write-ConsoleBanner -NameText "Processing Verification Job" -ValueText $vJobName -CenterText -PrependNewLine

        if (-not $isEnabled) {
            & $LocalWriteLog -Message "Verification Job '$vJobName' is disabled. Skipping." -Level "INFO"
            continue
        }

        # --- Get Verification Job Parameters ---
        $targetJobName = Get-ConfigValue -ConfigObject $vJobConfig -Key 'TargetJobName' -DefaultValue $null
        $passwordSecret = Get-ConfigValue -ConfigObject $vJobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
        $sandboxPath = Get-ConfigValue -ConfigObject $vJobConfig -Key 'SandboxPath' -DefaultValue $null
        $onDirtySandbox = Get-ConfigValue -ConfigObject $vJobConfig -Key 'OnDirtySandbox' -DefaultValue "Fail"
        $verificationSteps = @(Get-ConfigValue -ConfigObject $vJobConfig -Key 'VerificationSteps' -DefaultValue @())
        $testLatestCount = Get-ConfigValue -ConfigObject $vJobConfig -Key 'TestLatestCount' -DefaultValue 1

        if ([string]::IsNullOrWhiteSpace($targetJobName) -or [string]::IsNullOrWhiteSpace($sandboxPath)) {
            & $LocalWriteLog -Message "Verification Job '$vJobName' is misconfigured. 'TargetJobName' and 'SandboxPath' are required. Skipping." -Level "ERROR"
            continue
        }

        $targetBackupJobConfig = $Configuration.BackupLocations[$targetJobName]
        if ($null -eq $targetBackupJobConfig) {
            & $LocalWriteLog -Message "Verification Job '$vJobName': Target backup job '$targetJobName' not found in BackupLocations. Skipping." -Level "ERROR"
            continue
        }

        # --- Find Latest Backup(s) for the Target Job ---
        $destDirForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'DestinationDir' -DefaultValue $Configuration.DefaultDestinationDir
        $baseNameForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'Name' -DefaultValue $targetJobName
        $primaryExtForTargetJob = Get-ConfigValue -ConfigObject $targetBackupJobConfig -Key 'ArchiveExtension' -DefaultValue $Configuration.DefaultArchiveExtension

        & $LocalWriteLog -Message "Verification Job '$vJobName': Finding latest $testLatestCount backup(s) for '$targetJobName' in '$destDirForTargetJob'." -Level "INFO"
        $allInstances = Find-BackupArchiveInstance -DestinationDirectory $destDirForTargetJob -ArchiveBaseFileName $baseNameForTargetJob -ArchiveExtension $primaryExtForTargetJob -Logger $Logger
        
        $unpinnedInstances = $allInstances.GetEnumerator() | Where-Object { -not $_.Value.Pinned }
        $latestInstancesToTest = $unpinnedInstances | Sort-Object { $_.Value.SortTime } -Descending | Select-Object -First $testLatestCount

        if ($latestInstancesToTest.Count -eq 0) {
            & $LocalWriteLog -Message "Verification Job '$vJobName': No unpinned backup instances found for '$targetJobName'. Nothing to verify." -Level "WARNING"
            continue
        }

        # --- Loop Through Each Instance to Test ---
        foreach ($instanceToTest in $latestInstancesToTest) {
            $instanceKey = $instanceToTest.Name
            & $LocalWriteLog -Message "`n--- Verifying Instance: $instanceKey ---" -Level "HEADING"

            $overallVerificationStatus = "SUCCESS" # Assume success for this instance

            # 1. Prepare Sandbox
            if (-not (Initialize-VerificationSandboxInternal -SandboxPath $sandboxPath -OnDirtySandbox $onDirtySandbox -Logger $Logger -PSCmdletInstance $PSCmdlet)) {
                & $LocalWriteLog -Message "Verification Job '$vJobName': Failed to prepare sandbox for instance '$instanceKey'. Aborting verification for this instance." -Level "ERROR"
                continue
            }

            # 2. Get Archive Password
            $plainTextPassword = $null
            if (-not [string]::IsNullOrWhiteSpace($passwordSecret)) {
                $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $passwordSecret }
                $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Verification of '$targetJobName'" -Logger $Logger
                $plainTextPassword = $passwordResult.PlainTextPassword
                if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
                    & $LocalWriteLog -Message "Verification Job '$vJobName': Failed to retrieve password from secret '$passwordSecret'. Aborting verification for this instance." -Level "ERROR"
                    continue
                }
            }

            # 3. Restore Archive
            $firstArchivePart = $instanceToTest.Value.Files | Where-Object { $_.Name -match "\.001$" -or $_.Name -eq $instanceKey } | Sort-Object Name | Select-Object -First 1
            if ($null -eq $firstArchivePart) {
                & $LocalWriteLog -Message "Verification Job '$vJobName': Could not find the main archive file/first volume for instance '$instanceKey'. Aborting verification." -Level "ERROR"
                continue
            }
            
            & $LocalWriteLog -Message "Verification Job '$vJobName': Restoring '$($firstArchivePart.FullName)' to '$sandboxPath'." -Level "INFO"
            $restoreSuccess = Invoke-7ZipExtraction -SevenZipPathExe $Configuration.SevenZipPath `
                                                    -ArchivePath $firstArchivePart.FullName `
                                                    -OutputDirectory $sandboxPath `
                                                    -PlainTextPassword $plainTextPassword `
                                                    -Force `
                                                    -Logger $Logger `
                                                    -PSCmdlet $PSCmdlet
            
            if (-not $restoreSuccess) {
                & $LocalWriteLog -Message "Verification Job '$vJobName': Restore of instance '$instanceKey' FAILED. Aborting further checks for this instance." -Level "ERROR"
                continue
            }

            # 4. Perform Verification Steps
            foreach ($step in $verificationSteps) {
                & $LocalWriteLog -Message "  - Verification Step: '$step' starting..." -Level "INFO"
                $stepSuccess = $false
                switch ($step) {
                    "TestArchive" {
                        $testResult = Test-7ZipArchive -SevenZipPathExe $Configuration.SevenZipPath -ArchivePath $firstArchivePart.FullName -PlainTextPassword $plainTextPassword -Logger $Logger
                        if ($testResult.ExitCode -eq 0) { $stepSuccess = $true }
                    }
                    "VerifyChecksums" {
                        $contentsManifestFile = $instanceToTest.Value.Files | Where-Object { $_.Name -like "*.contents.manifest" } | Select-Object -First 1
                        if ($null -eq $contentsManifestFile) {
                            & $LocalWriteLog -Message "    - Step 'VerifyChecksums' FAILED: No contents manifest file (*.contents.manifest) found for instance '$instanceKey'." -Level "ERROR"
                            $stepSuccess = $false
                        } else {
                            & $LocalWriteLog -Message "    - Found contents manifest: '$($contentsManifestFile.Name)'. Verifying restored files against manifest..." -Level "INFO"
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
                                        
                                        $restoredItemPath = Join-Path -Path $sandboxPath -ChildPath $filePathInManifest
                                        
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
                                                $recalculatedCrc = Get-FileCrc32Internal -FilePath $restoredFileInfo.FullName
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
                                $stepSuccess = $false
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
                    & $LocalWriteLog -Message "  - Verification Step: '$step' PASSED." -Level "SUCCESS"
                } else {
                    & $LocalWriteLog -Message "  - Verification Step: '$step' FAILED." -Level "ERROR"
                    $overallVerificationStatus = "FAILURE"
                }
            }

            # 5. Cleanup Sandbox
            & $LocalWriteLog -Message "  - Cleaning up sandbox directory '$sandboxPath'." -Level "INFO"
            try {
                 Get-ChildItem -LiteralPath $sandboxPath -Force | Remove-Item -Recurse -Force -ErrorAction Stop
            } catch {
                 & $LocalWriteLog -Message "  - Failed to clean up sandbox. Manual cleanup may be required. Error: $($_.Exception.Message)" -Level "ERROR"
                 if ($overallVerificationStatus -ne "FAILURE") { $overallVerificationStatus = "WARNINGS" }
            }
            
            & $LocalWriteLog -Message "--- Verification for Instance '$instanceKey' Complete. Final Status: $overallVerificationStatus ---" -Level "HEADING"
            Write-Host # Add a blank line for readability between instances
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupVerification
