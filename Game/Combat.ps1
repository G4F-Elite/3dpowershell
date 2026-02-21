# ============================================================================
# Game/Combat.ps1 - Combat System Core
# ============================================================================
# Manages combat entities (enemies), player attack mechanics with cooldown,
# melee hit detection, damage calculation integrating weapon/player stats,
# enemy AI attack triggers, and a player combat state machine.
# Renders enemies as colored cubes at their world positions.
#
# Dependencies: Engine/Math.ps1 (Vector3, Matrix4),
#               Engine/Input.ps1 (Get-KeyDown, Get-MouseButton),
#               Engine/Shader.ps1 (shader uniforms),
#               Engine/Mesh.ps1 (New-CubeMesh, Draw-Mesh),
#               Engine/Camera.ps1 (Get-ViewMatrix),
#               Engine/OpenGL.ps1 (Register-UpdateCallback, Register-RenderCallback),
#               Game/Player.ps1 ($script:PlayerPosition),
#               Game/Stats.ps1 (Add-PlayerHP, Get-PlayerStats),
#               Game/Equipment.ps1 (Get-EquippedItem, Get-EquipmentStats),
#               Game/Tools.ps1 (Get-WeaponDamage),
#               Data/Items.ps1 (Get-ItemDefinition)
# ============================================================================

# --- Module State ---
$script:CombatEntities             = @()              # [PSCustomObject[]] All combat entities
$script:PlayerCombatState          = [string]'idle'    # 'idle', 'attacking', 'cooldown', 'blocking'
$script:PlayerAttackTimer          = [float]0.0        # Time remaining in current attack state
$script:PlayerAttackCooldownMax    = [float]0.625      # Default cooldown (1.0 / 1.6)
$script:PlayerAttackRange          = [float]2.5        # Melee reach in blocks
$script:PlayerAttackSwingTime      = [float]0.3        # Attack animation duration
$script:PlayerCurrentTarget        = $null             # Current nearest target in melee range
$script:PlayerBlockDamageReduction = [float]0.5        # Percent of damage reduced while blocking
$script:PlayerAnimationProxy       = $null             # Optional animation target for player attack
$script:CombatEnemyMesh            = $null             # Shared cube mesh for enemy rendering
$script:CombatRendererReady        = $false            # Lazy-init flag for GL resources

# ============================================================================
# Initialize-Combat - Reset state and register callbacks
# ============================================================================

function Initialize-Combat {
    <#
    .SYNOPSIS
        Initializes the combat system, resets all state, registers update
        and render callbacks. Must be called AFTER Initialize-Tools.
    #>

    $script:CombatEntities             = @()
    $script:PlayerCombatState          = 'idle'
    $script:PlayerAttackTimer          = [float]0.0
    $script:PlayerAttackCooldownMax    = [float]0.625
    $script:PlayerAttackRange          = [float]2.5
    $script:PlayerAttackSwingTime      = [float]0.3
    $script:PlayerCurrentTarget        = $null
    $script:PlayerBlockDamageReduction = [float]0.5
    $script:PlayerAnimationProxy       = $null
    $script:CombatEnemyMesh            = $null
    $script:CombatRendererReady        = $false

    Register-UpdateCallback ${function:Update-Combat}
    Register-RenderCallback ${function:Render-CombatEntities}

    Write-Host "[Combat] Combat system initialized." -ForegroundColor Green
}

# ============================================================================
# Combat Entity Management
# ============================================================================

function New-CombatEntity {
    <#
    .SYNOPSIS
        Creates a new combat entity PSCustomObject with all required stats.
    .PARAMETER Name
        Display name for the entity.
    .PARAMETER HP
        Maximum and initial hit points.
    .PARAMETER Damage
        Base damage per attack.
    .PARAMETER Defense
        Damage reduction value.
    .PARAMETER Position
        World position as PSCustomObject with X, Y, Z.
    .PARAMETER AttackRange
        Distance at which entity can attack (default 2.0).
    .PARAMETER DetectRange
        Distance at which entity detects the player (default 10.0).
    .PARAMETER AttackCooldownMax
        Seconds between attacks (default 1.5).
    .OUTPUTS
        PSCustomObject combat entity.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [float]$HP,

        [int]$Damage = 3,
        [int]$Defense = 0,
        $Position = $null,
        [float]$AttackRange = 2.0,
        [float]$DetectRange = 10.0,
        [float]$AttackCooldownMax = 1.5
    )

    if ($null -eq $Position) {
        $Position = New-Vector3
    }

    return [PSCustomObject]@{
        Name              = [string]$Name
        HP                = [float]$HP
        MaxHP             = [float]$HP
        Damage            = [int]$Damage
        Defense           = [int]$Defense
        Position          = $Position
        AttackRange       = [float]$AttackRange
        DetectRange       = [float]$DetectRange
        AttackCooldownMax = [float]$AttackCooldownMax
        AttackCooldown    = [float]0.0
        State             = [string]'idle'
        IsAlive           = [bool]$true
    }
}

