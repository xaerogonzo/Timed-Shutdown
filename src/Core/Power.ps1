#Requires -Version 5.1
<#
    Core/Power.ps1 - keep-awake, the four timed actions, snooze, quick actions.

    Keeping the machine awake used to mean rewriting the *global* power plan
    (standby/hibernate timeouts -> 0). That restore only ran on Cancel, so a timer
    that actually fired left the plan permanently set to "never sleep" -- and the
    state file recording the original values sat in %TEMP%.

    It now uses SetThreadExecutionState, which holds the request against this
    thread and is released by Windows when the process exits. Nothing global is
    written, so the settings cannot be stranded. Repair-LegacyPowerSuppression
    below undoes damage from the old behaviour, once.
#>

$script:keepAwakeHeld = $false

# ── Test seams ────────────────────────────────────────────────────────────────
<#
    The external commands this module drives, behind swappable scriptblocks.

    Core/Triggers.ps1 injects its seam through the per-tick $Context; the
    functions here are called directly, so the seam is script-scope instead --
    the same shape as Set-StateFilePath and Set-LogFilePath.

    Each returns @{ ExitCode; Output } rather than leaving the caller to read the
    ambient $LASTEXITCODE. That is not tidiness: a fake cannot set $LASTEXITCODE,
    so a test written against the ambient form would quietly be reading whatever
    the last REAL command in the session happened to leave behind, and would pass
    or fail for reasons unrelated to the code under test.
#>
$script:DefaultInvokeShutdownExe = {
    param([string[]]$Arguments)
    $out = & shutdown.exe @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String).Trim() }
}

$script:DefaultInvokePowercfg = {
    param([string[]]$Arguments)
    $out = & powercfg @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

<#
    Removes a one-shot backing task, returning $true if one was actually there.

    Absent is SUCCESS -- the caller wants it gone and it is gone. Anything else
    throws, so a genuine failure can never be mistaken for a completed cancel.
    The old code used -ErrorAction SilentlyContinue, which made those two
    outcomes indistinguishable.
#>
$script:DefaultRemovePendingTask = {
    param([string]$Name, [string]$TaskPath)
    $existing = Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $existing) { return $false }
    Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
    return $true
}

$script:InvokeShutdownExe = $script:DefaultInvokeShutdownExe
$script:InvokePowercfg    = $script:DefaultInvokePowercfg
$script:RemovePendingTask = $script:DefaultRemovePendingTask

function Set-PowerCommandSeam {
    param(
        [scriptblock] $ShutdownExe       = $null,
        [scriptblock] $Powercfg          = $null,
        [scriptblock] $RemovePendingTask = $null
    )
    if ($ShutdownExe)       { $script:InvokeShutdownExe = $ShutdownExe }
    if ($Powercfg)          { $script:InvokePowercfg    = $Powercfg }
    if ($RemovePendingTask) { $script:RemovePendingTask = $RemovePendingTask }
}

function Reset-PowerCommandSeam {
    $script:InvokeShutdownExe = $script:DefaultInvokeShutdownExe
    $script:InvokePowercfg    = $script:DefaultInvokePowercfg
    $script:RemovePendingTask = $script:DefaultRemovePendingTask
}

<#
    shutdown.exe /a reports "there was nothing to abort" as exit code 1116,
    ERROR_NO_SHUTDOWN_IN_PROGRESS. For a CANCEL that is success: the caller wants
    no pending shutdown, and there is none. Treating it as a failure would make
    cancelling an already-expired timer look broken.
#>
$script:ERROR_NO_SHUTDOWN_IN_PROGRESS = 1116

# Power can be exercised without Core/Log.ps1 loaded (unit tests dot-source this
# file alone), so logging is best-effort rather than a hard dependency. Same
# shape as Write-StateLog in Core/State.ps1.
function Write-PowerLog ([string]$Category, [string]$EventName, [string]$Detail) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Category $EventName $Detail }
}

