# ============================================================================
# World/World.ps1 - World Generation Orchestrator
# ============================================================================
# Coordinates chunk system, terrain generation, biomes, and block types to
# create a complete procedural voxel world. Manages chunk loading/unloading
# around the camera position and renders all visible chunks.
#
# Dependencies: Engine/OpenGL.ps1, Engine/Camera.ps1, Engine/Shader.ps1,
#   Engine/Texture.ps1, Engine/Mesh.ps1, Engine/Math.ps1,
#   World/Chunk.ps1, World/TerrainGen.ps1, World/Biomes.ps1, World/Blocks.ps1
# ============================================================================

# --- Module State ---
$script:WorldSeed          = [int]12345
$script:WorldChunks        = @{}
$script:WorldViewDistance   = [int]4
$script:WorldInitialized   = $false
$script:WorldChunkGenQueue = [System.Collections.ArrayList]::new()

# ============================================================================
# Initialize-World - Set up world systems and register callbacks
# ============================================================================

function Initialize-World {
    <#
    .SYNOPSIS
        Initializes the world generation system.
    .PARAMETER Seed
        Integer seed for deterministic world generation.
    .DESCRIPTION
        Sets the world seed, initializes the Perlin permutation table, and
        registers Update-World and Invoke-WorldRender as engine callbacks.
        Does NOT perform any GL calls (GL context may not be ready yet).
    #>
    param(
        [int]$Seed = 12345
    )

    $script:WorldSeed          = $Seed
    $script:WorldChunks        = @{}
    $script:WorldInitialized   = $false
    $script:WorldChunkGenQueue = [System.Collections.ArrayList]::new()

    # Initialize Perlin noise with deterministic seed
    Initialize-PerlinPermutation -Seed $Seed

    # Register callbacks (no GL calls here)
    Register-UpdateCallback ${function:Update-World}
    Register-RenderCallback ${function:Invoke-WorldRender}

    Write-Host "[World] World initialized with seed $Seed, view distance $script:WorldViewDistance chunks." -ForegroundColor Green
}

# ============================================================================
# Update-World - Per-frame update callback
# ============================================================================

function Update-World {
    <#
    .SYNOPSIS
        Per-frame world update. Loads/unloads chunks around camera.
    .DESCRIPTION
        Called automatically via update callback. Determines which chunks
        should be loaded based on camera position, queues missing chunks,
        and generates at most 2 new chunks per frame to avoid stutter.
        Unloads chunks outside view distance + 2 buffer zone.
    #>
    param($dt)

    # Get camera chunk coordinates
    $camPos = Get-CameraPosition
    [int]$camChunkX = [Math]::Floor($camPos.X / 16)
    [int]$camChunkZ = [Math]::Floor($camPos.Z / 16)

    $vd = $script:WorldViewDistance

    # --- Queue missing chunks within view distance ---
    for ($cx = $camChunkX - $vd; $cx -le $camChunkX + $vd; $cx++) {
        for ($cz = $camChunkZ - $vd; $cz -le $camChunkZ + $vd; $cz++) {
            $key = "$cx,$cz"
            if (-not $script:WorldChunks.ContainsKey($key)) {
                # Check if already in generation queue
                $alreadyQueued = $false
                foreach ($item in $script:WorldChunkGenQueue) {
                    if ($item.X -eq $cx -and $item.Z -eq $cz) {
                        $alreadyQueued = $true
                        break
                    }
                }
                if (-not $alreadyQueued) {
                    $script:WorldChunkGenQueue.Add([PSCustomObject]@{ X = $cx; Z = $cz }) | Out-Null
                }
            }
        }
    }

    # --- Generate at most 1 chunk per frame ---
    [int]$generated = 0
    while ($generated -lt 1 -and $script:WorldChunkGenQueue.Count -gt 0) {
        # Only generate if GL context is ready (WorldInitialized set by render callback)
        if (-not $script:WorldInitialized) { break }

        # Enforce max 64 chunks loaded
        if ($script:WorldChunks.Count -ge 64) { break }

        $item = $script:WorldChunkGenQueue[0]
        $script:WorldChunkGenQueue.RemoveAt(0)

        $key = "$($item.X),$($item.Z)"
        if (-not $script:WorldChunks.ContainsKey($key)) {
            Generate-Chunk -ChunkX $item.X -ChunkZ $item.Z
            $generated++
        }
    }

    # --- Unload chunks outside view distance + 2 ---
    $unloadDist = $vd + 2
    $keysToRemove = [System.Collections.ArrayList]::new()
    foreach ($key in $script:WorldChunks.Keys) {
        $parts = $key.Split(',')
        [int]$cx = [int]$parts[0]
        [int]$cz = [int]$parts[1]
        $dx = [Math]::Abs($cx - $camChunkX)
        $dz = [Math]::Abs($cz - $camChunkZ)
        if ($dx -gt $unloadDist -or $dz -gt $unloadDist) {
            $keysToRemove.Add($key) | Out-Null
        }
    }
    foreach ($key in $keysToRemove) {
        $parts = $key.Split(',')
        Remove-WorldChunk -ChunkX ([int]$parts[0]) -ChunkZ ([int]$parts[1])
    }
}

