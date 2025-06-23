# Modules\SnapshotProviders\HyperV.Snapshot.psm1
<#
.SYNOPSIS
    PoSh-Backup Snapshot Provider for Microsoft Hyper-V.
.DESCRIPTION
    This module implements the snapshot provider interface for creating and managing
    Hyper-V VM checkpoints (snapshots). It is designed to be called by the main
    SnapshotManager.psm1 facade and should not be invoked directly.

    The module's functions handle:
    - Creating application-consistent checkpoints of a specified VM.
    - Mounting the checkpoint's VHD(X) files, bringing them online, explicitly assigning
      drive letters, and making the data accessible for backup.
    - Providing the paths to the mounted data.
    - Cleaning up by removing assigned drive letters, dismounting the VHD(X) files,
      and removing the VM checkpoint.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Enhanced -Simulate output to be more descriptive.
    DateCreated:    10-Jun-2025
    LastModified:   23-Jun-2025
    Purpose:        Hyper-V snapshot provider implementation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires the 'Hyper-V' PowerShell module to be installed on the machine
                    running PoSh-Backup.
                    The user running PoSh-Backup must have appropriate administrative
                    permissions on the Hyper-V host to manage VMs and snapshots.
#>

#region --- Internal Helper: Get-PSCredentialFromSecret ---
# This helper is self-contained to avoid dependencies beyond SecretManagement.
function Get-PSCredentialFromSecretInternal-HyperV {
    param(
        [string]$SecretName,
        [scriptblock]$Logger
    )

    & $Logger -Message "HyperV.Snapshot/Get-PSCredentialFromSecretInternal-HyperV: Logger active for secret '$SecretName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) { return $null }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "PowerShell SecretManagement module not found. Cannot retrieve Hyper-V credentials."
    }
    try {
        $secretValue = Get-Secret -Name $SecretName -ErrorAction Stop
        if ($null -ne $secretValue -and $secretValue.Secret -is [System.Management.Automation.PSCredential]) {
            return $secretValue.Secret
        }
        elseif ($null -ne $secretValue) {
            throw "Secret '$SecretName' is not a PSCredential object as required."
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] HyperV.Snapshot Provider: Failed to retrieve credential secret '{0}'. Error: {1}" -f $SecretName, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- Internal Helper: Get-AvailableDriveLetter ---
function Get-AvailableDriveLetterInternal-HyperV {
    param(
        [scriptblock]$Logger
    )

    & $Logger -Message "HyperV.Snapshot/Get-AvailableDriveLetterInternal-HyperV: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "DEBUG") & $Logger -Message $MessageParam -Level $LevelParam }

    $existingDriveLetters = (Get-PSDrive -PSProvider 'FileSystem').Name
    foreach ($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K','J','I','H','G','F','E','D') {
        if ($letter -notin $existingDriveLetters) {
            & $LocalWriteLog -Message "HyperV.Snapshot Provider: Found available drive letter: $letter"
            return $letter
        }
    }
    & $LocalWriteLog -Message "HyperV.Snapshot Provider: Could not find an available drive letter from D-Z." -Level "WARNING"
    return $null
}
#endregion

#region --- Provider Implementation Functions (Internal to SnapshotManager) ---

function New-PoShBackupSnapshotInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceToSnapshot, # The VM Name
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderSettings,
        [Parameter(Mandatory = $false)]
        [string]$CredentialsSecretName,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "HyperV.Snapshot/New-PoShBackupSnapshotInternal: Logger active for Job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "HyperV.Snapshot Provider: Initializing snapshot creation for VM '$ResourceToSnapshot'." -Level "DEBUG"

    $result = @{
        Success             = $false
        SessionId           = $null
        ProviderType        = "HyperV"
        VMName              = $ResourceToSnapshot
        SnapshotObject      = $null
        MountedVhdInfo      = @{} # Maps VHD path to @{Disk=[DiskObj]; AssignedLetter='G'; AssignedPartitionNumber=2}
        ErrorMessage        = "An unknown error occurred."
    }

    if (-not (Get-Module -Name Hyper-V -ListAvailable)) {
        $result.ErrorMessage = "The 'Hyper-V' PowerShell module is not installed. This is required for Hyper-V snapshot operations."
        & $LocalWriteLog -Message "[ERROR] HyperV.Snapshot Provider: $($result.ErrorMessage)" -Level "ERROR"
        return $result
    }
    Import-Module -Name Hyper-V -ErrorAction Stop

    $hyperVHost = if ($ProviderSettings.ContainsKey('ComputerName')) { $ProviderSettings.ComputerName } else { $env:COMPUTERNAME }
    $credential = $null
    if (-not [string]::IsNullOrWhiteSpace($CredentialsSecretName)) {
        $credential = Get-PSCredentialFromSecretInternal-HyperV -SecretName $CredentialsSecretName -Logger $Logger
        if ($null -eq $credential) {
            $result.ErrorMessage = "Failed to retrieve Hyper-V credentials from secret '$CredentialsSecretName'."
            return $result
        }
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Would connect to Hyper-V host '$hyperVHost' and create an application-consistent checkpoint for VM '$ResourceToSnapshot'. The virtual disks from this checkpoint would then be mounted to make the data available for backup." -Level "SIMULATE"
        $result.Success = $true
        $result.SessionId = [guid]::NewGuid().ToString()
        $result.MountedVhdInfo = @{ "C:\Simulated\Path\To\VM.vhdx" = @{ Disk = "SIMULATED_DISK"; AssignedLetter = "G"; AssignedPartitionNumber = 2 } }
        $result.ErrorMessage = $null
        return $result
    }

    try {
        $getVmParams = @{ Name = $ResourceToSnapshot; ComputerName = $hyperVHost; ErrorAction = 'Stop' }
        if ($null -ne $credential) { $getVmParams.Credential = $credential }
        $vm = Get-VM @getVmParams
        if ($null -eq $vm) { throw "Virtual Machine '$ResourceToSnapshot' not found on host '$hyperVHost'." }

        if (-not $PSCmdlet.ShouldProcess($vm.Name, "Create Application-Consistent Checkpoint")) {
            $result.ErrorMessage = "Checkpoint creation for VM '$($vm.Name)' skipped by user."
            & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
            return $result
        }

        & $LocalWriteLog -Message "HyperV.Snapshot Provider: Creating application-consistent checkpoint for VM '$($vm.Name)'..." -Level "INFO"
        
        $checkpointParams = @{ VM = $vm; ErrorAction = 'Stop'; Passthru = $true }
        $snapshot = Checkpoint-VM @checkpointParams

        if ($null -eq $snapshot) { throw "Checkpoint-VM cmdlet did not return a snapshot object." }

        $result.SnapshotObject = $snapshot
        $result.SessionId = $snapshot.Id.ToString()
        & $LocalWriteLog -Message "HyperV.Snapshot Provider: Successfully created checkpoint '$($snapshot.Name)' (ID: $($snapshot.Id))." -Level "SUCCESS"

        & $LocalWriteLog -Message "HyperV.Snapshot Provider: Mounting VHD(X) files from checkpoint..." -Level "INFO"
        $snapshotVhdPaths = $snapshot.HardDrives.Path
        foreach ($vhdPath in $snapshotVhdPaths) {
            if (-not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) {
                throw "VHD file '$vhdPath' from snapshot does not exist or is inaccessible from this machine."
            }
            if (-not $PSCmdlet.ShouldProcess($vhdPath, "Mount VHD (Read-Only)")) {
                $result.ErrorMessage = "VHD mount for '$vhdPath' skipped by user."
                throw $result.ErrorMessage
            }
            & $LocalWriteLog -Message "  - Mounting '$vhdPath' as read-only..." -Level "DEBUG"
            $mountResult = Mount-VHD -Path $vhdPath -ReadOnly -Passthru -ErrorAction Stop
            $disk = Get-Disk -Number $mountResult.DiskNumber
            $result.MountedVhdInfo[$vhdPath] = @{ Disk = $disk; AssignedLetter = $null; AssignedPartitionNumber = $null }
        }

        $getPathsParams = @{ SnapshotSession = $result; Logger = $Logger }
        $discoveredPaths = Get-PoShBackupSnapshotPathsInternal @getPathsParams

        if ($discoveredPaths.Count -eq 0) {
            throw "Snapshot was created and VHD(s) were mounted, but no readable volumes with drive letters were found or could be assigned. This can happen if the guest VM uses a non-Windows filesystem (e.g., Linux ext4), if the host OS SAN policy prevents automount, or if no available drive letters (D-Z) were found."
        }

        $result.Success = $true
        $result.ErrorMessage = $null
    }
    catch {
        & $LocalWriteLog -Message "HyperV.Snapshot Provider: An error occurred during snapshot creation or mount. Error: $($_.Exception.Message)" -Level "ERROR"
        $result.ErrorMessage = $_.Exception.Message
        # Attempt to clean up a partial success (e.g., snapshot created but mount failed)
        if ($null -ne $result.SnapshotObject) {
            & $LocalWriteLog -Message "HyperV.Snapshot Provider: Attempting to clean up partially created snapshot..." -Level "WARNING"
            $removeParams = @{ SnapshotSession = $result; PSCmdlet = $PSCmdlet }
            Remove-PoShBackupSnapshotInternal @removeParams
        }
        return $result
    }
    return $result
}

function Get-PoShBackupSnapshotPathsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SnapshotSession,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $mountedPaths = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $SnapshotSession.MountedVhdInfo) {
        foreach ($vhdPathKey in $SnapshotSession.MountedVhdInfo.Keys) {
            $mountInfo = $SnapshotSession.MountedVhdInfo[$vhdPathKey]
            $disk = $mountInfo.Disk
            & $LocalWriteLog -Message "  - [DIAGNOSTIC] Processing mounted disk #$($disk.Number) from VHD '$vhdPathKey'. IsOffline: $($disk.IsOffline), IsReadOnly: $($disk.IsReadOnly)." -Level "INFO"
            try { $disk | Set-Disk -IsOffline $false -ErrorAction Stop | Out-Null }
            catch { & $LocalWriteLog -Message "    - [WARNING] HyperV.Snapshot Provider: Failed to bring disk #$($disk.Number) online. Error: $($_.Exception.Message)" -Level "WARNING"; continue }
            Start-Sleep -Seconds 2

            $partitions = Get-Partition -DiskNumber $disk.Number
            & $LocalWriteLog -Message "  - [DIAGNOSTIC] Found $($partitions.Count) partition(s) on disk #$($disk.Number)." -Level "INFO"
            $partitions | ForEach-Object { & $LocalWriteLog -Message ("    - [DIAGNOSTIC]   -> Partition #$($_.PartitionNumber), Type: $($_.Type), Size: $([math]::Round($_.Size / 1GB, 2)) GB, DriveLetter: '$($_.DriveLetter)', IsActive: $($_.IsActive), IsBoot: $($_.IsBoot)") -Level "INFO" }

            $mainPartition = $partitions | Where-Object { $_.Type -notin 'Recovery', 'System', 'Reserved', 'Unknown' } | Sort-Object Size -Descending | Select-Object -First 1
            
            if ($null -eq $mainPartition) {
                & $LocalWriteLog -Message "    - [WARNING] HyperV.Snapshot Provider: Could not find a suitable main data partition on disk $($disk.Number)." -Level "WARNING"
                continue
            }
            & $LocalWriteLog -Message "  - [DIAGNOSTIC] Selected main partition #$($mainPartition.PartitionNumber) for drive letter assignment." -Level "INFO"
            
            if ($mainPartition.DriveLetter) {
                $mountedPaths.Add("$($mainPartition.DriveLetter):")
                & $LocalWriteLog -Message "    - [INFO] Found existing drive letter '$($mainPartition.DriveLetter):' for partition $($mainPartition.PartitionNumber) on disk $($disk.Number)." -Level "INFO"
            } else {
                & $LocalWriteLog -Message "    - [INFO] Partition #$($mainPartition.PartitionNumber) on disk $($disk.Number) has no drive letter. Attempting to assign one..." -Level "INFO"
                $availableLetter = Get-AvailableDriveLetterInternal-HyperV -Logger $Logger
                if ($availableLetter) {
                    & $LocalWriteLog -Message "    - [DIAGNOSTIC] Available drive letter found: '$($availableLetter)'. Attempting to assign to partition #$($mainPartition.PartitionNumber)..." -Level "INFO"
                    try {
                        Set-Partition -DiskNumber $disk.Number -PartitionNumber $mainPartition.PartitionNumber -NewDriveLetter $availableLetter -ErrorAction Stop | Out-Null
                        $mountedPaths.Add("$($availableLetter):")
                        $mountInfo.AssignedLetter = $availableLetter
                        $mountInfo.AssignedPartitionNumber = $mainPartition.PartitionNumber
                        & $LocalWriteLog -Message "      - [SUCCESS] HyperV.Snapshot Provider: Successfully assigned drive letter '$($availableLetter):' to partition #$($mainPartition.PartitionNumber)." -Level "SUCCESS"
                    } catch {
                        & $LocalWriteLog -Message "      - [CRITICAL ERROR] FAILED to assign drive letter '$($availableLetter):' to partition #$($mainPartition.PartitionNumber). Exception: $($_.ToString())" -Level "ERROR"
                    }
                } else {
                    & $LocalWriteLog -Message "    - [WARNING] No available drive letters found (D-Z)." -Level "WARNING"
                }
            }
        }
    }
    return $mountedPaths
}

