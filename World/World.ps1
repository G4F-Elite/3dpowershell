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
$script:WorldChunksByCode  = @{}
$script:WorldViewDistance   = [int]4
$script:WorldInitialized   = $false
$script:WorldChunkGenQueue = [System.Collections.ArrayList]::new()
$script:WorldChunkGenHead = [int]0
$script:WorldChunkGenQueuedSet = @{}
$script:WorldChunkCapacity = [int]64
$script:WorldVerboseLogging = $true
$script:WorldLastProjWidth = [int]0
$script:WorldLastProjHeight = [int]0
$script:WorldCachedProjection = $null
$script:WorldChunkBootstrapCompleted = $false
$script:WorldChunkGenBudgetPerFrame = [int]9999
$script:WorldRenderDistancePadding = [int]1
$script:WorldFrustumPaddingChunks = [float]1.0
$script:WorldVisibleChunksScratch = $null
$script:WorldVisibleChunkCount = [int]0
$script:WorldChunkRemoveCodesScratch = [System.Collections.Generic.List[int64]]::new(64)
$script:WorldFrameTimesMs = [double[]]::new(512)
$script:WorldCachedModelIdentity = $null
$script:WorldChunkSetRevision = [int64]0
$script:WorldLastChunkTopologyRevision = [int64]-1
$script:WorldLastChunkSetRevision = [int64]-1
$script:WorldCachedVisibleByCode = [System.Collections.Generic.Dictionary[int64, object]]::new(256)
$script:WorldLastCameraX = [double]::NaN
$script:WorldLastCameraY = [double]::NaN
$script:WorldLastCameraZ = [double]::NaN
$script:WorldLastCameraYaw = [double]::NaN
$script:WorldLastCameraPitch = [double]::NaN
$script:WorldVisibilityCachePosThreshold = [double]0.35
$script:WorldVisibilityCacheRotThreshold = [double]0.01
$script:WorldCameraBasisCache = [PSCustomObject]@{
    Position = (New-Vector3 -X 0 -Y 0 -Z 0)
    ForwardX = [float]0.0
    ForwardY = [float]0.0
    ForwardZ = [float]-1.0
    RightX = [float]1.0
    RightY = [float]0.0
    RightZ = [float]0.0
    UpX = [float]0.0
    UpY = [float]1.0
    UpZ = [float]0.0
}

$script:WorldOcclusionStepToLinear = [float[]]@(
    [float]0.125,
    [float]0.250,
    [float]0.375,
    [float]0.500,
    [float]0.625,
    [float]0.750,
    [float]0.875
)

$script:WorldFrameTimesCount = [int]0
$script:WorldFrameTimesWriteIndex = [int]0

function Get-ChunkCoordCode {
    param(
        [Parameter(Mandatory = $true)][int]$ChunkX,
        [Parameter(Mandatory = $true)][int]$ChunkZ
    )

    [int64]$high = ([int64]$ChunkX) -shl 32
    [int64]$low = ([int64]$ChunkZ) -band 0x00000000FFFFFFFFL
    return ([int64]($high -bor $low))
}

function Decode-ChunkCoordCode {
    param(
        [Parameter(Mandatory = $true)][int64]$Code,
        [ref]$ChunkX,
        [ref]$ChunkZ
    )

    $ChunkX.Value = [int]($Code -shr 32)

    [int64]$low = [int64]($Code -band 0x00000000FFFFFFFFL)
    if ($low -ge 2147483648L) {
        $ChunkZ.Value = [int]($low - 4294967296L)
    }
    else {
        $ChunkZ.Value = [int]$low
    }
}

function Set-ChunkQueuedFlag {
    param(
        [Parameter(Mandatory = $true)][int]$ChunkX,
        [Parameter(Mandatory = $true)][int]$ChunkZ,
        [Parameter(Mandatory = $true)][bool]$Queued
    )

    $flagKey = (Get-ChunkCoordCode -ChunkX $ChunkX -ChunkZ $ChunkZ)
    if ($Queued) {
        $script:WorldChunkGenQueuedSet[$flagKey] = $true
    }
    elseif ($script:WorldChunkGenQueuedSet.ContainsKey($flagKey)) {
        $script:WorldChunkGenQueuedSet.Remove($flagKey)
    }
}

function Test-ChunkQueuedFlag {
    param(
        [Parameter(Mandatory = $true)][int]$ChunkX,
        [Parameter(Mandatory = $true)][int]$ChunkZ
    )

    $flagKey = (Get-ChunkCoordCode -ChunkX $ChunkX -ChunkZ $ChunkZ)
    return $script:WorldChunkGenQueuedSet.ContainsKey($flagKey)
}

function Add-ChunkToGenerationQueue {
    param(
        [Parameter(Mandatory = $true)][int]$ChunkX,
        [Parameter(Mandatory = $true)][int]$ChunkZ,
        [switch]$Priority
    )

    $chunkKey = "$ChunkX,$ChunkZ"
    if ($script:WorldChunks.ContainsKey($chunkKey)) {
        return
    }
    if (Test-ChunkQueuedFlag -ChunkX $ChunkX -ChunkZ $ChunkZ) {
        return
    }

    $code = Get-ChunkCoordCode -ChunkX $ChunkX -ChunkZ $ChunkZ
    if ($Priority) {
        $script:WorldChunkGenQueue.Insert([int]$script:WorldChunkGenHead, $code) | Out-Null
    }
    else {
        $script:WorldChunkGenQueue.Add($code) | Out-Null
    }
    Set-ChunkQueuedFlag -ChunkX $ChunkX -ChunkZ $ChunkZ -Queued $true
}

function Ensure-WorldChunkCodeMap {
    if ($script:WorldChunksByCode.Count -eq $script:WorldChunks.Count) {
        return
    }

    if ($script:WorldChunksByCode.Count -gt 0) {
        $script:WorldChunksByCode.Clear()
    }

    foreach ($chunk in $script:WorldChunks.Values) {
        if ($null -eq $chunk) { continue }
        [int]$cx = [int]$chunk.ChunkX
        [int]$cz = [int]$chunk.ChunkZ
        $code = Get-ChunkCoordCode -ChunkX $cx -ChunkZ $cz
        $script:WorldChunksByCode[$code] = $chunk
    }

    $script:WorldChunkSetRevision = [int64]$script:WorldChunkSetRevision + 1
}

