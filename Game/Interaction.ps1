# ============================================================================
# Game/Interaction.ps1 - Block Interaction (Place/Break)
# ============================================================================
# Handles left-click to break blocks and right-click to place blocks using
# the raycast system (Get-LookTarget). Renders a wireframe highlight around
# the currently targeted block. Enforces action cooldowns to prevent spam.
#
# Dependencies: Engine/Raycast.ps1, Engine/Input.ps1, Engine/Shader.ps1,
#   Engine/OpenGL.ps1, World/Chunk.ps1, World/Blocks.ps1, World/World.ps1,
#   Game/Player.ps1, Game/Tools.ps1 (Get-BreakTime, Invoke-DurabilityUse),
#   Game/Equipment.ps1 (Get-EquippedItem)
# ============================================================================

# --- Module State ---
$script:InteractionCooldown      = [float]0.0    # Time remaining before next action
$script:InteractionCooldownTime  = [float]0.25   # Seconds between actions
$script:InteractionLookTarget    = $null          # Current frame's raycast result
$script:InteractionLastBreakBlock = [byte]1       # ID of last broken block (default: stone)
$script:InteractionHighlightVAO  = [uint32]0      # VAO for wireframe highlight
$script:InteractionHighlightVBO  = [uint32]0      # VBO for wireframe highlight
$script:InteractionHighlightReady = $false         # Whether GL resources are created

# ============================================================================
# Initialize-Interaction - Set up state and register callbacks
# ============================================================================

function Initialize-Interaction {
    <#
    .SYNOPSIS
        Initializes the block interaction system and registers callbacks.
    .DESCRIPTION
        Resets cooldown state and registers Update-Interaction (update) and
        Render-BlockHighlight (render) callbacks. Must be called AFTER
        Initialize-Player and Initialize-Physics.
    #>

    $script:InteractionCooldown       = [float]0.0
    $script:InteractionLookTarget     = $null
    $script:InteractionLastBreakBlock  = [byte]1
    $script:InteractionHighlightReady  = $false

    Register-UpdateCallback ${function:Update-Interaction}
    Register-RenderCallback ${function:Render-BlockHighlight}

    Write-Host "[Interaction] Block interaction system initialized." -ForegroundColor Green
}

# ============================================================================
# Update-Interaction - Per-frame update: raycast + mouse input processing
# ============================================================================

function Update-Interaction {
    <#
    .SYNOPSIS
        Per-frame interaction update. Raycasts to find targeted block,
        processes mouse clicks for break/place with cooldown.
    #>
    param($dt)

    # Decrement cooldown
    if ($script:InteractionCooldown -gt 0) {
        $script:InteractionCooldown -= $dt
    }

    # Raycast each frame to find targeted block
    $script:InteractionLookTarget = Get-LookTarget

    # Skip input processing if cooldown active
    if ($script:InteractionCooldown -gt 0) { return }

    $target = $script:InteractionLookTarget
    if ($null -eq $target) { return }

    # --- Left click: break block ---
    if (Get-MouseButtonDown -Button 0) {
        Invoke-BreakBlock -Target $target
        return
    }

    # --- Right click: place block ---
    if (Get-MouseButtonDown -Button 1) {
        Invoke-PlaceBlock -Target $target
        return
    }
}

# ============================================================================
# Invoke-BreakBlock - Remove the targeted block from the world
# ============================================================================

function Invoke-BreakBlock {
    <#
    .SYNOPSIS
        Breaks the block at the raycast target position if it is breakable.
    .PARAMETER Target
        PSCustomObject from Get-LookTarget with BlockX/Y/Z, BlockId, etc.
    #>
    param($Target)

    # Check if block type is breakable
    $blockType = Get-BlockTypeById -Id ([byte]$Target.BlockId)
    if ($null -eq $blockType) { return }
    if (-not $blockType.IsBreakable) { return }

    # Get equipped tool for break time calculation
    $equippedTool = Get-EquippedItem -Slot 'MainHand'

    # Calculate break time based on tool and block type
    [float]$breakTime = Get-BreakTime -BlockName $blockType.Name -ToolName $equippedTool

    # Store the broken block ID for placement default
    $script:InteractionLastBreakBlock = [byte]$Target.BlockId

    # Set block to air
    Set-WorldBlock -X $Target.BlockX -Y $Target.BlockY -Z $Target.BlockZ -BlockId ([byte]0)

    # Drop resources from broken block
    Invoke-BlockDrop -BlockId ([byte]$Target.BlockId)

    # Consume tool durability if a tool is equipped
    if (-not [string]::IsNullOrEmpty($equippedTool)) {
        Invoke-DurabilityUse -ItemName $equippedTool | Out-Null
    }

    # Apply cooldown based on tool break time
    $script:InteractionCooldown = $breakTime

    Write-Host "[Interaction] Broke $($blockType.Name) at ($($Target.BlockX), $($Target.BlockY), $($Target.BlockZ))." -ForegroundColor DarkYellow
}