# Call on the WPF UI thread: the execution-state request is per-thread, and the
# UI thread is the one that stays alive for the life of the app.
function Enable-KeepAwake {
    if ($script:keepAwakeHeld) { return }
    try {
        $flags = [uint32]([WinApi]::ES_CONTINUOUS -bor [WinApi]::ES_SYSTEM_REQUIRED)
        $prev  = [WinApi]::SetThreadExecutionState($flags)
        $script:keepAwakeHeld = ($prev -ne 0)
    } catch { $script:keepAwakeHeld = $false }
}

function Disable-KeepAwake {
    if (-not $script:keepAwakeHeld) { return }
    try { [WinApi]::SetThreadExecutionState([uint32][WinApi]::ES_CONTINUOUS) | Out-Null } catch {}
    $script:keepAwakeHeld = $false
}

function Test-KeepAwakeHeld { return $script:keepAwakeHeld }

# ── Legacy power-plan repair ──────────────────────────────────────────────────

# Only still used to interpret state written by the old build.
function Get-PowerTimeoutSecs {
    $result = @{ SleepAC = 0; SleepDC = 0; HibAC = 0; HibDC = 0 }
    $re = [regex]'Current (AC|DC) Power Setting Index: (0x[\da-fA-F]+)'
    try {
        $sleepOut = (& $script:InvokePowercfg @('/query','SCHEME_CURRENT','SUB_SLEEP','STANDBYIDLE')).Output
        foreach ($m in $re.Matches($sleepOut)) {
            $v = [Convert]::ToInt32($m.Groups[2].Value, 16)
            if ($m.Groups[1].Value -eq 'AC') { $result.SleepAC = $v } else { $result.SleepDC = $v }
        }
    } catch {}
    try {
        $hibOut = (& $script:InvokePowercfg @('/query','SCHEME_CURRENT','SUB_SLEEP','HIBERNATEIDLE')).Output
        foreach ($m in $re.Matches($hibOut)) {
            $v = [Convert]::ToInt32($m.Groups[2].Value, 16)
            if ($m.Groups[1].Value -eq 'AC') { $result.HibAC = $v } else { $result.HibDC = $v }
        }
    } catch {}
    return $result
}

<#
    Restores a power plan left modified by the pre-rewrite build. Runs at most
    once: the flag is cleared either way. Returns $true if values were written.
#>
function Repair-LegacyPowerSuppression {
    $s = Read-State
    if (-not ($s -and $s.sleepSuppression -and $s.sleepSuppression.active)) { return $false }

    $ss   = $s.sleepSuppression
    $vals = @(
        [int]($ss.originalSleepAC -as [int]), [int]($ss.originalSleepDC -as [int]),
        [int]($ss.originalHibAC   -as [int]), [int]($ss.originalHibDC   -as [int])
    )

    if (($vals | Measure-Object -Sum).Sum -eq 0) {
        # All zeros means either sleep genuinely was disabled, or the old build's
        # English-only powercfg parse failed on a localized Windows and recorded
        # nothing. Writing "never" back could be the damage rather than the
        # repair, so leave the plan untouched and just drop the flag.
        Write-State @{ sleepSuppression = @{ active = $false } }
        return $false
    }

    $toMins = { param($sec) if ($sec -le 0) { 0 } else { [math]::Max(1, [int][math]::Floor($sec / 60)) } }
    try {
        & $script:InvokePowercfg @('/change','standby-timeout-ac',   "$(& $toMins $vals[0])") | Out-Null
        & $script:InvokePowercfg @('/change','standby-timeout-dc',   "$(& $toMins $vals[1])") | Out-Null
        & $script:InvokePowercfg @('/change','hibernate-timeout-ac', "$(& $toMins $vals[2])") | Out-Null
        & $script:InvokePowercfg @('/change','hibernate-timeout-dc', "$(& $toMins $vals[3])") | Out-Null
    } catch {}

    Write-State @{ sleepSuppression = @{ active = $false } }
    return $true
}

# ── Pending action ────────────────────────────────────────────────────────────

<#
    The cheap half of the old Get-PendingState: reads the state file only.
    The dispatcher ticks once a second, so it must not touch Task Scheduler --
    enumerating scheduled tasks is a CIM query and belongs in Core/Scheduler.ps1.
