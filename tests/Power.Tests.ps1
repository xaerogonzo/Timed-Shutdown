#Requires -Version 5.1
<#
    Tests for Core/Power.ps1.

    Nothing here runs shutdown.exe, powercfg, or touches Task Scheduler. Those go
    through Set-PowerCommandSeam, whose fakes record what they were asked to do
    and answer with a chosen exit code -- so the failure paths, which are the
    whole point of these tests, can actually be reached. You cannot make a real
    shutdown.exe fail on demand.

    The seams return @{ ExitCode; Output } rather than setting $LASTEXITCODE. A
    fake cannot set $LASTEXITCODE, so tests written against the ambient form
    would be reading whatever the last real command left behind.

    What is asserted is the TRANSACTION, not the symptom. Both defects covered
    here are partial-failure bugs: the interesting question is never "did it
    return false", it is "what is the state of the world afterwards".

    NB: BeforeEach must live inside a Describe. Pester 6 rejects test setup
    declared directly in the file's root block.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Interop.ps1"
    . "$PSScriptRoot\..\src\Core\Log.ps1"
    . "$PSScriptRoot\..\src\Core\State.ps1"
    . "$PSScriptRoot\..\src\Core\Scheduler.ps1"
    . "$PSScriptRoot\..\src\Core\Power.ps1"

    function New-Sandbox {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_powertests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    # ---- recording fakes -------------------------------------------------
    # Exit codes are looked up per flag, so a test can make exactly one of the
    # two shutdown.exe calls fail -- which is the situation the snooze defect
    # lives in, and is unreachable with a real shutdown.exe.
    $script:shutdownCalls = New-Object System.Collections.ArrayList
    $script:shutdownExit  = @{}
    $script:removedTasks  = New-Object System.Collections.ArrayList
    $script:removeThrows  = @{}
    $script:presentTasks  = New-Object System.Collections.ArrayList

    $script:FakeShutdown = {
        param([string[]]$Arguments)
        [void]$script:shutdownCalls.Add(($Arguments -join ' '))
        $flag = "$($Arguments[0])"
        $code = if ($script:shutdownExit.ContainsKey($flag)) { $script:shutdownExit[$flag] } else { 0 }
        return @{ ExitCode = $code; Output = "fake shutdown $flag -> $code" }
    }

    $script:FakeRemoveTask = {
        param([string]$Name, [string]$TaskPath)
        [void]$script:removedTasks.Add($Name)
        if ($script:removeThrows.ContainsKey($Name)) { throw $script:removeThrows[$Name] }
        return $script:presentTasks.Contains($Name)
    }

    function Reset-Fakes {
        $script:shutdownCalls.Clear()
        $script:removedTasks.Clear()
        $script:presentTasks.Clear()
        $script:shutdownExit = @{}
        $script:removeThrows = @{}
        Set-PowerCommandSeam -ShutdownExe $script:FakeShutdown -RemovePendingTask $script:FakeRemoveTask
    }

    function Get-LogText {
        $p = Get-LogFilePath
        if (Test-Path $p) { return (Get-Content $p -Raw) }
        return ''
    }
}

Describe 'Get-TrackedAction' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns $null when nothing is pending' {
        Get-TrackedAction | Should -BeNullOrEmpty
    }

    It 'returns the action while its target is still ahead' {
        Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
        $a = Get-TrackedAction

        $a          | Should -Not -BeNullOrEmpty
        $a.type     | Should -Be 'shutdown'
        $a.method   | Should -Be 'os-timer'
    }

    <#
        pendingAction mirrors a timer held OUTSIDE the app. Once its moment has
        passed the mirror is stale -- either the action happened, or it did not
        and never will -- so it is cleared rather than shown as a live countdown.
    #>
    It 'clears the state once the target has passed' {
        Write-PendingAction 'shutdown' 5 'os-timer' (Get-Date).AddSeconds(-5)

        Get-TrackedAction | Should -BeNullOrEmpty
        (Read-State).pendingAction.type | Should -Be 'null'
    }

    It 'clears the state rather than throwing on an unparseable target' {
        Write-State @{ pendingAction = @{ type = 'shutdown'; targetAt = 'not a date' } }

        { Get-TrackedAction } | Should -Not -Throw
        Get-TrackedAction     | Should -BeNullOrEmpty
    }

    It 'treats the sentinel type as nothing pending' {
        Clear-State
        Get-TrackedAction | Should -BeNullOrEmpty
    }
}