# ============================================================================
# Invoke-PlaceBlock - Place a block adjacent to the targeted face
# ============================================================================

function Invoke-PlaceBlock {
    <#
    .SYNOPSIS
        Places a block adjacent to the hit face of the targeted block.
    .PARAMETER Target
        PSCustomObject from Get-LookTarget with BlockX/Y/Z, NormalX/Y/Z, etc.
    #>
    param($Target)

    # Compute placement position from hit block + face normal
    [int]$placeX = $Target.BlockX + $Target.NormalX
    [int]$placeY = $Target.BlockY + $Target.NormalY
    [int]$placeZ = $Target.BlockZ + $Target.NormalZ

    # Validate Y range
    if ($placeY -lt 0 -or $placeY -gt 255) { return }

    # Check that the target position is air (not already occupied)
    $existingBlock = Get-WorldBlock -X $placeX -Y $placeY -Z $placeZ
    if ($existingBlock -ne [byte]0) { return }

    # Check player AABB collision - prevent placing blocks inside the player
    if (Test-BlockOverlapsPlayer -BlockX $placeX -BlockY $placeY -BlockZ $placeZ) { return }

    # Determine which block to place (last broken block, default stone)
    [byte]$placeId = $script:InteractionLastBreakBlock
    if ($placeId -eq [byte]0) { $placeId = [byte]1 }  # Fallback to stone

    # Place the block
    Set-WorldBlock -X $placeX -Y $placeY -Z $placeZ -BlockId $placeId

    # Apply cooldown
    $script:InteractionCooldown = $script:InteractionCooldownTime

    $blockType = Get-BlockTypeById -Id $placeId
    $name = if ($null -ne $blockType) { $blockType.Name } else { "Block $placeId" }
    Write-Host "[Interaction] Placed $name at ($placeX, $placeY, $placeZ)." -ForegroundColor DarkCyan
}

# ============================================================================
# Test-BlockOverlapsPlayer - Check if a block position overlaps player AABB
# ============================================================================

function Test-BlockOverlapsPlayer {
    <#
    .SYNOPSIS
        Returns $true if a block at the given world position would overlap
        the player's axis-aligned bounding box.
    #>
    param(
        [int]$BlockX,
        [int]$BlockY,
        [int]$BlockZ
    )

    $pos = $script:PlayerPosition
    [float]$halfW = 0.3   # PlayerWidth / 2
    [float]$halfD = 0.3   # PlayerDepth / 2
    [float]$playerH = 1.8 # PlayerHeight

    # Player AABB bounds
    [float]$pMinX = $pos.X - $halfW
    [float]$pMaxX = $pos.X + $halfW
    [float]$pMinY = $pos.Y
    [float]$pMaxY = $pos.Y + $playerH
    [float]$pMinZ = $pos.Z - $halfD
    [float]$pMaxZ = $pos.Z + $halfD

    # Block AABB: (BlockX, BlockY, BlockZ) to (BlockX+1, BlockY+1, BlockZ+1)
    [float]$bMinX = [float]$BlockX
    [float]$bMaxX = [float]($BlockX + 1)
    [float]$bMinY = [float]$BlockY
    [float]$bMaxY = [float]($BlockY + 1)
    [float]$bMinZ = [float]$BlockZ
    [float]$bMaxZ = [float]($BlockZ + 1)

    # AABB overlap test
    if ($pMaxX -le $bMinX) { return $false }
    if ($pMinX -ge $bMaxX) { return $false }
    if ($pMaxY -le $bMinY) { return $false }
    if ($pMinY -ge $bMaxY) { return $false }
    if ($pMaxZ -le $bMinZ) { return $false }
    if ($pMinZ -ge $bMaxZ) { return $false }

    return $true
}

# ============================================================================
# Set-WorldBlock - Set a block at world coordinates and rebuild chunk mesh
# ============================================================================

