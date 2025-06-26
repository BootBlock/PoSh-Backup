# Modules\ScriptModes\Diagnostics\ConfigTester.psm1
<#
.SYNOPSIS
    A sub-module for Diagnostics.psm1. Handles the `-TestConfig` script mode.
.DESCRIPTION
    This module contains the logic for performing a comprehensive test of the PoSh-Backup
    configuration. It displays key global settings, lists defined jobs and sets, shows
    a dependency graph, and simulates the post-run action determination.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle the -TestConfig diagnostic mode.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\Diagnostics
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics\ConfigTester.psm1: Could not import required modules. Error: $($_.Exception.Message)"
}
#endregion

#region --- Internal Helper: Draw Formatted Table ---
function Write-FormattedTableRowInternal {
    param(
        [hashtable]$ColumnWidths,
        [hashtable]$RowData,
        [hashtable]$ColorMap = @{}
    )

    Write-Host "  " -NoNewline

    $columnOrder = @('JobName', 'Enabled', 'Sources', 'DependsOn', 'Notes')

    foreach ($colName in $columnOrder) {
        $text = if ($RowData.ContainsKey($colName)) { [string]$RowData[$colName] } else { "" }
        $width = $ColumnWidths[$colName]
        $color = if ($ColorMap.ContainsKey($colName)) { $ColorMap[$colName] } else { $Global:ColourValue }

        if ($text.Length -gt $width) {
            $text = $text.Substring(0, $width - 3) + "..."
        }

        Write-Host $text.PadRight($width) -NoNewline -ForegroundColor $color
        Write-Host "  " -NoNewline
    }
    Write-Host
}
#endregion

#region --- Internal Helper: Format Dependency Graph ---
function Format-DependencyGraphInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DependencyMap
    )

    $outputLines = [System.Collections.Generic.List[string]]::new()
    if ($DependencyMap.Count -eq 0) {
        $outputLines.Add("    No jobs defined.")
        return $outputLines
    }

    $allJobs = $DependencyMap.Keys
    $allDependencies = @($DependencyMap.Values | ForEach-Object { $_ }) | Select-Object -Unique

    if ($allDependencies.Count -eq 0) {
        $outputLines.Add("    No job dependencies are defined in the configuration.")
        return $outputLines
    }

    $topLevelJobs = $allJobs | Where-Object { $_ -notin $allDependencies } | Sort-Object
    $processedJobs = @{}

    function Write-DependencyNode {
        param(
            [string]$JobName,
            [int]$IndentLevel,
            [hashtable]$Map,
            [hashtable]$Processed,
            [ref]$OutputListRef
        )

        $indent = "    " + ("  " * $IndentLevel)
        $arrow = if ($IndentLevel -gt 0) { "└─ " } else { "" }
        $line = "$indent$arrow$JobName"

        if ($Processed.ContainsKey($JobName)) {
            $OutputListRef.Value.Add("$line (see above)")
            return
        }

        $OutputListRef.Value.Add($line)
        $Processed[$JobName] = $true

        if ($Map.ContainsKey($JobName)) {
            $dependencies = $Map[$JobName]
            foreach ($dep in $dependencies) {
                Write-DependencyNode -JobName $dep -IndentLevel ($IndentLevel + 1) -Map $Map -Processed $Processed -OutputListRef $OutputListRef
            }
        }
    }

    foreach ($job in $topLevelJobs) {
        Write-DependencyNode -JobName $job -IndentLevel 0 -Map $DependencyMap -Processed $processedJobs -OutputListRef ([ref]$outputLines)
    }

    $remainingJobs = $allJobs | Where-Object { -not $processedJobs.ContainsKey($_) } | Sort-Object
    if ($remainingJobs.Count -gt 0) {
        $outputLines.Add("")
        $outputLines.Add("    (Jobs involved in cycles or that are only dependencies)")
        foreach ($job in $remainingJobs) {
            Write-DependencyNode -JobName $job -IndentLevel 0 -Map $DependencyMap -Processed $processedJobs -OutputListRef ([ref]$outputLines)
        }
    }
    
    return $outputLines
}
#endregion

