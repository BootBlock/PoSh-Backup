# Tests\Modules\Utilities\FileUtils.Tests.ps1 (Pester 5 - Cleaned Up)

# Define a dummy Write-LogMessage so Pester's Mock command can find it.
function Write-LogMessage { 
    param($Message, $ForegroundColour, $NoNewLine, $Level, $NoTimestampToLogFile) 
    # This dummy is intentionally empty as it will be mocked.
}

# Define local test versions of functions from FileUtils.psm1
function Get-ArchiveSizeFormatted-Local { 
    [CmdletBinding(DefaultParameterSetName = 'Path')] 
    param(
        [Parameter(ParameterSetName = 'Bytes', Mandatory = $true)]
        [long]$Bytes,
        [Parameter(ParameterSetName = 'Path', Mandatory = $true)]
        [string]$PathToArchive
    )
    $FormattedSize = "N/A"; $ActualBytes = 0
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (Test-Path -LiteralPath $PathToArchive -PathType Leaf) {
                $ArchiveFile = Get-Item -LiteralPath $PathToArchive -ErrorAction Stop; $ActualBytes = $ArchiveFile.Length
            } else { 
                Write-LogMessage -Message "[ERROR] FileUtils LocalTest: File not found at '$PathToArchive' for size formatting." -Level "ERROR" 
                return "File not found" 
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'Bytes') { $ActualBytes = $Bytes }
        else { Write-LogMessage -Message "[ERROR] FileUtils LocalTest: Invalid parameter set used." -Level "ERROR"; return "Error: Invalid parameters" }
        
        if ($ActualBytes -ge 1GB) { $FormattedSize = "{0:N2} GB" -f ($ActualBytes / 1GB) }
        elseif ($ActualBytes -ge 1MB) { $FormattedSize = "{0:N2} MB" -f ($ActualBytes / 1MB) }
        elseif ($ActualBytes -ge 1KB) { $FormattedSize = "{0:N2} KB" -f ($ActualBytes / 1KB) }
        else { $FormattedSize = "$ActualBytes Bytes" }
    } catch { Write-LogMessage -Message "[WARNING] FileUtils LocalTest: Error getting file size. Path: '$PathToArchive', Bytes: '$Bytes'. Error: $($_.Exception.Message)" -Level "WARNING"; $FormattedSize = "Error getting size" }
    return $FormattedSize
}

function Get-PoshBackupFileHash-Local { 
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$FilePath,
        [Parameter(Mandatory=$true)] [ValidateSet("SHA1","SHA256","SHA384","SHA512","MD5")] [string]$Algorithm,
        [Parameter(Mandatory=$false)] 
        [scriptblock]$InjectedFileHashCommand = $null 
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { 
        Write-LogMessage -Message "[ERROR] FileUtils LocalTest: File not found at '$FilePath'. Cannot generate hash." -Level "ERROR"
        return $null 
    }
    try {
        $fileHashObject = $null
        if ($null -ne $InjectedFileHashCommand) {
            $fileHashObject = & $InjectedFileHashCommand -LiteralPath $FilePath -Algorithm $Algorithm -ErrorAction Stop 
        } else {
            $fileHashObject = Get-FileHash -LiteralPath $FilePath -Algorithm $Algorithm -ErrorAction Stop 
        }
        
        if ($null -ne $fileHashObject -and -not [string]::IsNullOrWhiteSpace($fileHashObject.Hash)) { return $fileHashObject.Hash.ToUpperInvariant() }
        else { Write-LogMessage -Message "[WARNING] FileUtils LocalTest: Get-FileHash command returned no hash or an empty hash for '$FilePath'." -Level "WARNING"; return $null }
    } catch { 
        Write-LogMessage -Message "[ERROR] FileUtils LocalTest: Failed to generate $Algorithm hash for '$FilePath'. Error: $($_.Exception.Message)" -Level "ERROR"; return $null 
    }
}

BeforeAll {
    $currentTestScriptFileFullPath = $MyInvocation.MyCommand.ScriptBlock.File
    . $currentTestScriptFileFullPath # Dot-source self to make top-level functions available

    $script:FileUtils_LogStore = [System.Collections.Generic.List[object]]::new()
    Mock Write-LogMessage -MockWith { 
        param($Message, $ForegroundColour, $NoNewLine, $Level, $NoTimestampToLogFile)
        $script:FileUtils_LogStore.Add(@{Message = $Message; Level = $Level; Colour = $ForegroundColour})
    } -Verifiable # Make it verifiable for Should -Invoke
    
    $script:fnGetSize = ${function:Get-ArchiveSizeFormatted-Local}
    $script:fnGetHash = ${function:Get-PoshBackupFileHash-Local}

    if (-not $script:fnGetSize -or -not $script:fnGetHash) {
        throw "Failed to create script-scoped references to local FileUtils test functions."
    }
}

