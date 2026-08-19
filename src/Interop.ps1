#Requires -Version 5.1
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
