Describe 'Game/Inventory.ps1' {
    BeforeAll {
        function Register-UpdateCallback { param($Callback) }
        function Get-KeyDown { param($Key) return $false }

        . "$PSScriptRoot\..\..\Game\Inventory.ps1"
    }

    BeforeEach {
        Initialize-Inventory
    }

    It 'adds items using stack overflow into the next slot' {
        $ok = Add-InventoryItem -Name 'stone' -Count 70

        $ok | Should -Be $true
        (Get-InventorySlot -Index 0).ItemName | Should -Be 'stone'
        (Get-InventorySlot -Index 0).Count | Should -Be 64
        (Get-InventorySlot -Index 1).ItemName | Should -Be 'stone'
        (Get-InventorySlot -Index 1).Count | Should -Be 6
    }

    It 'removes from high index slots first to preserve hotbar stacks' {
        Add-InventoryItem -Name 'wood' -Count 64 | Out-Null
        Add-InventoryItem -Name 'wood' -Count 16 | Out-Null

        $removed = Remove-InventoryItem -Name 'wood' -Count 10

        $removed | Should -Be $true
        (Get-InventorySlot -Index 1).Count | Should -Be 6
        (Get-InventorySlot -Index 0).Count | Should -Be 64
    }

    It 'splits stack into first empty slot and preserves total count' {
        Add-InventoryItem -Name 'dirt' -Count 20 | Out-Null

        $splitOk = Split-InventoryStack -SlotIndex 0 -Amount 7

        $splitOk | Should -Be $true
        (Get-InventorySlot -Index 0).Count | Should -Be 13
        (Get-InventorySlot -Index 1).ItemName | Should -Be 'dirt'
        (Get-InventorySlot -Index 1).Count | Should -Be 7
        (Get-InventoryItemCount -Name 'dirt') | Should -Be 20
    }
}
