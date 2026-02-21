# ============================================================================
# Engine/Texture.ps1 — Procedural Texture Generation & Atlas Management
# ============================================================================
# Generates block textures procedurally (no external image files) and uploads
# them to the GPU as OpenGL textures. Provides a texture atlas system that
# arranges all block textures into a single GPU texture with UV lookup.
# ============================================================================

# --- Script-scope State ---
$script:BlockTextureAtlas = $null

# --- Block Texture Type Definitions ---
# Maps block type + face to a texture generator function name and seed
$script:TextureTypes = @{
    'dirt'       = @{ Seed = 100 }
    'stone'      = @{ Seed = 200 }
    'grass_top'  = @{ Seed = 300 }
    'grass_side' = @{ Seed = 400 }
    'wood_side'  = @{ Seed = 500 }
    'wood_top'   = @{ Seed = 600 }
}

# --- Default face-to-texture mapping for standard block types ---
$script:BlockFaceMapping = @{
    'dirt'  = @{ top = 'dirt'; bottom = 'dirt'; north = 'dirt'; south = 'dirt'; east = 'dirt'; west = 'dirt' }
    'stone' = @{ top = 'stone'; bottom = 'stone'; north = 'stone'; south = 'stone'; east = 'stone'; west = 'stone' }
    'grass' = @{ top = 'grass_top'; bottom = 'dirt'; north = 'grass_side'; south = 'grass_side'; east = 'grass_side'; west = 'grass_side' }
    'wood'  = @{ top = 'wood_top'; bottom = 'wood_top'; north = 'wood_side'; south = 'wood_side'; east = 'wood_side'; west = 'wood_side' }
}

# ============================================================================
# Internal Helpers — Pixel Manipulation
# ============================================================================

function Set-Pixel {
    <#
    .SYNOPSIS
        Sets a pixel in a byte array at (x, y) for a given texture width.
    #>
    param(
        [byte[]]$Data,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [byte]$R,
        [byte]$G,
        [byte]$B,
        [byte]$A = 255
    )

    $offset = ($Y * $Width + $X) * 4
    $Data[$offset]     = $R
    $Data[$offset + 1] = $G
    $Data[$offset + 2] = $B
    $Data[$offset + 3] = $A
}

function Clamp-Byte {
    <#
    .SYNOPSIS
        Clamps an integer to the 0-255 byte range.
    #>
    param([int]$Value)

    if ($Value -lt 0) { return [byte]0 }
    if ($Value -gt 255) { return [byte]255 }
    return [byte]$Value
}

# ============================================================================
# Internal Helpers — Procedural Texture Generators
# ============================================================================

function Generate-DirtTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 dirt texture: brown base with darker noise and pebbles.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(100)

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            # Brown base with noise
            $noise = $rng.Next(-20, 15)
            [byte]$r = Clamp-Byte (140 + $noise)
            [byte]$g = Clamp-Byte (100 + $noise)
            [byte]$b = Clamp-Byte (60 + [int]($noise * 0.5))

            # Occasional darker pebble spots (~12% chance)
            if ($rng.Next(100) -lt 12) {
                $r = Clamp-Byte ($r - 30)
                $g = Clamp-Byte ($g - 25)
                $b = Clamp-Byte ($b - 15)
            }

            Set-Pixel $data $x $y $Size $r $g $b 255
        }
    }

    return ,$data
}

