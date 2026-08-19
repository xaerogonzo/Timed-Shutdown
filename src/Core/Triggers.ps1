#Requires -Version 5.1
<#
    Core/Triggers.ps1 - "do X when Y happens".

    The point of this module is that a polling loop which fires whenever a
    predicate is true is NOT a trigger engine. Arm "when notepad exits", cancel
    the grace countdown, and notepad is still closed - so a naive loop fires
    again on the very next tick, forever. "The condition is true" and "the event
    just happened" are different statements, and for an app whose purpose is a
    destructive action the difference is the entire design.

    Invariants (also in docs/ARCHITECTURE.md):

      I1  An EVENT may cause at most one GRACE transition until a RESET occurs.
      I2  RESET is a transition observed AFTER entering COOLDOWN that returns the
          trigger to a re-armable baseline. It is never satisfied merely because
          a pre-existing predicate is still true.
      I3  Leaving COOLDOWN requires RESET *and* snooze expiry - both, never either.
      I4  Exactly one code path may start a power action (Invoke-PowerAction).
      I5  No trigger may fire from state loaded off disk; arming is a live user act.

    State machine:

      DISARMED -arm-> ARMING -(min arm)-> WATCHING -(primed)-> PRIMED
                                            ^                    |
                                     (RESET and snooze)      (EVENT edge)
                                            |                    v
                                        COOLDOWN <-cancel/activity/snooze- GRACE
                                                                           |
                                                                  (countdown ends)
                                                                           v
                                                                       EXECUTING

    Evaluators never touch the UI and never call Get-Process or Get-Date
    directly: everything arrives through $Context, so tests inject fake process
    counts and synthetic samples rather than depending on real machine load.
#>

$script:TRIGGER_KINDS = @('idle', 'process', 'downloads', 'signal', 'resource')

# Browser/downloader partial-file markers. A HEURISTIC, not a general download
# detector - a downloader using an unlisted temporary name is invisible to it.
$script:PARTIAL_EXTENSIONS = @('.crdownload', '.part', '.partial', '.download', '.aria2', '.!ut', '.opdownload')

# All durations are measured against Get-MonotonicMs, never Get-Date: wall-clock
# deltas break under NTP correction and DST, and the tick clock is the same
# family as GetLastInputInfo, which the grace abort compares against.
$script:MIN_ARM_SEC                  = 15
$script:GRACE_SEC                    = 60
$script:GRACE_ACTIVITY_TOLERANCE_SEC = 1.5
$script:SUSPEND_GAP_SEC              = 5

<#
    Milliseconds since boot. The single source of elapsed time in this module.

    Wrapped in a function so it can be substituted in tests and so there is
    exactly one place that knows which API provides it - see Interop.ps1 for why
    it is not [Environment]::TickCount64.
#>
function Get-MonotonicMs {
    return [long][WinApi]::GetTickCount64()
}

# ── Trigger record ────────────────────────────────────────────────────────────

function New-TriggerRecord {
    return @{
        State            = 'DISARMED'
        Kind             = 'idle'
        Action           = 'shutdown'
        Config           = @{}
        Eval             = @{}      # per-kind evaluator state; never shared
        ArmedAtTicks     = 0
        GraceStartTicks  = 0
        SnoozeUntilTicks = 0
        Status           = ''
        LastReason       = ''
    }
}

$script:trigger = New-TriggerRecord

function Get-Trigger       { return $script:trigger }
function Get-TriggerState  { return $script:trigger.State }
function Test-TriggerArmed { return $script:trigger.State -ne 'DISARMED' }

<#
    Everything an evaluator is allowed to know about the outside world.
    Tests build this by hand; the app builds one per tick.
#>
function New-TriggerContext {
    param(
        [long]        $NowTicks   = (Get-MonotonicMs),
        [double]      $IdleSec    = 0,
                      $Kbps       = $null,   # $null means "no valid sample"
                      $CpuPercent = $null,
        [double]      $TickGapSec = 1,
        [scriptblock] $GetProcessCount = $null,
        # Passive means "observe only". Set while ARMING so evaluators establish
        # their baselines without side effects - signal in particular must not
        # delete the flag file before the trigger is actually watching for it.
        [switch]      $Passive
    )
    if (-not $GetProcessCount) {
        $GetProcessCount = { param($name) @(Get-Process -Name $name -ErrorAction SilentlyContinue).Count }
    }
    return @{
        NowTicks        = $NowTicks
        IdleSec         = $IdleSec
        Kbps            = $Kbps
        CpuPercent      = $CpuPercent
        TickGapSec      = $TickGapSec
        GetProcessCount = $GetProcessCount
        Passive         = [bool]$Passive
    }
}