Describe "Get-ArchiveSizeFormatted Function (Locally Defined Logic)" {
    BeforeEach { $script:FileUtils_LogStore.Clear() }

    Context "With byte values" { 
        It "should format bytes correctly" { (& $script:fnGetSize -Bytes 500) | Should -Be "500 Bytes" }
        It "should format kilobytes correctly" { (& $script:fnGetSize -Bytes 1536) | Should -Be "1.50 KB" }
        It "should format megabytes correctly" { (& $script:fnGetSize -Bytes 2097152) | Should -Be "2.00 MB" }
        It "should format gigabytes correctly" { (& $script:fnGetSize -Bytes 1610612736) | Should -Be "1.50 GB" }
        It "should handle zero bytes" { (& $script:fnGetSize -Bytes 0) | Should -Be "0 Bytes" }
    }

    Context "With file paths" {
        $script:nonExistentFile = "" 
        $script:tempFile = ""      

        BeforeEach {
            $script:FileUtils_LogStore.Clear() 
            $script:nonExistentFile = Join-Path $env:TEMP "non_existent_poshbackup_test_file_$(Get-Random).tmp"
            if (Test-Path -LiteralPath $script:nonExistentFile -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFile -Force -ErrorAction SilentlyContinue }
            $script:tempFile = "" 
        }
        AfterEach {
            if (-not [string]::IsNullOrEmpty($script:tempFile) -and (Test-Path -LiteralPath $script:tempFile)) { Remove-Item -LiteralPath $script:tempFile -Force -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrEmpty($script:nonExistentFile) -and (Test-Path -LiteralPath $script:nonExistentFile)) { Remove-Item -LiteralPath $script:nonExistentFile -Force -ErrorAction SilentlyContinue }
        }

        It "should return 'File not found' and log an error" { 
            (& $script:fnGetSize -PathToArchive $script:nonExistentFile) | Should -Be "File not found"
            Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
        }
        It "should correctly format the size of an existing empty file" { 
            $script:tempFile = (New-TemporaryFile).FullName
            (& $script:fnGetSize -PathToArchive $script:tempFile) | Should -Be "0 Bytes"
        }
        It "should correctly format the size of an existing small file (KB)" { 
            $script:tempFile = (New-TemporaryFile).FullName
            Set-Content -LiteralPath $script:tempFile -Value ("A" * 2048) 
            (& $script:fnGetSize -PathToArchive $script:tempFile) | Should -Be "2.00 KB"
        }
    }
}

Describe "Get-PoshBackupFileHash Function (Locally Defined Logic)" {
    $script:tempFileHash = "" 
    $script:nonExistentFileHash = ""
    $knownContentHash = "PoShBackupTestString"
    $script:KnownSHA256Hash = "" 

    BeforeEach {
        $script:FileUtils_LogStore.Clear() 
        $script:nonExistentFileHash = Join-Path $env:TEMP "non_existent_hash_test_file_$(Get-Random).tmp"
        if (Test-Path -LiteralPath $script:nonExistentFileHash -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFileHash -Force -ErrorAction SilentlyContinue }
        
        $tempFileObj = New-TemporaryFile
        $script:tempFileHash = $tempFileObj.FullName
        [System.IO.File]::WriteAllText($script:tempFileHash, $knownContentHash, [System.Text.Encoding]::UTF8)
        $script:KnownSHA256Hash = (Get-FileHash -LiteralPath $script:tempFileHash -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    AfterEach {
        if (-not [string]::IsNullOrEmpty($script:tempFileHash) -and (Test-Path -LiteralPath $script:tempFileHash)) { Remove-Item -LiteralPath $script:tempFileHash -Force -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrEmpty($script:nonExistentFileHash) -and (Test-Path -LiteralPath $script:nonExistentFileHash)) { Remove-Item -LiteralPath $script:nonExistentFileHash -Force -ErrorAction SilentlyContinue }
    }

    It "should return the correct SHA256 hash for a file" { 
        $result = & $script:fnGetHash -FilePath $script:tempFileHash -Algorithm "SHA256"
        $result | Should -Be $script:KnownSHA256Hash
    }
    It "should return `$null for a non-existent file" { 
        $result = & $script:fnGetHash -FilePath $script:nonExistentFileHash -Algorithm "SHA256"
        $result | Should -BeNullOrEmpty
    }
    It "should log an error when file is not found" {
        & $script:fnGetHash -FilePath $script:nonExistentFileHash -Algorithm "SHA256" | Out-Null
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
    }
    It "should handle Get-FileHash throwing an error" {
        $mockedGetFileHashWithError = {
            param($LiteralPath, $Algorithm, $ErrorAction)
            throw "Simulated Get-FileHash error from mock scriptblock"
        }
        
        $result = & $script:fnGetHash -FilePath $script:tempFileHash -Algorithm "SHA256" -InjectedFileHashCommand $mockedGetFileHashWithError
        $result | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*Failed to generate SHA256 hash*" -and $Message -like "*Simulated Get-FileHash error from mock scriptblock*" }
    }
}