function Add-CombatEntity {
    <#
    .SYNOPSIS
        Adds a combat entity to the global entity list. Max 10 entities.
    .PARAMETER Entity
        PSCustomObject from New-CombatEntity.
    .OUTPUTS
        $true if added, $false if at capacity.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Entity
    )

    if ($script:CombatEntities.Count -ge 10) {
        Write-Host "[Combat] Cannot add entity - max 10 reached." -ForegroundColor Red
        return $false
    }

    $script:CombatEntities += $Entity
    Write-Host "[Combat] Added entity: $($Entity.Name) at ($($Entity.Position.X), $($Entity.Position.Y), $($Entity.Position.Z))." -ForegroundColor Cyan
    return $true
}

function Remove-CombatEntity {
    <#
    .SYNOPSIS
        Removes a combat entity from the global entity list by reference.
    .PARAMETER Entity
        The entity object to remove.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Entity
    )

    $newList = @()
    foreach ($e in $script:CombatEntities) {
        if (-not [object]::ReferenceEquals($e, $Entity)) {
            $newList += $e
        }
    }
    $script:CombatEntities = $newList
}

function Get-CombatEntities {
    <#
    .SYNOPSIS
        Returns the array of all active combat entities.
    .OUTPUTS
        Array of PSCustomObject combat entities.
    #>

    return ,$script:CombatEntities
}

# ============================================================================
# Proximity Queries
# ============================================================================

function Get-NearbyEnemies {
    <#
    .SYNOPSIS
        Returns all alive combat entities within the specified range of the player.
    .PARAMETER Range
        Maximum distance from the player position.
    .OUTPUTS
        Array of PSCustomObject combat entities within range.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [float]$Range
    )

    $playerPos = $script:PlayerPosition
    $results = @()

    foreach ($entity in $script:CombatEntities) {
        if (-not $entity.IsAlive) { continue }

        [float]$dx = $entity.Position.X - $playerPos.X
        [float]$dy = $entity.Position.Y - $playerPos.Y
        [float]$dz = $entity.Position.Z - $playerPos.Z
        [float]$dist = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)

        if ($dist -le $Range) {
            $results += $entity
        }
    }

    return ,$results
}

function Get-NearestCombatTarget {
    <#
    .SYNOPSIS
        Returns the nearest alive combat target in range of the player.
    .PARAMETER Range
        Max distance from player to consider a target valid.
    .OUTPUTS
        Combat entity object, or $null when none are in range.
    #>
    param(
        [float]$Range = [float]$script:PlayerAttackRange
    )

    $playerPos = $script:PlayerPosition
    if ($null -eq $playerPos) {
        return $null
    }

    $nearestEnemy = $null
    [float]$nearestDist = [float]999999.0

    foreach ($entity in $script:CombatEntities) {
        if ($null -eq $entity -or -not $entity.IsAlive) { continue }

        [float]$dx = $entity.Position.X - $playerPos.X
        [float]$dy = $entity.Position.Y - $playerPos.Y
        [float]$dz = $entity.Position.Z - $playerPos.Z
        [float]$dist = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)

        if ($dist -le $Range -and $dist -lt $nearestDist) {
            $nearestDist = $dist
            $nearestEnemy = $entity
        }
    }

    return $nearestEnemy
}

