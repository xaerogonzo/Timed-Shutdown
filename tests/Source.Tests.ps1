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
        function New-ScheduledTaskPrincipal { param($UserId, $RunLevel) 'principal' }
        function New-ScheduledTaskSettingsSet { param($DeleteExpiredTaskAfter, $ExecutionTimeLimit) 'settings' }
        function Register-ScheduledTask   { param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,[switch]$Force)
            $script:registeredTrigger = $Trigger }
        function Unregister-ScheduledTask { param($TaskName,$TaskPath,[switch]$Confirm,$ErrorAction) }
        function Ensure-TaskFolder {}

        $sched = Get-Content (Join-Path $script:srcDir 'Core\Scheduler.ps1') -Raw -Encoding UTF8
        $m = [regex]::Match($sched, '(?ms)^function New-PendingTask.*?^\}')
        $m.Success | Should -BeTrue
        . ([scriptblock]::Create($m.Value))

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
