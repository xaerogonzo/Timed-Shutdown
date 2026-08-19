#Requires -Version 5.1
<#
    Runs the Timed Shutdown test suite.

        .\tests\Invoke-Tests.ps1

    Windows ships Pester 3.4.0, whose syntax predates everything used here, so
    this checks for Pester 5 up front and prints the one-line install rather than
    failing with a wall of parse errors.

    The suite covers pure logic only (time parsing/formatting, the state file).
    Task Scheduler, powercfg, and shutdown.exe are side-effecting and stay
    verified by hand -- see docs\ARCHITECTURE.md.
#>

[CmdletBinding()]
param(
    # Pass -CI to return a non-zero exit code when anything fails.
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

# Ui.Tests.ps1 instantiates WPF objects, which requires a single-threaded
# apartment. powershell.exe is STA by default; pwsh is MTA, where those tests
# fail with an unhelpful COM error rather than a clear cause.
$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -ne 'STA') {
    Write-Host ''
    Write-Host "This session is $apartment; the WPF markup tests need STA." -ForegroundColor Yellow
    Write-Host '  Re-run with:' -ForegroundColor Cyan
    Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" -ForegroundColor White
    Write-Host ''
    exit 1
}

$pester = Get-Module -ListAvailable Pester |
          Where-Object { $_.Version.Major -ge 5 } |
          Sort-Object Version -Descending |
          Select-Object -First 1

if (-not $pester) {
    $installed = (Get-Module -ListAvailable Pester | Sort-Object Version -Descending |
                  Select-Object -First 1).Version
    Write-Host ''
    Write-Host 'Pester 5 or newer is required.' -ForegroundColor Yellow
    Write-Host "  Currently available: $(if ($installed) { "Pester $installed" } else { 'none' })" -ForegroundColor DarkGray
    Write-Host '  Windows ships Pester 3.4.0, which cannot run these tests.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Install it once with:' -ForegroundColor Cyan
    Write-Host '    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor White
    Write-Host ''
    exit 1
}

Import-Module Pester -MinimumVersion 5.0 -Force
Write-Host "Using Pester $($pester.Version)" -ForegroundColor DarkGray

$config = New-PesterConfiguration
$config.Run.Path        = $PSScriptRoot
$config.Run.PassThru    = $true
$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config

Write-Host ''
Write-Host ("Passed {0}  Failed {1}  Skipped {2}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount) `
    -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })

if ($CI -and $result.FailedCount -gt 0) { exit 1 }
exit 0
