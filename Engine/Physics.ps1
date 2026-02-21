# ============================================================================
# Engine/Physics.ps1 - AABB Collision Detection
# ============================================================================
# Checks the player's bounding box against world blocks and prevents
# clipping through solid blocks. Runs AFTER Update-Player each frame,
# reading the position Player.ps1 wrote and correcting it.
#
# Dependencies: Engine/Math.ps1, Game/Player.ps1, World/Blocks.ps1
# ============================================================================

# --- Module State ---
$script:PhysicsEnabled     = $true
$script:PhysicsPrevPosition = New-Vector3   # Position before Player.ps1 moved
$script:PhysicsSkinWidth   = [float]0.001   # Tiny gap to prevent floating point sticking

# ============================================================================
# Initialize-Physics - Register the physics update callback
# ============================================================================

function Initialize-Physics {
    <#
    .SYNOPSIS
        Registers Update-Physics callback. Must be called AFTER Initialize-Player
        so the physics callback runs after Update-Player in the callback list.
    #>

    $script:PhysicsEnabled = $true
    $script:PhysicsPrevPosition = $script:PlayerPosition

    Register-UpdateCallback ${function:Update-Physics}

    Write-Host "[Physics] AABB collision system initialized." -ForegroundColor Green
}

# ============================================================================
# Update-Physics - Per-frame collision detection and response
# ============================================================================

function Update-Physics {
    <#
    .SYNOPSIS
        Reads player position (already moved by Update-Player), tests AABB
        against solid world blocks, and pushes the player out of any overlaps.
        Resolves each axis independently to allow wall sliding.
    #>
    param($dt)

    if (-not $script:PhysicsEnabled) { return }
    if ($script:PlayerFlyMode) { return }

    # Player dimensions (from Player.ps1 module state)
    [float]$halfW = $script:PlayerWidth  * 0.5   # 0.3
    [float]$halfD = $script:PlayerDepth  * 0.5   # 0.3
    [float]$height = $script:PlayerHeight          # 1.8

    # The position Player.ps1 wrote this frame (feet position)
    $pos = $script:PlayerPosition
    $vel = $script:PlayerVelocity

    # We need the position BEFORE Player.ps1 moved to do axis-separated resolution.
    # Since we stored it at end of last frame, use that.
    $oldPos = $script:PhysicsPrevPosition

    # --- Axis-by-axis collision resolution ---
    # Start from oldPos, try each axis of the new position independently.
    # This gives wall-sliding behavior.

    # Resolve Y axis first (gravity/jumping is most important)
    $testPos = New-Vector3 -X $oldPos.X -Y $pos.Y -Z $oldPos.Z
    $resolved = Resolve-AxisCollision -Position $testPos -HalfW $halfW -Height $height -HalfD $halfD -Axis 'Y' -Velocity $vel
    $testPos = $resolved.Position
    $yVel = $resolved.Velocity

    # Resolve X axis
    $testPos = New-Vector3 -X $pos.X -Y $testPos.Y -Z $testPos.Z
    $resolved = Resolve-AxisCollision -Position $testPos -HalfW $halfW -Height $height -HalfD $halfD -Axis 'X' -Velocity (New-Vector3 -X $vel.X -Y $yVel -Z $vel.Z)
    $testPos = $resolved.Position
    $xVel = $resolved.XVelocity

    # Resolve Z axis
    $testPos = New-Vector3 -X $testPos.X -Y $testPos.Y -Z $pos.Z
    $resolved = Resolve-AxisCollision -Position $testPos -HalfW $halfW -Height $height -HalfD $halfD -Axis 'Z' -Velocity (New-Vector3 -X $xVel -Y $yVel -Z $vel.Z)
    $testPos = $resolved.Position
    $zVel = $resolved.ZVelocity

    # Write back corrected position and velocity
    $script:PlayerPosition = $testPos
    $script:PlayerVelocity = New-Vector3 -X $xVel -Y $yVel -Z $zVel

    # Store current position for next frame's old position
    $script:PhysicsPrevPosition = $script:PlayerPosition
}

# ============================================================================
# Resolve-AxisCollision - Check and resolve AABB overlap on a single axis
# ============================================================================

