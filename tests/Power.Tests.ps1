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

    # Stored as UTC round-trip format so a timezone change between write and read
    # cannot move the target.
    It 'stores the target in UTC round-trip format' {
        Write-PendingAction 'shutdown' 60 'os-timer' (Get-Date).AddMinutes(1)
        (Read-State).pendingAction.targetAt | Should -Match 'Z$'
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
