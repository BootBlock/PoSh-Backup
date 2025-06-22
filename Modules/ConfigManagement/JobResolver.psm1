# Modules\ConfigManagement\JobResolver.psm1
<#
.SYNOPSIS
    Determines the list of backup jobs and/or sets to process based on command-line parameters
    and the loaded PoSh-Backup configuration.
.DESCRIPTION
    This module is a sub-component of the main ConfigManager module for PoSh-Backup.
    Its primary function, Get-JobsToProcess, resolves which backup jobs should be run:
    - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
    - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
    - If neither is specified:
        - If only one job is defined in the configuration, it returns that job.
        - If multiple jobs/sets are defined, it presents an interactive, two-column menu for the user to choose.
          This menu now accepts single or multiple comma-separated selections.
        - Otherwise, it returns an error.
    - It filters out any jobs that are disabled (`Enabled = $false`) or specified via the -SkipJob CLI parameter.
    It also determines the 'StopSetOnError' policy and 'PostRunAction' for the resolved set.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.1 # Correctly handles ad-hoc job selections from the interactive menu.
    DateCreated:    24-May-2025
    LastModified:   21-Jun-2025
    Purpose:        To modularise job/set resolution logic from the main ConfigManager module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the parent 'Modules' directory for Get-ConfigValue.
#>