function Get-CameraYawPitchValues {
    param(
        [ref]$Yaw,
        [ref]$Pitch
    )

    $yawVar = Get-Variable -Scope Script -Name 'CameraYaw' -ErrorAction SilentlyContinue
    $pitchVar = Get-Variable -Scope Script -Name 'CameraPitch' -ErrorAction SilentlyContinue

    [double]$yawLocal = 0.0
    [double]$pitchLocal = 0.0

    if ($null -ne $yawVar) {
        try {
            $yawLocal = [double]$yawVar.Value
        }
        catch {
            $yawLocal = 0.0
        }
    }

    if ($null -ne $pitchVar) {
        try {
            $pitchLocal = [double]$pitchVar.Value
        }
        catch {
            $pitchLocal = 0.0
        }
    }

    if ($null -ne $Yaw) { $Yaw.Value = [double]$yawLocal }
    if ($null -ne $Pitch) { $Pitch.Value = [double]$pitchLocal }
}

function Ensure-VisibleChunkBufferCapacity {
    param([int]$Required)

    if ($Required -lt 1) { $Required = 1 }
    if ($null -eq $script:WorldVisibleChunksScratch -or $script:WorldVisibleChunksScratch.Length -lt $Required) {
        $script:WorldVisibleChunksScratch = [object[]]::new($Required)
    }
}

function Get-CameraBasisVectors {
    param(
        [switch]$ReuseCached
    )

    $pos = Get-CameraPosition
    [double]$yawD = 0.0
    [double]$pitchD = 0.0
    Get-CameraYawPitchValues -Yaw ([ref]$yawD) -Pitch ([ref]$pitchD)
    [float]$yaw = [float]$yawD
    [float]$pitch = [float]$pitchD

    if (
        $ReuseCached -and
        $null -ne $script:WorldCameraBasisCache -and
        $null -ne $script:WorldCameraBasisCache.Position -and
        [double]$script:WorldLastCameraX -eq [double]$pos.X -and
        [double]$script:WorldLastCameraY -eq [double]$pos.Y -and
        [double]$script:WorldLastCameraZ -eq [double]$pos.Z -and
        [double]$script:WorldLastCameraYaw -eq [double]$yaw -and
        [double]$script:WorldLastCameraPitch -eq [double]$pitch
    ) {
        return $script:WorldCameraBasisCache
    }

    [float]$sinYaw = [float][Math]::Sin($yaw)
    [float]$cosYaw = [float][Math]::Cos($yaw)
    [float]$sinPitch = [float][Math]::Sin($pitch)
    [float]$cosPitch = [float][Math]::Cos($pitch)

    [float]$fx = [float](-$sinYaw * $cosPitch)
    [float]$fy = [float]$sinPitch
    [float]$fz = [float](-$cosYaw * $cosPitch)
    [float]$flenSq = [float]($fx * $fx + $fy * $fy + $fz * $fz)
    if ($flenSq -gt 0.0) {
        [float]$invF = [float](1.0 / [Math]::Sqrt($flenSq))
        $fx *= $invF; $fy *= $invF; $fz *= $invF
    }

    [float]$rx = [float]$cosYaw
    [float]$ry = [float]0.0
    [float]$rz = [float](-$sinYaw)
    [float]$rlenSq = [float]($rx * $rx + $rz * $rz)
    if ($rlenSq -gt 0.0) {
        [float]$invR = [float](1.0 / [Math]::Sqrt($rlenSq))
        $rx *= $invR; $rz *= $invR
    }

    [float]$ux = [float]($fy * $rz - $fz * $ry)
    [float]$uy = [float]($fz * $rx - $fx * $rz)
    [float]$uz = [float]($fx * $ry - $fy * $rx)
    [float]$ulenSq = [float]($ux * $ux + $uy * $uy + $uz * $uz)
    if ($ulenSq -gt 0.0) {
        [float]$invU = [float](1.0 / [Math]::Sqrt($ulenSq))
        $ux *= $invU; $uy *= $invU; $uz *= $invU
    }

    $script:WorldCameraBasisCache.Position = $pos
    $script:WorldCameraBasisCache.ForwardX = [float]$fx
    $script:WorldCameraBasisCache.ForwardY = [float]$fy
    $script:WorldCameraBasisCache.ForwardZ = [float]$fz
    $script:WorldCameraBasisCache.RightX = [float]$rx
    $script:WorldCameraBasisCache.RightY = [float]$ry
    $script:WorldCameraBasisCache.RightZ = [float]$rz
    $script:WorldCameraBasisCache.UpX = [float]$ux
    $script:WorldCameraBasisCache.UpY = [float]$uy
    $script:WorldCameraBasisCache.UpZ = [float]$uz

    return $script:WorldCameraBasisCache
}