function Test-MeleeHit {
    <#
    .SYNOPSIS
        Returns $true when a target is alive and inside melee range.
    .PARAMETER Target
        Target combat entity.
    .PARAMETER Range
        Optional melee range override.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Target,

        [float]$Range = [float]$script:PlayerAttackRange
    )

    if ($null -eq $Target -or -not $Target.IsAlive) { return $false }

    $playerPos = $script:PlayerPosition
    if ($null -eq $playerPos) { return $false }

    [float]$dx = $Target.Position.X - $playerPos.X
    [float]$dy = $Target.Position.Y - $playerPos.Y
    [float]$dz = $Target.Position.Z - $playerPos.Z
    [float]$dist = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)

    return ($dist -le $Range)
}

function Get-CurrentCombatTarget {
    <#
    .SYNOPSIS
        Returns the currently selected melee target for the player.
    #>
    return $script:PlayerCurrentTarget
}

function Get-PlayerAttackDamage {
    <#
    .SYNOPSIS
        Computes player melee base damage from weapon plus available stats.
    .DESCRIPTION
        Keeps Task 25 scope simple:
        - Weapon damage from Get-WeaponDamage
        - Optional Strength bonus if PlayerStats exposes Strength
        - Optional equipment bonus if TotalDamage exceeds weapon damage
    #>
    param(
        [string]$WeaponName
    )

    [int]$weaponDamage = Get-WeaponDamage -WeaponName $WeaponName
    [int]$strengthBonus = 0
    [int]$equipmentBonus = 0

    $stats = Get-PlayerStats
    if ($null -ne $stats -and $null -ne $stats.PSObject.Properties['Strength']) {
        [int]$strengthRaw = [int][Math]::Floor([double]$stats.Strength)
        if ($strengthRaw -gt 0) {
            $strengthBonus = $strengthRaw
        }
    }

    $equipStats = Get-EquipmentStats
    if ($null -ne $equipStats -and $null -ne $equipStats.PSObject.Properties['TotalDamage']) {
        [int]$equipTotalDamage = [int]$equipStats.TotalDamage
        if ($equipTotalDamage -gt $weaponDamage) {
            $equipmentBonus = [int]($equipTotalDamage - $weaponDamage)
        }
    }

    return [int][Math]::Max(1, $weaponDamage + $strengthBonus + $equipmentBonus)
}

function Invoke-PlayerAttackAnimation {
    <#
    .SYNOPSIS
        Triggers optional player attack animation playback if available.
    #>

    if (-not (Get-Command -Name Play-EntityAnimation -ErrorAction SilentlyContinue)) {
        return
    }

    if ($null -eq $script:PlayerAnimationProxy) {
        $script:PlayerAnimationProxy = [PSCustomObject]@{
            Name = 'Player'
        }
    }

    if (Get-Command -Name Set-EntityCombatAnimationTiming -ErrorAction SilentlyContinue) {
        Set-EntityCombatAnimationTiming -Entity $script:PlayerAnimationProxy -AttackDuration $script:PlayerAttackSwingTime | Out-Null
    }

    if (Get-Command -Name Play-EntityAttackAnimation -ErrorAction SilentlyContinue) {
        Play-EntityAttackAnimation -Entity $script:PlayerAnimationProxy -ForceRestart | Out-Null
        return
    }

    Play-EntityAnimation -Entity $script:PlayerAnimationProxy -State 'Attack' -ForceRestart | Out-Null
}

# ============================================================================
# Player Combat State
# ============================================================================

function Get-CombatState {
    <#
    .SYNOPSIS
        Returns current player combat state: idle, attacking, cooldown, blocking.
    .OUTPUTS
        String combat state.
    #>

    return $script:PlayerCombatState
}

# ============================================================================
# Player Attack
# ============================================================================

