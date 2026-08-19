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
        $sleepOut = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1 | Out-String
        foreach ($m in $re.Matches($sleepOut)) {
            $v = [Convert]::ToInt32($m.Groups[2].Value, 16)
            if ($m.Groups[1].Value -eq 'AC') { $result.SleepAC = $v } else { $result.SleepDC = $v }
        }
    } catch {}
    try {
        $hibOut = powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 2>&1 | Out-String
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
        powercfg /change standby-timeout-ac   (& $toMins $vals[0]) | Out-Null
        powercfg /change standby-timeout-dc   (& $toMins $vals[1]) | Out-Null
        powercfg /change hibernate-timeout-ac (& $toMins $vals[2]) | Out-Null
        powercfg /change hibernate-timeout-dc (& $toMins $vals[3]) | Out-Null
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
    $out = & shutdown.exe /s /t $Seconds /c "Timed Shutdown Utility" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed: $out" }
    Write-PendingAction 'shutdown' $Seconds 'os-timer' (Get-Date).AddSeconds($Seconds)
    Enable-KeepAwake
}

function Start-TimedRestart ([int]$Seconds) {
    $out = & shutdown.exe /r /t $Seconds /c "Timed Shutdown Utility" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed: $out" }
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

function Stop-TimedAction {
    $s = Read-State
    if ($s -and $s.pendingAction -and $s.pendingAction.type -in @('shutdown','restart')) {
        & shutdown.exe /a 2>&1 | Out-Null
    }
    foreach ($t in 'TS_pending_sleep','TS_pending_hibernate') {
        Unregister-ScheduledTask -TaskName $t -TaskPath "$($script:TASK_FOLDER)\" `
            -Confirm:$false -ErrorAction SilentlyContinue
    }
    Clear-State
    Disable-KeepAwake
    $script:notifyFired   = $false
    $script:guardBlocking = $false
}

function Add-SnoozeTime ([int]$ExtraSec) {
    $s = Read-State
    if (-not ($s -and $s.pendingAction -and $s.pendingAction.type -ne 'null')) { return }
    try {
        $target    = [datetime]::Parse($s.pendingAction.targetAt).ToLocalTime()
        $newTarget = $target.AddSeconds($ExtraSec)
        $newSecs   = [math]::Max(1, [int]($newTarget - (Get-Date)).TotalSeconds)
        $type      = $s.pendingAction.type
        switch ($type) {
            'shutdown' {
                & shutdown.exe /a 2>&1 | Out-Null
                & shutdown.exe /s /t $newSecs /c "Timed Shutdown Utility" 2>&1 | Out-Null
            }
            'restart'  {
                & shutdown.exe /a 2>&1 | Out-Null
                & shutdown.exe /r /t $newSecs /c "Timed Shutdown Utility" 2>&1 | Out-Null
            }
            # New-PendingTask unregisters any existing task of the same name.
            'sleep'     { New-PendingTask 'TS_pending_sleep' 'rundll32.exe' 'powrprof.dll,SetSuspendState 0,1,0' $newTarget }
            'hibernate' { New-PendingTask 'TS_pending_hibernate' 'shutdown.exe' '/h' $newTarget }
        }
        Write-State @{ pendingAction = @{
            type      = $type
            seconds   = $newSecs
            method    = $s.pendingAction.method
            startedAt = $s.pendingAction.startedAt
            targetAt  = $newTarget.ToUniversalTime().ToString('o')
        }}
        $script:notifyFired = $false
    } catch {}
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
