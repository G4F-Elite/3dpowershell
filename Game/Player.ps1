# ============================================================================
# Game/Player.ps1 - Player Controller
# ============================================================================
# Manages player position, velocity, movement physics (gravity, friction),
# jumping, ground detection, and camera sync. Takes over camera movement
# from Camera.ps1 - the camera follows the player's eye position.
#
# Dependencies: Engine/Math.ps1, Engine/Input.ps1, Engine/Camera.ps1,
#   World/World.ps1, World/Chunk.ps1
# ============================================================================

# --- Module State ---
$script:PlayerPosition     = New-Vector3 -X 0 -Y 70 -Z 0   # Feet position
$script:PlayerVelocity     = New-Vector3                      # Current velocity
$script:PlayerWidth        = [float]0.6                       # AABB width (X)
$script:PlayerHeight       = [float]1.8                       # AABB height (Y)
$script:PlayerDepth        = [float]0.6                       # AABB depth (Z)
$script:PlayerEyeOffset    = [float]1.62                      # Eye height above feet
$script:PlayerMoveSpeed    = [float]4.3                       # Walking speed (blocks/sec)
$script:PlayerSprintMult   = [float]1.3                       # Sprint speed multiplier
$script:PlayerJumpVelocity = [float]8.0                       # Initial jump velocity
$script:PlayerGravity      = [float]20.0                      # Gravity acceleration
$script:PlayerTerminalVel  = [float]-50.0                     # Terminal velocity cap
$script:PlayerOnGround     = $false                           # Ground contact flag
$script:PlayerState        = 'Falling'                        # Walking, Falling, Jumping, Swimming
$script:PlayerFlyMode      = $false                           # Debug fly toggle (F3)

function Resolve-PlayerKeyBinding {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Keys]$Fallback
    )

    if (Get-Command -Name Get-KeyBinding -ErrorAction SilentlyContinue) {
        try {
            [string]$bindingName = [string](Get-KeyBinding -Action $Action -Default ([string]$Fallback))
            if (-not [string]::IsNullOrWhiteSpace($bindingName)) {
                $parsed = [System.Enum]::Parse([System.Windows.Forms.Keys], $bindingName, $true)
                if ($null -ne $parsed) {
                    return [System.Windows.Forms.Keys]$parsed
                }
            }
        }
        catch {
        }
    }

    return [System.Windows.Forms.Keys]$Fallback
}

# ============================================================================
# Initialize-Player - Set up player and register update callback
# ============================================================================

function Initialize-Player {
    <#
    .SYNOPSIS
        Initializes the player controller and registers Update-Player callback.
    .DESCRIPTION
        Spawns the player at (0, 70, 0). Must be called AFTER Initialize-Camera
        and Initialize-World. The player takes over camera positioning.
    #>

    $script:PlayerPosition     = New-Vector3 -X 0 -Y 70 -Z 0
    $script:PlayerVelocity     = New-Vector3
    $script:PlayerOnGround     = $false
    $script:PlayerState        = 'Falling'
    $script:PlayerFlyMode      = $false

    Register-UpdateCallback ${function:Update-Player}

    Write-Host "[Player] Player initialized at (0, 70, 0)." -ForegroundColor Green
}

# ============================================================================
# Update-Player - Per-frame player update
# ============================================================================

