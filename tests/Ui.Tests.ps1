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
                       'TxtSettleSec','ChkRecurse','TxtSignalPath','ChkResNet','TxtResKbps',
                       'ChkResCpu','TxtResCpu','RbResAll','RbResAny','TxtResSustain','TxtIdleTime') {
            Set-Variable -Name $n -Value $script:vWin.FindName($n) -Scope Script
        }
        $script:triggerKinds = @('process','downloads','signal','resource','idle')

        . (Join-Path $script:srcDir 'Core\Time.ps1')

        # Lift the two functions under test out of MainWindow.ps1 rather than
        # sourcing the whole file, which would build a second window.
        $uiSrc = Get-Content (Join-Path $script:uiDir 'MainWindow.ps1') -Raw -Encoding UTF8
        foreach ($fn in 'Get-SelectedTriggerKind','Get-TriggerConfigFromUi') {
            $m = [regex]::Match($uiSrc, "(?ms)^function $fn \{.*?^\}")
            if (-not $m.Success) { throw "could not extract $fn from MainWindow.ps1" }
            . ([scriptblock]::Create($m.Value))
        }
    }

    It 'refuses <Case>' -TestCases @(
        @{ Case = 'a process trigger with no names';   Kind = 0; Setup = { $TxtProcNames.Text = '' } }
        @{ Case = 'a process list of only commas';     Kind = 0; Setup = { $TxtProcNames.Text = ' , , ' } }
        @{ Case = 'downloads with no folder';          Kind = 1; Setup = { $TxtDownloadPath.Text = '' } }
        @{ Case = 'downloads with a missing folder';   Kind = 1; Setup = { $TxtDownloadPath.Text = 'X:
ope' } }
        @{ Case = 'downloads with a bad settle time';  Kind = 1; Setup = { $TxtDownloadPath.Text = $env:TEMP; $TxtSettleSec.Text = 'soon' } }
        @{ Case = 'a signal with no path';             Kind = 2; Setup = { $TxtSignalPath.Text = '' } }
        @{ Case = 'a signal in a missing folder';      Kind = 2; Setup = { $TxtSignalPath.Text = 'X:
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
            $TxtSignalPath.Text = $existing
            { Get-TriggerConfigFromUi } | Should -Throw
        } finally { Remove-Item $existing -Force -ErrorAction SilentlyContinue }
    }
}
