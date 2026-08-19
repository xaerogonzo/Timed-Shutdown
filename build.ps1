#Requires -Version 5.1
<#
    build.ps1 - bundles src\ into a single distributable script.

    Emits dist\TimedShutdown.ps1 by inlining every dot-source in src\Main.ps1 and
    embedding the .xaml markup as here-strings, so the shipped file needs no
    companion files. Behaviour is identical to running src\Main.ps1 directly.

    The output is written as UTF-8 WITH BOM, and every input is checked for one.
    That is not cosmetic: powershell.exe 5.1 parses a BOM-less file as
    Windows-1252, which turns "·" into "Â·" and mangles every other non-ASCII
    glyph in the UI.

    Many editors save UTF-8 without a BOM by default, which trips the check
    above. Run  .\build.ps1 -FixEncoding  to re-save every source file with one.

    Usage:  .\build.ps1  [-Quiet] [-FixEncoding]
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    # Re-save any BOM-less .ps1/.xaml under src\ (and this script) before building.
    [switch]$FixEncoding
)

$ErrorActionPreference = 'Stop'

$ROOT  = $PSScriptRoot
$SRC   = Join-Path $ROOT 'src'
$DIST  = Join-Path $ROOT 'dist'
$ENTRY = Join-Path $SRC  'Main.ps1'
$OUT   = Join-Path $DIST 'TimedShutdown.ps1'

# Matches:  . "$PSScriptRoot\Core\Time.ps1"
$INCLUDE_RE = '^\s*\.\s+"\$PSScriptRoot\\(.+?)"\s*$'

function Write-Step($msg, $color = 'Gray') {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}

<#
    Reads a source file, refusing anything without a UTF-8 BOM.
#>
function Read-SourceFile([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing source file: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "No UTF-8 BOM: $Path`n" +
              "       PowerShell 5.1 reads BOM-less scripts as Windows-1252, which corrupts every" +
              " non-ASCII character in the UI. Re-save this file as 'UTF-8 with BOM'."
    }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

$script:includedFiles = @()

function Expand-Include([string]$Text, [string]$BaseDir, [int]$Depth = 0) {
    if ($Depth -gt 5) { throw 'Include nesting deeper than 5 levels - probable cycle.' }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match $INCLUDE_RE) {
            $rel  = $Matches[1]
            $path = Join-Path $BaseDir $rel
            $script:includedFiles += $rel
            $out.Add("# ═══ begin $rel " + ('═' * [math]::Max(0, 56 - $rel.Length)))
            $out.Add((Expand-Include (Read-SourceFile $path) (Split-Path $path -Parent) ($Depth + 1)))
            $out.Add("# ═══ end $rel " + ('═' * [math]::Max(0, 58 - $rel.Length)))
        } else {
            $out.Add($line)
        }
    }
    return ($out -join "`r`n")
}

<#
    Replaces the empty XAML cache declaration in UI/Xaml.ps1 with one pre-filled
    from disk, so the bundled script resolves markup from memory. Import-XamlDocument
    checks the cache before the filesystem, so call sites are untouched.
#>
function Add-XamlCache([string]$Text) {
    $xamlFiles = @(Get-ChildItem -Path (Join-Path $SRC 'UI') -Filter '*.xaml' -File | Sort-Object Name)
    if ($xamlFiles.Count -eq 0) { throw 'No .xaml files found under src\UI.' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('$script:XamlCache = @{}')
    [void]$sb.AppendLine('# Markup embedded by build.ps1 so the bundle is self-contained.')
    foreach ($f in $xamlFiles) {
        $markup = Read-SourceFile $f.FullName
        # A here-string ends at a line whose first two characters are '@ - XAML is
        # always indented or starts with '<', but verify rather than assume.
        foreach ($l in ($markup -split "`r?`n")) {
            if ($l -match "^'@") { throw "Cannot embed $($f.Name): a line begins with '@ and would close the here-string early." }
        }
        [void]$sb.AppendLine("`$script:XamlCache['$($f.Name)'] = @'")
        [void]$sb.AppendLine($markup.TrimEnd())
        [void]$sb.AppendLine("'@")
        Write-Step ("  embedded {0,-24} {1,7:N0} bytes" -f $f.Name, $markup.Length)
    }

    $needle = '$script:XamlCache = @{}'
    if ($Text -notmatch [regex]::Escape($needle)) { throw "Could not find '$needle' in UI\Xaml.ps1." }
    $idx = $Text.IndexOf($needle)
    return $Text.Substring(0, $idx) + $sb.ToString().TrimEnd() + $Text.Substring($idx + $needle.Length)
}

# ── Build ─────────────────────────────────────────────────────────────────────

Write-Step ''
Write-Step '=== Timed Shutdown - bundle ===' 'Cyan'
Write-Step ''

if (-not (Test-Path $DIST)) { New-Item -ItemType Directory -Path $DIST -Force | Out-Null }

if ($FixEncoding) {
    $fixed = 0
    $targets = @(Get-ChildItem -Path $SRC -Recurse -Include '*.ps1','*.xaml' -File) + @(Get-Item $PSCommandPath)
    foreach ($f in $targets) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { continue }
        # Decode as UTF-8 (the BOM is only a marker; the bytes are already UTF-8)
        # and write it back with one.
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
        [System.IO.File]::WriteAllText($f.FullName, $content, (New-Object System.Text.UTF8Encoding($true)))
        Write-Step "  [bom] $($f.FullName.Substring($ROOT.Length + 1))" 'Yellow'
        $fixed++
    }
    Write-Step "  added a BOM to $fixed file(s)" 'Yellow'
    Write-Step ''
}

$text = Expand-Include (Read-SourceFile $ENTRY) $SRC
Write-Step "  inlined $($script:includedFiles.Count) modules:" 'Gray'
foreach ($f in $script:includedFiles) { Write-Step "    $f" 'DarkGray' }
Write-Step ''

$text = Add-XamlCache $text

# One #Requires at the top; the per-file copies are redundant once merged.
$lines  = $text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#Requires\b' }
$header = @(
    '#Requires -Version 5.1'
    '<#'
    '    Timed Shutdown - GENERATED FILE, DO NOT EDIT.'
    ''
    "    Built from src\ by build.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
    '    Edit the files under src\ and re-run build.ps1 instead.'
    '#>'
    ''
)
$final = (($header + $lines) -join "`r`n").TrimEnd() + "`r`n"

# Syntax-check before writing: a broken bundle should fail the build, not the app.
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($final, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($e in $parseErrors) { Write-Host "  [parse] line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
    throw "Bundle has $($parseErrors.Count) syntax error(s); nothing written."
}

[System.IO.File]::WriteAllText($OUT, $final, (New-Object System.Text.UTF8Encoding($true)))

# Confirm the BOM actually landed - this is the whole point of the exercise.
$outBytes = [System.IO.File]::ReadAllBytes($OUT)
if ($outBytes[0] -ne 0xEF -or $outBytes[1] -ne 0xBB -or $outBytes[2] -ne 0xBF) {
    throw 'Output is missing its UTF-8 BOM.'
}

Write-Step ("  OK  dist\TimedShutdown.ps1  {0:N0} bytes, {1:N0} lines, BOM present" -f $outBytes.Length, ($final -split "`r?`n").Count) 'Green'
Write-Step ''
Write-Step 'Build complete.' 'Green'
Write-Step ''
