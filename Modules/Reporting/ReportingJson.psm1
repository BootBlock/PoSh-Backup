# PowerShell Module: ReportingJson.psm1
# Description: Generates JSON reports for PoSh-Backup.
# Version: 1.0

function Invoke-JsonReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData, # Entire report data structure
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig, # Included for consistency, might be useful for context
        [Parameter(Mandatory=$true)] 
        [hashtable]$JobConfig,    # Included for consistency
        [Parameter(Mandatory=$false)]
        [scriptblock]$Logger = $null
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour = $Global:ColourInfo)
        if ($null -ne $Logger) { & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour } 
        else { Write-Host "[$Level] (ReportingJsonDirect) $Message" }
    }

    & $LocalWriteLog -Message "[INFO] JSON Report generation started for job '$JobName'." -Level "INFO"
    
    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).json"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        # Convert the entire ReportData hashtable to JSON. 
        # Depth 10 should be sufficient for nested objects like LogEntries.
        # The default depth of ConvertTo-Json is 2, which is often too shallow for complex objects.
        $ReportData | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - JSON report generated: $reportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate JSON report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }
}

Export-ModuleMember -Function Invoke-JsonReport