# ── Config access ─────────────────────────────────────────────────────────────

<#
    Reads a config value, falling back only when it is genuinely absent.

    `if ($Config.SustainSec) { ... } else { 120 }` looks harmless but treats 0 as
    missing, so "fire as soon as it goes quiet" would silently become "wait two
    minutes". Config also arrives as a PSCustomObject once it has round-tripped
    through state.json, so both shapes have to be handled.
#>
function Get-TriggerConfigValue ($Config, [string]$Key, $Default) {
    if ($null -eq $Config) { return $Default }
    $value = $null
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Key)) { $value = $Config[$Key] }
    } elseif ($Config.PSObject.Properties[$Key]) {
        $value = $Config.$Key
    }
    if ($null -eq $value) { return $Default }
    return $value
}

# ── Evaluators ────────────────────────────────────────────────────────────────
# Each returns @{ Event; Reset; Primed; Status } and mutates its own $Eval bag.

<#
    process - aggregate by NAME, not PID. "running" is count(name) > 0 and
    "exited" is count(name) == 0, so multiple instances are treated collectively.

      all : every target must have been seen running SIMULTANEOUSLY at least once
            after arming, then fires when all reach zero. Arming with A up and B
            down, then B starts and A exits, must NOT fire - never up together.
      any : at least one target seen running, then fires when THAT target hits zero.

    Arming while nothing matches is valid and waits for a start; otherwise
    "shut down when ffmpeg exits" would fire 15 seconds after arming.
#>
function Test-TriggerProcess ($Config, $Eval, $Context) {
    $names = @((Get-TriggerConfigValue $Config 'Names' @()) | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() })
    if ($names.Count -eq 0) {
        return @{ Event = $false; Reset = $false; Primed = $false; Status = 'No process names configured' }
    }
    $mode = Get-TriggerConfigValue $Config 'Mode' 'all'

    if (-not $Eval.ContainsKey('Prev'))     { $Eval['Prev']     = @{} }
    if (-not $Eval.ContainsKey('Observed')) { $Eval['Observed'] = @{} }

    $counts = @{}
    foreach ($n in $names) { $counts[$n] = [int](& $Context.GetProcessCount $n) }
    foreach ($n in $names) { if ($counts[$n] -gt 0) { $Eval['Observed'][$n] = $true } }

    # 'all' additionally requires one tick where every target was up at once.
    if ($mode -eq 'all') {
        $allUpNow = $true
        foreach ($n in $names) { if ($counts[$n] -le 0) { $allUpNow = $false; break } }
        if ($allUpNow) { $Eval['SimultaneousSeen'] = $true }
    }

    $primed = if ($mode -eq 'all') {
        [bool]$Eval['SimultaneousSeen']
    } else {
        @($names | Where-Object { $Eval['Observed'][$_] }).Count -gt 0
    }

    # EVENT is an edge: something that WAS up is now down.
    $event = $false
    if ($primed) {
        if ($mode -eq 'all') {
            $allDown   = @($names | Where-Object { $counts[$_] -gt 0 }).Count -eq 0
            $anyPrevUp = @($names | Where-Object { [int]$Eval['Prev'][$_] -gt 0 }).Count -gt 0
            $event = $allDown -and $anyPrevUp
        } else {
            foreach ($n in $names) {
                if ($Eval['Observed'][$n] -and [int]$Eval['Prev'][$n] -gt 0 -and $counts[$n] -eq 0) {
                    $event = $true; break
                }
            }
        }
    }

    # RESET (I2): only a target that was at ZERO when cooldown began counts. A
    # second instance already running at cooldown entry is pre-existing state and
    # must not clear cooldown.
    $reset = $false
    if ($Eval.ContainsKey('CooldownZero')) {
        foreach ($n in $names) {
            if ($Eval['CooldownZero'][$n] -and $counts[$n] -gt 0) { $reset = $true; break }
        }
    }

    $running = @($names | Where-Object { $counts[$_] -gt 0 })
    $status = if ($running.Count -gt 0) { "waiting - running: $($running -join ', ')" }
              elseif ($primed)          { 'target process(es) have exited' }
              else                      { "waiting for $($names -join ', ') to start" }

    $Eval['Prev'] = $counts
    return @{ Event = $event; Reset = $reset; Primed = $primed; Status = $status }
}