function Generate-StoneTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 stone texture: gray base with darker veins/cracks.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(200)

    # Pre-generate a simple vein pattern using a second RNG
    $veinRng = [System.Random]::new(201)
    $veinMap = [int[]]::new($Size * $Size)
    # Create a few random crack lines
    for ($line = 0; $line -lt 3; $line++) {
        $sx = $veinRng.Next(0, $Size)
        $sy = $veinRng.Next(0, $Size)
        $len = $veinRng.Next(6, 12)
        for ($step = 0; $step -lt $len; $step++) {
            $px = [Math]::Max(0, [Math]::Min($Size - 1, $sx))
            $py = [Math]::Max(0, [Math]::Min($Size - 1, $sy))
            $veinMap[$py * $Size + $px] = 1
            # Also mark adjacent pixel for thicker veins
            $apx = [Math]::Max(0, [Math]::Min($Size - 1, $sx + 1))
            $veinMap[$py * $Size + $apx] = 1
            # Random walk for crack direction
            $sx += $veinRng.Next(-1, 2)
            $sy += $veinRng.Next(0, 2)
        }
    }

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $noise = $rng.Next(-12, 10)
            [byte]$gray = Clamp-Byte (128 + $noise)

            # Darken veins
            if ($veinMap[$y * $Size + $x] -eq 1) {
                $gray = Clamp-Byte ($gray - 35)
            }

            Set-Pixel $data $x $y $Size $gray $gray (Clamp-Byte ($gray + 5)) 255
        }
    }

    return ,$data
}

function Generate-GrassTopTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 grass top texture: green base with lighter variations.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(300)

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $noise = $rng.Next(-20, 20)
            [byte]$r = Clamp-Byte (75 + [int]($noise * 0.4))
            [byte]$g = Clamp-Byte (160 + $noise)
            [byte]$b = Clamp-Byte (50 + [int]($noise * 0.3))

            # Occasional lighter grass blade highlights (~15%)
            if ($rng.Next(100) -lt 15) {
                $r = Clamp-Byte ($r + 15)
                $g = Clamp-Byte ($g + 25)
                $b = Clamp-Byte ($b + 10)
            }

            Set-Pixel $data $x $y $Size $r $g $b 255
        }
    }

    return ,$data
}

function Generate-GrassSideTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 grass side texture: dirt bottom 2/3, green strip top 1/3.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(400)

    # Compute the transition row (top 1/3 = green, bottom 2/3 = dirt)
    # Row 0 = top of texture, so rows 0..greenEnd are green
    $greenEnd = [int]([Math]::Floor($Size / 3.0)) - 1  # ~5 for 16px

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $noise = $rng.Next(-15, 15)

            if ($y -le $greenEnd) {
                # Green grass strip (top 1/3)
                [byte]$r = Clamp-Byte (75 + [int]($noise * 0.4))
                [byte]$g = Clamp-Byte (150 + $noise)
                [byte]$b = Clamp-Byte (48 + [int]($noise * 0.3))
            }
            elseif ($y -eq ($greenEnd + 1)) {
                # Transition row — mix of green and brown
                [byte]$r = Clamp-Byte (110 + $noise)
                [byte]$g = Clamp-Byte (120 + $noise)
                [byte]$b = Clamp-Byte (55 + [int]($noise * 0.5))
            }
            else {
                # Dirt base (bottom 2/3)
                [byte]$r = Clamp-Byte (140 + $noise)
                [byte]$g = Clamp-Byte (100 + $noise)
                [byte]$b = Clamp-Byte (60 + [int]($noise * 0.5))

                # Occasional pebbles
                if ($rng.Next(100) -lt 10) {
                    $r = Clamp-Byte ($r - 25)
                    $g = Clamp-Byte ($g - 20)
                    $b = Clamp-Byte ($b - 12)
                }
            }

            Set-Pixel $data $x $y $Size $r $g $b 255
        }
    }

    return ,$data
}

function Generate-WoodSideTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 wood side texture: brown with vertical grain lines.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(500)

    # Pre-determine which columns are grain lines
    $grainRng = [System.Random]::new(501)
    $grainCols = @{}
    for ($x = 0; $x -lt $Size; $x++) {
        # Every 3-4 pixels gets a grain line
        if (($x % 4) -eq 1 -or ($x % 4) -eq 2) {
            $grainCols[$x] = $true
        }
    }

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $noise = $rng.Next(-10, 10)

            # Base wood brown
            [byte]$r = Clamp-Byte (160 + $noise)
            [byte]$g = Clamp-Byte (120 + $noise)
            [byte]$b = Clamp-Byte (70 + [int]($noise * 0.5))

            # Darken grain line columns
            if ($grainCols.ContainsKey($x)) {
                $r = Clamp-Byte ($r - 25)
                $g = Clamp-Byte ($g - 20)
                $b = Clamp-Byte ($b - 12)
            }

            Set-Pixel $data $x $y $Size $r $g $b 255
        }
    }

    return ,$data
}

