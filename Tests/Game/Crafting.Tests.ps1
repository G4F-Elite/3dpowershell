Describe 'Game/Crafting.ps1 + Data/Recipes.ps1' {
    BeforeAll {
        $script:MockInventory = @{}

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

        . "$PSScriptRoot\..\..\Data\Items.ps1"
        . "$PSScriptRoot\..\..\Data\Recipes.ps1"
        . "$PSScriptRoot\..\..\Game\Crafting.ps1"
    }

    BeforeEach {
        $script:MockInventory = @{}
        Initialize-Items
        Initialize-CraftingRecipes
        Initialize-Crafting
    }

    It 'can craft planks from wood' {
        $script:MockInventory['wood'] = 4

        $canCraft = Test-CanCraft -Name 'Planks'
        $canCraft | Should -Be $true

        $result = Invoke-Craft -Name 'Planks'
        $result | Should -Be $true

        $script:MockInventory['wood'] | Should -Be 3
        $script:MockInventory['planks'] | Should -Be 4
    }

    It 'cannot craft when missing ingredients' {
        $script:MockInventory['wood'] = 0
        $canCraft = Test-CanCraft -Name 'Planks'
        $canCraft | Should -Be $false
    }

    It 'crafts multi-ingredient recipe (Wooden Sword)' {
        $script:MockInventory['planks'] = 10
        $script:MockInventory['stick'] = 10

        $result = Invoke-Craft -Name 'Wooden Sword'
        $result | Should -Be $true
        $script:MockInventory['wooden sword'] | Should -Be 1
        $script:MockInventory['planks'] | Should -Be 8
        $script:MockInventory['stick'] | Should -Be 9
    }

    It 'returns all recipes' {
        $all = Get-AllCraftingRecipes
        @($all).Count | Should -BeGreaterOrEqual 5
    }
}
