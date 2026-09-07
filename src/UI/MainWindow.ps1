#Requires -Version 5.1
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
$CmbProcPick        = $window.FindName('CmbProcPick')
$ChkProcBackground  = $window.FindName('ChkProcBackground')
$TxtDownloadPath    = $window.FindName('TxtDownloadPath')
$BtnBrowseDownload  = $window.FindName('BtnBrowseDownload')
$TxtSettleSec       = $window.FindName('TxtSettleSec')
$ChkRecurse         = $window.FindName('ChkRecurse')
$TxtSignalName      = $window.FindName('TxtSignalName')
$BtnCopySignalCmd   = $window.FindName('BtnCopySignalCmd')
$LblSignalResolved  = $window.FindName('LblSignalResolved')
$ChkSignalAdvanced  = $window.FindName('ChkSignalAdvanced')
$PanelSignalPath    = $window.FindName('PanelSignalPath')
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
$BtnCleanupLegacy   = $window.FindName('BtnCleanupLegacy')
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

<#
    Where a named signal lives.

    Deliberately the same folder tools\TimedShutdown-signal.cmd writes to. The
    name is the contract between the two: a user types "done" here and runs
    "TimedShutdown-signal.cmd done" from a script, and neither side has to know
    the path. Get-SignalPath is the single place that mapping exists.
#>
# Test seam, same shape as Set-StateFilePath / Set-LogFilePath: a test must be
# able to resolve signal paths without touching a live install.
$script:SIGNAL_DIR = $null
function Set-SignalDir ([string]$Path) { $script:SIGNAL_DIR = $Path }

function Get-SignalDir {
    if ($script:SIGNAL_DIR) { return $script:SIGNAL_DIR }
    return Join-Path (Join-Path $env:LOCALAPPDATA 'TimedShutdown') 'signals'
}

<#
    Creates the signal folder if it is not there yet.

    Without this, arming a named signal on a fresh install was REFUSED with
    "Folder does not exist" - the folder is only created when the signal tool
    first runs, and the whole point is to arm the trigger BEFORE the job that
    signals it. It passed in development purely because the folder already
    existed on that machine; CI on a clean runner caught it.

    -ErrorAction Stop is load-bearing: New-Item reports a bad path as a
    NON-terminating error, so without it the caller's try/catch never fires and
    validation would pass on a folder that was never created.
#>
function Initialize-SignalDir {
    $dir = Get-SignalDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    return $dir
}

function Get-SignalPath ([string]$Name) {
    return Join-Path (Get-SignalDir) "$Name.flag"
}

# The name goes into a filename, so refuse anything that is not one. Rejecting
# early beats a confusing failure when the trigger tries to watch the path.
function Test-SignalName ([string]$Name) {
    if (-not $Name) { return $false }
    if ($Name.Length -gt 64) { return $false }
    return $Name -match '^[A-Za-z0-9._-]+$'
}

<#
    The signal file the UI is currently configured for, honouring the
    advanced "use a full path instead" escape hatch.
#>
function Get-ConfiguredSignalPath {
    if ($ChkSignalAdvanced.IsChecked) { return $TxtSignalPath.Text.Trim() }
    return Get-SignalPath ($TxtSignalName.Text.Trim())
}

