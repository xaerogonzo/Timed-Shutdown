#Requires -Version 5.1
<#
    Timed Shutdown - GENERATED FILE, DO NOT EDIT.

    Built from src\ by build.ps1 on 2026-09-04 13:40:44.
    Edit the files under src\ and re-run build.ps1 instead.
#>

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

# ═══ begin Interop.ps1 ═════════════════════════════════════════════
<#
    Interop.ps1 - assemblies and P/Invoke surface.

    MUST be dot-sourced before anything else: every other module references the
    types defined here, and Add-Type has to have run before those references are
    resolved. Main.ps1 fixes the load order explicitly.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName System.Xaml

if (-not ('WinApi' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct FILETIME {
    public int dwLowDateTime;
    public int dwHighDateTime;
}

[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}

public class WinApi {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    // Releases the HICON behind a tray icon. Icon.FromHandle(h).Dispose() only
    // disposes the managed wrapper and leaks the underlying GDI handle.
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);

    // Milliseconds since boot, 64-bit so it never wraps.
    //
    // NOT [Environment]::TickCount64 - that is .NET Core 3.0+ only, and Windows
    // PowerShell 5.1 runs on .NET Framework 4.x where it does not exist. It
    // evaluates to nothing there, silently making every elapsed-time
    // calculation zero. [Environment]::TickCount does exist but is Int32 and
    // wraps after ~49 days, which would make a delta hugely negative.
    //
    // This is also deliberately the same clock family as GetLastInputInfo, so
    // the grace abort can compare idle growth against elapsed time and have the
    // two agree across suspend.
    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();

    // Keeps the machine awake while a timer is pending. Per-thread and cleared
    // automatically by Windows when the process exits, so unlike rewriting the
    // power plan this cannot strand the user's settings.
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS      = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;

    // CPU load without WMI or performance counters. Get-Counter uses LOCALIZED
    // counter names (breaks on non-English Windows, the same failure class as the
    // powercfg regex fixed in v2.0), and the WMI perf class measured ~290ms per
    // call - a third of the 1Hz tick budget. This costs ~1.7ms.
    // kernel time INCLUDES idle, so: load = 1 - idleDelta / (kernelDelta + userDelta)
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

    public static ulong FileTimeToULong(FILETIME ft) {
        return ((ulong)ft.dwHighDateTime << 32) | (uint)ft.dwLowDateTime;
    }

    // Used by the single-instance guard to surface the window that already owns
    // the mutex. Activation is best-effort: Windows does not guarantee
    // SetForegroundWindow succeeds, and a failure must never stop the second
    // instance from exiting.
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_RESTORE = 9;

    public const uint WM_SYSCOMMAND   = 0x0112;
    public const int  SC_MONITORPOWER = 0xF170;
    public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

    public static uint GetIdleMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        GetLastInputInfo(ref lii);
        return (uint)Environment.TickCount - lii.dwTime;
    }
}
'@
}

# The hotkey manager needs the WPF assemblies referenced explicitly, which means
# resolving their on-disk locations first. Failure here is non-fatal: the app
# simply runs without the Win+Alt+M global hotkey.
if (-not ('WindowHotkeyManager' -as [type])) {
    $_wpfRefs = @(
        [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -in @('PresentationCore','PresentationFramework','WindowsBase','System.Xaml') } |
        ForEach-Object { $_.Location } |
        Where-Object { $_ }
    )
    try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

public class WindowHotkeyManager {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    const uint MOD_ALT   = 0x0001;
    const uint MOD_WIN   = 0x0008;
    const uint VK_M      = 0x4D;
    const int  HK_ID     = 1;
    const int  WM_HOTKEY = 0x0312;

    HwndSource _src;
    IntPtr     _hwnd;
    public event EventHandler MonitorOff;

    public void Attach(Window w) {
        _hwnd = new WindowInteropHelper(w).Handle;
        _src  = HwndSource.FromHwnd(_hwnd);
        if (_src != null) _src.AddHook(WndProc);
        RegisterHotKey(_hwnd, HK_ID, MOD_WIN | MOD_ALT, VK_M);
    }

    public void Detach(Window w) {
        UnregisterHotKey(_hwnd, HK_ID);
        if (_src != null) { _src.RemoveHook(WndProc); _src = null; }
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HK_ID) {
            handled = true;
            var ev = MonitorOff;
            if (ev != null) ev(this, EventArgs.Empty);
        }
        return IntPtr.Zero;
    }
}
'@ -ReferencedAssemblies $_wpfRefs
    } catch {}
}

# ═══ end Interop.ps1 ═══════════════════════════════════════════════

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

# ═══ begin Core\Log.ps1 ════════════════════════════════════════════
<#
    Core/Log.ps1 - a small rolling log.

    Exists because the v2.1 scheduled-task bug failed *silently*:
    Register-ScheduledTask reported a non-terminating error that was piped to
    Out-Null, so the app counted down a Sleep timer that had no task behind it
    and nothing anywhere recorded why. A log would have shown it immediately.

    Kept deliberately dumb: append a line, roll at a size cap. No async, no
    handles held open - the dispatcher must never block on it.
#>

$script:LOG_FILE     = Join-Path (Join-Path $env:LOCALAPPDATA 'TimedShutdown') 'log.txt'
$script:LOG_MAX_BYTES = 256KB

# Test seam.
function Set-LogFilePath ([string]$Path) { $script:LOG_FILE = $Path }
function Get-LogFilePath { return $script:LOG_FILE }

function Invoke-LogRollover {
    try {
        if (-not (Test-Path $script:LOG_FILE)) { return }
        if ((Get-Item $script:LOG_FILE).Length -lt $script:LOG_MAX_BYTES) { return }
        # -Force is required: Move-Item fails outright when the target exists,
        # so a second rollover would silently stop logging without it.
        Move-Item $script:LOG_FILE "$($script:LOG_FILE).bak" -Force -ErrorAction Stop
    } catch {}
}

<#
    Appends one record.

        Write-Log 'trigger' 'armed' 'kind=process targets=ffmpeg mode=all'

    Fields are tab-separated with an ISO-8601 timestamp so the file greps and
    sorts cleanly.
#>
function Write-Log ([string]$Category, [string]$EventName, [string]$Detail = '') {
    try {
        $dir = Split-Path $script:LOG_FILE -Parent
        # -ErrorAction Stop is load-bearing, for the same reason it is on every
        # Register-ScheduledTask call: New-Item reports a bad path as a
        # NON-terminating error, which try/catch does not catch. Without it the
        # failure escaped into the error stream and execution carried on to the
        # append below -- so the catch here was giving false comfort, and an
        # unwritable log path meant an error record every single dispatcher tick.
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        Invoke-LogRollover

        $version = if ($script:APP_VERSION) { $script:APP_VERSION } else { '?' }

        # DOUBLE-quoted, and that is the whole point: PowerShell processes escape
        # sequences only inside double quotes. This literal was single-quoted
        # until v2.3, so `t was not a tab -- it was the two characters ` and t,
        # written between every field of every line ever logged. The "fields are
        # tab-separated" promise above was simply false, and nothing splitting on
        # tabs could read the file.
        $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f `
            (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), $version, $Category, $EventName, $Detail

        # Append with an explicit UTF-8 (no BOM on append) writer rather than
        # Add-Content, which re-opens and can trip over encoding on a rolled file.
        [System.IO.File]::AppendAllText($script:LOG_FILE, $line + "`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Logging must never take the app down.
    }
}