function Generate-WoodTopTexture {
    <#
    .SYNOPSIS
        Generates a 16x16 wood top texture: brown with concentric tree rings.
    #>
    param([int]$Size = 16)

    $data = [byte[]]::new($Size * $Size * 4)
    $rng = [System.Random]::new(600)

    $cx = $Size / 2.0
    $cy = $Size / 2.0

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $noise = $rng.Next(-8, 8)

            # Distance from center
            $dx = $x - $cx + 0.5
            $dy = $y - $cy + 0.5
            $dist = [Math]::Sqrt($dx * $dx + $dy * $dy)

            # Base wood color
            [byte]$r = Clamp-Byte (170 + $noise)
            [byte]$g = Clamp-Byte (130 + $noise)
            [byte]$b = Clamp-Byte (80 + [int]($noise * 0.5))

            # Concentric rings — darken every ~2.5 pixels of radius
            $ringPhase = $dist % 2.5
            if ($ringPhase -lt 1.0) {
                $r = Clamp-Byte ($r - 20)
                $g = Clamp-Byte ($g - 18)
                $b = Clamp-Byte ($b - 10)
            }

            # Darker center dot
            if ($dist -lt 1.5) {
                $r = Clamp-Byte ($r - 30)
                $g = Clamp-Byte ($g - 25)
                $b = Clamp-Byte ($b - 15)
            }

            Set-Pixel $data $x $y $Size $r $g $b 255
        }
    }

    return ,$data
}

# ============================================================================
# Public Functions — Single Texture Operations
# ============================================================================

function New-ProceduralTexture {
    <#
    .SYNOPSIS
        Generates a procedural texture by name and uploads it to the GPU.
    .PARAMETER TextureType
        One of: dirt, stone, grass_top, grass_side, wood_side, wood_top.
    .PARAMETER Size
        Texture resolution in pixels (default 16, must be <= 32).
    .OUTPUTS
        PSCustomObject with Handle (uint32), Width, Height, Type properties.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TextureType,
        [int]$Size = 16
    )

    # Generate pixel data based on type
    switch ($TextureType) {
        'dirt'       { $pixelData = Generate-DirtTexture -Size $Size }
        'stone'      { $pixelData = Generate-StoneTexture -Size $Size }
        'grass_top'  { $pixelData = Generate-GrassTopTexture -Size $Size }
        'grass_side' { $pixelData = Generate-GrassSideTexture -Size $Size }
        'wood_side'  { $pixelData = Generate-WoodSideTexture -Size $Size }
        'wood_top'   { $pixelData = Generate-WoodTopTexture -Size $Size }
        default      { throw "[Texture] Unknown texture type: $TextureType" }
    }

    # Generate OpenGL texture handle
    [uint32[]]$texIds = @([uint32]0)
    [OpenGL.Gl]::GenTextures($texIds)
    $handle = $texIds[0]

    # Bind and upload
    [OpenGL.Gl]::BindTexture([OpenGL.TextureTarget]::Texture2d, $handle)

    [OpenGL.Gl]::TexImage2D(
        [OpenGL.TextureTarget]::Texture2d,
        0,
        [OpenGL.InternalFormat]::Rgba8,
        $Size,
        $Size,
        0,
        [OpenGL.PixelFormat]::Rgba,
        [OpenGL.PixelType]::UnsignedByte,
        $pixelData
    )

    # Set texture parameters — nearest filtering for pixelated voxel look
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureMinFilter, [int][OpenGL.TextureMinFilter]::Nearest)
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureMagFilter, [int][OpenGL.TextureMagFilter]::Nearest)

    # Set wrap mode — repeat for tiling
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureWrapS, [int][OpenGL.TextureWrapMode]::Repeat)
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureWrapT, [int][OpenGL.TextureWrapMode]::Repeat)

    # Unbind
    [OpenGL.Gl]::BindTexture([OpenGL.TextureTarget]::Texture2d, [uint32]0)

    Write-Host "[Texture] Created '$TextureType' texture (${Size}x${Size}, handle: $handle)." -ForegroundColor DarkGray

    return [PSCustomObject]@{
        Handle = $handle
        Width  = $Size
        Height = $Size
        Type   = $TextureType
    }
}