function Test-ChunkVisibleApprox {
    param(
        [Parameter(Mandatory = $true)]$Chunk,
        [Parameter(Mandatory = $true)]$CameraBasis,
        [Parameter(Mandatory = $true)][float]$Aspect,
        [Parameter(Mandatory = $true)][float]$TanHalfFovY,
        [float]$PaddingChunks = [float]1.0
    )

    [float]$padding = [float]($PaddingChunks * 16.0)
    [float]$minX = [float]($Chunk.ChunkX * 16.0 - $padding)
    [float]$maxX = [float]($minX + 16.0 + ($padding * 2.0))
    [float]$minZ = [float]($Chunk.ChunkZ * 16.0 - $padding)
    [float]$maxZ = [float]($minZ + 16.0 + ($padding * 2.0))

    [int]$maxSolidY = [int]-1
    if ($null -ne $Chunk.PSObject.Properties['MaxSolidY']) {
        $maxSolidY = [int]$Chunk.MaxSolidY
    }
    if ($maxSolidY -lt 0) {
        return $false
    }
    [float]$minY = [float]-$padding
    [float]$maxY = [float]($maxSolidY + 1 + $padding)

    [float]$camX = [float]$CameraBasis.Position.X
    [float]$camY = [float]$CameraBasis.Position.Y
    [float]$camZ = [float]$CameraBasis.Position.Z

    [float]$cx = [float](($minX + $maxX) * 0.5)
    [float]$cy = [float](($minY + $maxY) * 0.5)
    [float]$cz = [float](($minZ + $maxZ) * 0.5)

    [float]$halfX = [float](($maxX - $minX) * 0.5)
    [float]$halfY = [float](($maxY - $minY) * 0.5)
    [float]$halfZ = [float](($maxZ - $minZ) * 0.5)

    [float]$toX = [float]($cx - $camX)
    [float]$toY = [float]($cy - $camY)
    [float]$toZ = [float]($cz - $camZ)

    [float]$viewX = [float]($toX * $CameraBasis.RightX + $toY * $CameraBasis.RightY + $toZ * $CameraBasis.RightZ)
    [float]$viewY = [float]($toX * $CameraBasis.UpX + $toY * $CameraBasis.UpY + $toZ * $CameraBasis.UpZ)
    [float]$viewZ = [float]($toX * $CameraBasis.ForwardX + $toY * $CameraBasis.ForwardY + $toZ * $CameraBasis.ForwardZ)

    [float]$radiusX = [float]([Math]::Abs($CameraBasis.RightX) * $halfX + [Math]::Abs($CameraBasis.RightY) * $halfY + [Math]::Abs($CameraBasis.RightZ) * $halfZ)
    [float]$radiusY = [float]([Math]::Abs($CameraBasis.UpX) * $halfX + [Math]::Abs($CameraBasis.UpY) * $halfY + [Math]::Abs($CameraBasis.UpZ) * $halfZ)
    [float]$radiusZ = [float]([Math]::Abs($CameraBasis.ForwardX) * $halfX + [Math]::Abs($CameraBasis.ForwardY) * $halfY + [Math]::Abs($CameraBasis.ForwardZ) * $halfZ)

    [float]$near = [float]0.1
    [float]$far = [float]500.0

    if (($viewZ + $radiusZ) -lt $near) { return $false }
    if (($viewZ - $radiusZ) -gt $far) { return $false }

    [float]$padMul = [float]1.1
    [float]$tanY = [float]($TanHalfFovY * $padMul)
    [float]$tanX = [float]($tanY * $Aspect)
    [float]$zForPlane = [float][Math]::Max($near, ($viewZ - $radiusZ))

    if ([Math]::Abs($viewX) - $radiusX -gt ($zForPlane * $tanX)) { return $false }
    if ([Math]::Abs($viewY) - $radiusY -gt ($zForPlane * $tanY)) { return $false }

    return $true
}

function Test-ChunkOccludedBasic {
    param(
        [Parameter(Mandatory = $true)]$Chunk,
        [Parameter(Mandatory = $true)]$CameraBasis,
        [Parameter(Mandatory = $true)]$ChunkGrid,
        [Parameter(Mandatory = $true)][int]$CamChunkX,
        [Parameter(Mandatory = $true)][int]$CamChunkZ,
        [int]$MaxSteps = 10
    )

    [int]$targetX = [int]$Chunk.ChunkX
    [int]$targetZ = [int]$Chunk.ChunkZ

    if ($targetX -eq $CamChunkX -and $targetZ -eq $CamChunkZ) {
        return $false
    }

    [float]$centerX = [float]($targetX * 16.0 + 8.0)
    [float]$centerY = [float][Math]::Min([Math]::Max([float]$CameraBasis.Position.Y, 1.0), ([float]$Chunk.MaxSolidY + 1.0))
    [float]$centerZ = [float]($targetZ * 16.0 + 8.0)

    [float]$toX = [float]($centerX - [float]$CameraBasis.Position.X)
    [float]$toY = [float]($centerY - [float]$CameraBasis.Position.Y)
    [float]$toZ = [float]($centerZ - [float]$CameraBasis.Position.Z)
    [float]$distSq = [float]($toX * $toX + $toY * $toY + $toZ * $toZ)

    if ($distSq -lt (32.0 * 32.0)) {
        return $false
    }

    [int]$dx = $targetX - $CamChunkX
    [int]$dz = $targetZ - $CamChunkZ
    [int]$steps = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dz))
    if ($steps -le 1) { return $false }
    if ($steps -gt $MaxSteps) { return $false }

    [float]$camPosX = [float]$CameraBasis.Position.X
    [float]$camPosZ = [float]$CameraBasis.Position.Z
    [float]$toCenterX = [float]($centerX - $camPosX)
    [float]$toCenterZ = [float]($centerZ - $camPosZ)

    [int]$sampleY = [int][Math]::Floor($centerY)
    if ($sampleY -lt 0) { $sampleY = 0 }
    if ($sampleY -gt 255) { $sampleY = 255 }

    for ($s = 1; $s -lt $steps; $s++) {
        [float]$t = [float]($s / [double]$steps)
        if ($steps -eq 8 -and $s -ge 1 -and $s -le 7) {
            $t = [float]$script:WorldOcclusionStepToLinear[$s - 1]
        }
        [float]$rayX = [float]($camPosX + $toCenterX * $t)
        [float]$rayZ = [float]($camPosZ + $toCenterZ * $t)
        [int]$ix = [int][Math]::Floor($rayX / 16.0)
        [int]$iz = [int][Math]::Floor($rayZ / 16.0)
        $checkCode = Get-ChunkCoordCode -ChunkX $ix -ChunkZ $iz
        if (-not $ChunkGrid.ContainsKey($checkCode)) { continue }

        $checkChunk = $ChunkGrid[$checkCode]
        if ($null -eq $checkChunk) { continue }

        [int]$checkMaxSolidY = [int]-1
        if ($null -ne $checkChunk.PSObject.Properties['MaxSolidY']) {
            $checkMaxSolidY = [int]$checkChunk.MaxSolidY
        }
        if ($checkMaxSolidY -lt $sampleY) { continue }
        [int]$localX = [int]($rayX - ($ix * 16.0))
        [int]$localZ = [int]($rayZ - ($iz * 16.0))
        if ($localX -lt 0) { $localX = 0 }
        if ($localX -gt 15) { $localX = 15 }
        if ($localZ -lt 0) { $localZ = 0 }
        if ($localZ -gt 15) { $localZ = 15 }

        [int]$blockIndex = $localX + ($localZ * 16) + ($sampleY * 256)
        [byte]$blockAtRay = [byte]$checkChunk.Blocks[$blockIndex]
        if ($blockAtRay -ne [byte]0 -and $blockAtRay -ne [byte]7) {
            return $true
        }
    }

    return $false
}