function Update-Player {
    <#
    .SYNOPSIS
        Per-frame player update. Handles input, physics, ground check, camera sync.
    #>
    param($dt)

    # Clamp dt to prevent physics explosions on lag spikes
    if ($dt -gt 0.1) { $dt = 0.1 }

    # --- Wait for spawn chunk before applying physics ---
    [int]$spawnChunkX = [Math]::Floor($script:PlayerPosition.X / 16.0)
    [int]$spawnChunkZ = [Math]::Floor($script:PlayerPosition.Z / 16.0)
    if (-not $script:WorldChunks.ContainsKey("$spawnChunkX,$spawnChunkZ")) {
        # Chunk not loaded yet — hold player in place, sync camera only
        $eyePos = New-Vector3 `
            -X $script:PlayerPosition.X `
            -Y ($script:PlayerPosition.Y + $script:PlayerEyeOffset) `
            -Z $script:PlayerPosition.Z
        Set-CameraPosition -Position $eyePos
        return
    }

    # --- F3 toggles fly mode ---
    if (Get-KeyDown ([System.Windows.Forms.Keys]::F3)) {
        $script:PlayerFlyMode = -not $script:PlayerFlyMode
        if ($script:PlayerFlyMode) {
            $script:PlayerVelocity = New-Vector3
            Write-Host "[Player] Fly mode ENABLED." -ForegroundColor Yellow
        } else {
            Write-Host "[Player] Fly mode DISABLED." -ForegroundColor Yellow
        }
    }

    if ($script:PlayerFlyMode) {
        Update-PlayerFlyMode $dt
    } else {
        Update-PlayerNormal $dt
    }

    # --- Sync camera to player eye position ---
    $eyePos = New-Vector3 `
        -X $script:PlayerPosition.X `
        -Y ($script:PlayerPosition.Y + $script:PlayerEyeOffset) `
        -Z $script:PlayerPosition.Z
    Set-CameraPosition -Position $eyePos
}

# ============================================================================
# Update-PlayerNormal - Standard movement with gravity
# ============================================================================

function Update-PlayerNormal {
    param($dt)

    [System.Windows.Forms.Keys]$moveForwardKey = Resolve-PlayerKeyBinding -Action 'MoveForward' -Fallback ([System.Windows.Forms.Keys]::W)
    [System.Windows.Forms.Keys]$moveBackwardKey = Resolve-PlayerKeyBinding -Action 'MoveBackward' -Fallback ([System.Windows.Forms.Keys]::S)
    [System.Windows.Forms.Keys]$moveLeftKey = Resolve-PlayerKeyBinding -Action 'MoveLeft' -Fallback ([System.Windows.Forms.Keys]::A)
    [System.Windows.Forms.Keys]$moveRightKey = Resolve-PlayerKeyBinding -Action 'MoveRight' -Fallback ([System.Windows.Forms.Keys]::D)
    [System.Windows.Forms.Keys]$sprintKey = Resolve-PlayerKeyBinding -Action 'Sprint' -Fallback ([System.Windows.Forms.Keys]::ShiftKey)
    [System.Windows.Forms.Keys]$jumpKey = Resolve-PlayerKeyBinding -Action 'Jump' -Fallback ([System.Windows.Forms.Keys]::Space)

    $yaw = $script:CameraYaw

    # --- Horizontal movement direction from camera yaw ---
    $forwardX = -[Math]::Sin($yaw)
    $forwardZ = -[Math]::Cos($yaw)
    $forward = New-Vector3 -X $forwardX -Y 0 -Z $forwardZ

    $worldUp = New-Vector3 -X 0 -Y 1 -Z 0
    $right = Vector3-Normalize (Vector3-Cross $forward $worldUp)

    $moveDir = New-Vector3

    if (Get-Key $moveForwardKey) {
        $moveDir = Vector3-Add $moveDir $forward
    }
    if (Get-Key $moveBackwardKey) {
        $moveDir = Vector3-Subtract $moveDir $forward
    }
    if (Get-Key $moveLeftKey) {
        $moveDir = Vector3-Subtract $moveDir $right
    }
    if (Get-Key $moveRightKey) {
        $moveDir = Vector3-Add $moveDir $right
    }

    # Normalize horizontal move direction
    $moveLen = Vector3-Length $moveDir
    if ($moveLen -gt 0) {
        $moveDir = Vector3-Normalize $moveDir
    }

    # Determine speed (sprint with Shift)
    $speed = $script:PlayerMoveSpeed
    if (Get-Key $sprintKey) {
        $speed = $speed * $script:PlayerSprintMult
    }

    # Apply horizontal velocity directly (no acceleration model - instant response)
    $hVelX = $moveDir.X * $speed
    $hVelZ = $moveDir.Z * $speed

    # --- Vertical physics ---
    $vVelY = $script:PlayerVelocity.Y

    # Jump
    if ($script:PlayerOnGround -and (Get-Key $jumpKey)) {
        $vVelY = $script:PlayerJumpVelocity
        $script:PlayerOnGround = $false
        $script:PlayerState = 'Jumping'
    }

    # Gravity
    $vVelY -= $script:PlayerGravity * $dt

    # Terminal velocity
    if ($vVelY -lt $script:PlayerTerminalVel) {
        $vVelY = $script:PlayerTerminalVel
    }

    # Store velocity
    $script:PlayerVelocity = New-Vector3 -X $hVelX -Y $vVelY -Z $hVelZ

    # --- Apply movement ---
    $newPos = New-Vector3 `
        -X ($script:PlayerPosition.X + $hVelX * $dt) `
        -Y ($script:PlayerPosition.Y + $vVelY * $dt) `
        -Z ($script:PlayerPosition.Z + $hVelZ * $dt)

    # --- Ground check ---
    $feetY = $newPos.Y
    $groundY = Get-GroundHeight -X $newPos.X -Z $newPos.Z

    if ($feetY -le $groundY) {
        # Land on ground
        $newPos = New-Vector3 -X $newPos.X -Y $groundY -Z $newPos.Z
        $script:PlayerVelocity = New-Vector3 -X $hVelX -Y 0 -Z $hVelZ
        $script:PlayerOnGround = $true
    } else {
        $script:PlayerOnGround = $false
    }

    # --- Update state ---
    if ($script:PlayerOnGround) {
        $script:PlayerState = 'Walking'
    } else {
        if ($script:PlayerVelocity.Y -gt 0) {
            $script:PlayerState = 'Jumping'
        } else {
            $script:PlayerState = 'Falling'
        }
    }

    # Check for swimming (feet in water block)
    $blockAtFeet = Get-WorldBlock -X ([int][Math]::Floor($newPos.X)) -Y ([int][Math]::Floor($newPos.Y)) -Z ([int][Math]::Floor($newPos.Z))
    if ($blockAtFeet -eq [byte]7) {
        $script:PlayerState = 'Swimming'
    }

    $script:PlayerPosition = $newPos

    # Prevent falling into the void
    if ($script:PlayerPosition.Y -lt -64) {
        $script:PlayerPosition = New-Vector3 -X $script:PlayerPosition.X -Y 70 -Z $script:PlayerPosition.Z
        $script:PlayerVelocity = New-Vector3
        Write-Host "[Player] Respawned - fell into void." -ForegroundColor Red
    }
}

# ============================================================================
# Update-PlayerFlyMode - Free-fly debug movement (no gravity)
# ============================================================================

function Update-PlayerFlyMode {
    param($dt)

    [System.Windows.Forms.Keys]$moveForwardKey = Resolve-PlayerKeyBinding -Action 'MoveForward' -Fallback ([System.Windows.Forms.Keys]::W)
    [System.Windows.Forms.Keys]$moveBackwardKey = Resolve-PlayerKeyBinding -Action 'MoveBackward' -Fallback ([System.Windows.Forms.Keys]::S)
    [System.Windows.Forms.Keys]$moveLeftKey = Resolve-PlayerKeyBinding -Action 'MoveLeft' -Fallback ([System.Windows.Forms.Keys]::A)
    [System.Windows.Forms.Keys]$moveRightKey = Resolve-PlayerKeyBinding -Action 'MoveRight' -Fallback ([System.Windows.Forms.Keys]::D)
    [System.Windows.Forms.Keys]$jumpKey = Resolve-PlayerKeyBinding -Action 'Jump' -Fallback ([System.Windows.Forms.Keys]::Space)
    [System.Windows.Forms.Keys]$sprintKey = Resolve-PlayerKeyBinding -Action 'Sprint' -Fallback ([System.Windows.Forms.Keys]::ShiftKey)

    $yaw = $script:CameraYaw

    $forwardX = -[Math]::Sin($yaw)
    $forwardZ = -[Math]::Cos($yaw)
    $forward = New-Vector3 -X $forwardX -Y 0 -Z $forwardZ

    $worldUp = New-Vector3 -X 0 -Y 1 -Z 0
    $right = Vector3-Normalize (Vector3-Cross $forward $worldUp)

    $moveDir = New-Vector3

    if (Get-Key $moveForwardKey) {
        $moveDir = Vector3-Add $moveDir $forward
    }
    if (Get-Key $moveBackwardKey) {
        $moveDir = Vector3-Subtract $moveDir $forward
    }
    if (Get-Key $moveLeftKey) {
        $moveDir = Vector3-Subtract $moveDir $right
    }
    if (Get-Key $moveRightKey) {
        $moveDir = Vector3-Add $moveDir $right
    }
    if (Get-Key $jumpKey) {
        $moveDir = Vector3-Add $moveDir $worldUp
    }
    if (Get-Key $sprintKey) {
        $moveDir = Vector3-Subtract $moveDir $worldUp
    }

    $moveLen = Vector3-Length $moveDir
    if ($moveLen -gt 0) {
        $moveDir = Vector3-Normalize $moveDir
        $flySpeed = $script:PlayerMoveSpeed * 2.0
        $velocity = Vector3-Multiply $moveDir ($flySpeed * $dt)
        $script:PlayerPosition = Vector3-Add $script:PlayerPosition $velocity
    }

    $script:PlayerVelocity = New-Vector3
    $script:PlayerOnGround = $false
    $script:PlayerState = 'Walking'
}

# ============================================================================
# Get-GroundHeight - Find the Y of the highest solid block beneath the player
# ============================================================================

function Get-GroundHeight {
    <#
    .SYNOPSIS
        Returns the Y coordinate of the top of the highest solid block beneath
        the given X,Z position, scanning downward from player feet.
    #>
    param(
        [float]$X,
        [float]$Z
    )

    [int]$blockX = [Math]::Floor($X)
    [int]$blockZ = [Math]::Floor($Z)

    # Start scanning from a reasonable height (player feet Y + small buffer)
    [int]$startY = [int][Math]::Floor($script:PlayerPosition.Y) + 2
    if ($startY -gt 255) { $startY = 255 }
    if ($startY -lt 0) { $startY = 0 }

    for ($y = $startY; $y -ge 0; $y--) {
        $blockId = Get-WorldBlock -X $blockX -Y $y -Z $blockZ
        if ($blockId -ne [byte]0 -and $blockId -ne [byte]7) {
            # Top of this solid block
            return [float]($y + 1)
        }
    }

    # No ground found - return 0 (bedrock level)
    return [float]0
}

# ============================================================================
# Get-WorldBlock - Query the world for a block at world coordinates
# ============================================================================

function Get-WorldBlock {
    <#
    .SYNOPSIS
        Returns the block ID at the given world coordinates by looking up
        the appropriate chunk in the world hashtable.
    #>
    param(
        [int]$X,
        [int]$Y,
        [int]$Z
    )

    if ($Y -lt 0 -or $Y -gt 255) { return [byte]0 }

    [int]$chunkX = [Math]::Floor($X / 16.0)
    [int]$chunkZ = [Math]::Floor($Z / 16.0)

    $key = "$chunkX,$chunkZ"
    if (-not $script:WorldChunks.ContainsKey($key)) {
        return [byte]0
    }

    $chunk = $script:WorldChunks[$key]

    # Convert world coords to chunk-local coords
    [int]$localX = $X - $chunkX * 16
    [int]$localZ = $Z - $chunkZ * 16

    # Handle negative modulo
    if ($localX -lt 0) { $localX += 16 }
    if ($localZ -lt 0) { $localZ += 16 }

    return (Get-ChunkBlock -Chunk $chunk -X $localX -Y $Y -Z $localZ)
}

# ============================================================================
# Public API
# ============================================================================

function Get-PlayerPosition {
    <#
    .SYNOPSIS
        Returns the player's feet position as a Vector3.
    #>
    return $script:PlayerPosition
}

function Set-PlayerPosition {
    <#
    .SYNOPSIS
        Teleports the player to the given position.
    #>
    param($Position)
    $script:PlayerPosition = $Position
    $script:PlayerVelocity = New-Vector3
    $script:PlayerOnGround = $false
}

function Get-PlayerState {
    <#
    .SYNOPSIS
        Returns the current player state string: Walking, Falling, Jumping, Swimming.
    #>
    return $script:PlayerState
}
