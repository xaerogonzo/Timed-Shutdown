# Timed Shutdown — Basic Instructions

---

## Project Overview

**Name:** Timed Shutdown
**Stack:** Windows PowerShell 5.1, WPF (XAML via `XamlReader`), Windows Forms
(`NotifyIcon` only), inline C# through `Add-Type` for P/Invoke. No external
packages; Pester 5 for tests.
**Entry point:** `TimedShutdown.bat` → `dist\TimedShutdown.ps1`, falling back to
`src\Main.ps1`.
**Purpose:** A tray utility for scheduling shutdown / restart / sleep /
hibernate, with live countdowns, an idle watch, recurring schedules, and guards
that hold the action back while the machine is still busy.

---

## Project Structure

```
TimedShutdown.bat     launcher (auto-elevates via UAC)
build.ps1 / build.bat bundles src\ -> dist\TimedShutdown.ps1
src\                  source modules (Main, Interop, Core\, UI\)
dist\                 generated single-file build - DO NOT EDIT
tests\                Pester 5 suite over the pure-logic modules
docs\                 ARCHITECTURE.md, CHANGELOG.md
```

`src\Core\` holds logic with no UI dependency; `src\UI\` holds the window,
dialog, tray, and their markup. See `docs\ARCHITECTURE.md` for the module map.

---

## Documentation Files

| File | Location | Purpose |
|---|---|---|
| README | `README.md` | User-facing: install, features, troubleshooting |
| Architecture | `docs\ARCHITECTURE.md` | Module map, load order, state schema, tick budget |
| Changelog | `docs\CHANGELOG.md` | Release history with the defect record |
| These instructions | `BASIC_INSTRUCTIONS.md` | Working agreements for this project |

---

## Architecture

- **Layers:** `Main.ps1` fixes the dot-source order, then `Interop` → `Core\` →
  `UI\`. Dot-sourcing shares a single scope, so `$script:` variables are common
  to all modules.
- **Data flow:** UI events call `Core\` functions, which mutate
  `%LOCALAPPDATA%\TimedShutdown\state.json` and issue `shutdown.exe` or Task
  Scheduler calls. A 1 Hz `DispatcherTimer` reads state back and refreshes the
  display.
- **Two timer mechanisms:** shutdown/restart use the OS timer (`shutdown /t`) and
  survive the app closing; sleep/hibernate use one-shot scheduled tasks.

---

## Key Files

| File | Role |
|---|---|
| `src\Main.ps1` | Load order, admin gate, startup recovery, dispatcher tick |
| `src\Interop.ps1` | `Add-Type` C#: `WinApi` P/Invoke and `WindowHotkeyManager` |
| `src\Core\Time.ps1` | All parsing/formatting; where both display bugs lived |
| `src\Core\Power.ps1` | Keep-awake, the four timed actions, legacy repair |
| `src\UI\MainWindow.ps1` | Control references and every event handler |
| `build.ps1` | Bundler; also the BOM gate |

---

## Project-Specific Rules

**Source files must be UTF-8 with BOM.** PowerShell 5.1 decodes a BOM-less
script as Windows-1252, which turns `·` into `Â·` and can cascade into parse
errors when mangled bytes land inside string literals. This was a real shipped
bug. `build.ps1` refuses to bundle a file without a BOM; `build.ps1 -FixEncoding`
repairs them. Most editors — and most tooling — default to writing no BOM, so
re-check after any edit.

**Never edit `dist\`.** It is generated. Change `src\` and re-run `build.ps1`.

**Never use `[int]` to truncate.** PowerShell's `[int]` cast rounds, half to
even. Use `[math]::Floor`. This is what produced "1 hour 31 minutes" for a
31-minute timer.

**Beware `$Matches` clobbering.** `$Matches` is overwritten by *every* `-match`.
Do not chain a second `-match` in a condition that reads capture groups from the
first — it silently empties them. This is what made `1h30m` unparseable.

**Keep the dispatcher tick cheap.** It runs once a second for the life of the
app. No CIM queries (`Get-ScheduledTask`), no unbounded file reads. Task
enumeration is on-demand only.

**Do not reintroduce global power-plan edits.** Keeping the machine awake is done
with `SetThreadExecutionState` from the UI thread, which Windows releases on
process exit. The previous `powercfg` approach left users' sleep settings
permanently disabled whenever a timer actually fired.

**Testing boundary.** `Core\Time.ps1` and `Core\State.ps1` are pure and unit
tested. Task Scheduler, `powercfg`, `shutdown.exe`, and WPF rendering are
side-effecting and verified by hand — use short timers (2 min) and cancel before
they fire. Tests must redirect the state path via `Set-StateFilePath` (including
the legacy path) so they cannot touch a live install.

**Never name a Pester `-TestCases` key `Input`.** `$Input` is PowerShell's
automatic pipeline enumerator, so the case binds as an empty array instead of
your value. This is quietly dangerous: a "rejects invalid input" case still
*passes*, because the function under test correctly rejects `@()`. Use `Text`.

**`BeforeEach`/`AfterEach` must sit inside a `Describe`.** Pester 6 rejects test
setup declared in a file's root block, and the whole file fails to load.

**Run the suite with `powershell -STA`.** The markup tests instantiate WPF
objects, which need a single-threaded apartment. `pwsh` is MTA;
`tests\Invoke-Tests.ps1` checks and tells you.

**Check module availability with 5.1, not `pwsh`.** They read different
`PSModulePath`s — `pwsh` does not include `Documents\WindowsPowerShell\Modules`
— so a module the tests can see looks absent from `pwsh`, and one installed from
`pwsh` lands where 5.1 will not find it. Always verify with
`powershell -NoProfile -Command "Get-Module -ListAvailable <name>"`.

**Keep `PART_SelectedContentHost` on the TabControl template's ContentPresenter.**
The name is load-bearing, not decorative: `TabControl` looks it up to find its
selected-content host, and `TabItemAutomationPeer` reaches tab content through
it. Remove it and every control inside every tab vanishes from the UI Automation
tree — invisible to screen readers and untestable. `tests\Ui.Tests.ps1` guards
this. The same applies to any other `PART_*` name in a rewritten template.

**Never name a parameter after a PowerShell automatic variable.** `$Args`,
`$Input`, `$Error`, `$Host`, `$Matches`, `$This`, `$Event`, `$Switch` and friends
are already bound, so the caller's value never arrives and the parameter is
silently empty — no error at the call site. A `[string]$Args` parameter is what
broke every Sleep and Hibernate timer. `tests\Source.Tests.ps1` checks this
across the whole tree with the AST.

**Do not assign to one either.** The parameter rule was enforced; the assignment
form was not, so seven `$event = ...` locals sat in the trigger engine until
PSScriptAnalyzer pointed at them. A local named `$event` is harmless in an
ordinary function and stops being harmless the moment that code is lifted into a
`Register-ObjectEvent -Action` scriptblock, where PowerShell binds `$Event`
itself. Both forms are now AST-checked, scope prefixes stripped, so
`$script:event` is caught as well.

**A `try/catch` does not catch a non-terminating error.** This is the single
most productive bug family in this codebase, and it is not limited to Task
Scheduler. `Register-ScheduledTask` reports rejection as a non-terminating
error, so `| Out-Null` without `-ErrorAction Stop` throws the failure away and
the surrounding `try/catch` never fires — the app counts down a timer with no
task behind it. `New-Item` does the same for a bad path, which meant
`Write-Log`'s catch was decorative and an unwritable log emitted an error record
on every dispatcher tick. Any cmdlet inside a `try` that you rely on the `catch`
for needs `-ErrorAction Stop`. Relatedly, `-DeleteExpiredTaskAfter` is only
accepted when the trigger sets an `EndBoundary`.

**Never report success for something that failed.** `-ErrorAction
SilentlyContinue` on a cancel made "the task was removed" and "removing it
failed" indistinguishable, so the UI said the timer was cancelled and the
scheduled sleep fired anyway. "Cancelled" is a claim the user acts on by walking
away from the machine. Where an operation can partly fail, decide what the world
should look like afterwards and test *that*, not the return value —
`Add-SnoozeTime` aborts the old timer before arming the new one, so a failed
re-arm has already destroyed what it was extending, and the only honest end
state is "nothing pending".

**Escape sequences only work in double-quoted strings.** `'{0}`t{1}'` writes a
literal backtick and a `t`; `"{0}`t{1}"` writes a tab. Every log line the app
ever produced was affected, and the doc comment directly above the bug promised
tab-separated fields.

**External commands in `Core\Power.ps1` go through the seams.** `shutdown.exe`,
`powercfg` and task removal are reached via `$script:InvokeShutdownExe` and
friends, swapped in tests by `Set-PowerCommandSeam`. They return
`@{ ExitCode; Output }` rather than leaving callers to read `$LASTEXITCODE`: a
fake cannot set `$LASTEXITCODE`, so a test written against the ambient form
silently reads whatever the last real command left behind. You cannot make a real
`shutdown.exe` fail on demand, and the failure paths are the ones worth testing.

**Keep Quick Actions outside the scrolling region.** ACTIVE TIMER and QUICK
ACTIONS once shared a `StackPanel`, which neither clips nor scrolls; the growing
timer panel pushed "Turn Off Monitor" and "Lock Screen" off a non-resizable
window. Quick Actions belong in their own `Auto` row below the `ScrollViewer`.

**Watch case-insensitive variable collisions.** `$W = 490` overwrites a `$w`
holding a Window. PowerShell does not distinguish them.

**Never break a trigger invariant.** I1–I5 are stated in `docs\ARCHITECTURE.md`
and each has a named regression test. The one that matters most: "the condition
is true" is not "the event just happened". A trigger that fires whenever its
predicate holds will refire forever the moment a user cancels the countdown.

**`if ($Config.Thing)` treats a configured 0 as absent.** Use
`Get-TriggerConfigValue`, which distinguishes absent from zero and handles both
hashtables and the `PSCustomObject` shape that comes back out of `state.json`.
A sustain of `0` means "immediately", not "use the default".

**Measure elapsed time with `Get-MonotonicMs`** (kernel32 `GetTickCount64` via
`Interop.ps1`). Not `Get-Date` (NTP and DST move it), not `Stopwatch`/QPC —
`GetLastInputInfo` reports `GetTickCount`, which does not advance during sleep,
and the grace abort compares idle growth against elapsed time, so mixing clock
families makes them disagree across suspend. `Get-Date` is for log timestamps only.

**`[Environment]::TickCount64` does not exist on this runtime.** It is .NET Core
3.0+; Windows PowerShell 5.1 runs on .NET Framework 4.x, where the expression
evaluates to *nothing* rather than erroring — so every elapsed calculation
silently became zero and a trigger sat in ARMING forever. Before using any .NET
API, check it exists on .NET Framework 4.x. And note the unit tests could not
catch this because they inject the clock: when you wrap a platform API behind a
seam, keep one test that exercises the real thing.

**Never persist runtime trigger state.** Grace and cooldown deadlines, priming
flags and last samples stay in memory. `TickCount64` values are meaningless after
a reboot, and a persisted "primed" flag could resurrect an armed destructive
action on launch (I5). `pendingAction` is the deliberate exception: it mirrors a
real OS timer or scheduled task that outlives the process, and is a mirror only —
the app never *initiates* an action from it.

**Window.Title must stay exactly `Timed Shutdown`.** The single-instance guard
finds the existing window by that title. The version belongs in the header
TextBlock, the tray tooltip and the log — never in the title.
