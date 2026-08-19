#Requires -Version 5.1
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