function Invoke-PlayerAttack {
    <#
    .SYNOPSIS
        Player attacks the nearest enemy in melee range using equipped weapon.
    .DESCRIPTION
        1. Checks player is not currently attacking/cooling down
        2. Finds nearest alive enemy within AttackRange
        3. Gets base damage from weapon + available player stats
        4. Applies damage formula: max(1, baseDamage - enemyDefense)
        5. Sets player state to 'attacking' for swing duration
        6. Computes cooldown from weapon AttackSpeed
    .OUTPUTS
        $true if attack landed, $false if no target or on cooldown.
    #>

    # Attack cannot start while already attacking or cooling down
    if ($script:PlayerCombatState -eq 'attacking' -or $script:PlayerCombatState -eq 'cooldown') {
        return $false
    }

    # Leaving block state to perform an attack is allowed
    if ($script:PlayerCombatState -eq 'blocking') {
        $script:PlayerCombatState = 'idle'
    }

    # Check if player is alive
    $stats = Get-PlayerStats
    if ($null -eq $stats -or -not $stats.IsAlive) {
        return $false
    }

    # Find nearest enemy within attack range
    $nearestEnemy = Get-NearestCombatTarget -Range $script:PlayerAttackRange
    $script:PlayerCurrentTarget = $nearestEnemy

    # Get weapon damage
    $weaponName = Get-EquippedItem -Slot 'MainHand'
    [int]$weaponDamage = Get-WeaponDamage -WeaponName $weaponName

    # Compute attack cooldown from weapon AttackSpeed
    [float]$attackSpeed = [float]1.6  # default
    if (-not [string]::IsNullOrEmpty($weaponName)) {
        $itemDef = Get-ItemDefinition -Name $weaponName
        if ($null -ne $itemDef -and $null -ne $itemDef.AttackSpeed -and $itemDef.AttackSpeed -gt 0) {
            $attackSpeed = [float]$itemDef.AttackSpeed
        }
    }
    $script:PlayerAttackCooldownMax = [float](1.0 / $attackSpeed)

    # Set attacking state (swing animation)
    $script:PlayerCombatState = 'attacking'
    $script:PlayerAttackTimer = $script:PlayerAttackSwingTime

    # Trigger optional animation module integration
    Invoke-PlayerAttackAnimation

    # Consume weapon durability
    if (-not [string]::IsNullOrEmpty($weaponName)) {
        Invoke-DurabilityUse -ItemName $weaponName | Out-Null
    }

    # Apply damage only if we have a valid in-range target
    if ($null -ne $nearestEnemy -and (Test-MeleeHit -Target $nearestEnemy -Range $script:PlayerAttackRange)) {
        [int]$baseDamage = Get-PlayerAttackDamage -WeaponName $weaponName
        [int]$finalDamage = [Math]::Max(1, $baseDamage - $nearestEnemy.Defense)
        $nearestEnemy.HP = [Math]::Max(0, $nearestEnemy.HP - $finalDamage)

        if ($nearestEnemy.HP -le 0) {
            $nearestEnemy.IsAlive = $false
            $nearestEnemy.State = 'dead'

            if (Get-Command -Name Play-EntityDeathAnimation -ErrorAction SilentlyContinue) {
                Play-EntityDeathAnimation -Entity $nearestEnemy -ForceRestart | Out-Null
            }
            elseif (Get-Command -Name Play-EntityAnimation -ErrorAction SilentlyContinue) {
                Play-EntityAnimation -Entity $nearestEnemy -State 'Death' -ForceRestart | Out-Null
            }

            Write-Host "[Combat] $($nearestEnemy.Name) defeated! (Damage: $finalDamage)" -ForegroundColor Yellow
        } else {
            if (Get-Command -Name Play-EntityHitReactionAnimation -ErrorAction SilentlyContinue) {
                Play-EntityHitReactionAnimation -Entity $nearestEnemy -ForceRestart | Out-Null
            }
            elseif (Get-Command -Name Play-EntityAnimation -ErrorAction SilentlyContinue) {
                Play-EntityAnimation -Entity $nearestEnemy -State 'HitReaction' -ForceRestart | Out-Null
            }

            Write-Host "[Combat] Hit $($nearestEnemy.Name) for $finalDamage damage ($([int]$nearestEnemy.HP)/$([int]$nearestEnemy.MaxHP) HP)." -ForegroundColor DarkYellow
        }

        return $true
    }

    # Attack animation plays even if no target hit (whiff)
    return $false
}

# ============================================================================
# Entity Attack (Generic)
# ============================================================================

