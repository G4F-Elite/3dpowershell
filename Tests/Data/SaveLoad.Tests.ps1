Describe 'Data/SaveLoad.ps1' {
    BeforeAll {
        function Get-PlayerPosition { return [PSCustomObject]@{ X = 10.0; Y = 64.0; Z = -5.0 } }
        function Get-InventorySlots { return @([PSCustomObject]@{ ItemName = 'stone'; Count = 3 }) }
        function Get-HotbarSelection { return 2 }
        function Get-AllEquipment { return @{ MainHand = 'iron_sword' } }
        function Get-AllQuests { return @([PSCustomObject]@{ Id='q1'; State='InProgress'; Objectives=@([PSCustomObject]@{ Id='o1'; CurrentCount=1; RequiredCount=2; IsCompleted=$false }) }) }
        function Get-PlayerStats { return [PSCustomObject]@{ HP=90; MaxHP=100; Mana=30; MaxMana=50; Stamina=40; MaxStamina=50; IsAlive=$true } }
        function Get-PlayerXP { return 120 }
        function Get-PlayerLevel { return 3 }
        function Get-ReputationFactions { return @([PSCustomObject]@{ Name='Guild'; Value=15 }) }

        . "$PSScriptRoot\..\..\Data\SaveLoad.ps1"
    }

    BeforeEach {
        $script:QuestFlags = @{ 'intro_seen' = $true }
        $script:WorldSeed = 777
        $script:WorldChunks = @{ '0,0' = [PSCustomObject]@{ ChunkX = 0; ChunkZ = 0; Mesh = [PSCustomObject]@{ IndexCount = 42 } } }
    }

    It 'creates schema-valid save envelope with required domains' {
        $env = New-SaveEnvelope -Slot 1
        $errors = $null

        $isValid = Test-SaveEnvelope -Envelope $env -ValidationErrors ([ref]$errors)

        $isValid | Should -Be $true
        @($errors).Count | Should -Be 0
        $env.Schema.Name | Should -Be 'voxel-rpg-save'
        $env.Data.Inventory.HotbarSelection | Should -Be 2
        $env.Data.World.Seed | Should -Be 777
    }

    It 'rejects envelope with missing data domains' {
        $bad = [PSCustomObject]@{
            Schema = [PSCustomObject]@{ Name = 'voxel-rpg-save'; Version = 1 }
            Slot = 1
            Data = [PSCustomObject]@{ PlayerPosition = [PSCustomObject]@{ X = 0; Y = 0; Z = 0 } }
        }
        $errors = $null

        $isValid = Test-SaveEnvelope -Envelope $bad -ValidationErrors ([ref]$errors)

        $isValid | Should -Be $false
        (@($errors) -join ';') | Should -Match 'Missing Data\.Inventory'
    }

    It 'writes and reads save file with round-trip validation' {
        $saveDir = Get-SaveDirectory
        if (Test-Path -LiteralPath $saveDir) {
            Remove-Item -LiteralPath $saveDir -Recurse -Force
        }

        Save-Game -Slot 1 | Out-Null
        $loaded = Read-SaveEnvelope -Slot 1

        $loaded.Schema.Name | Should -Be 'voxel-rpg-save'
        $loaded.Slot | Should -Be 1
        $loaded.Data.PlayerPosition.X | Should -Be 10
        $loaded.Data.Experience.Level | Should -Be 3
    }
}
