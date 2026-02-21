# ============================================================================
# World/Chunk.ps1  - Voxel Chunk Data, Mesh Generation
# ============================================================================
# A chunk is a 16x256x16 column of blocks stored as a flat byte array.
# Provides New-Chunk (creates empty chunk), Get/Set-ChunkBlock (block access),
# Build-ChunkMesh (generates optimized mesh with face culling),
# Draw-ChunkMesh (renders), and Remove-ChunkMesh (GPU cleanup).
# ============================================================================

# --- Constants ---
$script:CHUNK_SIZE_X = 16
$script:CHUNK_SIZE_Y = 256
$script:CHUNK_SIZE_Z = 16
$script:CHUNK_BLOCK_COUNT = 65536  # 16 * 256 * 16

# --- Block ID to Name Mapping ---
# Raw block names (human-readable)
$script:BlockNames = @{
    [byte]0 = 'air'
    [byte]1 = 'stone'
    [byte]2 = 'dirt'
    [byte]3 = 'grass'
    [byte]4 = 'sand'
    [byte]5 = 'wood'
    [byte]6 = 'leaves'
    [byte]7 = 'water'
}

# Texture fallback mapping (block name -> texture block type for Get-BlockFaceUV)
$script:BlockTextureMap = @{
    'stone'  = 'stone'
    'dirt'   = 'dirt'
    'grass'  = 'grass'
    'sand'   = 'dirt'     # fallback until sand texture added
    'wood'   = 'wood'
    'leaves' = 'grass'    # fallback until leaves texture added
    'water'  = 'stone'    # fallback, treat as transparent for face culling
}

# --- Transparent block IDs (faces visible when adjacent) ---
$script:TransparentBlocks = @{
    [byte]0 = $true   # air
    [byte]7 = $true   # water (transparent)
}

# ============================================================================
# Helper Functions
# ============================================================================

function Get-BlockName {
    <#
    .SYNOPSIS
        Maps a block ID byte to the texture block type name string.
    .PARAMETER BlockId
        Byte block ID (0-7).
    .OUTPUTS
        String block type name for texture lookup via Get-BlockFaceUV.
    #>
    param([byte]$BlockId)

    if ($script:BlockNames.ContainsKey($BlockId)) {
        $name = $script:BlockNames[$BlockId]
        if ($script:BlockTextureMap.ContainsKey($name)) {
            return $script:BlockTextureMap[$name]
        }
        return $name
    }
    return 'stone'
}

# ============================================================================
# Public Functions  - Chunk Data
# ============================================================================

function New-Chunk {
    <#
    .SYNOPSIS
        Creates a new empty chunk at the given chunk coordinates.
    .PARAMETER ChunkX
        Integer chunk X coordinate. World X = ChunkX * 16.
    .PARAMETER ChunkZ
        Integer chunk Z coordinate. World Z = ChunkZ * 16.
    .OUTPUTS
        PSCustomObject with ChunkX, ChunkZ, Blocks (byte[65536]), Mesh ($null).
    #>
    param(
        [int]$ChunkX = 0,
        [int]$ChunkZ = 0
    )

    $blocks = [byte[]]::new(65536)

    return [PSCustomObject]@{
        ChunkX = $ChunkX
        ChunkZ = $ChunkZ
        Blocks = $blocks
        Mesh   = $null
    }
}

function Get-ChunkBlock {
    <#
    .SYNOPSIS
        Gets the block ID at local coordinates (x, y, z) within a chunk.
    .PARAMETER Chunk
        Chunk PSCustomObject.
    .PARAMETER X
        Local X (0-15).
    .PARAMETER Y
        Local Y (0-255).
    .PARAMETER Z
        Local Z (0-15).
    .OUTPUTS
        Byte block ID.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk,
        [Parameter(Mandatory = $true)]
        [int]$X,
        [Parameter(Mandatory = $true)]
        [int]$Y,
        [Parameter(Mandatory = $true)]
        [int]$Z
    )

    if ($X -lt 0 -or $X -gt 15 -or $Y -lt 0 -or $Y -gt 255 -or $Z -lt 0 -or $Z -gt 15) {
        return [byte]0
    }

    $index = $X + $Z * 16 + $Y * 256
    return $Chunk.Blocks[$index]
}

