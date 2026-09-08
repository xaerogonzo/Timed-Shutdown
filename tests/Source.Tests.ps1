#Requires -Version 5.1
<#
    Static source hygiene checks. No app code runs; these parse the files.

    Both rules here exist because a violation of each shipped as a real bug:
    a $Args parameter that silently arrived empty and broke every Sleep and
    Hibernate timer, and BOM-less files that rendered "·" as "Â·".
#>

BeforeAll {
    $script:srcDir = Join-Path $PSScriptRoot '..\src'

    # PowerShell's automatic variables. A parameter named after one of these
    # never receives the caller's argument - the automatic value shadows it,
    # usually arriving empty, with no error at the call site.
    $script:ReservedNames = @(
        'args','input','error','host','matches','this','psitem','_','true','false','null',
        'home','pwd','profile','pid','psscriptroot','pscommandpath','psboundparameters',
        'myinvocation','executioncontext','lastexitcode','stacktrace','switch','foreach',
        'sender','event','eventargs','eventsubscriber','nestedpromptlevel','outputencoding',
        'shellid','stacktrace','consolefilename','psculture','psuiculture','psversiontable'
    )

    <#
        Assignments whose target is an automatic variable.

        The scope prefix is stripped before comparing, so `$script:event = ...`
        is caught too -- writing to a scoped variable that shares a name with an
        automatic is the same trap wearing a hat.
    #>
    function Get-AutomaticVariableAssignments ([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $out = @()
        foreach ($a in $ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $left = $a.Left
            if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

            $name = $left.VariablePath.UserPath
            $leaf = ($name -split ':')[-1]          # drop any script:/global:/local: prefix
            if ($script:ReservedNames -contains $leaf.ToLower()) {
                $out += [PSCustomObject]@{
                    File     = Split-Path $Path -Leaf
                    Variable = $name
                    Line     = $a.Extent.StartLineNumber
                }
            }
        }
        return $out
    }

    function Get-FunctionParameters ([string]$Path) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $funcs = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $out = @()
        foreach ($f in $funcs) {
            $params = @()
            if ($f.Parameters)              { $params += $f.Parameters }
            elseif ($f.Body.ParamBlock)     { $params += $f.Body.ParamBlock.Parameters }
            foreach ($p in $params) {
                $out += [PSCustomObject]@{
                    File     = Split-Path $Path -Leaf
                    Function = $f.Name
                    Param    = $p.Name.VariablePath.UserPath
                    Line     = $f.Extent.StartLineNumber
                }
            }
        }
        return $out
    }
}

