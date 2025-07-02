# Modules\Reporting.psm1
<#
.SYNOPSIS
    Acts as the central orchestrator for report generation in the PoSh-Backup solution.
    It determines the required report format(s) for a job and lazy-loads the appropriate
    format-specific reporting module to create the report.

.DESCRIPTION
    The Reporting orchestrator module is responsible for managing the overall reporting process for
    a completed PoSh-Backup job. It reads the job's effective configuration to determine
    which report types (e.g., HTML, CSV, JSON) are enabled.

    For each enabled report type:
    1. It constructs the expected path to the corresponding reporting sub-module.
    2. It lazy-loads the sub-module.
    3. The relevant 'Invoke-<Format>Report' function within that sub-module is then called.
    4. It passes all necessary data to the sub-module.

    This modular approach allows for easy extension with new report formats and improves
    script startup performance by only loading modules that are actively needed.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.5.0 # Refactored to lazy-load report provider sub-modules.
    DateCreated:    10-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Manages and dispatches report generation to format-specific reporting sub-modules.
    Prerequisites:  PowerShell 5.1+.
#>

# Explicitly import Utils.psm1 as it is a foundational dependency.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Warning "Reporting.psm1 CRITICAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message). Reporting functions may fail."
}


function Invoke-SetSummaryReportGenerator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$SetReportData,
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "[INFO] Reporting facade: Set Summary Report generation requested for set '$($SetReportData.SetName)'." -Level "INFO"

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
    $moduleSubPath = "Reporting"
    $moduleFileName = "ReportingSetSummary.psm1"
    $invokeFunctionName = "Invoke-SetSummaryReport"
    $reportModulePath = Join-Path -Path $mainScriptRoot -ChildPath "Modules\$moduleSubPath\$moduleFileName"

    if (-not (Test-Path -LiteralPath $reportModulePath -PathType Leaf)) {
        & $LocalWriteLog -Message "[WARNING] Reporting facade: Set Summary report module '$moduleFileName' not found at '$reportModulePath'. Skipping." -Level "WARNING"
        return
    }

    try {
        Import-Module -Name $reportModulePath -Force -ErrorAction Stop
        $reportFunctionCmd = Get-Command $invokeFunctionName -ErrorAction SilentlyContinue

        if ($reportFunctionCmd) {
            $reportDirectory = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HtmlReportDirectory' -DefaultValue "Reports"
            if (-not ([System.IO.Path]::IsPathRooted($reportDirectory))) {
                $reportDirectory = Join-Path -Path $mainScriptRoot -ChildPath $reportDirectory
            }
            if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
                New-Item -Path $reportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            $reportParams = @{
                ReportDirectory = $reportDirectory
                SetReportData   = $SetReportData
                GlobalConfig    = $GlobalConfig
                Logger          = $Logger
            }
            & $invokeFunctionName @reportParams
        } else {
             & $LocalWriteLog -Message "[ERROR] Set Summary report generation function '$invokeFunctionName' was not found in module '$moduleFileName'." -Level "ERROR"
        }
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to load or execute Set Summary reporting sub-module '$moduleFileName'. Error: $($_.Exception.ToString())" -Level "ERROR"
    }
}


function Invoke-ReportGenerator {
    [CmdletBinding()]
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

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $Logger -Message "Invoke-ReportGenerator: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $reportTypeSetting = Get-ConfigValue -ConfigObject $JobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ReportGeneratorType' -DefaultValue "HTML")
    $reportTypesToGenerate = @()
    if ($reportTypeSetting -is [array]) {
        $reportTypesToGenerate = $reportTypeSetting | ForEach-Object { $_.ToString().ToUpperInvariant() }
    } else {
        $reportTypesToGenerate = @($reportTypeSetting.ToString().ToUpperInvariant())
    }

    foreach ($reportType in $reportTypesToGenerate) {
        & $LocalWriteLog -Message "`n[INFO] Report generation requested for job '$JobName'. Type: '$reportType'." -Level "INFO"

        if ($reportType -eq "NONE") { & $LocalWriteLog -Message "  - Report generation is explicitly set to 'None'. Skipping." -Level "INFO"; continue }

        $moduleSubPath = "Reporting"
        $moduleFileName = "Reporting$($reportType).psm1"
        $invokeFunctionName = "Invoke-$($reportType)Report"

        $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
        if ([string]::IsNullOrWhiteSpace($mainScriptRoot)) { & $LocalWriteLog -Message "[ERROR] _PoShBackup_PSScriptRoot not found in GlobalConfig. Skipping '$reportType' report." -Level "ERROR"; continue }

        $reportModulePath = Join-Path -Path $mainScriptRoot -ChildPath "Modules\$moduleSubPath\$moduleFileName"
        if (-not (Test-Path -LiteralPath $reportModulePath -PathType Leaf)) { & $LocalWriteLog -Message "[WARNING] Reporting sub-module '$moduleFileName' not found at '$reportModulePath'. Skipping report type." -Level "WARNING"; continue }

        try {
            & $LocalWriteLog -Message "  - Attempting to load reporting sub-module: '$moduleFileName'" -Level "DEBUG"
            Import-Module -Name $reportModulePath -Force -ErrorAction Stop

            $reportFunctionCmd = Get-Command $invokeFunctionName -ErrorAction SilentlyContinue
            if ($reportFunctionCmd) {
                & $LocalWriteLog -Message "  - Executing report function '$invokeFunctionName'..." -Level "DEBUG"

                $typeSpecificDirKey = "$($reportType)ReportDirectory"
                $specificReportDirectory = Get-ConfigValue -ConfigObject $JobConfig -Key $typeSpecificDirKey -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key $typeSpecificDirKey -DefaultValue $ReportDirectory)
                $specificReportDirectory = Resolve-PoShBackupPath -PathToResolve $specificReportDirectory -ScriptRoot $mainScriptRoot

                if (-not (Test-Path -LiteralPath $specificReportDirectory -PathType Container)) {
                    & $LocalWriteLog -Message "[INFO] Report output directory '$specificReportDirectory' does not exist. Attempting to create..." -Level "INFO"
                    try { New-Item -Path $specificReportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog "  - Report directory created." "SUCCESS" }
                    catch { & $LocalWriteLog -Message "[WARNING] Failed to create report directory '$specificReportDirectory'. Skipping report. Error: $($_.Exception.Message)" -Level "WARNING"; continue }
                }

                $reportParams = @{ ReportDirectory = $specificReportDirectory; JobName = $JobName; ReportData = $ReportData; Logger = $Logger }
                if ($reportFunctionCmd.Parameters.ContainsKey('GlobalConfig')) { $reportParams.GlobalConfig = $GlobalConfig }
                if ($reportFunctionCmd.Parameters.ContainsKey('JobConfig')) { $reportParams.JobConfig = $JobConfig }

                & $invokeFunctionName @reportParams
            } else {
                & $LocalWriteLog -Message "[ERROR] Report function '$invokeFunctionName' not found in module '$moduleFileName'." -Level "ERROR"
            }
        } catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Reporting\$moduleFileName' exists and is not corrupted."
            & $LocalWriteLog -Message "[ERROR] Failed to load or execute reporting sub-module '$moduleFileName'. Error: $($_.Exception.ToString())" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
    }
}

Export-ModuleMember -Function Invoke-ReportGenerator, Invoke-SetSummaryReportGenerator