function Invoke-EntityAttack {
    <#
    .SYNOPSIS
        An entity attacks a target, applying damage and resetting cooldown.
    .PARAMETER Attacker
        The attacking combat entity.
    .PARAMETER TargetIsPlayer
        If $true, damage is applied to the player via Add-PlayerHP.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Attacker,

        [bool]$TargetIsPlayer = $true
    )

    if (-not $Attacker.IsAlive) { return }

    [int]$baseDamage = $Attacker.Damage

    if ($TargetIsPlayer) {
        # Get player armor defense
        $equipStats = Get-EquipmentStats
        [int]$playerDefense = $equipStats.TotalDefense

        [int]$finalDamage = [Math]::Max(1, $baseDamage - $playerDefense)

        if ($script:PlayerCombatState -eq 'blocking') {
            [float]$remainingFactor = [float](1.0 - $script:PlayerBlockDamageReduction)
            [int]$blockedDamage = [int][Math]::Floor($finalDamage * $remainingFactor)
            if ($blockedDamage -lt 0) {
                $blockedDamage = [int]0
            }

            [int]$mitigated = [int]($finalDamage - $blockedDamage)

            if ($blockedDamage -gt 0) {
                Add-PlayerHP -Delta (-$blockedDamage)
                Write-Host "[Combat] $($Attacker.Name) hit player for $blockedDamage damage (blocked $mitigated)." -ForegroundColor Red
            }
            else {
                Write-Host "[Combat] Player blocked all damage from $($Attacker.Name)!" -ForegroundColor Cyan
            }
        }
        else {
            Add-PlayerHP -Delta (-$finalDamage)
            Write-Host "[Combat] $($Attacker.Name) hit player for $finalDamage damage!" -ForegroundColor Red
        }
    }

    # Reset attacker cooldown
    $Attacker.AttackCooldown = $Attacker.AttackCooldownMax
}

# ============================================================================
# Update-Combat - Per-frame combat update
# ============================================================================

function Update-Combat {
    <#
    .SYNOPSIS
        Per-frame update: processes player combat state timer, enemy attack
        cooldowns, enemy AI (detect/chase/attack), and dead entity cleanup.
    #>
    param($dt)

    if ($dt -gt 0.1) { $dt = 0.1 }

    # --- Update player combat state machine ---
    if ($script:PlayerCombatState -eq 'attacking') {
        $script:PlayerAttackTimer -= $dt
        if ($script:PlayerAttackTimer -le 0) {
            # Transition to cooldown
            $script:PlayerCombatState = 'cooldown'
            $script:PlayerAttackTimer = $script:PlayerAttackCooldownMax
        }
    }
    elseif ($script:PlayerCombatState -eq 'cooldown') {
        $script:PlayerAttackTimer -= $dt
        if ($script:PlayerAttackTimer -le 0) {
            # Back to idle
            $script:PlayerCombatState = 'idle'
            $script:PlayerAttackTimer = [float]0.0
        }
    }
    elseif ($script:PlayerCombatState -eq 'blocking') {
        if (-not (Get-MouseButton -Button 1)) {
            $script:PlayerCombatState = 'idle'
            $script:PlayerAttackTimer = [float]0.0
        }
    }

    # --- Player attack input: F key triggers melee attack ---
    if (Get-KeyDown ([System.Windows.Forms.Keys]::F)) {
        Invoke-PlayerAttack | Out-Null
    }

    # --- Player block input: hold right mouse button while idle ---
    if ($script:PlayerCombatState -eq 'idle' -and (Get-MouseButton -Button 1)) {
        $script:PlayerCombatState = 'blocking'
        $script:PlayerAttackTimer = [float]0.0
    }

    # --- Update nearest target selection for melee targeting ---
    $script:PlayerCurrentTarget = Get-NearestCombatTarget -Range $script:PlayerAttackRange

    # --- Update each combat entity (simple AI for non-Enemy.ps1 entities) ---
    $playerPos = $script:PlayerPosition
    $playerStats = Get-PlayerStats

    foreach ($entity in $script:CombatEntities) {
        if (-not $entity.IsAlive) { continue }

        # Skip entities managed by Enemy.ps1 (they have AIState property)
        if ($null -ne $entity.PSObject.Properties['AIState']) { continue }

        # Tick down attack cooldown
        if ($entity.AttackCooldown -gt 0) {
            $entity.AttackCooldown -= $dt
            if ($entity.AttackCooldown -lt 0) {
                $entity.AttackCooldown = [float]0.0
            }
        }

        # Calculate distance to player
        [float]$dx = $playerPos.X - $entity.Position.X
        [float]$dy = $playerPos.Y - $entity.Position.Y
        [float]$dz = $playerPos.Z - $entity.Position.Z
        [float]$dist = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)

        # --- Simple AI state machine (fallback for non-Enemy entities) ---
        if ($null -ne $playerStats -and $playerStats.IsAlive) {
            if ($dist -le $entity.AttackRange) {
                $entity.State = 'attack'
                if ($entity.AttackCooldown -le 0) {
                    Invoke-EntityAttack -Attacker $entity -TargetIsPlayer $true
                }
            }
            elseif ($dist -le $entity.DetectRange) {
                $entity.State = 'chase'
                if ($dist -gt 0.1) {
                    [float]$moveSpeed = [float]2.0
                    [float]$invDist = 1.0 / $dist
                    [float]$moveX = $dx * $invDist * $moveSpeed * $dt
                    [float]$moveY = $dy * $invDist * $moveSpeed * $dt
                    [float]$moveZ = $dz * $invDist * $moveSpeed * $dt
                    $entity.Position = [PSCustomObject]@{
                        X = $entity.Position.X + $moveX
                        Y = $entity.Position.Y + $moveY
                        Z = $entity.Position.Z + $moveZ
                    }
                }
            }
            else {
                $entity.State = 'idle'
            }
        }
        else {
            $entity.State = 'idle'
        }
    }
}