function Set-WorldBlock {
    <#
    .SYNOPSIS
        Sets a block ID at the given world coordinates, modifies the chunk
        data, and rebuilds the affected chunk mesh.
    .PARAMETER X
        World X coordinate.
    .PARAMETER Y
        World Y coordinate (0-255).
    .PARAMETER Z
        World Z coordinate.
    .PARAMETER BlockId
        Byte block ID to set.
    #>
    param(
        [int]$X,
        [int]$Y,
        [int]$Z,
        [byte]$BlockId
    )

    if ($Y -lt 0 -or $Y -gt 255) { return }

    # Convert world coords to chunk coords
    [int]$chunkX = [Math]::Floor($X / 16.0)
    [int]$chunkZ = [Math]::Floor($Z / 16.0)

    $key = "$chunkX,$chunkZ"
    if (-not $script:WorldChunks.ContainsKey($key)) { return }

    $chunk = $script:WorldChunks[$key]

    # Convert world coords to chunk-local coords
    [int]$localX = $X - $chunkX * 16
    [int]$localZ = $Z - $chunkZ * 16

    # Handle negative modulo
    if ($localX -lt 0) { $localX += 16 }
    if ($localZ -lt 0) { $localZ += 16 }

    # Set the block in the chunk data
    Set-ChunkBlock -Chunk $chunk -X $localX -Y $Y -Z $localZ -BlockId $BlockId

    # Rebuild the chunk mesh to reflect the change
    Build-ChunkMesh -Chunk $chunk

    # If the block is at a chunk boundary, also rebuild the neighbor chunk
    # so its face culling is updated correctly
    if ($localX -eq 0) {
        $neighborKey = "$($chunkX - 1),$chunkZ"
        if ($script:WorldChunks.ContainsKey($neighborKey)) {
            Build-ChunkMesh -Chunk $script:WorldChunks[$neighborKey]
        }
    }
    if ($localX -eq 15) {
        $neighborKey = "$($chunkX + 1),$chunkZ"
        if ($script:WorldChunks.ContainsKey($neighborKey)) {
            Build-ChunkMesh -Chunk $script:WorldChunks[$neighborKey]
        }
    }
    if ($localZ -eq 0) {
        $neighborKey = "$chunkX,$($chunkZ - 1)"
        if ($script:WorldChunks.ContainsKey($neighborKey)) {
            Build-ChunkMesh -Chunk $script:WorldChunks[$neighborKey]
        }
    }
    if ($localZ -eq 15) {
        $neighborKey = "$chunkX,$($chunkZ + 1)"
        if ($script:WorldChunks.ContainsKey($neighborKey)) {
            Build-ChunkMesh -Chunk $script:WorldChunks[$neighborKey]
        }
    }
}

# ============================================================================
# Initialize-HighlightMesh - Create GPU resources for wireframe cube
# ============================================================================

function Initialize-HighlightMesh {
    <#
    .SYNOPSIS
        Creates a VAO/VBO for the wireframe highlight cube (12 edges = 24 verts).
    .DESCRIPTION
        Uses the same vertex format as the default shader (pos3+tex2+norm3).
        Vertex data is updated each frame via BufferData. Called lazily on
        first render when GL context is available.
    #>

    # Generate VAO
    [uint32[]]$vaoIds = @([uint32]0)
    [OpenGL.Gl]::GenVertexArrays($vaoIds)
    $script:InteractionHighlightVAO = $vaoIds[0]
    [OpenGL.Gl]::BindVertexArray($script:InteractionHighlightVAO)

    # Generate VBO
    [uint32[]]$vboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($vboIds)
    $script:InteractionHighlightVBO = $vboIds[0]
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $script:InteractionHighlightVBO)

    # Set up vertex attribute pointers (same layout as default shader)
    $program = Get-DefaultShaderProgram
    [int]$stride = 32  # 8 floats * 4 bytes

    # aPosition (vec3) - offset 0
    $posLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aPosition')
    if ($posLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$posLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$posLoc, 3,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(0)
        )
    }

    # aTexCoord (vec2) - offset 12
    $texLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aTexCoord')
    if ($texLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$texLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$texLoc, 2,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(12)
        )
    }

    # aNormal (vec3) - offset 20
    $normLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aNormal')
    if ($normLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$normLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$normLoc, 3,
            [OpenGL.VertexAttribType]::Float, $false,
            $stride, [IntPtr]::new(20)
        )
    }

    # Unbind
    [OpenGL.Gl]::BindVertexArray([uint32]0)

    $script:InteractionHighlightReady = $true
    Write-Host "[Interaction] Highlight mesh resources created (VAO: $($script:InteractionHighlightVAO))." -ForegroundColor DarkGray
}

