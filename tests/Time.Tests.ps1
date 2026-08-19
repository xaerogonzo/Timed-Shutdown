#Requires -Version 5.1
<#
    Regression tests for Core/Time.ps1.

    This module is where both of the reported display bugs lived, so the cases
    below are written to fail against the pre-rewrite code:
      - every h/m/s format returned $null   ($Matches clobbered by the unit check)
      - 31 minutes rendered as "1 hour 31 minutes"  ([int] rounds, not truncates)

    No GUI, no power calls, no Task Scheduler - safe to run at any time.

    NB: the -TestCases key is 'Text', never 'Input'. $Input is a reserved
    automatic variable (the pipeline enumerator), so a case named Input arrives
    as an empty array rather than the string - which silently turns every
    "rejects invalid input" case into a vacuous pass.
#>

BeforeAll {
    . "$PSScriptRoot\..\src\Core\Time.ps1"
}

Describe 'ConvertTo-Seconds' {

    Context 'relative durations' {
        # These all returned $null before the fix, despite being the formats the
        # placeholder and README advertise.
        It "parses '<Text>' as <Expected> seconds" -TestCases @(
            @{ Text = '1h30m';    Expected = 5400 }
            @{ Text = '45m';      Expected = 2700 }
            @{ Text = '2h';       Expected = 7200 }
            @{ Text = '90s';      Expected = 90   }
            @{ Text = '1h30m45s'; Expected = 5445 }
            @{ Text = '1h';       Expected = 3600 }
            @{ Text = '30s';      Expected = 30   }
            @{ Text = '2h15s';    Expected = 7215 }
        ) {
            ConvertTo-Seconds $Text | Should -Be $Expected
        }

        It 'ignores surrounding whitespace' {
            ConvertTo-Seconds '  45m  ' | Should -Be 2700
        }
    }

    Context 'bare numbers mean minutes' {
        It "parses '<Text>' as <Expected> seconds" -TestCases @(
            @{ Text = '30'; Expected = 1800 }
            @{ Text = '31'; Expected = 1860 }
            @{ Text = '90'; Expected = 5400 }
            @{ Text = '1';  Expected = 60   }
        ) {
            ConvertTo-Seconds $Text | Should -Be $Expected
        }
    }

    Context 'absolute clock times' {
        It 'accepts a valid HH:mm and returns a positive offset' {
            ConvertTo-Seconds '22:30' | Should -BeGreaterThan 0
        }
        It 'rolls past times to tomorrow rather than returning a negative offset' {
            # Whatever the current time, one minute ago must resolve to ~24h out.
            $past = (Get-Date).AddMinutes(-1).ToString('HH:mm')
            ConvertTo-Seconds $past | Should -BeGreaterThan 86000
        }
    }

    Context 'invalid input returns $null without throwing' {
        It "rejects '<Text>'" -TestCases @(
            @{ Text = ''            }
            @{ Text = '   '         }
            @{ Text = 'garbage'     }
            @{ Text = '25:00'       }   # hour out of range
            @{ Text = '10:99'       }   # minute out of range
            @{ Text = '0'           }   # zero-length timer
            @{ Text = '0m'          }
            @{ Text = 'abc123'      }
            @{ Text = '99999999999' }   # would overflow an [int] cast
            @{ Text = '1h30'        }   # trailing number with no unit
        ) {
            ConvertTo-Seconds $Text | Should -BeNullOrEmpty
        }

        It 'rejects durations beyond the 30-day cap' {
            ConvertTo-Seconds '9999h' | Should -BeNullOrEmpty
            ConvertTo-Seconds '50000' | Should -BeNullOrEmpty
        }

        It 'does not throw on a very long digit string' {
            { ConvertTo-Seconds ('9' * 40) } | Should -Not -Throw
        }
    }
}

Describe 'Split-Duration' {

    # The reported bug: [int]$ts.TotalHours rounds (half-to-even), so 31 minutes
    # gave H=1 while M stayed 31. 30 minutes was correct only by accident -- 0.5
    # rounds to even, i.e. down to 0.
    It '<Minutes> min -> <H>h <M>m' -TestCases @(
        @{ Minutes = 29;   H = 0;  M = 29 }
        @{ Minutes = 30;   H = 0;  M = 30 }
        @{ Minutes = 31;   H = 0;  M = 31 }
        @{ Minutes = 45;   H = 0;  M = 45 }
        @{ Minutes = 59;   H = 0;  M = 59 }
        @{ Minutes = 60;   H = 1;  M = 0  }
        @{ Minutes = 90;   H = 1;  M = 30 }
        @{ Minutes = 91;   H = 1;  M = 31 }
        @{ Minutes = 150;  H = 2;  M = 30 }
        @{ Minutes = 1500; H = 25; M = 0  }
    ) {
        $d = Split-Duration ($Minutes * 60)
        $d.H | Should -Be $H
        $d.M | Should -Be $M
    }

    It 'keeps seconds' {
        $d = Split-Duration 5445
        $d.H | Should -Be 1; $d.M | Should -Be 30; $d.S | Should -Be 45
    }

    It 'clamps negatives to zero' {
        $d = Split-Duration -500
        $d.H | Should -Be 0; $d.M | Should -Be 0; $d.S | Should -Be 0
    }
}

Describe 'Format-TargetTime' {

    It 'reports 31 minutes without inventing an hour' {
        $s = Format-TargetTime '31' 'shut down'
        $s | Should -BeLike '*31 minutes*'
        $s | Should -Not -BeLike '*hour*'
    }

    It 'reports 90 minutes as 1 hour 30 minutes' {
        Format-TargetTime '90' 'shut down' | Should -BeLike '*1 hour 30 minutes*'
    }

    It 'singularises correctly' {
        Format-TargetTime '60' 'restart' | Should -BeLike '*in 1 hour*'
        Format-TargetTime '1'  'restart' | Should -BeLike '*in 1 minute*'
    }

    It 'uses the verb it is given' {
        Format-TargetTime '10' 'hibernate' | Should -BeLike 'Will hibernate at*'
    }

    It 'returns guidance for invalid input' {
        Format-TargetTime 'nonsense' 'shut down' | Should -BeLike '*valid time*'
    }
}

Describe 'Format-Countdown' {
    It '<Minutes> min -> <Expected>' -TestCases @(
        @{ Minutes = 31; Expected = '31m 00s'     }
        @{ Minutes = 90; Expected = '1h 30m 00s'  }
        @{ Minutes = 91; Expected = '1h 31m 00s'  }
    ) {
        Format-Countdown ([timespan]::FromMinutes($Minutes)) | Should -Be $Expected
    }

    It 'drops to seconds only under a minute' {
        Format-Countdown ([timespan]::FromSeconds(9)) | Should -Be '9s'
    }
}

Describe 'Format-IdleDuration' {
    It '<Seconds>s -> <Expected>' -TestCases @(
        @{ Seconds = 1860; Expected = '31m 00s' }
        @{ Seconds = 5460; Expected = '1h 31m'  }
        @{ Seconds = 65;   Expected = '1m 05s'  }
        @{ Seconds = 5;    Expected = '5s'      }
    ) {
        Format-IdleDuration $Seconds | Should -Be $Expected
    }
}