function Resolve-AxisCollision {
    <#
    .SYNOPSIS
        Tests player AABB at given position against all overlapping solid blocks
        and resolves penetration along the specified axis.
    #>
    param(
        $Position,
        [float]$HalfW,
        [float]$Height,
        [float]$HalfD,
        [string]$Axis,
        $Velocity
    )

    $px = $Position.X
    $py = $Position.Y
    $pz = $Position.Z

    # Player AABB bounds
    [float]$minX = $px - $HalfW
    [float]$maxX = $px + $HalfW
    [float]$minY = $py
    [float]$maxY = $py + $Height
    [float]$minZ = $pz - $HalfD
    [float]$maxZ = $pz + $HalfD

    # Block coordinate range that could overlap the AABB
    [int]$bMinX = [Math]::Floor($minX)
    [int]$bMaxX = [Math]::Floor($maxX - $script:PhysicsSkinWidth)
    [int]$bMinY = [Math]::Floor($minY)
    [int]$bMaxY = [Math]::Floor($maxY - $script:PhysicsSkinWidth)
    [int]$bMinZ = [Math]::Floor($minZ)
    [int]$bMaxZ = [Math]::Floor($maxZ - $script:PhysicsSkinWidth)

    # Clamp Y to valid range
    if ($bMinY -lt 0) { $bMinY = 0 }
    if ($bMaxY -gt 255) { $bMaxY = 255 }

    $velX = $Velocity.X
    $velY = $Velocity.Y
    $velZ = $Velocity.Z

    for ($by = $bMinY; $by -le $bMaxY; $by++) {
        for ($bz = $bMinZ; $bz -le $bMaxZ; $bz++) {
            for ($bx = $bMinX; $bx -le $bMaxX; $bx++) {
                $blockId = Get-WorldBlock -X $bx -Y $by -Z $bz
                if (-not (Test-BlockSolid -Id $blockId)) { continue }

                # Block AABB: (bx, by, bz) to (bx+1, by+1, bz+1)
                [float]$blockMinX = [float]$bx
                [float]$blockMaxX = [float]($bx + 1)
                [float]$blockMinY = [float]$by
                [float]$blockMaxY = [float]($by + 1)
                [float]$blockMinZ = [float]$bz
                [float]$blockMaxZ = [float]($bz + 1)

                # Check AABB overlap
                $overlapsX = ($maxX -gt $blockMinX) -and ($minX -lt $blockMaxX)
                $overlapsY = ($maxY -gt $blockMinY) -and ($minY -lt $blockMaxY)
                $overlapsZ = ($maxZ -gt $blockMinZ) -and ($minZ -lt $blockMaxZ)

                if (-not ($overlapsX -and $overlapsY -and $overlapsZ)) { continue }

                # Resolve penetration on the specified axis
                switch ($Axis) {
                    'Y' {
                        if ($velY -le 0) {
                            # Moving down - push up to top of block
                            $py = $blockMaxY
                            $velY = 0
                            $script:PlayerOnGround = $true
                            $script:PlayerState = 'Walking'
                        } else {
                            # Moving up - push down to bottom of block
                            $py = $blockMinY - $Height
                            $velY = 0
                        }
                        # Recalculate Y bounds
                        $minY = $py
                        $maxY = $py + $Height
                    }
                    'X' {
                        if ($velX -gt 0) {
                            # Moving +X - push back to left side of block
                            $px = $blockMinX - $HalfW - $script:PhysicsSkinWidth
                        } else {
                            # Moving -X - push back to right side of block
                            $px = $blockMaxX + $HalfW + $script:PhysicsSkinWidth
                        }
                        $velX = 0
                        # Recalculate X bounds
                        $minX = $px - $HalfW
                        $maxX = $px + $HalfW
                    }
                    'Z' {
                        if ($velZ -gt 0) {
                            # Moving +Z - push back
                            $pz = $blockMinZ - $HalfD - $script:PhysicsSkinWidth
                        } else {
                            # Moving -Z - push forward
                            $pz = $blockMaxZ + $HalfD + $script:PhysicsSkinWidth
                        }
                        $velZ = 0
                        # Recalculate Z bounds
                        $minZ = $pz - $HalfD
                        $maxZ = $pz + $HalfD
                    }
                }
            }
        }
    }

    # Return result with resolved position and velocity components
    return [PSCustomObject]@{
        Position  = New-Vector3 -X $px -Y $py -Z $pz
        Velocity  = $velY
        XVelocity = $velX
        ZVelocity = $velZ
    }
}
