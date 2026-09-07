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
$mnuStartup = $ctxMenu.Items.Add('Start with Windows')
$ctxMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$mnuExit = $ctxMenu.Items.Add('Exit')
$trayIcon.ContextMenuStrip = $ctxMenu

# ── Start with Windows ────────────────────────────────────────────────────────
<#
    A per-user Run entry. HKCU, so no elevation: consistent with the rest of 2.4,
    where the app asks for administrator rights only when something genuinely
    needs them.

    The value is the launcher, not the .ps1, so the entry keeps working the same
    way a double-click does.
#>
$script:RUN_KEY  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RUN_NAME = 'TimedShutdown'

function Get-StartupCommand {
    return '"{0}"' -f (Join-Path $script:AppRoot 'TimedShutdown.bat')
}

function Test-StartupEnabled {
    try {
        $v = Get-ItemProperty -Path $script:RUN_KEY -Name $script:RUN_NAME -ErrorAction Stop
        return [bool]$v.$($script:RUN_NAME)
    } catch { return $false }
}

<#
    Writes or removes the Run entry, and reports what the registry ACTUALLY says
    afterwards rather than what was attempted.

    Set-ItemProperty failing is not hypothetical - policy can lock this key - and
    a menu tick that lies about whether the app will start at boot is the same
    class of defect as a cancel that claims to have worked.
#>
function Set-StartupEnabled ([bool]$Enabled) {
    if ($Enabled) {
        Set-ItemProperty -Path $script:RUN_KEY -Name $script:RUN_NAME `
                         -Value (Get-StartupCommand) -ErrorAction Stop
    } else {
        Remove-ItemProperty -Path $script:RUN_KEY -Name $script:RUN_NAME -ErrorAction SilentlyContinue
    }
    return (Test-StartupEnabled)
}

$mnuStartup.Checked = Test-StartupEnabled
$mnuStartup.add_Click({
    $wanted = -not $mnuStartup.Checked
    try {
        $actual = Set-StartupEnabled $wanted
        $mnuStartup.Checked = $actual
        if ($actual -ne $wanted) {
            Show-ErrorBox 'Windows did not accept the change to the startup entry.'
        } else {
            Write-Log 'settings' 'startup' "enabled=$actual"
        }
    } catch {
        $mnuStartup.Checked = Test-StartupEnabled
        Show-ErrorBox "Could not change the startup setting:`n`n$($_.Exception.Message)"
    }
})

$mnuOpen.add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
$trayIcon.add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })

$mnuCancel.add_Click({
    # The steps are independent: a failed timer cancel must not stop the trigger
    # being disarmed, and one shared catch{} previously meant it did -- while
    # also hiding the failure entirely.
    #
    # Stop-TimedAction now throws when a cancel genuinely failed rather than
    # reporting success, and that has to reach the user. The whole point is that
    # nobody should walk away from the machine believing a shutdown was called
    # off when it was not.
    $problems = @()
    try { Stop-TimedAction }    catch { $problems += "timer: $($_.Exception.Message)" }

    # Not a bare catch{}: a disarm that failed leaves the trigger ARMED and still
    # able to fire, which is precisely the thing the user just asked to stop.
    try { Stop-Trigger 'tray' } catch { $problems += "trigger: $($_.Exception.Message)" }

    # Only release the keep-awake request if nothing is actually pending; a
    # failed cancel means something still is.
    if (-not (Get-TrackedAction)) { Disable-KeepAwake }

    Refresh-ActiveTimer
    Update-TriggerDisplay

    if ($problems.Count -gt 0) {
        Show-ErrorBox ("Could not fully cancel:`n`n" + ($problems -join "`n"))
    }
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