function Set-ChunkBlock {
    <#
    .SYNOPSIS
        Sets the block ID at local coordinates (x, y, z) within a chunk.
    .PARAMETER Chunk
        Chunk PSCustomObject.
    .PARAMETER X
        Local X (0-15).
    .PARAMETER Y
        Local Y (0-255).
    .PARAMETER Z
        Local Z (0-15).
    .PARAMETER BlockId
        Byte block ID to set.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk,
        [Parameter(Mandatory = $true)]
        [int]$X,
        [Parameter(Mandatory = $true)]
        [int]$Y,
        [Parameter(Mandatory = $true)]
        [int]$Z,
        [Parameter(Mandatory = $true)]
        [byte]$BlockId
    )

    if ($X -lt 0 -or $X -gt 15 -or $Y -lt 0 -or $Y -gt 255 -or $Z -lt 0 -or $Z -gt 15) {
        return
    }

    $index = $X + $Z * 16 + $Y * 256
    $Chunk.Blocks[$index] = $BlockId
}

# ============================================================================
# Public Functions  - Mesh Generation
# ============================================================================

function Build-ChunkMesh {
    <#
    .SYNOPSIS
        Generates an optimized VAO/VBO/EBO mesh for a chunk with face culling.
    .DESCRIPTION
        Iterates all non-air blocks, checks 6 neighbors, and only emits faces
        adjacent to air or transparent blocks. Uses the same vertex format as
        Engine/Mesh.ps1: aPosition(vec3) + aTexCoord(vec2) + aNormal(vec3).
        MUST be called when GL context is active.
    .PARAMETER Chunk
        Chunk PSCustomObject from New-Chunk.
    .OUTPUTS
        Updates Chunk.Mesh with PSCustomObject (VAO, VBO, EBO, IndexCount)
        or $null if chunk has no visible faces.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk
    )

    # Clean up existing mesh if rebuilding
    if ($null -ne $Chunk.Mesh) {
        Remove-ChunkMesh -Chunk $Chunk
    }

    $atlas = Get-BlockTextureAtlas
    if ($null -eq $script:UVCache) {
        $script:UVCache = New-Object 'PSCustomObject[][]' 256
        $script:BlockNameCache = New-Object 'string[]' 256
        for ($i=0; $i -lt 256; $i++) {
            $script:UVCache[$i] = New-Object 'PSCustomObject[]' 6
        }
    }

    $blocks = $Chunk.Blocks
    $worldOffsetX = [float]($Chunk.ChunkX * 16)
    $worldOffsetZ = [float]($Chunk.ChunkZ * 16)

    $verts = [System.Collections.ArrayList]::new()
    $indices = [System.Collections.ArrayList]::new()
    [int]$vertexCount = 0

    # Face definitions: direction offsets, normal, and 4 vertex positions relative to block origin
    # Each block occupies (x, y, z) to (x+1, y+1, z+1) in local coords
    # Vertex order: bottom-left, bottom-right, top-right, top-left (CCW winding)

    for ($y = 0; $y -lt 256; $y++) {
        $yBase = $y * 256  # y * 16 * 16
        for ($z = 0; $z -lt 16; $z++) {
            $zBase = $z * 16
            for ($x = 0; $x -lt 16; $x++) {
                $idx = $x + $zBase + $yBase
                $blockId = $blocks[$idx]

                # Skip air blocks
                if ($blockId -eq 0) { continue }

                $blockName = $script:BlockNameCache[$blockId]; if ($null -eq $blockName) { $blockName = Get-BlockName -BlockId $blockId; $script:BlockNameCache[$blockId] = $blockName }
                $isTransparent = $script:TransparentBlocks.ContainsKey($blockId)

                # World-space position of this block's origin corner
                [float]$wx = $worldOffsetX + $x
                [float]$wy = [float]$y
                [float]$wz = $worldOffsetZ + $z

                # --- Check +Y (top) face ---
                $ny = $y + 1
                if ($ny -gt 255) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $zBase + $ny * 256] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][0]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'top'; $script:UVCache[$blockId][0] = $uv }
                    # top face: y+1 plane, normal (0,1,0)
                    [float]$fy = $wy + 1.0
                    [void]$verts.Add($wx); [void]$verts.Add($fy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($fy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($fy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx); [void]$verts.Add($fy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]1); [void]$verts.Add([float]0)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }

                # --- Check -Y (bottom) face ---
                $ny = $y - 1
                if ($ny -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $zBase + $ny * 256] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][1]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'bottom'; $script:UVCache[$blockId][1] = $uv }
                    # bottom face: y plane, normal (0,-1,0)
                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]-1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]-1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]-1); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]-1); [void]$verts.Add([float]0)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }

                # --- Check +Z (south) face ---
                $nz = $z + 1
                if ($nz -gt 15) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $nz * 16 + $yBase] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][2]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'south'; $script:UVCache[$blockId][2] = $uv }
                    [float]$fz = $wz + 1.0
                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($fz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]1)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy); [void]$verts.Add($fz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]1)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy + 1.0); [void]$verts.Add($fz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]1)

                    [void]$verts.Add($wx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($fz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]1)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }

                # --- Check -Z (north) face ---
                $nz = $z - 1
                if ($nz -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $nz * 16 + $yBase] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][3]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'north'; $script:UVCache[$blockId][3] = $uv }
                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]-1)

                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]-1)

                    [void]$verts.Add($wx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]-1)

                    [void]$verts.Add($wx + 1.0); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]0); [void]$verts.Add([float]0); [void]$verts.Add([float]-1)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }

                # --- Check +X (east) face ---
                $nx = $x + 1
                if ($nx -gt 15) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$nx + $zBase + $yBase] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][4]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'east'; $script:UVCache[$blockId][4] = $uv }
                    [float]$fx = $wx + 1.0
                    [void]$verts.Add($fx); [void]$verts.Add($wy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($fx); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($fx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($fx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }

                # --- Check -X (west) face ---
                $nx = $x - 1
                if ($nx -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$nx + $zBase + $yBase] }
                $neighborTransparent = $script:TransparentBlocks.ContainsKey($neighborId)
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $script:UVCache[$blockId][5]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'west'; $script:UVCache[$blockId][5] = $uv }
                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]-1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx); [void]$verts.Add($wy); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V1)
                    [void]$verts.Add([float]-1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz + 1.0)
                    [void]$verts.Add($uv.U1); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]-1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    [void]$verts.Add($wx); [void]$verts.Add($wy + 1.0); [void]$verts.Add($wz)
                    [void]$verts.Add($uv.U0); [void]$verts.Add($uv.V0)
                    [void]$verts.Add([float]-1); [void]$verts.Add([float]0); [void]$verts.Add([float]0)

                    $b = [uint32]$vertexCount
                    [void]$indices.Add($b); [void]$indices.Add($b + 1); [void]$indices.Add($b + 2)
                    [void]$indices.Add($b); [void]$indices.Add($b + 2); [void]$indices.Add($b + 3)
                    $vertexCount += 4
                }
            }
        }
    }

    # No visible faces  - no mesh needed
    if ($indices.Count -eq 0) {
        $Chunk.Mesh = $null
        Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ))  - empty mesh (no visible faces)." -ForegroundColor DarkGray
        return
    }

    # Convert ArrayLists to typed arrays
    [float[]]$vertexData = [float[]]::new($verts.Count)
    for ($i = 0; $i -lt $verts.Count; $i++) {
        $vertexData[$i] = [float]$verts[$i]
    }

    [uint32[]]$indexData = [uint32[]]::new($indices.Count)
    for ($i = 0; $i -lt $indices.Count; $i++) {
        $indexData[$i] = [uint32]$indices[$i]
    }

    $indexCount = $indexData.Length

    # --- Create VAO ---
    [uint32[]]$vaoIds = @([uint32]0)
    [OpenGL.Gl]::GenVertexArrays($vaoIds)
    $vao = $vaoIds[0]
    [OpenGL.Gl]::BindVertexArray($vao)

    # --- Create VBO ---
    [uint32[]]$vboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($vboIds)
    $vbo = $vboIds[0]
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $vbo)

    [uint32]$vertexByteSize = [uint32]($vertexData.Length * 4)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ArrayBuffer,
        $vertexByteSize,
        $vertexData,
        [OpenGL.BufferUsage]::DynamicDraw
    )

    # --- Create EBO ---
    [uint32[]]$eboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($eboIds)
    $ebo = $eboIds[0]
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ElementArrayBuffer, $ebo)

    [uint32]$indexByteSize = [uint32]($indexData.Length * 4)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ElementArrayBuffer,
        $indexByteSize,
        $indexData,
        [OpenGL.BufferUsage]::DynamicDraw
    )

    # --- Set up vertex attribute pointers ---
    $program = Get-DefaultShaderProgram
    [int]$stride = 32

    # aPosition (vec3)  - offset 0
    $posLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aPosition')
    if ($posLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$posLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$posLoc, 3,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(0)
        )
    }

    # aTexCoord (vec2)  - offset 12 bytes
    $texLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aTexCoord')
    if ($texLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$texLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$texLoc, 2,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(12)
        )
    }

    # aNormal (vec3)  - offset 20 bytes
    $normLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aNormal')
    if ($normLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$normLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$normLoc, 3,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(20)
        )
    }

    # Unbind VAO (leave EBO bound inside VAO state)
    [OpenGL.Gl]::BindVertexArray([uint32]0)

    $Chunk.Mesh = [PSCustomObject]@{
        VAO        = $vao
        VBO        = $vbo
        EBO        = $ebo
        IndexCount = $indexCount
    }

    $faceCount = [int]($indexCount / 6)
    Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ)) mesh built  - $faceCount faces, $indexCount indices, VAO: $vao." -ForegroundColor Green
}