<#
    downloads - baseline at arm, then activity, then settle.

    The baseline matters: a folder full of long-finished downloads is quiet the
    moment you arm, and without a baseline that reads as "a download just
    completed". Only files created, grown, or modified AFTER arming count.
#>
function Test-TriggerDownloads ($Config, $Eval, $Context) {
    $path      = [string](Get-TriggerConfigValue $Config 'Path' '')
    $recurse   = [bool](Get-TriggerConfigValue $Config 'Recurse' $false)
    $settleSec = [int](Get-TriggerConfigValue $Config 'SettleSec' 30)

    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return @{ Event = $false; Reset = $false; Primed = $false; Status = "Folder not found: $path" }
    }

    $files = @(Get-ChildItem -LiteralPath $path -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue)
    $snapshot = @{}
    foreach ($f in $files) { $snapshot[$f.FullName] = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" }

    # First evaluation establishes the baseline and claims no activity.
    if (-not $Eval.ContainsKey('Baseline')) {
        $Eval['Baseline']        = $snapshot
        $Eval['LastActivityTks'] = $null
        $Eval['ActivitySeen']    = $false
        return @{ Event = $false; Reset = $false; Primed = $false
                  Status = "baseline set - $($files.Count) existing file(s), waiting for activity" }
    }

    $partials = @($files | Where-Object {
        $script:PARTIAL_EXTENSIONS -contains [System.IO.Path]::GetExtension($_.Name).ToLowerInvariant()
    })

    # Activity = anything new, grown, or touched since the baseline. Files that
    # were already present and untouched do not qualify, so an unrelated editor
    # autosave elsewhere in the folder cannot hold the trigger open forever.
    $activity = $false
    foreach ($k in $snapshot.Keys) {
        if ($Eval['Baseline'][$k] -ne $snapshot[$k]) { $activity = $true; break }
    }
    if ($partials.Count -gt 0) { $activity = $true }

    if ($activity) {
        $Eval['LastActivityTks'] = $Context.NowTicks
        $Eval['ActivitySeen']    = $true
        $Eval['Baseline']        = $snapshot
        if ($Eval.ContainsKey('CooldownArmed')) { $Eval['CooldownActivity'] = $true }
    }

    $primed   = [bool]$Eval['ActivitySeen']
    $quietFor = if ($Eval['LastActivityTks']) { ($Context.NowTicks - $Eval['LastActivityTks']) / 1000 } else { 0 }
    $event    = $primed -and $partials.Count -eq 0 -and $quietFor -ge $settleSec
    $reset    = [bool]$Eval['CooldownActivity']

    $status = if ($partials.Count -gt 0) { "downloading - $($partials.Count) partial file(s)" }
              elseif (-not $primed)      { 'waiting for download activity' }
              else                       { "settling - quiet $([int]$quietFor)s of ${settleSec}s" }

    return @{ Event = $event; Reset = $reset; Primed = $primed; Status = $status }
}

<#
    signal - absent, then present, then consumed.

    Polling at 1 Hz: a flag that appears AND is deleted by the producer between
    ticks is invisible. The contract is that the producer writes the file and
    leaves it; this app deletes it. If deletion fails the event is NOT reported,
    because pretending it was consumed would retrigger every tick.
#>
function Test-TriggerSignal ($Config, $Eval, $Context) {
    $path = [string](Get-TriggerConfigValue $Config 'Path' '')
    if (-not $path) {
        return @{ Event = $false; Reset = $false; Primed = $false; Status = 'No signal path configured' }
    }

    $exists = Test-Path -LiteralPath $path
    if (-not $exists) { $Eval['SeenAbsent'] = $true }
    if ($exists -and $Context.Passive) {
        # Seen during ARMING: leave it in place so it is still there to fire on
        # once watching actually begins. Consuming it here would lose the signal.
        return @{ Event = $false; Reset = $false; Primed = [bool]$Eval['SeenAbsent']
                  Status = "signal already present - will act once armed" }
    }

    $primed = [bool]$Eval['SeenAbsent']
    $event  = $false
    $status = if ($exists) { "signal present: $path" } else { "waiting for $path" }

    if ($primed -and $exists -and -not $Context.Passive) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $event  = $true
            $status = 'signal received'
            $Eval['SeenAbsent']  = $false
            $Eval['DeleteError'] = $null
        } catch {
            $Eval['DeleteError'] = $_.Exception.Message
            $status = "signal present but could not be deleted: $($_.Exception.Message)"
        }
    }

    # Consuming the file already returned the world to its re-armable baseline,
    # and firing again requires a fresh absent->present edge.
    $reset = -not (Test-Path -LiteralPath $path)
    return @{ Event = $event; Reset = $reset; Primed = $primed; Status = $status }
}

