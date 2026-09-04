#Requires -Version 5.1
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
