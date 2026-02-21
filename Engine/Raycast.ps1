# ============================================================================
# Engine/Raycast.ps1 - DDA Voxel Raycasting
# ============================================================================
# Provides ray-voxel intersection using the Digital Differential Analyzer
# (DDA) algorithm. Casts a 3D ray through the voxel grid and returns the
# first solid block hit with its face normal and distance.
#
# Used for block selection/highlighting and block interaction (place/break).
#
# Dependencies: Engine/Camera.ps1, Game/Player.ps1, World/Blocks.ps1
# ============================================================================

# --- Configuration ---
$script:RaycastMaxDistance = [float]7.0   # Max reach distance in blocks

# ============================================================================
# Get-CameraRay - Compute ray origin and direction from camera state
# ============================================================================

function Get-CameraRay {
    <#
    .SYNOPSIS
        Computes the ray origin (player eye position) and ray direction
        (camera look direction) from current camera/player state.
    .OUTPUTS
        PSCustomObject with Origin (Vector3) and Direction (Vector3).
    #>

    # Eye position = player feet + eye offset
    $eyeX = $script:PlayerPosition.X
    $eyeY = $script:PlayerPosition.Y + $script:PlayerEyeOffset
    $eyeZ = $script:PlayerPosition.Z

    # Forward direction from camera yaw and pitch
    $yaw   = $script:CameraYaw
    $pitch = $script:CameraPitch

    $dirX = -[Math]::Sin($yaw) * [Math]::Cos($pitch)
    $dirY =  [Math]::Sin($pitch)
    $dirZ = -[Math]::Cos($yaw) * [Math]::Cos($pitch)

    return [PSCustomObject]@{
        Origin    = [PSCustomObject]@{ X = [float]$eyeX; Y = [float]$eyeY; Z = [float]$eyeZ }
        Direction = [PSCustomObject]@{ X = [float]$dirX; Y = [float]$dirY; Z = [float]$dirZ }
    }
}

# ============================================================================
# Invoke-Raycast - DDA voxel traversal algorithm
# ============================================================================