<#
    resource - sustained quiet across the enabled metrics.

    A metric with no valid sample makes the whole condition unsatisfied. An
    unavailable CPU reading must never degrade to "0%, therefore idle" - that
    would fire on a busy machine.
#>
function Test-TriggerResource ($Config, $Eval, $Context) {
    $netOn      = [bool](Get-TriggerConfigValue $Config 'NetEnabled' $false)
    $cpuOn      = [bool](Get-TriggerConfigValue $Config 'CpuEnabled' $false)
    $sustainSec = [int](Get-TriggerConfigValue $Config 'SustainSec' 120)
    $match      = Get-TriggerConfigValue $Config 'Match' 'all'

    if (-not $netOn -and -not $cpuOn) {
        return @{ Event = $false; Reset = $false; Primed = $false; Status = 'No metric enabled' }
    }

    $results = @()
    $missing = @()
    if ($netOn) {
        if ($null -eq $Context.Kbps) { $missing += 'network' }
        else { $results += ([double]$Context.Kbps -lt [double](Get-TriggerConfigValue $Config 'NetKbps' 100)) }
    }
    if ($cpuOn) {
        if ($null -eq $Context.CpuPercent) { $missing += 'CPU' }
        else { $results += ([double]$Context.CpuPercent -lt [double](Get-TriggerConfigValue $Config 'CpuPercent' 10)) }
    }

    if ($missing.Count -gt 0) {
        return @{ Event = $false; Reset = $false; Primed = [bool]$Eval['SeenAbove']
                  Status = "waiting for a valid $($missing -join ' and ') sample" }
    }

    $below = if ($match -eq 'any') { $results -contains $true } else { -not ($results -contains $false) }

    if (-not $below) {
        $Eval['SeenAbove']  = $true
        $Eval['BelowSince'] = $null
        if ($Eval.ContainsKey('CooldownArmed')) { $Eval['CooldownAbove'] = $true }
    } elseif (-not $Eval['BelowSince']) {
        $Eval['BelowSince'] = $Context.NowTicks
    }

    $primed  = [bool]$Eval['SeenAbove']
    $heldFor = if ($Eval['BelowSince']) { ($Context.NowTicks - $Eval['BelowSince']) / 1000 } else { 0 }
    $event   = $primed -and $below -and $heldFor -ge $sustainSec
    $reset   = [bool]$Eval['CooldownAbove']

    $parts = @()
    if ($netOn) { $parts += "net $([math]::Round([double]$Context.Kbps,1))/$($Config.NetKbps) KB/s" }
    if ($cpuOn) { $parts += "cpu $($Context.CpuPercent)/$($Config.CpuPercent)%" }
    $status = if (-not $primed) { "waiting for activity first - $($parts -join ', ')" }
              elseif ($below)   { "quiet $([int]$heldFor)s of ${sustainSec}s - $($parts -join ', ')" }
              else              { "busy - $($parts -join ', ')" }

    return @{ Event = $event; Reset = $reset; Primed = $primed; Status = $status }
}

<#
    idle - the v1 behaviour, unchanged. PRIMED immediately so the engine has no
    hidden special path.
#>
function Test-TriggerIdle ($Config, $Eval, $Context) {
    $threshold = [int](Get-TriggerConfigValue $Config 'ThresholdSec' 1800)
    $idle = [double]$Context.IdleSec
    return @{
        Event  = ($idle -ge $threshold)
        Reset  = ($idle -lt $threshold)
        Primed = $true
        Status = "idle $([int]$idle)s of ${threshold}s"
    }
}

