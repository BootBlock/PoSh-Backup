# Tests\Modules\Utilities\FileUtils.Tests.ps1 (Pester 5 - Idiomatic Mocks & Assertions)

function Write-LogMessage { 
    param($Message, $ForegroundColour, $NoNewLine, $Level, $NoTimestampToLogFile) 
}

function Get-ArchiveSizeFormatted-LocalTest-TopLevel-Idiomatic { 
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

function Get-PoshBackupFileHash-LocalTest-TopLevel-Idiomatic { 
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
            $fileHashObject = Get-FileHash -LiteralPath $FilePath -Algorithm $Algorithm -ErrorAction Stop # Call actual cmdlet
        }
        
        if ($null -ne $fileHashObject -and -not [string]::IsNullOrWhiteSpace($fileHashObject.Hash)) { return $fileHashObject.Hash.ToUpperInvariant() }
        else { Write-LogMessage -Message "[WARNING] FileUtils LocalTest: Get-FileHash command returned no hash or an empty hash for '$FilePath'." -Level "WARNING"; return $null }
    } catch { 
        Write-LogMessage -Message "[ERROR] FileUtils LocalTest: Failed to generate $Algorithm hash for '$FilePath'. Error: $($_.Exception.Message)" -Level "ERROR"; return $null 
    }
}

BeforeAll {
    $currentTestScriptFileFullPath = $MyInvocation.MyCommand.ScriptBlock.File
    . $currentTestScriptFileFullPath 
    Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Self dot-sourced '$currentTestScriptFileFullPath'."

    # Mock Write-LogMessage ONCE for the entire file. Make it Verifiable.
    Mock Write-LogMessage -MockWith { 
        param($Message, $ForegroundColour, $NoNewLine, $Level, $NoTimestampToLogFile)
        # This scriptblock can be empty if we only use Should -Invoke with -ParameterFilter
        # Or it can collect to an array if we need to inspect messages for tests that don't use Should -Invoke
        # For simplicity with Should -Invoke, often an empty scriptblock is fine for the mock itself.
        # However, to keep the debug HIT message:
        Write-Host "MOCKED Write-LogMessage HIT! Level: '$Level', Message: '$Message'"
    } -Verifiable
    Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Mocked Write-LogMessage globally for this test file."

    $script:GetArchiveSizeFormattedLocal_Idiomatic_FU = ${function:Get-ArchiveSizeFormatted-LocalTest-TopLevel-Idiomatic}
    $script:GetPoshBackupFileHashLocal_Idiomatic_FU = ${function:Get-PoshBackupFileHash-LocalTest-TopLevel-Idiomatic}

    if (-not $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -or -not $script:GetPoshBackupFileHashLocal_Idiomatic_FU) {
        throw "Failed to create script-scoped references to top-level FileUtils test functions."
    }
    Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Got references to top-level FileUtils test functions."
}

