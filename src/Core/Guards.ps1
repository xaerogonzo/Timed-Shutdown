#Requires -Version 5.1
<#
    Core/Guards.ps1 - postpone an action while the machine is still busy.

    These used to read $ChkGuardNetwork / $TxtNetKbps / $TxtProcessName straight
    out of the UI scope. They now take parameters, so Core/ never depends on UI/
    and the logic can be tested without a window.
#>

$script:lastNetBytes = $null
$script:lastNetTime  = $null

<#
    Throughput since the previous call, in KB/s. The first call establishes the
    baseline and returns 0.
#>
function Get-NetworkKbps {
    try {
        $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue
        $total = 0
        foreach ($st in $stats) { $total += $st.ReceivedBytes + $st.SentBytes }
        $now = [datetime]::UtcNow

        if ($null -ne $script:lastNetBytes -and $null -ne $script:lastNetTime) {
            $elapsed = ($now - $script:lastNetTime).TotalSeconds
            if ($elapsed -gt 0.1) {
                # Max(0, ...) guards against adapter counters resetting.
                $delta = [math]::Max(0, $total - $script:lastNetBytes)
                $script:lastNetBytes = $total
                $script:lastNetTime  = $now
                return $delta / 1024.0 / $elapsed
            }
        }
        $script:lastNetBytes = $total
        $script:lastNetTime  = $now
        return 0.0
    } catch { return 0.0 }
}

<#
    Returns a human-readable reason the action should be held back, or $null when
    nothing is blocking.
#>
function Get-GuardBlockReason {
    param(
        [bool]   $NetworkGuard  = $false,
        [double] $CurrentKbps   = 0,
        [double] $ThresholdKbps = 0,
        [bool]   $ProcessGuard  = $false,
        [string] $ProcessName   = '',
        # Same seam idiom as New-TriggerContext's GetProcessCount in
        # Core/Triggers.ps1: the real lookup is the default and tests swap it, so
        # guard behaviour can be exercised without depending on which processes
        # happen to be running on the machine executing the suite.
        [scriptblock] $GetProcessCount = $null
    )
    if (-not $GetProcessCount) {
        $GetProcessCount = { param($name) @(Get-Process -Name $name -ErrorAction SilentlyContinue).Count }
    }

    if ($NetworkGuard -and $CurrentKbps -gt $ThresholdKbps) {
        return "network active ($([math]::Round($CurrentKbps, 1)) KB/s)"
    }
    if ($ProcessGuard) {
        # Strip a typed .exe, exactly as the Triggers tab already does in
        # UI/MainWindow.ps1 -- "people type ffmpeg.exe out of habit".
        #
        # Get-Process -Name matches the process name WITHOUT its extension, so
        # "steam.exe" matched nothing and this guard silently never blocked. The
        # identical text typed one tab over DID work, because that path strips it.
        # A guard that quietly does nothing is worse than no guard: the user
        # believes the shutdown is being held back.
        $p = ($ProcessName.Trim() -replace '\.exe$', '')
        if ($p -ne '' -and (& $GetProcessCount $p) -gt 0) {
            return "process '$p' is running"
        }
    }
    return $null
}

function Test-GuardsAllClear {
    param(
        [bool]   $NetworkGuard  = $false,
        [double] $CurrentKbps   = 0,
        [double] $ThresholdKbps = 0,
        [bool]   $ProcessGuard  = $false,
        [string] $ProcessName   = '',
        [scriptblock] $GetProcessCount = $null
    )
    return $null -eq (Get-GuardBlockReason -NetworkGuard $NetworkGuard -CurrentKbps $CurrentKbps `
                        -ThresholdKbps $ThresholdKbps -ProcessGuard $ProcessGuard -ProcessName $ProcessName `
                        -GetProcessCount $GetProcessCount)
}

# ── CPU ───────────────────────────────────────────────────────────────────────

$script:lastCpuIdle = $null
$script:lastCpuBusy = $null

<#
    Whole-system CPU load as a percentage, or $null when no reading is available
    yet.

    Returning $null on the first call is deliberate and load-bearing: the value
    is a delta between two samples, so the first call has nothing to compare
    against. A caller must treat $null as "no data" and never as 0% - reading an
    unavailable sample as "0%, therefore idle" would fire a resource trigger on
    a busy machine.

    Uses GetSystemTimes rather than Get-Counter (localized counter names) or the
    WMI perf class (~290ms per call). See Interop.ps1.
#>
function Get-CpuPercent {
    try {
        $idle = New-Object FILETIME; $kern = New-Object FILETIME; $user = New-Object FILETIME
        if (-not [WinApi]::GetSystemTimes([ref]$idle, [ref]$kern, [ref]$user)) { return $null }

        $idleNow = [WinApi]::FileTimeToULong($idle)
        # Kernel time already includes idle time, so busy = kernel + user.
        $busyNow = [WinApi]::FileTimeToULong($kern) + [WinApi]::FileTimeToULong($user)

        if ($null -eq $script:lastCpuIdle) {
            $script:lastCpuIdle = $idleNow; $script:lastCpuBusy = $busyNow
            return $null                      # priming sample
        }

        # Capture the previous values BEFORE overwriting them, or the
        # backwards-counter check below compares a value against itself.
        $prevIdle = $script:lastCpuIdle
        $prevBusy = $script:lastCpuBusy
        $script:lastCpuIdle = $idleNow
        $script:lastCpuBusy = $busyNow

        # Counters went backwards (or wrapped): unsigned subtraction would give a
        # huge bogus delta, so refuse the sample instead.
        if ($idleNow -lt $prevIdle -or $busyNow -lt $prevBusy) { return $null }

        $dIdle = $idleNow - $prevIdle
        $dBusy = $busyNow - $prevBusy

        # No elapsed busy time, or more idle than total: nonsensical, not 0%.
        if ($dBusy -le 0 -or $dIdle -gt $dBusy) { return $null }

        return [math]::Round((1 - ($dIdle / [double]$dBusy)) * 100, 1)
    } catch { return $null }
}

function Reset-CpuSampler { $script:lastCpuIdle = $null; $script:lastCpuBusy = $null }

# ── Idle ──────────────────────────────────────────────────────────────────────

<#
    Seconds since the last mouse move, click, or keypress anywhere on the desktop.

    Backed by GetLastInputInfo, which reports GetTickCount - the same clock family
    the trigger engine measures grace against. That pairing is deliberate: a
    QueryPerformanceCounter-based elapsed compared against this would disagree
    across suspend, because the two advance differently while the machine sleeps.
#>
function Get-IdleSeconds {
    try { return [WinApi]::GetIdleMs() / 1000.0 } catch { return 0.0 }
}
