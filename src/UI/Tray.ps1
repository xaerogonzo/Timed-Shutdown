#Requires -Version 5.1
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
