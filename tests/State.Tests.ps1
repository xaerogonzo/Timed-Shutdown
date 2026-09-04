#Requires -Version 5.1
<#
    Tests for Core/State.ps1.

    Every test redirects the store into a fresh temp directory via
    Set-StateFilePath, including the legacy path -- otherwise a run would migrate
    (and delete) the real %TEMP% state file belonging to a live install.

    NB: BeforeEach must live inside a Describe. Pester 6 rejects test setup
    declared directly in the file's root block.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Core\State.ps1"

    function New-Sandbox {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "TS_tests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }
}

Describe 'Read-State / Write-State' {

    BeforeEach {
        $sandbox   = New-Sandbox
        $stateFile = Join-Path $sandbox 'state.json'
        Set-StateFilePath $stateFile
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns $null when no state file exists' {
        Read-State | Should -BeNullOrEmpty
    }

    It 'round-trips a written value' {
        Write-State @{ pendingAction = @{ type = 'shutdown'; seconds = 1800 } }
        $s = Read-State
        $s.pendingAction.type    | Should -Be 'shutdown'
        $s.pendingAction.seconds | Should -Be 1800
    }

    It 'merges partial writes instead of replacing the document' {
        Write-State @{ pendingAction = @{ type = 'restart' } }
        Write-State @{ idleWatch = @{ active = $true; thresholdSec = 600 } }
        $s = Read-State
        $s.pendingAction.type     | Should -Be 'restart'
        $s.idleWatch.thresholdSec | Should -Be 600
    }

    It 'overwrites a key on a later write' {
        Write-State @{ pendingAction = @{ type = 'sleep' } }
        Write-State @{ pendingAction = @{ type = 'hibernate' } }
        (Read-State).pendingAction.type | Should -Be 'hibernate'
    }

    It 'stamps the schema version' {
        Write-State @{ pendingAction = @{ type = 'null' } }
        (Read-State).stateSchemaVersion | Should -Not -BeNullOrEmpty
    }

    It 'writes JSON without a BOM' {
        Write-State @{ pendingAction = @{ type = 'null' } }
        $bytes = [System.IO.File]::ReadAllBytes($stateFile)
        # 0xEF 0xBB 0xBF would break strict JSON consumers.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'survives a corrupt state file' {
        Set-Content -Path $stateFile -Value '{ this is not json' -Encoding UTF8
        { Read-State } | Should -Not -Throw
        Read-State | Should -BeNullOrEmpty
    }

    It 'reflects a change made after the value was cached' {
        Write-State @{ pendingAction = @{ type = 'shutdown' } }
        Read-State | Out-Null                                   # populate cache
        Write-State @{ pendingAction = @{ type = 'restart' } }   # must invalidate
        (Read-State).pendingAction.type | Should -Be 'restart'
    }
}

Describe 'Clear-State' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It "sets the pending action type to 'null'" {
        Write-State @{ pendingAction = @{ type = 'shutdown'; seconds = 60 } }
        Clear-State
        (Read-State).pendingAction.type | Should -Be 'null'
    }

    It 'leaves other sections intact' {
        Write-State @{ idleWatch = @{ active = $true } }
        Clear-State
        (Read-State).idleWatch.active | Should -BeTrue
    }
}

Describe 'Initialize-StateStore' {

    BeforeEach { $sandbox = New-Sandbox }
    AfterEach  { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the state directory' {
        $nested = Join-Path $sandbox 'nested\deep\state.json'
        Set-StateFilePath $nested
        Initialize-StateStore
        Test-Path (Split-Path $nested -Parent) | Should -BeTrue
    }

    It 'migrates a legacy %TEMP% state file to the new location' {
        $legacy = Join-Path $sandbox 'legacy.json'
        $target = Join-Path $sandbox 'migrated.json'
        Set-Content -Path $legacy -Value '{"version":"1.0","pendingAction":{"type":"restart"}}' -Encoding UTF8

        Set-StateFilePath $target $legacy
        Initialize-StateStore

        Test-Path $legacy | Should -BeFalse
        Test-Path $target | Should -BeTrue
        (Read-State).pendingAction.type | Should -Be 'restart'
    }

    It 'does not clobber an existing state file with the legacy one' {
        $legacy = Join-Path $sandbox 'legacy2.json'
        $target = Join-Path $sandbox 'current.json'
        Set-Content -Path $legacy -Value '{"version":"1.0","pendingAction":{"type":"restart"}}' -Encoding UTF8
        Set-Content -Path $target -Value '{"version":"1.0","pendingAction":{"type":"sleep"}}'   -Encoding UTF8

        Set-StateFilePath $target $legacy
        Initialize-StateStore

        (Read-State).pendingAction.type | Should -Be 'sleep'
        Test-Path $legacy | Should -BeTrue
    }
}