function Write-LogHeader {
    Write-Log 'app' 'start' ("version={0} ps={1} os={2}" -f `
        $script:APP_VERSION, $PSVersionTable.PSVersion, [Environment]::OSVersion.Version)
}

# ═══ end Core\Log.ps1 ══════════════════════════════════════════════
# ═══ begin Core\Time.ps1 ═══════════════════════════════════════════
<#
    Core/Time.ps1 - parsing and formatting of durations.

    Pure functions with no UI or system dependencies, which is what makes them
    unit-testable (see tests/Time.Tests.ps1). Both of the display bugs this
    module was rewritten to fix lived here.
#>

# 30 days. Anything beyond this is treated as a typo rather than a real timer.
$script:MAX_TIMER_SECONDS = 2592000

function ConvertTo-BoundedSeconds ([long]$Seconds) {
    if ($Seconds -lt 1 -or $Seconds -gt $script:MAX_TIMER_SECONDS) { return $null }
    return [int]$Seconds
}

<#
    Accepts:
      22:30     next occurrence of that clock time (today, else tomorrow)
      1h30m     relative duration; any combination of h/m/s
      45m  2h  90s  1h30m45s
      90        a bare number means minutes
    Returns whole seconds, or $null if the input is not a valid time.
#>
function ConvertTo-Seconds ([string]$TimeStr) {
    if ([string]::IsNullOrWhiteSpace($TimeStr)) { return $null }
    $t = $TimeStr.Trim()

    # Absolute clock time.
    if ($t -match '^(\d{1,2}):(\d{2})$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
        if ($h -gt 23 -or $m -gt 59) { return $null }
        $now    = Get-Date
        $target = $now.Date.AddHours($h).AddMinutes($m)
        if ($target -le $now) { $target = $target.AddDays(1) }
        return [int][math]::Round(($target - $now).TotalSeconds)
    }

    # Relative duration.
    #
    # The lookahead is what requires at least one unit letter. That check used to
    # be a second `-and ($t -match '[hms]')` test -- which reassigned $Matches and
    # wiped capture groups 1-3, so $sec stayed 0 and every h/m/s input was
    # rejected as invalid. Keep the unit check inside this one regex.
    #
    # Digit counts are capped so the arithmetic below cannot overflow.
    if ($t -match '^(?=.*[hms])(?:(\d{1,7})h)?(?:(\d{1,7})m)?(?:(\d{1,7})s)?$') {
        [long]$sec = 0
        if ($Matches[1]) { $sec += [long]$Matches[1] * 3600 }
        if ($Matches[2]) { $sec += [long]$Matches[2] * 60   }
        if ($Matches[3]) { $sec += [long]$Matches[3]        }
        return ConvertTo-BoundedSeconds $sec
    }

    # Bare number = minutes. TryParse rather than a cast: a long run of digits
    # would throw an overflow exception straight into the TextChanged handler.
    if ($t -match '^\d+$') {
        [long]$mins = 0
        if (-not [long]::TryParse($t, [ref]$mins)) { return $null }
        if ($mins -gt ($script:MAX_TIMER_SECONDS / 60)) { return $null }
        return ConvertTo-BoundedSeconds ($mins * 60)
    }

    return $null
}

<#
    Splits a duration into whole hours/minutes/seconds.

    Hours MUST come from [math]::Floor, never from an [int] cast: [int] rounds
    (and rounds half to even), so [int]([timespan]::FromMinutes(31)).TotalHours
    was 1 while .Minutes was 31 -- displaying "1 hour 31 minutes". 30 minutes
    escaped the bug only because 0.5 rounds to even, i.e. down to 0.
#>
function Split-Duration ([double]$TotalSeconds) {
    $s = [int][math]::Round($TotalSeconds)
    if ($s -lt 0) { $s = 0 }
    return @{
        H = [int][math]::Floor($s / 3600)
        M = [int][math]::Floor(($s % 3600) / 60)
        S = $s % 60
    }
}

function Format-Countdown ([timespan]$ts) {
    $d = Split-Duration $ts.TotalSeconds
    if ($d.H -gt 0) { return "$($d.H)h $($d.M.ToString('00'))m $($d.S.ToString('00'))s" }
    if ($d.M -gt 0) { return "$($d.M)m $($d.S.ToString('00'))s" }
    return "$($d.S)s"
}

function Format-TargetTime ([string]$TimeStr, [string]$Verb) {
    $sec = ConvertTo-Seconds $TimeStr
    if ($null -eq $sec) { return 'Enter a valid time  (e.g. 1h30m  ·  45m  ·  2h  ·  22:30)' }

    $target = (Get-Date).AddSeconds($sec)
    $d      = Split-Duration $sec

    $parts = @()
    if ($d.H -gt 0) { $parts += "$($d.H) hour$(if ($d.H -ne 1) { 's' })" }
    if ($d.M -gt 0) { $parts += "$($d.M) minute$(if ($d.M -ne 1) { 's' })" }
    if ($d.S -gt 0 -and $d.H -eq 0) { $parts += "$($d.S) second$(if ($d.S -ne 1) { 's' })" }
    if ($parts.Count -eq 0) { $parts = @('less than a minute') }

    return "Will $Verb at $($target.ToString('h:mm tt'))  ·  in $($parts -join ' ')"
}

function Format-IdleDuration ([double]$Seconds) {
    $d = Split-Duration $Seconds
    if ($d.H -gt 0) { return "$($d.H)h $($d.M.ToString('00'))m" }
    if ($d.M -gt 0) { return "$($d.M)m $($d.S.ToString('00'))s" }
    return "$($d.S)s"
}

# ═══ end Core\Time.ps1 ═════════════════════════════════════════════
# ═══ begin Core\State.ps1 ══════════════════════════════════════════
<#
    Core/State.ps1 - the on-disk state file.

    Tracks the pending action, the idle watch, and (legacy only) any power-plan
    suppression left behind by an older build.

    The file used to live in %TEMP%, where a disk cleanup could delete the only
    record of the user's original power settings. It now lives under
    %LOCALAPPDATA% and migrates the old file on first run.
#>

# Bumped whenever the on-disk shape changes. Migration keys on THIS, never on
# structural sniffing - "does key X exist" guesses wrong the moment two versions
# happen to share a key.
$script:STATE_SCHEMA_VERSION = 2

$script:STATE_DIR         = Join-Path $env:LOCALAPPDATA 'TimedShutdown'
$script:STATE_FILE        = Join-Path $script:STATE_DIR 'state.json'
$script:LEGACY_STATE_FILE = Join-Path $env:TEMP 'TimedShutdown_state.json'

# Read-State runs several times per dispatcher tick. Cache on the file's write
# timestamp so a 1 s tick costs one stat() rather than a parse of the whole file.
$script:stateCache      = $null
$script:stateCacheStamp = $null

<#
    Test seam: point the store somewhere disposable.

    LegacyPath must be redirected too, or a test run would migrate (and delete)
    the real %TEMP% state file belonging to a live install.
#>
function Set-StateFilePath ([string]$Path, [string]$LegacyPath = '') {
    $script:STATE_FILE        = $Path
    $script:STATE_DIR         = Split-Path $Path -Parent
    $script:LEGACY_STATE_FILE = if ($LegacyPath) { $LegacyPath } else { Join-Path $script:STATE_DIR '__no_legacy__.json' }
    $script:stateCache        = $null
    $script:stateCacheStamp   = $null
}

function Initialize-StateStore {
    if (-not (Test-Path $script:STATE_DIR)) {
        New-Item -ItemType Directory -Path $script:STATE_DIR -Force | Out-Null
    }
    if ((-not (Test-Path $script:STATE_FILE)) -and (Test-Path $script:LEGACY_STATE_FILE)) {
        try { Move-Item $script:LEGACY_STATE_FILE $script:STATE_FILE -Force } catch {}
    }
}

function Read-State {
    if (-not (Test-Path $script:STATE_FILE)) {
        $script:stateCache = $null; $script:stateCacheStamp = $null
        return $null
    }
    try {
        $stamp = (Get-Item $script:STATE_FILE).LastWriteTimeUtc
        if ($null -ne $script:stateCache -and $stamp -eq $script:stateCacheStamp) {
            return $script:stateCache
        }
        $obj = Get-Content $script:STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:stateCache      = $obj
        $script:stateCacheStamp = $stamp
        return $obj
    } catch { return $null }
}

function Write-State ($partial) {
    Initialize-StateStore
    $h = @{ stateSchemaVersion = $script:STATE_SCHEMA_VERSION }
    $existing = Read-State
    if ($existing) { $existing.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    foreach ($kv in $partial.GetEnumerator()) { $h[$kv.Key] = $kv.Value }

    $json = $h | ConvertTo-Json -Depth 5
    # No BOM: this is JSON, not a PowerShell script.
    [System.IO.File]::WriteAllText($script:STATE_FILE, $json, (New-Object System.Text.UTF8Encoding($false)))

    $script:stateCache      = $null
    $script:stateCacheStamp = $null
}

function Clear-State {
    Write-State @{ pendingAction = @{ type = 'null' } }
}

# ── Schema migration ──────────────────────────────────────────────────────────

# State can be exercised without Core/Log.ps1 loaded (unit tests dot-source this
# file alone), so logging is best-effort rather than a hard dependency.
function Write-StateLog ([string]$Category, [string]$EventName, [string]$Detail) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Category $EventName $Detail }
}

<#
    Reads the schema version from a state object.

    v1 predates the field and instead wrote `version = '1.0'`, which nothing ever
    read back. Absent or '1.0' therefore means v1.
#>
function Get-StateSchemaVersion ($State) {
    if (-not $State) { return 0 }
    if ($State.PSObject.Properties['stateSchemaVersion']) {
        return [int]$State.stateSchemaVersion
    }
    return 1
}

<#
    Brings the state file up to the current schema, returning $true if anything
    was written.

    Safety rules, both deliberate:

    * A v1 armed idle watch becomes a v2 `idle` trigger that is DISARMED. A
      migration must never create an armed destructive action on a machine whose
      owner has not re-consented under the new UI.

    * A state file from a FUTURE schema is never reinterpreted as the current
      one. That would mean guessing at fields written by a version of the app
      that does not exist yet. Safe defaults are loaded, nothing is armed, and
      the reason is logged. This matters as soon as anyone copies a state file
      between machines.
#>
function Update-StateSchema {
    $state = Read-State
    if (-not $state) { return $false }

    $found = Get-StateSchemaVersion $state

    if ($found -gt $script:STATE_SCHEMA_VERSION) {
        # Written by a newer build than this one. Reinterpreting it would mean
        # guessing at fields that do not exist yet, so preserve the file intact
        # (the user may go back to that build) and start from clean defaults
        # with nothing armed.
        $preserved = "$($script:STATE_FILE).v$found.bak"
        try { Copy-Item $script:STATE_FILE $preserved -Force -ErrorAction Stop } catch {}
        Remove-Item $script:STATE_FILE -Force -ErrorAction SilentlyContinue
        $script:stateCache = $null; $script:stateCacheStamp = $null

        Write-State @{
            stateSchemaVersion = $script:STATE_SCHEMA_VERSION
            trigger            = @{ kind = 'idle'; action = 'shutdown'; armed = $false; config = @{} }
            settings           = @{}
        }
        Write-StateLog 'state' 'future-schema' `
            "found=$found supported=$($script:STATE_SCHEMA_VERSION) - preserved to $preserved, started clean, nothing armed"
        return $true
    }

    if ($found -ge $script:STATE_SCHEMA_VERSION) { return $false }

    # ---- v1 -> v2 ----
    $wasArmed = $false
    $trigger  = @{ kind = 'idle'; action = 'shutdown'; armed = $false; config = @{ thresholdSec = 1800 } }

    if ($state.PSObject.Properties['idleWatch'] -and $state.idleWatch) {
        $iw = $state.idleWatch
        if ($iw.PSObject.Properties['thresholdSec'] -and [int]$iw.thresholdSec -gt 0) {
            $trigger.config.thresholdSec = [int]$iw.thresholdSec
        }
        if ($iw.PSObject.Properties['type'] -and $iw.type -and $iw.type -ne 'null') {
            $trigger.action = [string]$iw.type
        }
        $wasArmed = [bool]$iw.active
    }

    Write-State @{
        stateSchemaVersion = $script:STATE_SCHEMA_VERSION
        trigger            = $trigger
        settings           = @{}
        idleWatch          = $null      # v1 shape retired
        # Retire the v1 'version' field too. Leaving it alongside
        # stateSchemaVersion means two fields that both look like "the version",
        # and a future reader has to guess which one governs.
        version            = $null
    }

    Write-StateLog 'state' 'migrated' ("v{0}->v{1} idleWatchWasArmed={2} (migrated DISARMED)" -f `
        $found, $script:STATE_SCHEMA_VERSION, $wasArmed)
    return $true
}

# ── Settings ──────────────────────────────────────────────────────────────────

<#
    Persisted UI preferences only.

    Runtime timing (grace/cooldown/sustain deadlines, priming flags, last
    samples) is deliberately NOT persisted: those are monotonic tick values that
    mean nothing after a reboot, and a persisted "primed" flag could resurrect an
    armed destructive action across a restart.
#>
function Get-Settings {
    $s = Read-State
    $defaults = @{
        notifyMins  = 5
        netKbps     = 100
        processName = ''
        lastAction  = 'shutdown'
    }
    if ($s -and $s.PSObject.Properties['settings'] -and $s.settings) {
        foreach ($k in @($defaults.Keys)) {
            if ($s.settings.PSObject.Properties[$k]) { $defaults[$k] = $s.settings.$k }
        }
    }
    return $defaults
}

function Save-Settings ($Settings) { Write-State @{ settings = $Settings } }

# ═══ end Core\State.ps1 ════════════════════════════════════════════
# ═══ begin Core\Scheduler.ps1 ══════════════════════════════════════
<#
    Core/Scheduler.ps1 - Windows Task Scheduler entries under \TimedShutdown\.

    Two kinds of task live in this folder:
      TS_pending_*  one-shot backing for a sleep/hibernate countdown
      TS_<action>_* user-created schedules shown on the Schedule tab

    Everything here issues CIM calls, so none of it belongs on the dispatcher
    tick -- see Get-TrackedAction in Core/Power.ps1 for the once-a-second path.
#>

$script:TASK_FOLDER = '\TimedShutdown'

function Ensure-TaskFolder {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $root = $svc.GetFolder('\')
    try { $root.GetFolder('TimedShutdown') | Out-Null }
    catch { $root.CreateFolder('TimedShutdown') | Out-Null }
}

<#
    NB: the argument-string parameter is $Arguments, never $Args.

    $Args is a reserved automatic variable (the function's own argument array),
    so a parameter of that name never receives the caller's value -- it arrives
    empty. New-ScheduledTaskAction then rejects -Argument '' and the whole call
    fails with "Cannot validate argument on parameter 'Argument'", which is what
    broke every Sleep and Hibernate timer.
#>
function New-PendingTask ([string]$Name, [string]$Exe, [string]$Arguments, [datetime]$FireAt) {
    Ensure-TaskFolder
    Unregister-ScheduledTask -TaskName $Name -TaskPath "$($script:TASK_FOLDER)\" `
        -Confirm:$false -ErrorAction SilentlyContinue
    $a  = New-ScheduledTaskAction  -Execute $Exe -Argument $Arguments
    $t  = New-ScheduledTaskTrigger -Once -At $FireAt

    # DeleteExpiredTaskAfter makes the one-shot task clean itself up, but Task
    # Scheduler only accepts it when the trigger declares when it expires.
    # Without this the whole registration is rejected with "The task XML is
    # missing a required element or attribute ... EndBoundary".
    $t.EndBoundary = $FireAt.AddMinutes(5).ToString('s')

    $p  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $st = New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter '00:01:00' -ExecutionTimeLimit '00:05:00'

    # -ErrorAction Stop is load-bearing: Register-ScheduledTask reports failure
    # as a NON-terminating error, so piping to Out-Null without it swallowed the
    # rejection entirely. The app then wrote its pending state and counted down
    # a timer that had no task behind it and could never fire.
    Register-ScheduledTask -TaskName $Name -TaskPath "$($script:TASK_FOLDER)\" `
        -Action $a -Trigger $t -Principal $p -Settings $st -Force -ErrorAction Stop | Out-Null
}

<#
    Resolves "22:30" to the next time that clock reading occurs.

    A 'once' schedule anchored to today would silently never fire if the time had
    already passed, so it rolls to tomorrow -- matching what ConvertTo-Seconds
    does for the timer box. Daily and weekly triggers roll over on their own.
#>
function Resolve-ScheduleTime ([string]$AtTime, [string]$Recurrence, [datetime]$Now = (Get-Date)) {
    $pt = [datetime]::ParseExact($AtTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($Recurrence -eq 'once' -and $pt -le $Now) { $pt = $pt.AddDays(1) }
    return $pt
}

<#
    The task name, built separately so the rollover rule above and the naming
    rule here can both be tested without registering anything.

    NB the name is the ONLY record of what a schedule does -- the Scheduled tab
    reads it back and shows it raw. That is why it encodes action, recurrence,
    days and time.
#>
function Get-ScheduledTaskName {
    param(
        [string]   $ActionType,
        [string]   $Recurrence,
        [string]   $AtTime,
        [string[]] $DaysOfWeek = @()
    )
    $dayStr = if ($DaysOfWeek.Count -gt 0) { '_' + ($DaysOfWeek -join '') } else { '' }
    return "TS_${ActionType}_${Recurrence}${dayStr}_$($AtTime -replace ':','')"
}

function Add-ScheduledAction ([string]$ActionType, [string]$Recurrence, [string]$AtTime, [string[]]$DaysOfWeek = @()) {
    Ensure-TaskFolder
    $taskAction = switch ($ActionType) {
        'shutdown'  { New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/s /f' }
        'restart'   { New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/r /f' }
        'sleep'     { New-ScheduledTaskAction -Execute 'rundll32.exe' -Argument 'powrprof.dll,SetSuspendState 0,1,0' }
        'hibernate' { New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/h' }
    }
    $pt = Resolve-ScheduleTime $AtTime $Recurrence
    $trigger = switch ($Recurrence) {
        'once'   { New-ScheduledTaskTrigger -Once   -At $pt }
        'daily'  { New-ScheduledTaskTrigger -Daily  -At $pt }
        'weekly' { New-ScheduledTaskTrigger -Weekly -At $pt -DaysOfWeek $DaysOfWeek }
    }
    $name   = Get-ScheduledTaskName $ActionType $Recurrence $AtTime $DaysOfWeek
    $pr     = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $set    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit '00:05:00'
    Register-ScheduledTask -TaskName $name -TaskPath "$($script:TASK_FOLDER)\" `
        -Action $taskAction -Trigger $trigger -Principal $pr -Settings $set -Force -ErrorAction Stop | Out-Null
    return $name
}

function Get-ScheduledActionsList {
    @(Get-ScheduledTask -TaskPath "$($script:TASK_FOLDER)\" -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -notmatch '^TS_pending_' }) | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName `
                    -TaskPath "$($script:TASK_FOLDER)\" -ErrorAction SilentlyContinue
        $next = if ($info -and $info.NextRunTime -and $info.NextRunTime -gt [datetime]::MinValue) {
            $info.NextRunTime.ToString('MM/dd  h:mm tt')
        } else { '—' }
        [PSCustomObject]@{ Name = $_.TaskName; NextRun = $next }
    }
}

# ═══ end Core\Scheduler.ps1 ════════════════════════════════════════
# ═══ begin Core\Guards.ps1 ═════════════════════════════════════════
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

# ═══ end Core\Guards.ps1 ═══════════════════════════════════════════
# ═══ begin Core\Triggers.ps1 ═══════════════════════════════════════
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

# ═══ end Core\Triggers.ps1 ═════════════════════════════════════════
# ═══ begin Core\Power.ps1 ══════════════════════════════════════════
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

# ═══ end Core\Power.ps1 ════════════════════════════════════════════
# ═══ begin UI\Theme.ps1 ════════════════════════════════════════════
<#
    UI/Theme.ps1 - the colour values used from code.

    Anything purely declarative lives in the XAML; these are the few shades the
    event handlers have to apply at runtime.
#>

$script:COLOR_OK      = '#A6E3A1'  # green  - valid input, keep-awake active
$script:COLOR_MUTED   = '#6C7086'  # grey   - placeholder / invalid input
$script:COLOR_WARN    = '#FAB387'  # amber  - a guard is holding the action back

function ConvertTo-Brush ([string]$hex) {
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

# ═══ end UI\Theme.ps1 ══════════════════════════════════════════════
# ═══ begin UI\Xaml.ps1 ═════════════════════════════════════════════
<#
    UI/Xaml.ps1 - loads .xaml markup into WPF objects.

    Markup normally comes off disk from src/UI. The bundler pre-populates
    $script:XamlCache with the same markup as here-strings, so the single-file
    build in dist/ resolves from memory and needs no companion files. Call sites
    are identical either way.
#>

$script:XamlRoot  = $PSScriptRoot
$script:XamlCache = @{}
# Markup embedded by build.ps1 so the bundle is self-contained.
$script:XamlCache['MainWindow.xaml'] = @'
<?xml version="1.0" encoding="utf-8"?>
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Timed Shutdown"
    Width="490" Height="800"
    ResizeMode="CanResize" MinWidth="470" MinHeight="700"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E2E"
    FontFamily="Segoe UI">

  <Window.Resources>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#45475A" CornerRadius="3" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ActionToggle" TargetType="ToggleButton">
      <Setter Property="Background" Value="#2A2A3E"/>
      <Setter Property="Foreground" Value="#BAC2DE"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="0,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#7C9DDA"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#7C9DDA"/>
                <Setter Property="Foreground" Value="#1E1E2E"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsChecked" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="Background" Value="#313244"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#585B70"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#7C9DDA"/>
      <Setter Property="Foreground" Value="#1E1E2E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#89B4FA"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#6785BE"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#313244"/>
                <Setter Property="Foreground" Value="#45475A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button">
      <Setter Property="Background" Value="#F38BA8"/>
      <Setter Property="Foreground" Value="#1E1E2E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F5A3B5"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#313244"/>
                <Setter Property="Foreground" Value="#45475A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#45475A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#BAC2DE"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="ChkBd" Width="15" Height="15" CornerRadius="3"
                      Background="#2A2A3E" BorderBrush="#585B70" BorderThickness="1.5"
                      VerticalAlignment="Center" Margin="0,0,7,0">
                <TextBlock x:Name="ChkMark" Text="&#x2713;" Foreground="#89B4FA"
                           FontSize="10" HorizontalAlignment="Center"
                           VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="ChkBd" Property="Background" Value="#1C2C4A"/>
                <Setter TargetName="ChkBd" Property="BorderBrush" Value="#7C9DDA"/>
                <Setter TargetName="ChkMark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ChkBd" Property="BorderBrush" Value="#7C9DDA"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!--
      Padding carries 4px of slack on the right that the old 4,0,4,10 did not.
      TabPanel sizes each tab from its normal-weight text, but the IsSelected
      trigger below switches the header to SemiBold, which measures ~1.7px wider
      at 14px Segoe UI - enough to clip the last glyph ("Timers" -> "Timer").
      Total horizontal space per tab is unchanged: Margin drops 12 -> 8 as
      Padding gains 4, so the strip looks the same but the text always fits.
    -->
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#6C7086"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="4,0,8,10"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBd" Background="Transparent"
                    BorderThickness="0,0,0,2" BorderBrush="Transparent"
                    Padding="{TemplateBinding Padding}" Cursor="Hand">
              <TextBlock x:Name="TabTxt" Text="{TemplateBinding Header}"
                         FontSize="14" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBd" Property="BorderBrush" Value="#7C9DDA"/>
                <Setter TargetName="TabTxt" Property="Foreground" Value="#CDD6F4"/>
                <Setter TargetName="TabTxt" Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsSelected" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="TabTxt" Property="Foreground" Value="#BAC2DE"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Grid Margin="24,20,24,24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,18">
      <TextBlock Text="&#x23FB;" FontSize="22" Foreground="#7C9DDA"
                 VerticalAlignment="Center" Margin="0,0,10,3"/>
      <TextBlock x:Name="LblAppTitle" Text="Timed Shutdown" FontSize="20" FontWeight="Bold"
                 Foreground="#CDD6F4" VerticalAlignment="Center"/>
    </StackPanel>

    <TabControl Grid.Row="1" x:Name="MainTabs" Background="Transparent" BorderThickness="0">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TabPanel Grid.Row="0" IsItemsHost="True" Background="Transparent"/>
            <Border Grid.Row="1" Background="Transparent" Padding="0,18,0,0">
              <!--
                The name PART_SelectedContentHost is required, not decorative.
                TabControl looks it up to populate SelectedContentHost, and
                TabItemAutomationPeer resolves the selected tab's content
                through that property. Unnamed, the whole tab content is absent
                from the UI Automation tree: screen readers see three tab
                headers and nothing else, and no control inside a tab can be
                reached by assistive technology or UI testing.
              -->
              <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"/>
            </Border>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>

      <!-- ══ Timers Tab ══ -->
      <TabItem Header="Timers">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="ACTION" FontSize="10" Foreground="#6C7086"
                     FontWeight="SemiBold" Margin="0,0,0,8"/>

          <UniformGrid Grid.Row="1" Columns="4" Margin="0,0,0,18">
            <ToggleButton x:Name="BtnShutdown" IsChecked="True" Content="Shutdown"
                          Style="{StaticResource ActionToggle}" Margin="0,0,4,0"/>
            <ToggleButton x:Name="BtnRestart" Content="Restart"
                          Style="{StaticResource ActionToggle}" Margin="4,0,4,0"/>
            <ToggleButton x:Name="BtnSleep" Content="Sleep"
                          Style="{StaticResource ActionToggle}" Margin="4,0,4,0"/>
            <ToggleButton x:Name="BtnHibernate" Content="Hibernate"
                          Style="{StaticResource ActionToggle}" Margin="4,0,0,0"/>
          </UniformGrid>

          <TextBlock Grid.Row="2" Text="TIME" FontSize="10" Foreground="#6C7086"
                     FontWeight="SemiBold" Margin="0,0,0,8"/>

          <Grid Grid.Row="3" Margin="0,0,0,8">
            <Border Background="#2A2A3E" CornerRadius="6"
                    BorderBrush="#45475A" BorderThickness="1" Height="44">
              <Grid>
                <TextBox x:Name="TxtTime" Background="Transparent" Foreground="#CDD6F4"
                         BorderThickness="0" Padding="12,0" FontSize="14"
                         VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                <TextBlock x:Name="TxtPlaceholder"
                           Text="e.g.  1h30m  &#183;  45m  &#183;  2h  &#183;  22:30"
                           Foreground="#45475A" FontSize="14"
                           Margin="13,0,0,0" VerticalAlignment="Center"
                           IsHitTestVisible="False"/>
              </Grid>
            </Border>
          </Grid>

          <TextBlock x:Name="LblPreview" Grid.Row="4"
                     Text="Enter a time above to preview"
                     Foreground="#6C7086" FontSize="13"
                     TextWrapping="Wrap" Margin="0,0,0,14"/>

          <Button x:Name="BtnStart" Grid.Row="5" Content="Start Timer"
                  Style="{StaticResource PrimaryBtn}"
                  Height="42" HorizontalAlignment="Stretch"
                  Padding="0" Margin="0,0,0,12"/>

          <!-- Options section -->
          <Border Grid.Row="6" Background="#161626" CornerRadius="6"
                  Padding="14,10" Margin="0,0,0,14">
            <StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <CheckBox x:Name="ChkNotify" VerticalAlignment="Center" Margin="0,0,0,0"/>
                <TextBlock Text="Notify" Foreground="#BAC2DE" FontSize="13"
                           VerticalAlignment="Center" Margin="0,0,8,0"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="44" Height="26"
                        BorderBrush="#45475A" BorderThickness="1" Margin="0,0,6,0">
                  <TextBox x:Name="TxtNotifyMins" Background="Transparent" Foreground="#CDD6F4"
                           BorderThickness="0" Padding="4,0" FontSize="12" Text="5"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"
                           HorizontalContentAlignment="Center"/>
                </Border>
                <TextBlock Text="min before" Foreground="#6C7086" FontSize="13"
                           VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <CheckBox x:Name="ChkGuardNetwork" VerticalAlignment="Center" Margin="0,0,0,0"/>
                <TextBlock Text="Network guard" Foreground="#BAC2DE" FontSize="13"
                           VerticalAlignment="Center" Margin="0,0,8,0"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="54" Height="26"
                        BorderBrush="#45475A" BorderThickness="1" Margin="0,0,6,0">
                  <TextBox x:Name="TxtNetKbps" Background="Transparent" Foreground="#CDD6F4"
                           BorderThickness="0" Padding="4,0" FontSize="12" Text="100"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"
                           HorizontalContentAlignment="Center"/>
                </Border>
                <TextBlock Text="KB/s threshold" Foreground="#6C7086" FontSize="13"
                           VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <CheckBox x:Name="ChkGuardProcess" VerticalAlignment="Center" Margin="0,0,0,0"/>
                <TextBlock Text="Process guard" Foreground="#BAC2DE" FontSize="13"
                           VerticalAlignment="Center" Margin="0,0,8,0"/>
                <Border Background="#2A2A3E" CornerRadius="4" Height="26" MinWidth="120"
                        BorderBrush="#45475A" BorderThickness="1">
                  <TextBox x:Name="TxtProcessName" Background="Transparent" Foreground="#CDD6F4"
                           BorderThickness="0" Padding="6,0" FontSize="12"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                </Border>
              </StackPanel>
            </StackPanel>
          </Border>

          <!--
            The active timer scrolls; Quick Actions stay pinned.

            These used to share one StackPanel, which neither clips nor scrolls.
            When the active-timer panel appeared it pushed Quick Actions past the
            bottom of a fixed-size, non-resizable window, so "Turn Off Monitor"
            and "Lock Screen" became unreachable exactly while a timer was
            running - which is when they are most wanted. The layout had ~2px of
            slack even before the guard banner, so window chrome or DPI rounding
            was enough to lose them.
          -->
          <Grid Grid.Row="7">
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"
                          HorizontalScrollBarVisibility="Disabled">
              <StackPanel>
                <Rectangle Height="1" Fill="#313244" Margin="0,0,0,12"/>
                <TextBlock Text="ACTIVE TIMER" FontSize="10" Foreground="#6C7086"
                           FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock x:Name="LblNoTimer" Text="No active timer"
                           Foreground="#45475A" FontSize="13"/>

              <Border x:Name="PanelActive" Background="#2A2A3E" CornerRadius="8"
                      Padding="18,14" Visibility="Collapsed">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="LblActiveType" Grid.Row="0" Grid.Column="0"
                             Text="SHUTDOWN" Foreground="#7C9DDA"
                             FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="LblCountdown" Grid.Row="1" Grid.Column="0"
                             Text="--h --m --s" Foreground="#CDD6F4"
                             FontSize="28" FontWeight="Bold" Margin="0,2,0,2"/>
                  <Button Grid.Row="0" Grid.RowSpan="2" Grid.Column="1"
                          x:Name="BtnCancel" Content="Cancel"
                          Style="{StaticResource DangerBtn}"
                          Padding="14,8" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  <StackPanel Grid.Row="2" Grid.ColumnSpan="2" Margin="0,8,0,0">
                    <TextBlock x:Name="LblActiveTarget" Text=""
                               Foreground="#6C7086" FontSize="12"/>
                    <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
                      <TextBlock x:Name="LblSleepSuppressed" Text="&#x25CF; Keeping PC awake"
                                 Foreground="#A6E3A1" FontSize="11"
                                 Visibility="Collapsed" Margin="0,0,14,0"/>
                      <TextBlock x:Name="LblGuardBlocked" Text=""
                                 Foreground="#FAB387" FontSize="11" Visibility="Collapsed"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                      <Button x:Name="BtnSnooze15" Content="+15m"
                              Style="{StaticResource SecondaryBtn}"
                              Padding="8,5" FontSize="12" Margin="0,0,6,0"/>
                      <Button x:Name="BtnSnooze30" Content="+30m"
                              Style="{StaticResource SecondaryBtn}"
                              Padding="8,5" FontSize="12" Margin="0,0,6,0"/>
                      <Button x:Name="BtnSnooze60" Content="+1h"
                              Style="{StaticResource SecondaryBtn}"
                              Padding="8,5" FontSize="12"/>
                    </StackPanel>
                  </StackPanel>
                </Grid>
              </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Row 1 is Auto and outside the ScrollViewer: always on screen. -->
            <StackPanel Grid.Row="1">
              <Rectangle Height="1" Fill="#313244" Margin="0,14,0,12"/>
              <TextBlock Text="QUICK ACTIONS" FontSize="10" Foreground="#6C7086"
                         FontWeight="SemiBold" Margin="0,0,0,10"/>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnMonitorOff" Content="Turn Off Monitor"
                        Style="{StaticResource SecondaryBtn}"
                        Padding="14,9" Margin="0,0,8,0"/>
                <Button x:Name="BtnLockScreen" Content="Lock Screen"
                        Style="{StaticResource SecondaryBtn}" Padding="14,9"/>
              </StackPanel>
            </StackPanel>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ══ Idle Tab ══ -->
      <!-- ══ Triggers Tab ══ -->
      <!--
        Replaces the old Idle tab: "wait for idle" is one kind of trigger, and
        two tabs that both mean "watch a condition then fire" would be
        incoherent. The idle evaluator is the v1 logic, unchanged.
      -->
      <TabItem Header="Triggers">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="WAIT FOR" FontSize="10" Foreground="#6C7086"
                     FontWeight="SemiBold" Margin="0,0,0,8"/>

          <ComboBox Grid.Row="1" x:Name="CmbTriggerKind" Height="34" Margin="0,0,0,14"
                    Background="#2A2A3E" Foreground="#CDD6F4" BorderBrush="#45475A"
                    VerticalContentAlignment="Center" FontSize="13">
            <ComboBoxItem Content="A process exits"/>
            <ComboBoxItem Content="Downloads finish"/>
            <ComboBoxItem Content="A signal file appears"/>
            <ComboBoxItem Content="Network / CPU go quiet"/>
            <ComboBoxItem Content="The PC goes idle"/>
          </ComboBox>

          <!-- Per-kind configuration; exactly one is visible at a time. -->
          <Grid Grid.Row="2" Margin="0,0,0,14">

            <StackPanel x:Name="CfgProcess" Visibility="Visible">
              <TextBlock Text="PROCESS NAMES  (comma separated, no .exe)" FontSize="10" Foreground="#6C7086" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <Border Background="#2A2A3E" CornerRadius="6" BorderBrush="#45475A"
                      BorderThickness="1" Height="34" Margin="0,0,0,8">
                <Grid>
                  <TextBox x:Name="TxtProcNames" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="13" Padding="10,0"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                  <TextBlock x:Name="TxtProcNamesPlaceholder" Text="e.g.  ffmpeg, HandBrake"
                             Foreground="#45475A" FontSize="13" Margin="11,0,0,0"
                             VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
              </Border>
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="RbProcAll" Content="all have exited" IsChecked="True"
                             Foreground="#BAC2DE" FontSize="12" Margin="0,0,14,0"/>
                <RadioButton x:Name="RbProcAny" Content="any one exits"
                             Foreground="#BAC2DE" FontSize="12"/>
              </StackPanel>
            </StackPanel>

            <StackPanel x:Name="CfgDownloads" Visibility="Collapsed">
              <TextBlock Text="WATCH FOLDER" FontSize="10" Foreground="#6C7086" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <Border Background="#2A2A3E" CornerRadius="6" BorderBrush="#45475A"
                      BorderThickness="1" Height="34" Margin="0,0,0,8">
                <TextBox x:Name="TxtDownloadPath" Background="Transparent" BorderThickness="0"
                         Foreground="#CDD6F4" FontSize="12" Padding="10,0"
                         VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
              </Border>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="settle" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="46" Height="24" Margin="8,0,8,0"
                        BorderBrush="#45475A" BorderThickness="1">
                  <TextBox x:Name="TxtSettleSec" Text="30" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="12" TextAlignment="Center"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                </Border>
                <TextBlock Text="s" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center" Margin="0,0,14,0"/>
                <CheckBox x:Name="ChkRecurse" Content="include subfolders" FontSize="12"/>
              </StackPanel>
            </StackPanel>

            <StackPanel x:Name="CfgSignal" Visibility="Collapsed">
              <TextBlock Text="SIGNAL FILE  (deleted when detected)" FontSize="10" Foreground="#6C7086" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <Border Background="#2A2A3E" CornerRadius="6" BorderBrush="#45475A"
                      BorderThickness="1" Height="34" Margin="0,0,0,6">
                <TextBox x:Name="TxtSignalPath" Background="Transparent" BorderThickness="0"
                         Foreground="#CDD6F4" FontSize="12" Padding="10,0"
                         VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
              </Border>
              <TextBlock Text="Any tool that can run a command can trigger this — see the README."
                         Foreground="#6C7086" FontSize="11" TextWrapping="Wrap"/>
            </StackPanel>

            <StackPanel x:Name="CfgResource" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <CheckBox x:Name="ChkResNet" Content="Network below" IsChecked="True" FontSize="12"
                          VerticalAlignment="Center"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="54" Height="24" Margin="8,0,6,0"
                        BorderBrush="#45475A" BorderThickness="1">
                  <TextBox x:Name="TxtResKbps" Text="100" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="12" TextAlignment="Center"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                </Border>
                <TextBlock Text="KB/s" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <CheckBox x:Name="ChkResCpu" Content="CPU below" FontSize="12" VerticalAlignment="Center"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="54" Height="24" Margin="8,0,6,0"
                        BorderBrush="#45475A" BorderThickness="1">
                  <TextBox x:Name="TxtResCpu" Text="10" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="12" TextAlignment="Center"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                </Border>
                <TextBlock Text="%" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="RbResAll" Content="all enabled" IsChecked="True"
                             Foreground="#BAC2DE" FontSize="12" Margin="0,0,12,0"/>
                <RadioButton x:Name="RbResAny" Content="any enabled"
                             Foreground="#BAC2DE" FontSize="12" Margin="0,0,14,0"/>
                <TextBlock Text="for" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center"/>
                <Border Background="#2A2A3E" CornerRadius="4" Width="50" Height="24" Margin="6,0,6,0"
                        BorderBrush="#45475A" BorderThickness="1">
                  <TextBox x:Name="TxtResSustain" Text="120" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="12" TextAlignment="Center"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                </Border>
                <TextBlock Text="s" Foreground="#BAC2DE" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
            </StackPanel>

            <StackPanel x:Name="CfgIdle" Visibility="Collapsed">
              <TextBlock Text="IDLE THRESHOLD" FontSize="10" Foreground="#6C7086" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <Border Background="#2A2A3E" CornerRadius="6" BorderBrush="#45475A"
                      BorderThickness="1" Height="34">
                <Grid>
                  <TextBox x:Name="TxtIdleTime" Background="Transparent" BorderThickness="0"
                           Foreground="#CDD6F4" FontSize="13" Padding="10,0"
                           VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
                  <TextBlock x:Name="TxtIdlePlaceholder" Text="e.g.  30m  &#183;  1h"
                             Foreground="#45475A" FontSize="13" Margin="11,0,0,0"
                             VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
              </Border>
            </StackPanel>
          </Grid>

          <TextBlock Grid.Row="3" Text="THEN" FontSize="10" Foreground="#6C7086"
                     FontWeight="SemiBold" Margin="0,0,0,8"/>

          <UniformGrid Grid.Row="4" Columns="4" Margin="0,0,0,14">
            <ToggleButton x:Name="TrgBtnShutdown" IsChecked="True" Content="Shutdown"
                          Style="{StaticResource ActionToggle}" Margin="0,0,4,0"/>
            <ToggleButton x:Name="TrgBtnRestart" Content="Restart"
                          Style="{StaticResource ActionToggle}" Margin="4,0,4,0"/>
            <ToggleButton x:Name="TrgBtnSleep" Content="Sleep"
                          Style="{StaticResource ActionToggle}" Margin="4,0,4,0"/>
            <ToggleButton x:Name="TrgBtnHibernate" Content="Hibernate"
                          Style="{StaticResource ActionToggle}" Margin="4,0,0,0"/>
          </UniformGrid>

          <!-- Status scrolls; the arm/disarm button stays pinned in row 6. -->
          <ScrollViewer Grid.Row="5" VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Disabled">
            <StackPanel>
              <Rectangle Height="1" Fill="#313244" Margin="0,0,0,12"/>
              <TextBlock Text="STATUS" FontSize="10" Foreground="#6C7086"
                         FontWeight="SemiBold" Margin="0,0,0,10"/>
              <TextBlock x:Name="LblTriggerState" Text="Not armed"
                         Foreground="#45475A" FontSize="13" Margin="0,0,0,4"/>
              <TextBlock x:Name="LblTriggerStatus" Text="" Foreground="#6C7086"
                         FontSize="12" TextWrapping="Wrap"/>

              <Border x:Name="PanelGrace" Background="#3A2A2E" CornerRadius="8"
                      Padding="16,12" Margin="0,12,0,0" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock x:Name="LblGraceHeadline" Text="Acting in 60s"
                             Foreground="#F38BA8" FontSize="20" FontWeight="Bold"/>
                  <TextBlock x:Name="LblGraceWhy" Text="" Foreground="#BAC2DE"
                             FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  <TextBlock Text="Move the mouse or press a key to cancel."
                             Foreground="#6C7086" FontSize="11" Margin="0,4,0,0"/>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Button x:Name="BtnGraceCancel" Content="Cancel"
                            Style="{StaticResource DangerBtn}" Padding="14,7" Margin="0,0,8,0"/>
                    <Button x:Name="BtnGraceSnooze" Content="Snooze 15m"
                            Style="{StaticResource SecondaryBtn}" Padding="14,7"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <Button Grid.Row="6" x:Name="BtnTriggerArm" Content="Arm Trigger"
                  Style="{StaticResource PrimaryBtn}" Height="42"
                  HorizontalAlignment="Stretch" Margin="0,14,0,0"/>
        </Grid>
      </TabItem>
      <TabItem Header="Scheduled">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="SCHEDULED ACTIONS" FontSize="10" Foreground="#6C7086"
                     FontWeight="SemiBold" Margin="0,0,0,10"/>

          <Border Grid.Row="1" Background="#2A2A3E" CornerRadius="8"
                  Margin="0,0,0,12" Padding="4">
            <ListView x:Name="LvScheduled" Background="Transparent" BorderThickness="0"
                      Foreground="#CDD6F4" VirtualizingPanel.IsVirtualizing="False"
                      ScrollViewer.HorizontalScrollBarVisibility="Disabled">
              <ListView.Resources>
                <Style TargetType="ListViewItem">
                  <Setter Property="Background" Value="Transparent"/>
                  <Setter Property="Foreground" Value="#CDD6F4"/>
                  <Setter Property="Padding" Value="8,6"/>
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="ListViewItem">
                        <Border x:Name="ItemBd" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                          <GridViewRowPresenter HorizontalAlignment="Stretch"/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="ItemBd" Property="Background" Value="#363655"/>
                          </Trigger>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="ItemBd" Property="Background" Value="#2D2D45"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                </Style>
              </ListView.Resources>
              <ListView.View>
                <GridView>
                  <GridView.ColumnHeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader">
                      <Setter Property="Background" Value="Transparent"/>
                      <Setter Property="Foreground" Value="#6C7086"/>
                      <Setter Property="BorderThickness" Value="0"/>
                      <Setter Property="Padding" Value="8,6"/>
                      <Setter Property="FontSize" Value="10"/>
                      <Setter Property="FontWeight" Value="SemiBold"/>
                      <Setter Property="Cursor" Value="Arrow"/>
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="GridViewColumnHeader">
                            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                              <TextBlock Text="{TemplateBinding Content}"
                                         Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                            </Border>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </GridView.ColumnHeaderContainerStyle>
                  <GridViewColumn Header="NAME" Width="230" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="NEXT RUN" Width="160" DisplayMemberBinding="{Binding NextRun}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </Border>

          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <Button x:Name="BtnAddSchedule" Content="+ Add"
                    Style="{StaticResource SecondaryBtn}" Padding="16,9" Margin="0,0,8,0"/>
            <Button x:Name="BtnRemoveSchedule" Content="- Remove"
                    Style="{StaticResource DangerBtn}" Padding="16,9"/>
          </StackPanel>
        </Grid>
      </TabItem>

    </TabControl>
  </Grid>
</Window>
'@
$script:XamlCache['ScheduleDialog.xaml'] = @'
<?xml version="1.0" encoding="utf-8"?>
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Add Scheduled Action"
    Width="340" Height="340"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterOwner"
    Background="#1E1E2E"
    FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6C7086"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="InputBox" TargetType="ComboBox">
      <Setter Property="Background" Value="#2A2A3E"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="DayToggle" TargetType="ToggleButton">
      <Setter Property="Background" Value="#2A2A3E"/>
      <Setter Property="Foreground" Value="#BAC2DE"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Width" Value="38"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#7C9DDA"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#7C9DDA"/>
                <Setter Property="Foreground" Value="#1E1E2E"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsChecked" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="Background" Value="#313244"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#7C9DDA"/>
      <Setter Property="Foreground" Value="#1E1E2E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#89B4FA"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#45475A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="ACTION" Style="{StaticResource FieldLabel}"/>
    <ComboBox Grid.Row="0" x:Name="CmbAction" Style="{StaticResource InputBox}" Margin="0,16,0,14">
      <ComboBoxItem Content="Shutdown" IsSelected="True"/>
      <ComboBoxItem Content="Restart"/>
      <ComboBoxItem Content="Sleep"/>
      <ComboBoxItem Content="Hibernate"/>
    </ComboBox>
    <TextBlock Grid.Row="1" Text="RECURRENCE" Style="{StaticResource FieldLabel}"/>
    <ComboBox Grid.Row="1" x:Name="CmbRecurrence" Style="{StaticResource InputBox}" Margin="0,16,0,14">
      <ComboBoxItem Content="Once" IsSelected="True"/>
      <ComboBoxItem Content="Daily"/>
      <ComboBoxItem Content="Weekly"/>
    </ComboBox>
    <StackPanel Grid.Row="2" x:Name="PanelDays" Visibility="Collapsed" Margin="0,0,0,14">
      <TextBlock Text="DAYS" Style="{StaticResource FieldLabel}"/>
      <StackPanel Orientation="Horizontal">
        <ToggleButton x:Name="DayMon" Content="Mo" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DayTue" Content="Tu" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DayWed" Content="We" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DayThu" Content="Th" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DayFri" Content="Fr" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DaySat" Content="Sa" Style="{StaticResource DayToggle}" Margin="0,0,4,0"/>
        <ToggleButton x:Name="DaySun" Content="Su" Style="{StaticResource DayToggle}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock Grid.Row="3" Text="TIME  (HH:MM — 24-hour)" Style="{StaticResource FieldLabel}"/>
    <Border Grid.Row="3" Background="#2A2A3E" CornerRadius="6"
            BorderBrush="#45475A" BorderThickness="1" Height="36" Margin="0,16,0,14">
      <TextBox x:Name="TxtDlgTime" Background="Transparent" Foreground="#CDD6F4"
               BorderThickness="0" Padding="10,0" FontSize="13"
               VerticalContentAlignment="Center" CaretBrush="#CDD6F4"/>
    </Border>
    <TextBlock Grid.Row="4" x:Name="LblDlgError" Text=""
               Foreground="#F38BA8" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnDlgCancel" Content="Cancel"
              Style="{StaticResource SecondaryBtn}" Padding="16,9" Margin="0,0,8,0"/>
      <Button x:Name="BtnDlgCreate" Content="Create"
              Style="{StaticResource PrimaryBtn}" Padding="20,9"/>
    </StackPanel>
  </Grid>
</Window>
'@

function Import-XamlDocument ([string]$Name) {
    if ($script:XamlCache.ContainsKey($Name)) { return [xml]$script:XamlCache[$Name] }
    $path = Join-Path $script:XamlRoot $Name
    if (-not (Test-Path $path)) { throw "XAML resource not found: $path" }
    return [xml](Get-Content $path -Raw -Encoding UTF8)
}

function New-XamlWindow ([string]$Name) {
    $doc = Import-XamlDocument $Name
    return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
}

# ═══ end UI\Xaml.ps1 ═══════════════════════════════════════════════
# ═══ begin UI\MainWindow.ps1 ═══════════════════════════════════════
<#
    UI/MainWindow.ps1 - the main window: control references, display helpers,
    and event wiring.

    Building the window is a side effect of dot-sourcing this file, so it must be
    sourced after UI/Xaml.ps1 and UI/Theme.ps1 and before UI/Tray.ps1 (which
    attaches to $window).
#>

$window = New-XamlWindow 'MainWindow.xaml'

# ── Control references ────────────────────────────────────────────────────────
$MainTabs           = $window.FindName('MainTabs')
$BtnShutdown        = $window.FindName('BtnShutdown')
$BtnRestart         = $window.FindName('BtnRestart')
$BtnSleep           = $window.FindName('BtnSleep')
$BtnHibernate       = $window.FindName('BtnHibernate')
$TxtTime            = $window.FindName('TxtTime')
$TxtPlaceholder     = $window.FindName('TxtPlaceholder')
$LblPreview         = $window.FindName('LblPreview')
$BtnStart           = $window.FindName('BtnStart')
$ChkNotify          = $window.FindName('ChkNotify')
$TxtNotifyMins      = $window.FindName('TxtNotifyMins')
$ChkGuardNetwork    = $window.FindName('ChkGuardNetwork')
$TxtNetKbps         = $window.FindName('TxtNetKbps')
$ChkGuardProcess    = $window.FindName('ChkGuardProcess')
$TxtProcessName     = $window.FindName('TxtProcessName')
$LblNoTimer         = $window.FindName('LblNoTimer')
$PanelActive        = $window.FindName('PanelActive')
$LblActiveType      = $window.FindName('LblActiveType')
$LblCountdown       = $window.FindName('LblCountdown')
$LblActiveTarget    = $window.FindName('LblActiveTarget')
$LblSleepSuppressed = $window.FindName('LblSleepSuppressed')
$LblGuardBlocked    = $window.FindName('LblGuardBlocked')
$BtnCancel          = $window.FindName('BtnCancel')
$BtnSnooze15        = $window.FindName('BtnSnooze15')
$BtnSnooze30        = $window.FindName('BtnSnooze30')
$BtnSnooze60        = $window.FindName('BtnSnooze60')
$BtnMonitorOff      = $window.FindName('BtnMonitorOff')
$BtnLockScreen      = $window.FindName('BtnLockScreen')
# ── Triggers tab ──
$CmbTriggerKind     = $window.FindName('CmbTriggerKind')
$CfgProcess         = $window.FindName('CfgProcess')
$CfgDownloads       = $window.FindName('CfgDownloads')
$CfgSignal          = $window.FindName('CfgSignal')
$CfgResource        = $window.FindName('CfgResource')
$CfgIdle            = $window.FindName('CfgIdle')
$TxtProcNames       = $window.FindName('TxtProcNames')
$TxtProcNamesPlaceholder = $window.FindName('TxtProcNamesPlaceholder')
$RbProcAll          = $window.FindName('RbProcAll')
$RbProcAny          = $window.FindName('RbProcAny')
$TxtDownloadPath    = $window.FindName('TxtDownloadPath')
$TxtSettleSec       = $window.FindName('TxtSettleSec')
$ChkRecurse         = $window.FindName('ChkRecurse')
$TxtSignalPath      = $window.FindName('TxtSignalPath')
$ChkResNet          = $window.FindName('ChkResNet')
$TxtResKbps         = $window.FindName('TxtResKbps')
$ChkResCpu          = $window.FindName('ChkResCpu')
$TxtResCpu          = $window.FindName('TxtResCpu')
$RbResAll           = $window.FindName('RbResAll')
$RbResAny           = $window.FindName('RbResAny')
$TxtResSustain      = $window.FindName('TxtResSustain')
$TxtIdleTime        = $window.FindName('TxtIdleTime')
$TxtIdlePlaceholder = $window.FindName('TxtIdlePlaceholder')
$TrgBtnShutdown     = $window.FindName('TrgBtnShutdown')
$TrgBtnRestart      = $window.FindName('TrgBtnRestart')
$TrgBtnSleep        = $window.FindName('TrgBtnSleep')
$TrgBtnHibernate    = $window.FindName('TrgBtnHibernate')
$LblTriggerState    = $window.FindName('LblTriggerState')
$LblTriggerStatus   = $window.FindName('LblTriggerStatus')
$PanelGrace         = $window.FindName('PanelGrace')
$LblGraceHeadline   = $window.FindName('LblGraceHeadline')
$LblGraceWhy        = $window.FindName('LblGraceWhy')
$BtnGraceCancel     = $window.FindName('BtnGraceCancel')
$BtnGraceSnooze     = $window.FindName('BtnGraceSnooze')
$BtnTriggerArm      = $window.FindName('BtnTriggerArm')
$LvScheduled        = $window.FindName('LvScheduled')
$BtnAddSchedule     = $window.FindName('BtnAddSchedule')
$BtnRemoveSchedule  = $window.FindName('BtnRemoveSchedule')

# ── UI-scope state ────────────────────────────────────────────────────────────
$script:selectedAction     = 'shutdown'
$script:triggerAction      = 'shutdown'
# Index order must match the ComboBoxItems in MainWindow.xaml.
$script:triggerKinds       = @('process', 'downloads', 'signal', 'resource', 'idle')
$script:actionVerbs        = @{ shutdown = 'shut down'; restart = 'restart'; sleep = 'sleep'; hibernate = 'hibernate' }

# ── Display helpers ───────────────────────────────────────────────────────────

function Show-ErrorBox ([string]$msg) {
    [System.Windows.MessageBox]::Show($msg, 'Timed Shutdown', 'OK', 'Warning') | Out-Null
}

# Enumerating scheduled tasks is a CIM query, so this is called on demand only --
# at startup, when the Scheduled tab is opened, and after an add/remove.
function Refresh-ScheduledList {
    $LvScheduled.Items.Clear()
    foreach ($item in (Get-ScheduledActionsList)) { $LvScheduled.Items.Add($item) | Out-Null }
}

function Refresh-ActiveTimer {
    $tracked = Get-TrackedAction
    if ($tracked) {
        $target    = [datetime]::Parse($tracked.targetAt).ToLocalTime()
        $remaining = $target - (Get-Date)
        if ($remaining.TotalSeconds -gt 0) {
            $LblActiveType.Text            = ([string]$tracked.type).ToUpper()
            $LblCountdown.Text             = Format-Countdown $remaining
            $LblActiveTarget.Text          = "fires at $($target.ToString('h:mm tt'))"
            $LblSleepSuppressed.Visibility = if (Test-KeepAwakeHeld) { 'Visible' } else { 'Collapsed' }
            $PanelActive.Visibility        = 'Visible'
            $LblNoTimer.Visibility         = 'Collapsed'
            return
        }
    }
    $LblSleepSuppressed.Visibility = 'Collapsed'
    $LblGuardBlocked.Visibility    = 'Collapsed'
    $PanelActive.Visibility        = 'Collapsed'
    $LblNoTimer.Visibility         = 'Visible'
}

function Update-Preview {
    $verb = $script:actionVerbs[$script:selectedAction]
    $LblPreview.Text       = Format-TargetTime $TxtTime.Text $verb
    $LblPreview.Foreground = if ($null -ne (ConvertTo-Seconds $TxtTime.Text)) {
        ConvertTo-Brush $script:COLOR_OK
    } else { ConvertTo-Brush $script:COLOR_MUTED }
}

function Set-ActionSelection ([string]$action) {
    $script:selectedAction = $action
    $map = @{ shutdown = $BtnShutdown; restart = $BtnRestart; sleep = $BtnSleep; hibernate = $BtnHibernate }
    foreach ($key in $map.Keys) { $map[$key].IsChecked = ($key -eq $action) }
    Update-Preview
}

function Set-TriggerActionSelection ([string]$action) {
    $script:triggerAction = $action
    $map = @{ shutdown = $TrgBtnShutdown; restart = $TrgBtnRestart; sleep = $TrgBtnSleep; hibernate = $TrgBtnHibernate }
    foreach ($key in $map.Keys) { $map[$key].IsChecked = ($key -eq $action) }
}

function Get-SelectedTriggerKind {
    $i = [math]::Max(0, $CmbTriggerKind.SelectedIndex)
    return $script:triggerKinds[$i]
}

# Exactly one configuration panel is visible at a time.
function Update-TriggerKindPanels {
    $kind  = Get-SelectedTriggerKind
    $panels = @{
        process = $CfgProcess; downloads = $CfgDownloads; signal = $CfgSignal
        resource = $CfgResource; idle = $CfgIdle
    }
    foreach ($k in $panels.Keys) {
        $panels[$k].Visibility = if ($k -eq $kind) { 'Visible' } else { 'Collapsed' }
    }
}

<#
    Builds the trigger config from the controls, or throws with a message the
    caller shows verbatim. Validation lives here so an invalid trigger can never
    be armed - an armed trigger that cannot fire is worse than a refusal.
#>
function Get-TriggerConfigFromUi {
    switch (Get-SelectedTriggerKind) {
        'process' {
            $names = @($TxtProcNames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($names.Count -eq 0) { throw 'Enter at least one process name.' }
            # Friendly: people type "ffmpeg.exe" out of habit.
            $names = @($names | ForEach-Object { $_ -replace '\.exe$', '' })
            return @{ Names = $names; Mode = $(if ($RbProcAny.IsChecked) { 'any' } else { 'all' }) }
        }
        'downloads' {
            $path = $TxtDownloadPath.Text.Trim()
            if (-not $path) { throw 'Choose a folder to watch.' }
            if (-not (Test-Path -LiteralPath $path)) { throw "Folder not found:`n$path" }
            $settle = 0
            if (-not [int]::TryParse($TxtSettleSec.Text.Trim(), [ref]$settle) -or $settle -lt 0) {
                throw 'Settle time must be a whole number of seconds.'
            }
            return @{ Path = $path; SettleSec = $settle; Recurse = [bool]$ChkRecurse.IsChecked }
        }
        'signal' {
            $path = $TxtSignalPath.Text.Trim()
            if (-not $path) { throw 'Enter a signal file path.' }
            $dir = Split-Path $path -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { throw "Folder does not exist:`n$dir" }
            if (Test-Path -LiteralPath $path) {
                throw "That signal file already exists.`n`nThe trigger fires when the file APPEARS, so it must not be there when you arm. Delete it first."
            }
            return @{ Path = $path }
        }
        'resource' {
            $netOn = [bool]$ChkResNet.IsChecked
            $cpuOn = [bool]$ChkResCpu.IsChecked
            if (-not $netOn -and -not $cpuOn) { throw 'Enable at least one of network or CPU.' }
            $kbps = 0.0; $cpu = 0.0; $sustain = 0
            if ($netOn -and -not [double]::TryParse($TxtResKbps.Text.Trim(), [ref]$kbps)) { throw 'Network threshold must be a number.' }
            if ($cpuOn -and -not [double]::TryParse($TxtResCpu.Text.Trim(), [ref]$cpu))   { throw 'CPU threshold must be a number.' }
            if (-not [int]::TryParse($TxtResSustain.Text.Trim(), [ref]$sustain) -or $sustain -lt 0) {
                throw 'Sustain time must be a whole number of seconds.'
            }
            return @{
                NetEnabled = $netOn; NetKbps = $kbps
                CpuEnabled = $cpuOn; CpuPercent = $cpu
                Match      = $(if ($RbResAny.IsChecked) { 'any' } else { 'all' })
                SustainSec = $sustain
            }
        }
        default {
            $sec = ConvertTo-Seconds $TxtIdleTime.Text
            if ($null -eq $sec) { throw "Invalid idle threshold.`nTry: 30m  ·  1h  ·  45m" }
            if ($sec -lt 30)    { throw 'Idle threshold must be at least 30 seconds.' }
            return @{ ThresholdSec = $sec }
        }
    }
}

# Reflects engine state into the Triggers tab. Called every tick.
function Update-TriggerDisplay {
    $t     = Get-Trigger
    $armed = Test-TriggerArmed

    $BtnTriggerArm.Content = if ($armed) { 'Disarm' } else { 'Arm Trigger' }
    $CmbTriggerKind.IsEnabled = -not $armed

    if (-not $armed) {
        $LblTriggerState.Text       = 'Not armed'
        $LblTriggerState.Foreground = ConvertTo-Brush $script:COLOR_MUTED
        $LblTriggerStatus.Text      = ''
        $PanelGrace.Visibility      = 'Collapsed'
        return
    }

    $verb = $script:actionVerbs[$t.Action]
    $LblTriggerState.Text       = "$($t.State) - will $verb"
    $LblTriggerState.Foreground = ConvertTo-Brush $(if ($t.State -eq 'GRACE') { $script:COLOR_WARN } else { $script:COLOR_OK })
    $LblTriggerStatus.Text      = $t.Status

    if ($t.State -eq 'GRACE') {
        $left = [math]::Max(0, $script:GRACE_SEC - (((Get-MonotonicMs) - $t.GraceStartTicks) / 1000))
        $LblGraceHeadline.Text = "$(($verb.Substring(0,1).ToUpper() + $verb.Substring(1))) in $([int]$left)s"
        $LblGraceWhy.Text      = "Trigger: $($t.Status)"
        $PanelGrace.Visibility = 'Visible'
    } else {
        $PanelGrace.Visibility = 'Collapsed'
    }
}

# Reads the guard checkboxes so Core/Guards.ps1 never has to touch the UI.
function Get-GuardSettings {
    return @{
        NetworkGuard  = [bool]$ChkGuardNetwork.IsChecked
        ThresholdKbps = [double]($TxtNetKbps.Text -as [double])
        ProcessGuard  = [bool]$ChkGuardProcess.IsChecked
        ProcessName   = [string]$TxtProcessName.Text
    }
}

# ── Event handlers ────────────────────────────────────────────────────────────

$BtnShutdown.Add_Click({  Set-ActionSelection 'shutdown'  })
$BtnRestart.Add_Click({   Set-ActionSelection 'restart'   })
$BtnSleep.Add_Click({     Set-ActionSelection 'sleep'     })
$BtnHibernate.Add_Click({ Set-ActionSelection 'hibernate' })

$TxtTime.Add_TextChanged({
    $TxtPlaceholder.Visibility = if ([string]::IsNullOrEmpty($TxtTime.Text)) { 'Visible' } else { 'Collapsed' }
    Update-Preview
})

$BtnStart.Add_Click({
    $sec = ConvertTo-Seconds $TxtTime.Text
    if ($null -eq $sec) { Show-ErrorBox "Invalid time format.`nTry: 1h30m  ·  45m  ·  2h  ·  22:30"; return }
    # Routed through the single chokepoint so a timer and a trigger can never
    # both start an action (I4).
    if (Invoke-PowerAction $script:selectedAction $sec 'timer') {
        $TxtTime.Text = ''
        $script:notifyFired = $false
        Save-TriggerSettings
    }
})

$BtnCancel.Add_Click({
    try { Stop-TimedAction; Refresh-ActiveTimer }
    catch { Show-ErrorBox "Failed to cancel: $_" }
})

$BtnSnooze15.Add_Click({ Add-SnoozeTime 900;  Refresh-ActiveTimer })
$BtnSnooze30.Add_Click({ Add-SnoozeTime 1800; Refresh-ActiveTimer })
$BtnSnooze60.Add_Click({ Add-SnoozeTime 3600; Refresh-ActiveTimer })

$BtnMonitorOff.Add_Click({ Invoke-MonitorOff })
$BtnLockScreen.Add_Click({ Invoke-LockScreen })

$TrgBtnShutdown.Add_Click({  Set-TriggerActionSelection 'shutdown'  })
$TrgBtnRestart.Add_Click({   Set-TriggerActionSelection 'restart'   })
$TrgBtnSleep.Add_Click({     Set-TriggerActionSelection 'sleep'     })
$TrgBtnHibernate.Add_Click({ Set-TriggerActionSelection 'hibernate' })

$CmbTriggerKind.Add_SelectionChanged({ Update-TriggerKindPanels })

$TxtProcNames.Add_TextChanged({
    $TxtProcNamesPlaceholder.Visibility =
        if ([string]::IsNullOrEmpty($TxtProcNames.Text)) { 'Visible' } else { 'Collapsed' }
})

$TxtIdleTime.Add_TextChanged({
    $TxtIdlePlaceholder.Visibility =
        if ([string]::IsNullOrEmpty($TxtIdleTime.Text)) { 'Visible' } else { 'Collapsed' }
})

<#
    Arming is always a live user action (I5) - nothing arms itself from state
    loaded off disk. Editing a trigger while armed is not supported: disarm
    first, so the trigger that is running is always the one you configured.
#>
$BtnTriggerArm.Add_Click({
    if (Test-TriggerArmed) {
        Stop-Trigger 'user'
        if (-not (Get-TrackedAction)) { Disable-KeepAwake }
        Update-TriggerDisplay
        return
    }
    try {
        $config = Get-TriggerConfigFromUi
    } catch {
        Show-ErrorBox $_.Exception.Message
        return
    }
    try {
        Start-Trigger (Get-SelectedTriggerKind) $script:triggerAction $config | Out-Null
        Enable-KeepAwake
        Save-TriggerSettings
        Update-TriggerDisplay
    } catch { Show-ErrorBox "Failed to arm trigger: $_" }
})

$BtnGraceCancel.Add_Click({
    if (Stop-TriggerGrace 'cancelled') { Update-TriggerDisplay }
})

$BtnGraceSnooze.Add_Click({
    if (Suspend-Trigger 900) { Update-TriggerDisplay }
})

# Refresh the task list when the Scheduled tab is opened rather than on a timer.
$MainTabs.Add_SelectionChanged({
    if ($MainTabs.SelectedIndex -eq 2) {
        try { Refresh-ScheduledList } catch {}
    }
})

$BtnAddSchedule.Add_Click({
    $res = Show-AddScheduleDialog $window
    if ($null -ne $res) {
        try {
            Add-ScheduledAction $res.ActionType $res.Recurrence $res.AtTime $res.DaysOfWeek | Out-Null
            Refresh-ScheduledList
        } catch { Show-ErrorBox "Failed to create scheduled task: $_" }
    }
})

$BtnRemoveSchedule.Add_Click({
    $selected = $LvScheduled.SelectedItem
    if ($null -eq $selected) { Show-ErrorBox 'Select a task from the list first.'; return }
    $confirm = [System.Windows.MessageBox]::Show(
        "Remove scheduled task '$($selected.Name)'?", 'Confirm Remove', 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        try {
            Unregister-ScheduledTask -TaskName $selected.Name `
                -TaskPath "$($script:TASK_FOLDER)\" -Confirm:$false -ErrorAction Stop
            Refresh-ScheduledList
        } catch { Show-ErrorBox "Failed to remove task: $_" }
    }
})

# ── Settings persistence ──────────────────────────────────────────────────────

<#
    Only preferences are persisted, never runtime trigger state. Reloading a
    "primed" or "grace" flag from disk could resurrect an armed destructive
    action across a restart (I5).
#>
function Save-TriggerSettings {
    try {
        Save-Settings @{
            notifyMins  = $TxtNotifyMins.Text
            netKbps     = $TxtNetKbps.Text
            processName = $TxtProcessName.Text
            lastAction  = $script:selectedAction
            trgKind     = $CmbTriggerKind.SelectedIndex
            trgAction   = $script:triggerAction
            trgProcs    = $TxtProcNames.Text
            trgProcMode = $(if ($RbProcAny.IsChecked) { 'any' } else { 'all' })
            trgDlPath   = $TxtDownloadPath.Text
            trgDlSettle = $TxtSettleSec.Text
            trgDlRec    = [bool]$ChkRecurse.IsChecked
            trgSigPath  = $TxtSignalPath.Text
            trgResNet   = [bool]$ChkResNet.IsChecked
            trgResKbps  = $TxtResKbps.Text
            trgResCpuOn = [bool]$ChkResCpu.IsChecked
            trgResCpu   = $TxtResCpu.Text
            trgResMatch = $(if ($RbResAny.IsChecked) { 'any' } else { 'all' })
            trgResSust  = $TxtResSustain.Text
            trgIdle     = $TxtIdleTime.Text
        }
    } catch {}
}

function Restore-Settings {
    try {
        $s = Get-Settings
        if ($s.notifyMins)  { $TxtNotifyMins.Text  = "$($s.notifyMins)" }
        if ($s.netKbps)     { $TxtNetKbps.Text     = "$($s.netKbps)" }
        if ($s.processName) { $TxtProcessName.Text = "$($s.processName)" }
        if ($s.lastAction)  { Set-ActionSelection "$($s.lastAction)" }

        if ($null -ne $s.trgKind)  { $CmbTriggerKind.SelectedIndex = [int]$s.trgKind }
        if ($s.trgAction)   { Set-TriggerActionSelection "$($s.trgAction)" }
        if ($s.trgProcs)    { $TxtProcNames.Text     = "$($s.trgProcs)" }
        if ($s.trgProcMode -eq 'any') { $RbProcAny.IsChecked = $true }
        if ($s.trgDlPath)   { $TxtDownloadPath.Text  = "$($s.trgDlPath)" }
        if ($s.trgDlSettle) { $TxtSettleSec.Text     = "$($s.trgDlSettle)" }
        if ($null -ne $s.trgDlRec)   { $ChkRecurse.IsChecked = [bool]$s.trgDlRec }
        if ($s.trgSigPath)  { $TxtSignalPath.Text    = "$($s.trgSigPath)" }
        if ($null -ne $s.trgResNet)  { $ChkResNet.IsChecked = [bool]$s.trgResNet }
        if ($s.trgResKbps)  { $TxtResKbps.Text       = "$($s.trgResKbps)" }
        if ($null -ne $s.trgResCpuOn) { $ChkResCpu.IsChecked = [bool]$s.trgResCpuOn }
        if ($s.trgResCpu)   { $TxtResCpu.Text        = "$($s.trgResCpu)" }
        if ($s.trgResMatch -eq 'any') { $RbResAny.IsChecked = $true }
        if ($s.trgResSust)  { $TxtResSustain.Text    = "$($s.trgResSust)" }
        if ($s.trgIdle)     { $TxtIdleTime.Text      = "$($s.trgIdle)" }
    } catch {}
}

# Sensible defaults for first run.
if (-not $TxtDownloadPath.Text) {
    $TxtDownloadPath.Text = Join-Path $env:USERPROFILE 'Downloads'
}
if (-not $TxtSignalPath.Text) {
    $TxtSignalPath.Text = Join-Path (Join-Path $env:LOCALAPPDATA 'TimedShutdown') 'signals\done.flag'
}
Update-TriggerKindPanels

# ═══ end UI\MainWindow.ps1 ═════════════════════════════════════════
# ═══ begin UI\ScheduleDialog.ps1 ═══════════════════════════════════
<#
    UI/ScheduleDialog.ps1 - modal "Add Scheduled Action" dialog.

    Returns a hashtable of the chosen settings, or $null when cancelled. Creating
    the task is the caller's job (Add-ScheduledAction in Core/Scheduler.ps1).
#>

function Show-AddScheduleDialog ([System.Windows.Window]$Owner) {
    $dlg       = New-XamlWindow 'ScheduleDialog.xaml'
    $dlg.Owner = $Owner

    $cmbAction     = $dlg.FindName('CmbAction')
    $cmbRecurrence = $dlg.FindName('CmbRecurrence')
    $panelDays     = $dlg.FindName('PanelDays')
    $txtDlgTime    = $dlg.FindName('TxtDlgTime')
    $lblDlgError   = $dlg.FindName('LblDlgError')
    $btnCreate     = $dlg.FindName('BtnDlgCreate')
    $btnDlgCancel  = $dlg.FindName('BtnDlgCancel')

    $dayToggles = @{
        Monday    = $dlg.FindName('DayMon')
        Tuesday   = $dlg.FindName('DayTue')
        Wednesday = $dlg.FindName('DayWed')
        Thursday  = $dlg.FindName('DayThu')
        Friday    = $dlg.FindName('DayFri')
        Saturday  = $dlg.FindName('DaySat')
        Sunday    = $dlg.FindName('DaySun')
    }

    # The day picker only applies to a weekly recurrence (index 2).
    $cmbRecurrence.Add_SelectionChanged({
        $panelDays.Visibility = if ($cmbRecurrence.SelectedIndex -eq 2) { 'Visible' } else { 'Collapsed' }
    })

    $actionMapDlg = @('shutdown','restart','sleep','hibernate')
    $recMapDlg    = @('once','daily','weekly')
    $script:dialogResult = $null

    $btnCreate.Add_Click({
        $lblDlgError.Text = ''
        $actionType = $actionMapDlg[$cmbAction.SelectedIndex]
        $recurrence = $recMapDlg[$cmbRecurrence.SelectedIndex]
        $atTime     = $txtDlgTime.Text.Trim()

        if ($atTime -notmatch '^\d{1,2}:\d{2}$') {
            $lblDlgError.Text = 'Please enter a valid 24-hour time  (e.g. 22:30)'
            return
        }
        try {
            $h = [int]($atTime -split ':')[0]; $m = [int]($atTime -split ':')[1]
            if ($h -gt 23 -or $m -gt 59) { throw }
            $atTime = '{0:D2}:{1:D2}' -f $h, $m
        } catch { $lblDlgError.Text = 'Invalid time value.'; return }

        $days = @()
        if ($recurrence -eq 'weekly') {
            $days = $dayToggles.GetEnumerator() | Where-Object { $_.Value.IsChecked } |
                    ForEach-Object { $_.Key }
            if ($days.Count -eq 0) {
                $lblDlgError.Text = 'Select at least one day for a weekly schedule.'
                return
            }
        }

        try {
            $script:dialogResult = @{
                ActionType = $actionType; Recurrence = $recurrence
                AtTime     = $atTime;     DaysOfWeek = $days
            }
            $dlg.DialogResult = $true; $dlg.Close()
        } catch { $lblDlgError.Text = "Error: $_" }
    })

    $btnDlgCancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    $ok = $dlg.ShowDialog()
    if ($ok -eq $true) { return $script:dialogResult }
    return $null
}

# ═══ end UI\ScheduleDialog.ps1 ═════════════════════════════════════
# ═══ begin UI\Tray.ps1 ═════════════════════════════════════════════
<#
    UI/Tray.ps1 - notification-area icon, context menu, and window lifecycle.

    Closing the window hides it instead; only the tray's Exit item really quits.
    Dot-source after UI/MainWindow.ps1, which creates $window.
#>

# A 16x16 bitmap we own outright, rather than depending on a shipped .ico.
$script:trayBitmap = New-Object System.Drawing.Bitmap(16, 16)
$_gfx = [System.Drawing.Graphics]::FromImage($script:trayBitmap)
$_gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$_brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 124, 157, 218))
$_gfx.FillEllipse($_brush, 1, 1, 13, 13)
$_brush.Dispose(); $_gfx.Dispose()
$script:trayIconHandle = $script:trayBitmap.GetHicon()
$script:trayIconObj    = [System.Drawing.Icon]::FromHandle($script:trayIconHandle)

$trayIcon         = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon    = $script:trayIconObj
$trayIcon.Text    = 'Timed Shutdown'
$trayIcon.Visible = $true

$ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
$mnuOpen = $ctxMenu.Items.Add('Open')
$ctxMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$mnuCancel = $ctxMenu.Items.Add('Cancel Timer / Disarm')
$mnuLog    = $ctxMenu.Items.Add('Open Log')
$ctxMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$mnuExit = $ctxMenu.Items.Add('Exit')
$trayIcon.ContextMenuStrip = $ctxMenu

$mnuOpen.add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
$trayIcon.add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })

$mnuCancel.add_Click({
    try {
        Stop-TimedAction
        Stop-Trigger 'tray'
        Disable-KeepAwake
        Refresh-ActiveTimer
        Update-TriggerDisplay
    } catch {}
})

$mnuLog.add_Click({
    try {
        $p = Get-LogFilePath
        if (Test-Path $p) { Start-Process notepad.exe -ArgumentList "`"$p`"" }
        else { [System.Windows.MessageBox]::Show('No log file yet.', 'Timed Shutdown', 'OK', 'Information') | Out-Null }
    } catch {}
})

$mnuExit.add_Click({ $script:exitApp = $true; $window.Close() })

# ── Window lifecycle ──────────────────────────────────────────────────────────

$window.Add_Loaded({
    # Re-register the icon now the WPF message loop is running; without this the
    # icon can fail to appear when the app starts minimised.
    $trayIcon.Visible = $false
    $trayIcon.Visible = $true

    try {
        $script:hotkeyMgr = New-Object WindowHotkeyManager
        $script:hotkeyMgr.Attach($window)
        $script:hotkeyMgr.add_MonitorOff({ Invoke-MonitorOff })
    } catch {}
})

$window.Add_StateChanged({
    if ($window.WindowState -eq 'Minimized') {
        $window.Hide()
        if ($script:firstMinimize) {
            $script:firstMinimize = $false
            $trayIcon.ShowBalloonTip(3000, 'Timed Shutdown',
                'Minimized to system tray  -  double-click the icon to restore',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

$window.Add_Closing({
    param($s, $e)
    if (-not $script:exitApp) {
        $e.Cancel = $true
        $window.Hide()
    }
})

$window.Add_Closed({
    try { if ($script:hotkeyMgr) { $script:hotkeyMgr.Detach($window) } } catch {}
    Disable-KeepAwake
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    # Icon.FromHandle wraps the handle without owning it, so disposing the wrapper
    # leaks the HICON. DestroyIcon is what actually releases it.
    try { $script:trayIconObj.Dispose() } catch {}
    try { [WinApi]::DestroyIcon($script:trayIconHandle) | Out-Null } catch {}
    try { $script:trayBitmap.Dispose() } catch {}
})

# ═══ end UI\Tray.ps1 ═══════════════════════════════════════════════

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
