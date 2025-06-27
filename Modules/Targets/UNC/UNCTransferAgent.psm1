# Modules\Targets\UNC\UNCTransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for UNC.Target.psm1. Handles the actual file transfer operation.
.DESCRIPTION
    This module provides the 'Start-PoShBackupUNCCopy' function. It is responsible for
    transferring a single file to a UNC destination. It contains the logic to decide
    whether to use the standard 'Copy-Item' cmdlet or the more resilient 'robocopy.exe'
    based on the target's configuration. It includes the helper functions for building
    the Robocopy argument list and invoking the process.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the UNC file transfer logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Private Helper: Build Robocopy Arguments ---
function Get-RobocopyArgument {
    param(
        [string]$SourceFile,
        [string]$DestinationDirectory,
        [hashtable]$RobocopySettings
    )

    $sourceDir = Split-Path -Path $SourceFile -Parent
    $fileNameOnly = Split-Path -Path $SourceFile -Leaf
    
    $argumentsList = [System.Collections.Generic.List[string]]::new()
    $argumentsList.Add("`"$sourceDir`"")
    $argumentsList.Add("`"$DestinationDirectory`"")
    $argumentsList.Add("`"$fileNameOnly`"")

    if ($null -eq $RobocopySettings) { $RobocopySettings = @{} }

    $copyFlags = if ($RobocopySettings.ContainsKey('CopyFlags')) { $RobocopySettings.CopyFlags } else { "DAT" }
    $argumentsList.Add("/COPY:$copyFlags")
    $dirCopyFlags = if ($RobocopySettings.ContainsKey('DirectoryCopyFlags')) { $RobocopySettings.DirectoryCopyFlags } else { "T" }
    $argumentsList.Add("/DCOPY:$dirCopyFlags")
    $retries = if ($RobocopySettings.ContainsKey('Retries')) { $RobocopySettings.Retries } else { 5 }
    $argumentsList.Add("/R:$retries")
    $waitTime = if ($RobocopySettings.ContainsKey('WaitTime')) { $RobocopySettings.WaitTime } else { 15 }
    $argumentsList.Add("/W:$waitTime")

    if ($RobocopySettings.ContainsKey('MultiThreadedCount') -and $RobocopySettings.MultiThreadedCount -is [int] -and $RobocopySettings.MultiThreadedCount -gt 0) {
        $argumentsList.Add("/MT:$($RobocopySettings.MultiThreadedCount)")
    }
    if ($RobocopySettings.ContainsKey('InterPacketGap') -and $RobocopySettings.InterPacketGap -is [int] -and $RobocopySettings.InterPacketGap -gt 0) {
        $argumentsList.Add("/IPG:$($RobocopySettings.InterPacketGap)")
    }
    if ($RobocopySettings.ContainsKey('UnbufferedIO') -and $RobocopySettings.UnbufferedIO -eq $true) {
        $argumentsList.Add("/J")
    }

    $argumentsList.Add("/NS"); $argumentsList.Add("/NC"); $argumentsList.Add("/NFL")
    $argumentsList.Add("/NDL"); $argumentsList.Add("/NP"); $argumentsList.Add("/NJH"); $argumentsList.Add("/NJS")
    
    if ($RobocopySettings.ContainsKey('Verbose') -and $RobocopySettings.Verbose -eq $true) {
        $argumentsList.Add("/V")
    }

    return $argumentsList.ToArray()
}
#endregion

#region --- Private Helper: Execute Robocopy Transfer ---
function Invoke-RobocopyTransfer {
    [CmdletBinding()]
    param(
        [string]$SourceFile,
        [string]$DestinationDirectory,
        [hashtable]$RobocopySettings,
        [scriptblock]$Logger
    )
    
    & $Logger -Message "UNCTransferAgent/Invoke-RobocopyTransfer: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    try {
        $arguments = Get-RobocopyArgument -SourceFile $SourceFile -DestinationDirectory $DestinationDirectory -RobocopySettings $RobocopySettings
        & $LocalWriteLog -Message "      - Robocopy command: robocopy.exe $($arguments -join ' ')" -Level "DEBUG"
        
        $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -lt 8) {
            return @{ Success = $true; ExitCode = $process.ExitCode }
        }
        else {
            return @{ Success = $false; ExitCode = $process.ExitCode; ErrorMessage = "Robocopy failed with exit code $($process.ExitCode)." }
        }
    }
    catch {
        return @{ Success = $false; ExitCode = -1; ErrorMessage = "Failed to execute Robocopy process. Error: $($_.Exception.Message)" }
    }
}
#endregion

function Start-PoShBackupUNCCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$FullRemoteDestinationPath,
        [Parameter(Mandatory = $true)]
        [bool]$UseRobocopy,
        [Parameter(Mandatory = $false)]
        [hashtable]$RobocopySettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "UNCTransferAgent/Start-PoShBackupUNCCopy: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if (-not $PSCmdletInstance.ShouldProcess($FullRemoteDestinationPath, "Copy File to UNC Path")) {
        return @{ Success = $false; ErrorMessage = "File copy to '$FullRemoteDestinationPath' skipped by user." }
    }
    
    try {
        if ($UseRobocopy) {
            & $LocalWriteLog -Message "      - UNCTransferAgent: Copying file using Robocopy..." -Level "INFO"
            $remoteFinalDir = Split-Path -Path $FullRemoteDestinationPath -Parent
            $roboResult = Invoke-RobocopyTransfer -SourceFile $LocalSourcePath -DestinationDirectory $remoteFinalDir -RobocopySettings $RobocopySettings -Logger $Logger
            if (-not $roboResult.Success) { throw $roboResult.ErrorMessage }
        }
        else {
            & $LocalWriteLog -Message "      - UNCTransferAgent: Copying file using Copy-Item..." -Level "INFO"
            Copy-Item -LiteralPath $LocalSourcePath -Destination $FullRemoteDestinationPath -Force -ErrorAction Stop
        }
        return @{ Success = $true }
    }
    catch {
        return @{ Success = $false; ErrorMessage = "Failed to copy file to '$FullRemoteDestinationPath'. Error: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Start-PoShBackupUNCCopy