function Invoke-TriggerEvaluator ($Kind, $Config, $Eval, $Context) {
    switch ($Kind) {
        'process'   { return Test-TriggerProcess   $Config $Eval $Context }
        'downloads' { return Test-TriggerDownloads $Config $Eval $Context }
        'signal'    { return Test-TriggerSignal    $Config $Eval $Context }
        'resource'  { return Test-TriggerResource  $Config $Eval $Context }
        default     { return Test-TriggerIdle      $Config $Eval $Context }
    }
}

# ── Engine ────────────────────────────────────────────────────────────────────

<#
    Arms a trigger. Always a live user action (I5) - nothing here is reachable
    from state loaded off disk.
#>
function Start-Trigger ([string]$Kind, [string]$Action, $Config, $Context = $null) {
    if ($script:TRIGGER_KINDS -notcontains $Kind) { throw "Unknown trigger kind: $Kind" }
    if (-not $Context) { $Context = New-TriggerContext }

    $script:trigger = New-TriggerRecord
    $script:trigger.State        = 'ARMING'
    $script:trigger.Kind         = $Kind
    $script:trigger.Action       = $Action
    $script:trigger.Config       = $Config
    $script:trigger.ArmedAtTicks = $Context.NowTicks
    $script:trigger.Status       = 'arming...'

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log 'trigger' 'armed' "kind=$Kind action=$Action $(ConvertTo-TriggerSummary $Config)"
    }
    return $script:trigger
}

function Stop-Trigger ([string]$Reason = 'user') {
    if ($script:trigger.State -ne 'DISARMED' -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log 'trigger' 'disarmed' "reason=$Reason"
    }
    $script:trigger = New-TriggerRecord
}

