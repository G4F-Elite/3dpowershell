# ============================================================================
# World/TerrainGen.ps1  - Perlin Noise Terrain Generation
# ============================================================================
# Provides deterministic 2D Perlin noise for terrain height generation.
# Uses proper gradient noise with permutation table, dot products, and
# smoothstep interpolation. Supports octave layering (fractal Brownian motion)
# for natural-looking terrain detail.
#
# Public functions:
#   Get-PerlinNoise2D -X <float> -Y <float>   -> raw noise in [-1, 1]
#   Get-NoiseHeight   -X <float> -Z <float> -Seed <int> -> height in [20, 64]
# ============================================================================

# --- Module State ---
# Permutation table (256 entries, doubled for wrapping). Initialized per seed.
$script:PerlinPerm = $null
# The seed used to generate the current permutation table (for lazy caching).
$script:PerlinPermSeed = $null

# --- Gradient Vectors for 2D Perlin Noise ---
# 8 unit-length gradient directions (classic Perlin improvement uses these)
$script:PerlinGradients2D = @(
    @( 1.0,  0.0),
    @(-1.0,  0.0),
    @( 0.0,  1.0),
    @( 0.0, -1.0),
    @( 0.7071067811865476,  0.7071067811865476),   # (1,1) normalized
    @(-0.7071067811865476,  0.7071067811865476),   # (-1,1) normalized
    @( 0.7071067811865476, -0.7071067811865476),   # (1,-1) normalized
    @(-0.7071067811865476, -0.7071067811865476)    # (-1,-1) normalized
)

# --- Terrain Generation Constants ---
$script:TerrainOctaves = 4
$script:TerrainLacunarity  = 2.0
$script:TerrainPersistence = 0.5
$script:TerrainScale       = 0.015    # World coord to noise coord scale
$script:TerrainBaseHeight  = 38       # Center of height range
$script:TerrainAmplitude   = 24       # Max deviation from base (range 14-62)
$script:TerrainMinHeight   = 20
$script:TerrainMaxHeight   = 64

