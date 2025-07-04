# Modules\Managers\VerificationManager.psm1
<#
.SYNOPSIS
    Manages the automated verification of PoSh-Backup archives by restoring them
    to a sandbox environment and performing integrity checks.
.DESCRIPTION
    This module provides the core functionality for the Automated Backup Verification feature.
    It has been refactored into a facade that orchestrates the verification process by
    lazy-loading and calling specialised sub-modules for each stage of the operation:
    - 'BackupFinder.psm1': Finds the target backup instances to be verified.
    - 'SandboxManager.psm1': Manages the creation, preparation, and cleanup of the sandbox.
    - 'ArchiveRestorer.psm1': Handles restoring the archive to the sandbox.
    - 'IntegrityChecker.psm1': Performs the configured verification steps.

    The main exported function, 'Invoke-PoShBackupVerification', sequences these calls to
    provide a complete, end-to-end verification workflow.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.2.0 # Refactored to lazy-load sub-modules.
    DateCreated:    12-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate the automated verification of backup archives.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- CRC32 .NET Class Definition ---
# This class needs to be loaded here so it's available to the sub-modules.
Add-Type -TypeDefinition @"
namespace DamienG.Security.Cryptography
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

        $targetJobName = Get-ConfigValue -ConfigObject $vJobConfig -Key 'TargetJobName' -DefaultValue $null
        if ([string]::IsNullOrWhiteSpace($targetJobName)) {
            & $LocalWriteLog -Message "Verification Job '$vJobName' is misconfigured. 'TargetJobName' is required. Skipping." -Level "ERROR"
            continue
        }
        $targetBackupJobConfig = Get-ConfigValue -ConfigObject $Configuration.BackupLocations -Key $targetJobName -DefaultValue $null
        if ($null -eq $targetBackupJobConfig) {
            & $LocalWriteLog -Message "Verification Job '$vJobName': Target backup job '$targetJobName' not found in BackupLocations. Skipping." -Level "ERROR"
            continue
        }

        $effectiveTargetJobConfig = try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Core\ConfigManager.psm1") -Force -ErrorAction Stop
            $dummyReportDataRef = [ref]@{ JobName = $targetJobName }
            Get-PoShBackupJobEffectiveConfiguration -JobConfig $targetBackupJobConfig -GlobalConfig $Configuration -CliOverrides @{} -JobReportDataRef $dummyReportDataRef -Logger $Logger
        } catch { & $LocalWriteLog -Message "[ERROR] VerificationManager: Failed to resolve effective config for target job '$targetJobName'. Error: $($_.Exception.Message)" -Level "ERROR"; continue }

        # 1. Find the target backup instances to verify
        $instancesToTest = try {
            Import-Module -Name (Join-Path $PSScriptRoot "VerificationManager\BackupFinder.psm1") -Force -ErrorAction Stop
            Find-VerificationTarget -VerificationJobName $vJobName -VerificationJobConfig $vJobConfig -GlobalConfig $Configuration -Logger $Logger
        } catch { & $LocalWriteLog -Message "[ERROR] VerificationManager: Could not load or run the BackupFinder module. Skipping job '$vJobName'. Error: $($_.Exception.Message)" -Level "ERROR"; continue }

        if ($instancesToTest.Count -eq 0) { continue }

        # 2. Loop through each instance and perform the verification workflow
        foreach ($instance in $instancesToTest) {
            $instanceKey = $instance.Name
            & $LocalWriteLog -Message "`n--- Verifying Instance: $instanceKey ---" -Level "HEADING"
            $overallVerificationStatus = "SUCCESS"

            $sandboxPath = Get-ConfigValue -ConfigObject $vJobConfig -Key 'SandboxPath' -DefaultValue $null
            $onDirtySandbox = Get-ConfigValue -ConfigObject $vJobConfig -Key 'OnDirtySandbox' -DefaultValue "Fail"

            try {
                # 2a. Prepare Sandbox
                Import-Module -Name (Join-Path $PSScriptRoot "VerificationManager\SandboxManager.psm1") -Force -ErrorAction Stop
                if (-not (Initialize-VerificationSandbox -SandboxPath $sandboxPath -OnDirtySandbox $onDirtySandbox -Logger $Logger -PSCmdletInstance $PSCmdlet)) {
                    throw "Failed to prepare sandbox for instance '$instanceKey'."
                }

                # 2b. Restore Archive
                $firstArchivePart = $instance.Value.Files | Where-Object { $_.Name -match '\.001$' -or $_.Name -eq $instanceKey } | Sort-Object Name | Select-Object -First 1
                if ($null -eq $firstArchivePart) { throw "Could not find the main archive file/first volume for instance '$instanceKey'." }

                Import-Module -Name (Join-Path $PSScriptRoot "VerificationManager\ArchiveRestorer.psm1") -Force -ErrorAction Stop
                $restoreResult = Invoke-PoShBackupRestoreForVerification -ArchiveToRestorePath $firstArchivePart.FullName `
                    -SandboxPath $sandboxPath -SevenZipPath $Configuration.SevenZipPath `
                    -PasswordSecretName (Get-ConfigValue -ConfigObject $vJobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null) `
                    -TargetJobName $targetJobName -Logger $Logger -PSCmdletInstance $PSCmdlet

                if (-not $restoreResult.Success) { throw "Restore of '$($firstArchivePart.FullName)' FAILED." }

                # 2c. Perform Integrity Checks on restored files
                Import-Module -Name (Join-Path $PSScriptRoot "VerificationManager\IntegrityChecker.psm1") -Force -ErrorAction Stop
                $checksSuccess = Invoke-PoShBackupIntegrityCheck -VerificationJobConfig $vJobConfig `
                    -EffectiveTargetJobConfig $effectiveTargetJobConfig -InstanceToTest $instance -SandboxPath $sandboxPath `
                    -SevenZipPath $Configuration.SevenZipPath -PlainTextPassword $restoreResult.PlainTextPassword -Logger $Logger

                if (-not $checksSuccess) { $overallVerificationStatus = "FAILURE" }
            }
            catch {
                $advice = "ADVICE: This could be due to a missing sub-module file in 'Modules\Managers\VerificationManager\'. Please check the error message for specifics."
                & $LocalWriteLog -Message "[ERROR] Verification Job '$vJobName': A critical error occurred during instance verification. Error: $($_.Exception.Message)" -Level "ERROR"
                & $LocalWriteLog -Message $advice -Level "ADVICE"
                $overallVerificationStatus = "FAILURE"
            }
            finally {
                # 2d. Cleanup Sandbox
                try {
                    Import-Module -Name (Join-Path $PSScriptRoot "VerificationManager\SandboxManager.psm1") -Force -ErrorAction Stop
                    Clear-VerificationSandbox -SandboxPath $sandboxPath -Logger $Logger
                } catch { & $LocalWriteLog -Message "[ERROR] VerificationManager: Failed to load SandboxManager for cleanup. Manual cleanup may be required." -Level "ERROR" }
            }

            & $LocalWriteLog -Message "--- Verification for Instance '$instanceKey' Complete. Final Status: $overallVerificationStatus ---" -Level "HEADING"
            Write-Host
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupVerification
