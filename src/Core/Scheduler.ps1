#Requires -Version 5.1
<#
    Core/Scheduler.ps1 - Windows Task Scheduler entries under \TimedShutdown\.

    Two kinds of task live in this folder:
      TS_pending_*  one-shot backing for a sleep/hibernate countdown
      TS_<action>_* user-created schedules shown on the Schedule tab

    Everything here issues CIM calls, so none of it belongs on the dispatcher
    tick -- see Get-TrackedAction in Core/Power.ps1 for the once-a-second path.

    PRIVILEGE. Tasks are registered under the CURRENT USER by default, which
    needs no elevation: Authenticated Users hold Write on %WINDIR%\System32\Tasks.
    Builds up to 2.3 always used a SYSTEM principal, which does require
    elevation, and that single choice was the only reason the whole app demanded
    UAC. The SYSTEM form is still available, opt-in, for the one thing it buys --
    firing while nobody is signed in -- and is registered through an elevated
    child process rather than by elevating the app.
#>

$script:TASK_FOLDER = '\TimedShutdown'

# Well-known SID for NT AUTHORITY\SYSTEM. Task principals report either the name
# or the SID depending on how they were registered, so leftover-task detection
# has to match both.
$script:SYSTEM_SID = 'S-1-5-18'

function Ensure-TaskFolder {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $root = $svc.GetFolder('\')
    try { $root.GetFolder('TimedShutdown') | Out-Null }
    catch { $root.CreateFolder('TimedShutdown') | Out-Null }
}

<#
    The principal a task runs as -- the whole of this release's UAC story.

    Current user (default) needs no elevation and fires whenever that user is
    signed in. A LOCKED workstation still counts: the session exists, so the
    task runs. Only signing out stops it.

    SYSTEM fires regardless of who is signed in, and registering it REQUIRES
    elevation. That is the entire trade, and it is why this is a parameter
    rather than a constant.

    -RunLevel Limited is correct for the current-user form. SetSuspendState and
    shutdown.exe /s|/r|/h all run on a standard token (Users hold
    SeShutdownPrivilege by default), so asking for Highest would raise a UAC
    prompt to buy nothing.
#>
function New-TaskPrincipalFor ([bool]$WhenSignedOut = $false) {
    if ($WhenSignedOut) {
        return New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    return New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                                      -LogonType Interactive -RunLevel Limited
}

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
    Tasks in our folder that run as SYSTEM, which an unelevated process cannot
    remove.

    Builds up to 2.3 registered every task this way. After the switch to a
    current-user principal those leftovers remain, and Unregister-ScheduledTask
    on them fails with access denied -- which would mean Cancel silently not
    working on the very timer the user wants stopped. Callers use this to say so
    plainly rather than surfacing a raw CIM error.
#>
function Get-ElevatedLeftoverTask {
    @(Get-ScheduledTask -TaskPath "$($script:TASK_FOLDER)\" -ErrorAction SilentlyContinue |
      Where-Object {
          $u = $_.Principal.UserId
          $u -and ($u -eq $script:SYSTEM_SID -or $u -match '(?i)(^|\)system$')
      })
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

    # Always the current user, never SYSTEM: this task backs a countdown shown
    # in a window the user is looking at, so they are signed in by definition.
    # Asking for SYSTEM here would demand elevation to buy nothing.
    $p  = New-TaskPrincipalFor $false
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

<#
    Registers a user-visible schedule, returning the task name.

    $WhenSignedOut asks for a SYSTEM principal so the action fires even with
    nobody logged on. That needs elevation, so when this process is not
    elevated the registration is handed to an elevated child (see
    Register-TaskElevated) rather than elevating the whole app.
#>
function Add-ScheduledAction ([string]$ActionType, [string]$Recurrence, [string]$AtTime, [string[]]$DaysOfWeek = @(), [bool]$WhenSignedOut = $false) {
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
    $pr     = New-TaskPrincipalFor $WhenSignedOut
    $set    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit '00:05:00'

    if ($WhenSignedOut -and -not (Test-IsElevated)) {
        Register-TaskElevated -Name $name -ActionType $ActionType -Recurrence $Recurrence `
                              -AtTime $AtTime -DaysOfWeek $DaysOfWeek
        return $name
    }

    Register-ScheduledTask -TaskName $name -TaskPath "$($script:TASK_FOLDER)\" `
        -Action $taskAction -Trigger $trigger -Principal $pr -Settings $set -Force -ErrorAction Stop | Out-Null
    return $name
}

<#
    Registers a SYSTEM task through an elevated child process.

    Elevating the whole app to create one scheduled task is disproportionate, and
    an elevated window cannot accept drag-and-drop from Explorer, which would
    break the folder pickers. So the escalation is scoped to this one operation.

    schtasks.exe is driven by its OWN flags rather than by exported task XML.
    The obvious-looking route - build the task with New-ScheduledTask and hand
    over $task.XmlText - does not work: New-ScheduledTask returns a CimInstance
    with no XmlText property at all, so that code would have thrown the first
    time a user ticked the box. /RU SYSTEM /RL HIGHEST expresses the same intent
    natively, with no XML and no temp file.

    READING THE RESULT BACK IS THE POINT. schtasks reporting exit 0 is not
    evidence that a task exists, and this codebase has already shipped two bugs
    from trusting a success that had not happened. A declined UAC prompt (1223)
    is an ordinary "no" from the user, reported as such.
#>
function Register-TaskElevated {
    param(
        [string]   $Name,
        [string]   $ActionType,
        [string]   $Recurrence,
        [string]   $AtTime,
        [string[]] $DaysOfWeek = @()
    )
    $run = switch ($ActionType) {
        'shutdown'  { 'shutdown.exe /s /f' }
        'restart'   { 'shutdown.exe /r /f' }
        'sleep'     { 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0' }
        'hibernate' { 'shutdown.exe /h' }
        default     { throw "unknown action type '$ActionType'" }
    }

    # No hand-written quotes. PowerShell already quotes an argument containing
    # spaces; adding literal " characters makes schtasks read them as part of the
    # value and reject the task name outright.
    $taskArgs = @('/Create', '/TN', "$($script:TASK_FOLDER)\$Name", '/TR', $run,
                  '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/ST', $AtTime, '/F')

    switch ($Recurrence) {
        'once' {
            # schtasks wants /SD as literal mm/dd/yyyy and rejects anything else
            # ("Invalid Start Date"), so this is deliberately InvariantCulture
            # and NOT the machine short-date format - the opposite of the usual
            # rule in this codebase, and verified against schtasks directly.
            $taskArgs += @('/SC', 'ONCE', '/SD',
                (Resolve-ScheduleTime $AtTime 'once').ToString('MM/dd/yyyy',
                    [System.Globalization.CultureInfo]::InvariantCulture))
        }
        'daily'  { $taskArgs += @('/SC', 'DAILY') }
        'weekly' {
            if (-not $DaysOfWeek -or @($DaysOfWeek).Count -eq 0) {
                throw 'A weekly schedule needs at least one day.'
            }
            $days = (@($DaysOfWeek) | ForEach-Object { $_.Substring(0, 3).ToUpperInvariant() }) -join ','
            $taskArgs += @('/SC', 'WEEKLY', '/D', $days)
        }
        default { throw "unknown recurrence '$Recurrence'" }
    }

    $proc = Start-Process -FilePath 'schtasks.exe' -Verb RunAs -Wait -PassThru `
                          -WindowStyle Hidden -ArgumentList $taskArgs
    if ($proc.ExitCode -eq 1223) {
        throw 'Administrator approval was declined, so the schedule was not created.'
    }

    $check = Get-ScheduledTask -TaskName $Name -TaskPath "$($script:TASK_FOLDER)\" -ErrorAction SilentlyContinue
    if (-not $check) {
        throw "schtasks exited $($proc.ExitCode) but no task was created."
    }
}

<#
    Removes SYSTEM-principal leftovers via one elevated schtasks call.

    Same verify-don't-trust rule: the caller is told what actually went, not
    what was attempted.
#>
function Remove-TaskElevated ([string[]]$Names) {
    if (-not $Names -or $Names.Count -eq 0) { return @() }
    # One elevated shell, one prompt, all deletions.
    # Here the quotes ARE needed: this string is parsed by cmd.exe, not by
    # PowerShell's argument builder, and a task path could contain a space.
    $cmd  = ($Names | ForEach-Object { "schtasks /Delete /TN `"$($script:TASK_FOLDER)\$_`" /F" }) -join ' & '
    $proc = Start-Process -FilePath 'cmd.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                -ArgumentList @('/c', $cmd)
    if ($proc.ExitCode -eq 1223) { throw 'Administrator approval was declined; nothing was removed.' }

    $remaining = @(Get-ElevatedLeftoverTask | ForEach-Object { $_.TaskName })
    return $remaining
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