Describe "Get-ArchiveSizeFormatted Function (Locally Defined Logic)" {
    # BeforeEach is not strictly needed here if Should -Invoke handles state per It block.
    # If other tests in this Describe need the log array, we can add it back.

    Context "With byte values" { 
        It "should format bytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -Bytes 500) | Should -Be "500 Bytes" }
        It "should format kilobytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -Bytes 1536) | Should -Be "1.50 KB" }
        It "should format megabytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -Bytes 2097152) | Should -Be "2.00 MB" }
        It "should format gigabytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -Bytes 1610612736) | Should -Be "1.50 GB" }
        It "should handle zero bytes" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -Bytes 0) | Should -Be "0 Bytes" }
    }

    Context "With file paths" {
        $script:nonExistentFileForSizeTestLocal_Idiomatic_FU = "" 
        $script:tempFileForSizeTestLocal_Idiomatic_FU = ""      

        BeforeEach {
            $script:nonExistentFileForSizeTestLocal_Idiomatic_FU = Join-Path $env:TEMP "non_existent_poshbackup_test_file_$(Get-Random).tmp"
            if (Test-Path -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU -Force -ErrorAction SilentlyContinue }
            $script:tempFileForSizeTestLocal_Idiomatic_FU = "" 
        }
        AfterEach {
            if (-not [string]::IsNullOrEmpty($script:tempFileForSizeTestLocal_Idiomatic_FU) -and (Test-Path -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU)) { Remove-Item -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU -Force -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrEmpty($script:nonExistentFileForSizeTestLocal_Idiomatic_FU) -and (Test-Path -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU)) { Remove-Item -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU -Force -ErrorAction SilentlyContinue }
        }

        It "should return 'File not found' and log an error" { 
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -PathToArchive $script:nonExistentFileForSizeTestLocal_Idiomatic_FU) | Should -Be "File not found"
            Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
        }
        It "should correctly format the size of an existing empty file" { 
            $script:tempFileForSizeTestLocal_Idiomatic_FU = (New-TemporaryFile).FullName
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -PathToArchive $script:tempFileForSizeTestLocal_Idiomatic_FU) | Should -Be "0 Bytes"
        }
        It "should correctly format the size of an existing small file (KB)" { 
            $script:tempFileForSizeTestLocal_Idiomatic_FU = (New-TemporaryFile).FullName
            Set-Content -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU -Value ("A" * 2048) 
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU -PathToArchive $script:tempFileForSizeTestLocal_Idiomatic_FU) | Should -Be "2.00 KB"
        }
    }
}

Describe "Get-PoshBackupFileHash Function (Locally Defined Logic)" {
    $script:tempFileForHashTestLocal_Idiomatic_FU_Hash = "" 
    $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash = ""
    $knownContentForHashLocal_Idiomatic_FU_Hash = "PoShBackupTestString"
    $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash = "" 

    BeforeEach {
        # $script:GlobalFileUtilsMockedLogs_SRAFixed.Clear() # Not needed if using Should -Invoke
        $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash = Join-Path $env:TEMP "non_existent_hash_test_file_$(Get-Random).tmp"
        if (Test-Path -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash -Force -ErrorAction SilentlyContinue }
        
        $tempFileObj = New-TemporaryFile
        $script:tempFileForHashTestLocal_Idiomatic_FU_Hash = $tempFileObj.FullName
        [System.IO.File]::WriteAllText($script:tempFileForHashTestLocal_Idiomatic_FU_Hash, $knownContentForHashLocal_Idiomatic_FU_Hash, [System.Text.Encoding]::UTF8)
        $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash = (Get-FileHash -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    AfterEach {
        if (-not [string]::IsNullOrEmpty($script:tempFileForHashTestLocal_Idiomatic_FU_Hash) -and (Test-Path -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash)) { Remove-Item -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash -Force -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrEmpty($script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash) -and (Test-Path -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash)) { Remove-Item -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash -Force -ErrorAction SilentlyContinue }
    }

    It "should return the correct SHA256 hash for a file" { 
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU -FilePath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash -Algorithm "SHA256"
        $result | Should -Be $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash
    }
    It "should return `$null for a non-existent file" { 
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU -FilePath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash -Algorithm "SHA256"
        $result | Should -BeNullOrEmpty
    }
    It "should log an error when file is not found" {
        & $script:GetPoshBackupFileHashLocal_Idiomatic_FU -FilePath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash -Algorithm "SHA256" | Out-Null
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
    }
    It "should handle Get-FileHash throwing an error" {
        $mockedGetFileHashWithError = {
            param($LiteralPath, $Algorithm, $ErrorAction) # Match expected params
            # Write-Host "MOCKED Get-FileHash (via scriptblock) is CALLED for path '$LiteralPath' with algo '$Algorithm' AND WILL THROW"
            throw "Simulated Get-FileHash error from mock scriptblock"
        }
        
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU -FilePath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash -Algorithm "SHA256" -InjectedFileHashCommand $mockedGetFileHashWithError
        $result | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*Failed to generate SHA256 hash*" -and $Message -like "*Simulated Get-FileHash error from mock scriptblock*" }
    }
}
