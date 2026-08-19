#Requires -Version 5.1
<#
    Tests for Core/Triggers.ps1 - the state machine and the five evaluators.

    Everything is driven through an injected $Context, so no test depends on real
    machine load, real processes, or the passage of real time. Simulated ticks
    advance a fake clock.

    The invariant tests are the point of this file. Each corresponds to a rule in
    docs/ARCHITECTURE.md, and I1/I2 in particular guard the bug this engine was
    designed to prevent: a trigger that refires forever once you cancel it.
#>

BeforeAll {
    # Interop first: Get-MonotonicMs calls into [WinApi].
    . "$PSScriptRoot\..\src\Interop.ps1"
    . "$PSScriptRoot\..\src\Core\Triggers.ps1"

    # --- simulated world ---
    $script:simNow   = 1000000L
    $script:simProcs = @{}
    $script:simIdle  = 0.0
    $script:simGap   = 1.0

    # Helpers must be defined here, not in a Describe body: Pester runs Describe
    # blocks during discovery, so functions declared there do not exist at run time.
    function DlCtx { New-TriggerContext -NowTicks $script:dlNow }

    function Ctx {
        New-TriggerContext -NowTicks $script:simNow -IdleSec $script:simIdle -TickGapSec $script:simGap `
            -GetProcessCount { param($n) [int]$script:simProcs[$n] }
    }
    function Step ([int]$Seconds = 1, [switch]$UserActive) {
        $script:simNow += ($Seconds * 1000)
        if ($UserActive) { $script:simIdle = 0.0 } else { $script:simIdle += $Seconds }
        $script:simGap = $Seconds
        return (Update-Trigger (Ctx))
    }
    function StepN ([int]$N) { $r = $null; for ($i = 0; $i -lt $N; $i++) { $r = Step 1 }; return $r }

    function Reset-Sim {
        $script:simNow   = 1000000L
        $script:simProcs = @{}
        $script:simIdle  = 0.0
        $script:simGap   = 1.0
        Stop-Trigger 'test'
    }

    # Arms a process trigger and advances it to PRIMED with the target running.
    function Arm-PrimedProcess ([string[]]$Names, [string]$Mode = 'all') {
        foreach ($n in $Names) { $script:simProcs[$n] = 1 }
        Start-Trigger 'process' 'shutdown' @{ Names = $Names; Mode = $Mode } (Ctx) | Out-Null
        StepN ($script:MIN_ARM_SEC + 3) | Out-Null
    }
}

Describe 'Arming' {
    BeforeEach { Reset-Sim }

    It 'does not fire during the minimum arm window' {
        $script:simProcs['notepad'] = 1
        Start-Trigger 'process' 'shutdown' @{ Names = @('notepad'); Mode = 'all' } (Ctx) | Out-Null
        Get-TriggerState | Should -Be 'ARMING'
        $script:simProcs['notepad'] = 0
        $r = StepN ([int]$script:MIN_ARM_SEC - 2)
        $r.Fire | Should -BeFalse
        Get-TriggerState | Should -Not -Be 'GRACE'
    }

    It 'waits for a process that is not running yet rather than firing immediately' {
        $script:simProcs['ffmpeg'] = 0
        Start-Trigger 'process' 'shutdown' @{ Names = @('ffmpeg'); Mode = 'all' } (Ctx) | Out-Null
        StepN 25 | Out-Null
        Get-TriggerState | Should -Be 'WATCHING' -Because 'the target has never been seen running'
    }

    It 'rejects an unknown kind' {
        { Start-Trigger 'telepathy' 'shutdown' @{} (Ctx) } | Should -Throw
    }
}

Describe 'Invariant I1/I2 - no retrigger after a cancelled grace' {
    BeforeEach { Reset-Sim }

    <#
        THE regression test for this engine. Cancelling the countdown leaves the
        condition ("notepad is not running") still true, so a naive predicate loop
        fires again on the very next tick, forever.
    #>
    It 'stays in COOLDOWN while the firing condition remains true' {
        Arm-PrimedProcess @('notepad')
        $script:simProcs['notepad'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        Stop-TriggerGrace 'cancelled' (Ctx) | Out-Null
        Get-TriggerState | Should -Be 'COOLDOWN'

        $fired = $false
        for ($i = 0; $i -lt 180; $i++) { if ((Step 1).Fire) { $fired = $true } }
        $fired | Should -BeFalse -Because 'the condition is still true but no new event occurred'
        Get-TriggerState | Should -Be 'COOLDOWN'
    }

    It 're-arms once a genuine reset transition occurs, and can fire again' {
        Arm-PrimedProcess @('notepad')
        $script:simProcs['notepad'] = 0
        StepN 1 | Out-Null
        Stop-TriggerGrace 'cancelled' (Ctx) | Out-Null
        StepN 5 | Out-Null
        Get-TriggerState | Should -Be 'COOLDOWN'

        $script:simProcs['notepad'] = 1     # the reset transition
        StepN 2 | Out-Null
        Get-TriggerState | Should -Be 'PRIMED'

        $script:simProcs['notepad'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'
    }

    <#
        I2 specifically: RESET must be a transition, not a currently-true
        predicate. In 'any' mode a second target can still be running when
        cooldown begins - that pre-existing state must not clear cooldown.
    #>
    It 'a target already running at cooldown entry does not clear cooldown' {
        $script:simProcs = @{ alpha = 1; beta = 1 }
        Start-Trigger 'process' 'shutdown' @{ Names = @('alpha','beta'); Mode = 'any' } (Ctx) | Out-Null
        StepN 20 | Out-Null
        $script:simProcs['alpha'] = 0       # alpha exits; beta still up
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        Stop-TriggerGrace 'cancelled' (Ctx) | Out-Null
        StepN 30 | Out-Null
        Get-TriggerState | Should -Be 'COOLDOWN' -Because 'beta was already running when cooldown began'

        $script:simProcs['alpha'] = 1       # a target that WAS zero returns
        StepN 2 | Out-Null
        Get-TriggerState | Should -Be 'PRIMED'
    }

    It 'raises Fire exactly once when grace expires' {
        Arm-PrimedProcess @('notepad')
        $script:simProcs['notepad'] = 0
        StepN 1 | Out-Null
        $fires = 0
        for ($i = 0; $i -lt ($script:GRACE_SEC + 20); $i++) { if ((Step 1).Fire) { $fires++ } }
        $fires | Should -Be 1
        Get-TriggerState | Should -Be 'EXECUTING'
    }
}

Describe 'Invariant I3 - snooze needs reset AND expiry' {
    BeforeEach { Reset-Sim }

    It 'does not re-arm while snoozed even though the reset condition is already true' {
        Arm-PrimedProcess @('gamma')
        $script:simProcs['gamma'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        Suspend-Trigger 30 (Ctx) | Out-Null
        $script:simProcs['gamma'] = 1       # reset satisfied immediately
        StepN 10 | Out-Null
        Get-TriggerState | Should -Be 'COOLDOWN' -Because 'the snooze has not expired'

        StepN 30 | Out-Null
        Get-TriggerState | Should -Be 'PRIMED'
    }
}

Describe 'Grace' {
    BeforeEach { Reset-Sim }

    It 'aborts when input arrives during the countdown' {
        Arm-PrimedProcess @('delta')
        $script:simIdle = 300.0             # user away five minutes
        $script:simProcs['delta'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        StepN 10 | Out-Null                  # idle keeps growing: no abort
        Get-TriggerState | Should -Be 'GRACE'

        $r = Step 1 -UserActive
        Get-TriggerState | Should -Be 'COOLDOWN'
        $r.Reason | Should -Be 'user activity'
    }

    <#
        The naive check - "is idle time low?" - would abort instantly here,
        because for a process trigger the user is usually sitting right there
        when the render finishes. What matters is input AFTER grace began.
    #>
    It 'does not abort merely because the user was active when it fired' {
        Arm-PrimedProcess @('eps')
        $script:simProcs['eps'] = 0
        $script:simIdle = 0.5
        $script:simNow += 1000
        Update-Trigger (Ctx) | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        for ($i = 1; $i -le 10; $i++) {
            $script:simNow += 1000; $script:simIdle = 0.5 + $i; $script:simGap = 1
            Update-Trigger (Ctx) | Out-Null
        }
        Get-TriggerState | Should -Be 'GRACE'
    }

    It 'aborts when the machine appears to have slept' {
        Arm-PrimedProcess @('zeta')
        $script:simIdle = 100.0
        $script:simProcs['zeta'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'

        $r = Step ([int]$script:SUSPEND_GAP_SEC + 15)
        Get-TriggerState | Should -Be 'COOLDOWN'
        $r.Reason | Should -Be 'apparent suspend/stall'
    }
}

Describe 'process evaluator' {

    It 'all-mode does not fire unless the targets were up simultaneously' {
        Reset-Sim
        $script:simProcs = @{ a = 1; b = 0 }
        Start-Trigger 'process' 'shutdown' @{ Names = @('a','b'); Mode = 'all' } (Ctx) | Out-Null
        StepN 20 | Out-Null
        $script:simProcs['b'] = 1; $script:simProcs['a'] = 0   # never up together
        StepN 3 | Out-Null
        Get-TriggerState | Should -Not -Be 'GRACE'
    }

    It 'all-mode fires once every target has been up and all have exited' {
        Reset-Sim
        Arm-PrimedProcess @('a','b') 'all'
        $script:simProcs['a'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Not -Be 'GRACE' -Because 'b is still running'
        $script:simProcs['b'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'
    }

    It 'treats multiple instances of one name collectively' {
        Reset-Sim
        $script:simProcs['chrome'] = 3
        Start-Trigger 'process' 'shutdown' @{ Names = @('chrome'); Mode = 'all' } (Ctx) | Out-Null
        StepN 20 | Out-Null
        $script:simProcs['chrome'] = 1
        StepN 1 | Out-Null
        Get-TriggerState | Should -Not -Be 'GRACE' -Because 'one instance is still running'
        $script:simProcs['chrome'] = 0
        StepN 1 | Out-Null
        Get-TriggerState | Should -Be 'GRACE'
    }

    It 'reports a configuration problem instead of firing' {
        $r = Test-TriggerProcess @{ Names = @() } @{} (Ctx)
        $r.Event  | Should -BeFalse
        $r.Status | Should -BeLike '*No process names*'
    }
}

Describe 'downloads evaluator' {

    BeforeEach {
        $script:dlDir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_dl_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:dlDir -Force | Out-Null
        $script:dlNow = 5000000L
        $script:dlEval = @{}
    }
    AfterEach { Remove-Item $script:dlDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'does not treat an already-quiet folder as a finished download' {
        Set-Content (Join-Path $script:dlDir 'old.mkv') 'x' -Encoding ascii
        $cfg = @{ Path = $script:dlDir; SettleSec = 5 }
        Test-TriggerDownloads $cfg $script:dlEval (DlCtx) | Out-Null   # baseline
        $script:dlNow += 120000
        $r = Test-TriggerDownloads $cfg $script:dlEval (DlCtx)
        $r.Primed | Should -BeFalse
        $r.Event  | Should -BeFalse
    }

    It 'primes on a partial file and fires once it is gone and the folder settles' {
        $cfg = @{ Path = $script:dlDir; SettleSec = 5 }
        Test-TriggerDownloads $cfg $script:dlEval (DlCtx) | Out-Null
        Set-Content (Join-Path $script:dlDir 'big.iso.crdownload') 'p' -Encoding ascii
        $script:dlNow += 1000
        (Test-TriggerDownloads $cfg $script:dlEval (DlCtx)).Primed | Should -BeTrue

        Remove-Item (Join-Path $script:dlDir 'big.iso.crdownload') -Force
        Set-Content (Join-Path $script:dlDir 'big.iso') 'done' -Encoding ascii
        $script:dlNow += 1000
        (Test-TriggerDownloads $cfg $script:dlEval (DlCtx)).Event | Should -BeFalse
        $script:dlNow += 6000
        (Test-TriggerDownloads $cfg $script:dlEval (DlCtx)).Event | Should -BeTrue
    }

    It 'does not count a pre-existing file that is only read' {
        Set-Content (Join-Path $script:dlDir 'notes.txt') 'hello' -Encoding ascii
        $cfg = @{ Path = $script:dlDir; SettleSec = 2 }
        Test-TriggerDownloads $cfg $script:dlEval (DlCtx) | Out-Null
        $script:dlNow += 10000
        Get-Content (Join-Path $script:dlDir 'notes.txt') | Out-Null
        (Test-TriggerDownloads $cfg $script:dlEval (DlCtx)).Primed | Should -BeFalse
    }

    It 'reports a missing folder rather than firing' {
        $r = Test-TriggerDownloads @{ Path = 'X:\nope' } @{} (DlCtx)
        $r.Event  | Should -BeFalse
        $r.Status | Should -BeLike '*not found*'
    }
}

Describe 'signal evaluator' {

    BeforeEach {
        $script:sigDir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_sig_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:sigDir -Force | Out-Null
        $script:sigPath = Join-Path $script:sigDir 'go.flag'
    }
    AfterEach { Remove-Item $script:sigDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'ignores a signal file that already existed when armed' {
        Set-Content $script:sigPath 'x' -Encoding ascii
        $ev = @{}
        $r = Test-TriggerSignal @{ Path = $script:sigPath } $ev (New-TriggerContext)
        $r.Primed | Should -BeFalse
        $r.Event  | Should -BeFalse
        Test-Path $script:sigPath | Should -BeTrue -Because 'it must not consume a file it did not arm against'
    }

    It 'fires on absent -> present and consumes the file' {
        $ev = @{}
        (Test-TriggerSignal @{ Path = $script:sigPath } $ev (New-TriggerContext)).Primed | Should -BeTrue
        Set-Content $script:sigPath 'x' -Encoding ascii
        (Test-TriggerSignal @{ Path = $script:sigPath } $ev (New-TriggerContext)).Event | Should -BeTrue
        Test-Path $script:sigPath | Should -BeFalse
        (Test-TriggerSignal @{ Path = $script:sigPath } $ev (New-TriggerContext)).Event | Should -BeFalse
    }

    It 'does not report an event when the file cannot be deleted' {
        Set-Content $script:sigPath 'x' -Encoding ascii
        $ev = @{ SeenAbsent = $true }
        $fs = [System.IO.File]::Open($script:sigPath, 'Open', 'Read', 'None')
        try {
            $r = Test-TriggerSignal @{ Path = $script:sigPath } $ev (New-TriggerContext)
            $r.Event | Should -BeFalse -Because 'pretending it was consumed would retrigger every tick'
            $ev['DeleteError'] | Should -Not -BeNullOrEmpty
        } finally { $fs.Close() }
    }
}

Describe 'resource evaluator' {

    It 'never treats a missing sample as zero' {
        $cfg = @{ NetEnabled = $true; NetKbps = 100; CpuEnabled = $true; CpuPercent = 10; Match = 'all'; SustainSec = 0 }
        $ev  = @{ SeenAbove = $true }
        $r = Test-TriggerResource $cfg $ev (New-TriggerContext -Kbps 5 -CpuPercent $null)
        $r.Event  | Should -BeFalse -Because 'an unavailable CPU reading must not look like an idle CPU'
        $r.Status | Should -BeLike '*valid*sample*'
    }

    It 'requires activity before it will consider the machine quiet' {
        $cfg = @{ NetEnabled = $true; NetKbps = 100; CpuEnabled = $false; SustainSec = 0 }
        $ev  = @{}
        $r = Test-TriggerResource $cfg $ev (New-TriggerContext -Kbps 5)
        $r.Primed | Should -BeFalse
        $r.Event  | Should -BeFalse
    }

    It 'restarts the sustain window when the condition breaks' {
        $cfg = @{ NetEnabled = $true; NetKbps = 100; CpuEnabled = $false; SustainSec = 5 }
        $ev  = @{}
        $now = 100000L
        Test-TriggerResource $cfg $ev (New-TriggerContext -NowTicks $now -Kbps 900) | Out-Null
        $now += 1000
        Test-TriggerResource $cfg $ev (New-TriggerContext -NowTicks $now -Kbps 5) | Out-Null
        $now += 3000
        Test-TriggerResource $cfg $ev (New-TriggerContext -NowTicks $now -Kbps 900) | Out-Null   # blip
        $now += 4000
        (Test-TriggerResource $cfg $ev (New-TriggerContext -NowTicks $now -Kbps 5)).Event |
            Should -BeFalse -Because 'the blip restarted the window'
        $now += 6000
        (Test-TriggerResource $cfg $ev (New-TriggerContext -NowTicks $now -Kbps 5)).Event | Should -BeTrue
    }

    It 'honours <Match> mode' -TestCases @(
        @{ Match = 'all'; Expected = $false }
        @{ Match = 'any'; Expected = $true  }
    ) {
        $cfg = @{ NetEnabled = $true; NetKbps = 100; CpuEnabled = $true; CpuPercent = 10; Match = $Match; SustainSec = 0 }
        $ev  = @{ SeenAbove = $true }
        # network quiet, CPU busy
        (Test-TriggerResource $cfg $ev (New-TriggerContext -Kbps 5 -CpuPercent 80)).Event | Should -Be $Expected
    }

    It 'rejects a configuration with no metric enabled' {
        (Test-TriggerResource @{ NetEnabled = $false; CpuEnabled = $false } @{} (New-TriggerContext)).Status |
            Should -Be 'No metric enabled'
    }

    <#
        Regression: `if ($Config.SustainSec) { ... } else { 120 }` treats a
        configured 0 as absent, silently turning "fire as soon as it is quiet"
        into a two-minute wait.
    #>
    It 'treats a configured zero as zero, not as absent' {
        Get-TriggerConfigValue @{ SustainSec = 0 }  'SustainSec' 120 | Should -Be 0
        Get-TriggerConfigValue @{}                  'SustainSec' 120 | Should -Be 120
        Get-TriggerConfigValue $null                'SustainSec' 120 | Should -Be 120
    }

    It 'reads config that has round-tripped through JSON as a PSCustomObject' {
        $obj = '{"SustainSec":0,"Match":"any"}' | ConvertFrom-Json
        Get-TriggerConfigValue $obj 'SustainSec' 120   | Should -Be 0
        Get-TriggerConfigValue $obj 'Match'      'all' | Should -Be 'any'
        Get-TriggerConfigValue $obj 'Missing'    'dflt' | Should -Be 'dflt'
    }
}

Describe 'idle evaluator' {
    It 'fires at the threshold and resets below it' {
        (Test-TriggerIdle @{ ThresholdSec = 60 } @{} (New-TriggerContext -IdleSec 30)).Event | Should -BeFalse
        (Test-TriggerIdle @{ ThresholdSec = 60 } @{} (New-TriggerContext -IdleSec 30)).Reset | Should -BeTrue
        (Test-TriggerIdle @{ ThresholdSec = 60 } @{} (New-TriggerContext -IdleSec 61)).Event | Should -BeTrue
    }

    It 'is primed immediately so the engine has no special case' {
        (Test-TriggerIdle @{ ThresholdSec = 60 } @{} (New-TriggerContext -IdleSec 0)).Primed | Should -BeTrue
    }
}

Describe 'Monotonic clock' {

    <#
        Regression, and a nasty one: this module originally used
        [Environment]::TickCount64, which is .NET Core 3.0+ only. Windows
        PowerShell 5.1 runs on .NET Framework 4.x, where it does not exist and
        evaluates to nothing - so every elapsed-time calculation was zero and a
        trigger sat in ARMING forever.

        The rest of the suite injects NowTicks, so it could not have caught this.
        These tests deliberately exercise the DEFAULT path.
    #>
    It 'returns a real, advancing value on this runtime' {
        $a = Get-MonotonicMs
        $a | Should -BeGreaterThan 0 -Because 'a missing API would yield $null, which compares as 0'
        Start-Sleep -Milliseconds 1100
        (Get-MonotonicMs) | Should -BeGreaterThan $a
    }

    It 'builds a default context with a working clock' {
        (New-TriggerContext).NowTicks | Should -BeGreaterThan 0
    }

    It 'advances a real trigger out of ARMING' {
        Stop-Trigger 'test'
        # MIN_ARM_SEC is 15s of real time, so shorten it just for this check.
        $saved = $script:MIN_ARM_SEC
        try {
            $script:MIN_ARM_SEC = 1
            Start-Trigger 'idle' 'shutdown' @{ ThresholdSec = 99999 } | Out-Null
            Get-TriggerState | Should -Be 'ARMING'
            Start-Sleep -Milliseconds 1200
            Update-Trigger (New-TriggerContext -IdleSec 0) | Out-Null
            Get-TriggerState | Should -Be 'PRIMED' -Because 'the arm window must actually elapse'
        } finally { $script:MIN_ARM_SEC = $saved; Stop-Trigger 'test' }
    }
}

Describe 'Passive evaluation while arming' {

    <#
        Regression: the ARMING state evaluates so baselines get established, but
        the signal evaluator DELETES the file it sees. A flag arriving during the
        15-second arm window was therefore consumed and the event lost - the
        trigger then waited forever for a signal that had already been thrown away.
    #>
    It 'does not consume a signal file that arrives while still arming' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_pass_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $sig = Join-Path $dir 'go.flag'
            $ev  = @{ SeenAbsent = $true }
            Set-Content $sig 'x' -Encoding ascii

            $r = Test-TriggerSignal @{ Path = $sig } $ev (New-TriggerContext -Passive)
            $r.Event | Should -BeFalse
            Test-Path $sig | Should -BeTrue -Because 'the flag must survive until the trigger is watching'

            # Once watching, the same flag fires and is consumed.
            $r = Test-TriggerSignal @{ Path = $sig } $ev (New-TriggerContext)
            $r.Event | Should -BeTrue
            Test-Path $sig | Should -BeFalse
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