Describe 'Write-PendingAction' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'round-trips every field' {
        $at = (Get-Date).AddMinutes(45)
        Write-PendingAction 'hibernate' 2700 'scheduled-task' $at
        $a = (Read-State).pendingAction

        $a.type    | Should -Be 'hibernate'
        $a.seconds | Should -Be 2700
        $a.method  | Should -Be 'scheduled-task'
        ([datetime]::Parse($a.targetAt).ToLocalTime() - $at).TotalSeconds |
            Should -BeLessThan 1
    }

    <#
        Stored as UTC round-trip format so a timezone change between write and
        read cannot move the target.

        Asserted against the RAW FILE, deliberately. Read-State goes through
        ConvertFrom-Json, and Windows PowerShell 5.1 silently coerces an
        ISO-8601 string into a [datetime] -- so the value handed back
        stringifies through the CURRENT CULTURE ("9/8/2026 9:19:46 AM") and
        has no trailing Z to find, whatever is genuinely on disk.

        Matching against that failed on an en-US machine while the data it
        was checking was perfectly correct, and under a culture that happens
        to round-trip it would have PASSED for the wrong reason -- the worse
        half, since a format regression would then ship unnoticed. PS7's
        ConvertFrom-Json coerces differently again, so the parsed value is
        the wrong thing to assert on in any edition.

        What this test MEANS is "the bytes we persisted are UTC round-trip
        format", so it reads the bytes.
    #>
    It 'stores the target in UTC round-trip format' {
        Write-PendingAction 'shutdown' 60 'os-timer' (Get-Date).AddMinutes(1)

        $raw = Get-Content (Join-Path $sandbox 'state.json') -Raw -Encoding UTF8
        $raw | Should -Match '"targetAt"\s*:\s*"[^"]+Z"'
        # Same function writes both, and both have to survive a timezone change.
        $raw | Should -Match '"startedAt"\s*:\s*"[^"]+Z"'
    }
}