function Update-SignalDisplay {
    $advanced = [bool]$ChkSignalAdvanced.IsChecked
    $PanelSignalPath.Visibility = if ($advanced) { 'Visible' } else { 'Collapsed' }
    $BtnCopySignalCmd.IsEnabled = -not $advanced

    if ($advanced) {
        $LblSignalResolved.Text = ''
        return
    }
    $name = $TxtSignalName.Text.Trim()
    $LblSignalResolved.Text = if (Test-SignalName $name) {
        Get-SignalPath $name
    } else {
        'Use letters, digits, dot, dash or underscore.'
    }
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
            if (-not $ChkSignalAdvanced.IsChecked) {
                if (-not (Test-SignalName $TxtSignalName.Text.Trim())) {
                    throw "Enter a signal name using letters, digits, dot, dash or underscore.`n`nFor example:  done"
                }
                # The app owns this folder, so it creates it rather than refusing.
                # A full path typed by the user is a different matter: that one is
                # still checked, never created.
                try { Initialize-SignalDir | Out-Null }
                catch { throw "Could not create the signal folder:`n$($_.Exception.Message)" }
            }
            $path = Get-ConfiguredSignalPath
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

<#
    Add-SnoozeTime returns $false when the re-arm failed. By then the original
    timer is already cancelled and the pending state cleared, so the panel simply
    disappears -- which on its own looks exactly like a successful cancel. Say
    what actually happened instead.

    The Get-TrackedAction check first separates that from the harmless race where
    the timer expired between the panel rendering and the click landing; there is
    nothing to report in that case.
#>
function Invoke-Snooze ([int]$ExtraSec) {
    if (-not (Get-TrackedAction)) { Refresh-ActiveTimer; return }

    $extended = Add-SnoozeTime $ExtraSec
    Refresh-ActiveTimer
    if (-not $extended) {
        Show-ErrorBox ("Could not extend the timer.`n`n" +
                       "The pending action was cancelled and could not be re-armed, " +
                       "so nothing is scheduled now. See the log for details.")
    }
}

$BtnSnooze15.Add_Click({ Invoke-Snooze 900  })
$BtnSnooze30.Add_Click({ Invoke-Snooze 1800 })
$BtnSnooze60.Add_Click({ Invoke-Snooze 3600 })

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

# ── Process picker ────────────────────────────────────────────────────────────

<#
    Refills the picker from the live process list.

    Bound to DropDownOpened, NOT to the dispatcher tick: enumerating processes
    costs 50-150 ms, and the tick has a hard rule against work of that size. It
    also means the list is always current at the moment it is read, with no
    cache to go stale.
#>
function Update-ProcessPicker {
    $prompt = [PSCustomObject]@{ Name = ''; Display = 'Pick a running process…' }
    $rows   = @()
    try {
        $rows = @(Get-ProcessChoices (Get-Process -ErrorAction SilentlyContinue) `
                                     ([bool]$ChkProcBackground.IsChecked))
    } catch {}

    # ItemTemplate comes from the markup; setting DisplayMemberPath as well
    # would throw, and would not fix the closed box in any case.
    $CmbProcPick.ItemsSource   = @($prompt) + $rows
    $CmbProcPick.SelectedIndex = 0
}

<#
    Appends the picked name to the text box.

    The box stays the source of truth - the picker only saves typing - so this
    de-duplicates against what is already there rather than replacing it, and
    resets the selection so the control reads as an action rather than a
    current value.
#>
function Add-PickedProcess {
    $item = $CmbProcPick.SelectedItem
    if (-not $item -or -not $item.Name) { return }

    $existing = @($TxtProcNames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($existing -notcontains $item.Name) {
        $existing += $item.Name
        $TxtProcNames.Text = ($existing -join ', ')
    }
    $CmbProcPick.SelectedIndex = 0
}

# Seed with just the prompt so the control reads as a labelled action rather
# than an empty box. The real list is built on open.
$CmbProcPick.ItemsSource   = @([PSCustomObject]@{ Name = ''; Display = 'Pick a running process…' })
$CmbProcPick.SelectedIndex = 0

$CmbProcPick.Add_DropDownOpened({ Update-ProcessPicker })
$CmbProcPick.Add_SelectionChanged({ Add-PickedProcess })
$ChkProcBackground.Add_Click({ Update-ProcessPicker })

# ── Path pickers ──────────────────────────────────────────────────────────────
# The app no longer runs elevated, so these dialogs can interact with an
# unelevated Explorer normally. Validation stays in Get-TriggerConfigFromUi:
# a picker is a convenience, never a second source of truth.

$BtnBrowseDownload.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Folder to watch for downloads'
    $current = $TxtDownloadPath.Text.Trim()
    if ($current -and (Test-Path -LiteralPath $current)) { $dlg.SelectedPath = $current }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TxtDownloadPath.Text = $dlg.SelectedPath
    }
    $dlg.Dispose()
})

$ChkSignalAdvanced.Add_Click({ Update-SignalDisplay })
$TxtSignalName.Add_TextChanged({ Update-SignalDisplay })

<#
    Puts the exact command on the clipboard.

    The whole point of naming signals is that the user never has to reason about
    where the flag file goes; handing them the literal line to paste into a hook
    or build script is what closes that loop.
#>
$BtnCopySignalCmd.Add_Click({
    $name = $TxtSignalName.Text.Trim()
    if (-not (Test-SignalName $name)) {
        Show-ErrorBox "Enter a signal name first.`n`nLetters, digits, dot, dash or underscore - for example:  done"
        return
    }
    $tool = Join-Path $script:AppRoot 'tools\TimedShutdown-signal.cmd'
    try {
        [System.Windows.Clipboard]::SetText("`"$tool`" $name")
        $LblSignalResolved.Text = 'Copied. Paste it wherever your job finishes.'
    } catch {
        Show-ErrorBox "Could not write to the clipboard: $($_.Exception.Message)"
    }
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
        try { Refresh-ScheduledList }        catch {}
        try { Update-LegacyCleanupButton }   catch {}
    }
})

