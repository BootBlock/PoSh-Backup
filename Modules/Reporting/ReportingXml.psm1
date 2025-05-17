<#
.SYNOPSIS
    Generates XML (Extensible Markup Language) reports for PoSh-Backup jobs using
    PowerShell's 'Export-Clixml' format. This format serialises PowerShell objects,
    including their type information, making it suitable for re-importing into PowerShell
    with high fidelity.

.DESCRIPTION
    This module creates an XML representation of the backup job's report data.
    It utilises PowerShell's native 'Export-Clixml' cmdlet, which produces a detailed
    XML structure that accurately represents PowerShell objects. The '$ReportData' hashtable
    is first cast to a [PSCustomObject] to ensure proper serialisation by 'Export-Clixml'.

    The resulting .xml file can be easily re-hydrated into a PowerShell object using
    'Import-Clixml', preserving the original data structure and types. This makes it
    particularly useful for PowerShell-based post-processing, auditing, or archiving
    of report data.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.2 # Added defensive logger call for PSSA.
    DateCreated:    14-May-2025
    LastModified:   17-May-2025
    Purpose:        XML (specifically PowerShell Clixml) report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-XmlReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a single XML (Clixml) file containing all report data for a PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and serialises
        the entire data structure into a single XML file using PowerShell's 'Export-Clixml'
        cmdlet. The input '$ReportData' hashtable is cast to a [PSCustomObject] before export
        to ensure optimal serialisation. The output file is named using the job name and a timestamp.
        This format is primarily intended for consumption by other PowerShell scripts or for archiving
        data in a way that can be perfectly re-imported into PowerShell.
    .PARAMETER ReportDirectory
        The target directory where the generated XML report file for this job will be saved.
        This path is typically resolved by the main Reporting.psm1 orchestrator.
    .PARAMETER JobName
        The name of the backup job. This is used in the filename of the generated XML report
        to clearly associate it with the job.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
        This entire hashtable (cast to PSCustomObject) will be serialised to a Clixml file.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for logging the XML report generation process itself.
    .EXAMPLE
        # This function is typically called by Reporting.psm1 (orchestrator)
        # $xmlParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports\XML\MyJob"
        #     JobName         = "MyJob"
        #     ReportData      = $JobReportDataObject
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-XmlReport @xmlParams
        #
        # To re-import the data later:
        # $importedData = Import-Clixml -Path "C:\PoShBackup\Reports\XML\MyJob\MyJob_Report_Timestamp.xml"
    .OUTPUTS
        None. This function creates a file in the specified ReportDirectory.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line:
    & $Logger -Message "Invoke-XmlReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] XML Report (Clixml format) generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).xml"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        # Cast ReportData to PSCustomObject for Export-Clixml to ensure it's treated as a single object
        # rather than Export-Clixml trying to process individual hashtable entries.
        [PSCustomObject]$ReportData | Export-Clixml -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - XML report (Export-Clixml format) generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate XML report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] XML Report (Clixml format) generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-XmlReport
