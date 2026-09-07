#Requires -Version 5.1
<#
    UI/Xaml.ps1 - loads .xaml markup into WPF objects.

    Markup normally comes off disk from src/UI. The bundler pre-populates
    $script:XamlCache with the same markup as here-strings, so the single-file
    build in dist/ resolves from memory and needs no companion files. Call sites
    are identical either way.
#>

$script:XamlRoot  = $PSScriptRoot
$script:XamlCache = @{}

# Control templates every window shares. Spliced into each document's
# <Window.Resources> by Import-XamlDocument, so there is one copy rather than one
# per window.
$script:THEME_XAML = 'Theme.xaml'

$script:WPF_NS  = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'

# Test seam: point markup loading at a source tree other than this module's own
# directory. Same shape as Set-StateFilePath and Set-LogFilePath.
function Set-XamlRoot ([string]$Path) { $script:XamlRoot = $Path }

<#
    Reads one .xaml document, with the shared theme merged in.

    The merge happens HERE rather than in New-XamlWindow so that every consumer
    of a document - the app and the markup tests alike - sees exactly what WPF
    will be handed. A test that parsed the raw file would be checking markup the
    application never actually loads.

    Order matters: shared entries go FIRST, so a window that wants to override
    one can simply declare its own afterwards and win. It also means Theme.xaml
    cannot reference a window's resources, which is why that file is documented
    as self-contained.
#>
function Import-XamlDocument ([string]$Name) {
    $doc = Read-XamlDocument $Name
    if ($Name -ne $script:THEME_XAML) { Merge-SharedResource $doc }
    return $doc
}

function Read-XamlDocument ([string]$Name) {
    if ($script:XamlCache.ContainsKey($Name)) { return [xml]$script:XamlCache[$Name] }
    $path = Join-Path $script:XamlRoot $Name
    if (-not (Test-Path $path)) { throw "XAML resource not found: $path" }
    return [xml](Get-Content $path -Raw -Encoding UTF8)
}

<#
    Copies Theme.xaml's entries into $Doc's <Window.Resources>.

    InsertBefore against a FIXED reference node appends in source order: each new
    node lands immediately before the window's original first entry, and so after
    the ones already inserted. Inserting before a moving "current first" would
    silently reverse them.
#>
function Merge-SharedResource ([xml]$Doc) {
    $nsm = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
    $nsm.AddNamespace('d', $script:WPF_NS)

    $resNode = $Doc.SelectSingleNode('/d:Window/d:Window.Resources', $nsm)
    if (-not $resNode) { throw 'Window has no <Window.Resources> to merge shared styles into.' }

    $theme  = Read-XamlDocument $script:THEME_XAML
    $anchor = $resNode.FirstChild

    foreach ($child in @($theme.DocumentElement.ChildNodes)) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        [void]$resNode.InsertBefore($Doc.ImportNode($child, $true), $anchor)
    }
}

function New-XamlWindow ([string]$Name) {
    $doc = Import-XamlDocument $Name
    return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
}
