<#
.SYNOPSIS
    Acts as the central orchestrator for report generation in the PoSh-Backup solution.
    It determines the required report format(s) for a job by inspecting the configuration
    and dispatches the report creation task to the appropriate format-specific reporting module.

.DESCRIPTION
    The Reporting orchestrator module is responsible for managing the overall reporting process for
    a completed PoSh-Backup job. It reads the job's effective configuration (merged from global
    and job-specific settings) to determine which report types (e.g., HTML, CSV, JSON) are enabled.

    For each enabled report type:
    1. It constructs the expected path to the corresponding reporting sub-module (e.g.,
       'Modules\Reporting\ReportingHtml.psm1', 'Modules\Reporting\ReportingCsv.psm1').
    2. If the sub-module exists, it is dynamically imported.
    3. The relevant 'Invoke-<Format>Report' function within that sub-module is then called.
    4. This orchestrator passes necessary data to the sub-module, including the detailed
       report data object, job name, configuration settings, and a logger reference.
       Global and job-specific configuration objects are passed if the sub-module's function
       is designed to accept them.
    5. It also ensures that the target directory for the specific report format exists,
       attempting to create it if necessary, before calling the sub-module.

    This modular approach allows for easy extension with new report formats in the future
    without modifying this core orchestrator.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.3.2 # Added explicit Import-Module for Utils.psm1.
    DateCreated:    10-May-2025
    LastModified:   18-May-2025
    Purpose:        Manages and dispatches report generation to format-specific reporting sub-modules.
    Prerequisites:  PowerShell 5.1+.
                    Core PoSh-Backup modules: Utils.psm1.
                    Format-specific reporting modules (e.g., ReportingHtml.psm1, ReportingCsv.psm1)
                    must be located in the '.\Modules\Reporting\' subdirectory relative to the main script.
                    The $GlobalConfig hashtable passed to Invoke-ReportGenerator must contain a
                    '_PoShBackup_PSScriptRoot' key pointing to the main script's root directory.
#>

# Explicitly import Utils.psm1 to ensure its functions are available, especially Get-ConfigValue.
# $PSScriptRoot here refers to the directory of Reporting.psm1 (Modules).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Utils.psm1") -Force -ErrorAction Stop
} catch {
    # If this fails, the module cannot function. Write-Error is appropriate as Write-LogMessage might not be available
    # if Utils.psm1 didn't load for the main script either.
    Write-Error "Reporting.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw 
}