# ============================================================================
# Invoke-WorldRender - Per-frame render callback
# ============================================================================

function Invoke-WorldRender {
    <#
    .SYNOPSIS
        Renders all loaded world chunks with proper shader setup.
    .DESCRIPTION
        On first call, performs lazy GL initialization (calls Initialize-Renderer).
        Sets up shader program, projection/view/model matrices, lighting uniforms,
        binds texture atlas, and draws all loaded chunk meshes.
    #>
    param($dt)

    # --- Lazy GL initialization on first render frame ---
    if (-not $script:WorldInitialized) {
        Initialize-Renderer
        $script:WorldInitialized = $true
        Write-Host "[World] GL resources initialized on first render frame." -ForegroundColor Green
    }

    # --- Set up shader ---
    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program

    # --- Projection matrix ---
    $glCtrl = Get-GlControl
    [float]$width  = [float]$glCtrl.ClientSize.Width
    [float]$height = [float]$glCtrl.ClientSize.Height
    if ($height -lt 1) { $height = 1 }
    [float]$aspect = $width / $height
    [float]$fovRad = [float]([Math]::PI / 3.0)  # 60 degrees
    $proj = Matrix4-Perspective -FovRadians $fovRad -Aspect $aspect -Near 0.1 -Far 500.0

    # --- View matrix from camera ---
    $view = Get-ViewMatrix

    # --- Model matrix (identity - chunks use world-space coordinates) ---
    $model = Matrix4-Identity

    # --- Set MVP uniforms ---
    Set-ShaderUniformMatrix4 -Program $program -Name 'uProjection' -Matrix $proj
    Set-ShaderUniformMatrix4 -Program $program -Name 'uView'       -Matrix $view
    Set-ShaderUniformMatrix4 -Program $program -Name 'uModel'      -Matrix $model

    # --- Lighting uniforms ---
    Set-ShaderUniform1f -Program $program -Name 'uAmbient'  -Value 0.3
    # Normalized sun direction (0.3, 0.8, 0.5) - approx normalized
    [float]$lx = 0.3; [float]$ly = 0.8; [float]$lz = 0.5
    [float]$len = [Math]::Sqrt($lx * $lx + $ly * $ly + $lz * $lz)
    if ($len -gt 0) { $lx /= $len; $ly /= $len; $lz /= $len }
    Set-ShaderUniform3f -Program $program -Name 'uLightDir' -X $lx -Y $ly -Z $lz

    # --- Bind texture atlas ---
    $atlas = Get-BlockTextureAtlas
    Bind-Texture -Handle $atlas.Handle -Unit 0
    Set-ShaderUniform1i -Program $program -Name 'uTexture' -Value 0

    # --- Draw all loaded chunks ---
    foreach ($key in $script:WorldChunks.Keys) {
        $chunk = $script:WorldChunks[$key]
        Draw-ChunkMesh -Chunk $chunk
    }
}

# ============================================================================
# Generate-Chunk - Create and populate a chunk with terrain data
# ============================================================================