#>
function Get-TrackedAction {
    $s = Read-State
    if (-not ($s -and $s.pendingAction -and $s.pendingAction.type -ne 'null')) { return $null }
    try {
        $target = [datetime]::Parse($s.pendingAction.targetAt).ToLocalTime()
        if ($target -gt (Get-Date)) { return $s.pendingAction }
        Clear-State
    } catch { Clear-State }
    return $null
}

# ── Timed actions ─────────────────────────────────────────────────────────────

function Write-PendingAction ([string]$Type, [int]$Seconds, [string]$Method, [datetime]$TargetAt) {
    Write-State @{ pendingAction = @{
        type      = $Type
        seconds   = $Seconds
        method    = $Method
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        targetAt  = $TargetAt.ToUniversalTime().ToString('o')
    }}
}

function Start-TimedShutdown ([int]$Seconds) {
    $r = & $script:InvokeShutdownExe @('/s','/t',"$Seconds",'/c','Timed Shutdown Utility')
    if ($r.ExitCode -ne 0) { throw "shutdown.exe failed: $($r.Output)" }
    Write-PendingAction 'shutdown' $Seconds 'os-timer' (Get-Date).AddSeconds($Seconds)
    Enable-KeepAwake
}

function Start-TimedRestart ([int]$Seconds) {
    $r = & $script:InvokeShutdownExe @('/r','/t',"$Seconds",'/c','Timed Shutdown Utility')
    if ($r.ExitCode -ne 0) { throw "shutdown.exe failed: $($r.Output)" }
    Write-PendingAction 'restart' $Seconds 'os-timer' (Get-Date).AddSeconds($Seconds)
    Enable-KeepAwake
}

# Sleep and hibernate have no OS-level timer equivalent, so they go through a
# one-shot scheduled task. ES_SYSTEM_REQUIRED blocks only *idle* sleep, so it
# does not interfere with the task's own forced suspend.
function Start-TimedSleep ([int]$Seconds) {
    $fireAt = (Get-Date).AddSeconds($Seconds)
    New-PendingTask 'TS_pending_sleep' 'rundll32.exe' 'powrprof.dll,SetSuspendState 0,1,0' $fireAt
    Write-PendingAction 'sleep' $Seconds 'scheduled-task' $fireAt
    Enable-KeepAwake
}

function Start-TimedHibernate ([int]$Seconds) {
    $fireAt = (Get-Date).AddSeconds($Seconds)
    New-PendingTask 'TS_pending_hibernate' 'shutdown.exe' '/h' $fireAt
    Write-PendingAction 'hibernate' $Seconds 'scheduled-task' $fireAt
    Enable-KeepAwake
}

<#
    Cancels whatever is pending, and reports honestly whether it managed to.

    Three outcomes have to stay distinguishable, because "cancelled" is a claim
    the user acts on -- they walk away from the machine believing it:

      * the target was there and is now gone   -> success, state cleared
      * there was nothing to cancel            -> success, state cleared
      * a cancel was attempted and FAILED      -> throws, state left intact

    -ErrorAction SilentlyContinue collapsed the second and third together, so a
    failed Unregister-ScheduledTask was indistinguishable from a task that had
    already gone. The app cleared its state, the UI said the timer was cancelled,
    and the scheduled sleep fired anyway.

    State is deliberately NOT cleared on failure. pendingAction mirrors something
    that still exists outside this process, so dropping the mirror would leave
    the user unable to see -- or retry -- the thing still counting down.