function Invoke-Raycast {
    <#
    .SYNOPSIS
        Casts a ray from the given origin in the given direction using the
        DDA algorithm, stepping through voxel grid cells.
    .PARAMETER OriginX
        Ray origin X coordinate (float).
    .PARAMETER OriginY
        Ray origin Y coordinate (float).
    .PARAMETER OriginZ
        Ray origin Z coordinate (float).
    .PARAMETER DirX
        Ray direction X component (should be normalized).
    .PARAMETER DirY
        Ray direction Y component.
    .PARAMETER DirZ
        Ray direction Z component.
    .PARAMETER MaxDistance
        Maximum ray distance in blocks. Defaults to $script:RaycastMaxDistance.
    .OUTPUTS
        PSCustomObject with BlockX, BlockY, BlockZ, NormalX, NormalY, NormalZ,
        Distance, BlockId -- or $null if no solid block hit within range.
    #>
    param(
        [float]$OriginX,
        [float]$OriginY,
        [float]$OriginZ,
        [float]$DirX,
        [float]$DirY,
        [float]$DirZ,
        [float]$MaxDistance = $script:RaycastMaxDistance
    )

    # Current voxel coordinates (integer grid cell containing the origin)
    [int]$mapX = [Math]::Floor($OriginX)
    [int]$mapY = [Math]::Floor($OriginY)
    [int]$mapZ = [Math]::Floor($OriginZ)

    # Step direction for each axis: +1 or -1
    [int]$stepX = if ($DirX -ge 0) { 1 } else { -1 }
    [int]$stepY = if ($DirY -ge 0) { 1 } else { -1 }
    [int]$stepZ = if ($DirZ -ge 0) { 1 } else { -1 }

    # tDelta: how far along the ray (in t) to move one full voxel in each axis
    # Avoid division by zero with a very large number
    $huge = [float]1e30

    if ([Math]::Abs($DirX) -gt 1e-10) {
        $tDeltaX = [float]([Math]::Abs(1.0 / $DirX))
    } else {
        $tDeltaX = $huge
    }

    if ([Math]::Abs($DirY) -gt 1e-10) {
        $tDeltaY = [float]([Math]::Abs(1.0 / $DirY))
    } else {
        $tDeltaY = $huge
    }

    if ([Math]::Abs($DirZ) -gt 1e-10) {
        $tDeltaZ = [float]([Math]::Abs(1.0 / $DirZ))
    } else {
        $tDeltaZ = $huge
    }

    # tMax: distance along ray to the next voxel boundary for each axis
    if ([Math]::Abs($DirX) -gt 1e-10) {
        if ($DirX -ge 0) {
            $tMaxX = [float](($mapX + 1.0 - $OriginX) / $DirX)
        } else {
            $tMaxX = [float](($mapX - $OriginX) / $DirX)
        }
    } else {
        $tMaxX = $huge
    }

    if ([Math]::Abs($DirY) -gt 1e-10) {
        if ($DirY -ge 0) {
            $tMaxY = [float](($mapY + 1.0 - $OriginY) / $DirY)
        } else {
            $tMaxY = [float](($mapY - $OriginY) / $DirY)
        }
    } else {
        $tMaxY = $huge
    }

    if ([Math]::Abs($DirZ) -gt 1e-10) {
        if ($DirZ -ge 0) {
            $tMaxZ = [float](($mapZ + 1.0 - $OriginZ) / $DirZ)
        } else {
            $tMaxZ = [float](($mapZ - $OriginZ) / $DirZ)
        }
    } else {
        $tMaxZ = $huge
    }

    # Track which face was last crossed for normal computation
    # 0 = X axis, 1 = Y axis, 2 = Z axis
    [int]$lastAxis = -1

    # Maximum number of steps to prevent infinite loops
    [int]$maxSteps = [int]($MaxDistance * 3) + 1

    for ($i = 0; $i -lt $maxSteps; $i++) {
        # Check the current voxel for a solid block
        $blockId = Get-WorldBlock -X $mapX -Y $mapY -Z $mapZ
        if (Test-BlockSolid -Id $blockId) {
            # Compute distance from origin to the hit point
            # Use the tMax of the axis we last stepped (that is the entry t)
            if ($lastAxis -eq 0) {
                $dist = $tMaxX - $tDeltaX
            } elseif ($lastAxis -eq 1) {
                $dist = $tMaxY - $tDeltaY
            } elseif ($lastAxis -eq 2) {
                $dist = $tMaxZ - $tDeltaZ
            } else {
                # Ray started inside a solid block (distance = 0)
                $dist = [float]0.0
            }

            if ($dist -gt $MaxDistance) {
                return $null
            }

            # Determine face normal from the last axis stepped
            [int]$nX = 0; [int]$nY = 0; [int]$nZ = 0
            if ($lastAxis -eq 0) {
                $nX = -$stepX
            } elseif ($lastAxis -eq 1) {
                $nY = -$stepY
            } elseif ($lastAxis -eq 2) {
                $nZ = -$stepZ
            }
            # If lastAxis is -1, we started inside a block; normal is zero vector

            return [PSCustomObject]@{
                BlockX  = [int]$mapX
                BlockY  = [int]$mapY
                BlockZ  = [int]$mapZ
                NormalX = [int]$nX
                NormalY = [int]$nY
                NormalZ = [int]$nZ
                Distance = [float]$dist
                BlockId  = $blockId
            }
        }

        # Advance to the next voxel boundary (DDA step)
        if ($tMaxX -lt $tMaxY) {
            if ($tMaxX -lt $tMaxZ) {
                # Step X
                if ($tMaxX -gt $MaxDistance) { return $null }
                $mapX += $stepX
                $tMaxX += $tDeltaX
                $lastAxis = 0
            } else {
                # Step Z
                if ($tMaxZ -gt $MaxDistance) { return $null }
                $mapZ += $stepZ
                $tMaxZ += $tDeltaZ
                $lastAxis = 2
            }
        } else {
            if ($tMaxY -lt $tMaxZ) {
                # Step Y
                if ($tMaxY -gt $MaxDistance) { return $null }
                $mapY += $stepY
                $tMaxY += $tDeltaY
                $lastAxis = 1
            } else {
                # Step Z
                if ($tMaxZ -gt $MaxDistance) { return $null }
                $mapZ += $stepZ
                $tMaxZ += $tDeltaZ
                $lastAxis = 2
            }
        }
    }

    # Exceeded max steps without hitting anything
    return $null
}

# ============================================================================
# Get-LookTarget - Convenience: raycast from camera eye in look direction
# ============================================================================

function Get-LookTarget {
    <#
    .SYNOPSIS
        Casts a ray from the player's eye position in the camera's look
        direction and returns the first solid block hit, or $null.
    .DESCRIPTION
        Combines Get-CameraRay and Invoke-Raycast into a single call for
        easy use by block selection, highlighting, and interaction systems.
    .OUTPUTS
        PSCustomObject with BlockX, BlockY, BlockZ, NormalX, NormalY, NormalZ,
        Distance, BlockId -- or $null if no block in range.
    #>

    $ray = Get-CameraRay

    return (Invoke-Raycast `
        -OriginX $ray.Origin.X `
        -OriginY $ray.Origin.Y `
        -OriginZ $ray.Origin.Z `
        -DirX $ray.Direction.X `
        -DirY $ray.Direction.Y `
        -DirZ $ray.Direction.Z)
}
