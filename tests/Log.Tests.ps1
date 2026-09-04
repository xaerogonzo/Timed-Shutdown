#Requires -Version 5.1
<#
    Tests for Core/Log.ps1.

    Every test redirects the log into a fresh temp directory via Set-LogFilePath,
    so a run can never append to (or roll) the real log of a live install.

    NB: BeforeEach must live inside a Describe. Pester 6 rejects test setup
    declared directly in the file's root block.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Core\Log.ps1"

    function New-Sandbox {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_logtests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    # The separator under test. Referred to by code point rather than typed,
    # because a literal tab in a test file is invisible in review and survives
    # exactly the kind of editor round-trip that would make this test lie.
    $script:TAB = [char]9
}

Describe 'Write-Log record format' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-LogFilePath (Join-Path $sandbox 'log.txt')
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    <#
        Regression, shipped in every build through v2.2.

        The format string was SINGLE-quoted -- '{0}`t{1}' -- and PowerShell
        processes escape sequences only inside double quotes. So `t was never a
        tab; it was the two literal characters ` and t, written between every
        field of every line. The module's own doc comment promised tab-separated
        fields "so the file greps and sorts cleanly", and nothing splitting on
        tabs could read a single line of it.
    #>
    It 'separates fields with a real tab, not a literal backtick-t' {
        Write-Log 'trigger' 'armed' 'kind=process'
        $line = (Get-Content (Get-LogFilePath) -Raw).TrimEnd("`r`n")

        $line.Contains($script:TAB) | Should -BeTrue
        $line.Contains('`t')        | Should -BeFalse
    }

    It 'writes exactly five tab-separated fields' {
        Write-Log 'trigger' 'armed' 'kind=process'
        $line   = (Get-Content (Get-LogFilePath) -Raw).TrimEnd("`r`n")
        $fields = $line.Split($script:TAB)

        $fields.Count | Should -Be 5
        $fields[2]    | Should -Be 'trigger'
        $fields[3]    | Should -Be 'armed'
        $fields[4]    | Should -Be 'kind=process'
    }

    It 'leads with a sortable ISO-8601 timestamp' {
        Write-Log 'app' 'start' ''
        $stamp = (Get-Content (Get-LogFilePath) -Raw).TrimEnd("`r`n").Split($script:TAB)[0]

        $stamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}'
        { [datetime]::Parse($stamp) } | Should -Not -Throw
    }

    It 'still writes five fields when the detail is empty' {
        Write-Log 'app' 'exit' ''
        $line = (Get-Content (Get-LogFilePath) -Raw).TrimEnd("`r`n")
        $line.Split($script:TAB).Count | Should -Be 5
    }

    It 'appends rather than replacing' {
        Write-Log 'app' 'start' 'one'
        Write-Log 'app' 'exit'  'two'
        @(Get-Content (Get-LogFilePath)).Count | Should -Be 2
    }
}

Describe 'Invoke-LogRollover' {

    BeforeEach {
        $sandbox = New-Sandbox
        $logFile = Join-Path $sandbox 'log.txt'
        Set-LogFilePath $logFile

        # A shade over the 256 KB cap. Written directly rather than by logging
        # thousands of lines, which would make the test slow for no extra signal.
        function Set-OversizeLog ([string]$Marker) {
            [System.IO.File]::WriteAllText($logFile, ($Marker + ('x' * 300KB)))
        }
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'does nothing while the file is under the cap' {
        Write-Log 'app' 'start' ''
        Invoke-LogRollover
        Test-Path "$logFile.bak" | Should -BeFalse
    }

    It 'does nothing when there is no file at all' {
        { Invoke-LogRollover } | Should -Not -Throw
        Test-Path "$logFile.bak" | Should -BeFalse
    }

    It 'moves an oversized log aside and starts a fresh one' {
        Set-OversizeLog 'FIRST'
        Write-Log 'app' 'start' 'after-roll'

        Test-Path "$logFile.bak" | Should -BeTrue
        (Get-Content "$logFile.bak" -Raw) | Should -BeLike 'FIRST*'

        # The new file holds only what was written after the roll.
        $now = Get-Content $logFile -Raw
        $now.Length            | Should -BeLessThan 256KB
        $now.Contains('after-roll') | Should -BeTrue
    }

    <#
        Move-Item fails outright when the target exists, so without -Force the
        SECOND rollover throws, the catch swallows it, and the log silently stops
        growing -- the failure being invisible is the point of the test.
    #>
    It 'overwrites an existing .bak on a second rollover' {
        Set-OversizeLog 'FIRST'
        Write-Log 'app' 'start' 'roll-one'

        Set-OversizeLog 'SECOND'
        Write-Log 'app' 'start' 'roll-two'

        (Get-Content "$logFile.bak" -Raw) | Should -BeLike 'SECOND*'
        (Get-Content $logFile -Raw).Contains('roll-two') | Should -BeTrue
    }
}

Describe 'Write-Log never takes the app down' {

    BeforeEach { $sandbox = New-Sandbox }
    AfterEach  { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    <#
        The dispatcher logs once a second and several times per user action. A
        logging failure that propagated would take the window with it, which is a
        far worse outcome than a missing log line.
    #>
    It 'swallows a path whose parent directory cannot be created' {
        # A FILE where the log's parent directory would have to go, so the
        # New-Item that creates the directory cannot succeed.
        $blocker = Join-Path $sandbox 'blocker'
        [System.IO.File]::WriteAllText($blocker, 'not a directory')
        Set-LogFilePath (Join-Path $blocker 'log.txt')

        { Write-Log 'app' 'start' '' } | Should -Not -Throw
    }

    It 'swallows a path on a drive that does not exist' {
        Set-LogFilePath 'Q:\missing\TimedShutdown\log.txt'
        { Write-Log 'app' 'start' '' } | Should -Not -Throw
    }

    <#
        Not throwing is only half the contract. New-Item reports a bad path as a
        NON-terminating error, which try/catch does NOT catch: before v2.3 the
        record escaped into the error stream and only the .NET append that
        followed was actually caught, so the catch was giving false comfort. With
        the dispatcher logging once a second, an unwritable path meant an error
        record on the stream every tick.

        Asserted against the redirected stream rather than $Error, because $Error
        is a history that records caught exceptions too -- it is non-empty either
        way once -ErrorAction Stop routes the failure into the catch, so it cannot
        tell the fixed code from the broken code. What the user actually sees is
        the stream.
    #>
    It 'writes nothing to the error stream when the path is unusable' {
        Set-LogFilePath 'Q:\missing\TimedShutdown\log.txt'
        @(Write-Log 'app' 'start' '' 2>&1) | Should -BeNullOrEmpty
    }

    It 'writes nothing to the error stream when the parent cannot be created' {
        $blocker = Join-Path $sandbox 'blocker'
        [System.IO.File]::WriteAllText($blocker, 'not a directory')
        Set-LogFilePath (Join-Path $blocker 'log.txt')

        @(Write-Log 'app' 'start' '' 2>&1) | Should -BeNullOrEmpty
    }
}
