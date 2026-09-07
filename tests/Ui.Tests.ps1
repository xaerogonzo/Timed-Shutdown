#Requires -Version 5.1
<#
    Checks that the XAML markup and the code that reaches into it agree.

    Every control the UI modules look up with FindName('X') must actually exist
    in the corresponding .xaml, and the markup must load into a real WPF object
    tree. This catches the common regression of renaming an element in markup
    without updating the code (or vice versa), which otherwise surfaces only as a
    null-reference at runtime once you click the affected control.

    Loads markup only - no window is shown, and nothing on the system is touched.
    Requires an STA thread; powershell.exe is STA by default, pwsh is not.
#>

BeforeAll {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $script:srcDir = Join-Path $PSScriptRoot '..\src'
    $script:uiDir  = Join-Path $script:srcDir 'UI'

    function Get-FindNameRefs ([string]$Path) {
        $text = Get-Content $Path -Raw -Encoding UTF8
        return [regex]::Matches($text, "FindName\(\s*'([^']+)'\s*\)") |
               ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    }

    function Get-XamlNames ([string]$Path) {
        [xml]$doc = Get-Content $Path -Raw -Encoding UTF8
        $ns = New-Object System.Xml.XmlNamespaceManager $doc.NameTable
        $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        return $doc.SelectNodes('//@x:Name', $ns) | ForEach-Object { $_.Value }
    }
}

Describe 'MainWindow markup' {

    It 'loads into a WPF Window' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
        $w | Should -Not -BeNullOrEmpty
        $w.Title | Should -Be 'Timed Shutdown'
    }

    It 'defines every control MainWindow.ps1 looks up' {
        $declared = Get-XamlNames    (Join-Path $script:uiDir 'MainWindow.xaml')
        $used     = Get-FindNameRefs (Join-Path $script:uiDir 'MainWindow.ps1')
        $used | Should -Not -BeNullOrEmpty
        $missing = @($used | Where-Object { $_ -notin $declared })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'exposes the three expected tabs, unabbreviated' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
        @($w.FindName('MainTabs').Items | ForEach-Object { $_.Header }) | Should -Be @('Timers','Triggers','Scheduled')
    }

    # Regression: TabPanel sizes each tab from its normal-weight header, but the
    # IsSelected trigger switches it to SemiBold. Without slack in the padding the
    # wider text overflows and the last glyph is clipped.
    It 'leaves room for the SemiBold selected state in every tab' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
        $probe = New-Object System.Windows.Controls.TextBlock
        $probe.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
        $probe.FontSize   = 14
        $probe.FontWeight = [System.Windows.FontWeights]::SemiBold
        $inf = [System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)

        foreach ($tab in $w.FindName('MainTabs').Items) {
            $tab.Measure($inf)
            $probe.Text = [string]$tab.Header
            $probe.Measure($inf)
            $textBox = $tab.DesiredSize.Width - $tab.Margin.Left - $tab.Margin.Right - $tab.Padding.Left
            $textBox | Should -BeGreaterThan $probe.DesiredSize.Width -Because "tab '$($tab.Header)' would clip when selected"
        }
    }
}

Describe 'Accessibility' {

    <#
        Regression: the custom TabControl template's ContentPresenter was
        unnamed. TabControl resolves its selected-content host by looking up the
        template child literally named PART_SelectedContentHost, and
        TabItemAutomationPeer reaches the tab's content through that. Without
        the name, the entire contents of every tab were absent from the UI
        Automation tree -- a screen reader saw three tab headers and nothing
        else, and no control inside a tab could be driven by assistive
        technology or UI testing.
    #>
    It 'exposes the selected tab content to UI Automation' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))

        # Resolve through the Window's name scope before detaching the content;
        # afterwards the scope no longer answers for it.
        $content = $win.Content
        $tabs    = $win.FindName('MainTabs')
        $tabs | Should -Not -BeNullOrEmpty

        # Realise a visual tree; a Window that is never shown has none.
        $win.SetValue([System.Windows.Controls.ContentControl]::ContentProperty, $null)
        $surface = New-Object System.Windows.Controls.Border
        $surface.Resources = $win.Resources
        $surface.Child     = $content
        $surface.Measure([System.Windows.Size]::new(490, 800))
        $surface.Arrange([System.Windows.Rect]::new(0, 0, 490, 800))
        $surface.UpdateLayout()

        $tabs.Template.FindName('PART_SelectedContentHost', $tabs) | Should -Not -BeNullOrEmpty

        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($tabs)
        $peer.ResetChildrenCache()
        $tabPeers = $peer.GetChildren()
        $tabPeers.Count | Should -Be 3

        # The selected tab must expose its contents, not just its header.
        $selected = $tabPeers[0]
        $selected.ResetChildrenCache()
        $selected.GetChildren().Count | Should -BeGreaterThan 1 -Because 'the selected tab must expose its contents'

        # And a real control must be reachable by AutomationId.
        $found = New-Object System.Collections.Generic.List[string]
        function Walk($p, $d) {
            if ($d -gt 8) { return }
            $p.ResetChildrenCache()
            $kids = $p.GetChildren()
            if (-not $kids) { return }
            foreach ($c in $kids) { $found.Add($c.GetAutomationId()); Walk $c ($d + 1) }
        }
        foreach ($tp in $tabPeers) { Walk $tp 0 }

        foreach ($aid in 'TxtTime','LblPreview','BtnStart','BtnCancel') {
            $found -contains $aid | Should -BeTrue -Because "$aid must be reachable via UI Automation"
        }
    }
}

