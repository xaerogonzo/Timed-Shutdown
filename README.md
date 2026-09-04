# Timed Shutdown

[![tests](https://github.com/xaerogonzo/Timed-Shutdown/actions/workflows/tests.yml/badge.svg)](https://github.com/xaerogonzo/Timed-Shutdown/actions/workflows/tests.yml)

A dark-themed WPF utility for Windows that makes timed shutdowns, restarts, sleeps, and hibernations more convenient than raw `shutdown` commands. Set timers in plain English, watch live countdowns, guard against accidental shutdowns, and let the app run quietly in the system tray.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 (included with Windows)
- Administrator privileges (required for Task Scheduler entries)

---

## Installation

No installer needed. Keep the project folder together and double-click **`TimedShutdown.bat`**. It auto-elevates via UAC.

```
TimedShutdown.bat      <- launch this
build.bat / build.ps1  <- rebuilds dist\ from src\
src\                   <- source modules
dist\TimedShutdown.ps1 <- the bundled script the launcher runs
```

The launcher prefers `dist\TimedShutdown.ps1` and falls back to `src\Main.ps1`, so the app runs even before you have built anything.

---

## Features

### Timers Tab

#### Actions

| Button | What it does |
|--------|-------------|
| Shutdown | Shuts the PC down |
| Restart | Reboots the PC |
| Sleep | Suspends to RAM |
| Hibernate | Suspends to disk |

#### Time Input

| Format | Meaning |
|--------|---------|
| `1h30m` | 1 hour 30 minutes from now |
| `45m` | 45 minutes from now |
| `2h` | 2 hours from now |
| `90s` | 90 seconds from now |
| `1h30m45s` | Any combination of h/m/s |
| `90` | 90 minutes from now (plain number = minutes) |
| `22:30` | At 10:30 PM today, or tomorrow if that time has passed |

Timers are capped at 30 days. A live preview below the input shows the exact target time and a human-readable countdown before you start.

#### Active Timer Panel

Once a timer is running the panel shows the action type, a live countdown, the exact clock time it will fire, and:

- **Keeping PC awake** indicator (green) — the app is holding off Windows' idle sleep
- **Waiting** indicator (amber) — a guard is postponing the action, with the reason
- **Snooze buttons**: `+15m`, `+30m`, `+1h`
- **Cancel** — stops the timer immediately

#### Options

**Notify N min before** — a tray balloon when the timer gets that close.

**Network guard** — set a KB/s threshold (default 100). If network activity is above it as the timer runs out, the action is pushed back a minute at a time until traffic drops. Useful for letting downloads finish.

**Process guard** — name a process (e.g. `robocopy`, `steam`, `ffmpeg`); the action won't fire while it is running.

#### Quick Actions

- **Turn Off Monitor** — cuts power to the display without sleeping or locking
- **Lock Screen** — locks the workstation immediately

---

### Triggers Tab

Acts when *something happens*, rather than when a clock runs out. Pick what to
wait for, pick the action, press **Arm Trigger**.

| Wait for | Fires when |
|---|---|
| **A process exits** | Named processes have exited — `ffmpeg`, `HandBrake`, a game, a backup tool. Choose *all have exited* or *any one exits*. |
| **Downloads finish** | A watched folder has no partial-download files left and nothing has changed for N seconds. |
| **A signal file appears** | A file shows up at a chosen path. The universal hook — see below. |
| **Network / CPU go quiet** | Network below X KB/s and/or CPU below Y %, held for N seconds. |
| **The PC goes idle** | No mouse or keyboard input for the chosen threshold. |

Three behaviours are worth knowing, because they are what stop a trigger firing
by accident:

- **It waits for the event, not the condition.** Arming "when `ffmpeg` exits"
  while ffmpeg is *not* running waits for it to start first. Cancelling a
  countdown does not re-fire a second later — the trigger will not go off again
  until the situation genuinely resets (the process runs again, a new download
  starts, a fresh signal file appears).
- **A 60-second countdown you can stop.** When a trigger fires you get a
  countdown with **Cancel** and **Snooze 15m** — and *moving the mouse or pressing
  a key cancels it*. If the machine was asleep when the countdown should have
  ended, it aborts rather than acting on wake.
- **A trigger cannot fire in the first 15 seconds** after arming, so arming while
  the condition already happens to be true does nothing.

Editing a trigger while it is armed is not supported — disarm first, so the
trigger that is running is always the one you configured.

#### Signal files: triggering from anything

`tools\TimedShutdown-signal.cmd` writes a flag file that an armed **signal**
trigger picks up:

```bash
tools\TimedShutdown-signal.cmd done
```

That writes `%LOCALAPPDATA%\TimedShutdown\signals\done.flag`. Any tool that can
run a command can now trigger a shutdown — build scripts, backup jobs, render
queues, scheduled tasks.

> Write the file and **leave it**: the app deletes it when it consumes it. A flag
> that the producer creates and removes itself between two one-second polls is
> never seen. And point the trigger at a path you do not mind being deleted.

**Claude Code:** add a `Stop` hook to `.claude/settings.json`. If you already have
`Stop` hooks, append to the array rather than replacing it — a copy-paste that
overwrites will silently disable whatever was there:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "C:\\path\\to\\tools\\TimedShutdown-signal.cmd done" }
        ]
      }
    ]
  }
}
```

Arm a **signal file appears** trigger with the action you want, and the machine
shuts down when Claude finishes.

---

### Scheduled Tab

Recurring or one-time actions via Windows Task Scheduler, stored in the `\TimedShutdown\` task folder.

- **+ Add** — action, recurrence (Once / Daily / Weekly with a day picker), and a 24-hour time
- **- Remove** — deletes the selected task
- A `once` schedule for a time that has already passed today is created for **tomorrow**, so it still fires

---

### System Tray

The app lives in the tray when minimized or when the window is closed with X.

- **Double-click** to restore
- Tooltip shows the active countdown or trigger state
- Right-click for **Open**, **Cancel Timer / Disarm**, **Open Log**, **Exit**

Closing with X minimizes to tray; use the tray menu's Exit to actually quit.

---

### Global Hotkey

**Win + Alt + M** turns off the monitor from anywhere, even when the app is minimized.

---

### Keeping the PC awake

While a timer or trigger is pending, the app asks Windows to hold off automatic sleep using `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`.

This is a request tied to the running process. It changes **no** global settings, and Windows drops it automatically when the app exits — so your power plan can never be left modified, even on a crash or power loss. You can confirm the request is active with:

```bash
powercfg /requests
```

It blocks only *idle* sleep. Closing the lid or choosing Sleep from the Start menu still works normally, as do the app's own sleep and hibernate actions.

> **Upgrading from an older version:** builds before this one edited the global power plan directly (standby/hibernate → never) and only restored it if you pressed Cancel — so a timer that actually fired left sleep permanently disabled. On first launch the app detects that leftover state, restores the values it recorded, and tells you it did. If your plan was already showing "never" and you would rather set it yourself, check **Settings → System → Power & battery → Screen and sleep**.

---

## State File

```
%LOCALAPPDATA%\TimedShutdown\state.json
```

Tracks the pending timer, your saved settings, and the trigger configuration. An older file at `%TEMP%\TimedShutdown_state.json` is migrated automatically on first run. You can delete it safely — the app recreates it as needed.

---

## How Timers Work Internally

| Action | Method |
|--------|--------|
| Shutdown | `shutdown.exe /s /t N` — OS-level, survives app close |
| Restart | `shutdown.exe /r /t N` — OS-level, survives app close |
| Sleep | One-shot Task Scheduler entry running `rundll32 powrprof.dll,SetSuspendState` |
| Hibernate | One-shot Task Scheduler entry running `shutdown.exe /h` |

Shutdown and Restart are managed by Windows itself, so they fire even if the app is closed — press Cancel first if you want to abort. Sleep and Hibernate entries are removed when cancelled.

---

## Development

Source lives in `src\` as dot-sourced modules; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module map and load order.

Rebuild the single-file bundle after any change:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

Source files must be saved as **UTF-8 with BOM**. PowerShell 5.1 reads a BOM-less script as Windows-1252, which turns `·` into `Â·` and corrupts every other non-ASCII glyph in the UI. The build fails loudly if a BOM is missing; this re-saves them:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -FixEncoding
```

