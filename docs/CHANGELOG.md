# Changelog

## v2.2 - 2026-08-18

Event triggers, and the repository prepared for publication.

### Added

**Triggers tab.** Acts when something happens rather than when a clock runs out:
a process exits, downloads finish, a signal file appears, network/CPU go quiet,
or the PC goes idle. Replaces the Idle tab — "wait for idle" is one kind of
trigger, and two tabs both meaning "watch a condition then fire" would be
incoherent. The idle evaluator is the v1 logic, unchanged.

The engine is a real state machine, not five boolean predicates, because a
polling loop that fires whenever a predicate is true is unusable for a
destructive action: arm "when notepad exits", cancel the countdown, and notepad
is still closed — so it fires again on the next tick, forever. Five invariants
(I1–I5, documented in `docs/ARCHITECTURE.md` with named regression tests)
separate "the condition is true" from "the event just happened":

- Each trigger must be **primed** by observing its prerequisite before it can
  fire. Arming "when ffmpeg exits" while ffmpeg is not running waits for it to
  start rather than firing 15 seconds later.
- Cancelling a countdown enters **COOLDOWN**, which only clears on a genuine
  reset *transition* — never because a pre-existing condition is still true. A
  second process instance already running when cooldown began does not count.
- **Snooze requires both** the reset and the snooze expiry, or it would just
  delay the same firing by fifteen minutes.

**A 60-second grace countdown that aborts on user activity.** The obvious check —
"is idle time low?" — is wrong: for a process trigger the user is usually sitting
right there when the render finishes, so it would abort every time. What matters
is whether input arrived *after* the countdown began, which falls out of
comparing idle growth against elapsed time. A tick gap of 5 s or more (the
machine slept, or the app stalled) also aborts: powering off seconds after a wake
is hostile, and a grace that "expired" while suspended never gave the user their
60 seconds.

**`tools/TimedShutdown-signal.cmd`** — writes a flag file that a signal trigger
consumes, so any tool that can run a command can trigger a shutdown. README
carries a Claude Code `Stop`-hook recipe that appends to the existing hooks array
rather than replacing it.

**Rolling log** at `%LOCALAPPDATA%\TimedShutdown\log.txt`, capped at 256 KB with
one rollover, recording every arm, fire, cancel, abort and error with a reason.
The v2.1 scheduled-task bug failed silently; this is what would have surfaced it.
Reachable from the tray menu.

**Single-instance guard** via a named mutex, released in a `finally`. Two copies
previously both ticked and fought over `state.json`. The second instance tries to
focus the first and exits regardless — Windows does not guarantee
`SetForegroundWindow` succeeds, and that must never block the exit.

**Settings persistence.** Notify minutes, guard thresholds, process name, and the
whole trigger configuration survive a restart. Runtime timing deliberately does
not: those are monotonic tick values meaningless after a reboot, and a persisted
"primed" flag could resurrect an armed destructive action.

**Publishing:** MIT `LICENSE`, `.gitignore` (`.claude/` carried two absolute local
paths), GitHub Actions CI on `windows-latest`, and a version string in the header,
tray tooltip and log. A third-party audit found no bundled fonts, DLLs, icons, or
vendored source; the only binary asset was an orphaned `Monitor.jpg`, removed.

### Fixed

**`Get-Counter` would have been a locale bug.** CPU sampling uses
`GetSystemTimes` instead: `Get-Counter` relies on localized counter names — the
same failure class as the `powercfg` regex fixed in v2.0 — and the WMI
performance class measured ~290 ms steady-state and 7 s cold, a third of the
1 Hz tick budget for one reading. `GetSystemTimes` costs ~1.7 ms and agreed
within 1 %.

**A configured `0` was silently treated as absent.** `if ($Config.SustainSec)`
is false for zero, so "fire as soon as it goes quiet" quietly became a
two-minute wait. Config access now distinguishes absent from zero, and handles
both hashtables and the `PSCustomObject` shape that comes back out of
`state.json`.

**`$Event` used as a parameter name** in the new logging functions — a reserved
automatic variable, exactly the class of bug that broke Sleep and Hibernate in
v2.1. Caught by the AST test added in that release.

**`[Environment]::TickCount64` does not exist on PowerShell 5.1.** It is .NET
Core 3.0+; 5.1 runs on .NET Framework 4.x, where it evaluates to nothing rather
than erroring. Every elapsed-time calculation was therefore zero and a trigger
sat in ARMING forever, never reaching WATCHING. Replaced with kernel32
`GetTickCount64` behind `Get-MonotonicMs`. The unit suite could not have caught
it — every test injects the clock — so there is now a test that exercises the
default path and asserts the value actually advances.

**A signal file arriving during the arm window was eaten.** ARMING evaluates so
baselines get established, but the signal evaluator *deletes* the flag it finds.
A flag written inside the 15-second arm window was consumed and the event lost,
leaving the trigger waiting forever for something already thrown away.
Evaluation during ARMING is now passive.

### Changed