# ============================================================================
# Public Functions — Texture Atlas
# ============================================================================

function New-TextureAtlas {
    <#
    .SYNOPSIS
        Creates a texture atlas from all block texture types.
    .DESCRIPTION
        Arranges all block textures in a single row (1 row x N columns).
        Each tile is 16x16 pixels. Atlas is uploaded as a single GPU texture.
    .OUTPUTS
        PSCustomObject with Handle, Width, Height, TileSize, TileCount,
        and TileIndex (hashtable mapping texture type name to column index).
    #>
    param([int]$TileSize = 16)

    $typeNames = @('dirt', 'stone', 'grass_top', 'grass_side', 'wood_side', 'wood_top')
    $tileCount = $typeNames.Count
    $atlasWidth = $tileCount * $TileSize
    $atlasHeight = $TileSize

    Write-Host "[Texture] Building texture atlas ($tileCount tiles, ${atlasWidth}x${atlasHeight})..." -ForegroundColor Yellow

    # Allocate atlas pixel data
    $atlasData = [byte[]]::new($atlasWidth * $atlasHeight * 4)

    # Build index mapping
    $tileIndex = @{}

    for ($i = 0; $i -lt $tileCount; $i++) {
        $typeName = $typeNames[$i]
        $tileIndex[$typeName] = $i

        # Generate tile pixel data
        switch ($typeName) {
            'dirt'       { $tileData = Generate-DirtTexture -Size $TileSize }
            'stone'      { $tileData = Generate-StoneTexture -Size $TileSize }
            'grass_top'  { $tileData = Generate-GrassTopTexture -Size $TileSize }
            'grass_side' { $tileData = Generate-GrassSideTexture -Size $TileSize }
            'wood_side'  { $tileData = Generate-WoodSideTexture -Size $TileSize }
            'wood_top'   { $tileData = Generate-WoodTopTexture -Size $TileSize }
        }

        # Copy tile into atlas at column i
        $xOffset = $i * $TileSize
        for ($row = 0; $row -lt $TileSize; $row++) {
            $srcStart = $row * $TileSize * 4
            $srcLen   = $TileSize * 4
            $dstStart = ($row * $atlasWidth + $xOffset) * 4
            [Array]::Copy($tileData, $srcStart, $atlasData, $dstStart, $srcLen)
        }

        Write-Host "[Texture]   Tile $i = '$typeName'" -ForegroundColor DarkGray
    }

    # Upload atlas to GPU
    [uint32[]]$texIds = @([uint32]0)
    [OpenGL.Gl]::GenTextures($texIds)
    $handle = $texIds[0]

    [OpenGL.Gl]::BindTexture([OpenGL.TextureTarget]::Texture2d, $handle)

    [OpenGL.Gl]::TexImage2D(
        [OpenGL.TextureTarget]::Texture2d,
        0,
        [OpenGL.InternalFormat]::Rgba8,
        $atlasWidth,
        $atlasHeight,
        0,
        [OpenGL.PixelFormat]::Rgba,
        [OpenGL.PixelType]::UnsignedByte,
        $atlasData
    )

    # Nearest filtering for pixelated voxel aesthetic
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureMinFilter, [int][OpenGL.TextureMinFilter]::Nearest)
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureMagFilter, [int][OpenGL.TextureMagFilter]::Nearest)

    # Clamp to edge for atlas (no repeat — prevents bleeding between tiles)
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureWrapS, [int][OpenGL.TextureWrapMode]::ClampToEdge)
    [OpenGL.Gl]::TexParameter([OpenGL.TextureTarget]::Texture2d, [OpenGL.TextureParameterName]::TextureWrapT, [int][OpenGL.TextureWrapMode]::ClampToEdge)

    # Unbind
    [OpenGL.Gl]::BindTexture([OpenGL.TextureTarget]::Texture2d, [uint32]0)

    $atlas = [PSCustomObject]@{
        Handle    = $handle
        Width     = $atlasWidth
        Height    = $atlasHeight
        TileSize  = $TileSize
        TileCount = $tileCount
        TileIndex = $tileIndex
    }

    Write-Host "[Texture] Atlas created (handle: $handle, ${atlasWidth}x${atlasHeight}, $tileCount tiles)." -ForegroundColor Green

    return $atlas
}