function Get-WorldPerformanceSummary {
    if (
        $null -eq $script:WorldFrameTimesMs -or
        $script:WorldFrameTimesMs.Length -eq 0 -or
        [int]$script:WorldFrameTimesCount -le 0
    ) {
        return [PSCustomObject]@{
            FrameCount = [int]0
            AverageFrameMs = [double]0.0
            AverageFps = [double]0.0
            MinFrameMs = [double]0.0
            MaxFrameMs = [double]0.0
        }
    }

    [int]$capacity = [int]$script:WorldFrameTimesMs.Length
    [int]$count = [int]$script:WorldFrameTimesCount
    if ($count -gt $capacity) {
        $count = $capacity
    }
    if ($count -le 0) {
        return [PSCustomObject]@{
            FrameCount = [int]0
            AverageFrameMs = [double]0.0
            AverageFps = [double]0.0
            MinFrameMs = [double]0.0
            MaxFrameMs = [double]0.0
        }
    }

    [double]$sum = 0.0
    [double]$min = [double]::PositiveInfinity
    [double]$max = 0.0

    [int]$start = [int]$script:WorldFrameTimesWriteIndex - $count
    if ($start -lt 0) {
        $start += $capacity
    }

    for ($i = 0; $i -lt $count; $i++) {
        [int]$idx = ($start + $i)
        if ($idx -ge $capacity) {
            $idx -= $capacity
        }

        [double]$v = [double]$script:WorldFrameTimesMs[$idx]
        $sum += $v
        if ($v -lt $min) { $min = $v }
        if ($v -gt $max) { $max = $v }
    }

    [double]$avgMs = 0.0
    if ($count -gt 0) {
        $avgMs = $sum / $count
    }
    [double]$avgFps = 0.0
    if ($avgMs -gt 0.0) {
        $avgFps = 1000.0 / $avgMs
    }

    return [PSCustomObject]@{
        FrameCount = $count
        AverageFrameMs = [double]$avgMs
        AverageFps = [double]$avgFps
        MinFrameMs = [double]$min
        MaxFrameMs = [double]$max
    }
}

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
    $script:WorldChunksByCode  = @{}
    $script:WorldInitialized   = $false
    $script:WorldChunkGenQueue = [System.Collections.ArrayList]::new()
    $script:WorldChunkGenHead = [int]0
    $script:WorldChunkGenQueuedSet = @{}
    $script:WorldChunkBootstrapCompleted = $false
    $script:WorldVisibleChunksScratch = $null
    $script:WorldVisibleChunkCount = [int]0
    if ($null -eq $script:WorldChunkRemoveCodesScratch) {
        $script:WorldChunkRemoveCodesScratch = [System.Collections.Generic.List[int64]]::new(64)
    }
    $script:WorldChunkSetRevision = [int64]0
    $script:WorldLastChunkTopologyRevision = [int64]-1
    $script:WorldLastChunkSetRevision = [int64]-1
    $script:WorldCachedVisibleByCode = [System.Collections.Generic.Dictionary[int64, object]]::new(256)
    $script:WorldLastCameraX = [double]::NaN
    $script:WorldLastCameraY = [double]::NaN
    $script:WorldLastCameraZ = [double]::NaN
    $script:WorldLastCameraYaw = [double]::NaN
    $script:WorldLastCameraPitch = [double]::NaN
    $script:WorldCachedModelIdentity = Matrix4-Identity
    if ($null -eq $script:WorldCameraBasisCache) {
        $script:WorldCameraBasisCache = [PSCustomObject]@{
            Position = (New-Vector3 -X 0 -Y 0 -Z 0)
            ForwardX = [float]0.0
            ForwardY = [float]0.0
            ForwardZ = [float]-1.0
            RightX = [float]1.0
            RightY = [float]0.0
            RightZ = [float]0.0
            UpX = [float]0.0
            UpY = [float]1.0
            UpZ = [float]0.0
        }
    }
    if ($null -eq $script:WorldFrameTimesMs -or $script:WorldFrameTimesMs.Length -ne 512) {
        $script:WorldFrameTimesMs = [double[]]::new(512)
    }
    else {
        [Array]::Clear($script:WorldFrameTimesMs, 0, $script:WorldFrameTimesMs.Length)
    }
    $script:WorldFrameTimesCount = [int]0
    $script:WorldFrameTimesWriteIndex = [int]0

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

    Ensure-WorldChunkCodeMap

    # Get camera chunk coordinates
    $camPos = Get-CameraPosition
    [int]$camChunkX = [Math]::Floor($camPos.X / 16)
    [int]$camChunkZ = [Math]::Floor($camPos.Z / 16)

    $vd = $script:WorldViewDistance

    if (-not $script:WorldChunkBootstrapCompleted) {
        # First fill nearest chunks first for fastest visible world bring-up.
        [int]$radiusMax = $vd
        for ($r = 0; $r -le $radiusMax; $r++) {
            for ($cx = $camChunkX - $r; $cx -le $camChunkX + $r; $cx++) {
                for ($cz = $camChunkZ - $r; $cz -le $camChunkZ + $r; $cz++) {
                    if ([Math]::Max([Math]::Abs($cx - $camChunkX), [Math]::Abs($cz - $camChunkZ)) -ne $r) { continue }
                    Add-ChunkToGenerationQueue -ChunkX $cx -ChunkZ $cz -Priority
                }
            }
        }
        $script:WorldChunkBootstrapCompleted = $true
    }
    else {
        # Steady-state queue maintenance around camera.
        # Inline existence check avoids expensive function call overhead for loaded chunks.
        for ($cx = $camChunkX - $vd; $cx -le $camChunkX + $vd; $cx++) {
            for ($cz = $camChunkZ - $vd; $cz -le $camChunkZ + $vd; $cz++) {
                if ($script:WorldChunks.ContainsKey("$cx,$cz")) { continue }
                Add-ChunkToGenerationQueue -ChunkX $cx -ChunkZ $cz
            }
        }
    }

    # --- Generate queued chunks with fixed per-frame budget (prevents frame spikes) ---
    if ($script:WorldInitialized) {
        [int]$queueTail = $script:WorldChunkGenQueue.Count
        [int]$generatedThisFrame = 0
        while (
            $script:WorldChunks.Count -lt $script:WorldChunkCapacity -and
            $script:WorldChunkGenHead -lt $queueTail -and
            $generatedThisFrame -lt $script:WorldChunkGenBudgetPerFrame
        ) {
            $itemEntry = $script:WorldChunkGenQueue[$script:WorldChunkGenHead]
            $script:WorldChunkGenHead++

            [int]$itemX = 0
            [int]$itemZ = 0

            if ($itemEntry -is [int64] -or $itemEntry -is [int32] -or $itemEntry -is [long]) {
                [int64]$itemCode = [int64]$itemEntry
                Decode-ChunkCoordCode -Code $itemCode -ChunkX ([ref]$itemX) -ChunkZ ([ref]$itemZ)
            }
            else {
                if ($null -ne $itemEntry -and $null -ne $itemEntry.PSObject.Properties['X']) {
                    $itemX = [int]$itemEntry.X
                }
                if ($null -ne $itemEntry -and $null -ne $itemEntry.PSObject.Properties['Z']) {
                    $itemZ = [int]$itemEntry.Z
                }
            }

            Set-ChunkQueuedFlag -ChunkX $itemX -ChunkZ $itemZ -Queued $false

            $key = "$itemX,$itemZ"
            if (-not $script:WorldChunks.ContainsKey($key)) {
                Generate-Chunk -ChunkX $itemX -ChunkZ $itemZ
                $generatedThisFrame++
            }
        }

        if ($script:WorldChunkGenHead -ge $queueTail) {
            $script:WorldChunkGenQueue.Clear()
            $script:WorldChunkGenHead = 0
        }
        elseif ($script:WorldChunkGenHead -gt 0 -and ($script:WorldChunkGenHead -ge 1024 -or $script:WorldChunkGenHead -ge [int]($script:WorldChunkGenQueue.Count / 2))) {
            $script:WorldChunkGenQueue.RemoveRange(0, $script:WorldChunkGenHead)
            $script:WorldChunkGenHead = 0
        }
    }

    # --- Unload chunks outside view distance + 2 ---
    $unloadDist = $vd + 2
    $removeList = $script:WorldChunkRemoveCodesScratch
    if ($null -eq $removeList) {
        $removeList = [System.Collections.Generic.List[int64]]::new(64)
        $script:WorldChunkRemoveCodesScratch = $removeList
    }
    else {
        $removeList.Clear()
    }
    foreach ($entry in $script:WorldChunksByCode.GetEnumerator()) {
        [int64]$code = [int64]$entry.Key
        $chunk = $entry.Value
        [int]$cx = [int]$chunk.ChunkX
        [int]$cz = [int]$chunk.ChunkZ
        $dx = [Math]::Abs($cx - $camChunkX)
        $dz = [Math]::Abs($cz - $camChunkZ)
        if ($dx -gt $unloadDist -or $dz -gt $unloadDist) {
            [void]$removeList.Add($code)
        }
    }
    foreach ($code in $removeList) {
        [int]$rmX = 0
        [int]$rmZ = 0
        Decode-ChunkCoordCode -Code ([int64]$code) -ChunkX ([ref]$rmX) -ChunkZ ([ref]$rmZ)
        Remove-WorldChunk -ChunkX $rmX -ChunkZ $rmZ
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

    Ensure-WorldChunkCodeMap

    # --- Lazy GL initialization on first render frame ---
    if (-not $script:WorldInitialized) {
        Initialize-Renderer
        $script:WorldInitialized = $true
        Write-Host "[World] GL resources initialized on first render frame." -ForegroundColor Green

        # Generate all initial chunks synchronously now that GL is ready.
        # This runs once on first frame to avoid queue/timing issues.
        $camPos = Get-CameraPosition
        [int]$initCX = [Math]::Floor($camPos.X / 16)
        [int]$initCZ = [Math]::Floor($camPos.Z / 16)
        [int]$initVD = $script:WorldViewDistance
        for ($ix = $initCX - $initVD; $ix -le $initCX + $initVD; $ix++) {
            for ($iz = $initCZ - $initVD; $iz -le $initCZ + $initVD; $iz++) {
                $initKey = "$ix,$iz"
                if (-not $script:WorldChunks.ContainsKey($initKey)) {
                    Generate-Chunk -ChunkX $ix -ChunkZ $iz
                }
                Set-ChunkQueuedFlag -ChunkX $ix -ChunkZ $iz -Queued $false
            }
        }
        # Clear queue since we just generated everything
        $script:WorldChunkGenQueue.Clear()
        $script:WorldChunkGenHead = 0
        $script:WorldChunkGenQueuedSet = @{}
        Write-Host "[World] Initial $($script:WorldChunks.Count) chunks generated." -ForegroundColor Green
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
    if ($null -eq $script:WorldCachedProjection -or $script:WorldLastProjWidth -ne [int]$width -or $script:WorldLastProjHeight -ne [int]$height) {
        [float]$fovRad = [float]([Math]::PI / 3.0)  # 60 degrees
        $script:WorldCachedProjection = Matrix4-Perspective -FovRadians $fovRad -Aspect $aspect -Near 0.1 -Far 500.0
        $script:WorldLastProjWidth = [int]$width
        $script:WorldLastProjHeight = [int]$height
    }
    $proj = $script:WorldCachedProjection

    # --- View matrix from camera ---
    $view = Get-ViewMatrix

    # --- Model matrix (identity - chunks use world-space coordinates) ---
    $model = $script:WorldCachedModelIdentity
    if ($null -eq $model) {
        $model = Matrix4-Identity
        $script:WorldCachedModelIdentity = $model
    }

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

    # --- Draw visible chunks only (distance + frustum + basic occlusion) ---
    [double]$frameStartTicks = [double]([System.Diagnostics.Stopwatch]::GetTimestamp())

    $camBasis = Get-CameraBasisVectors -ReuseCached
    [int]$camChunkX = [Math]::Floor($camBasis.Position.X / 16)
    [int]$camChunkZ = [Math]::Floor($camBasis.Position.Z / 16)
    [int]$renderDist = [int]($script:WorldViewDistance + $script:WorldRenderDistancePadding)

    [float]$fovRad = [float]([Math]::PI / 3.0)
    [float]$tanHalfFovY = [float][Math]::Tan($fovRad * 0.5)
    [float]$frustumPaddingChunks = [float]$script:WorldFrustumPaddingChunks

    $topologyRevision = [int64]-1
    if (Get-Command -Name Get-ChunkTopologyRevision -ErrorAction SilentlyContinue) {
        $topologyRevision = [int64](Get-ChunkTopologyRevision)
    }

    [double]$currentYaw = 0.0
    [double]$currentPitch = 0.0
    Get-CameraYawPitchValues -Yaw ([ref]$currentYaw) -Pitch ([ref]$currentPitch)
    [double]$camDeltaPos =
        [Math]::Abs([double]$camBasis.Position.X - [double]$script:WorldLastCameraX) +
        [Math]::Abs([double]$camBasis.Position.Y - [double]$script:WorldLastCameraY) +
        [Math]::Abs([double]$camBasis.Position.Z - [double]$script:WorldLastCameraZ)
    [double]$camDeltaRot =
        [Math]::Abs($currentYaw - [double]$script:WorldLastCameraYaw) +
        [Math]::Abs($currentPitch - [double]$script:WorldLastCameraPitch)

    [double]$posThreshold = [double]$script:WorldVisibilityCachePosThreshold
    if ($posThreshold -lt 0.001) { $posThreshold = 0.001 }
    [double]$rotThreshold = [double]$script:WorldVisibilityCacheRotThreshold
    if ($rotThreshold -lt 0.0005) { $rotThreshold = 0.0005 }

    $cameraChanged = (
        [double]::IsNaN([double]$script:WorldLastCameraX) -or
        $camDeltaPos -gt $posThreshold -or
        $camDeltaRot -gt $rotThreshold
    )

    $canReuseVisibility = (
        -not $cameraChanged -and
        $script:WorldLastChunkTopologyRevision -eq $topologyRevision -and
        $script:WorldLastChunkSetRevision -eq $script:WorldChunkSetRevision
    )

    Ensure-VisibleChunkBufferCapacity -Required $script:WorldChunks.Count
    [int]$visibleCount = 0

    if ($canReuseVisibility -and $script:WorldCachedVisibleByCode.Count -gt 0) {
        foreach ($chunk in $script:WorldCachedVisibleByCode.Values) {
            if ($null -eq $chunk) { continue }
            if ($visibleCount -ge $script:WorldVisibleChunksScratch.Length) { break }
            $script:WorldVisibleChunksScratch[$visibleCount] = $chunk
            $visibleCount++
        }
    }
    else {
        if ($script:WorldCachedVisibleByCode.Count -gt 0) {
            $script:WorldCachedVisibleByCode.Clear()
        }

        foreach ($entry in $script:WorldChunksByCode.GetEnumerator()) {
            [int64]$chunkCode = [int64]$entry.Key
            $chunk = $entry.Value
            if ($null -eq $chunk) { continue }

            [int]$dx = [Math]::Abs([int]$chunk.ChunkX - $camChunkX)
            [int]$dz = [Math]::Abs([int]$chunk.ChunkZ - $camChunkZ)
            if ($dx -gt $renderDist -or $dz -gt $renderDist) { continue }

            if (-not (Test-ChunkVisibleApprox -Chunk $chunk -CameraBasis $camBasis -Aspect $aspect -TanHalfFovY $tanHalfFovY -PaddingChunks $frustumPaddingChunks)) {
                continue
            }

            if (Test-ChunkOccludedBasic -Chunk $chunk -CameraBasis $camBasis -ChunkGrid $script:WorldChunksByCode -CamChunkX $camChunkX -CamChunkZ $camChunkZ -MaxSteps 8) {
                continue
            }

            $script:WorldVisibleChunksScratch[$visibleCount] = $chunk
            $visibleCount++
            $script:WorldCachedVisibleByCode[$chunkCode] = $chunk
        }

        $script:WorldLastChunkTopologyRevision = $topologyRevision
        $script:WorldLastChunkSetRevision = $script:WorldChunkSetRevision
    }

    for ($i = 0; $i -lt $visibleCount; $i++) {
        Draw-ChunkMesh -Chunk $script:WorldVisibleChunksScratch[$i]
    }
    for ($i = $visibleCount; $i -lt $script:WorldVisibleChunkCount; $i++) {
        $script:WorldVisibleChunksScratch[$i] = $null
    }
    $script:WorldVisibleChunkCount = $visibleCount

    [double]$nowTicks = [double]([System.Diagnostics.Stopwatch]::GetTimestamp())
    [double]$freq = [double][System.Diagnostics.Stopwatch]::Frequency
    if ($freq -gt 0.0) {
        [double]$frameMs = (($nowTicks - $frameStartTicks) * 1000.0) / $freq
        [int]$cap = [int]$script:WorldFrameTimesMs.Length
        if ($cap -gt 0) {
            [int]$writeIdx = [int]$script:WorldFrameTimesWriteIndex
            if ($writeIdx -ge $cap) {
                $writeIdx = 0
            }

            $script:WorldFrameTimesMs[$writeIdx] = [double]$frameMs

            $writeIdx++
            if ($writeIdx -ge $cap) {
                $writeIdx = 0
            }
            $script:WorldFrameTimesWriteIndex = $writeIdx

            if ([int]$script:WorldFrameTimesCount -lt $cap) {
                $script:WorldFrameTimesCount = [int]$script:WorldFrameTimesCount + 1
            }
        }
    }

    $script:WorldLastCameraX = [double]$camBasis.Position.X
    $script:WorldLastCameraY = [double]$camBasis.Position.Y
    $script:WorldLastCameraZ = [double]$camBasis.Position.Z
    $script:WorldLastCameraYaw = $currentYaw
    $script:WorldLastCameraPitch = $currentPitch

    $script:WorldCameraBasisCache.Position = $camBasis.Position
    $script:WorldCameraBasisCache.ForwardX = [float]$camBasis.ForwardX
    $script:WorldCameraBasisCache.ForwardY = [float]$camBasis.ForwardY
    $script:WorldCameraBasisCache.ForwardZ = [float]$camBasis.ForwardZ
    $script:WorldCameraBasisCache.RightX = [float]$camBasis.RightX
    $script:WorldCameraBasisCache.RightY = [float]$camBasis.RightY
    $script:WorldCameraBasisCache.RightZ = [float]$camBasis.RightZ
    $script:WorldCameraBasisCache.UpX = [float]$camBasis.UpX
    $script:WorldCameraBasisCache.UpY = [float]$camBasis.UpY
    $script:WorldCameraBasisCache.UpZ = [float]$camBasis.UpZ
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
    $blocks = $chunk.Blocks
    [int]$chunkBaseX = $ChunkX * 16
    [int]$chunkBaseZ = $ChunkZ * 16

    # Resolve biome once per chunk (reduces expensive per-column biome noise sampling)
    [int]$chunkCenterWorldX = [int]($ChunkX * 16 + 8)
    [int]$chunkCenterWorldZ = [int]($ChunkZ * 16 + 8)
    [double]$chunkTempNoise = Get-PerlinNoise2D -X ($chunkCenterWorldX * 0.005) -Y ($chunkCenterWorldZ * 0.005)
    [float]$chunkTemp = [float]($chunkTempNoise * 0.5 + 0.5)
    [double]$chunkMoistNoise = Get-PerlinNoise2D -X ($chunkCenterWorldX * 0.005 + 1000) -Y ($chunkCenterWorldZ * 0.005 + 1000)
    [float]$chunkMoist = [float]($chunkMoistNoise * 0.5 + 0.5)

    $biomePlains = $script:Biomes['Plains']
    $biomeForest = $script:Biomes['Forest']
    $biomeDesert = $script:Biomes['Desert']
    $biomeMountains = $script:Biomes['Mountains']
    $biomeSnow = $script:Biomes['Snow']
    $biomeSwamp = $script:Biomes['Swamp']

    if ($chunkTemp -lt 0.3) {
        $biome = $biomeSnow
    }
    elseif ($chunkTemp -ge 0.7 -and $chunkMoist -lt 0.3) {
        $biome = $biomeDesert
    }
    elseif ($chunkTemp -ge 0.3 -and $chunkTemp -lt 0.5 -and $chunkMoist -lt 0.4) {
        $biome = $biomeMountains
    }
    elseif ($chunkTemp -ge 0.3 -and $chunkTemp -lt 0.7 -and $chunkMoist -ge 0.85) {
        $biome = $biomeSwamp
    }
    elseif ($chunkTemp -ge 0.3 -and $chunkTemp -lt 0.7 -and $chunkMoist -ge 0.55) {
        $biome = $biomeForest
    }
    else {
        $biome = $biomePlains
    }

    [int]$biomeBaseHeight = [int]$biome.BaseHeight
    [float]$biomeHeightVariation = [float]$biome.HeightVariation
    [byte]$biomeFillerBlock = [byte]$biome.FillerBlock
    [byte]$biomeSubSurfaceBlock = [byte]$biome.SubSurfaceBlock
    [byte]$biomeSurfaceBlock = [byte]$biome.SurfaceBlock
    [int]$biomeWaterLevel = [int]$biome.WaterLevel
    [float]$biomeTreeDensity = [float]$biome.TreeDensity

    $heightMap = Get-ChunkHeightMap16x16 -BaseX $chunkBaseX -BaseZ $chunkBaseZ

    for ($x = 0; $x -lt 16; $x++) {
        [int]$worldX = $chunkBaseX + $x
        for ($z = 0; $z -lt 16; $z++) {
            [int]$worldZ = $chunkBaseZ + $z
            [int]$zBase16 = $z * 16
            [int]$columnBase = $x + $zBase16

            # Get base terrain height from precomputed chunk heightmap
            $baseHeight = $heightMap[$columnBase]

            # Adjust height based on biome parameters
            [int]$height = [int][Math]::Floor($biomeBaseHeight + ($baseHeight - 38) * $biomeHeightVariation)

            # Clamp height to valid range
            if ($height -lt 1) { $height = 1 }
            if ($height -gt 255) { $height = 255 }

            # Fill column blocks (branch-minimized loops)
            $blocks[$columnBase] = 1

            [int]$fillerEnd = $height - 4
            if ($fillerEnd -ge 1) {
                [int]$idx = $columnBase + 256
                for ($y = 1; $y -le $fillerEnd; $y++) {
                    $blocks[$idx] = $biomeFillerBlock
                    $idx += 256
                }
            }

            [int]$subStart = $height - 3
            if ($subStart -lt 1) { $subStart = 1 }
            [int]$subEnd = $height - 1
            if ($subEnd -ge $subStart) {
                [int]$idx = $columnBase + ($subStart * 256)
                for ($y = $subStart; $y -le $subEnd; $y++) {
                    $blocks[$idx] = $biomeSubSurfaceBlock
                    $idx += 256
                }
            }

            [int]$surfaceIndex = $columnBase + ($height * 256)
            $blocks[$surfaceIndex] = $biomeSurfaceBlock

            # Fill water if height < water level
            [int]$waterLevel = $biomeWaterLevel
            if ($height -lt $waterLevel) {
                [int]$waterIdx = $columnBase + (($height + 1) * 256)
                for ($y = $height + 1; $y -le $waterLevel; $y++) {
                    $blocks[$waterIdx] = 7
                    $waterIdx += 256
                }
            }

            if ($height -gt [int]$chunk.MaxSolidY) {
                $chunk.MaxSolidY = [int]$height
            }

            # --- Optional: Place trees ---
            if ($biomeTreeDensity -gt 0 -and $biomeSurfaceBlock -eq [byte]3 -and $height -gt $waterLevel) {
                # Deterministic tree placement using hash
                [long]$hashVal = [System.Math]::Abs($worldX * 73856093 -bxor $worldZ * 19349663)
                [double]$treeCheck = ($hashVal % 1000) / 1000.0
                if ($treeCheck -lt $biomeTreeDensity) {
                    # Ensure trunk fits within chunk boundaries (leave 1-block border)
                    if ($x -ge 2 -and $x -le 13 -and $z -ge 2 -and $z -le 13) {
                        # Trunk: 4 blocks of wood above surface
                        [int]$trunkBase = $height + 1
                        for ($ty = 0; $ty -lt 4; $ty++) {
                            $treeY = $trunkBase + $ty
                            if ($treeY -lt 256) {
                                $blocks[$columnBase + $treeY * 256] = 5
                                if ($treeY -gt [int]$chunk.MaxSolidY) {
                                    $chunk.MaxSolidY = [int]$treeY
                                }
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
                                            $blocks[$leafX + $leafZ * 16 + $leafY * 256] = 6
                                            if ($leafY -gt [int]$chunk.MaxSolidY) {
                                                $chunk.MaxSolidY = [int]$leafY
                                            }
                                        }
                                        else {
                                            # Top of trunk gets leaves too
                                            $blocks[$leafX + $leafZ * 16 + $leafY * 256] = 6
                                            if ($leafY -gt [int]$chunk.MaxSolidY) {
                                                $chunk.MaxSolidY = [int]$leafY
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
    }

    # Build mesh once at creation; later rebuilds are revision/dirty-gated.
    Build-ChunkMesh -Chunk $chunk

    # Store in world maps
    $key = "$ChunkX,$ChunkZ"
    $script:WorldChunks[$key] = $chunk
    $code = Get-ChunkCoordCode -ChunkX $ChunkX -ChunkZ $ChunkZ
    $script:WorldChunksByCode[$code] = $chunk
    $script:WorldChunkSetRevision = [int64]$script:WorldChunkSetRevision + 1

    if ($script:WorldVerboseLogging) {
        Write-Host "[World] Generated chunk ($ChunkX, $ChunkZ) - biome sampling complete." -ForegroundColor DarkCyan
    }

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
        $code = Get-ChunkCoordCode -ChunkX $ChunkX -ChunkZ $ChunkZ
        if ($script:WorldChunksByCode.ContainsKey($code)) {
            $script:WorldChunksByCode.Remove($code)
        }
        Set-ChunkQueuedFlag -ChunkX $ChunkX -ChunkZ $ChunkZ -Queued $false
        $script:WorldChunkSetRevision = [int64]$script:WorldChunkSetRevision + 1
        if ($script:WorldVerboseLogging) {
            Write-Host "[World] Unloaded chunk ($ChunkX, $ChunkZ)." -ForegroundColor DarkGray
        }
    }
}

function Get-WorldLoadedChunkCount {
    return [int]$script:WorldChunks.Count
}

function Get-WorldVisibleChunkCount {
    return [int]$script:WorldVisibleChunkCount
}

function Set-WorldVisibilityCacheState {
    param([bool]$Enabled)

    if (-not $Enabled) {
        $script:WorldLastChunkTopologyRevision = [int64]-1
        $script:WorldLastChunkSetRevision = [int64]-1
        $script:WorldLastCameraX = [double]::NaN
        $script:WorldLastCameraY = [double]::NaN
        $script:WorldLastCameraZ = [double]::NaN
        $script:WorldLastCameraYaw = [double]::NaN
        $script:WorldLastCameraPitch = [double]::NaN
    }

    if ($script:WorldCachedVisibleByCode.Count -gt 0) {
        $script:WorldCachedVisibleByCode.Clear()
    }
    for ($i = 0; $i -lt $script:WorldVisibleChunkCount; $i++) {
        $script:WorldVisibleChunksScratch[$i] = $null
    }
    $script:WorldVisibleChunkCount = 0
}

function Set-WorldPerformanceSampling {
    param(
        [bool]$Enabled,
        [ValidateRange(16, 8192)]
        [int]$HistorySize = 512
    )

    if (-not $Enabled) {
        $script:WorldFrameTimesMs = [double[]]::new(16)
        $script:WorldFrameTimesCount = [int]0
        $script:WorldFrameTimesWriteIndex = [int]0
        return
    }

    if ($null -eq $script:WorldFrameTimesMs -or $script:WorldFrameTimesMs.Length -ne $HistorySize) {
        $script:WorldFrameTimesMs = [double[]]::new($HistorySize)
    }
    else {
        [Array]::Clear($script:WorldFrameTimesMs, 0, $script:WorldFrameTimesMs.Length)
    }

    $script:WorldFrameTimesCount = [int]0
    $script:WorldFrameTimesWriteIndex = [int]0
}
