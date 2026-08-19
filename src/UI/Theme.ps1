#Requires -Version 5.1
<#
    UI/Theme.ps1 - the colour values used from code.

    Anything purely declarative lives in the XAML; these are the few shades the
    event handlers have to apply at runtime.
#>

$script:COLOR_OK      = '#A6E3A1'  # green  - valid input, keep-awake active
$script:COLOR_MUTED   = '#6C7086'  # grey   - placeholder / invalid input
$script:COLOR_WARN    = '#FAB387'  # amber  - a guard is holding the action back

function ConvertTo-Brush ([string]$hex) {
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}
