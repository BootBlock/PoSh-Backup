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
        [scriptblock]$InjectedFileHashCommand = $null # Changed from default ${function:Get-FileHash}
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { 
        Write-LogMessage -Message "[ERROR] FileUtils LocalTest: File not found at '$FilePath'. Cannot generate hash." -Level "ERROR"
        return $null 
    }
    try {
        $fileHashObject = $null
        if ($null -ne $InjectedFileHashCommand) {
            # Call the injected command (our mock)
            $fileHashObject = & $InjectedFileHashCommand -LiteralPath $FilePath -Algorithm $Algorithm -ErrorAction Stop 
        } else {
            # Call the actual Get-FileHash cmdlet directly
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
    . $currentTestScriptFileFullPath 
    #Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Self dot-sourced '$currentTestScriptFileFullPath'."

    # Mock Write-LogMessage ONCE for the entire file. Make it Verifiable.
    Mock Write-LogMessage -MockWith { 
        param($Message, $ForegroundColour, $NoNewLine, $Level, $NoTimestampToLogFile)
        # This scriptblock can be empty if we only use Should -Invoke with -ParameterFilter
        # Adding to a log array is only needed if we want to inspect messages outside of Should -Invoke
        # For debugging the "MOCKED Write-LogMessage HIT" is useful.
        # Write-Host "MOCKED Write-LogMessage HIT! Level: '$Level', Message: '$Message'" 
    } -Verifiable # -Verifiable is key for Should -Invoke
    #Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Mocked Write-LogMessage globally for this test file."

    $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 = ${function:Get-ArchiveSizeFormatted-LocalTest-TopLevel-Idiomatic}
    $script:GetPoshBackupFileHashLocal_Idiomatic_FU2 = ${function:Get-PoshBackupFileHash-LocalTest-TopLevel-Idiomatic}

    if (-not $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -or -not $script:GetPoshBackupFileHashLocal_Idiomatic_FU2) {
        throw "Failed to create script-scoped references to top-level FileUtils test functions."
    }
    #Write-Host "DEBUG FileUtils.Tests: (Pester 5.x) Got references to top-level FileUtils test functions."
}

Describe "Get-ArchiveSizeFormatted Function (Locally Defined Logic)" {
    # No BeforeEach needed for log clearing if using Should -Invoke correctly for each test

    Context "With byte values" { 
        It "should format bytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -Bytes 500) | Should -Be "500 Bytes" }
        It "should format kilobytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -Bytes 1536) | Should -Be "1.50 KB" }
        It "should format megabytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -Bytes 2097152) | Should -Be "2.00 MB" }
        It "should format gigabytes correctly" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -Bytes 1610612736) | Should -Be "1.50 GB" }
        It "should handle zero bytes" { (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -Bytes 0) | Should -Be "0 Bytes" }
    }

    Context "With file paths" {
        $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2 = "" 
        $script:tempFileForSizeTestLocal_Idiomatic_FU2 = ""      

        BeforeEach {
            # $script:GlobalFileUtilsMockedLogs_SRAFixed.Clear() # Not needed if using Should -Invoke
            $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2 = Join-Path $env:TEMP "non_existent_poshbackup_test_file_$(Get-Random).tmp"
            if (Test-Path -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2 -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2 -Force -ErrorAction SilentlyContinue }
            $script:tempFileForSizeTestLocal_Idiomatic_FU2 = "" 
        }
        AfterEach {
            if (-not [string]::IsNullOrEmpty($script:tempFileForSizeTestLocal_Idiomatic_FU2) -and (Test-Path -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU2)) { Remove-Item -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU2 -Force -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrEmpty($script:nonExistentFileForSizeTestLocal_Idiomatic_FU2) -and (Test-Path -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2)) { Remove-Item -LiteralPath $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2 -Force -ErrorAction SilentlyContinue }
        }

        It "should return 'File not found' and log an error" { 
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -PathToArchive $script:nonExistentFileForSizeTestLocal_Idiomatic_FU2) | Should -Be "File not found"
            Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
        }
        It "should correctly format the size of an existing empty file" { 
            $script:tempFileForSizeTestLocal_Idiomatic_FU2 = (New-TemporaryFile).FullName
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -PathToArchive $script:tempFileForSizeTestLocal_Idiomatic_FU2) | Should -Be "0 Bytes"
        }
        It "should correctly format the size of an existing small file (KB)" { 
            $script:tempFileForSizeTestLocal_Idiomatic_FU2 = (New-TemporaryFile).FullName
            Set-Content -LiteralPath $script:tempFileForSizeTestLocal_Idiomatic_FU2 -Value ("A" * 2048) 
            (& $script:GetArchiveSizeFormattedLocal_Idiomatic_FU2 -PathToArchive $script:tempFileForSizeTestLocal_Idiomatic_FU2) | Should -Be "2.00 KB"
        }
    }
}

