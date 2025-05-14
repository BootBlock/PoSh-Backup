# PowerShell Module: Reporting.psm1 (Orchestrator)
# Description: Dispatches report generation to specific format modules.
# Version: 2.0 

# This module relies on Write-LogMessage being available from Utils.psm1,
# which is imported by the main PoSh-Backup.ps1 script.

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
        [hashtable]$JobConfig 
    )

    # Determine the ReportGeneratorType for the current job
    $reportType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ReportGeneratorType' -DefaultValue "HTML")
    $reportType = $reportType.ToString().ToUpperInvariant() # Standardize to uppercase

    Write-LogMessage "`n[INFO] Report generation requested. Type: '$reportType' for job '$JobName'." -Level "INFO"

    if ($reportType -eq "NONE") {
        Write-LogMessage "  - Report generation is set to 'None' for this job. Skipping." -Level "INFO"
        return
    }

    # Construct module name and function name based on type
    $moduleFileName = "Reporting$($reportType).psm1" # e.g., ReportingHTML.psm1, ReportingCSV.psm1
    $invokeFunctionName = "Invoke-$($reportType)Report" # e.g., Invoke-HtmlReport, Invoke-CsvReport

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
    if ([string]::IsNullOrWhiteSpace($mainScriptRoot)) {
        Write-LogMessage "[ERROR] _PoShBackup_PSScriptRoot not found in GlobalConfig. Cannot determine path for report modules." -Level "ERROR"
        return
    }
    $reportModulePath = Join-Path -Path $mainScriptRoot -ChildPath "Modules\$moduleFileName"

    if (-not (Test-Path -LiteralPath $reportModulePath -PathType Leaf)) {
        Write-LogMessage "[WARNING] Report module file '$moduleFileName' not found at '$reportModulePath' for type '$reportType'. Skipping report generation." -Level "WARNING"
        return
    }

    try {
        Write-LogMessage "  - Attempting to load report module: $moduleFileName" -Level "DEBUG"
        Import-Module -Name $reportModulePath -Force -ErrorAction Stop
        
        # Check if the specific invoke function exists after import
        if (Get-Command $invokeFunctionName -ErrorAction SilentlyContinue) {
            Write-LogMessage "  - Executing $invokeFunctionName..." -Level "DEBUG"
            
            # Prepare parameters for the specific report generator
            $reportParams = @{
                ReportDirectory = $ReportDirectory
                JobName         = $JobName
                ReportData      = $ReportData
                GlobalConfig    = $GlobalConfig
                JobConfig       = $JobConfig
                Logger          = ${function:Write-LogMessage} # Pass reference to Write-LogMessage
            }
            
            & $invokeFunctionName @reportParams

        } else {
            Write-LogMessage "[ERROR] Function '$invokeFunctionName' not found in module '$moduleFileName' after import. Report generation failed for type '$reportType'." -Level "ERROR"
        }
    } catch {
        Write-LogMessage "[ERROR] Failed to load or execute report module '$moduleFileName' for type '$reportType'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-ReportGenerator