- State schema v2 with migration keyed on `stateSchemaVersion`, not structural
  sniffing. A v1 armed idle watch migrates to a **disarmed** idle trigger: a
  migration must never create an armed destructive action on a machine whose
  owner has not re-consented. A file from a future schema is preserved to
  `state.json.v<N>.bak` and replaced with clean defaults.
- All power actions funnel through a single `Invoke-PowerAction` chokepoint. WPF's
  dispatcher is single-threaded, but `MessageBox`, `ShowDialog` and invoking
  `shutdown.exe` pump messages, so ticks can re-enter. If a timer and a trigger
  come due together the timer wins — it is the explicit user instruction.
- `Core/IdleWatch.ps1` retired; `Get-IdleSeconds` moved to `Core/Guards.ps1`.

135 tests, all passing.

## v2.1 - 2026-08-18

Fixes for two problems reported against v2.0.

### Fixed

**Sleep and Hibernate timers never worked.** Two independent faults, stacked.

The first was visible: `New-PendingTask` declared its argument-string parameter
as `[string]$Args`. `$Args` is a PowerShell automatic variable holding the
function's own argument array, so the caller's value never arrived -- the
parameter was always empty. `New-ScheduledTaskAction` then rejected
`-Argument ''` and the timer failed with *"Cannot validate argument on parameter
'Argument'. The argument is null or empty."* Renamed to `$Arguments`. Shutdown
and Restart were unaffected because they call `shutdown.exe` directly instead of
going through a scheduled task.

Fixing that exposed the second, which was silent and worse. The settings used
`-DeleteExpiredTaskAfter` so the one-shot task would clean itself up, but Task
Scheduler only accepts that when the trigger declares when it expires; without an
`EndBoundary` it rejected the registration with *"The task XML is missing a
required element or attribute ... EndBoundary"*. Because
`Register-ScheduledTask` reports failure as a **non-terminating** error and the
call ended in `| Out-Null` with no `-ErrorAction Stop`, the rejection was
discarded. The app wrote its pending state and counted down a Sleep or Hibernate
timer that had no task behind it and could never fire. The trigger now sets an
`EndBoundary`, and every `Register-ScheduledTask` call uses `-ErrorAction Stop`
so a failure surfaces in the UI instead of vanishing.

**Turn Off Monitor and Lock Screen were unreachable while a timer ran.**
ACTIVE TIMER and QUICK ACTIONS shared one `StackPanel`, which neither clips nor
scrolls. When the active-timer panel appeared it pushed both buttons past the
bottom of a window that was fixed-size and `ResizeMode="CanMinimize"` -- so they
could not be scrolled to, resized to, or reached at all, precisely when a
shutdown was pending and Turn Off Monitor was most wanted. Measurement showed the
layout had about 2px of slack even before the guard banner, so window chrome or
DPI rounding was enough to lose them.

Quick Actions now sit in their own `Auto` row outside a `ScrollViewer`, so they
are pinned to the bottom and the active-timer section scrolls instead. The window
is also resizable (`MinHeight` 700) as a second safety valve.

### Added

- `tests/Source.Tests.ps1` -- static checks: no function parameter may shadow a
  PowerShell automatic variable, `New-PendingTask` must pass a non-empty argument
  string, the one-shot trigger must carry an `EndBoundary`, and every
  `Register-ScheduledTask` call must use `-ErrorAction Stop`. Source-encoding
  checks moved here from `Ui.Tests.ps1`.
- `tests/Ui.Tests.ps1` -- the quick-action buttons must stay within the client
  area at several window heights with a timer running and a guard banner shown.

81 tests, all passing.

## v2.0 — 2026-08-13