Describe 'Stop-TimedAction' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Set-LogFilePath   (Join-Path $sandbox 'log.txt')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'the target exists and the cancel succeeds' {

        It 'aborts the OS timer and clears the state' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)

            { Stop-TimedAction } | Should -Not -Throw

            $script:shutdownCalls | Should -Contain '/a'
            Get-TrackedAction     | Should -BeNullOrEmpty
        }

        It 'removes both one-shot backing tasks' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            Stop-TimedAction

            $script:removedTasks | Should -Contain 'TS_pending_sleep'
            $script:removedTasks | Should -Contain 'TS_pending_hibernate'
        }

        # shutdown.exe is only involved for the OS-timer methods; a sleep timer
        # is a scheduled task, and calling /a for it would be noise.
        It 'does not call shutdown /a for a sleep timer' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            Stop-TimedAction

            $script:shutdownCalls | Should -Not -Contain '/a'
        }
    }

    Context 'there was nothing to cancel' {

        <#
            1116 is ERROR_NO_SHUTDOWN_IN_PROGRESS. For a CANCEL that is success:
            the caller wants no pending shutdown and there is none. Treating it
            as failure would make cancelling a timer that had just expired look
            broken, which is precisely when a user is most likely to press it.
        #>
        It 'treats "nothing to abort" as success, not failure' {
            Write-PendingAction 'shutdown' 5 'os-timer' (Get-Date).AddMinutes(1)
            $script:shutdownExit['/a'] = 1116

            { Stop-TimedAction } | Should -Not -Throw
            Get-TrackedAction    | Should -BeNullOrEmpty
        }

        It 'treats an absent backing task as success' {
            Write-PendingAction 'sleep' 5 'scheduled-task' (Get-Date).AddMinutes(1)
            # presentTasks is empty, so the fake reports nothing was there.

            { Stop-TimedAction } | Should -Not -Throw
            Get-TrackedAction    | Should -BeNullOrEmpty
        }
    }

    Context 'the cancel genuinely failed' {

        <#
            Regression, shipped through v2.2.

            The unregister ran with -ErrorAction SilentlyContinue, which made a
            real failure indistinguishable from a task that had already gone. The
            app cleared its state and the UI reported the timer cancelled -- and
            the scheduled sleep fired anyway. "Cancelled" is a claim the user acts
            on by walking away from the machine.
        #>
        It 'throws rather than reporting a cancel it did not perform' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            $script:removeThrows['TS_pending_sleep'] = 'access denied'

            { Stop-TimedAction } | Should -Throw
        }

        <#
            State is deliberately left intact. pendingAction mirrors something
            that still exists outside this process, so dropping the mirror would
            leave the user unable to see -- or retry -- the thing still counting
            down toward powering the machine off.
        #>
        It 'leaves the pending state intact so the action can still be seen and retried' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            $script:removeThrows['TS_pending_sleep'] = 'access denied'

            try { Stop-TimedAction } catch { }

            Get-TrackedAction        | Should -Not -BeNullOrEmpty
            (Get-TrackedAction).type | Should -Be 'sleep'
        }

        It 'throws when shutdown /a fails for a real reason' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            $script:shutdownExit['/a'] = 5   # anything but 0 or 1116

            { Stop-TimedAction }     | Should -Throw
            Get-TrackedAction        | Should -Not -BeNullOrEmpty
        }

        It 'records the reason in the log' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            $script:removeThrows['TS_pending_sleep'] = 'access denied'

            try { Stop-TimedAction } catch { }

            Get-LogText | Should -Match 'cancel-failed'
        }

        # One failure must not stop the other target being attempted, or a broken
        # sleep task would leave a hibernate task registered behind it.
        It 'still attempts the second task after the first fails' {
            Write-PendingAction 'sleep' 1800 'scheduled-task' (Get-Date).AddMinutes(30)
            $script:removeThrows['TS_pending_sleep'] = 'access denied'

            try { Stop-TimedAction } catch { }

            $script:removedTasks | Should -Contain 'TS_pending_hibernate'
        }
    }
}

