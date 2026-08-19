#Requires -Version 5.1
<#
    Timed Shutdown - entry point.

    Run this file directly during development; run dist\TimedShutdown.ps1 (built
    by build.ps1) for the single-file distribution. Both take the same path
    through the code - the bundler only inlines these dot-sources and the XAML.

    Load order is fixed rather than globbed: Interop.ps1 defines the types every
    other module references, Log.ps1 must exist before anything wants to record a
    failure, and UI/MainWindow.ps1 creates $window, which UI/Tray.ps1 attaches to.
#>

# Shown in the header, the tray tooltip, and every log line. NOT in Window.Title:
# the single-instance guard finds the existing window by exact title, so the
# title has to stay stable across versions.
$script:APP_VERSION = '2.2'

. "$PSScriptRoot\Interop.ps1"

# ── Admin check ───────────────────────────────────────────────────────────────
# Registering SYSTEM-principal scheduled tasks (sleep/hibernate timers and the
# Schedule tab) needs elevation. TimedShutdown.bat handles the UAC prompt.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [System.Windows.MessageBox]::Show(
        "Administrator privileges are required.`n`nPlease launch via TimedShutdown.bat.",
        'Administrator Required', 'OK', 'Warning') | Out-Null
    exit 1
}

# ── Single instance ───────────────────────────────────────────────────────────
# Before ANY state mutation: two instances would both tick and fight over
# state.json. Activation of the existing window is best-effort - Windows does not
# guarantee SetForegroundWindow succeeds, and a failure must never stop this
# instance from exiting cleanly.
$script:mutexOwned = $false
$script:appMutex   = New-Object System.Threading.Mutex($true, 'Local\TimedShutdown', [ref]$script:mutexOwned)
if (-not $script:mutexOwned) {
    try {
        $hwnd = [WinApi]::FindWindow($null, 'Timed Shutdown')
        if ($hwnd -ne [IntPtr]::Zero) {
            [WinApi]::ShowWindow($hwnd, [WinApi]::SW_RESTORE) | Out-Null
            [WinApi]::SetForegroundWindow($hwnd) | Out-Null
        }
    } catch {}
    try { $script:appMutex.Dispose() } catch {}
    exit 0
}