$BtnAddSchedule.Add_Click({
    $res = Show-AddScheduleDialog $window
    if ($null -ne $res) {
        try {
            Add-ScheduledAction $res.ActionType $res.Recurrence $res.AtTime $res.DaysOfWeek `
                                $res.WhenSignedOut | Out-Null
            Refresh-ScheduledList
        } catch { Show-ErrorBox "Failed to create scheduled task: $_" }
    }
})

<#
    Shows the cleanup button only when leftovers actually exist.

    Called when the Scheduled tab is opened rather than on a timer: enumerating
    tasks is a CIM query and has no business on the dispatcher tick.
#>
function Update-LegacyCleanupButton {
    try {
        $leftovers = @(Get-ElevatedLeftoverTask)
        $BtnCleanupLegacy.Visibility = if ($leftovers.Count -gt 0 -and -not $script:isElevated) {
            'Visible'
        } else { 'Collapsed' }
    } catch { $BtnCleanupLegacy.Visibility = 'Collapsed' }
}

$BtnCleanupLegacy.Add_Click({
    $leftovers = @(Get-ElevatedLeftoverTask)
    if ($leftovers.Count -eq 0) { Update-LegacyCleanupButton; return }

    $names = @($leftovers | ForEach-Object { $_.TaskName })
    $confirm = [System.Windows.MessageBox]::Show(
        ("These tasks were created by an older version running as administrator:`n`n  " +
         ($names -join "`n  ") +
         "`n`nRemoving them needs administrator approval once. Continue?"),
        'Remove leftover tasks', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    try {
        # Returns what is STILL there, so the report describes the end state
        # rather than the attempt.
        $remaining = @(Remove-TaskElevated $names)
        Update-LegacyCleanupButton
        Refresh-ScheduledList
        if ($remaining.Count -gt 0) {
            Show-ErrorBox ("Some tasks could not be removed:`n`n  " + ($remaining -join "`n  "))
        }
    } catch {
        Show-ErrorBox "Cleanup failed: $($_.Exception.Message)"
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
            trgProcBg   = [bool]$ChkProcBackground.IsChecked
            trgSigName  = $TxtSignalName.Text
            trgSigAdv   = [bool]$ChkSignalAdvanced.IsChecked
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
        if ($null -ne $s.trgProcBg) { $ChkProcBackground.IsChecked = [bool]$s.trgProcBg }
        if ($s.trgSigName)  { $TxtSignalName.Text    = "$($s.trgSigName)" }
        if ($null -ne $s.trgSigAdv) { $ChkSignalAdvanced.IsChecked = [bool]$s.trgSigAdv }
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
if (-not $TxtSignalName.Text) { $TxtSignalName.Text = 'done' }
if (-not $TxtSignalPath.Text) {
    # Only the advanced escape hatch uses this; seeding it from the same folder
    # means switching to it shows something meaningful rather than an empty box.
    $TxtSignalPath.Text = Get-SignalPath 'done'
}
Update-SignalDisplay
Update-TriggerKindPanels
