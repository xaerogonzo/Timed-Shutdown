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
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Invoke-LogRollover

        $version = if ($script:APP_VERSION) { $script:APP_VERSION } else { '?' }
        $line = '{0}`t{1}`t{2}`t{3}`t{4}' -f `
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