function Invoke-PoShBackupConfigTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    Write-ConsoleBanner -NameText "Configuration Test Mode" -ValueText "Summary" -CenterText -PrependNewLine

    & $LocalWriteLog -Message "  Configuration file(s) loaded and validated successfully from:" -Level "SUCCESS"
    & $LocalWriteLog -Message "    $($ActualConfigFile)" -Level "SUCCESS"
    if ($ConfigLoadResult.UserConfigLoaded) {
        & $LocalWriteLog -Message "          (User overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
    }

    Write-ConsoleBanner -NameText "Key Global Settings" -BannerWidth 78 -CenterText -PrependNewLine
    $sevenZipPathDisplay = if ($Configuration.ContainsKey('SevenZipPath')) { $Configuration.SevenZipPath } else { 'N/A' }
    Write-NameValue "7-Zip Path                " $sevenZipPathDisplay
    $defaultDestDirDisplay = if ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }
    Write-NameValue "Default Staging Dir       " $defaultDestDirDisplay
    $delLocalArchiveDisplay = if ($Configuration.ContainsKey('DeleteLocalArchiveAfterSuccessfulTransfer')) { $Configuration.DeleteLocalArchiveAfterSuccessfulTransfer } else { '$true (default)' }
    Write-NameValue "Delete Local Post Transfer" $delLocalArchiveDisplay
    $logDirDisplay = if ($Configuration.ContainsKey('LogDirectory')) { $Configuration.LogDirectory } else { 'N/A (File Logging Disabled)' }
    Write-NameValue "Log Directory             " $logDirDisplay
    $vssEnabledDisplayGlobal = if ($Configuration.ContainsKey('EnableVSS')) { $Configuration.EnableVSS } else { $false }
    Write-NameValue "Default VSS Enabled       " $vssEnabledDisplayGlobal
    $treatWarningsAsSuccessDisplayGlobal = if ($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }
    Write-NameValue "Treat 7-Zip Warns as OK   " $treatWarningsAsSuccessDisplayGlobal

    if ($Configuration.ContainsKey('BackupTargets') -and $Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.Count -gt 0) {
        Write-ConsoleBanner -NameText "Defined Backup Targets" -BannerWidth 78 -CenterText -PrependNewLine
        foreach ($targetNameKey in ($Configuration.BackupTargets.Keys | Sort-Object)) {
            $targetConfType = $Configuration.BackupTargets[$targetNameKey].Type
            Write-NameValue "Target" "$targetNameKey (Type: $targetConfType)"
        }
    }

    if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
        Write-ConsoleBanner -NameText "Defined Backup Jobs" -BannerWidth 78 -CenterText -PrependNewLine
    
        $jobDetailsList = [System.Collections.Generic.List[hashtable]]::new()
        $maxWidths = @{ JobName = 10; Enabled = 7; Sources = 7; DependsOn = 10; Notes = 5 }

        foreach ($jobNameKey in ($Configuration.BackupLocations.Keys | Sort-Object)) {
            $jobConf = $Configuration.BackupLocations[$jobNameKey]
        
            $notes = [System.Collections.Generic.List[string]]::new()
            if ((@(Get-ConfigValue -ConfigObject $jobConf -Key 'TargetNames' -DefaultValue @())).Count -eq 0) { $notes.Add("Local Only") }
            if ((Get-ConfigValue -ConfigObject $jobConf -Key 'EnableVSS' -DefaultValue $Configuration.EnableVSS) -ne $true) { $notes.Add("VSS Disabled") }
            if ((Get-ConfigValue -ConfigObject $jobConf -Key 'CreateSFX' -DefaultValue $Configuration.DefaultCreateSFX) -eq $true) { $notes.Add("SFX") }
            if (-not [string]::IsNullOrWhiteSpace((Get-ConfigValue -ConfigObject $jobConf -Key 'SplitVolumeSize' -DefaultValue $Configuration.DefaultSplitVolumeSize))) { $notes.Add("Splitting") }

            $jobData = @{
                JobName   = $jobNameKey
                Enabled   = Get-ConfigValue -ConfigObject $jobConf -Key 'Enabled' -DefaultValue $true
                Sources   = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }
                DependsOn = (@(Get-ConfigValue -ConfigObject $jobConf -Key 'DependsOnJobs' -DefaultValue @()) -join ", ")
                Notes     = ($notes -join ", ")
            }
            $jobDetailsList.Add($jobData)

            $maxWidths.JobName = [math]::Max($maxWidths.JobName, $jobData.JobName.Length)
            $maxWidths.DependsOn = [math]::Max($maxWidths.DependsOn, $jobData.DependsOn.Length)
            $maxWidths.Notes = [math]::Max($maxWidths.Notes, $jobData.Notes.Length)
            $maxWidths.Sources = [math]::Max($maxWidths.Sources, $jobData.Sources.Length)
            if ($maxWidths.Sources -gt 50) { $maxWidths.Sources = 50 }
        }

        $headerData = @{ JobName = "Job Name"; Enabled = "Enabled"; Sources = "Sources"; DependsOn = "Depends On"; Notes = "Notes" }
        Write-FormattedTableRowInternal -ColumnWidths $maxWidths -RowData $headerData -ColorMap @{ Default = $Global:ColourHeading }
    
        $headerUnderline = @{}
        $headerData.Keys | ForEach-Object { $headerUnderline[$_] = "-" * $maxWidths[$_] }
        Write-FormattedTableRowInternal -ColumnWidths $maxWidths -RowData $headerUnderline -ColorMap @{ Default = $Global:ColourHeading }

        foreach ($job in $jobDetailsList) {
            $colorMap = @{
                JobName   = $Global:ColourInfo
                Enabled   = if ($job.Enabled) { $Global:ColourSuccess } else { $Global:ColourError }
                Sources   = $Global:ColourValue
                DependsOn = "Gray"
                Notes     = "DarkGray"
            }
            Write-FormattedTableRowInternal -ColumnWidths $maxWidths -RowData $job -ColorMap $colorMap
        }
    }

    if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
        Write-ConsoleBanner -NameText "Defined Backup Sets" -BannerWidth 78 -CenterText -PrependNewLine
        foreach ($setNameKey in ($Configuration.BackupSets.Keys | Sort-Object)) {
            $setConf = $Configuration.BackupSets[$setNameKey]
            & $LocalWriteLog -Message ("`n  Set: {0}" -f $setNameKey) -Level "NONE"
            $jobsInSetDisplay = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }; & $LocalWriteLog -Message ("    Jobs in Set: {0}" -f $jobsInSetDisplay) -Level "NONE"
        }
    }

    Write-ConsoleBanner -NameText "Job Dependency Graph" -BannerWidth 78 -CenterText -PrependNewLine
    try {
        if (Get-Command Get-PoShBackupJobDependencyMap -ErrorAction SilentlyContinue) {
            $dependencyMapData = Get-PoShBackupJobDependencyMap -AllBackupLocations $Configuration.BackupLocations
            $graphLines = Format-DependencyGraphInternal -DependencyMap $dependencyMapData
            foreach ($line in $graphLines) { & $LocalWriteLog -Message $line -Level "NONE" }
        }
        else { & $LocalWriteLog -Message "    (Could not generate graph: Get-PoShBackupJobDependencyMap function not found.)" -Level "NONE" }
    }
    catch { & $LocalWriteLog -Message "    (An error occurred while generating the dependency graph: $($_.Exception.Message))" -Level "NONE" }

    if (Get-Command Invoke-PoShBackupPostRunActionHandler -ErrorAction SilentlyContinue) {
        Write-ConsoleBanner -NameText "Effective Post-Run Action" -BannerWidth 78 -CenterText -PrependNewLine
        $postRunResolution = Invoke-PoShBackupPostRunActionHandler -OverallStatus "SIMULATED_COMPLETE" `
            -CliOverrideSettings $CliOverrideSettingsInternal -SetSpecificPostRunAction $null -JobSpecificPostRunActionForNonSet $null `
            -GlobalConfig $Configuration -IsSimulateMode $true -TestConfigIsPresent $true `
            -Logger $Logger -ResolveOnly
        if ($null -ne $postRunResolution) {
            Write-NameValue "Action" $postRunResolution.Action
            Write-NameValue "Source" $postRunResolution.Source
            if ($postRunResolution.Action -ne 'None') {
                Write-NameValue "Trigger On" $postRunResolution.TriggerOnStatus
                Write-NameValue "Delay (seconds)" $postRunResolution.DelaySeconds
                Write-NameValue "Force Action" $postRunResolution.ForceAction
            }
        }
    }
    else {
        Write-ConsoleBanner -NameText "Effective Post-Run Action" -BannerWidth 78 -CenterText -PrependNewLine
        & $LocalWriteLog -Message "    (Could not be determined as PostRunActionOrchestrator was not available)" -Level "NONE"
    }

    $validationMessages = if ($ConfigLoadResult.ContainsKey('ValidationMessages')) { $ConfigLoadResult.ValidationMessages } else { @() }
    
    $finalBannerColor = '$Global:ColourError'
    $finalBannerValue = "Finished with Errors ($($validationMessages.Count))"
    $finalBannerBorderColor = '$Global:ColourError'

    if ($null -eq $validationMessages -or $validationMessages.Count -eq 0) {
        $finalBannerColor = '$Global:ColourSuccess'
        $finalBannerValue = "All Checks Passed"
        $finalBannerBorderColor = '$Global:ColourSuccess'
    }

    Write-ConsoleBanner -NameText "Final Test Result" `
                        -ValueText $finalBannerValue `
                        -NameForegroundColor $finalBannerColor `
                        -ValueForegroundColor $finalBannerColor `
                        -BorderForegroundColor $finalBannerBorderColor `
                        -BannerWidth 78 `
                        -CenterText `
                        -PrependNewLine
}

Export-ModuleMember -Function Invoke-PoShBackupConfigTest
