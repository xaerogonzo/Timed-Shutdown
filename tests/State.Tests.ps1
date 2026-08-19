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
