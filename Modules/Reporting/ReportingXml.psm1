# PowerShell Module: ReportingXml.psm1
# Description: Generates XML reports (PowerShell Clixml format) for PoSh-Backup.
# Version: 1.0

function Invoke-XmlReport {
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
        [Parameter(Mandatory=$false)]
        [scriptblock]$Logger = $null
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour = $Global:ColourInfo)
        if ($null -ne $Logger) { & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour } 
        else { Write-Host "[$Level] (ReportingXmlDirect) $Message" }
    }

    & $LocalWriteLog -Message "[INFO] XML Report (Clixml) generation started for job '$JobName'." -Level "INFO"
        
    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).xml" # Using .xml, though it's Clixml
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        # Export-Clixml serializes PowerShell objects, including type information.
        # It's great for re-importing into PowerShell but less generic for other XML parsers.
        [PSCustomObject]$ReportData | Export-Clixml -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - XML report (Export-Clixml format) generated: $reportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate XML report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }
}

Export-ModuleMember -Function Invoke-XmlReport