<#
    Schema migration.

    docs/ARCHITECTURE.md states both of these rules as safety invariants, and
    until now nothing enforced either. They are the two places where a state file
    can turn into an armed destructive action on a machine whose owner never
    asked for one.
#>
Describe 'Get-StateSchemaVersion' {

    BeforeEach {
        $sandbox = New-Sandbox
        Set-StateFilePath (Join-Path $sandbox 'state.json')
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads 0 for no state at all' {
        Get-StateSchemaVersion $null | Should -Be 0
    }

    # v1 predates the field and instead wrote a `version` of '1.0', which nothing
    # ever read back. Absent therefore means v1, not "unknown".
    It 'reads the legacy version field as v1' {
        Set-Content -Path (Join-Path $sandbox 'state.json') `
            -Value '{"version":"1.0","idleWatch":{"active":true}}' -Encoding UTF8
        Get-StateSchemaVersion (Read-State) | Should -Be 1
    }

    It 'reads a file with no version marker at all as v1' {
        Set-Content -Path (Join-Path $sandbox 'state.json') `
            -Value '{"idleWatch":{"active":true}}' -Encoding UTF8
        Get-StateSchemaVersion (Read-State) | Should -Be 1
    }

    It 'reads an explicit schema version' {
        Write-State @{ pendingAction = @{ type = 'null' } }
        Get-StateSchemaVersion (Read-State) | Should -Be 2
    }
}

Describe 'Update-StateSchema - v1 to v2' {

    BeforeEach {
        $sandbox   = New-Sandbox
        $stateFile = Join-Path $sandbox 'state.json'
        Set-StateFilePath $stateFile
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports that it migrated' {
        Set-Content -Path $stateFile -Encoding UTF8 `
            -Value '{"version":"1.0","idleWatch":{"active":false,"thresholdSec":1800,"type":"sleep"}}'
        Update-StateSchema | Should -BeTrue
    }

    <#
        THE invariant. A v1 armed idle watch becomes a v2 idle trigger that is
        DISARMED.

        The v2 trigger engine is not the v1 one -- different priming, different
        grace behaviour, different abort rules. Carrying "armed" across that
        boundary would mean an upgrade silently re-consented, on the owner's
        behalf, to a destructive action configured under rules that no longer
        exist. They have to arm it again, having seen the new UI.
    #>
    It 'migrates an ARMED v1 idle watch to a DISARMED v2 trigger' {
        Set-Content -Path $stateFile -Encoding UTF8 `
            -Value '{"version":"1.0","idleWatch":{"active":true,"thresholdSec":1800,"type":"shutdown"}}'
        Update-StateSchema | Out-Null

        $s = Read-State
        $s.trigger       | Should -Not -BeNullOrEmpty
        $s.trigger.armed | Should -BeFalse
    }

    It 'carries the configured threshold and action across' {
        Set-Content -Path $stateFile -Encoding UTF8 `
            -Value '{"version":"1.0","idleWatch":{"active":true,"thresholdSec":2700,"type":"hibernate"}}'
        Update-StateSchema | Out-Null

        $s = Read-State
        $s.trigger.kind                | Should -Be 'idle'
        $s.trigger.action              | Should -Be 'hibernate'
        $s.trigger.config.thresholdSec | Should -Be 2700
    }

    It 'falls back to a default threshold when v1 recorded none' {
        Set-Content -Path $stateFile -Encoding UTF8 -Value '{"version":"1.0","idleWatch":{"active":false}}'
        Update-StateSchema | Out-Null
        (Read-State).trigger.config.thresholdSec | Should -Be 1800
    }

    It 'migrates a file with no idleWatch at all' {
        Set-Content -Path $stateFile -Encoding UTF8 -Value '{"version":"1.0"}'
        Update-StateSchema | Out-Null

        $s = Read-State
        $s.trigger.armed | Should -BeFalse
        $s.trigger.kind  | Should -Be 'idle'
    }

    It 'stamps the new schema version' {
        Set-Content -Path $stateFile -Encoding UTF8 -Value '{"version":"1.0","idleWatch":{"active":true}}'
        Update-StateSchema | Out-Null
        Get-StateSchemaVersion (Read-State) | Should -Be 2
    }

    <#
        Both v1 fields are retired rather than left lying around. Leaving
        `version` beside `stateSchemaVersion` would mean two fields that each
        look like "the version", and a future reader would have to guess which
        one governs.
    #>
    It 'retires the v1 idleWatch and version fields' {
        Set-Content -Path $stateFile -Encoding UTF8 `
            -Value '{"version":"1.0","idleWatch":{"active":true,"thresholdSec":1800}}'
        Update-StateSchema | Out-Null

        $s = Read-State
        $s.idleWatch | Should -BeNullOrEmpty
        $s.version   | Should -BeNullOrEmpty
    }

    It 'is a no-op the second time' {
        Set-Content -Path $stateFile -Encoding UTF8 -Value '{"version":"1.0","idleWatch":{"active":true}}'
        Update-StateSchema | Should -BeTrue
        Update-StateSchema | Should -BeFalse
    }

    It 'does nothing when there is no state file' {
        Update-StateSchema | Should -BeFalse
    }
}

