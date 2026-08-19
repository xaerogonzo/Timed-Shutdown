# Architecture

Timed Shutdown is a PowerShell 5.1 + WPF desktop app. Source is split into
dot-sourced modules under `src\`; `build.ps1` bundles them into a single
`dist\TimedShutdown.ps1` for distribution. Both entry points execute identical
code — the bundler only inlines the dot-sources and embeds the XAML.

## Module map

```
src\Main.ps1               entry point: mutex, load order, admin gate, startup
                           recovery, Invoke-PowerAction, the dispatcher tick
src\Interop.ps1            Add-Type C#: WinApi (P/Invoke) + WindowHotkeyManager

src\Core\Log.ps1           rolling log under %LOCALAPPDATA%
src\Core\Time.ps1          ConvertTo-Seconds, Split-Duration, Format-*
src\Core\State.ps1         state file, schema version + migration, settings
src\Core\Scheduler.ps1     Task Scheduler: folder, pending tasks, user schedules
src\Core\Guards.ps1        network/CPU sampling, idle, guard predicates
src\Core\Triggers.ps1      the trigger state machine and five evaluators
src\Core\Power.ps1         keep-awake, legacy repair, the four timed actions

src\UI\Theme.ps1           runtime colour values + ConvertTo-Brush
src\UI\Xaml.ps1            Import-XamlDocument / New-XamlWindow
src\UI\MainWindow.xaml     main window markup
src\UI\MainWindow.ps1      control refs, display helpers, event wiring, settings
src\UI\ScheduleDialog.*    add-schedule dialog
src\UI\Tray.ps1            NotifyIcon, context menu, window lifecycle
```

`Core\` never references UI controls. Guard and trigger functions take
parameters or a `$Context`, and `UI\MainWindow.ps1` supplies them. That boundary
is what makes the core testable without a window.

## Load order

Fixed in `Main.ps1` rather than globbed, because it matters:

1. **`Interop.ps1` first** — every other module references types it defines with
   `Add-Type`.
2. **Admin gate** — needs `PresentationFramework` for the message box.
3. **The mutex** — before any state mutation (see below).
4. **`Log.ps1` early** — so a failure during startup has somewhere to go.
5. **`Core\` before `UI\`**, and **`MainWindow.ps1` before `Tray.ps1`** — sourcing
   `MainWindow.ps1` creates `$window`, which `Tray.ps1` attaches handlers to.

Dot-sourcing shares one scope, so `$script:` variables are visible to all modules.

---

## The trigger engine

**This is the conceptual centre of the project.** Everything else is plumbing
around it.

A polling loop that fires whenever a predicate is true is *not* a trigger engine.
Arm "when notepad exits", cancel the countdown, and notepad is still closed — so
a naive loop fires again on the very next tick, forever. **"The condition is
true" and "the event just happened" are different statements**, and for an app
whose purpose is a destructive action that difference is the whole design.

```
DISARMED ──arm──► ARMING ──(min arm time)──► WATCHING ──(primed)──► PRIMED
                                                 ▲                     │
                                                 │                (EVENT edge)
                                          (RESET transition             │
                                           AND snooze expired)          ▼
                                             COOLDOWN ◄──cancel/activity/snooze── GRACE
                                                                                   │
                                                                         (countdown ends)
                                                                                   ▼
                                                                        EXECUTING ──► DISARMED
