#Requires -Version 5.1
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
