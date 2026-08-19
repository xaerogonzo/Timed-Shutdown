#Requires -Version 5.1
<#
    Core/State.ps1 - the on-disk state file.

    Tracks the pending action, the idle watch, and (legacy only) any power-plan
    suppression left behind by an older build.

    The file used to live in %TEMP%, where a disk cleanup could delete the only
    record of the user's original power settings. It now lives under
    %LOCALAPPDATA% and migrates the old file on first run.
#>

# Bumped whenever the on-disk shape changes. Migration keys on THIS, never on
# structural sniffing - "does key X exist" guesses wrong the moment two versions
# happen to share a key.
$script:STATE_SCHEMA_VERSION = 2

$script:STATE_DIR         = Join-Path $env:LOCALAPPDATA 'TimedShutdown'
$script:STATE_FILE        = Join-Path $script:STATE_DIR 'state.json'
$script:LEGACY_STATE_FILE = Join-Path $env:TEMP 'TimedShutdown_state.json'

# Read-State runs several times per dispatcher tick. Cache on the file's write
# timestamp so a 1 s tick costs one stat() rather than a parse of the whole file.
$script:stateCache      = $null
$script:stateCacheStamp = $null

<#
    Test seam: point the store somewhere disposable.

    LegacyPath must be redirected too, or a test run would migrate (and delete)
    the real %TEMP% state file belonging to a live install.
#>
function Set-StateFilePath ([string]$Path, [string]$LegacyPath = '') {
    $script:STATE_FILE        = $Path
    $script:STATE_DIR         = Split-Path $Path -Parent
    $script:LEGACY_STATE_FILE = if ($LegacyPath) { $LegacyPath } else { Join-Path $script:STATE_DIR '__no_legacy__.json' }
    $script:stateCache        = $null
    $script:stateCacheStamp   = $null
}

function Initialize-StateStore {
    if (-not (Test-Path $script:STATE_DIR)) {
        New-Item -ItemType Directory -Path $script:STATE_DIR -Force | Out-Null
    }
    if ((-not (Test-Path $script:STATE_FILE)) -and (Test-Path $script:LEGACY_STATE_FILE)) {
        try { Move-Item $script:LEGACY_STATE_FILE $script:STATE_FILE -Force } catch {}
    }
}

function Read-State {
    if (-not (Test-Path $script:STATE_FILE)) {
        $script:stateCache = $null; $script:stateCacheStamp = $null
        return $null
    }
    try {
        $stamp = (Get-Item $script:STATE_FILE).LastWriteTimeUtc
        if ($null -ne $script:stateCache -and $stamp -eq $script:stateCacheStamp) {
            return $script:stateCache
        }
        $obj = Get-Content $script:STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:stateCache      = $obj
        $script:stateCacheStamp = $stamp
        return $obj
    } catch { return $null }
}

function Write-State ($partial) {
    Initialize-StateStore
    $h = @{ stateSchemaVersion = $script:STATE_SCHEMA_VERSION }
    $existing = Read-State
    if ($existing) { $existing.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    foreach ($kv in $partial.GetEnumerator()) { $h[$kv.Key] = $kv.Value }

    $json = $h | ConvertTo-Json -Depth 5
    # No BOM: this is JSON, not a PowerShell script.
    [System.IO.File]::WriteAllText($script:STATE_FILE, $json, (New-Object System.Text.UTF8Encoding($false)))

    $script:stateCache      = $null
    $script:stateCacheStamp = $null
}

function Clear-State {
    Write-State @{ pendingAction = @{ type = 'null' } }
}

# ── Schema migration ──────────────────────────────────────────────────────────

# State can be exercised without Core/Log.ps1 loaded (unit tests dot-source this
# file alone), so logging is best-effort rather than a hard dependency.
function Write-StateLog ([string]$Category, [string]$EventName, [string]$Detail) {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Category $EventName $Detail }
}

<#
    Reads the schema version from a state object.

    v1 predates the field and instead wrote `version = '1.0'`, which nothing ever
    read back. Absent or '1.0' therefore means v1.
#>
function Get-StateSchemaVersion ($State) {
    if (-not $State) { return 0 }
    if ($State.PSObject.Properties['stateSchemaVersion']) {
        return [int]$State.stateSchemaVersion
    }
    return 1
}

