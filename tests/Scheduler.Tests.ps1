#Requires -Version 5.1
<#
    Tests for the pure logic in Core/Scheduler.ps1.

    Nothing here registers, queries or removes a scheduled task. Everything that
    touches Task Scheduler is a CIM call and stays verified by hand, per
    docs/ARCHITECTURE.md -- these cover the two decisions made BEFORE any of that
    happens: which instant a schedule resolves to, and what the task is called.

    Resolve-ScheduleTime takes an injectable $Now. Without it these tests would
    depend on the clock of the machine running them: "22:30 has already passed"
    is only true after 22:30, so the regression below would pass or fail
    according to the time of day.

    NB: BeforeEach must live inside a Describe. Pester 6 rejects test setup
    declared directly in the file's root block.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Core\Scheduler.ps1"

    # Today's date at a given clock reading -- the same anchoring ParseExact
    # applies when it is handed a time with no date.
    function At ([int]$Hour, [int]$Minute) {
        $t = Get-Date
        return (Get-Date -Year $t.Year -Month $t.Month -Day $t.Day `
                    -Hour $Hour -Minute $Minute -Second 0 -Millisecond 0)
    }
}

Describe 'Resolve-ScheduleTime - once' {

    <#
        Regression, fixed in v2.0 and never covered until now.

        The time was anchored to today with no rollover, so a 'once' schedule for
        a moment that had already passed was registered in the past and simply
        never fired. The user got a task that looked correct in the list and did
        nothing.
    #>
    It 'rolls to tomorrow when the time has already passed today' {
        $now = At 23 0
        $r   = Resolve-ScheduleTime '22:30' 'once' $now

        $r.Date   | Should -Be $now.Date.AddDays(1)
        $r.Hour   | Should -Be 22
        $r.Minute | Should -Be 30
    }

    It 'stays today when the time is still ahead' {
        $now = At 8 0
        $r   = Resolve-ScheduleTime '22:30' 'once' $now

        $r.Date   | Should -Be $now.Date
        $r.Hour   | Should -Be 22
        $r.Minute | Should -Be 30
    }

    # -le, not -lt: a schedule for the current minute has effectively passed, and
    # registering it for right now is a race the user cannot win.
    It 'rolls when the time is exactly now' {
        $now = At 22 30
        (Resolve-ScheduleTime '22:30' 'once' $now).Date | Should -Be $now.Date.AddDays(1)
    }

    It 'stays today one minute before the time' {
        $now = At 22 29
        (Resolve-ScheduleTime '22:30' 'once' $now).Date | Should -Be $now.Date
    }

    It 'handles midnight' {
        $now = At 12 0
        $r   = Resolve-ScheduleTime '00:00' 'once' $now

        # 00:00 today is behind midday, so it rolls.
        $r.Date | Should -Be $now.Date.AddDays(1)
        $r.Hour | Should -Be 0
    }
}

Describe 'Resolve-ScheduleTime - recurring' {

    # Daily and weekly triggers roll over by themselves; moving the anchor would
    # shift the whole series by a day.
    It 'never rolls a daily schedule, even for a time already past' {
        $now = At 23 0
        (Resolve-ScheduleTime '22:30' 'daily' $now).Date | Should -Be $now.Date
    }

    It 'never rolls a weekly schedule, even for a time already past' {
        $now = At 23 0
        (Resolve-ScheduleTime '22:30' 'weekly' $now).Date | Should -Be $now.Date
    }
}

Describe 'Resolve-ScheduleTime - parsing' {

    It 'reads a 24-hour clock, not a 12-hour one' {
        $r = Resolve-ScheduleTime '18:45' 'daily' (At 0 0)
        $r.Hour   | Should -Be 18
        $r.Minute | Should -Be 45
    }

    It 'accepts a leading-zero hour' {
        $r = Resolve-ScheduleTime '09:05' 'daily' (At 0 0)
        $r.Hour   | Should -Be 9
        $r.Minute | Should -Be 5
    }

    # ParseExact with InvariantCulture, so the result does not depend on the
    # machine's locale -- the same failure class as the English-only powercfg
    # parse fixed in v2.0 and the localized counter names avoided in v2.2.
    It 'parses identically under a culture that formats times differently' {
        $original = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $r = Resolve-ScheduleTime '18:45' 'daily' (At 0 0)
            $r.Hour   | Should -Be 18
            $r.Minute | Should -Be 45
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    # The dialog validates the format before calling, so this documents the
    # contract rather than a path a user can reach.
    It 'throws on a time it cannot parse' {
        { Resolve-ScheduleTime 'half past ten' 'once' (At 0 0) } | Should -Throw
    }
}

Describe 'Get-ScheduledTaskName' {

    It 'names a one-off with action, recurrence and time' {
        Get-ScheduledTaskName 'shutdown' 'once' '22:30' | Should -Be 'TS_shutdown_once_2230'
    }

    It 'names a daily schedule' {
        Get-ScheduledTaskName 'restart' 'daily' '07:00' | Should -Be 'TS_restart_daily_0700'
    }

    It 'appends the selected days for a weekly schedule' {
        Get-ScheduledTaskName 'sleep' 'weekly' '23:15' @('Monday','Tuesday') |
            Should -Be 'TS_sleep_weekly_MondayTuesday_2315'
    }

    It 'omits the day segment when no days are given' {
        Get-ScheduledTaskName 'hibernate' 'once' '01:00' @() | Should -Be 'TS_hibernate_once_0100'
    }

    It 'handles a single day' {
        Get-ScheduledTaskName 'shutdown' 'weekly' '18:00' @('Friday') |
            Should -Be 'TS_shutdown_weekly_Friday_1800'
    }

    # The colon is stripped because it is not legal in a Task Scheduler name.
    It 'strips the colon from the time' {
        Get-ScheduledTaskName 'shutdown' 'once' '09:05' | Should -Not -Match ':'
    }

    It 'is stable for the same inputs' {
        $a = Get-ScheduledTaskName 'shutdown' 'weekly' '22:30' @('Monday','Friday')
        $b = Get-ScheduledTaskName 'shutdown' 'weekly' '22:30' @('Monday','Friday')
        $a | Should -Be $b
    }

    <#
        Every user schedule carries the TS_ prefix, and Get-ScheduledActionsList
        filters the one-shot backing tasks out by matching '^TS_pending_'. A name
        that collided with that prefix would hide the schedule from the tab it
        was created on.
    #>
    It 'never collides with the TS_pending_ prefix reserved for timer backing tasks' {
        foreach ($action in 'shutdown','restart','sleep','hibernate') {
            foreach ($rec in 'once','daily','weekly') {
                Get-ScheduledTaskName $action $rec '22:30' | Should -Not -Match '^TS_pending_'
            }
        }
    }
}

<#
    The elevated registration path, pinned by its arguments.

    It cannot be exercised end to end in a test - it deliberately raises a UAC
    prompt - so the argument vector is asserted instead. That is where both of
    its real bugs lived, and neither was visible by reading the code:

      * hand-written quotes around /TN and /TR were passed to schtasks as
        LITERAL quote characters, and it rejected the task name with "The
        filename, directory name, or volume label syntax is incorrect";
      * /SD built from the machine short-date format was rejected with "Invalid
        Start Date (Date should be in mm/dd/yyyy format)".

    Both were found by running schtasks directly. This test is what keeps them
    found.
#>
Describe 'Register-TaskElevated argument construction' {

    BeforeAll {
        . "$PSScriptRoot\..\src\Core\Scheduler.ps1"

        # Capture the argument vector instead of raising a UAC prompt.
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $Verb, $WindowStyle)
            $script:spFile = $FilePath
            $script:spArgs = @($ArgumentList)
            return [PSCustomObject]@{ ExitCode = 0 }
        }
        function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction)
            [PSCustomObject]@{ TaskName = $TaskName } }

        function Get-Args ([string]$Rec, [string[]]$Days = @()) {
            $script:spArgs = $null
            Register-TaskElevated -Name 'TS_x' -ActionType 'shutdown' -Recurrence $Rec `
                                  -AtTime '22:30' -DaysOfWeek $Days
            return $script:spArgs
        }
    }

    It 'runs schtasks.exe, not an elevated copy of the app' {
        Get-Args 'daily' | Out-Null
        $script:spFile | Should -Be 'schtasks.exe'
    }

    It 'asks for a SYSTEM principal - the whole reason it elevates' {
        $a = Get-Args 'daily'
        $a | Should -Contain 'SYSTEM'
        $a | Should -Contain '/RL'
    }

    <#
        The quoting bug. PowerShell quotes an argument containing spaces on its
        own; a literal quote character becomes part of the value.
    #>
    It 'passes the task name and command without literal quote characters' {
        $a = @(Get-Args 'daily')
        $tn = $a[[array]::IndexOf($a, '/TN') + 1]
        $tr = $a[[array]::IndexOf($a, '/TR') + 1]

        $tn | Should -Be '\TimedShutdown\TS_x'
        $tn | Should -Not -Match '"'
        $tr | Should -Be 'shutdown.exe /s /f'
        $tr | Should -Not -Match '"'
    }

    <#
        The date bug. schtasks demands literal mm/dd/yyyy and rejects the machine
        short-date format - the opposite of this codebase's usual locale rule,
        which is exactly why it needs a test rather than a comment.
    #>
    It 'formats /SD as mm-dd-yyyy regardless of culture' {
        $a = @(Get-Args 'once')
        $sd = $a[[array]::IndexOf($a, '/SD') + 1]
        $sd | Should -Match '^\d{2}/\d{2}/\d{4}$'
    }

    It 'abbreviates weekly days the way schtasks expects' {
        $a = @(Get-Args 'weekly' @('Monday', 'Wednesday'))
        $a[[array]::IndexOf($a, '/D') + 1] | Should -Be 'MON,WED'
    }

    It 'refuses a weekly schedule with no days rather than creating a broken task' {
        { Get-Args 'weekly' @() } | Should -Throw
    }

    It 'refuses an unknown recurrence or action' {
        { Get-Args 'hourly' } | Should -Throw
        { Register-TaskElevated -Name 'x' -ActionType 'explode' -Recurrence 'daily' -AtTime '22:30' } |
            Should -Throw
    }
}