#>
function Stop-TimedAction {
    $s        = Read-State
    $failures = @()

    if ($s -and $s.pendingAction -and $s.pendingAction.type -in @('shutdown','restart')) {
        try {
            $r = & $script:InvokeShutdownExe @('/a')
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $script:ERROR_NO_SHUTDOWN_IN_PROGRESS) {
                $failures += "shutdown /a exited $($r.ExitCode): $($r.Output)"
            }
        } catch {
            $failures += "shutdown /a threw: $($_.Exception.Message)"
        }
    }

    foreach ($t in 'TS_pending_sleep','TS_pending_hibernate') {
        try {
            & $script:RemovePendingTask $t "$($script:TASK_FOLDER)\" | Out-Null
        } catch {
            $failures += Format-TaskRemovalFailure $t $_.Exception.Message
        }
    }

    if ($failures.Count -gt 0) {
        $detail = $failures -join '; '
        Write-PowerLog 'action' 'cancel-failed' $detail
        throw "Could not cancel the pending action: $detail"
    }

    $wasPending = if ($s -and $s.pendingAction) { "$($s.pendingAction.type)" } else { 'none' }
    Write-PowerLog 'action' 'cancelled' "was=$wasPending"

    Clear-State
    Disable-KeepAwake
    $script:notifyFired   = $false
    $script:guardBlocking = $false
}

<#
    Explains a failed task removal, naming the upgrade case when that is what it is.

    Builds up to 2.3 registered pending tasks under a SYSTEM principal, which
    required elevation. 2.4 registers them as the current user and no longer
    elevates - so a task left behind by the older build cannot be removed by
    this process, and the raw CIM error ("Access is denied") gives the user
    nothing to act on. A cancel that fails is the one message in this app that
    must be unambiguous: the user acts on it by walking away from the machine.
#>
function Format-TaskRemovalFailure ([string]$TaskName, [string]$Message) {
    if ($Message -match '(?i)access is denied|0x80070005|unauthorized') {
        return ("could not remove ${TaskName}: it was created by an older version of " +
                'Timed Shutdown that ran as administrator, so this (unelevated) copy ' +
                'cannot remove it. Use Remove leftover tasks on the Scheduled tab, or ' +
                'delete it from Task Scheduler under \TimedShutdown.')
    }
    return "could not remove ${TaskName}: $Message"
}

<#
    Pushes the pending action out by $ExtraSec. Returns $true on success.

    The TRANSACTION matters more than the arithmetic here. For shutdown and
    restart this cancels the OS timer and then arms a new one, so between those
    two calls there is no timer at all -- and if the second fails, the first has
    already destroyed the very thing being extended.

    The old code ran both with their exit codes ignored, inside a catch that
    swallowed everything, and then wrote pendingAction regardless. A failed
    re-arm left state claiming a countdown that nothing was driving: the window
    ticked down to zero and the machine stayed on. That is the v2.1
    scheduled-task defect exactly -- a timer with nothing behind it -- and the
    guard extension on the dispatcher tick calls straight into here, so it could
    happen without anyone touching a Snooze button.

    On failure the honest end state is "nothing pending", because the original
    really is gone. State is cleared, the reason is logged, and $false is
    returned so the caller can say so rather than showing a phantom countdown.
#>
function Add-SnoozeTime ([int]$ExtraSec) {
    $s = Read-State
    if (-not ($s -and $s.pendingAction -and $s.pendingAction.type -ne 'null')) { return $false }

    $type = $s.pendingAction.type
    try {
        $target    = [datetime]::Parse($s.pendingAction.targetAt).ToLocalTime()
        $newTarget = $target.AddSeconds($ExtraSec)
        $newSecs   = [math]::Max(1, [int]($newTarget - (Get-Date)).TotalSeconds)

        switch ($type) {
            'shutdown' { Reset-OsTimer '/s' $newSecs }
            'restart'  { Reset-OsTimer '/r' $newSecs }
            # New-PendingTask unregisters any existing task of the same name, and
            # registers with -ErrorAction Stop, so a rejection throws to the catch.
            'sleep'     { New-PendingTask 'TS_pending_sleep' 'rundll32.exe' 'powrprof.dll,SetSuspendState 0,1,0' $newTarget }
            'hibernate' { New-PendingTask 'TS_pending_hibernate' 'shutdown.exe' '/h' $newTarget }
            default     { throw "unknown pending action type '$type'" }
        }

        Write-State @{ pendingAction = @{
            type      = $type
            seconds   = $newSecs
            method    = $s.pendingAction.method
            startedAt = $s.pendingAction.startedAt
            targetAt  = $newTarget.ToUniversalTime().ToString('o')
        }}
        $script:notifyFired = $false
        return $true
    } catch {
        # Whatever was pending is already gone -- /a ran, or New-PendingTask
        # unregistered before failing to register. Writing a pendingAction now
        # would be exactly the phantom timer this exists to prevent.
        Clear-State
        Disable-KeepAwake
        $script:notifyFired   = $false
        $script:guardBlocking = $false
        Write-PowerLog 'action' 'snooze-failed' "type=$type error=$($_.Exception.Message)"
        return $false
    }
}

