Describe 'Game/Reputation.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Game\Reputation.ps1"
    }

    BeforeEach {
        Initialize-ReputationSystem -Quiet
    }

    It 'maps numeric reputation to correct level names' {
        (Resolve-ReputationLevel -Value -600) | Should -Be 'Hated'
        (Resolve-ReputationLevel -Value -200) | Should -Be 'Hostile'
        (Resolve-ReputationLevel -Value 0) | Should -Be 'Neutral'
        (Resolve-ReputationLevel -Value 200) | Should -Be 'Friendly'
        (Resolve-ReputationLevel -Value 700) | Should -Be 'Honored'
        (Resolve-ReputationLevel -Value 1000) | Should -Be 'Exalted'
    }

    It 'creates factions and tracks reputation gains' {
        $faction = New-ReputationFaction -Name 'Village' -InitialValue 0
        $faction | Should -Not -Be $null
        $faction.Level | Should -Be 'Neutral'

        Add-Reputation -Delta 150 -Faction 'Village'
        $record = Get-ReputationFaction -Name 'Village'
        $record.Value | Should -Be 150
        $record.Level | Should -Be 'Friendly'
    }

    It 'clamps reputation to min/max range' {
        New-ReputationFaction -Name 'Bandits' -InitialValue 0 | Out-Null
        Add-Reputation -Delta -2000 -Faction 'Bandits'
        $record = Get-ReputationFaction -Name 'Bandits'
        $record.Value | Should -BeGreaterOrEqual -1000
    }

    It 'enforces max faction limit' {
        New-ReputationFaction -Name 'A' | Out-Null
        New-ReputationFaction -Name 'B' | Out-Null
        New-ReputationFaction -Name 'C' | Out-Null
        New-ReputationFaction -Name 'D' | Out-Null

        $extra = New-ReputationFaction -Name 'E'
        $extra | Should -Be $null
    }

    It 'returns all tracked factions' {
        New-ReputationFaction -Name 'Miners' | Out-Null
        $all = Get-ReputationFactions
        @($all).Count | Should -BeGreaterOrEqual 2
    }
}