Describe "Get-PoshBackupFileHash Function (Locally Defined Logic)" {
    $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 = "" 
    $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 = ""
    $knownContentForHashLocal_Idiomatic_FU_Hash2 = "PoShBackupTestString"
    $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash2 = "" 

    BeforeEach {
        # $script:GlobalFileUtilsMockedLogs_SRAFixed.Clear() # Not needed if using Should -Invoke
        $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 = Join-Path $env:TEMP "non_existent_hash_test_file_$(Get-Random).tmp"
        if (Test-Path -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 -PathType Leaf) { Remove-Item -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 -Force -ErrorAction SilentlyContinue }
        
        $tempFileObj = New-TemporaryFile
        $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 = $tempFileObj.FullName
        [System.IO.File]::WriteAllText($script:tempFileForHashTestLocal_Idiomatic_FU_Hash2, $knownContentForHashLocal_Idiomatic_FU_Hash2, [System.Text.Encoding]::UTF8)
        $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash2 = (Get-FileHash -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    AfterEach {
        if (-not [string]::IsNullOrEmpty($script:tempFileForHashTestLocal_Idiomatic_FU_Hash2) -and (Test-Path -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2)) { Remove-Item -LiteralPath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 -Force -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrEmpty($script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2) -and (Test-Path -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2)) { Remove-Item -LiteralPath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 -Force -ErrorAction SilentlyContinue }
    }

    It "should return the correct SHA256 hash for a file" { 
        # This test now calls the function which will use the REAL Get-FileHash by default
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU2 -FilePath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 -Algorithm "SHA256"
        $result | Should -Be $script:KnownSHA256ForHashTestLocal_Idiomatic_FU_Hash2
    }
    It "should return `$null for a non-existent file" { 
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU2 -FilePath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 -Algorithm "SHA256"
        $result | Should -BeNullOrEmpty
    }
    It "should log an error when file is not found" {
        & $script:GetPoshBackupFileHashLocal_Idiomatic_FU2 -FilePath $script:nonExistentFileForHashTestLocal_Idiomatic_FU_Hash2 -Algorithm "SHA256" | Out-Null
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*File not found at*" }
    }
    It "should handle Get-FileHash throwing an error" {
        $mockedGetFileHashWithError = {
            param($LiteralPath, $Algorithm, $ErrorAction)
            # Write-Host "MOCKED Get-FileHash (via scriptblock) is CALLED for path '$LiteralPath' with algo '$Algorithm' AND WILL THROW"
            throw "Simulated Get-FileHash error from mock scriptblock"
        }
        
        $result = & $script:GetPoshBackupFileHashLocal_Idiomatic_FU2 -FilePath $script:tempFileForHashTestLocal_Idiomatic_FU_Hash2 -Algorithm "SHA256" -InjectedFileHashCommand $mockedGetFileHashWithError
        $result | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-LogMessage -Times 1 -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*Failed to generate SHA256 hash*" -and $Message -like "*Simulated Get-FileHash error from mock scriptblock*" }
    }
}