<#
    Brings the state file up to the current schema, returning $true if anything
    was written.

    Safety rules, both deliberate:

    * A v1 armed idle watch becomes a v2 `idle` trigger that is DISARMED. A
      migration must never create an armed destructive action on a machine whose
      owner has not re-consented under the new UI.

    * A state file from a FUTURE schema is never reinterpreted as the current
      one. That would mean guessing at fields written by a version of the app
      that does not exist yet. Safe defaults are loaded, nothing is armed, and
      the reason is logged. This matters as soon as anyone copies a state file
      between machines.
#>
function Update-StateSchema {
    $state = Read-State
    if (-not $state) { return $false }

    $found = Get-StateSchemaVersion $state

    if ($found -gt $script:STATE_SCHEMA_VERSION) {
        # Written by a newer build than this one. Reinterpreting it would mean
        # guessing at fields that do not exist yet, so preserve the file intact
        # (the user may go back to that build) and start from clean defaults
        # with nothing armed.
        $preserved = "$($script:STATE_FILE).v$found.bak"
        try { Copy-Item $script:STATE_FILE $preserved -Force -ErrorAction Stop } catch {}
        Remove-Item $script:STATE_FILE -Force -ErrorAction SilentlyContinue
        $script:stateCache = $null; $script:stateCacheStamp = $null

        Write-State @{
            stateSchemaVersion = $script:STATE_SCHEMA_VERSION
            trigger            = @{ kind = 'idle'; action = 'shutdown'; armed = $false; config = @{} }
            settings           = @{}
        }
        Write-StateLog 'state' 'future-schema' `
            "found=$found supported=$($script:STATE_SCHEMA_VERSION) - preserved to $preserved, started clean, nothing armed"
        return $true
    }

    if ($found -ge $script:STATE_SCHEMA_VERSION) { return $false }

    # ---- v1 -> v2 ----
    $wasArmed = $false
    $trigger  = @{ kind = 'idle'; action = 'shutdown'; armed = $false; config = @{ thresholdSec = 1800 } }

    if ($state.PSObject.Properties['idleWatch'] -and $state.idleWatch) {
        $iw = $state.idleWatch
        if ($iw.PSObject.Properties['thresholdSec'] -and [int]$iw.thresholdSec -gt 0) {
            $trigger.config.thresholdSec = [int]$iw.thresholdSec
        }
        if ($iw.PSObject.Properties['type'] -and $iw.type -and $iw.type -ne 'null') {
            $trigger.action = [string]$iw.type
        }
        $wasArmed = [bool]$iw.active
    }

    Write-State @{
        stateSchemaVersion = $script:STATE_SCHEMA_VERSION
        trigger            = $trigger
        settings           = @{}
        idleWatch          = $null      # v1 shape retired
        # Retire the v1 'version' field too. Leaving it alongside
        # stateSchemaVersion means two fields that both look like "the version",
        # and a future reader has to guess which one governs.
        version            = $null
    }

    Write-StateLog 'state' 'migrated' ("v{0}->v{1} idleWatchWasArmed={2} (migrated DISARMED)" -f `
        $found, $script:STATE_SCHEMA_VERSION, $wasArmed)
    return $true
}

# ── Settings ──────────────────────────────────────────────────────────────────

<#
    Persisted UI preferences only.

    Runtime timing (grace/cooldown/sustain deadlines, priming flags, last
    samples) is deliberately NOT persisted: those are monotonic tick values that
    mean nothing after a reboot, and a persisted "primed" flag could resurrect an
    armed destructive action across a restart.
#>
function Get-Settings {
    $s = Read-State
    $defaults = @{
        notifyMins  = 5
        netKbps     = 100
        processName = ''
        lastAction  = 'shutdown'
    }
    if ($s -and $s.PSObject.Properties['settings'] -and $s.settings) {
        foreach ($k in @($defaults.Keys)) {
            if ($s.settings.PSObject.Properties[$k]) { $defaults[$k] = $s.settings.$k }
        }
    }
    return $defaults
}

function Save-Settings ($Settings) { Write-State @{ settings = $Settings } }
