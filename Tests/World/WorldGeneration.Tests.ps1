Describe 'World generation (TerrainGen + World + Chunk)' {
    BeforeAll {
        function Register-UpdateCallback { param($Callback) }
        function Register-RenderCallback { param($Callback) }
        function Remove-ChunkMesh { param($Chunk) }
        function Initialize-Renderer { }
        function Get-DefaultShaderProgram { return 1 }
        function Use-ShaderProgram { param($Program) }
        function Get-GlControl { return [PSCustomObject]@{ ClientSize = [PSCustomObject]@{ Width = 800; Height = 600 }; Width = 800; Height = 600 } }
        function Get-ViewMatrix { return Matrix4-Identity }
        function Set-ShaderUniformMatrix4 { param($Program, $Name, $Matrix) }
        function Set-ShaderUniform1f { param($Program, $Name, $Value) }
        function Set-ShaderUniform3f { param($Program, $Name, $X, $Y, $Z) }
        function Get-BlockTextureAtlas { return [PSCustomObject]@{ Handle = 1 } }
        function Bind-Texture { param($Handle, $Unit) }
        function Set-ShaderUniform1i { param($Program, $Name, $Value) }
        function Draw-ChunkMesh { param($Chunk) }

        . "$PSScriptRoot\..\..\Engine\Math.ps1"
        function Get-CameraPosition { return (New-Vector3 -X 0 -Y 70 -Z 0) }

        . "$PSScriptRoot\..\..\World\TerrainGen.ps1"
        . "$PSScriptRoot\..\..\World\Biomes.ps1"
        . "$PSScriptRoot\..\..\World\Chunk.ps1"
        function Build-ChunkMesh { param($Chunk, [switch]$Force) }
        . "$PSScriptRoot\..\..\World\World.ps1"
    }

    BeforeEach {
        Initialize-Biomes
        Initialize-World -Seed 12345
    }

    It 'produces deterministic perlin samples for same seed and coordinates' {
        Initialize-PerlinPermutation -Seed 12345
        $n1 = Get-PerlinNoise2D -X 12.5 -Y -7.25
        $n2 = Get-PerlinNoise2D -X 12.5 -Y -7.25

        $n1 | Should -Be $n2
        $n1 | Should -BeGreaterOrEqual -1.1
        $n1 | Should -BeLessOrEqual 1.1
    }

    It 'returns valid terrain heights and deterministic chunk maps' {
        $h1 = Get-NoiseHeight -X 100 -Z 200
        $h2 = Get-NoiseHeight -X 100 -Z 200

        $h1 | Should -Be $h2
        $h1 | Should -BeGreaterOrEqual 20
        $h1 | Should -BeLessOrEqual 64

        $mapA = Get-ChunkHeightMap16x16 -BaseX 0 -BaseZ 0
        $mapB = Get-ChunkHeightMap16x16 -BaseX 0 -BaseZ 0
        $mapA.Length | Should -Be 256
        $mapA[42] | Should -Be $mapB[42]
    }

    It 'generates chunk data with non-empty terrain and stable block access' {
        $chunk = Generate-Chunk -ChunkX 0 -ChunkZ 0

        $chunk.ChunkX | Should -Be 0
        $chunk.ChunkZ | Should -Be 0
        $chunk.MaxSolidY | Should -BeGreaterThan 0
        ($chunk.Blocks | Measure-Object).Count | Should -Be 65536

        $b = Get-ChunkBlock -Chunk $chunk -X 0 -Y 0 -Z 0
        $b | Should -Not -Be $null
        $script:WorldChunks.ContainsKey('0,0') | Should -Be $true
    }
}
