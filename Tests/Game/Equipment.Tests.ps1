Describe 'Game/Equipment.ps1' {
    BeforeAll {
        $script:MockInventory = @{}

        function Get-ItemDefinition {
            param([string]$Name)
            $items = @{
                'iron sword' = [PSCustomObject]@{ Name = 'Iron Sword'; Type = 'Weapon'; Damage = 6; Durability = 251; AttackSpeed = 1.6; StackSize = 1 }
                'iron helmet' = [PSCustomObject]@{ Name = 'Iron Helmet'; Type = 'Armor'; Defense = 2; Durability = 166; Slot = 'helmet'; StackSize = 1 }
                'iron chestplate' = [PSCustomObject]@{ Name = 'Iron Chestplate'; Type = 'Armor'; Defense = 6; Durability = 241; Slot = 'chest'; StackSize = 1 }
                'stone' = [PSCustomObject]@{ Name = 'Stone'; Type = 'Resource'; StackSize = 64 }
            }
            return $items[$Name.ToLower()]
        }

        function Get-InventoryItemCount {
            param([string]$Name)
            $key = $Name.ToLower()
            if ($script:MockInventory.ContainsKey($key)) { return $script:MockInventory[$key] }
            return 0
        }

        function Add-InventoryItem {
            param([string]$Name, [int]$Count = 1)
            $key = $Name.ToLower()
            if (-not $script:MockInventory.ContainsKey($key)) { $script:MockInventory[$key] = 0 }
            $script:MockInventory[$key] += $Count
            return $true
        }

        function Remove-InventoryItem {
            param([string]$Name, [int]$Count = 1)
            $key = $Name.ToLower()
            if (-not $script:MockInventory.ContainsKey($key) -or $script:MockInventory[$key] -lt $Count) { return $false }
            $script:MockInventory[$key] -= $Count
            return $true
        }

        . "$PSScriptRoot\..\..\Game\Equipment.ps1"
    }

    BeforeEach {
        $script:MockInventory = @{ 'iron sword' = 1; 'iron helmet' = 1; 'iron chestplate' = 1 }
        Initialize-Equipment
    }

    It 'equips weapon in MainHand from inventory' {
        $result = Equip-Item -ItemName 'Iron Sword' -Slot 'MainHand'
        $result | Should -Be $true
        (Get-EquippedItem -Slot 'MainHand') | Should -Be 'Iron Sword'
        $script:MockInventory['iron sword'] | Should -Be 0
    }

    It 'rejects non-weapon items in MainHand' {
        $script:MockInventory['stone'] = 5
        $result = Equip-Item -ItemName 'Stone' -Slot 'MainHand'
        $result | Should -Be $false
        (Get-EquippedItem -Slot 'MainHand') | Should -Be ''
    }

    It 'equips armor in matching slot' {
        $result = Equip-Item -ItemName 'Iron Helmet' -Slot 'Helmet'
        $result | Should -Be $true
        (Get-EquippedItem -Slot 'Helmet') | Should -Be 'Iron Helmet'
    }

    It 'aggregates equipment stats correctly' {
        Equip-Item -ItemName 'Iron Sword' -Slot 'MainHand' | Out-Null
        Equip-Item -ItemName 'Iron Chestplate' -Slot 'Chest' | Out-Null

        $stats = Get-EquipmentStats
        $stats.TotalDamage | Should -BeGreaterThan 0
        $stats.TotalDefense | Should -BeGreaterThan 0
    }

    It 'unequips item back to inventory' {
        Equip-Item -ItemName 'Iron Sword' -Slot 'MainHand' | Out-Null
        $result = Unequip-Item -Slot 'MainHand'
        $result | Should -Be $true
        (Get-EquippedItem -Slot 'MainHand') | Should -Be ''
        $script:MockInventory['iron sword'] | Should -Be 1
    }
}