Run the tests. `-STA` is required — the markup tests instantiate WPF objects:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\Invoke-Tests.ps1
```

Needs Pester 6.1.0 (Windows ships 3.4.0, which cannot run them). Install it once:

```bash
powershell -NoProfile -Command "Install-Module Pester -RequiredVersion 6.1.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

`-RequiredVersion`, not `-MinimumVersion`, and pinned to the version CI runs.
Asking for "5.0 or newer" once installed a Pester whose breaking changes
(root-level `BeforeEach` rejected) silently failed a whole test file — the suite
reported green while a file had not loaded at all.

If that fails with a `ShouldContinue` error, the NuGet provider is missing and
PowerShellGet is trying to prompt for it. Bootstrap it first:

```bash
powershell -NoProfile -Command "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force"
```

Note that `Install-Module` from **pwsh 7** writes to a different module path than
Windows PowerShell 5.1 reads, and the tests run under 5.1. Check what 5.1 can
actually see, not what your current shell reports:

```bash
powershell -NoProfile -Command "Get-Module -ListAvailable Pester | Select-Object Version, Path"
```

---

## Troubleshooting

**"Administrator privileges are required"**
Launch via `TimedShutdown.bat` rather than running the `.ps1` directly.

**Win+Alt+M doesn't work**
Another application already registered that combination. The app skips hotkey registration silently; nothing else is affected.

**Network guard KB/s is always 0**
Needs the `NetAdapter` module (included with Windows 10/11), which may be absent in some environments.

**Text shows `Â·` or other garbled characters**
A source file lost its UTF-8 BOM. Run `build.ps1 -FixEncoding` and rebuild.

**A trigger did not fire, or fired when you did not expect**
Check the log — every arm, fire, cancel, and abort is recorded with a reason.
Tray menu → **Open Log**, or:

```bash
notepad %LOCALAPPDATA%\TimedShutdown\log.txt
```

**Two copies of the app**
Only one runs at a time; launching again focuses the existing window.

---

## Licence

MIT — see [LICENSE](LICENSE).

Colour palette based on [Catppuccin](https://github.com/catppuccin/catppuccin)
Mocha (MIT).