Describe 'Update-StateSchema - a file from the future' {

    BeforeEach {
        $sandbox   = New-Sandbox
        $stateFile = Join-Path $sandbox 'state.json'
        Set-StateFilePath $stateFile

        Set-Content -Path $stateFile -Encoding UTF8 -Value (@{
            stateSchemaVersion = 99
            trigger            = @{ kind = 'quantum'; action = 'shutdown'; armed = $true }
            somethingNew       = @{ nested = 'value' }
        } | ConvertTo-Json -Depth 5)
    }
    AfterEach { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports that it changed something' {
        Update-StateSchema | Should -BeTrue
    }

    <#
        Reinterpreting a newer file as the current schema would mean guessing at
        fields written by a build that does not exist yet. It is preserved
        instead -- the user may well go back to that build, and this stops being
        hypothetical the moment anyone copies a state file between machines.
    #>
    It 'preserves the original alongside, named for its schema' {
        Update-StateSchema | Out-Null
        Test-Path "$stateFile.v99.bak" | Should -BeTrue

        $preserved = Get-Content "$stateFile.v99.bak" -Raw | ConvertFrom-Json
        $preserved.stateSchemaVersion  | Should -Be 99
        $preserved.somethingNew.nested | Should -Be 'value'
    }

    <#
        The safety half: it starts from clean defaults with NOTHING armed. That
        future file carried an armed trigger of a kind this build has never heard
        of; honouring it would arm a destructive action whose firing rules cannot
        be evaluated at all.
    #>
    It 'starts clean with nothing armed' {
        Update-StateSchema | Out-Null

        $s = Read-State
        $s.trigger.armed | Should -BeFalse
        $s.trigger.kind  | Should -Be 'idle'
    }

    It 'drops the unrecognised fields from the live file' {
        Update-StateSchema | Out-Null
        (Read-State).somethingNew | Should -BeNullOrEmpty
    }

    It 'stamps the version this build actually supports' {
        Update-StateSchema | Out-Null
        Get-StateSchemaVersion (Read-State) | Should -Be 2
    }

    It 'settles down after one pass' {
        Update-StateSchema | Should -BeTrue
        Update-StateSchema | Should -BeFalse
    }
}