# ============================================================================
# Render-BlockHighlight - Draw wireframe cube around targeted block
# ============================================================================

function Render-BlockHighlight {
    <#
    .SYNOPSIS
        Renders a wireframe cube overlay on the currently targeted block.
    .DESCRIPTION
        Called each frame via render callback. Uses GL lines with the default
        shader. Slightly expands the cube (0.002 units) to prevent z-fighting.
    #>
    param($dt)

    $target = $script:InteractionLookTarget
    if ($null -eq $target) { return }

    # Lazy-init GPU resources
    if (-not $script:InteractionHighlightReady) {
        Initialize-HighlightMesh
    }

    # Build wireframe vertex data for a unit cube at block position
    # Slight expansion to avoid z-fighting with block faces
    [float]$e = [float]0.002  # Expansion amount
    [float]$x0 = [float]$target.BlockX - $e
    [float]$y0 = [float]$target.BlockY - $e
    [float]$z0 = [float]$target.BlockZ - $e
    [float]$x1 = [float]($target.BlockX + 1) + $e
    [float]$y1 = [float]($target.BlockY + 1) + $e
    [float]$z1 = [float]($target.BlockZ + 1) + $e

    # 8 corners of the cube
    # Each vertex: pos(3) + texcoord(2) + normal(3) = 8 floats
    # We use texcoord (0,0) and normal (0,0,0) since we just need position for lines
    # 12 edges * 2 vertices per edge = 24 vertices * 8 floats = 192 floats

    [float[]]$verts = [float[]]::new(192)
    [int]$vi = 0

    # Helper: add a line segment (2 vertices)
    # Edge format: startXYZ -> endXYZ

    # --- Bottom face edges (y=y0) ---
    # Edge 0: (x0,y0,z0) -> (x1,y0,z0)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 1: (x1,y0,z0) -> (x1,y0,z1)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 2: (x1,y0,z1) -> (x0,y0,z1)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 3: (x0,y0,z1) -> (x0,y0,z0)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # --- Top face edges (y=y1) ---
    # Edge 4: (x0,y1,z0) -> (x1,y1,z0)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 5: (x1,y1,z0) -> (x1,y1,z1)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 6: (x1,y1,z1) -> (x0,y1,z1)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 7: (x0,y1,z1) -> (x0,y1,z0)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # --- Vertical edges (connecting top and bottom) ---
    # Edge 8: (x0,y0,z0) -> (x0,y1,z0)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 9: (x1,y0,z0) -> (x1,y1,z0)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 10: (x1,y0,z1) -> (x1,y1,z1)
    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x1; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # Edge 11: (x0,y0,z1) -> (x0,y1,z1)
    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y0; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    $verts[$vi] = $x0; $vi++; $verts[$vi] = $y1; $vi++; $verts[$vi] = $z1; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++
    $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++; $verts[$vi] = [float]0; $vi++

    # --- Upload vertex data and draw ---
    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program

    # Set model matrix to identity (wireframe is in world space)
    $model = Matrix4-Identity
    Set-ShaderUniformMatrix4 -Program $program -Name 'uModel' -Matrix $model

    # Set lighting to full bright so highlight is clearly visible
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value ([float]1.0)
    Set-ShaderUniform3f -Program $program -Name 'uLightDir' -X ([float]0) -Y ([float]1) -Z ([float]0)

    # Bind VAO and upload data
    [OpenGL.Gl]::BindVertexArray($script:InteractionHighlightVAO)
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $script:InteractionHighlightVBO)

    [uint32]$byteSize = [uint32]($verts.Length * 4)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ArrayBuffer,
        $byteSize,
        $verts,
        [OpenGL.BufferUsage]::DynamicDraw
    )

    # Disable depth test to draw highlight on top
    [OpenGL.Gl]::Disable([OpenGL.EnableCap]::DepthTest)

    # Draw the 12 edges (24 vertices) as lines
    [OpenGL.Gl]::DrawArrays([OpenGL.PrimitiveType]::Lines, 0, 24)

    # Re-enable depth test
    [OpenGL.Gl]::Enable([OpenGL.EnableCap]::DepthTest)

    # Unbind
    [OpenGL.Gl]::BindVertexArray([uint32]0)

    # Restore ambient for subsequent rendering (world render sets this anyway)
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value ([float]0.3)
}