<#
    Re-arms the OS timer at a new offset: abort, then set.

    The abort may legitimately find nothing -- the timer can expire in the gap
    between reading state and getting here -- so 1116 is tolerated. The SET is
    not optional, and a non-zero exit there throws, because carrying on would
    record a countdown with no timer behind it.
#>
function Reset-OsTimer ([string]$Flag, [int]$Seconds) {
    $abort = & $script:InvokeShutdownExe @('/a')
    if ($abort.ExitCode -ne 0 -and $abort.ExitCode -ne $script:ERROR_NO_SHUTDOWN_IN_PROGRESS) {
        throw "shutdown /a exited $($abort.ExitCode): $($abort.Output)"
    }

    $set = & $script:InvokeShutdownExe @($Flag, '/t', "$Seconds", '/c', 'Timed Shutdown Utility')
    if ($set.ExitCode -ne 0) {
        throw "shutdown $Flag exited $($set.ExitCode): $($set.Output)"
    }
}

# ── Quick actions ─────────────────────────────────────────────────────────────

<#
    Turning the monitor off, as a bounded ASYNCHRONOUS operation.

    The v2.4 version was two lines and both were wrong:

        Start-Sleep -Milliseconds 300
        [WinApi]::SendMessage([WinApi]::HWND_BROADCAST, ...)

    Start-Sleep blocked the WPF dispatcher, and the unbounded broadcast blocked
    it again -- that one potentially forever, since SendMessage to
    HWND_BROADCAST waits on every top-level window in the session with no
    timeout at all. One app not pumping its queue left Timed Shutdown
    permanently at "(Not Responding)", needing a force-quit. The Win+Alt+M path
    was worse still: it ran all of that INSIDE a WndProc.

    So nothing here blocks. Invoke-MonitorOff records the start, arms a
    DispatcherTimer and returns; Step-MonitorOff runs one poll step per tick and
    performs the send once input has settled. The send is bounded per recipient
    by SendMessageTimeout + SMTO_ABORTIFHUNG.

    Splitting it this way is also what makes it testable: the state machine is
    three plain functions, and the timer is plumbing that only calls into them.
#>

# Input must be quiet this long before sending. Firing while the click that
# asked for it is still settling just wakes the display straight back up.
$script:MONITOR_SETTLE_MS = 700

# ...but never wait longer than this. Without a cap, a hand resting on the mouse
# means the display never turns off AT ALL -- a worse bug than the one the
# settle window exists to fix.
$script:MONITOR_MAX_WAIT_MS = 3000

$script:MONITOR_POLL_MS = 100

# PER RECIPIENT, not for the broadcast as a whole. See Interop.ps1.
$script:MONITOR_SEND_TIMEOUT_MS = 1000

$script:monitorOffPending = $false
$script:monitorOffTimer   = $null
$script:monitorOffStarted = 0

<#
    Test seams, the same shape as the shutdown.exe / powercfg ones above.

    The send returns @{ Result; LastError } rather than the raw IntPtr because a
    native BOOL-style failure does NOT raise a PowerShell exception. Wrapping
    the P/Invoke in try/catch would catch nothing whatsoever, and we would be
    back to the silent failure this change exists to remove. The caller has to
    inspect the value, so the value has to carry the error code with it.
#>
$script:DefaultSendMonitorOff = {
    $res = [UIntPtr]::Zero
    $rc  = [WinApi]::SendMessageTimeout([WinApi]::HWND_BROADCAST, [WinApi]::WM_SYSCOMMAND,
               [IntPtr][WinApi]::SC_MONITORPOWER, [IntPtr]2,
               [WinApi]::SMTO_ABORTIFHUNG, [uint32]$script:MONITOR_SEND_TIMEOUT_MS, [ref]$res)
    # Read the error IMMEDIATELY. The thread's last-error value is clobbered by
    # the next call that sets one, so anything in between -- even a pipeline --
    # can substitute a completely unrelated code.
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{ Result = $rc; LastError = $err }
}