# Explicitly import dependent Utils.psm1 from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "JobResolver.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Exported Job/Set Resolution Function ---
function Get-JobsToProcess {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Determines the list of backup jobs to process based on command-line parameters and configuration.
    .DESCRIPTION
        This function resolves which backup jobs should be run.
        - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
        - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
        - If neither is specified:
            - If only one job is defined in the configuration, it returns that job.
            - If multiple jobs/sets are defined, it presents an interactive menu for the user to choose.
            - Otherwise (zero jobs defined), it returns an error.
        It also determines the 'StopSetOnError' policy and 'PostRunAction' for the resolved set.
    .PARAMETER Config
        The loaded PoSh-Backup configuration hashtable.
    .PARAMETER SpecifiedJobName
        The job name provided via the -BackupLocationName command-line parameter, if any.
    .PARAMETER SpecifiedSetName
        The set name provided via the -RunSet command-line parameter, if any.
    .PARAMETER JobsToSkip
        An array of job names provided via the -SkipJob command-line parameter.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with keys: Success, JobsToRun, SetName, StopSetOnErrorPolicy, SetPostRunAction, ErrorMessage.
    #>
    param(
        [hashtable]$Config,
        [string]$SpecifiedJobName,
        [string]$SpecifiedSetName,
        [string[]]$JobsToSkip,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "JobResolver/Get-JobsToProcess: Initialising job/set resolution." -Level "DEBUG" -ErrorAction SilentlyContinue

    # --- START: Configurable colours for the interactive menu ---
    $menuInstructionColour  = "White"
    $menuJobColour          = "Green"
    $menuSetColour          = "Cyan"
    $menuHeaderColour       = "Gray"
    $menuNumberColour       = "DarkYellow"
    $menuQuitColour         = "Red"
    # --- END: Configurable colours ---

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $initialJobsToConsider = [System.Collections.Generic.List[string]]::new()
    $setName = $null
    $stopSetOnErrorPolicy = $true # Default for StopSetOnError is "StopSet", hence $true
    $setPostRunAction = $null

    if (-not [string]::IsNullOrWhiteSpace($SpecifiedSetName)) {
        & $LocalWriteLog -Message "`n[INFO] JobResolver: Backup Set specified by user: '$SpecifiedSetName'" -Level "INFO"
        if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].ContainsKey($SpecifiedSetName)) {
            $setDefinition = $Config['BackupSets'][$SpecifiedSetName]
            $setName = $SpecifiedSetName
            $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())

            if ($jobNamesInSet.Count -gt 0) {
                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $initialJobsToConsider.Add($_.Trim()) } }
                if ($initialJobsToConsider.Count -eq 0) {
                    return @{ Success = $false; ErrorMessage = "JobResolver: Backup Set '$setName' defined but 'JobNames' list is empty/invalid." }
                }
                $stopSetOnErrorPolicy = if (((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -as [string]).ToUpperInvariant() -eq "CONTINUESET") { $false } else { $true }
                if ($setDefinition.ContainsKey('PostRunAction') -and $setDefinition.PostRunAction -is [hashtable]) {
                    $setPostRunAction = $setDefinition.PostRunAction
                    & $LocalWriteLog -Message "  - JobResolver: Set '$setName' has specific PostRunAction settings." -Level "DEBUG"
                }
                & $LocalWriteLog -Message "  - JobResolver: Jobs in set '$setName': $($initialJobsToConsider -join ', ')" -Level "INFO"
                & $LocalWriteLog -Message "  - JobResolver: Policy for set on job failure: $(if($stopSetOnErrorPolicy){'StopSet'}else{'ContinueSet'})" -Level "INFO"
            }
            else {
                return @{ Success = $false; ErrorMessage = "JobResolver: Backup Set '$setName' defined but has no 'JobNames' listed." }
            }
        }
        else {
            $availableSetsMessage = "No Backup Sets defined."
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $setNameList = $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableSetsMessage = "Available Backup Sets: $($setNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "JobResolver: Specified Backup Set '$SpecifiedSetName' not found. $availableSetsMessage" }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SpecifiedJobName)) {
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].ContainsKey($SpecifiedJobName)) {
            $initialJobsToConsider.Add($SpecifiedJobName)
            & $LocalWriteLog -Message "`n[INFO] JobResolver: Single Backup Location specified by user: '$SpecifiedJobName'" -Level "INFO"
        }
        else {
            $availableJobsMessage = "No Backup Locations defined."
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $jobNameList = $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableJobsMessage = "Available Backup Locations: $($jobNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "JobResolver: Specified BackupLocationName '$SpecifiedJobName' not found. $availableJobsMessage" }
        }
    }
    else {
        $allDefinedJobs = if ($Config.ContainsKey('BackupLocations') -and $Config.BackupLocations -is [hashtable]) { @($Config.BackupLocations.Keys) } else { @() }
        $allDefinedSets = if ($Config.ContainsKey('BackupSets') -and $Config.BackupSets -is [hashtable]) { @($Config.BackupSets.Keys) } else { @() }

        if ($allDefinedJobs.Count -eq 1 -and $allDefinedSets.Count -eq 0) {
            $initialJobsToConsider.Add($allDefinedJobs[0])
            & $LocalWriteLog -Message "`n[INFO] JobResolver: No job/set specified. Auto-selected single defined Backup Location: '$($allDefinedJobs[0])'" -Level "INFO"
        }
        elseif ($allDefinedJobs.Count -eq 0) {
            return @{ Success = $false; ErrorMessage = "JobResolver: No job/set specified, and no Backup Locations defined. Nothing to back up." }
        }
        else { # Multiple jobs and/or sets exist, so prompt the user.
            Write-Host
            Write-ConsoleBanner -NameText "PoSh Backup" -ValueText "Interactive Selection" -CenterText
            Write-Host "Please select a Backup Job or a Backup Set to run:" -ForegroundColor $menuInstructionColour
            Write-Host

            $menuMap = @{} # Maps menu number to item details
            $menuIndex = 1
            $leftColumnWidth = 38

            $sortedJobs = $allDefinedJobs | Sort-Object
            $sortedSets = $allDefinedSets | Sort-Object

            # --- Build Menu Items Sequentially ---
            $jobDisplayLines = [System.Collections.Generic.List[string]]::new()
            $setDisplayLines = [System.Collections.Generic.List[string]]::new()
            foreach ($jobName in $sortedJobs) {
                $jobDisplayLines.Add(("{0,2}. {1}" -f $menuIndex, $jobName))
                $menuMap[$menuIndex] = @{ Name = $jobName; Type = 'Job' }
                $menuIndex++
            }
            foreach ($setName in $sortedSets) {
                $setDisplayLines.Add(("{0,2}. {1}" -f $menuIndex, $setName))
                $menuMap[$menuIndex] = @{ Name = $setName; Type = 'Set' }
                $menuIndex++
            }

            # --- Draw Menu ---
            Write-Host ("  {0}{1}" -f "Backup Jobs".PadRight($leftColumnWidth), "Backup Sets") -ForegroundColor $menuHeaderColour
            Write-Host ("  {0}{1}" -f ("-" * 11).PadRight($leftColumnWidth), ("-" * 11)) -ForegroundColor $menuHeaderColour

            $maxRows = [math]::Max($jobDisplayLines.Count, $setDisplayLines.Count)

            for ($i = 0; $i -lt $maxRows; $i++) {
                Write-Host "  " -NoNewline

                # Left Column (Jobs)
                if ($i -lt $jobDisplayLines.Count) {
                    $jobLine = $jobDisplayLines[$i]
                    $jobLine -match "^(\s*\d+\.)(.*)$" | Out-Null
                    Write-Host $Matches[1] -ForegroundColor $menuNumberColour -NoNewline
                    Write-Host $Matches[2].PadRight($leftColumnWidth - $Matches[1].Length) -ForegroundColor $menuJobColour -NoNewline
                } else {
                    Write-Host (" " * $leftColumnWidth) -NoNewline
                }

                # Right Column (Sets)
                if ($i -lt $setDisplayLines.Count) {
                    $setLine = $setDisplayLines[$i]
                    $setLine -match "^(\s*\d+\.)(.*)$" | Out-Null
                    Write-Host $Matches[1] -ForegroundColor $menuNumberColour -NoNewline
                    Write-Host $Matches[2] -ForegroundColor $menuSetColour
                }
            }

            # --- Get User Input (New Logic) ---
            Write-Host
            Write-Host ("   0. Quit") -ForegroundColor $menuQuitColour
            Write-Host

            while ($true) {
                $userInput = Read-Host "Enter selection(s), comma-separated (or press Enter to quit)"
                if ([string]::IsNullOrWhiteSpace($userInput) -or $userInput -eq '0') {
                    & $LocalWriteLog -Message "JobResolver: User chose to quit from interactive menu." -Level "INFO"
                    exit 0
                }

                $selectionStrings = $userInput.Split(',') | ForEach-Object { $_.Trim() }
                $validSelections = [System.Collections.Generic.List[object]]::new()
                $invalidInputs = [System.Collections.Generic.List[string]]::new()

                foreach ($selectionStr in $selectionStrings) {
                    if ($selectionStr -match '^\d+$') {
                        $index = [int]$selectionStr
                        if ($menuMap.ContainsKey($index)) {
                            $validSelections.Add($menuMap[$index])
                        } else {
                            $invalidInputs.Add($selectionStr)
                        }
                    } else {
                        $invalidInputs.Add($selectionStr)
                    }
                }

                if ($invalidInputs.Count -gt 0) {
                    Write-Warning "Invalid or out-of-range selection(s): $($invalidInputs -join ', ')"
                }

                if ($validSelections.Count -gt 0) {
                    $uniqueSelections = $validSelections | Select-Object -Unique # De-duplicate the selections

                    if ($uniqueSelections.Count -eq 1 -and $uniqueSelections[0].Type -eq 'Set') {
                        # --- SCENARIO 1: User selected exactly one set ---
                        $selectedItem = $uniqueSelections[0]
                        $setName = $selectedItem.Name
                        & $LocalWriteLog -Message "`n[INFO] JobResolver: Single Backup Set '$setName' selected by user." -Level "INFO"
                        $setDefinition = $Config.BackupSets[$setName]
                        $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())
                        $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $initialJobsToConsider.Add($_.Trim()) } }
                        $stopSetOnErrorPolicy = if (((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -as [string]).ToUpperInvariant() -eq "CONTINUESET") { $false } else { $true }
                        if ($setDefinition.ContainsKey('PostRunAction')) { $setPostRunAction = $setDefinition.PostRunAction }
                    } else {
                        # --- SCENARIO 2: User selected one or more jobs, or a mix ---
                        # This is an ad-hoc run. We just collect the jobs.
                        # Set a transient name for logging/display purposes.
                        $setName = "(Interactive Selection)"
                        $stopSetOnErrorPolicy = $true # Safest default for ad-hoc runs is to stop on error.
                        $setPostRunAction = $null # No set-level action for ad-hoc.

                        & $LocalWriteLog -Message "`n[INFO] JobResolver: Ad-hoc collection of jobs/sets selected by user." -Level "INFO"
                        foreach ($selectedItem in $uniqueSelections) {
                            if ($selectedItem.Type -eq 'Job') {
                                $initialJobsToConsider.Add($selectedItem.Name)
                                & $LocalWriteLog -Message "  - Job '$($selectedItem.Name)' added to run list." -Level "DEBUG"
                            } else { # It's a set
                                $setDefinition = $Config.BackupSets[$selectedItem.Name]
                                $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())
                                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $initialJobsToConsider.Add($_.Trim()) } }
                                & $LocalWriteLog -Message "  - Jobs from Set '$($selectedItem.Name)' added to run list." -Level "DEBUG"
                            }
                        }
                    }
                    break # Exit the while loop
                }
            }
        }
    }

    # --- Filter out disabled jobs ---
    $enabledJobs = [System.Collections.Generic.List[string]]::new()
    foreach ($jobNameCandidate in ($initialJobsToConsider | Select-Object -Unique)) {
        if ($Config.BackupLocations.ContainsKey($jobNameCandidate)) {
            $jobConfForEnableCheck = $Config.BackupLocations[$jobNameCandidate]
            $isJobEnabled = Get-ConfigValue -ConfigObject $jobConfForEnableCheck -Key 'Enabled' -DefaultValue $true
            if ($isJobEnabled) {
                $enabledJobs.Add($jobNameCandidate)
            } else {
                & $LocalWriteLog -Message "  - JobResolver: Job '$jobNameCandidate' is disabled (Enabled = `$false). It will be skipped." -Level "INFO"
            }
        } else {
            & $LocalWriteLog -Message "  - JobResolver: Job '$jobNameCandidate' listed in set '$setName' not found in BackupLocations. Skipping." -Level "WARNING"
        }
    }

    # --- Filter out jobs specified by -SkipJob ---
    $finalJobsToRun = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $JobsToSkip -and $JobsToSkip.Count -gt 0) {
        & $LocalWriteLog -Message "`n[INFO] JobResolver: Applying -SkipJob CLI parameter. Jobs to skip: $($JobsToSkip -join ', ')" -Level "INFO"
        $jobsToSkipCleaned = @($JobsToSkip | ForEach-Object { $_.Trim() })

        foreach ($jobToRunCandidate in $enabledJobs) {
            if ($jobToRunCandidate -in $jobsToSkipCleaned) {
                & $LocalWriteLog -Message "  - JobResolver: Job '$jobToRunCandidate' has been SKIPPED from the current run due to the -SkipJob parameter." -Level "WARNING"
            } else {
                $finalJobsToRun.Add($jobToRunCandidate)
            }
        }
    } else {
        $finalJobsToRun.AddRange($enabledJobs)
    }

    if ($finalJobsToRun.Count -eq 0) {
        return @{ Success = $false; ErrorMessage = "JobResolver: No valid, enabled backup jobs determined after parsing parameters/config and applying filters." }
    }

    return @{
        Success              = $true;
        JobsToRun            = $finalJobsToRun;
        SetName              = $setName;
        StopSetOnErrorPolicy = $stopSetOnErrorPolicy;
        SetPostRunAction     = $setPostRunAction
    }
}
#endregion

Export-ModuleMember -Function Get-JobsToProcess