function Generate-Chunk {
    <#
    .SYNOPSIS
        Generates a new chunk at the given chunk coordinates.
    .DESCRIPTION
        Creates an empty chunk, fills it with terrain blocks based on Perlin
        noise height and biome selection, optionally places trees, builds
        the chunk mesh (GL call), and stores it in the world hashtable.
    .PARAMETER ChunkX
        Chunk X coordinate.
    .PARAMETER ChunkZ
        Chunk Z coordinate.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$ChunkX,
        [Parameter(Mandatory = $true)]
        [int]$ChunkZ
    )

    $chunk = New-Chunk -ChunkX $ChunkX -ChunkZ $ChunkZ

    for ($x = 0; $x -lt 16; $x++) {
        for ($z = 0; $z -lt 16; $z++) {
            # World coordinates for this column
            [int]$worldX = $ChunkX * 16 + $x
            [int]$worldZ = $ChunkZ * 16 + $z

            # Get base terrain height from noise
            $baseHeight = Get-NoiseHeight -X $worldX -Z $worldZ -Seed $script:WorldSeed

            # Get biome for this column using temperature and moisture noise
            [double]$tempNoise = Get-PerlinNoise2D -X ($worldX * 0.005) -Y ($worldZ * 0.005)
            [float]$temp = [float]($tempNoise * 0.5 + 0.5)

            [double]$moistNoise = Get-PerlinNoise2D -X ($worldX * 0.005 + 1000) -Y ($worldZ * 0.005 + 1000)
            [float]$moist = [float]($moistNoise * 0.5 + 0.5)

            $biome = Get-Biome -Temperature $temp -Moisture $moist

            # Adjust height based on biome parameters
            [int]$height = [int][Math]::Floor($biome.BaseHeight + ($baseHeight - 38) * $biome.HeightVariation)

            # Clamp height to valid range
            if ($height -lt 1) { $height = 1 }
            if ($height -gt 255) { $height = 255 }

            # Fill column blocks
            for ($y = 0; $y -le $height; $y++) {
                if ($y -eq 0) {
                    # Bedrock layer (stone)
                    $chunk.Blocks[$x + $z * 16 + $y * 256] = 1
                }
                elseif ($y -le ($height - 4)) {
                    # Filler (usually stone)
                    $chunk.Blocks[$x + $z * 16 + $y * 256] = $biome.FillerBlock
                }
                elseif ($y -le ($height - 1)) {
                    # Sub-surface (usually dirt)
                    $chunk.Blocks[$x + $z * 16 + $y * 256] = $biome.SubSurfaceBlock
                }
                else {
                    # Surface block (grass, sand, etc.)
                    $chunk.Blocks[$x + $z * 16 + $y * 256] = $biome.SurfaceBlock
                }
            }

            # Fill water if height < water level
            [int]$waterLevel = $biome.WaterLevel
            if ($height -lt $waterLevel) {
                for ($y = $height + 1; $y -le $waterLevel; $y++) {
                    $chunk.Blocks[$x + $z * 16 + $y * 256] = 7
                }
            }

            # --- Optional: Place trees ---
            if ($biome.TreeDensity -gt 0 -and $biome.SurfaceBlock -eq [byte]3 -and $height -gt $waterLevel) {
                # Deterministic tree placement using hash
                [long]$hashVal = [System.Math]::Abs($worldX * 73856093 -bxor $worldZ * 19349663)
                [double]$treeCheck = ($hashVal % 1000) / 1000.0
                if ($treeCheck -lt $biome.TreeDensity) {
                    # Ensure trunk fits within chunk boundaries (leave 1-block border)
                    if ($x -ge 2 -and $x -le 13 -and $z -ge 2 -and $z -le 13) {
                        # Trunk: 4 blocks of wood above surface
                        [int]$trunkBase = $height + 1
                        for ($ty = 0; $ty -lt 4; $ty++) {
                            $treeY = $trunkBase + $ty
                            if ($treeY -lt 256) {
                                $chunk.Blocks[$x + $z * 16 + $treeY * 256] = 5
                            }
                        }

                        # Leaf canopy: 3x3x3 on top of trunk
                        [int]$leafBase = $trunkBase + 4
                        for ($lx = -1; $lx -le 1; $lx++) {
                            for ($lz = -1; $lz -le 1; $lz++) {
                                for ($ly = 0; $ly -lt 3; $ly++) {
                                    [int]$leafX = $x + $lx
                                    [int]$leafZ = $z + $lz
                                    [int]$leafY = $leafBase + $ly
                                    if ($leafY -lt 256 -and $leafX -ge 0 -and $leafX -le 15 -and $leafZ -ge 0 -and $leafZ -le 15) {
                                        # Don't overwrite trunk with leaves
                                        if (-not ($lx -eq 0 -and $lz -eq 0 -and $ly -eq 0)) {
                                            $chunk.Blocks[$leafX + $leafZ * 16 + $leafY * 256] = 6
                                        }
                                        else {
                                            # Top of trunk gets leaves too
                                            $chunk.Blocks[$leafX + $leafZ * 16 + $leafY * 256] = 6
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    # Build mesh (GL call - only valid inside render/update callback after GL context)
    Build-ChunkMesh -Chunk $chunk

    # Store in world hashtable
    $key = "$ChunkX,$ChunkZ"
    $script:WorldChunks[$key] = $chunk

    Write-Host "[World] Generated chunk ($ChunkX, $ChunkZ) - biome sampling complete." -ForegroundColor DarkCyan

    return $chunk
}

# ============================================================================
# Remove-WorldChunk - Unload a chunk and free its GPU resources
# ============================================================================

function Remove-WorldChunk {
    <#
    .SYNOPSIS
        Removes a chunk from the world, freeing its GPU mesh resources.
    .PARAMETER ChunkX
        Chunk X coordinate.
    .PARAMETER ChunkZ
        Chunk Z coordinate.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$ChunkX,
        [Parameter(Mandatory = $true)]
        [int]$ChunkZ
    )

    $key = "$ChunkX,$ChunkZ"
    if ($script:WorldChunks.ContainsKey($key)) {
        $chunk = $script:WorldChunks[$key]
        Remove-ChunkMesh -Chunk $chunk
        $script:WorldChunks.Remove($key)
        Write-Host "[World] Unloaded chunk ($ChunkX, $ChunkZ)." -ForegroundColor DarkGray
    }
}