Restructure of the single 1776-line `TimedShutdown.ps1` into `src\` modules, plus
repairs to every defect found while doing it. The pre-restructure file was kept
alongside the source through v2.2 and then removed — git history covers it from
the first commit onwards.

### Fixed

**Every `h`/`m`/`s` time format was rejected.** `ConvertTo-Seconds` validated its
input with `... -and ($t -match '[hms]')`. That second `-match` reassigns the
automatic `$Matches` variable, wiping capture groups 1–3, so the accumulator
stayed at 0 and the function returned `$null`. `1h30m`, `45m`, `2h`, and `90s` —
the formats the placeholder, error message, and README all advertise — never
worked; only a bare minute count and `HH:mm` did. The unit check is now a
lookahead inside the same regex.

**Durations over 30 minutes gained a phantom hour.** `$h = [int]$ts.TotalHours`
rounds rather than truncates, and PowerShell's `[int]` cast rounds half to even,
while `$ts.Minutes` is exact. 31 minutes became `H=1, M=31` → "1 hour 31
minutes"; 90 minutes became "2 hours 30 minutes". 30 minutes was right only by
accident, because 0.5 rounds down to 0 — which is why the bug looked like it
started at 31. Hours now come from `[math]::Floor` via a single shared
`Split-Duration`, used by all three formatters.

**Sleep was left permanently disabled after a timer fired.** The app set the
global power plan's standby and hibernate timeouts to "never" and only restored
them from `Stop-TimedAction` — reachable solely by pressing Cancel. A timer that
actually fired powered the machine off with the plan still modified, and nothing
on next launch put it back, despite the README describing exactly such a
recovery. Replaced with `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`,
which touches no global setting and is released by Windows on process exit.
`Repair-LegacyPowerSuppression` restores plans already modified by the old build,
once, at startup.

**`Â·` and other garbled characters throughout the UI.** The script was UTF-8
without a BOM; `powershell.exe` 5.1 decodes BOM-less files as Windows-1252, so
`·` (`C2 B7`) rendered as `Â·`. All sources now carry a BOM, `build.ps1` refuses
to bundle a file without one and verifies the output has one, and
`build.ps1 -FixEncoding` repairs offenders.

**Tab labels lost their last character** — "Timers" rendered as "Timer", "Idle"
as "Idl", "Scheduled" as "Schedule". `TabPanel` sizes each tab from its
normal-weight header, but the `IsSelected` trigger switches it to SemiBold, which
measures ~1.7 px wider at 14 px Segoe UI. Padding gained 4 px and margin lost 4,
so each tab's total footprint is unchanged while the text always fits.

**A CIM query every second.** The 1 Hz dispatcher tick called `Get-PendingState`,
which ran `Get-ScheduledTask` alongside the state read. Split into a cheap
`Get-TrackedAction` (state file only, cached on write timestamp) for the tick,
with task enumeration moved to startup, Scheduled-tab activation, and add/remove.

**`once` schedules for a time already past never fired.** The time was anchored
to today with no rollover. Now rolls to tomorrow, matching the timer box.

**Overflow crash from the preview box.** A long digit string hit `[int]$t`, which
throws, from inside the `TextChanged` handler. Parsing uses `[long]::TryParse`
with a 30-day cap and returns `$null` instead.

**Tray icon handle leak.** `[Icon]::FromHandle($h).Dispose()` disposed a fresh
managed wrapper and left the underlying `HICON` allocated. Now calls `DestroyIcon`.

**Guard churn.** While a guard was blocking, every tick ran `shutdown /a` followed
by `shutdown /s /t N` — re-arming the OS timer once per second and pushing the
target out 30 s each time. Now engages inside 15 s and extends by 60 s, so at
most one re-arm per minute.

**Every tab's contents were invisible to screen readers.** The custom
`TabControl` template's `ContentPresenter` was unnamed. `TabControl` resolves its
selected-content host by looking up the template child literally named
`PART_SelectedContentHost`, and `TabItemAutomationPeer` reaches the tab's content
through it — so without the name, the entire UI Automation tree consisted of the
title, three tab headers, and nothing else. Assistive technology could not reach
a single control, and neither could UI testing. Found while driving the running
app: the automation tree had 6 nodes total. Named, it exposes 36 under the
selected tab.

**`build.ps1` never worked.** It was an unmodified Nuitka *Python* template —
`--enable-plugin=tk-inter`, `--include-package=PIL`, and `[ENTRY_SCRIPT]` /
`[OUTPUT_NAME]` placeholders — for a PowerShell/WPF project. Replaced with a
bundler that inlines the `src\` dot-sources, embeds the XAML, syntax-checks the
result, and writes UTF-8 with BOM.

### Changed

- State moved to `%LOCALAPPDATA%\TimedShutdown\state.json` (migrated from
  `%TEMP%`, where a disk cleanup could destroy the recorded power settings).
- Timers capped at 30 days.
- Notification rounding uses `Ceiling`, so "in ~1 min" no longer appears with
  90 seconds left.
- "Sleep suppressed" indicator relabelled "Keeping PC awake" to match what the
  app now does.
- `TimedShutdown.bat` runs `dist\TimedShutdown.ps1`, falling back to
  `src\Main.ps1`.
- `Monitor.jpg` moved to `docs\assets\`.

### Added

- `tests\` — Pester 5 suite over `Core\Time.ps1` and `Core\State.ps1`, including
  a regression case for each display bug above. `tests\Invoke-Tests.ps1` checks
  the Pester version and prints the install command rather than failing obscurely.
- `docs\ARCHITECTURE.md` — module map, load order, state schema, tick budget.

### Verification

Automated: 72 Pester tests (Pester 6.1.0, Windows PowerShell 5.1, STA) covering
parsing, duration splitting, the three formatters, state round-trip/caching/
migration, XAML load, control-reference agreement, tab metrics, and source
encoding. All pass.

Manual, still required after any change to the side-effecting paths:

1. `31` in the timer box reads "in 31 minutes"; `90` reads "in 1 hour 30 minutes";
   `1h30m`, `45m`, `2h`, `90s` are all accepted.
2. The separator renders as `·`, and the tab strip reads Timers / Idle / Scheduled
   with no clipped characters.
3. `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` is unchanged across a
   full timer cycle, and `powercfg /requests` shows a SYSTEM request while a timer
   is pending.
4. A `once` schedule set for a time already past today resolves to tomorrow.
5. A 2-minute shutdown counts down, snoozes, and cancels correctly.