$script:DefaultGetIdleMs = { [int][WinApi]::GetIdleMs() }

# Deliberately NOT Core/Triggers.ps1's Get-MonotonicMs, despite being the same
# one-liner: Power.ps1 is dot-sourced ALONE by tests/Power.Tests.ps1, so taking
# a dependency on Triggers.ps1 would break that file on its next run. Same
# reasoning as Write-PowerLog treating Core/Log.ps1 as optional.
$script:DefaultGetMonotonicMs = { [long][WinApi]::GetTickCount64() }

$script:SendMonitorOff = $script:DefaultSendMonitorOff
$script:GetIdleMs      = $script:DefaultGetIdleMs
$script:GetMonotonicMs = $script:DefaultGetMonotonicMs

function Set-MonitorSeam {
    param(
        [scriptblock] $SendMonitorOff = $null,
        [scriptblock] $GetIdleMs      = $null,
        [scriptblock] $GetMonotonicMs = $null
    )
    if ($SendMonitorOff) { $script:SendMonitorOff = $SendMonitorOff }
    if ($GetIdleMs)      { $script:GetIdleMs      = $GetIdleMs }
    if ($GetMonotonicMs) { $script:GetMonotonicMs = $GetMonotonicMs }
}

function Reset-MonitorSeam {
    $script:SendMonitorOff = $script:DefaultSendMonitorOff
    $script:GetIdleMs      = $script:DefaultGetIdleMs
    $script:GetMonotonicMs = $script:DefaultGetMonotonicMs
}

function Test-MonitorOffPending { return $script:monitorOffPending }

# Drops an armed poll. Separate from the pending flag on purpose: a 'wait' step
# must keep the flag while doing none of this.
function Stop-MonitorOffPoll {
    if ($script:monitorOffTimer) {
        try { $script:monitorOffTimer.Stop() } catch {}
    }
    $script:monitorOffTimer = $null
}

# Back to "nothing in flight", for the failure paths and for tests between cases.
function Reset-MonitorOffState {
    Stop-MonitorOffPoll
    $script:monitorOffPending = $false
}

<#
    Whether this poll step should send yet. Pure: no clock, no I/O, no state.

    Milliseconds and integers throughout -- everything upstream is already
    tick-based, and converting to fractional seconds here would only introduce
    rounding at exactly the boundaries the tests pin down.

      WaitedMs >= MONITOR_MAX_WAIT_MS  -> send, whatever the input is doing
      IdleMs   >= MONITOR_SETTLE_MS    -> send
      otherwise                        -> wait
#>
function Get-MonitorOffDecision ([int]$IdleMs, [int]$WaitedMs) {
    if ($WaitedMs -ge $script:MONITOR_MAX_WAIT_MS) { return 'send' }
    if ($IdleMs   -ge $script:MONITOR_SETTLE_MS)   { return 'send' }
    return 'wait'
}

<#
    Classifies what the native send actually did.

    $Sent is the @{ Result; LastError } handed back by the send seam. Return
    exactly one of:

      'sent'   - the request went through normally.
      'hung'   - at least one recipient was skipped because it was not pumping
                 its queue. SMTO_ABORTIFHUNG exists to produce this; other
                 windows may well have handled the command, and the display very
                 likely did go off. NOT a failure.
      'failed' - the call genuinely did not work, and is worth a log entry.

    The Win32 shape: SendMessageTimeout returns non-zero on success. Zero means
    either "timed out or aborted on a hung recipient" or "failed outright", and
    the only thing separating those two is the error code captured alongside it
    -- [WinApi]::ERROR_TIMEOUT (1460), or 0 when the call set no error at all.

    Both ways of getting this wrong have already shipped in this app: crying
    wolf turns an ordinary broadcast into an alarming log line, and swallowing
    the failure is exactly the silence that hid the original freeze for a whole
    release.