# ============================================================================
# Initialize-PerlinPermutation - Build permutation table from seed
# ============================================================================
# Creates a 512-entry permutation table (256 values doubled for wrapping)
# using a deterministic RNG seeded with the given value.
# Cached: only rebuilds if seed changes.
# ============================================================================
function Initialize-PerlinPermutation {
    param(
        [Parameter(Mandatory=$true)]
        [int]$Seed
    )

    # Skip rebuild if already initialized with this seed
    if ($script:PerlinPerm -ne $null -and $script:PerlinPermSeed -eq $Seed) {
        return
    }

    # Build sequential 0-255 array
    [int[]]$perm = [int[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        $perm[$i] = $i
    }

    # Fisher-Yates shuffle with deterministic RNG
    $rng = [System.Random]::new($Seed)
    for ($i = 255; $i -gt 0; $i--) {
        $j = $rng.Next($i + 1)
        $tmp = $perm[$i]
        $perm[$i] = $perm[$j]
        $perm[$j] = $tmp
    }

    # Double the table for wrapping (avoids modulo in hot path)
    [int[]]$doubled = [int[]]::new(512)
    for ($i = 0; $i -lt 256; $i++) {
        $doubled[$i] = $perm[$i]
        $doubled[$i + 256] = $perm[$i]
    }

    $script:PerlinPerm = $doubled
    $script:PerlinPermSeed = $Seed
}

# ============================================================================
# Perlin Fade (smoothstep) - 6t^5 - 15t^4 + 10t^3
# ============================================================================
# Ken Perlin's improved interpolation curve. Has zero first and second
# derivatives at t=0 and t=1, producing smoother results than linear interp.
# ============================================================================
function Perlin-Fade { param([double]$t) return ($t * $t * $t * ($t * ($t * 6.0 - 15.0) + 10.0)) }

# ============================================================================
# Perlin Lerp - Linear interpolation
# ============================================================================
function Perlin-Lerp { param([double]$a, [double]$b, [double]$t) return ($a + $t * ($b - $a)) }

# ============================================================================
# Perlin-GradDot - Gradient dot product for 2D
# ============================================================================
# Selects a gradient vector based on hash value and computes its dot product
# with the distance vector (dx, dy).
# ============================================================================
function Perlin-GradDot {
    param([int]$hash, [double]$dx, [double]$dy)
    $grad = $script:PerlinGradients2D[$hash -band 7]
    return ($grad[0] * $dx + $grad[1] * $dy)
}

# ============================================================================
# Get-PerlinNoise2D - Single-octave 2D Perlin noise
# ============================================================================
# Returns a noise value in approximately [-1, 1] range for given coordinates.
# The permutation table must be initialized before calling this function
# (call Initialize-PerlinPermutation first).
#
# Parameters:
#   -X  X coordinate (float)
#   -Y  Y coordinate (float)
#
# Returns: [double] noise value in [-1, 1]
# ============================================================================
function Get-PerlinNoise2D {
    param(
        [double]$X,
        [double]$Y
    )

    $perm = $script:PerlinPerm
    $grads = $script:PerlinGradients2D

    # Grid cell coordinates (handle negative coords correctly)
    [int]$xi = [System.Math]::Floor($X)
    [int]$yi = [System.Math]::Floor($Y)

    # Fractional position within cell
    [double]$xf = $X - $xi
    [double]$yf = $Y - $yi

    # Wrap grid coords to 0-255 range (bitwise AND)
    $xi = $xi -band 255
    $yi = $yi -band 255

    # Fade curves for interpolation weights (inlined Perlin-Fade)
    [double]$u = ($xf * $xf * $xf * ($xf * ($xf * 6.0 - 15.0) + 10.0))
    [double]$v = ($yf * $yf * $yf * ($yf * ($yf * 6.0 - 15.0) + 10.0))

    # Hash coordinates of the 4 corners of the cell
    [int]$aa = $perm[$perm[$xi]     + $yi]
    [int]$ab = $perm[$perm[$xi]     + $yi + 1]
    [int]$ba = $perm[$perm[$xi + 1] + $yi]
    [int]$bb = $perm[$perm[$xi + 1] + $yi + 1]

    # Gradient dot products at each corner (inlined Perlin-GradDot)
    $g = $grads[$aa -band 7]
    [double]$g00 = ($g[0] * $xf + $g[1] * $yf)

    [double]$xfm1 = ($xf - 1.0)
    [double]$yfm1 = ($yf - 1.0)

    $g = $grads[$ba -band 7]
    [double]$g10 = ($g[0] * $xfm1 + $g[1] * $yf)

    $g = $grads[$ab -band 7]
    [double]$g01 = ($g[0] * $xf + $g[1] * $yfm1)

    $g = $grads[$bb -band 7]
    [double]$g11 = ($g[0] * $xfm1 + $g[1] * $yfm1)

    # Bilinear interpolation using fade curves (inlined Perlin-Lerp)
    [double]$x0 = ($g00 + $u * ($g10 - $g00))
    [double]$x1 = ($g01 + $u * ($g11 - $g01))
    [double]$result = ($x0 + $v * ($x1 - $x0))

    return $result
}

# ============================================================================
# Get-FractalNoise2D - Multi-octave fractal Brownian motion noise
# ============================================================================
# Layers multiple octaves of Perlin noise with increasing frequency and
# decreasing amplitude. Produces more detailed, natural-looking terrain.
#
# Parameters:
#   -X            X coordinate
#   -Y            Y coordinate
#   -Octaves      Number of noise layers (default: 6)
#   -Lacunarity   Frequency multiplier per octave (default: 2.0)
#   -Persistence  Amplitude multiplier per octave (default: 0.5)
#
# Returns: [double] combined noise value (normalized to approximately [-1, 1])
# ============================================================================
function Get-FractalNoise2D {
    param(
        [double]$X,
        [double]$Y,
        [int]$Octaves = $script:TerrainOctaves,
        [double]$Lacunarity = $script:TerrainLacunarity,
        [double]$Persistence = $script:TerrainPersistence
    )

    [double]$total = 0.0
    [double]$frequency = 1.0
    [double]$amplitude = 1.0
    [double]$maxAmplitude = 0.0  # For normalization

    for ($i = 0; $i -lt $Octaves; $i++) {
        $total += (Get-PerlinNoise2D -X ($X * $frequency) -Y ($Y * $frequency)) * $amplitude
        $maxAmplitude += $amplitude
        $amplitude *= $Persistence
        $frequency *= $Lacunarity
    }

    # Normalize to [-1, 1]
    if ($maxAmplitude -gt 0.0) {
        $total = $total / $maxAmplitude
    }

    return $total
}

# ============================================================================
# Get-NoiseHeight - Get terrain height at world coordinates
# ============================================================================
# Returns a deterministic integer height value for the given world X,Z
# coordinates and seed. Uses multi-octave Perlin noise scaled and mapped
# to the terrain height range.
#
# Parameters:
#   -X     World X coordinate (float)
#   -Z     World Z coordinate (float)
#   -Seed  Integer seed for deterministic generation
#
# Returns: [int] height value in range [20, 64]
# ============================================================================
function Get-NoiseHeight {
    param(
        [double]$X,
        [double]$Z
    )

    # Initialize (or verify) permutation table for this seed
    

    # Scale world coordinates to noise space
    [double]$nx = $X * $script:TerrainScale
    [double]$nz = $Z * $script:TerrainScale

    # Inline fractal noise loop (avoids extra function call per column)
    $perm = $script:PerlinPerm
    $grads = $script:PerlinGradients2D
    [int]$octaves = $script:TerrainOctaves
    [double]$lacunarity = $script:TerrainLacunarity
    [double]$persistence = $script:TerrainPersistence

    [double]$total = 0.0
    [double]$frequency = 1.0
    [double]$amplitude = 1.0
    [double]$maxAmplitude = 0.0

    for ($o = 0; $o -lt $octaves; $o++) {
        [double]$px = $nx * $frequency
        [double]$py = $nz * $frequency

        [int]$xi = [System.Math]::Floor($px)
        [int]$yi = [System.Math]::Floor($py)
        [double]$xf = $px - $xi
        [double]$yf = $py - $yi
        $xi = $xi -band 255
        $yi = $yi -band 255

        [double]$u = ($xf * $xf * $xf * ($xf * ($xf * 6.0 - 15.0) + 10.0))
        [double]$v = ($yf * $yf * $yf * ($yf * ($yf * 6.0 - 15.0) + 10.0))

        [int]$aa = $perm[$perm[$xi] + $yi]
        [int]$ab = $perm[$perm[$xi] + $yi + 1]
        [int]$ba = $perm[$perm[$xi + 1] + $yi]
        [int]$bb = $perm[$perm[$xi + 1] + $yi + 1]

        $g = $grads[$aa -band 7]
        [double]$g00 = ($g[0] * $xf + $g[1] * $yf)

        [double]$xfm1 = ($xf - 1.0)
        [double]$yfm1 = ($yf - 1.0)

        $g = $grads[$ba -band 7]
        [double]$g10 = ($g[0] * $xfm1 + $g[1] * $yf)

        $g = $grads[$ab -band 7]
        [double]$g01 = ($g[0] * $xf + $g[1] * $yfm1)

        $g = $grads[$bb -band 7]
        [double]$g11 = ($g[0] * $xfm1 + $g[1] * $yfm1)

        [double]$x0 = ($g00 + $u * ($g10 - $g00))
        [double]$x1 = ($g01 + $u * ($g11 - $g01))
        [double]$octaveNoise = ($x0 + $v * ($x1 - $x0))

        $total += ($octaveNoise * $amplitude)
        $maxAmplitude += $amplitude
        $amplitude *= $persistence
        $frequency *= $lacunarity
    }

    [double]$noise = 0.0
    if ($maxAmplitude -gt 0.0) {
        $noise = $total / $maxAmplitude
    }

    # Map noise to height range: base +/- amplitude
    [double]$height = $script:TerrainBaseHeight + ($noise * $script:TerrainAmplitude)

    # Clamp to valid range
    if ($height -lt $script:TerrainMinHeight) { $height = $script:TerrainMinHeight }
    if ($height -gt $script:TerrainMaxHeight) { $height = $script:TerrainMaxHeight }

    # Return as integer
    return [int][System.Math]::Floor($height)
}

function Get-ChunkHeightMap16x16 {
    param(
        [int]$BaseX,
        [int]$BaseZ
    )

    $perm = $script:PerlinPerm
    $grads = $script:PerlinGradients2D

    [int]$octaves = $script:TerrainOctaves
    [double]$lacunarity = $script:TerrainLacunarity
    [double]$persistence = $script:TerrainPersistence
    [double]$scale = $script:TerrainScale

    [double]$baseHeight = $script:TerrainBaseHeight
    [double]$amplitudeScale = $script:TerrainAmplitude
    [double]$minHeight = $script:TerrainMinHeight
    [double]$maxHeight = $script:TerrainMaxHeight

    [int[]]$heights = [int[]]::new(256)

    for ($x = 0; $x -lt 16; $x++) {
        [double]$nxBase = ($BaseX + $x) * $scale
        for ($z = 0; $z -lt 16; $z++) {
            [double]$nzBase = ($BaseZ + $z) * $scale

            [double]$total = 0.0
            [double]$frequency = 1.0
            [double]$amplitude = 1.0
            [double]$maxAmplitude = 0.0

            for ($o = 0; $o -lt $octaves; $o++) {
                [double]$px = $nxBase * $frequency
                [double]$py = $nzBase * $frequency

                [int]$xi = [System.Math]::Floor($px)
                [int]$yi = [System.Math]::Floor($py)
                [double]$xf = $px - $xi
                [double]$yf = $py - $yi
                $xi = $xi -band 255
                $yi = $yi -band 255

                [double]$u = ($xf * $xf * $xf * ($xf * ($xf * 6.0 - 15.0) + 10.0))
                [double]$v = ($yf * $yf * $yf * ($yf * ($yf * 6.0 - 15.0) + 10.0))

                [int]$aa = $perm[$perm[$xi] + $yi]
                [int]$ab = $perm[$perm[$xi] + $yi + 1]
                [int]$ba = $perm[$perm[$xi + 1] + $yi]
                [int]$bb = $perm[$perm[$xi + 1] + $yi + 1]

                $g = $grads[$aa -band 7]
                [double]$g00 = ($g[0] * $xf + $g[1] * $yf)

                [double]$xfm1 = ($xf - 1.0)
                [double]$yfm1 = ($yf - 1.0)

                $g = $grads[$ba -band 7]
                [double]$g10 = ($g[0] * $xfm1 + $g[1] * $yf)

                $g = $grads[$ab -band 7]
                [double]$g01 = ($g[0] * $xf + $g[1] * $yfm1)

                $g = $grads[$bb -band 7]
                [double]$g11 = ($g[0] * $xfm1 + $g[1] * $yfm1)

                [double]$x0 = ($g00 + $u * ($g10 - $g00))
                [double]$x1 = ($g01 + $u * ($g11 - $g01))
                [double]$octaveNoise = ($x0 + $v * ($x1 - $x0))

                $total += ($octaveNoise * $amplitude)
                $maxAmplitude += $amplitude
                $amplitude *= $persistence
                $frequency *= $lacunarity
            }

            [double]$noise = 0.0
            if ($maxAmplitude -gt 0.0) {
                $noise = $total / $maxAmplitude
            }

            [double]$height = $baseHeight + ($noise * $amplitudeScale)
            if ($height -lt $minHeight) { $height = $minHeight }
            if ($height -gt $maxHeight) { $height = $maxHeight }

            $heights[$x + $z * 16] = [int][System.Math]::Floor($height)
        }
    }

    return ,$heights
}