Describe 'Parameter names' {

    <#
        Regression: New-PendingTask declared [string]$Args. $Args is the
        function's own automatic argument array, so the caller's value never
        landed - New-ScheduledTaskAction then rejected -Argument '' and every
        Sleep and Hibernate timer failed with "Cannot validate argument on
        parameter 'Argument'". Shutdown and Restart were unaffected because they
        call shutdown.exe directly rather than going through a scheduled task.
    #>
    It 'no function parameter shadows a PowerShell automatic variable' {
        $offenders = @(
            Get-ChildItem -Path $script:srcDir -Recurse -Filter '*.ps1' -File | ForEach-Object {
                Get-FunctionParameters $_.FullName
            } | Where-Object { $script:ReservedNames -contains $_.Param.ToLower() }
        )
        ($offenders | ForEach-Object { "$($_.File):$($_.Line) $($_.Function) -> `$$($_.Param)" }) -join '; ' |
            Should -BeNullOrEmpty
    }

    It 'New-PendingTask passes a non-empty argument string through' {
        . (Join-Path $script:srcDir 'Core\Time.ps1')   # harmless, keeps parse deps obvious
        $captured = $null
        # Stand in for the scheduler cmdlets so nothing is registered.
        function New-ScheduledTaskAction { param($Execute, $Argument)
            if ([string]::IsNullOrEmpty($Argument)) { throw "empty -Argument for $Execute" }
            $script:captured = $Argument; return 'action' }
        # -Once is a switch on the real cmdlet; declaring it as a value parameter
        # makes it swallow the next token and fail to bind. The real cmdlet also
        # returns an object with a settable EndBoundary, which the code needs.
        function New-ScheduledTaskTrigger   { param([switch]$Once, $At)
            [PSCustomObject]@{ Once = [bool]$Once; At = $At; EndBoundary = $null } }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel)
            $script:principalArgs = @{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
            return 'principal' }
        function New-ScheduledTaskSettingsSet { param($DeleteExpiredTaskAfter, $ExecutionTimeLimit) 'settings' }
        function Register-ScheduledTask   { param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,[switch]$Force)
            $script:registeredTrigger = $Trigger }
        function Unregister-ScheduledTask { param($TaskName,$TaskPath,[switch]$Confirm,$ErrorAction) }
        function Ensure-TaskFolder {}

        $sched = Get-Content (Join-Path $script:srcDir 'Core\Scheduler.ps1') -Raw -Encoding UTF8
        # New-PendingTask now delegates the principal choice, so lift that
        # function in too rather than stubbing it - which principal it picks is
        # exactly what the next test checks.
        foreach ($fn in 'New-TaskPrincipalFor', 'New-PendingTask') {
            $m = [regex]::Match($sched, "(?ms)^function $fn .*?^\}")
            $m.Success | Should -BeTrue
            . ([scriptblock]::Create($m.Value))
        }

        { New-PendingTask 'TS_pending_sleep' 'rundll32.exe' 'powrprof.dll,SetSuspendState 0,1,0' (Get-Date) } |
            Should -Not -Throw
        $script:captured | Should -Be 'powrprof.dll,SetSuspendState 0,1,0'
    }

    <#
        Regression: -DeleteExpiredTaskAfter is only accepted when the trigger
        declares when it expires. Without an EndBoundary the registration was
        rejected ("The task XML is missing a required element or attribute ...
        EndBoundary") -- and because Register-ScheduledTask reports that as a
        NON-terminating error, piping to Out-Null discarded it. The app then
        counted down a Sleep/Hibernate timer with no task behind it.
    #>
    It 'gives the one-shot trigger an EndBoundary' {
        $script:registeredTrigger | Should -Not -BeNullOrEmpty
        $script:registeredTrigger.EndBoundary | Should -Not -BeNullOrEmpty
    }

    <#
        Regression: builds up to 2.3 registered this task under a SYSTEM
        principal, and that single choice is why the whole app demanded UAC on
        every launch. A task backing a countdown shown in a visible window has
        no need of it - the user is signed in by definition.

        Asserting "not SYSTEM" rather than a literal account name keeps this
        meaningful on any machine, including CI runners.
    #>
    It 'backs a pending timer with a current-user principal, never SYSTEM' {
        $script:principalArgs | Should -Not -BeNullOrEmpty
        $script:principalArgs.UserId    | Should -Not -Match '(?i)^system$'
        $script:principalArgs.UserId    | Should -Not -Be 'S-1-5-18'
        $script:principalArgs.LogonType | Should -Be 'Interactive'
        # Highest would raise a UAC prompt; SetSuspendState does not need one.
        $script:principalArgs.RunLevel  | Should -Be 'Limited'
    }

    It 'lets scheduled-task registration failures surface' {
        # Without -ErrorAction Stop these failures are non-terminating and the
        # surrounding try/catch never sees them.
        $sched = Get-Content (Join-Path $script:srcDir 'Core\Scheduler.ps1') -Raw -Encoding UTF8
        $calls = [regex]::Matches($sched, '(?s)Register-ScheduledTask.*?(?=?
\s*?
|?
\s*\})')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($m in $calls) {
            $m.Value | Should -BeLike '*-ErrorAction Stop*'
        }
    }
}

Describe 'Source encoding' {

    # PowerShell 5.1 decodes a BOM-less script as Windows-1252, which is what
    # turned "·" into "Â·" throughout the UI.
    It 'every source file carries a UTF-8 BOM' {
        $offenders = @(
            Get-ChildItem -Path $script:srcDir -Recurse -Include '*.ps1','*.xaml' -File | ForEach-Object {
                $b = [System.IO.File]::ReadAllBytes($_.FullName)
                if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $_.Name }
            }
        )
        $offenders -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Variable assignments' {

    <#
        The parameter rule above catches `[string]$Args` -- a parameter that
        silently arrives empty. This catches the other half of the same mistake:
        ASSIGNING to an automatic variable.

        BASIC_INSTRUCTIONS.md forbids these names outright, and the v2.2
        changelog calls a $Event parameter "exactly the class of bug that broke
        Sleep and Hibernate in v2.1" -- but only the parameter form was ever
        enforced, so seven `$event = ...` assignments sat in the trigger engine,
        the most safety-critical module in the project, without complaint.

        A local named $event is harmless in an ordinary function. It stops being
        harmless the moment that code is lifted into a Register-ObjectEvent
        -Action scriptblock, where $Event is bound by PowerShell itself -- and
        this app already runs WinForms event handlers. The rule is cheap; finding
        out the hard way is not.

        Found by PSScriptAnalyzer's PSAvoidAssignmentToAutomaticVariable, which
        the CI baseline step surfaced.
    #>
    It 'no assignment targets a PowerShell automatic variable' {
        $offenders = @(
            Get-ChildItem -Path $script:srcDir -Recurse -Filter '*.ps1' -File | ForEach-Object {
                Get-AutomaticVariableAssignments $_.FullName
            }
        )
        ($offenders | ForEach-Object { "$($_.File):$($_.Line) -> `$$($_.Variable)" }) -join '; ' |
            Should -BeNullOrEmpty
    }
}

<#
    The admin gate, pinned out.

    Builds up to 2.3 refused to start unelevated, and the sole cause was a
    SYSTEM task principal. Both halves are asserted: no startup gate, and no
    module quietly reintroducing a SYSTEM principal on the default path.
