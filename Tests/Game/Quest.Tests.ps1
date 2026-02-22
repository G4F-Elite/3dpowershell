Describe 'Game/Quest.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Game\Quest.ps1"
    }

    BeforeEach {
        Initialize-QuestSystem
    }

    It 'starts quest, updates matching objective events, and auto-completes' {
        $quest = New-Quest -Id 'q_wolves' -Name 'Wolf Hunt' -Objectives @(
            (New-QuestObjective -Type Kill -Target 'wolf' -RequiredCount 2)
        )

        (Start-Quest -Quest $quest).State | Should -Be 'InProgress'

        $r1 = Update-QuestKill -Target 'wolf' -Count 1
        $r1.UpdatedObjectives.Count | Should -Be 1
        (Get-QuestProgress -Quest $quest).CompletedObjectives | Should -Be 0

        $r2 = Update-QuestKill -Target 'wolf' -Count 1
        $r2.CompletedQuests.Count | Should -Be 1

        (Get-Quest -Quest 'q_wolves').State | Should -Be 'Completed'
        @(Get-CompletedQuests).Count | Should -Be 1
    }

    It 'does not update objective for non-matching target' {
        $quest = New-Quest -Id 'q_apples' -Name 'Gather Apples' -Objectives @(
            (New-QuestObjective -Type Gather -Target 'apple' -RequiredCount 3)
        )
        Start-Quest -Quest $quest | Out-Null

        $result = Update-QuestGather -Target 'berry' -Count 2
        $progress = Get-QuestProgress -Quest $quest

        $result.UpdatedObjectives.Count | Should -Be 0
        $progress.CompletedObjectives | Should -Be 0
        $progress.State | Should -Be 'InProgress'
    }

    It 'supports generic quest flags through Set-QuestState fallback' {
        Set-QuestState -Name 'intro_seen' -Value $true | Out-Null

        (Get-QuestFlag -Name 'intro_seen') | Should -Be $true
        (Get-QuestState -Name 'intro_seen') | Should -Be $true
    }
}