# ============================================================================
# Public Functions  - Rendering, Cleanup
# ============================================================================

function Draw-ChunkMesh {
    <#
    .SYNOPSIS
        Renders a chunk mesh using its VAO and index buffer.
    .PARAMETER Chunk
        Chunk PSCustomObject with populated Mesh property.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk
    )

    if ($null -eq $Chunk.Mesh) { return }

    [OpenGL.Gl]::BindVertexArray($Chunk.Mesh.VAO)
    [OpenGL.Gl]::DrawElements(
        [OpenGL.PrimitiveType]::Triangles,
        $Chunk.Mesh.IndexCount,
        [OpenGL.DrawElementsType]::UnsignedInt,
        [IntPtr]::Zero
    )
    [OpenGL.Gl]::BindVertexArray([uint32]0)
}

function Remove-ChunkMesh {
    <#
    .SYNOPSIS
        Deletes GPU resources (VAO, VBO, EBO) for a chunk mesh.
    .PARAMETER Chunk
        Chunk PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk
    )

    if ($null -eq $Chunk.Mesh) { return }

    if ($Chunk.Mesh.VAO -gt 0) {
        [uint32[]]$vaoArr = @($Chunk.Mesh.VAO)
        [OpenGL.Gl]::DeleteVertexArrays($vaoArr)
    }
    if ($Chunk.Mesh.VBO -gt 0) {
        [uint32[]]$vboArr = @($Chunk.Mesh.VBO)
        [OpenGL.Gl]::DeleteBuffers($vboArr)
    }
    if ($Chunk.Mesh.EBO -gt 0) {
        [uint32[]]$eboArr = @($Chunk.Mesh.EBO)
        [OpenGL.Gl]::DeleteBuffers($eboArr)
    }

    Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ)) mesh removed (VAO: $($Chunk.Mesh.VAO))." -ForegroundColor DarkGray
    $Chunk.Mesh = $null
}
