# PowerShell Module: Reporting.psm1 (Orchestrator)
# Description: Dispatches report generation to specific format modules.
# Version: 2.1 (Updated module paths for subdirectory structure) 

function Invoke-ReportGenerator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory, # This is the base directory like "Reports"
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)] 
        [hashtable]$JobConfig 
    )

    $reportTypeSetting = Get-ConfigValue -ConfigObject $JobConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ReportGeneratorType' -DefaultValue "HTML")
    # Handle if ReportGeneratorType is an array (e.g., from user config) - take the first valid one or default
    $reportTypesToGenerate = @()
    if ($reportTypeSetting -is [array]) {
        $reportTypesToGenerate = $reportTypeSetting | ForEach-Object { $_.ToString().ToUpperInvariant() }
    } else {
        $reportTypesToGenerate = @($reportTypeSetting.ToString().ToUpperInvariant())
    }

    foreach ($reportType in $reportTypesToGenerate) {
        Write-LogMessage "`n[INFO] Report generation requested. Type: '$reportType' for job '$JobName'." -Level "INFO"

        if ($reportType -eq "NONE") {
            Write-LogMessage "  - Report generation is set to 'None' for this type. Skipping." -Level "INFO"
            continue
        }

        $moduleSubPath = "Reporting" # New subdirectory
        $moduleFileName = "Reporting$($reportType).psm1" 
        $invokeFunctionName = "Invoke-$($reportType)Report" 

        $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
        if ([string]::IsNullOrWhiteSpace($mainScriptRoot)) {
            Write-LogMessage "[ERROR] _PoShBackup_PSScriptRoot not found in GlobalConfig. Cannot determine path for report modules." -Level "ERROR"
            continue
        }
        # MODIFIED PATH:
        $reportModulePath = Join-Path -Path $mainScriptRoot -ChildPath "Modules\$moduleSubPath\$moduleFileName"

        if (-not (Test-Path -LiteralPath $reportModulePath -PathType Leaf)) {
            Write-LogMessage "[WARNING] Report module file '$moduleFileName' not found at '$reportModulePath' for type '$reportType'. Skipping this report type." -Level "WARNING"
            continue
        }

        try {
            Write-LogMessage "  - Attempting to load report module: $moduleFileName" -Level "DEBUG"
            Import-Module -Name $reportModulePath -Force -ErrorAction Stop
            
            if (Get-Command $invokeFunctionName -ErrorAction SilentlyContinue) {
                Write-LogMessage "  - Executing $invokeFunctionName..." -Level "DEBUG"
                
                # Determine specific directory for this report type, defaulting to $ReportDirectory
                $typeSpecificDirKey = "$($reportType)ReportDirectory" # e.g. HtmlReportDirectory, CsvReportDirectory
                $specificReportDirectory = Get-ConfigValue -ConfigObject $JobConfig -Key $typeSpecificDirKey -DefaultValue `
                                            (Get-ConfigValue -ConfigObject $GlobalConfig -Key $typeSpecificDirKey -DefaultValue $ReportDirectory)

                if (-not ([System.IO.Path]::IsPathRooted($specificReportDirectory))) {
                    $specificReportDirectory = Join-Path -Path $mainScriptRoot -ChildPath $specificReportDirectory
                }
                 # Ensure the specific directory exists
                if (-not (Test-Path -LiteralPath $specificReportDirectory -PathType Container)) {
                    Write-LogMessage "[INFO] Report directory '$specificReportDirectory' for type '$reportType' does not exist. Attempting to create..." -Level "INFO"
                    try {
                        New-Item -Path $specificReportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        Write-LogMessage "  - Report directory '$specificReportDirectory' created successfully." -ForegroundColour $Global:ColourSuccess
                    } catch {
                        Write-LogMessage "[WARNING] Failed to create report directory '$specificReportDirectory'. Report for type '$reportType' might be skipped. Error: $($_.Exception.Message)" -Level "WARNING"
                        continue # Skip this report type if its directory can't be made
                    }
                }


                $reportParams = @{
                    ReportDirectory = $specificReportDirectory # Use the potentially type-specific directory
                    JobName         = $JobName
                    ReportData      = $ReportData
                    GlobalConfig    = $GlobalConfig
                    JobConfig       = $JobConfig
                    Logger          = ${function:Write-LogMessage} 
                }
                
                & $invokeFunctionName @reportParams

            } else {
                Write-LogMessage "[ERROR] Function '$invokeFunctionName' not found in module '$moduleFileName' after import. Report generation failed for type '$reportType'." -Level "ERROR"
            }
        } catch {
            Write-LogMessage "[ERROR] Failed to load or execute report module '$moduleFileName' for type '$reportType'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } # End foreach $reportType
}

Export-ModuleMember -Function Invoke-ReportGenerator