Describe 'ScheduleDialog markup' {

    It 'loads into a WPF Window' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'ScheduleDialog.xaml') -Raw -Encoding UTF8
        [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc)) | Should -Not -BeNullOrEmpty
    }

    It 'defines every control ScheduleDialog.ps1 looks up' {
        $declared = Get-XamlNames    (Join-Path $script:uiDir 'ScheduleDialog.xaml')
        $used     = Get-FindNameRefs (Join-Path $script:uiDir 'ScheduleDialog.ps1')
        $used | Should -Not -BeNullOrEmpty
        $missing = @($used | Where-Object { $_ -notin $declared })
        $missing -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Quick Actions reachability' {

    <#
        Regression: ACTIVE TIMER and QUICK ACTIONS shared a single StackPanel,
        which neither clips nor scrolls. Showing the active-timer panel pushed
        "Turn Off Monitor" and "Lock Screen" past the bottom of a fixed-size,
        non-resizable window, making them unreachable exactly while a timer was
        running. The pinned-row layout must keep them on screen in every state.
    #>
    It 'keeps the quick-action buttons on screen at <Client>px with a timer running' -TestCases @(
        @{ Client = 761 }
        @{ Client = 700 }
        @{ Client = 661 }
    ) {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))

        $content = $win.Content
        $panel   = $win.FindName('PanelActive')
        $noTimer = $win.FindName('LblNoTimer')
        $guard   = $win.FindName('LblGuardBlocked')
        $awake   = $win.FindName('LblSleepSuppressed')
        $buttons = @($win.FindName('BtnMonitorOff'), $win.FindName('BtnLockScreen'))

        $win.SetValue([System.Windows.Controls.ContentControl]::ContentProperty, $null)
        $surface = New-Object System.Windows.Controls.Border
        $surface.Resources = $win.Resources
        $surface.Child     = $content

        # Worst case: timer running, keep-awake shown, and a guard banner.
        $panel.Visibility = 'Visible'; $noTimer.Visibility = 'Collapsed'
        $awake.Visibility = 'Visible'; $guard.Visibility   = 'Visible'

        $surface.Width = 474; $surface.Height = $Client
        $surface.Measure([System.Windows.Size]::new(474, $Client))
        $surface.Arrange([System.Windows.Rect]::new(0, 0, 474, $Client))
        $surface.UpdateLayout()

        foreach ($b in $buttons) {
            $top = $b.TransformToAncestor($surface).Transform([System.Windows.Point]::new(0,0)).Y
            $top | Should -BeGreaterOrEqual 0
            ($top + $b.ActualHeight) | Should -BeLessOrEqual $Client `
                -Because "'$($b.Content)' must stay on screen while a timer is running"
        }
    }

    It 'sets a minimum window height that cannot hide them' {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
        $win.ResizeMode | Should -Not -Be 'CanMinimize' -Because 'the user must be able to enlarge the window'
        $win.MinHeight  | Should -BeGreaterOrEqual 680
    }
}

Describe 'Trigger configuration validation' {

    <#
        Arming an invalid trigger must be refused, not accepted-and-broken: an
        armed trigger that can never fire is worse than a clear refusal. These
        drive Get-TriggerConfigFromUi against a real (unshown) window, so they
        cover the validation logic without any mouse involvement.
    #>
    BeforeAll {
        [xml]$doc = Get-Content (Join-Path $script:uiDir 'MainWindow.xaml') -Raw -Encoding UTF8
        $script:vWin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))

        foreach ($n in 'CmbTriggerKind','TxtProcNames','RbProcAll','RbProcAny','TxtDownloadPath',
                       'TxtSettleSec','ChkRecurse','TxtSignalName','ChkSignalAdvanced','TxtSignalPath',
                       'ChkResNet','TxtResKbps',
                       'ChkResCpu','TxtResCpu','RbResAll','RbResAny','TxtResSustain','TxtIdleTime') {
            Set-Variable -Name $n -Value $script:vWin.FindName($n) -Scope Script
        }
        $script:triggerKinds = @('process','downloads','signal','resource','idle')

        # Signal paths resolve into a disposable folder: these tests must never
        # create or delete anything under a live install's %LOCALAPPDATA%.
        $script:signalSandbox = Join-Path $env:TEMP "TS_signals_$([guid]::NewGuid().ToString('N'))"

        . (Join-Path $script:srcDir 'Core\Time.ps1')

        # Lift the two functions under test out of MainWindow.ps1 rather than
        # sourcing the whole file, which would build a second window.
        $uiSrc = Get-Content (Join-Path $script:uiDir 'MainWindow.ps1') -Raw -Encoding UTF8
        # Every function the validation path reaches. Omitting one does not make
        # a "refuses X" test fail -- it makes it pass for the wrong reason, on a
        # null-reference rather than the refusal being tested.
        foreach ($fn in 'Set-SignalDir','Get-SignalDir','Initialize-SignalDir','Get-SignalPath',
                        'Test-SignalName','Get-ConfiguredSignalPath','Get-SelectedTriggerKind',
                        'Get-TriggerConfigFromUi') {
            # The parameter list is optional: Get-SelectedTriggerKind has none,
            # Get-SignalPath ([string]$Name) does. A pattern that assumed one
            # shape silently failed to extract the other.
            $m = [regex]::Match($uiSrc, "(?ms)^function $fn\s*(\([^)]*\))?\s*\{.*?^\}")
            if (-not $m.Success) { throw "could not extract $fn from MainWindow.ps1" }
            . ([scriptblock]::Create($m.Value))
        }

        # Must come AFTER the lift: Set-SignalDir is one of the functions above.
        Set-SignalDir $script:signalSandbox
    }

    AfterAll {
        Remove-Item $script:signalSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses <Case>' -TestCases @(
        @{ Case = 'a process trigger with no names';   Kind = 0; Setup = { $TxtProcNames.Text = '' } }
        @{ Case = 'a process list of only commas';     Kind = 0; Setup = { $TxtProcNames.Text = ' , , ' } }
        @{ Case = 'downloads with no folder';          Kind = 1; Setup = { $TxtDownloadPath.Text = '' } }
        @{ Case = 'downloads with a missing folder';   Kind = 1; Setup = { $TxtDownloadPath.Text = 'X:
ope' } }
        @{ Case = 'downloads with a bad settle time';  Kind = 1; Setup = { $TxtDownloadPath.Text = $env:TEMP; $TxtSettleSec.Text = 'soon' } }
        @{ Case = 'a signal with no path';             Kind = 2; Setup = { $ChkSignalAdvanced.IsChecked = $true; $TxtSignalPath.Text = '' } }
        @{ Case = 'a signal name that is empty';       Kind = 2; Setup = { $ChkSignalAdvanced.IsChecked = $false; $TxtSignalName.Text = '' } }
        @{ Case = 'a signal name with a path separator'; Kind = 2; Setup = { $ChkSignalAdvanced.IsChecked = $false; $TxtSignalName.Text = 'sub\done' } }
        @{ Case = 'a signal name with a space';        Kind = 2; Setup = { $ChkSignalAdvanced.IsChecked = $false; $TxtSignalName.Text = 'all done' } }
        @{ Case = 'a signal in a missing folder';      Kind = 2; Setup = { $ChkSignalAdvanced.IsChecked = $true; $TxtSignalPath.Text = 'X:
ope\go.flag' } }
        @{ Case = 'resource with no metric enabled';   Kind = 3; Setup = { $ChkResNet.IsChecked = $false; $ChkResCpu.IsChecked = $false } }
        @{ Case = 'resource with a bad threshold';     Kind = 3; Setup = { $ChkResNet.IsChecked = $true; $TxtResKbps.Text = 'lots' } }
        @{ Case = 'an unparseable idle threshold';     Kind = 4; Setup = { $TxtIdleTime.Text = 'banana' } }
        @{ Case = 'an idle threshold under 30s';       Kind = 4; Setup = { $TxtIdleTime.Text = '10s' } }
    ) {
        $CmbTriggerKind.SelectedIndex = $Kind
        & $Setup
        { Get-TriggerConfigFromUi } | Should -Throw
    }

    It 'accepts <Case>' -TestCases @(
        @{ Case = 'a single process name'; Kind = 0; Setup = { $TxtProcNames.Text = 'ffmpeg' } }
        @{ Case = 'a valid download watch'; Kind = 1; Setup = { $TxtDownloadPath.Text = $env:TEMP; $TxtSettleSec.Text = '30' } }
        @{ Case = 'a settle time of zero';  Kind = 1; Setup = { $TxtDownloadPath.Text = $env:TEMP; $TxtSettleSec.Text = '0' } }
        @{ Case = 'network only';           Kind = 3; Setup = { $ChkResNet.IsChecked = $true; $ChkResCpu.IsChecked = $false; $TxtResKbps.Text = '100'; $TxtResSustain.Text = '120' } }
        @{ Case = 'a valid idle threshold'; Kind = 4; Setup = { $TxtIdleTime.Text = '30m' } }
    ) {
        $CmbTriggerKind.SelectedIndex = $Kind
        & $Setup
        { Get-TriggerConfigFromUi } | Should -Not -Throw
    }

    It 'strips a typed .exe from process names' {
        $CmbTriggerKind.SelectedIndex = 0
        $TxtProcNames.Text = 'ffmpeg.exe, HandBrake.exe'
        (Get-TriggerConfigFromUi).Names | Should -Be @('ffmpeg','HandBrake')
    }

    <#
        The signal trigger fires on absent -> present, so a file that is already
        there when you arm would never produce an edge. Refusing at arm time is
        much kinder than silently waiting forever.
    #>
    It 'refuses a signal file that already exists' {
        $existing = Join-Path $env:TEMP "TS_val_$([guid]::NewGuid().ToString('N')).flag"
        Set-Content $existing 'x' -Encoding ascii
        try {
            $CmbTriggerKind.SelectedIndex = 2
            $ChkSignalAdvanced.IsChecked = $true
            $TxtSignalPath.Text = $existing
            { Get-TriggerConfigFromUi } | Should -Throw
        } finally { Remove-Item $existing -Force -ErrorAction SilentlyContinue }
    }

    <#
        A named signal must resolve to the same folder
        tools\TimedShutdown-signal.cmd writes to. The name is the whole contract
        between the two halves; if they ever disagree the trigger waits forever
        on a file nothing creates.

        Asserted against the DEFAULT location and as pure strings, so it stays a
        statement about the contract and touches no filesystem.
    #>
    It 'defaults to the folder the signal tool writes to' {
        Set-SignalDir $null
        try {
            Get-SignalPath 'done' |
                Should -Be (Join-Path (Join-Path $env:LOCALAPPDATA 'TimedShutdown') 'signals\done.flag')
            $tool = Get-Content (Join-Path $PSScriptRoot '..\tools\TimedShutdown-signal.cmd') -Raw
            $tool | Should -Match ([regex]::Escape('TimedShutdown\signals'))
        } finally { Set-SignalDir $script:signalSandbox }
    }

    <#
        Regression, caught by CI on a clean runner and not locally.

        Arming a named signal used to be REFUSED with "Folder does not exist"
        whenever the signals folder had not been created yet - which on a fresh
        install is always, because the folder appears when the signal TOOL first
        runs and the entire point is to arm before the job that signals it. It
        passed in development only because that machine had run the app before.

        The sandbox below is what makes this test mean anything: pointed at a
        directory that is deleted between cases, it reproduces "fresh install"
        every time.
    #>
    It 'creates the signal folder rather than refusing when it does not exist' {
        Remove-Item $script:signalSandbox -Recurse -Force -ErrorAction SilentlyContinue
        Test-Path $script:signalSandbox | Should -BeFalse

        $CmbTriggerKind.SelectedIndex = 2
        $ChkSignalAdvanced.IsChecked  = $false
        $TxtSignalName.Text           = 'done'

        $cfg = Get-TriggerConfigFromUi
        $cfg.Path | Should -Be (Join-Path $script:signalSandbox 'done.flag')
        Test-Path $script:signalSandbox | Should -BeTrue
    }

    It 'accepts a signal name of <_> on a machine that has never run the app' -ForEach @('done', 'build_2', 'a.b-c') {
        Remove-Item $script:signalSandbox -Recurse -Force -ErrorAction SilentlyContinue
        $CmbTriggerKind.SelectedIndex = 2
        $ChkSignalAdvanced.IsChecked  = $false
        $TxtSignalName.Text           = $_
        { Get-TriggerConfigFromUi } | Should -Not -Throw
    }

    <#
        A full path the USER typed is still checked and never created: the app
        owns its own signals folder, not an arbitrary directory.
    #>
    It 'still refuses a user-supplied full path in a folder that does not exist' {
        $CmbTriggerKind.SelectedIndex = 2
        $ChkSignalAdvanced.IsChecked  = $true
        $TxtSignalPath.Text = Join-Path $env:TEMP "TS_nope_$([guid]::NewGuid().ToString('N'))\go.flag"
        { Get-TriggerConfigFromUi } | Should -Throw
    }
}

<#
    The v2.4 readability defect, pinned.

    ComboBox was the only control in the app still on the stock Aero template.
    Aero IGNORES the Background set on a ComboBox and paints its dropdown popup
    with SystemColors.WindowBrush - white - so the pale #CDD6F4 foreground sat on
    white and the menu was unreadable. Setting properties cannot fix that.

    These tests therefore assert the TEMPLATE, not the Background. A future
    change that drops the template while keeping the colour setters would
    reintroduce the exact bug and still satisfy any colour-only assertion.

    They also load markup through the real Import-XamlDocument path rather than
    parsing the file, because the shared theme is merged in there. A test that
    read the raw .xaml would be checking markup the app never actually loads.
#>
Describe 'Shared control theme' {

    BeforeAll {
        . (Join-Path $script:uiDir 'Xaml.ps1')
        Set-XamlRoot $script:uiDir
    }

    It 'merges the shared theme into <_>' -ForEach @('MainWindow.xaml', 'ScheduleDialog.xaml') {
        $w = New-XamlWindow $_
        foreach ($type in @([System.Windows.Controls.ComboBox],
                            [System.Windows.Controls.ComboBoxItem],
                            [System.Windows.Controls.RadioButton])) {
            $style = $w.TryFindResource($type)
            $style | Should -Not -BeNullOrEmpty -Because "$($type.Name) needs a style in $_"
            @($style.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Count |
                Should -Be 1 -Because "$($type.Name) needs a real template, not colour setters"
        }
    }

    It 'keeps PART_Popup, which ComboBox looks up to find its dropdown' {
        $w        = New-XamlWindow 'MainWindow.xaml'
        $style    = $w.TryFindResource([System.Windows.Controls.ComboBox])
        $template = ($style.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Value
        $root     = $template.LoadContent()

        $popup = $root.FindName('PART_Popup')
        if (-not $popup) {
            # LoadContent does not always register names; fall back to a walk.
            $popup = @($root.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.Popup] })[0]
        }
        $popup | Should -Not -BeNullOrEmpty
    }

    <#
        The specific fix: the popup paints its OWN background. Inheriting is
        what produced white.
    #>
    It 'gives the dropdown popup an explicit dark background' {
        $w        = New-XamlWindow 'MainWindow.xaml'
        $style    = $w.TryFindResource([System.Windows.Controls.ComboBox])
        $template = ($style.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Value
        $root     = $template.LoadContent()

        $popup = @($root.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.Popup] })[0]
        $popup | Should -Not -BeNullOrEmpty

        $border = $popup.Child
        $border          | Should -BeOfType [System.Windows.Controls.Border]
        $border.Background | Should -Not -BeNullOrEmpty

        # Dark, not the system window brush that caused the bug.
        $c = $border.Background.Color
        ([int]$c.R + [int]$c.G + [int]$c.B) | Should -BeLessThan 300
    }

    <#
        Shared entries are spliced in FIRST so a window can still override one by
        declaring its own afterwards. If that order ever inverts, per-window
        customisation silently stops working.
    #>
    It 'puts shared entries before the window own resources' {
        $doc = Import-XamlDocument 'MainWindow.xaml'
        $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $nsm.AddNamespace('d', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $nsm.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

        $res   = $doc.SelectSingleNode('/d:Window/d:Window.Resources', $nsm)
        $names = @($res.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } |
                   ForEach-Object { $_.GetAttribute('TargetType') })

        # ComboBox comes from Theme.xaml; ScrollBar is MainWindow first entry.
        $names.IndexOf('ComboBox') | Should -BeLessThan $names.IndexOf('ScrollBar')
    }

    It 'does not merge the theme into itself' {
        # Guards against the recursion that a missing self-check would cause.
        { Import-XamlDocument 'Theme.xaml' } | Should -Not -Throw
    }
}