function Remove-PoShBackupSnapshotInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SnapshotSession,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)]
        [switch]$IsSimulateMode
    )

    if ($IsSimulateMode.IsPresent) {
        Write-Verbose "SIMULATE: HyperV.Snapshot Provider: Would clean up snapshot for VM '$($SnapshotSession.VMName)'."
        Write-Verbose "SIMULATE:   - Any manually assigned drive letters would be removed."
        Write-Verbose "SIMULATE:   - All mounted VHD(X) files for this session would be dismounted."
        Write-Verbose "SIMULATE:   - The Hyper-V checkpoint named '$($SnapshotSession.SnapshotObject.Name)' would be removed."
        return
    }

    $snapshotObject = $SnapshotSession.SnapshotObject
    $mountedVhdInfo = $SnapshotSession.MountedVhdInfo

    if ($null -ne $mountedVhdInfo) {
        foreach ($vhdPath in $mountedVhdInfo.Keys) {
            $mountInfo = $mountedVhdInfo[$vhdPath]
            # First, remove any manually assigned drive letter
            if (-not [string]::IsNullOrWhiteSpace($mountInfo.AssignedLetter)) {
                if ($PSCmdlet.ShouldProcess("Partition #$($mountInfo.AssignedPartitionNumber) on Disk #$($mountInfo.Disk.Number)", "Remove Assigned Drive Letter '$($mountInfo.AssignedLetter)'")) {
                    Write-Verbose "HyperV.Snapshot Provider: Removing assigned drive letter '$($mountInfo.AssignedLetter):'."
                    try {
                        Remove-PartitionAccessPath -DiskNumber $mountInfo.Disk.Number -PartitionNumber $mountInfo.AssignedPartitionNumber -DriveLetter $mountInfo.AssignedLetter -ErrorAction Stop | Out-Null
                    } catch {
                        Write-Warning "HyperV.Snapshot Provider: Failed to remove assigned drive letter '$($mountInfo.AssignedLetter)'. Manual cleanup may be required. Error: $($_.Exception.Message)"
                    }
                }
            }

            # Then, dismount the VHD
            if ($PSCmdlet.ShouldProcess($vhdPath, "Dismount VHD")) {
                Write-Verbose "HyperV.Snapshot Provider: Dismounting VHD '$vhdPath'."
                try {
                    Dismount-VHD -Path $vhdPath -ErrorAction Stop
                }
                catch {
                    Write-Warning "HyperV.Snapshot Provider: Failed to dismount VHD '$vhdPath'. Manual cleanup may be required. Error: $($_.Exception.Message)"
                }
            }
        }
    }

    if ($null -ne $snapshotObject) {
        if ($PSCmdlet.ShouldProcess($snapshotObject.Name, "Remove VM Checkpoint")) {
            Write-Verbose "HyperV.Snapshot Provider: Removing VM checkpoint '$($snapshotObject.Name)'."
            try {
                Remove-VMSnapshot -VMSnapshot $snapshotObject -ErrorAction Stop
            }
            catch {
                Write-Warning "HyperV.Snapshot Provider: Failed to remove VM checkpoint '$($snapshotObject.Name)'. Manual cleanup required. Error: $($_.Exception.Message)"
            }
        }
    }
}
#endregion

Export-ModuleMember -Function New-PoShBackupSnapshotInternal, Get-PoShBackupSnapshotPathsInternal, Remove-PoShBackupSnapshotInternal
