#Requires -Version 5.1
<#
    Tests for Core/Guards.ps1.

    Get-GuardBlockReason takes an injectable GetProcessCount, so the process
    guard is exercised without depending on what happens to be running on the
    machine executing the suite. Rather than a spy variable, the fakes answer
    only to one exact name -- so a passing test is evidence of WHAT was looked
    up, not merely that something was.

    Get-CpuPercent is deliberately driven through the REAL GetSystemTimes call.
    The v2.2 postmortem on [Environment]::TickCount64 makes the case: every
    evaluator test injects its clock, so none of them could catch a platform API
    that silently returned nothing. A seam needs one test that does not use it.

    NB: BeforeEach must live inside a Describe. Pester 6 rejects test setup
    declared directly in the file's root block.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Interop.ps1"
    . "$PSScriptRoot\..\src\Core\Guards.ps1"

    # Answers 1 for one exact name and 0 for anything else, so a test that passes
    # is evidence the guard looked up the name we expect.
    function New-ProcessFake ([string]$Running) {
        return [scriptblock]::Create("param(`$name) if (`$name -eq '$Running') { 1 } else { 0 }")
    }

    $script:NothingRunning = { param($name) 0 }
}

Describe 'Get-GuardBlockReason - network' {

    It 'blocks while throughput is above the threshold' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 250 -ThresholdKbps 100 |
            Should -Match 'network active'
    }

    It 'does not block below the threshold' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 40 -ThresholdKbps 100 |
            Should -BeNullOrEmpty
    }

    # -gt, not -ge: sitting exactly on the threshold is not "above" it.
    It 'does not block exactly at the threshold' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 100 -ThresholdKbps 100 |
            Should -BeNullOrEmpty
    }

    It 'ignores throughput entirely when the guard is off' {
        Get-GuardBlockReason -NetworkGuard $false -CurrentKbps 9999 -ThresholdKbps 100 |
            Should -BeNullOrEmpty
    }

    It 'reports the current rate, rounded, so the banner says why' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 250.46 -ThresholdKbps 100 |
            Should -Be 'network active (250.5 KB/s)'
    }

    It 'blocks on a threshold of zero whenever there is any traffic' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 0.5 -ThresholdKbps 0 |
            Should -Match 'network active'
    }
}

Describe 'Get-GuardBlockReason - process' {

    It 'blocks while the named process is running' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'robocopy' `
            -GetProcessCount (New-ProcessFake 'robocopy') | Should -Match "process 'robocopy' is running"
    }

    It 'does not block when it is not running' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'robocopy' `
            -GetProcessCount $script:NothingRunning | Should -BeNullOrEmpty
    }

    It 'ignores the process entirely when the guard is off' {
        Get-GuardBlockReason -ProcessGuard $false -ProcessName 'robocopy' `
            -GetProcessCount (New-ProcessFake 'robocopy') | Should -BeNullOrEmpty
    }

    It 'does not block on an empty name' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName '' `
            -GetProcessCount (New-ProcessFake '') | Should -BeNullOrEmpty
    }

    It 'does not block on a whitespace-only name' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName '   ' `
            -GetProcessCount (New-ProcessFake '') | Should -BeNullOrEmpty
    }

    It 'trims surrounding whitespace before looking up' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName '  ffmpeg  ' `
            -GetProcessCount (New-ProcessFake 'ffmpeg') | Should -Match "process 'ffmpeg' is running"
    }

    <#
        Regression, shipped through v2.2.

        Get-Process -Name matches the process name WITHOUT its extension, so
        "steam.exe" matched nothing and this guard silently never blocked -- while
        the same text typed on the Triggers tab worked, because that path strips
        the suffix. The fake answers only to 'steam', so this passing is proof the
        lookup used the stripped name.

        A guard that quietly does nothing is worse than no guard at all: the user
        believes the shutdown is being held back while it goes ahead.
    #>
    It 'strips a typed .exe, matching what the Triggers tab does' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'steam.exe' `
            -GetProcessCount (New-ProcessFake 'steam') | Should -Match "process 'steam' is running"
    }

    It 'strips .EXE regardless of case' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'Steam.EXE' `
            -GetProcessCount (New-ProcessFake 'Steam') | Should -Match 'is running'
    }

    It 'strips only a trailing .exe, not one in the middle of a name' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'my.exe.tool' `
            -GetProcessCount (New-ProcessFake 'my.exe.tool') | Should -Match 'is running'
    }

    It 'names the stripped process in the reason, not the typed text' {
        Get-GuardBlockReason -ProcessGuard $true -ProcessName 'steam.exe' `
            -GetProcessCount (New-ProcessFake 'steam') | Should -Be "process 'steam' is running"
    }
}

