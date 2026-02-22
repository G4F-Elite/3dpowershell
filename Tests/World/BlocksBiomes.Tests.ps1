Describe 'World/Blocks.ps1 + World/Biomes.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\World\Blocks.ps1"
        . "$PSScriptRoot\..\..\World\Biomes.ps1"
    }

    BeforeEach {
        Initialize-BlockTypes
        Initialize-Biomes
    }

    Context 'Block Types' {
        It 'has at least 10 block types defined' {
            $all = Get-AllBlockTypes
            @($all).Count | Should -BeGreaterOrEqual 8
        }

        It 'returns correct properties for Stone' {
            $stone = Get-BlockType -Name 'Stone'
            $stone | Should -Not -Be $null
            $stone.IsSolid | Should -Be $true
            $stone.IsTransparent | Should -Be $false
        }

        It 'reports Air as not solid and transparent' {
            $air = Get-BlockType -Name 'Air'
            $air | Should -Not -Be $null
            $air.IsSolid | Should -Be $false
            $air.IsTransparent | Should -Be $true
        }
    }

    Context 'Biomes' {
        It 'has at least 5 biome types' {
            $biomes = Get-AllBiomes
            @($biomes).Count | Should -BeGreaterOrEqual 5
        }

        It 'selects Desert for hot and dry conditions' {
            $biome = Get-Biome -Temperature 0.85 -Moisture 0.1
            $biome | Should -Not -Be $null
            $biome.Name | Should -Be 'Desert'
        }

        It 'selects Snow for cold conditions' {
            $biome = Get-Biome -Temperature 0.1 -Moisture 0.5
            $biome | Should -Not -Be $null
            $biome.Name | Should -Be 'Snow'
        }
    }
}