function Get-BlockFaceUV {
    <#
    .SYNOPSIS
        Returns UV coordinates for a given block type and face from the atlas.
    .PARAMETER Atlas
        Atlas PSCustomObject from New-TextureAtlas.
    .PARAMETER BlockType
        Block type name (dirt, stone, grass, wood).
    .PARAMETER Face
        Face name (top, bottom, north, south, east, west).
    .OUTPUTS
        PSCustomObject with U0, V0, U1, V1 (float UV coordinates).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Atlas,
        [Parameter(Mandatory = $true)]
        [string]$BlockType,
        [Parameter(Mandatory = $true)]
        [string]$Face
    )

    # Resolve block type + face to texture name
    $textureName = $null
    if ($script:BlockFaceMapping.ContainsKey($BlockType)) {
        $faceMap = $script:BlockFaceMapping[$BlockType]
        if ($faceMap.ContainsKey($Face)) {
            $textureName = $faceMap[$Face]
        }
    }

    # Fallback: try the block type directly as a texture name
    if ($null -eq $textureName) {
        $textureName = $BlockType
    }

    # Look up tile index
    if (-not $Atlas.TileIndex.ContainsKey($textureName)) {
        Write-Warning "[Texture] Unknown texture '$textureName' for block '$BlockType' face '$Face'. Using index 0."
        $tileIdx = 0
    }
    else {
        $tileIdx = $Atlas.TileIndex[$textureName]
    }

    # Compute UV coordinates (single row atlas)
    [float]$u0 = [float]$tileIdx / [float]$Atlas.TileCount
    [float]$v0 = [float]0.0
    [float]$u1 = [float]($tileIdx + 1) / [float]$Atlas.TileCount
    [float]$v1 = [float]1.0

    return [PSCustomObject]@{
        U0 = $u0
        V0 = $v0
        U1 = $u1
        V1 = $v1
    }
}

# ============================================================================
# Public Functions — Convenience
# ============================================================================

function Bind-Texture {
    <#
    .SYNOPSIS
        Binds an OpenGL texture to the active texture unit.
    .PARAMETER Handle
        UInt32 texture handle from New-ProceduralTexture or atlas.
    .PARAMETER Unit
        Texture unit index (default 0). Sets ActiveTexture before binding.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Handle,
        [int]$Unit = 0
    )

    # Activate the texture unit (GL_TEXTURE0 + unit)
    [OpenGL.Gl]::ActiveTexture([OpenGL.TextureUnit]::Texture0 + $Unit)
    [OpenGL.Gl]::BindTexture([OpenGL.TextureTarget]::Texture2d, $Handle)
}

function Get-BlockTextureAtlas {
    <#
    .SYNOPSIS
        Returns the block texture atlas, creating it on first call.
    .DESCRIPTION
        Lazy-creates and caches the texture atlas containing all block
        textures. Subsequent calls return the cached atlas.
    .OUTPUTS
        PSCustomObject atlas (Handle, Width, Height, TileSize, TileCount, TileIndex).
    #>

    if ($null -eq $script:BlockTextureAtlas) {
        Write-Host "[Texture] Creating block texture atlas (first call)..." -ForegroundColor Yellow
        $script:BlockTextureAtlas = New-TextureAtlas -TileSize 16
        Write-Host "[Texture] Block texture atlas ready." -ForegroundColor Green
    }

    return $script:BlockTextureAtlas
}