Describe 'Get-GuardBlockReason - both guards' {

    # Network is checked first, so its reason wins. Only one can be shown in the
    # banner, and re-ordering would silently change what the user is told.
    It 'reports the network reason when both are blocking' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 250 -ThresholdKbps 100 `
            -ProcessGuard $true -ProcessName 'robocopy' `
            -GetProcessCount (New-ProcessFake 'robocopy') | Should -Match 'network active'
    }

    It 'falls through to the process reason when the network is quiet' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 5 -ThresholdKbps 100 `
            -ProcessGuard $true -ProcessName 'robocopy' `
            -GetProcessCount (New-ProcessFake 'robocopy') | Should -Match 'process'
    }

    It 'returns $null when neither blocks' {
        Get-GuardBlockReason -NetworkGuard $true -CurrentKbps 5 -ThresholdKbps 100 `
            -ProcessGuard $true -ProcessName 'robocopy' `
            -GetProcessCount $script:NothingRunning | Should -BeNullOrEmpty
    }

    It 'returns $null when both guards are off' {
        Get-GuardBlockReason | Should -BeNullOrEmpty
    }
}

Describe 'Test-GuardsAllClear' {

    It 'is true when nothing blocks' {
        Test-GuardsAllClear -NetworkGuard $true -CurrentKbps 5 -ThresholdKbps 100 |
            Should -BeTrue
    }

    It 'is false when the network blocks' {
        Test-GuardsAllClear -NetworkGuard $true -CurrentKbps 500 -ThresholdKbps 100 |
            Should -BeFalse
    }

    # It must forward the seam, or it would silently consult the real machine and
    # disagree with Get-GuardBlockReason given identical arguments.
    It 'is false when the process blocks, through the injected lookup' {
        Test-GuardsAllClear -ProcessGuard $true -ProcessName 'ffmpeg' `
            -GetProcessCount (New-ProcessFake 'ffmpeg') | Should -BeFalse
    }

    It 'is true when the injected lookup finds nothing' {
        Test-GuardsAllClear -ProcessGuard $true -ProcessName 'ffmpeg' `
            -GetProcessCount $script:NothingRunning | Should -BeTrue
    }
}

<#
    Get-CpuPercent feeds a resource trigger whose job is to power the machine
    off. The contract matters more than any individual branch:

        the result is $null, or a number in [0, 100]

    never NaN, never infinite, never negative, never above 100. Anything outside
    that range, compared against a user threshold, is a shutdown decision made on
    a nonsense reading.
#>
Describe 'Get-CpuPercent contract' {

    BeforeEach { Reset-CpuSampler }
    AfterEach  { Reset-CpuSampler }

    <#
        Load-bearing, and the reason the function returns $null rather than 0:
        the value is a delta between two samples, so the first call has nothing
        to compare against. A caller reading "no data" as "0%, therefore idle"
        would fire a resource trigger on a fully busy machine.
    #>
    It 'returns $null for the priming sample' {
        Get-CpuPercent | Should -BeNullOrEmpty
    }

    It 'returns a real reading once it has two samples' {
        Get-CpuPercent | Out-Null
        Start-Sleep -Milliseconds 120
        $cpu = Get-CpuPercent

        $cpu | Should -Not -BeNullOrEmpty
        $cpu | Should -BeOfType [double]
    }

    It 'never leaves the 0..100 range across repeated sampling' {
        Get-CpuPercent | Out-Null
        foreach ($i in 1..12) {
            Start-Sleep -Milliseconds 60
            $cpu = Get-CpuPercent
            if ($null -ne $cpu) {
                [double]::IsNaN($cpu)      | Should -BeFalse
                [double]::IsInfinity($cpu) | Should -BeFalse
                $cpu | Should -BeGreaterOrEqual 0
                $cpu | Should -BeLessOrEqual 100
            }
        }
    }

    # Reset-CpuSampler exists so switching trigger kinds or re-arming cannot
    # inherit a stale baseline and compute a delta across an arbitrary gap.
    It 'primes again after a reset' {
        Get-CpuPercent | Out-Null
        Start-Sleep -Milliseconds 120
        Get-CpuPercent | Should -Not -BeNullOrEmpty

        Reset-CpuSampler
        Get-CpuPercent | Should -BeNullOrEmpty
    }
}