function Invoke-ReportGenerator {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Orchestrates the generation of one or more report types for a completed backup job.
    .DESCRIPTION
        This function determines which report formats are configured for the specified job,
        loads the necessary reporting sub-modules, and calls their respective report generation
        functions. It handles the resolution of report output directories and ensures they exist.
    .PARAMETER ReportDirectory
        The base directory where reports are generally stored (e.g., ".\Reports").
        Specific report types might have their own subdirectories configured via settings like
        'HtmlReportDirectory', 'CsvReportDirectory', etc., which take precedence if set.
    .PARAMETER JobName
        The name of the backup job for which reports are being generated.
    .PARAMETER ReportData
        A hashtable containing all the data collected during the backup job's execution,
        including summary details, log entries, hook script information, and configuration used.
        This data is passed to the specific report generation functions.
    .PARAMETER GlobalConfig
        The global configuration hashtable for PoSh-Backup. This is used to find the script root
        path ('_PoShBackup_PSScriptRoot') for locating modules and may be passed to sub-modules
        if they accept a -GlobalConfig parameter.
    .PARAMETER JobConfig
        The specific configuration hashtable for the job being reported on. This may be passed
        to sub-modules if they accept a -JobConfig parameter (e.g., for job-specific report settings).
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # This function is typically called by PoSh-Backup.ps1 after a job completes.
        # $reportParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports"
        #     JobName         = "MyServerBackup"
        #     ReportData      = $currentJobReportDataObject
        #     GlobalConfig    = $Configuration
        #     JobConfig       = $Configuration.BackupLocations.MyServerBackup
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-ReportGenerator @reportParams
    .OUTPUTS
        None. This function calls other functions that produce file outputs.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory, 
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)]
        [hashtable]$JobConfig,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Invoke-ReportGenerator: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue


    # Determine which report types are configured for this job
    # Get-ConfigValue is now available due to the Import-Module Utils.psm1 at the top of this module.
    $reportTypeSetting = Get-ConfigValue -ConfigObject $JobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ReportGeneratorType' -DefaultValue "HTML")
    $reportTypesToGenerate = @()
    if ($reportTypeSetting -is [array]) {
        $reportTypesToGenerate = $reportTypeSetting | ForEach-Object { $_.ToString().ToUpperInvariant() }
    } else {
        $reportTypesToGenerate = @($reportTypeSetting.ToString().ToUpperInvariant())
    }

    foreach ($reportType in $reportTypesToGenerate) {
        & $LocalWriteLog -Message "`n[INFO] Report generation requested for job '$JobName'. Type: '$reportType'." -Level "INFO"

        if ($reportType -eq "NONE") {
            & $LocalWriteLog -Message "  - Report generation is explicitly set to 'None' for this type/job. Skipping." -Level "INFO"
            continue
        }

        $moduleSubPath = "Reporting" # Subdirectory within Modules
        $moduleFileName = "Reporting$($reportType).psm1" # e.g., ReportingHTML.psm1
        $invokeFunctionName = "Invoke-$($reportType)Report" # e.g., Invoke-HtmlReport

        $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
        if ([string]::IsNullOrWhiteSpace($mainScriptRoot)) {
            & $LocalWriteLog -Message "[ERROR] _PoShBackup_PSScriptRoot not found in GlobalConfig. Cannot determine path for reporting sub-modules. Skipping '$reportType' report for job '$JobName'." -Level "ERROR"
            continue
        }
        $reportModulePath = Join-Path -Path $mainScriptRoot -ChildPath "Modules\$moduleSubPath\$moduleFileName"

        if (-not (Test-Path -LiteralPath $reportModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[WARNING] Reporting sub-module file '$moduleFileName' for type '$reportType' not found at expected path: '$reportModulePath'. Skipping this report type for job '$JobName'." -Level "WARNING"
            continue
        }

        try {
            & $LocalWriteLog -Message "  - Attempting to load reporting sub-module: '$moduleFileName' from '$reportModulePath'" -Level "DEBUG"
            Import-Module -Name $reportModulePath -Force -ErrorAction Stop # Force import to pick up any changes if module was already loaded

            $reportFunctionCmd = Get-Command $invokeFunctionName -ErrorAction SilentlyContinue
            if ($reportFunctionCmd) {
                & $LocalWriteLog -Message "  - Executing report function '$invokeFunctionName' for job '$JobName'..." -Level "DEBUG"

                # Determine the specific output directory for this report type
                $typeSpecificDirKey = "$($reportType)ReportDirectory" # e.g., "HtmlReportDirectory", "CsvReportDirectory"
                $specificReportDirectory = Get-ConfigValue -ConfigObject $JobConfig -Key $typeSpecificDirKey -DefaultValue `
                                            (Get-ConfigValue -ConfigObject $GlobalConfig -Key $typeSpecificDirKey -DefaultValue $ReportDirectory) # Fallback chain

                # Resolve relative paths from the main script root
                if (-not ([System.IO.Path]::IsPathRooted($specificReportDirectory))) {
                    $specificReportDirectory = Join-Path -Path $mainScriptRoot -ChildPath $specificReportDirectory
                }

                # Ensure the target report directory exists
                if (-not (Test-Path -LiteralPath $specificReportDirectory -PathType Container)) {
                    & $LocalWriteLog -Message "[INFO] Report output directory '$specificReportDirectory' for type '$reportType' does not exist. Attempting to create..." -Level "INFO"
                    try {
                        New-Item -Path $specificReportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        & $LocalWriteLog -Message "  - Report output directory '$specificReportDirectory' created successfully." -Level "SUCCESS"
                    } catch {
                        & $LocalWriteLog -Message "[WARNING] Failed to create report output directory '$specificReportDirectory' for type '$reportType'. Report generation for this type may fail or be skipped. Error: $($_.Exception.Message)" -Level "WARNING"
                        continue # Skip to next report type if directory creation fails
                    }
                }

                # Base parameters common to all report functions
                $reportParams = @{
                    ReportDirectory = $specificReportDirectory
                    JobName         = $JobName
                    ReportData      = $ReportData
                    Logger          = $Logger # Pass the logger reference
                }

                # Conditionally add GlobalConfig and JobConfig if the target function accepts them
                if ($reportFunctionCmd.Parameters.ContainsKey('GlobalConfig')) {
                    $reportParams.GlobalConfig = $GlobalConfig
                }
                if ($reportFunctionCmd.Parameters.ContainsKey('JobConfig')) {
                    $reportParams.JobConfig = $JobConfig
                }
                
                # Call the specific report generation function
                & $invokeFunctionName @reportParams

            } else {
                & $LocalWriteLog -Message "[ERROR] Report generation function '$invokeFunctionName' was not found in module '$moduleFileName' after successful import. Cannot generate '$reportType' report for job '$JobName'." -Level "ERROR"
            }
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to load or execute reporting sub-module '$moduleFileName' for type '$reportType' for job '$JobName'. Error: $($_.Exception.ToString())" -Level "ERROR"
        }
    }
}

Export-ModuleMember -Function Invoke-ReportGenerator