Describe 'Add-SnoozeTime' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Set-LogFilePath   (Join-Path $sandbox 'log.txt')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'nothing pending' {
        It 'reports failure without calling shutdown.exe' {
            Add-SnoozeTime 900 | Should -BeFalse
            $script:shutdownCalls.Count | Should -Be 0
        }
    }

    Context 'the re-arm succeeds' {

        It 'reports success' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            Add-SnoozeTime 900 | Should -BeTrue
        }

        # Abort first, then set: leaving the old timer armed would give two.
        It 'aborts before re-arming' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            Add-SnoozeTime 900 | Out-Null

            $script:shutdownCalls[0] | Should -Be '/a'
            $script:shutdownCalls[1] | Should -BeLike '/s /t *'
        }

        It 'moves the target out by the requested amount' {
            $before = (Get-Date).AddMinutes(30)
            Write-PendingAction 'shutdown' 1800 'os-timer' $before
            Add-SnoozeTime 900 | Out-Null

            $after = [datetime]::Parse((Read-State).pendingAction.targetAt).ToLocalTime()
            ($after - $before).TotalSeconds | Should -BeGreaterThan 890
            ($after - $before).TotalSeconds | Should -BeLessThan 910
        }

        It 'uses /r for a restart, not /s' {
            Write-PendingAction 'restart' 1800 'os-timer' (Get-Date).AddMinutes(30)
            Add-SnoozeTime 900 | Out-Null

            ($script:shutdownCalls -join ' | ') | Should -Match '/r /t'
        }

        It 'preserves the original method and start time' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            $startedAt = (Read-State).pendingAction.startedAt
            Add-SnoozeTime 900 | Out-Null

            (Read-State).pendingAction.method    | Should -Be 'os-timer'
            (Read-State).pendingAction.startedAt | Should -Be $startedAt
        }

        # The timer may expire in the gap between reading state and re-arming.
        # That abort finding nothing is not a reason to refuse the extension.
        It 'tolerates 1116 from the abort and still re-arms' {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            $script:shutdownExit['/a'] = 1116

            Add-SnoozeTime 900 | Should -BeTrue
        }
    }

    <#
        The defect this whole file exists for.

        Add-SnoozeTime cancels the OS timer and then arms a new one, so between
        those two calls there is no timer at all. The old code ignored both exit
        codes inside a catch that swallowed everything, then wrote pendingAction
        regardless -- so a failed re-arm left state claiming a countdown that
        nothing was driving. The window ticked to zero and the machine stayed on.

        That is the v2.1 scheduled-task defect exactly: a timer with nothing
        behind it. And the guard extension on the dispatcher tick calls straight
        into here, so it could happen without anyone pressing a thing.
    #>
    Context 'the re-arm fails after the abort already succeeded' {

        BeforeEach {
            Write-PendingAction 'shutdown' 1800 'os-timer' (Get-Date).AddMinutes(30)
            $script:shutdownExit['/s'] = 1   # the abort succeeds; the set does not
        }

        It 'reports failure' {
            Add-SnoozeTime 900 | Should -BeFalse
        }

        It 'really did abort the old timer' {
            Add-SnoozeTime 900 | Out-Null
            $script:shutdownCalls[0] | Should -Be '/a'
        }

        It 'leaves no pending action recorded' {
            Add-SnoozeTime 900 | Out-Null
            (Read-State).pendingAction.type | Should -Be 'null'
        }

        # Get-TrackedAction is what drives the countdown panel, so this IS the
        # assertion that the UI shows no timer.
        It 'shows no countdown, because there is genuinely nothing pending' {
            Add-SnoozeTime 900 | Out-Null
            Get-TrackedAction | Should -BeNullOrEmpty
        }

        It 'records the failure and its reason in the log' {
            Add-SnoozeTime 900 | Out-Null
            Get-LogText | Should -Match 'snooze-failed'
        }

        It 'releases the keep-awake request, since nothing is pending now' {
            Add-SnoozeTime 900 | Out-Null
            Test-KeepAwakeHeld | Should -BeFalse
        }
    }
}

<#
    Only still used to interpret state written by the pre-v2.0 build, which set
    the global power plan's timeouts to "never" and restored them solely from
    Cancel -- so a timer that actually fired left sleep permanently disabled.
#>
Describe 'Get-PowerTimeoutSecs' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the AC and DC indices out of powercfg output' {
        $standby = @"
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
  Subgroup GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Sleep)
    Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)
      Current AC Power Setting Index: 0x00000708
      Current DC Power Setting Index: 0x00000384
"@
        $hib = @"
      Current AC Power Setting Index: 0x00000e10
      Current DC Power Setting Index: 0x00000000