function ConvertTo-TriggerSummary ($Config) {
    if (-not $Config) { return '' }
    return (($Config.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ')
}

<#
    Enters COOLDOWN, snapshotting whatever each evaluator needs to recognise a
    genuine RESET later (I2). Without the snapshot, "a target is running" would
    be trivially true for an unrelated instance and cooldown would clear at once.
#>
function Enter-TriggerCooldown ([string]$Reason, [int]$SnoozeSec = 0, $Context = $null) {
    if (-not $Context) { $Context = New-TriggerContext }
    $t = $script:trigger
    $t.State      = 'COOLDOWN'
    $t.LastReason = $Reason
    $t.SnoozeUntilTicks = if ($SnoozeSec -gt 0) { $Context.NowTicks + ($SnoozeSec * 1000) } else { 0 }

    switch ($t.Kind) {
        'process' {
            $zero = @{}
            foreach ($n in @(Get-TriggerConfigValue $t.Config 'Names' @())) {
                if ($n -and "$n".Trim()) {
                    $zero["$n".Trim()] = ([int](& $Context.GetProcessCount "$n".Trim()) -eq 0)
                }
            }
            $t.Eval['CooldownZero'] = $zero
        }
        'downloads' { $t.Eval['CooldownArmed'] = $true; $t.Eval['CooldownActivity'] = $false }
        'resource'  { $t.Eval['CooldownArmed'] = $true; $t.Eval['CooldownAbove']    = $false }
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log 'trigger' 'cooldown' "reason=$Reason snoozeSec=$SnoozeSec"
    }
}

function Clear-TriggerCooldownMarks {
    $t = $script:trigger
    foreach ($k in @('CooldownZero', 'CooldownArmed', 'CooldownActivity', 'CooldownAbove')) {
        if ($t.Eval.ContainsKey($k)) { $t.Eval.Remove($k) }
    }
    $t.SnoozeUntilTicks = 0
}

<#
    Advances the state machine by one tick. Returns:

        @{ Fire = $bool; Status = string; State = string; Reason = string }

    Fire is true for exactly one tick, when grace expires. The caller owns the
    action (I4) - this module never invokes one.
#>
function Update-Trigger ($Context = $null) {
    if (-not $Context) { $Context = New-TriggerContext }
    $t = $script:trigger
    $fire   = $false
    $reason = ''

    switch ($t.State) {

        'DISARMED' { }

        'ARMING' {
            # Evaluate so baselines are established, but ignore any EVENT: a
            # trigger must not fire in the seconds right after arming, when the
            # condition may already happen to be satisfied. Passive so the
            # evaluator cannot consume anything while doing it.
            $passiveCtx = $Context.Clone()
            $passiveCtx.Passive = $true
            $r = Invoke-TriggerEvaluator $t.Kind $t.Config $t.Eval $passiveCtx
            $t.Status = "arming - $($r.Status)"
            if ((($Context.NowTicks - $t.ArmedAtTicks) / 1000) -ge $script:MIN_ARM_SEC) {
                $t.State = if ($r.Primed) { 'PRIMED' } else { 'WATCHING' }
            }
        }

        'WATCHING' {
            $r = Invoke-TriggerEvaluator $t.Kind $t.Config $t.Eval $Context
            $t.Status = $r.Status
            if ($r.Primed) { $t.State = 'PRIMED' }
        }

        'PRIMED' {
            $r = Invoke-TriggerEvaluator $t.Kind $t.Config $t.Eval $Context
            $t.Status = $r.Status
            if (-not $r.Primed) { $t.State = 'WATCHING' }
            elseif ($r.Event) {
                $t.State           = 'GRACE'
                $t.GraceStartTicks = $Context.NowTicks
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log 'trigger' 'fired' "kind=$($t.Kind) status=$($r.Status)"
                }
            }
        }

        'GRACE' {
            $elapsed = ($Context.NowTicks - $t.GraceStartTicks) / 1000

            if ($Context.TickGapSec -ge $script:SUSPEND_GAP_SEC) {
                # The app did not run for a while - the machine slept or stalled.
                # Powering off seconds after a wake is hostile, and a grace that
                # "expired" while suspended never gave the user their 60 seconds.
                Enter-TriggerCooldown 'apparent suspend/stall' 0 $Context
                $reason   = 'apparent suspend/stall'
                $t.Status = 'grace aborted - machine slept'
            }
            elseif (($Context.IdleSec + $script:GRACE_ACTIVITY_TOLERANCE_SEC) -lt $elapsed) {
                # Idle should grow 1:1 with elapsed grace. If it has not, input
                # arrived DURING grace. Comparing raw idle against a threshold
                # would instead abort instantly whenever the user happened to be
                # at the machine when the trigger fired.
                Enter-TriggerCooldown 'user activity' 0 $Context
                $reason   = 'user activity'
                $t.Status = 'grace aborted - you are at the PC'
            }
            elseif ($elapsed -ge $script:GRACE_SEC) {
                $t.State  = 'EXECUTING'
                $t.Status = 'firing'
                $fire     = $true
            }
            else {
                $t.Status = "acting in $([int]($script:GRACE_SEC - $elapsed))s"
            }
        }

        'COOLDOWN' {
            $r = Invoke-TriggerEvaluator $t.Kind $t.Config $t.Eval $Context
            $snoozeLeft = if ($t.SnoozeUntilTicks -gt 0) {
                [math]::Max(0, ($t.SnoozeUntilTicks - $Context.NowTicks) / 1000)
            } else { 0 }

            # I3: both, never either.
            if ($r.Reset -and $snoozeLeft -le 0) {
                Clear-TriggerCooldownMarks
                $t.State  = if ($r.Primed) { 'PRIMED' } else { 'WATCHING' }
                $t.Status = $r.Status
            } elseif ($snoozeLeft -gt 0) {
                $t.Status = "snoozed $([int]$snoozeLeft)s - $($r.Status)"
            } else {
                $t.Status = "waiting to re-arm - $($r.Status)"
            }
        }

        'EXECUTING' { $t.Status = 'firing' }
    }

    return @{ Fire = $fire; Status = $t.Status; State = $t.State; Reason = $reason }
}

<#
    Cancel the pending action but keep the trigger armed. Per I1/I2 it cannot
    fire again until a genuine reset transition occurs.
#>
function Stop-TriggerGrace ([string]$Reason = 'cancelled', $Context = $null) {
    if ($script:trigger.State -ne 'GRACE') { return $false }
    Enter-TriggerCooldown $Reason 0 $Context
    return $true
}

<#
    Snooze: abandon this grace and refuse to re-arm for SnoozeSec, per I3 also
    requiring a genuine reset. Without the reset requirement, snoozing while the
    condition is still true just delays the same firing by 15 minutes.
#>
function Suspend-Trigger ([int]$SnoozeSec = 900, $Context = $null) {
    if ($script:trigger.State -ne 'GRACE') { return $false }
    Enter-TriggerCooldown 'snoozed' $SnoozeSec $Context
    return $true
}

function Complete-TriggerExecution {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log 'trigger' 'executed' "kind=$($script:trigger.Kind) action=$($script:trigger.Action)"
    }
    Stop-Trigger 'fired'
}
