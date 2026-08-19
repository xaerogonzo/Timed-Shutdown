#Requires -Version 5.1
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