"@
        Set-PowerCommandSeam -Powercfg ([scriptblock]::Create(@"
param([string[]]`$Arguments)
if (`$Arguments -contains 'STANDBYIDLE') { return @{ ExitCode = 0; Output = @'
$standby
'@ } }
return @{ ExitCode = 0; Output = @'
$hib
'@ }
"@))

        $r = Get-PowerTimeoutSecs
        $r.SleepAC | Should -Be 1800     # 0x708
        $r.SleepDC | Should -Be 900      # 0x384
        $r.HibAC   | Should -Be 3600     # 0xe10
        $r.HibDC   | Should -Be 0
    }

    <#
        The old build parsed English-only powercfg output. On a localized Windows
        the regex matched nothing and every value was recorded as zero -- the same
        failure class as the localized counter names avoided in v2.2. Returning
        zeros rather than throwing is what lets Repair-LegacyPowerSuppression
        recognise the situation and decline to "restore" anything.
    #>
    It 'returns zeros rather than throwing when nothing matches' {
        Set-PowerCommandSeam -Powercfg { param([string[]]$Arguments) @{ ExitCode = 0; Output = 'Energieschema-GUID: ...' } }

        $r = Get-PowerTimeoutSecs
        $r.SleepAC | Should -Be 0
        $r.HibDC   | Should -Be 0
    }

    It 'returns zeros rather than throwing when powercfg blows up' {
        Set-PowerCommandSeam -Powercfg { param([string[]]$Arguments) throw 'powercfg exploded' }

        { Get-PowerTimeoutSecs } | Should -Not -Throw
        (Get-PowerTimeoutSecs).SleepAC | Should -Be 0
    }
}

Describe 'Repair-LegacyPowerSuppression' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Set-LogFilePath   (Join-Path $sandbox 'log.txt')
        Reset-Fakes

        $script:powercfgCalls = New-Object System.Collections.ArrayList
        Set-PowerCommandSeam -Powercfg {
            param([string[]]$Arguments)
            [void]$script:powercfgCalls.Add(($Arguments -join ' '))
            return @{ ExitCode = 0; Output = '' }
        }
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'does nothing when there is no legacy suppression recorded' {
        Repair-LegacyPowerSuppression | Should -BeFalse
        $script:powercfgCalls.Count   | Should -Be 0
    }

    It 'restores the recorded values and clears the flag' {
        Write-State @{ sleepSuppression = @{
            active = $true
            originalSleepAC = 1800; originalSleepDC = 900
            originalHibAC   = 3600; originalHibDC   = 0
        }}

        Repair-LegacyPowerSuppression | Should -BeTrue

        ($script:powercfgCalls -join ' | ') | Should -Match 'standby-timeout-ac 30'
        ($script:powercfgCalls -join ' | ') | Should -Match 'standby-timeout-dc 15'
        ($script:powercfgCalls -join ' | ') | Should -Match 'hibernate-timeout-ac 60'
        (Read-State).sleepSuppression.active | Should -BeFalse
    }

    <#
        All four recorded as zero is ambiguous: either sleep genuinely was
        disabled, or the old build's English-only powercfg parse failed on a
        localized Windows and recorded nothing at all. Writing "never" back could
        BE the damage rather than the repair, so the plan is left alone and only
        the flag is dropped.
    #>
    It 'leaves the plan alone when all four recorded values are zero' {
        Write-State @{ sleepSuppression = @{
            active = $true
            originalSleepAC = 0; originalSleepDC = 0
            originalHibAC   = 0; originalHibDC   = 0
        }}

        Repair-LegacyPowerSuppression | Should -BeFalse
        $script:powercfgCalls.Count   | Should -Be 0
        (Read-State).sleepSuppression.active | Should -BeFalse
    }

    # Runs at most once: the flag is cleared either way, so a second launch is a
    # no-op even if the first declined to write anything.
    It 'is a no-op on the second run' {
        Write-State @{ sleepSuppression = @{
            active = $true
            originalSleepAC = 1800; originalSleepDC = 900
            originalHibAC   = 3600; originalHibDC   = 0
        }}

        Repair-LegacyPowerSuppression | Should -BeTrue
        $script:powercfgCalls.Clear()
        Repair-LegacyPowerSuppression | Should -BeFalse
        $script:powercfgCalls.Count   | Should -Be 0
    }

    # Seconds to whole minutes, floored, but never rounding a non-zero timeout
    # down to "never" -- 30 seconds must not become 0.
    It 'never floors a non-zero timeout to never' {
        Write-State @{ sleepSuppression = @{
            active = $true
            originalSleepAC = 30; originalSleepDC = 0
            originalHibAC   = 0;  originalHibDC   = 0
        }}

        Repair-LegacyPowerSuppression | Out-Null
        ($script:powercfgCalls -join ' | ') | Should -Match 'standby-timeout-ac 1'
    }
}

<#
    A failed cancel is the one message in this app the user acts on by walking
    away from the machine, so it has to say something they can act on.

    After 2.4 the likeliest cause is an upgrade: tasks registered by an older,
    elevated build cannot be removed by this unelevated one, and the raw CIM
    text ("Access is denied") gives no clue what to do.
#>
Describe 'Format-TaskRemovalFailure' {

    It 'explains the pre-2.4 upgrade case for <_>' -ForEach @(
        'Access is denied.',
        'Exception calling method: 0x80070005',
        'UnauthorizedAccessException'
    ) {
        $msg = Format-TaskRemovalFailure 'TS_pending_sleep' $_
        $msg | Should -Match 'older version'
        $msg | Should -Match 'Remove leftover tasks'
        $msg | Should -Match 'TS_pending_sleep'
    }

    It 'passes an unrelated failure through unchanged' {
        $msg = Format-TaskRemovalFailure 'TS_pending_sleep' 'The RPC server is unavailable.'
        $msg | Should -Match 'RPC server is unavailable'
        $msg | Should -Not -Match 'older version'
    }

    <#
        Stop-TimedAction must keep NOT clearing state when a removal failed.
        pendingAction mirrors something still running outside this process;
        dropping the mirror would leave the user unable to see or retry it.
    #>
    It 'leaves the pending action intact when removal is denied' {
        Write-PendingAction 'sleep' 600 'scheduled-task' (Get-Date).AddMinutes(10)
        Set-PowerCommandSeam -RemovePendingTask { param($Name, $TaskPath) throw 'Access is denied.' }

        { Stop-TimedAction } | Should -Throw
        (Read-State).pendingAction.type | Should -Be 'sleep'

        Reset-PowerCommandSeam
    }
}

<#
    The README states that "every arm, fire, cancel, and abort is recorded with a
    reason". Only the FAILURE path used to write a line, so the one question you
    actually ask the log - "was my timer really called off?" - had no answer in
    it. A promise in the docs that the code does not keep is a defect.
#>
Describe 'Stop-TimedAction logging' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
        Set-LogFilePath   (Join-Path $sandbox 'log.txt')
        Reset-Fakes
    }
    AfterEach {
        Reset-PowerCommandSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'records a successful cancel, naming what was pending' {
        Write-PendingAction 'shutdown' 600 'os-timer' (Get-Date).AddMinutes(10)
        Set-PowerCommandSeam -ShutdownExe { param($Arguments) @{ ExitCode = 0; Output = '' } } `
                             -RemovePendingTask { param($Name, $TaskPath) $false }

        Stop-TimedAction

        $log = Get-Content (Join-Path $sandbox 'log.txt') -Raw
        $log | Should -Match 'cancelled'
        $log | Should -Match 'was=shutdown'
    }

    It 'still records the failure path distinctly' {
        Write-PendingAction 'sleep' 600 'scheduled-task' (Get-Date).AddMinutes(10)
        Set-PowerCommandSeam -RemovePendingTask { param($Name, $TaskPath) throw 'Access is denied.' }

        { Stop-TimedAction } | Should -Throw

        $log = Get-Content (Join-Path $sandbox 'log.txt') -Raw
        $log | Should -Match 'cancel-failed'
        # A failed cancel must never also claim to have succeeded.
        $log | Should -Not -Match 'cancelled'
    }
}

<#
    The v2.4 "Turn Off Monitor" freeze.

    Invoke-MonitorOff blocked the WPF dispatcher twice over -- Start-Sleep, then
    an unbounded SendMessage to HWND_BROADCAST that waits on every top-level
    window in the session forever. One app not pumping its queue left the app
    permanently at "(Not Responding)".

    The rewrite is a state machine, and what is asserted here is the STATE, not
    that a monitor happened to switch off. The three failures worth catching are
    all invisible from the outside:

      * a second click stacking a second poll on top of the first,
      * an exception in the async plumbing leaving monitorOffPending stuck true,
        which disables the button for the life of the process,
      * a hung recipient -- the tolerated outcome SMTO_ABORTIFHUNG exists to
        produce -- being reported as a failure.

    The DispatcherTimer never ticks here (Pester runs no message pump), which is
    exactly why Step-MonitorOff is a function: the poll is driven by hand.
#>
Describe 'Monitor off' {

    BeforeAll {
        # The clock and the idle reading are seams, so a test can place input
        # activity and elapsed time wherever the case needs them. Nothing here
        # touches a real display.
        function Set-MonitorFakes {
            $script:monSends      = New-Object System.Collections.ArrayList
            $script:monIdle       = 0
            $script:monNow        = 0
            $script:monSendThrows = $false
            $script:monSendResult = @{ Result = [IntPtr]1; LastError = 0 }

            Set-MonitorSeam -GetIdleMs      { [int]$script:monIdle } `
                            -GetMonotonicMs { [long]$script:monNow } `
                            -SendMonitorOff {
                                [void]$script:monSends.Add('send')
                                if ($script:monSendThrows) { throw 'fake send blew up' }
                                return $script:monSendResult
                            }
        }
    }

    BeforeEach {
        $sandbox = New-Sandbox
        Set-LogFilePath (Join-Path $sandbox 'log.txt')
        Reset-MonitorOffState
        Set-MonitorFakes
    }
    AfterEach {
        Reset-MonitorOffState
        Reset-MonitorSeam
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'the decision' {

        It 'waits while the input that asked for it is still settling' {
            Get-MonitorOffDecision 100 200 | Should -Be 'wait'
        }

        It 'sends once input has been quiet for the settle window' {
            # Exactly at the boundary, not past it.
            Get-MonitorOffDecision 700 100 | Should -Be 'send'
        }

        <#
            The cap is the load-bearing half. Without it a hand resting on the
            mouse holds IdleMs below the settle window indefinitely and the
            display never turns off AT ALL -- a worse bug than the wake-back-on
            the settle window exists to fix.
        #>
        It 'sends at the cap however busy the input is' {
            Get-MonitorOffDecision 0   3000 | Should -Be 'send'
            Get-MonitorOffDecision 699 3000 | Should -Be 'send'
        }
    }

    Context 'the native outcome' {

        # SendMessageTimeout returns non-zero on success.
        It 'reports a normal send' {
            Get-MonitorOffOutcome @{ Result = [IntPtr]1; LastError = 0 } | Should -Be 'sent'
        }

        <#
            Zero with ERROR_TIMEOUT (1460), or with no error set at all, is
            SMTO_ABORTIFHUNG doing its job: a window that was not pumping got
            skipped. Other windows may well have handled the command and the
            display very likely did go off. Calling that a failure would put an
            alarming line in the log for an ordinary broadcast.
        #>
        It 'treats a hung recipient as tolerated, not a failure' {
            Get-MonitorOffOutcome @{ Result = [IntPtr]::Zero; LastError = [WinApi]::ERROR_TIMEOUT } |
                Should -Be 'hung'
            Get-MonitorOffOutcome @{ Result = [IntPtr]::Zero; LastError = 0 } | Should -Be 'hung'
        }

        # ERROR_ACCESS_DENIED. Swallowing this is the silence that hid the
        # original freeze for a whole release.
        It 'reports a genuine failure' {
            Get-MonitorOffOutcome @{ Result = [IntPtr]::Zero; LastError = 5 } | Should -Be 'failed'
        }
    }

    Context 'the pending operation' {

        <#
            The direct regression for the deleted Start-Sleep -Milliseconds 300.
            Anything that blocks here blocks the dispatcher, and on the Win+Alt+M
            path it blocks inside a WndProc.
        #>
        It 'returns immediately rather than blocking the dispatcher' {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-MonitorOff
            $sw.Stop()
            $sw.ElapsedMilliseconds | Should -BeLessThan 200
        }

        It 'stays pending across a wait step' {
            $script:monNow  = 1000
            Invoke-MonitorOff
            $script:monNow  = 1100
            $script:monIdle = 50          # input still busy
            Step-MonitorOff
            $script:monSends.Count      | Should -Be 0
            Test-MonitorOffPending      | Should -BeTrue
        }

        <#
            The reentrancy guard, asserted through behaviour rather than through
            the flag itself.

            Invoke-MonitorOff sets monitorOffStarted. If the second click were
            let through it would reset that to 3500, leaving the step below only
            500 ms into a fresh settle window -- and it would wait. It sends
            instead, which is only possible if the second click was ignored and
            the ORIGINAL 1000 start is still in force.

            This is what a pending flag cleared in Invoke-MonitorOff's own
            finally would fail: by the time the second click arrived the flag
            would already be false, and a second poll would be armed alongside
            the first.
        #>
        It 'a second click does not restart the settle window' {
            $script:monNow = 1000
            Invoke-MonitorOff
            Test-MonitorOffPending | Should -BeTrue

            $script:monNow = 3500
            Invoke-MonitorOff                 # the double-click

            $script:monNow  = 4000            # 3000 ms past the original start
            $script:monIdle = 0               # still busy, so only the cap can fire
            Step-MonitorOff

            $script:monSends.Count | Should -Be 1
            Test-MonitorOffPending | Should -BeFalse
        }

        It 'allows a fresh operation once the first has completed' {
            $script:monNow = 0
            Invoke-MonitorOff
            $script:monNow = 5000
            Step-MonitorOff
            Test-MonitorOffPending | Should -BeFalse

            Invoke-MonitorOff
            Test-MonitorOffPending | Should -BeTrue
        }
    }

    Context 'failure paths' {

        <#
            An exception inside the new async plumbing must not strand the flag.
            If it did, Turn Off Monitor would be dead for the rest of the
            session with nothing on screen to say why -- the button would simply
            stop doing anything.
        #>
        It 'clears the flag when the send throws, and logs it' {
            $script:monSendThrows = $true
            Invoke-MonitorOff
            $script:monNow = 5000

            { Step-MonitorOff } | Should -Not -Throw

            Test-MonitorOffPending | Should -BeFalse
            (Get-Content (Join-Path $sandbox 'log.txt') -Raw) | Should -Match 'off-failed'

            # ...and the feature still works afterwards.
            Invoke-MonitorOff
            Test-MonitorOffPending | Should -BeTrue
        }

        <#
            A native BOOL-style failure returns a value; it does not throw. That
            is why the seam hands back @{ Result; LastError } instead of a raw
            IntPtr -- a try/catch around the P/Invoke would catch nothing.
        #>
        It 'logs a failing native result, which never throws on its own' {
            $script:monSendResult = @{ Result = [IntPtr]::Zero; LastError = 5 }
            Invoke-MonitorOff
            $script:monNow = 5000

            Step-MonitorOff

            Test-MonitorOffPending | Should -BeFalse
            (Get-Content (Join-Path $sandbox 'log.txt') -Raw) | Should -Match 'off-failed'
        }

        # A skipped hung window is not worth alarming the user about.
        It 'does not log a failure when a recipient was merely hung' {
            $script:monSendResult = @{ Result = [IntPtr]::Zero; LastError = [WinApi]::ERROR_TIMEOUT }
            Invoke-MonitorOff
            $script:monNow = 5000

            Step-MonitorOff

            $log = Get-Content (Join-Path $sandbox 'log.txt') -Raw
            $log | Should -Match 'outcome=hung'
            $log | Should -Not -Match 'off-failed'
        }

        <#
            One attempt, then stop. Re-arming the poll after a failure would turn
            a transient fault into a 10 Hz message storm.
        #>
        It 'does not retry after a failure' {
            $script:monSendResult = @{ Result = [IntPtr]::Zero; LastError = 5 }
            Invoke-MonitorOff
            $script:monNow = 5000
            Step-MonitorOff

            # A stray tick arriving after completion must do nothing at all.
            Step-MonitorOff
            $script:monSends.Count | Should -Be 1
        }
    }
}