# ============================================================================
# Render-CombatEntities - Draw enemies as colored cubes
# ============================================================================

function Render-CombatEntities {
    <#
    .SYNOPSIS
        Render callback that draws all alive combat entities as colored cubes
        at their world positions using the default shader.
    .PARAMETER dt
        Delta time in seconds (from game loop).
    #>
    param($dt)

    # Skip if no entities
    if ($script:CombatEntities.Count -eq 0) { return }

    # Check if any alive entities exist
    $hasAlive = $false
    foreach ($e in $script:CombatEntities) {
        if ($e.IsAlive) { $hasAlive = $true; break }
    }
    if (-not $hasAlive) { return }

    # Lazy-init the enemy mesh on first render (GL context required)
    if (-not $script:CombatRendererReady) {
        $script:CombatEnemyMesh = New-CubeMesh -BlockType 'stone'
        $script:CombatRendererReady = $true
        Write-Host "[Combat] Enemy mesh created for rendering." -ForegroundColor DarkGray
    }

    if ($null -eq $script:CombatEnemyMesh) { return }

    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program

    # --- Projection matrix (match World.ps1 pattern) ---
    $glCtrl = Get-GlControl
    [float]$width  = [float]$glCtrl.Width
    [float]$height = [float]$glCtrl.Height
    if ($height -lt 1) { $height = 1 }
    [float]$aspect = $width / $height
    [float]$fovRad = [float]([Math]::PI / 3.0)
    $proj = Matrix4-Perspective -FovRadians $fovRad -Aspect $aspect -Near 0.1 -Far 500.0

    # --- View matrix from camera ---
    $view = Get-ViewMatrix

    # --- Set shared uniforms ---
    Set-ShaderUniformMatrix4 -Program $program -Name 'uProjection' -Matrix $proj
    Set-ShaderUniformMatrix4 -Program $program -Name 'uView'       -Matrix $view

    # Lighting - high ambient so enemies are clearly visible with red tint
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value 0.9
    Set-ShaderUniform3f -Program $program -Name 'uLightDir' -X 0.3 -Y 0.8 -Z 0.5

    # Bind texture atlas
    $atlas = Get-BlockTextureAtlas
    Bind-Texture -Handle $atlas.Handle -Unit 0
    Set-ShaderUniform1i -Program $program -Name 'uTexture' -Value 0

    # --- Draw each alive entity ---
    foreach ($entity in $script:CombatEntities) {
        if (-not $entity.IsAlive) { continue }

        # Model matrix: translate to entity position, offset Y by 0.5 so cube sits on ground
        $model = Matrix4-Translation `
            -X $entity.Position.X `
            -Y ($entity.Position.Y + 0.5) `
            -Z $entity.Position.Z

        Set-ShaderUniformMatrix4 -Program $program -Name 'uModel' -Matrix $model

        Draw-Mesh -Mesh $script:CombatEnemyMesh
    }

    # Restore ambient for subsequent renderers
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value 0.3
}