```

### Invariants

Changes must not violate these. Each has a named regression test in
`tests\Triggers.Tests.ps1`.

> **I1** — An EVENT may cause at most one GRACE transition until a RESET occurs.
>
> **I2** — RESET is a transition observed *after* entering COOLDOWN that returns
> the trigger to a re-armable baseline. It is never satisfied merely because a
> pre-existing predicate is still true. COOLDOWN cannot clear from the same state
> that caused the EVENT.
>
> **I3** — Leaving COOLDOWN requires RESET **and** snooze expiry — both, never
> either.
>
> **I4** — Exactly one code path may start a power action (`Invoke-PowerAction`).
>
> **I5** — No trigger may fire from state loaded off disk. Arming is always a
> live user action.

I2 is what kills the retrigger loop. Concretely, `Enter-TriggerCooldown`
snapshots each evaluator's baseline, and `Reset` becomes true only on an observed
change from *that snapshot*. A second process instance still running when
cooldown began is pre-existing state and must not clear cooldown.

I3 matters because without it, pressing Snooze while the condition is still true
just delays the same firing by fifteen minutes.

### Evaluator contract

Each kind owns a mutable state bag — never one shared global, or switching kinds
or re-arming inherits stale timing.

```powershell
@{
    Event  = $bool    # a triggering EDGE just occurred
    Reset  = $bool    # post-COOLDOWN transition per I2
    Primed = $bool    # prerequisite observed; may now watch for the edge
    Status = 'string' # live UI text
}
```

| Kind | Primes when | EVENT when | RESET when |
|---|---|---|---|
| `process` | target observed running | observed-running targets reach zero (all / any) | a target goes 0 → ≥1 |
| `signal` | path observed absent | file appears **and deletion succeeds** | path present → absent |
| `downloads` | post-arm activity observed | no partials **and** no post-arm activity for N s | new post-arm activity |
| `resource` | a valid sample above threshold | below threshold sustained N s | a valid sample above threshold |
| `idle` | immediately on entering WATCHING | idle ≥ threshold | idle falls below threshold |

`process` aggregates **by name**: `running = count(name) > 0`. `all` additionally
requires every target to have been seen up *simultaneously*, so arming with A up
and B down, then B starting and A exiting, does not fire.

`downloads` snapshots `(name, size, mtime)` at arm. Only post-arm creations,
growth, or modifications count as activity — otherwise a folder of long-finished
downloads is quiet the moment you arm and reads as "a download just completed".

`signal` is polled once per tick, so a flag created *and deleted by the producer*
between ticks is invisible. The contract is that the producer writes and leaves
it; the app deletes it. A failed deletion is not reported as an event, because
pretending it was consumed would retrigger every tick.

`resource` is satisfied only when **every enabled metric has a valid sample** and
the AND/OR predicate holds. An unavailable CPU reading must never degrade to
"0 %, therefore idle".

### Timing

All durations use `Get-MonotonicMs`, never `Get-Date` — wall-clock deltas break
under NTP correction and DST. `Stopwatch`/QPC is also wrong *here*:
`GetLastInputInfo` reports `GetTickCount`, which does not advance during sleep,
and the grace abort compares idle growth against elapsed time. Mixing clock
families would make them disagree across suspend. `Get-Date` is for log
timestamps and display only.

`Get-MonotonicMs` wraps kernel32 `GetTickCount64`. It is deliberately **not**
`[Environment]::TickCount64`, which is .NET Core 3.0+ only: on .NET Framework
4.x — what Windows PowerShell 5.1 runs on — that expression evaluates to nothing
rather than erroring, making every elapsed calculation silently zero. That
shipped once and left triggers stuck in ARMING forever. `[Environment]::TickCount`
does exist but is `Int32` and wraps after ~49 days, which would make a delta
hugely negative.

Because every evaluator test injects `NowTicks`, none of them could have caught
it. `tests\Triggers.Tests.ps1` therefore keeps a small set that exercises the
*default* context and asserts the clock genuinely advances — the general lesson
being that a seam over a platform API needs one test that does not use the seam.

```powershell
$script:MIN_ARM_SEC                  = 15
$script:GRACE_SEC                    = 60
$script:GRACE_ACTIVITY_TOLERANCE_SEC = 1.5
$script:SUSPEND_GAP_SEC              = 5
```

**Abort-on-activity.** The naive check — "is idle time low?" — is wrong: for a
`process` trigger the user is often sitting right there when the render finishes,
so it would abort instantly every time. What matters is whether input arrived
*after* grace began, which falls out of the arithmetic: idle should grow 1:1 with
elapsed grace, and if it has not, something was pressed.

**Suspend.** A tick gap of `SUSPEND_GAP_SEC` or more means the machine slept or
the app stalled: abort the grace. Powering off seconds after a wake is hostile,
and a grace that "expired" while suspended never gave the user their 60 seconds.
The two abort reasons are logged distinctly — `user activity` vs
`apparent suspend/stall`.

---

## Action ownership

WPF's dispatcher is single-threaded, so a tick cannot preempt a click handler
mid-statement — but blocking calls that pump messages (`MessageBox`, `ShowDialog`,
invoking `shutdown.exe`) do allow re-entrancy, and ticks queue behind them.

Per **I4**, every path funnels through `Invoke-PowerAction`, guarded by
`$script:actionInProgress`. If a timer and a trigger come due on the same tick
the **timer wins** — it is the explicit user instruction — and the trigger
returns to COOLDOWN logging that it was superseded.

Editing a trigger while armed is not supported: disarm first, so the trigger that
is running is always the one you configured.

---

## Encoding: UTF-8 with BOM, non-negotiable

Every `.ps1` and `.xaml` file must carry a UTF-8 BOM. `powershell.exe` 5.1
decodes a BOM-less file as Windows-1252, so `·` (U+00B7, bytes `C2 B7`) renders
as `Â·` — and mangled characters inside string literals can cascade into parse
errors. `build.ps1` refuses to bundle a source file without one, writes the
output with one, and verifies it landed. `build.ps1 -FixEncoding` repairs them.

## XAML loading

`Import-XamlDocument` checks `$script:XamlCache` before the filesystem. Running
from `src\` the cache is empty, so markup is read from `src\UI\*.xaml`. The
bundler replaces the empty `$script:XamlCache = @{}` declaration with one
pre-filled from the same files, making `dist\` self-contained.

The `TabControl` template's `ContentPresenter` **must** keep the name
`PART_SelectedContentHost`. `TabControl` looks it up to find its selected-content
host, and `TabItemAutomationPeer` reaches tab content through it. Unnamed, every
control inside every tab vanishes from the UI Automation tree — invisible to
screen readers and untestable.

## State

`%LOCALAPPDATA%\TimedShutdown\state.json`, migrated from the old
`%TEMP%\TimedShutdown_state.json` on first run (`%TEMP%` could be cleaned,
destroying the only record of the user's original power settings).

```jsonc
{
  "stateSchemaVersion": 2,
  "settings":      { /* UI preferences only */ },
  "trigger":       { "kind": "process", "action": "sleep", "config": {}, "armed": true },
  "pendingAction": { "type": "shutdown", "targetAt": "...", "method": "os-timer" }
}
```

Runtime timing — grace/cooldown deadlines, priming flags, last samples — is
deliberately **not** persisted. Those are `TickCount64` values that mean nothing
after a reboot, and a persisted `primed` flag could resurrect an armed
destructive action (**I5**).

`pendingAction` *is* persisted, and that is deliberate too: it mirrors state that
lives **outside** the app — a real `shutdown /s /t N` timer held by Windows, or a
registered scheduled task. Both keep running when the app closes, so without it
the app reopens unable to see or cancel something it started.

> `pendingAction` is a mirror, never a source of truth for *firing*. The app
> displays and cancels from it; it never initiates an action from it.
> `Get-TrackedAction` clears it once `targetAt` has passed.

Migration keys on `stateSchemaVersion`, never structural sniffing. Absent or the
legacy `version: '1.0'` means v1. A v1 armed idle watch migrates to a v2 `idle`
trigger that is **disarmed** — a migration must never create an armed destructive
action on a machine whose owner has not re-consented. A file from a *future*
schema is preserved to `state.json.v<N>.bak` and replaced with clean defaults;
reinterpreting it would mean guessing at fields written by a build that does not
exist yet.

## Keeping the machine awake

`Enable-KeepAwake` calls `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`
from the WPF UI thread — the request is per-thread, and that is the thread which
lives for the life of the app. Windows releases it on process exit, so no global
state can be stranded. It suppresses only *idle* sleep.

Builds before v2.0 set the global power plan's timeouts to 0 and only restored
them from `Stop-TimedAction`, so a timer that actually fired left sleep
permanently disabled. `Repair-LegacyPowerSuppression` runs once at startup to
undo that; if all four recorded values are `0` it leaves the plan alone, since
that pattern also means the old build's English-only `powercfg` parse failed.

## The dispatcher tick

One `DispatcherTimer` at 1 Hz drives the countdown, notification, guards, trigger
evaluation, and tray tooltip. It must stay cheap:

- `Get-TrackedAction` reads only the state file, cached on write timestamp. The
  pre-v2.0 code ran `Get-ScheduledTask` — a CIM query — once per second.
- CPU comes from `GetSystemTimes` (~1.7 ms). `Get-Counter` uses localized counter
  names and breaks on non-English Windows; the WMI perf class measured ~290 ms
  steady-state and 7 s cold, a third of the tick budget for one reading.
- Task enumeration happens on demand: startup, Scheduled-tab activation, and
  after add/remove.

## Testing

`tests\` covers the pure logic with Pester 5+. Trigger evaluators take an
injected `$Context`, so no test depends on real machine load, real processes, or
real elapsed time.

Task Scheduler, `powercfg`, `shutdown.exe`, and live WPF rendering are
side-effecting and verified by hand — use short timers and cancel before they
fire. `Set-StateFilePath` redirects the store (and the legacy path) into a temp
directory so a run cannot touch a live install.