<#
    Get-IdleSeconds wraps GetLastInputInfo. Its clock family is load-bearing --
    it reports GetTickCount, the same family the grace abort measures elapsed
    time against, so that the two cannot disagree across a suspend.
#>
Describe 'Get-IdleSeconds' {

    It 'returns a non-negative number' {
        $idle = Get-IdleSeconds
        $idle | Should -Not -BeNullOrEmpty
        $idle | Should -BeGreaterOrEqual 0
    }

    It 'never throws, so a failed read cannot break the tick' {
        { Get-IdleSeconds } | Should -Not -Throw
    }
}

# ── Process picker ────────────────────────────────────────────────────────────

Describe 'Get-ProcessChoices' {

    BeforeEach {
        # Stand-ins for System.Diagnostics.Process. Only the two properties the
        # function reads are modelled, so a test cannot accidentally depend on
        # what is actually running on the machine.
        function New-FakeProc ([string]$Name, [string]$Title = '') {
            [PSCustomObject]@{ ProcessName = $Name; MainWindowTitle = $Title }
        }
    }

    It 'returns nothing for an empty list' {
        @(Get-ProcessChoices @() $true).Count | Should -Be 0
    }

    It 'survives a null list rather than throwing' {
        @(Get-ProcessChoices $null $true).Count | Should -Be 0
    }

    <#
        The trigger engine aggregates by NAME and treats "exited" as "no
        instances left". The picker must present the same unit, or it would
        imply you are choosing one particular window.
    #>
    It 'collapses instances of one name into a single row with a count' {
        $rows = @(Get-ProcessChoices @(
            (New-FakeProc 'chrome' 'Inbox'), (New-FakeProc 'chrome'), (New-FakeProc 'chrome')
        ) $true)
        $rows.Count      | Should -Be 1
        $rows[0].Name    | Should -Be 'chrome'
        $rows[0].Count   | Should -Be 3
        $rows[0].Display | Should -Match '3 running'
    }

    It 'keeps a window title found on any instance of the group' {
        # The windowless instance is first, so a naive "read the first one"
        # implementation would report no title.
        $rows = @(Get-ProcessChoices @(
            (New-FakeProc 'code'), (New-FakeProc 'code' 'main.ps1')
        ) $true)
        $rows[0].HasWindow | Should -BeTrue
        $rows[0].Title     | Should -Be 'main.ps1'
    }

    It 'hides background processes unless asked' {
        $procs = @((New-FakeProc 'svchost'), (New-FakeProc 'notepad' 'Untitled'))
        @(Get-ProcessChoices $procs $false).Name | Should -Be 'notepad'
        @(Get-ProcessChoices $procs $true).Count | Should -Be 2
    }

    <#
        A list led by csrss, dwm and svchost is what made the old free-text box
        feel like the easier option, so this ordering is the feature.
    #>
    It 'sorts windowed processes above background ones, then alphabetically' {
        $rows = @(Get-ProcessChoices @(
            (New-FakeProc 'zzz-service'), (New-FakeProc 'aaa-service'),
            (New-FakeProc 'notepad' 'Untitled'), (New-FakeProc 'ffmpeg' 'encoding')
        ) $true)
        @($rows | ForEach-Object { $_.Name }) | Should -Be @('ffmpeg', 'notepad', 'aaa-service', 'zzz-service')
    }

    <#
        Unelevated - which this app now always is - reading MainWindowTitle on a
        process owned by another account can throw. That must cost the title,
        not the whole list.
    #>
    It 'keeps going when MainWindowTitle throws' {
        $hostile = [PSCustomObject]@{ ProcessName = 'guarded' }
        $hostile | Add-Member -MemberType ScriptProperty -Name MainWindowTitle -Value { throw 'Access is denied' }

        $rows = @(Get-ProcessChoices @($hostile, (New-FakeProc 'notepad' 'Untitled')) $true)
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.Name -eq 'guarded' }).HasWindow | Should -BeFalse
    }

    It 'ignores entries with no usable name' {
        @(Get-ProcessChoices @((New-FakeProc '  '), (New-FakeProc 'notepad' 'x')) $true).Count | Should -Be 1
    }

    It 'trims a long window title so it cannot widen the dropdown' {
        $long = 'x' * 200
        $rows = @(Get-ProcessChoices @((New-FakeProc 'app' $long)) $true)
        $rows[0].Display.Length | Should -BeLessThan 70
    }

    It 'omits the count for a single instance' {
        $rows = @(Get-ProcessChoices @((New-FakeProc 'ffmpeg' 'encode')) $true)
        $rows[0].Display | Should -Not -Match 'running'
    }
}