try {

. "$PSScriptRoot\Core\Log.ps1"
. "$PSScriptRoot\Core\Time.ps1"
. "$PSScriptRoot\Core\State.ps1"
. "$PSScriptRoot\Core\Scheduler.ps1"
. "$PSScriptRoot\Core\Guards.ps1"
. "$PSScriptRoot\Core\Triggers.ps1"
. "$PSScriptRoot\Core\Power.ps1"
. "$PSScriptRoot\UI\Theme.ps1"
. "$PSScriptRoot\UI\Xaml.ps1"
. "$PSScriptRoot\UI\MainWindow.ps1"
. "$PSScriptRoot\UI\ScheduleDialog.ps1"
. "$PSScriptRoot\UI\Tray.ps1"

# ── Script-scope state ────────────────────────────────────────────────────────
$script:notifyFired     = $false
$script:guardBlocking   = $false
$script:currentKbps     = 0.0
$script:currentCpu      = $null
$script:exitApp         = $false
$script:firstMinimize   = $true
$script:hotkeyMgr       = $null
$script:actionInProgress = $false
$script:lastTickTicks   = Get-MonotonicMs

# A guard postpones the action once it is inside GUARD_TRIGGER_SEC, pushing the
# target out by GUARD_EXTEND_SEC. The old code used a 30 s window and extended by
# 30 s on *every* tick, re-arming shutdown.exe once a second.
$script:GUARD_TRIGGER_SEC = 15
$script:GUARD_EXTEND_SEC  = 60

# ── Startup ───────────────────────────────────────────────────────────────────

Initialize-StateStore
Write-LogHeader
Update-StateSchema | Out-Null

# Undo any power plan left modified by the pre-v2.0 build. No-op afterwards.
if (Repair-LegacyPowerSuppression) {
    $trayIcon.ShowBalloonTip(6000, 'Timed Shutdown',
        'Restored the sleep/hibernate settings left changed by an earlier version.',
        [System.Windows.Forms.ToolTipIcon]::Info)
}

Restore-Settings
if (Get-TrackedAction) { Enable-KeepAwake }

Refresh-ActiveTimer
Refresh-ScheduledList
Update-TriggerDisplay

$window.Title = 'Timed Shutdown'   # stable; version lives in the header instead
$LblAppTitle = $window.FindName('LblAppTitle')
if ($LblAppTitle) { $LblAppTitle.Text = "Timed Shutdown  v$($script:APP_VERSION)" }

# ── The single action chokepoint (I4) ─────────────────────────────────────────
<#
    Every path that can start a power action goes through here: an expiring
    timer, a fired trigger, the tray menu.

    WPF's dispatcher is single-threaded, so a tick cannot preempt a click handler
    mid-statement - but blocking calls that pump messages (MessageBox, ShowDialog,
    invoking shutdown.exe) DO allow re-entrancy, and ticks queue up behind them.
    The flag is what stops two owners starting an action.
#>
function Invoke-PowerAction ([string]$Action, [int]$DelaySec, [string]$Source) {
    if ($script:actionInProgress) {
        Write-Log 'action' 'suppressed' "source=$Source action=$Action reason=already-in-progress"
        return $false
    }
    $script:actionInProgress = $true
    try {
        Write-Log 'action' 'start' "source=$Source action=$Action delaySec=$DelaySec"
        switch ($Action) {
            'shutdown'  { Start-TimedShutdown  $DelaySec }
            'restart'   { Start-TimedRestart   $DelaySec }
            'sleep'     { Start-TimedSleep     $DelaySec }
            'hibernate' { Start-TimedHibernate $DelaySec }
            default     { throw "Unknown action: $Action" }
        }
        Refresh-ActiveTimer
        return $true
    } catch {
        Write-Log 'action' 'failed' "source=$Source action=$Action error=$($_.Exception.Message)"
        Show-ErrorBox "Failed to start $Action`:`n$($_.Exception.Message)"
        return $false
    } finally {
        $script:actionInProgress = $false
    }
}

# ── Dispatcher ────────────────────────────────────────────────────────────────

$dispTimer          = New-Object System.Windows.Threading.DispatcherTimer
$dispTimer.Interval = [timespan]::FromSeconds(1)

$dispTimer.Add_Tick({
    $nowTicks = Get-MonotonicMs
    $gapSec   = ($nowTicks - $script:lastTickTicks) / 1000
    $script:lastTickTicks = $nowTicks

    $script:currentKbps = Get-NetworkKbps
    $script:currentCpu  = Get-CpuPercent      # $null until the second sample

    Refresh-ActiveTimer

    $tracked = Get-TrackedAction
    if ($tracked) {
        try {
            $ttgt    = [datetime]::Parse($tracked.targetAt).ToLocalTime()
            $tremain = $ttgt - (Get-Date)

            if ($ChkNotify.IsChecked -and -not $script:notifyFired) {
                $notifyMins = [int]($TxtNotifyMins.Text -as [int])
                if ($notifyMins -gt 0 -and $tremain.TotalMinutes -le $notifyMins) {
                    $minsLeft = [math]::Max(1, [int][math]::Ceiling($tremain.TotalMinutes))
                    $trayIcon.ShowBalloonTip(8000, 'Timed Shutdown',
                        "$($tracked.type) in ~$minsLeft min  -  Click tray icon to open",
                        [System.Windows.Forms.ToolTipIcon]::Warning)
                    $script:notifyFired = $true
                }
            }

            $g = Get-GuardSettings
            if ($g.NetworkGuard -or $g.ProcessGuard) {
                $reason = Get-GuardBlockReason -NetworkGuard $g.NetworkGuard -CurrentKbps $script:currentKbps `
                            -ThresholdKbps $g.ThresholdKbps -ProcessGuard $g.ProcessGuard -ProcessName $g.ProcessName

                if ($null -ne $reason -and $tremain.TotalSeconds -le $script:GUARD_TRIGGER_SEC -and $tremain.TotalSeconds -gt 0) {
                    Add-SnoozeTime $script:GUARD_EXTEND_SEC
                    $script:guardBlocking = $true
                    Write-Log 'guard' 'extended' "reason=$reason"
                }
                if ($null -ne $reason -and $script:guardBlocking) {
                    $LblGuardBlocked.Text       = "⏸ Waiting: $reason"
                    $LblGuardBlocked.Visibility = 'Visible'
                } elseif ($null -eq $reason) {
                    $script:guardBlocking       = $false
                    $LblGuardBlocked.Visibility = 'Collapsed'
                }
            } elseif ($script:guardBlocking) {
                $script:guardBlocking       = $false
                $LblGuardBlocked.Visibility = 'Collapsed'
            }
        } catch {}
    }

    # ── Triggers ──
    if (Test-TriggerArmed) {
        try {
            $ctx = New-TriggerContext -NowTicks $nowTicks -IdleSec (Get-IdleSeconds) `
                     -Kbps $script:currentKbps -CpuPercent $script:currentCpu -TickGapSec $gapSec
            $res = Update-Trigger $ctx

            if ($res.Fire) {
                $t = Get-Trigger
                # A timer already counting down is the explicit user instruction
                # and wins; the trigger goes back to cooldown rather than racing it.
                if (Get-TrackedAction) {
                    Write-Log 'trigger' 'superseded' 'a timer was already pending'
                    Enter-TriggerCooldown 'superseded by timer' 0 $ctx
                } else {
                    $act = $t.Action
                    Complete-TriggerExecution
                    Invoke-PowerAction $act 5 "trigger:$($t.Kind)" | Out-Null
                    if (-not (Get-TrackedAction)) { Disable-KeepAwake }
                }
            } elseif ($res.Reason) {
                $trayIcon.ShowBalloonTip(5000, 'Timed Shutdown',
                    "Action cancelled - $($res.Reason)", [System.Windows.Forms.ToolTipIcon]::Info)
            }
            Update-TriggerDisplay
        } catch {
            Write-Log 'trigger' 'error' $_.Exception.Message
        }
    }

    # Tray tooltip. Capped at 63 chars - NotifyIcon.Text throws beyond that.
    try {
        $tip = if ($tracked) {
            $t2 = [datetime]::Parse($tracked.targetAt).ToLocalTime()
            $r2 = $t2 - (Get-Date)
            if ($r2.TotalSeconds -gt 0) { "$($tracked.type) in $(Format-Countdown $r2)" } else { 'Timed Shutdown' }
        } elseif (Test-TriggerArmed) {
            "Trigger: $((Get-Trigger).State.ToLower())"
        } else { "Timed Shutdown v$($script:APP_VERSION)" }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $trayIcon.Text = $tip
    } catch {}
})

$dispTimer.Start()

# ── Show ──────────────────────────────────────────────────────────────────────
$window.ShowDialog() | Out-Null
$dispTimer.Stop()
Save-TriggerSettings
Disable-KeepAwake
Write-Log 'app' 'exit' ''

}
finally {
    # Release deterministically: an exception during startup must not leave a
    # confused mutex lifetime inside this process.
    if ($script:appMutex) {
        if ($script:mutexOwned) { try { $script:appMutex.ReleaseMutex() } catch {} }
        try { $script:appMutex.Dispose() } catch {}
    }
}
