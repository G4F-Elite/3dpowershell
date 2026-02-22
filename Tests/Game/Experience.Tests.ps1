Describe 'Game/Experience.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Game\Experience.ps1"
    }

    BeforeEach {
        Initialize-ExperienceSystem -Quiet
    }

    It 'produces deterministic XP table with linear growth' {
        $l2 = Get-XPRequiredForNextLevel -Level 1
        $l3 = Get-XPRequiredForNextLevel -Level 2
        $l2 | Should -Be 100
        $l3 | Should -Be 150
    }

    It 'caps at max level 50 and returns 0 XP required' {
        $max = Get-MaxPlayerLevel
        $max | Should -Be 50
        $xpNeeded = Get-XPRequiredForNextLevel -Level 50
        $xpNeeded | Should -Be 0
    }

    It 'levels up player when sufficient XP is added' {
        $player = [PSCustomObject]@{ Name = 'Test'; Level = 1; XP = 0; MaxLevel = 50 }
        $result = Add-PlayerXP -Player $player -Amount 250 -SuppressNotification

        $result.CurrentLevel | Should -BeGreaterThan 1
        $result.LevelsGained | Should -BeGreaterThan 0
        $player.Level | Should -BeGreaterThan 1
    }

    It 'prevents leveling past max level' {
        $player = [PSCustomObject]@{ Name = 'Test'; Level = 49; XP = 0; MaxLevel = 50 }
        Set-PlayerLevel -Player $player -Level 49 -SuppressNotification | Out-Null
        Add-PlayerXP -Player $player -Amount 999999 -SuppressNotification | Out-Null

        $player.Level | Should -BeLessOrEqual 50
    }

    It 'produces cumulative XP table where levels increase monotonically' {
        $prev = 0
        for ($lvl = 2; $lvl -le 50; $lvl++) {
            $required = Get-XPRequiredForLevel -Level $lvl
            $required | Should -BeGreaterThan $prev
            $prev = $required
        }
    }
}