#>
function Get-MonitorOffOutcome ($Sent) {
    # No result object at all means the seam itself is broken. Guessing
    # 'sent' here would be the silence this function exists to end.
    if (-not $Sent) { return 'failed' }

    # Non-zero is a plain success and needs no error inspection.
    if ([IntPtr]$Sent.Result -ne [IntPtr]::Zero) { return 'sent' }

    # Zero is ambiguous, and only the error code separates the two cases.
    # ERROR_TIMEOUT is SMTO_ABORTIFHUNG doing exactly its job; 0 is the
    # call declining to set an error at all, which is the same story. Every
    # OTHER code is a real fault -- ERROR_ACCESS_DENIED and friends -- and
    # gets reported rather than swallowed.
    $err = [int]$Sent.LastError
    if ($err -eq 0 -or $err -eq [WinApi]::ERROR_TIMEOUT) { return 'hung' }
    return 'failed'
}

<#
    One poll step. The DispatcherTimer calls this; tests call it directly, which
    is the entire reason it is a function rather than an inline scriptblock.

    Every terminal path -- sent, tolerated, or thrown -- stops the timer, drops
    the reference and clears the pending flag. A path that misses one leaves
    either a timer ticking forever or monitorOffPending stuck true, and the
    second of those disables the button for the life of the process.

    One attempt only: a failed send logs and stops. Re-arming the poll after a
    failure would turn a transient fault into a 10Hz message storm.
#>
function Step-MonitorOff {
    # A tick queued before Stop() still arrives. Anything past here
    # would send a SECOND time on an operation that already finished.
    if (-not $script:monitorOffPending) { return }

    $complete = $false
    try {
        $waited = [int]((& $script:GetMonotonicMs) - $script:monitorOffStarted)
        $idle   = [int](& $script:GetIdleMs)
        if ((Get-MonitorOffDecision $idle $waited) -eq 'wait') { return }

        # Past here the operation is over however it goes, so tear the poll down
        # BEFORE sending: a throw inside the send must not leave it armed.
        $complete = $true
        Stop-MonitorOffPoll

        $outcome = Get-MonitorOffOutcome (& $script:SendMonitorOff)
        if ($outcome -eq 'failed') {
            Write-PowerLog 'monitor' 'off-failed' "waitedMs=$waited idleMs=$idle"
        } else {
            Write-PowerLog 'monitor' 'off' "outcome=$outcome waitedMs=$waited idleMs=$idle"
        }
    } catch {
        $complete = $true
        Stop-MonitorOffPoll
        Write-PowerLog 'monitor' 'off-failed' $_.Exception.Message
    } finally {
        # Deliberately NOT unconditional: a 'wait' step has to leave the flag
        # set, or the next click would arm a second poll alongside this one.
        if ($complete) { $script:monitorOffPending = $false }
    }
}

<#
    Arms the poll and returns AT ONCE. Safe to call from a WndProc.

    The pending flag is set here and deliberately NOT cleared here: it has to
    stay true for the whole asynchronous operation, which outlives this function
    by design. Clearing it in a finally would make it useless -- the second click
    of a double-click would arrive after the flag had already gone false and arm
    a second, overlapping poll, which is precisely the stacking it exists to
    prevent. Only a terminal Step-MonitorOff path clears it.
#>
function Invoke-MonitorOff {
    if ($script:monitorOffPending) { return }
    $script:monitorOffPending = $true
    $script:monitorOffStarted = & $script:GetMonotonicMs

    try {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [timespan]::FromMilliseconds($script:MONITOR_POLL_MS)
        $t.Add_Tick({ Step-MonitorOff })
        $script:monitorOffTimer = $t
        $t.Start()
    } catch {
        # Could not arm at all -- release the flag, or the button is dead for the
        # rest of the session.
        Reset-MonitorOffState
        Write-PowerLog 'monitor' 'off-failed' "could not arm: $($_.Exception.Message)"
    }
}

function Invoke-LockScreen {
    & rundll32.exe user32.dll,LockWorkStation
}
