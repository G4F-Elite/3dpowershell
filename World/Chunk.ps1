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
$script:ChunkVerboseLogging = $true
$script:ChunkTopologyRevision = [int64]0

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
$script:TransparentBlockLookup = [bool[]]::new(256)
$script:TransparentBlockLookup[0] = $true
$script:TransparentBlockLookup[7] = $true

$script:ChunkReusableFaceIndexPattern = [uint32[]]@(
    [uint32]0,
    [uint32]1,
    [uint32]2,
    [uint32]0,
    [uint32]2,
    [uint32]3
)

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

function Update-ChunkMaxSolidYFromTop {
    <#
    .SYNOPSIS
        Recomputes Chunk.MaxSolidY by scanning downward from StartY.
    .DESCRIPTION
        Called only when removing a block at the previous MaxSolidY, which is
        an infrequent path. Keeps hot read paths fast by maintaining MaxSolidY
        incrementally during regular writes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Chunk,
        [Parameter(Mandatory = $true)]
        [int]$StartY
    )

    $blocks = $Chunk.Blocks
    if ($null -eq $blocks) {
        $Chunk.MaxSolidY = [int]-1
        return
    }

    if ($StartY -gt 255) { $StartY = 255 }
    if ($StartY -lt 0) {
        $Chunk.MaxSolidY = [int]-1
        return
    }

    for ($scanY = $StartY; $scanY -ge 0; $scanY--) {
        $yBase = $scanY * 256
        for ($scanZ = 0; $scanZ -lt 16; $scanZ++) {
            $zBase = $scanZ * 16
            for ($scanX = 0; $scanX -lt 16; $scanX++) {
                if ($blocks[$scanX + $zBase + $yBase] -ne [byte]0) {
                    $Chunk.MaxSolidY = [int]$scanY
                    return
                }
            }
        }
    }

    $Chunk.MaxSolidY = [int]-1
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
        MaxSolidY = [int]-1
        MeshDirty = $true
        MeshRevision = [int]0
        MeshBuiltRevision = [int]-1
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

    if ($Y -gt [int]$Chunk.MaxSolidY) {
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
    $currentId = $Chunk.Blocks[$index]
    if ($currentId -eq $BlockId) {
        return
    }

    $Chunk.Blocks[$index] = $BlockId

    if ($null -eq $Chunk.PSObject.Properties['MeshDirty']) {
        $Chunk | Add-Member -MemberType NoteProperty -Name MeshDirty -Value $true
    }
    else {
        $Chunk.MeshDirty = $true
    }

    if ($null -eq $Chunk.PSObject.Properties['MeshRevision']) {
        $Chunk | Add-Member -MemberType NoteProperty -Name MeshRevision -Value ([int]1)
    }
    else {
        $Chunk.MeshRevision = [int]$Chunk.MeshRevision + 1
    }
    $script:ChunkTopologyRevision = [int64]$script:ChunkTopologyRevision + 1

    if ($BlockId -ne [byte]0) {
        if ($Y -gt [int]$Chunk.MaxSolidY) {
            $Chunk.MaxSolidY = [int]$Y
        }
    }
    elseif ($Y -eq [int]$Chunk.MaxSolidY) {
        Update-ChunkMaxSolidYFromTop -Chunk $Chunk -StartY ($Y - 1)
    }
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
        $Chunk,
        [switch]$Force
    )

    if ($null -eq $Chunk.PSObject.Properties['MeshDirty']) {
        $Chunk | Add-Member -MemberType NoteProperty -Name MeshDirty -Value $true
    }
    if ($null -eq $Chunk.PSObject.Properties['MeshRevision']) {
        $Chunk | Add-Member -MemberType NoteProperty -Name MeshRevision -Value ([int]0)
    }
    if ($null -eq $Chunk.PSObject.Properties['MeshBuiltRevision']) {
        $Chunk | Add-Member -MemberType NoteProperty -Name MeshBuiltRevision -Value ([int]-1)
    }

    if (
        -not $Force -and
        $null -ne $Chunk.Mesh -and
        -not [bool]$Chunk.MeshDirty -and
        [int]$Chunk.MeshBuiltRevision -eq [int]$Chunk.MeshRevision
    ) {
        return
    }

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
    $transparentLookup = $script:TransparentBlockLookup
    $uvCache = $script:UVCache
    $blockNameCache = $script:BlockNameCache

    [int]$maxY = 255
    $maxY = [int]$Chunk.MaxSolidY
    if ($maxY -lt 0) {
        $Chunk.Mesh = $null
        $Chunk.MeshDirty = $false
        $Chunk.MeshBuiltRevision = [int]$Chunk.MeshRevision
        return
    }
    if ($maxY -gt 255) { $maxY = 255 }

    $verts = [System.Collections.Generic.List[float]]::new(131072)
    $indices = [System.Collections.Generic.List[uint32]]::new(98304)
    [int]$vertexCount = 0

    # Face definitions: direction offsets, normal, and 4 vertex positions relative to block origin
    # Each block occupies (x, y, z) to (x+1, y+1, z+1) in local coords
    # Vertex order: bottom-left, bottom-right, top-right, top-left (CCW winding)

    for ($y = 0; $y -le $maxY; $y++) {
        $yBase = $y * 256  # y * 16 * 16
        for ($z = 0; $z -lt 16; $z++) {
            $zBase = $z * 16
            for ($x = 0; $x -lt 16; $x++) {
                $idx = $x + $zBase + $yBase
                $blockId = $blocks[$idx]

                # Skip air blocks
                if ($blockId -eq 0) { continue }

                $blockName = $blockNameCache[$blockId]; if ($null -eq $blockName) { $blockName = Get-BlockName -BlockId $blockId; $blockNameCache[$blockId] = $blockName }
                $isTransparent = $transparentLookup[[int]$blockId]

                # World-space position of this block's origin corner
                [float]$wx = $worldOffsetX + $x
                [float]$wy = [float]$y
                [float]$wz = $worldOffsetZ + $z

                # --- Check +Y (top) face ---
                $ny = $y + 1
                if ($ny -gt $maxY) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $zBase + $ny * 256] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][0]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'top'; $uvCache[$blockId][0] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }

                # --- Check -Y (bottom) face ---
                $ny = $y - 1
                if ($ny -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $zBase + $ny * 256] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][1]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'bottom'; $uvCache[$blockId][1] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }

                # --- Check +Z (south) face ---
                $nz = $z + 1
                if ($nz -gt 15) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $nz * 16 + $yBase] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][2]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'south'; $uvCache[$blockId][2] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }

                # --- Check -Z (north) face ---
                $nz = $z - 1
                if ($nz -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$x + $nz * 16 + $yBase] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][3]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'north'; $uvCache[$blockId][3] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }

                # --- Check +X (east) face ---
                $nx = $x + 1
                if ($nx -gt 15) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$nx + $zBase + $yBase] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][4]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'east'; $uvCache[$blockId][4] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }

                # --- Check -X (west) face ---
                $nx = $x - 1
                if ($nx -lt 0) { $neighborId = [byte]0 }
                else { $neighborId = $blocks[$nx + $zBase + $yBase] }
                $neighborTransparent = $transparentLookup[[int]$neighborId]
                if ($neighborId -eq 0 -or ($neighborTransparent -and -not $isTransparent)) {
                    $uv = $uvCache[$blockId][5]; if ($null -eq $uv) { $uv = Get-BlockFaceUV -Atlas $atlas -BlockType $blockName -Face 'west'; $uvCache[$blockId][5] = $uv }
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
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 1))
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add($b)
                    [void]$indices.Add([uint32]($b + 2))
                    [void]$indices.Add([uint32]($b + 3))
                    $vertexCount += 4
                }
            }
        }
    }

    # No visible faces  - no mesh needed
    if ($indices.Count -eq 0) {
        $Chunk.Mesh = $null
        $Chunk.MeshDirty = $false
        $Chunk.MeshBuiltRevision = [int]$Chunk.MeshRevision
        if ($script:ChunkVerboseLogging) {
            Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ))  - empty mesh (no visible faces)." -ForegroundColor DarkGray
        }
        return
    }

    # Convert typed lists to arrays (single allocation each)
    [float[]]$vertexData = $verts.ToArray()
    [uint32[]]$indexData = $indices.ToArray()

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
        [OpenGL.BufferUsage]::StaticDraw
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
        [OpenGL.BufferUsage]::StaticDraw
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
    $Chunk.MeshDirty = $false
    $Chunk.MeshBuiltRevision = [int]$Chunk.MeshRevision

    if ($script:ChunkVerboseLogging) {
        $faceCount = [int]($indexCount / 6)
        Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ)) mesh built  - $faceCount faces, $indexCount indices, VAO: $vao." -ForegroundColor Green
    }
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

    if ($script:ChunkVerboseLogging) {
        Write-Host "[Chunk] Chunk ($($Chunk.ChunkX), $($Chunk.ChunkZ)) mesh removed (VAO: $($Chunk.Mesh.VAO))." -ForegroundColor DarkGray
    }
    $Chunk.Mesh = $null
}

function Get-ChunkTopologyRevision {
    return [int64]$script:ChunkTopologyRevision
}