#>
Describe 'Runs without elevation' {

    BeforeAll {
        $script:allSrc = @(Get-ChildItem -Path $script:srcDir -Recurse -Include '*.ps1' -File)
    }

    It 'has no #Requires -RunAsAdministrator anywhere in src' {
        $hits = @($script:allSrc | Where-Object {
            (Get-Content $_.FullName -Raw -Encoding UTF8) -match '(?im)^\s*#Requires.*RunAsAdministrator'
        })
        ($hits | ForEach-Object { $_.Name }) -join ', ' | Should -BeNullOrEmpty
    }

    <#
        Main.ps1 may still READ the elevation state - the Scheduled tab needs to
        know whether it must escalate - but it must not exit on it.
    #>
    It 'does not exit when the user is not an administrator' {
        $main = Get-Content (Join-Path $script:srcDir 'Main.ps1') -Raw -Encoding UTF8
        $main | Should -Not -Match '(?s)if \(-not \$isAdmin\)'
        $main | Should -Not -Match 'Administrator privileges are required'
    }

    It 'still records elevation so the opt-in path can use it' {
        $main = Get-Content (Join-Path $script:srcDir 'Main.ps1') -Raw -Encoding UTF8
        $main | Should -Match '\$script:isElevated'
    }

    <#
        A SYSTEM principal is legitimate ONLY behind the explicit
        "run even when I'm signed out" opt-in, which New-TaskPrincipalFor gates.
        Anywhere else it silently reintroduces the UAC requirement.
    #>
    It 'creates SYSTEM principals only inside New-TaskPrincipalFor' {
        $offenders = @()
        foreach ($f in $script:allSrc) {
            $text = Get-Content $f.FullName -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($text, "New-ScheduledTaskPrincipal[^
]*")) {
                if ($m.Value -match "(?i)-UserId\s+'?SYSTEM'?") {
                    # Allowed only in the helper that the opt-in calls.
                    $before = $text.Substring(0, $m.Index)
                    $fn = [regex]::Matches($before, '(?m)^function\s+([A-Za-z-]+)')
                    $enclosing = if ($fn.Count) { $fn[$fn.Count - 1].Groups[1].Value } else { '<top level>' }
                    if ($enclosing -ne 'New-TaskPrincipalFor') {
                        $offenders += "$($f.Name): $enclosing"
                    }
                }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }

    It 'no longer auto-elevates from the launcher' {
        $bat = Get-Content (Join-Path $script:srcDir '..\TimedShutdown.bat') -Raw
        $bat | Should -Not -Match '(?i)-Verb RunAs'
    }
}


<#
    The v2.4 "Turn Off Monitor" freeze, as a static rule.

    Invoke-MonitorOff blocked the WPF dispatcher with Start-Sleep and then
    handed it to an unbounded SendMessage(HWND_BROADCAST, ...), which waits on
    every top-level window in the session with no timeout and no way out. The
    app sat at "(Not Responding)" until it was force-quit, every single time.

    PROJECT POLICY, not a universal PowerShell rule. Every code path in src/
    runs on the WPF dispatcher -- this app has no background thread anywhere --
    so a blanket ban on Start-Sleep is a faithful statement of the real
    invariant here rather than a superstition about a useful cmdlet. If genuine
    off-thread work is ever added, NARROW this rule to the UI entry points; do
    not delete it. The invariant is "the dispatcher is never blocked", and its
    sharper form is that a WndProc must never call anything that can block at
    all -- which is what made the Win+Alt+M path the worse of the two.
#>
Describe 'UI thread is never blocked' {

    BeforeAll {
        $script:uiSrc = @(Get-ChildItem -Path $script:srcDir -Recurse -Include '*.ps1' -File)

        <#
            Parsed, not grepped, and deliberately so: Core/Power.ps1 quotes the
            old two-line implementation verbatim in a comment, so the next reader
            can see what was wrong. A regex would flag that comment forever and
            the rule would be deleted rather than fixed.
        #>
        function Get-CommandCalls ([string]$Path, [string]$Name) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            return @($ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                "$($args[0].GetCommandName())" -eq $Name }, $true))
        }

        function Get-UnboundedBroadcast ([string]$Path) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            return @($ast.FindAll({
                $n = $args[0]
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                "$($n.Member)" -eq 'SendMessage' -and
                $n.Arguments -and $n.Arguments.Count -gt 0 -and
                "$($n.Arguments[0].Extent.Text)" -match 'HWND_BROADCAST' }, $true))
        }
    }

    It 'no source file calls Start-Sleep' {
        $offenders = @($script:uiSrc | Where-Object {
            (Get-CommandCalls $_.FullName 'Start-Sleep').Count -gt 0
        })
        ($offenders | ForEach-Object { $_.Name }) -join ', ' | Should -BeNullOrEmpty
    }

    <#
        A broadcast must go through SendMessageTimeout + SMTO_ABORTIFHUNG. That
        bounds each RECIPIENT individually -- it is NOT a wall-clock cap on the
        whole broadcast, since several hung windows still sum -- but it is the
        difference between a finite wait and an infinite one.
    #>
    It 'never broadcasts through the unbounded SendMessage' {
        $offenders = @($script:uiSrc | Where-Object {
            (Get-UnboundedBroadcast $_.FullName).Count -gt 0
        })
        ($offenders | ForEach-Object { $_.Name }) -join ', ' | Should -BeNullOrEmpty
    }
}
