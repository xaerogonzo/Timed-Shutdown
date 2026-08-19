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

function Import-XamlDocument ([string]$Name) {
    if ($script:XamlCache.ContainsKey($Name)) { return [xml]$script:XamlCache[$Name] }
    $path = Join-Path $script:XamlRoot $Name
    if (-not (Test-Path $path)) { throw "XAML resource not found: $path" }
    return [xml](Get-Content $path -Raw -Encoding UTF8)
}

function New-XamlWindow ([string]$Name) {
    $doc = Import-XamlDocument $Name
    return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
}
