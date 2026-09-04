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
            $failures += "could not remove ${t}: $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        $detail = $failures -join '; '
        Write-PowerLog 'action' 'cancel-failed' $detail
        throw "Could not cancel the pending action: $detail"
    }

    Clear-State
    Disable-KeepAwake
    $script:notifyFired   = $false
    $script:guardBlocking = $false
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

function Invoke-MonitorOff {
    # Brief pause so the click's own input event doesn't wake the display again.
    Start-Sleep -Milliseconds 300
    [WinApi]::SendMessage([WinApi]::HWND_BROADCAST, [WinApi]::WM_SYSCOMMAND,
        [IntPtr][WinApi]::SC_MONITORPOWER, [IntPtr]2) | Out-Null
}

function Invoke-LockScreen {
    & rundll32.exe user32.dll,LockWorkStation
}
