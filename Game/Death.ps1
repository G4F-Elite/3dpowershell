# ============================================================================
# Game/Death.ps1 - Death, Respawn, and Enemy Death Primitives
# ============================================================================
# Handles:
# - Player death detection (HP <= 0)
# - Timed player respawn at configured spawn position
# - Optional, safe death penalties (placeholder-friendly)
# - Enemy death loot descriptor generation
# - Enemy respawn queue and timer processing
#
# Dependencies (optional but used when available):
# - Engine/OpenGL.ps1: Register-UpdateCallback
# - Game/Stats.ps1: Get-PlayerStats, Set-PlayerHP
# - Game/Player.ps1: Get-PlayerPosition, Set-PlayerPosition
# ============================================================================

# --- Module State ---
$script:DeathSystem = $null
$script:EnemyRespawnQueue = [System.Collections.ArrayList]::new()
$script:DeathUpdateRegistered = $false

# ============================================================================
# Internal Helpers
# ============================================================================

function Copy-DeathVector3 {
    param($Vector)

    if ($null -eq $Vector) {
        return [PSCustomObject]@{
            X = [float]0.0
            Y = [float]70.0
            Z = [float]0.0
        }
    }

    [float]$x = [float]0.0
    [float]$y = [float]70.0
    [float]$z = [float]0.0

    if ($null -ne $Vector.PSObject.Properties['X']) { $x = [float]$Vector.X }
    if ($null -ne $Vector.PSObject.Properties['Y']) { $y = [float]$Vector.Y }
    if ($null -ne $Vector.PSObject.Properties['Z']) { $z = [float]$Vector.Z }

    return [PSCustomObject]@{
        X = $x
        Y = $y
        Z = $z
    }
}

function Set-DeathObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Value
    )

    if ($null -eq $Object) { return }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    } else {
        $Object.$Name = $Value
    }
}

function Get-DeathPlayerStats {
    $getStatsCmd = Get-Command -Name Get-PlayerStats -ErrorAction SilentlyContinue
    if ($null -ne $getStatsCmd) {
        return Get-PlayerStats
    }

    $statsVar = Get-Variable -Name PlayerStats -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $statsVar) {
        return $script:PlayerStats
    }

    return $null
}

function Get-DeathPlayerPosition {
    $getPositionCmd = Get-Command -Name Get-PlayerPosition -ErrorAction SilentlyContinue
    if ($null -ne $getPositionCmd) {
        return (Copy-DeathVector3 -Vector (Get-PlayerPosition))
    }

    $playerPosVar = Get-Variable -Name PlayerPosition -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $playerPosVar) {
        return (Copy-DeathVector3 -Vector $script:PlayerPosition)
    }

    return (Copy-DeathVector3 -Vector $null)
}

function Set-DeathPlayerPosition {
    param(
        [Parameter(Mandatory = $true)]
        $Position
    )

    $safePosition = Copy-DeathVector3 -Vector $Position

    $setPositionCmd = Get-Command -Name Set-PlayerPosition -ErrorAction SilentlyContinue
    if ($null -ne $setPositionCmd) {
        Set-PlayerPosition -Position $safePosition
        return
    }

    $playerPosVar = Get-Variable -Name PlayerPosition -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $playerPosVar) {
        $script:PlayerPosition = $safePosition
    }
}

function Get-DeathHPValue {
    param($Stats)

    if ($null -eq $Stats) { return [float]0.0 }
    if ($null -eq $Stats.PSObject.Properties['HP']) { return [float]0.0 }
    return [float]$Stats.HP
}

function Get-DeathMaxHPValue {
    param($Stats)

    if ($null -eq $Stats) { return [float]100.0 }
    if ($null -eq $Stats.PSObject.Properties['MaxHP']) { return [float]100.0 }
    return [float]$Stats.MaxHP
}

# ============================================================================
# Initialize-DeathSystem - Reset state and register update callback
# ============================================================================

function Initialize-DeathSystem {
    <#
    .SYNOPSIS
        Initializes death system state and registers Update-DeathSystem callback.
    .DESCRIPTION
        Creates script-scope death state, sets the spawn position to the current
        player position if available, and enables timed respawn behavior.
    #>

    $spawnPosition = Get-DeathPlayerPosition

    $script:DeathSystem = [PSCustomObject]@{
        IsInitialized         = $true
        IsPlayerDead          = $false
        DeathCount            = [int]0
        RespawnDelaySeconds   = [float]5.0
        RespawnTimerRemaining = [float]0.0
        RespawnHPPercent      = [float]1.0
        SpawnPosition         = (Copy-DeathVector3 -Vector $spawnPosition)
        PenaltyConfig         = [PSCustomObject]@{
            EnableItemPenalty = [bool]$false
            EnableXPPenalty   = [bool]$false
            XPPercentLoss     = [float]0.0
        }
        LastPenalty           = $null
        LastEnemyLoot         = $null
    }

    $script:EnemyRespawnQueue = [System.Collections.ArrayList]::new()

    if (-not $script:DeathUpdateRegistered) {
        $registerCmd = Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue
        if ($null -ne $registerCmd) {
            Register-UpdateCallback ${function:Update-DeathSystem}
            $script:DeathUpdateRegistered = $true
            Write-Host "[Death] Update callback registered." -ForegroundColor DarkGray
        } else {
            Write-Host "[Death] Register-UpdateCallback not found. Manual Update-DeathSystem calls required." -ForegroundColor DarkYellow
        }
    }

    Write-Host "[Death] Death system initialized (respawn delay: $($script:DeathSystem.RespawnDelaySeconds)s)." -ForegroundColor Green
}

# ============================================================================
# Update-DeathSystem - Per-frame death and respawn processing
# ============================================================================

function Update-DeathSystem {
    <#
    .SYNOPSIS
        Per-frame update. Detects player death, handles respawn timer, and
        processes enemy respawn queue timers.
    #>
    param($dt)

    if ($null -eq $script:DeathSystem -or -not $script:DeathSystem.IsInitialized) { return }

    [float]$delta = [float]0.0
    if ($null -ne $dt) {
        $delta = [float]$dt
    }
    if ($delta -lt 0) { $delta = [float]0.0 }
    if ($delta -gt 0.25) { $delta = [float]0.25 }

    $stats = Get-DeathPlayerStats

    if (-not $script:DeathSystem.IsPlayerDead) {
        if ($null -ne $stats) {
            [float]$hp = Get-DeathHPValue -Stats $stats
            if ($hp -le 0) {
                Invoke-PlayerDeath | Out-Null
            }
        }
    } else {
        $script:DeathSystem.RespawnTimerRemaining = [Math]::Max(
            [float]0.0,
            [float]($script:DeathSystem.RespawnTimerRemaining - $delta)
        )

        if ($script:DeathSystem.RespawnTimerRemaining -le 0) {
            Invoke-PlayerRespawn | Out-Null
        }
    }

    Update-EnemyRespawnQueue -dt $delta
}

# ============================================================================
# Player Death and Respawn
# ============================================================================

function Set-DeathSpawnPosition {
    <#
    .SYNOPSIS
        Sets the player respawn spawn position.
    .PARAMETER Position
        Position object with X,Y,Z. If omitted, uses X/Y/Z parameters.
    #>
    param(
        $Position = $null,
        [float]$X = [float]0.0,
        [float]$Y = [float]70.0,
        [float]$Z = [float]0.0
    )

    if ($null -eq $script:DeathSystem) {
        Initialize-DeathSystem
    }

    if ($null -eq $Position) {
        $Position = [PSCustomObject]@{
            X = [float]$X
            Y = [float]$Y
            Z = [float]$Z
        }
    }

    $script:DeathSystem.SpawnPosition = Copy-DeathVector3 -Vector $Position
}

function Set-DeathRespawnDelay {
    <#
    .SYNOPSIS
        Sets respawn delay in seconds. Minimum value is 0.1.
    #>
    param([float]$Seconds)

    if ($null -eq $script:DeathSystem) {
        Initialize-DeathSystem
    }

    if ($Seconds -lt 0.1) { $Seconds = [float]0.1 }
    $script:DeathSystem.RespawnDelaySeconds = [float]$Seconds
}

function Set-DeathPenaltyConfig {
    <#
    .SYNOPSIS
        Configures optional death penalties.
    .DESCRIPTION
        Penalties are disabled by default and are safe placeholders unless
        external XP or inventory hooks are available.
    #>
    param(
        [bool]$EnableItemPenalty = $false,
        [bool]$EnableXPPenalty = $false,
        [float]$XPPercentLoss = [float]0.0
    )

    if ($null -eq $script:DeathSystem) {
        Initialize-DeathSystem
    }

    [float]$clampedXPPercent = [float]([Math]::Min(1.0, [Math]::Max(0.0, $XPPercentLoss)))

    $script:DeathSystem.PenaltyConfig = [PSCustomObject]@{
        EnableItemPenalty = [bool]$EnableItemPenalty
        EnableXPPenalty   = [bool]$EnableXPPenalty
        XPPercentLoss     = $clampedXPPercent
    }
}

function Invoke-DeathPenalty {
    <#
    .SYNOPSIS
        Applies optional, safe death penalties and returns a summary object.
    .DESCRIPTION
        By default this is non-destructive. XP and item penalties only apply
        when enabled and when external APIs exist.
    #>

    if ($null -eq $script:DeathSystem) {
        return $null
    }

    $result = [PSCustomObject]@{
        AppliedItemPenalty = $false
        AppliedXPPenalty   = $false
        XPRemoved          = [int]0
        ItemsRemoved       = @()
        Notes              = [string]'No penalties applied.'
    }

    $cfg = $script:DeathSystem.PenaltyConfig
    if ($null -eq $cfg) {
        $script:DeathSystem.LastPenalty = $result
        return $result
    }

    # Optional XP penalty hook
    if ($cfg.EnableXPPenalty -and $cfg.XPPercentLoss -gt 0) {
        $getXPCmd = Get-Command -Name Get-PlayerXP -ErrorAction SilentlyContinue
        $addXPCmd = Get-Command -Name Add-PlayerXP -ErrorAction SilentlyContinue

        if ($null -ne $getXPCmd -and $null -ne $addXPCmd) {
            [float]$currentXP = [float](Get-PlayerXP)
            [int]$xpLoss = [int][Math]::Floor($currentXP * [float]$cfg.XPPercentLoss)
            if ($xpLoss -gt 0) {
                Add-PlayerXP -Amount (-$xpLoss)
                $result.AppliedXPPenalty = $true
                $result.XPRemoved = $xpLoss
                $result.Notes = 'Applied XP penalty.'
            }
        } else {
            $result.Notes = 'XP penalty enabled but XP API is unavailable.'
        }
    }

    # Optional item penalty hook
    if ($cfg.EnableItemPenalty) {
        $inventoryPenaltyCmd = Get-Command -Name Invoke-InventoryDeathPenalty -ErrorAction SilentlyContinue
        if ($null -ne $inventoryPenaltyCmd) {
            $removed = Invoke-InventoryDeathPenalty
            $result.AppliedItemPenalty = $true
            if ($null -ne $removed) {
                $result.ItemsRemoved = @($removed)
            }
            if ($result.Notes -eq 'No penalties applied.') {
                $result.Notes = 'Applied item penalty hook.'
            }
        } else {
            if ($result.Notes -eq 'No penalties applied.') {
                $result.Notes = 'Item penalty enabled but inventory penalty hook is unavailable.'
            }
        }
    }

    $script:DeathSystem.LastPenalty = $result
    return $result
}

function Invoke-PlayerDeath {
    <#
    .SYNOPSIS
        Marks player as dead and starts respawn timer.
    #>

    if ($null -eq $script:DeathSystem -or -not $script:DeathSystem.IsInitialized) {
        Initialize-DeathSystem
    }

    if ($script:DeathSystem.IsPlayerDead) {
        return $false
    }

    $script:DeathSystem.IsPlayerDead = $true
    $script:DeathSystem.DeathCount += 1
    $script:DeathSystem.RespawnTimerRemaining = [float]$script:DeathSystem.RespawnDelaySeconds

    $stats = Get-DeathPlayerStats
    if ($null -ne $stats) {
        Set-DeathObjectProperty -Object $stats -Name 'HP' -Value ([float]0.0)
        Set-DeathObjectProperty -Object $stats -Name 'IsAlive' -Value $false
    }

    Invoke-DeathPenalty | Out-Null

    Write-Host "[Death] Player died. Respawn in $([Math]::Round($script:DeathSystem.RespawnDelaySeconds, 2))s." -ForegroundColor Red
    return $true
}

function Invoke-PlayerRespawn {
    <#
    .SYNOPSIS
        Respawns player at configured spawn position and restores HP.
    #>

    if ($null -eq $script:DeathSystem -or -not $script:DeathSystem.IsInitialized) {
        return $false
    }

    if (-not $script:DeathSystem.IsPlayerDead) {
        return $false
    }

    $stats = Get-DeathPlayerStats
    [float]$maxHP = Get-DeathMaxHPValue -Stats $stats

    [float]$respawnPercent = [float]([Math]::Min(1.0, [Math]::Max(0.05, $script:DeathSystem.RespawnHPPercent)))
    [float]$respawnHP = [Math]::Max([float]1.0, [float]($maxHP * $respawnPercent))

    $setHPCmd = Get-Command -Name Set-PlayerHP -ErrorAction SilentlyContinue
    if ($null -ne $setHPCmd) {
        Set-PlayerHP -Amount $respawnHP
    } elseif ($null -ne $stats) {
        Set-DeathObjectProperty -Object $stats -Name 'HP' -Value $respawnHP
    }

    if ($null -ne $stats) {
        Set-DeathObjectProperty -Object $stats -Name 'IsAlive' -Value $true
    }

    Set-DeathPlayerPosition -Position $script:DeathSystem.SpawnPosition

    $script:DeathSystem.IsPlayerDead = $false
    $script:DeathSystem.RespawnTimerRemaining = [float]0.0

    Write-Host "[Death] Player respawned at ($($script:DeathSystem.SpawnPosition.X), $($script:DeathSystem.SpawnPosition.Y), $($script:DeathSystem.SpawnPosition.Z))." -ForegroundColor Green
    return $true
}

function Test-PlayerDead {
    <#
    .SYNOPSIS
        Returns $true when player is in dead state.
    #>

    if ($null -eq $script:DeathSystem) { return $false }
    return [bool]$script:DeathSystem.IsPlayerDead
}

function Get-PlayerRespawnRemaining {
    <#
    .SYNOPSIS
        Returns remaining respawn timer seconds for the player.
    #>

    if ($null -eq $script:DeathSystem) { return [float]0.0 }
    return [float]$script:DeathSystem.RespawnTimerRemaining
}

# ============================================================================
# Enemy Death and Respawn
# ============================================================================

function New-EnemyLootDescriptor {
    <#
    .SYNOPSIS
        Creates a loot descriptor for a defeated enemy.
    .DESCRIPTION
        Uses enemy LootTable if present, otherwise emits a placeholder-safe
        default drop descriptor.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Entity
    )

    [string]$enemyName = 'Enemy'
    if ($null -ne $Entity.PSObject.Properties['Name']) {
        [string]$candidate = [string]$Entity.Name
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $enemyName = $candidate
        }
    }

    $position = Copy-DeathVector3 -Vector $null
    if ($null -ne $Entity.PSObject.Properties['Position']) {
        $position = Copy-DeathVector3 -Vector $Entity.Position
    }

    [bool]$usesPlaceholderDrops = $true
    $drops = @()

    if ($null -ne $Entity.PSObject.Properties['LootTable'] -and $null -ne $Entity.LootTable) {
        $drops = @($Entity.LootTable)
        if ($drops.Count -gt 0) {
            $usesPlaceholderDrops = $false
        }
    }

    if ($drops.Count -eq 0) {
        $drops = @(
            [PSCustomObject]@{
                Type     = 'Resource'
                Name     = 'loot_placeholder'
                MinCount = [int]1
                MaxCount = [int]1
                Chance   = [float]1.0
            }
        )
    }

    return [PSCustomObject]@{
        LootId              = [Guid]::NewGuid().ToString()
        EnemyName           = $enemyName
        Position            = $position
        Drops               = $drops
        UsesPlaceholderDrop = $usesPlaceholderDrops
        CreatedUtc          = [DateTime]::UtcNow
    }
}

function Queue-EnemyRespawn {
    <#
    .SYNOPSIS
        Queues an enemy for timed respawn.
    .PARAMETER Entity
        Enemy entity object (PSCustomObject-like).
    .PARAMETER RespawnSeconds
        Seconds before enemy is restored.
    .PARAMETER SpawnPosition
        Optional explicit respawn position. Defaults to entity's current position.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Entity,

        [float]$RespawnSeconds = [float]15.0,
        $SpawnPosition = $null
    )

    if ($RespawnSeconds -le 0) {
        return $false
    }

    if ($null -eq $SpawnPosition -and $null -ne $Entity.PSObject.Properties['Position']) {
        $SpawnPosition = $Entity.Position
    }

    $safeSpawnPos = Copy-DeathVector3 -Vector $SpawnPosition

    [float]$respawnHP = [float]1.0
    if ($null -ne $Entity.PSObject.Properties['MaxHP'] -and [float]$Entity.MaxHP -gt 0) {
        $respawnHP = [float]$Entity.MaxHP
    }

    # Update existing queue entry if this entity is already queued
    for ($i = 0; $i -lt $script:EnemyRespawnQueue.Count; $i++) {
        $existing = $script:EnemyRespawnQueue[$i]
        if ([object]::ReferenceEquals($existing.Entity, $Entity)) {
            $existing.RespawnSeconds = [float]$RespawnSeconds
            $existing.RemainingSeconds = [float]$RespawnSeconds
            $existing.SpawnPosition = $safeSpawnPos
            $existing.RespawnHP = $respawnHP
            return $true
        }
    }

    $entry = [PSCustomObject]@{
        Entity           = $Entity
        RespawnSeconds   = [float]$RespawnSeconds
        RemainingSeconds = [float]$RespawnSeconds
        SpawnPosition    = $safeSpawnPos
        RespawnHP        = $respawnHP
        QueuedUtc        = [DateTime]::UtcNow
    }

    $script:EnemyRespawnQueue.Add($entry) | Out-Null
    return $true
}

function Invoke-QueuedEnemyRespawn {
    param(
        [Parameter(Mandatory = $true)]
        $QueueEntry
    )

    if ($null -eq $QueueEntry -or $null -eq $QueueEntry.Entity) {
        return $null
    }

    $entity = $QueueEntry.Entity

    [float]$hp = [float]$QueueEntry.RespawnHP
    if ($null -ne $entity.PSObject.Properties['MaxHP'] -and [float]$entity.MaxHP -gt 0) {
        $hp = [float]$entity.MaxHP
    }

    Set-DeathObjectProperty -Object $entity -Name 'HP' -Value $hp
    Set-DeathObjectProperty -Object $entity -Name 'IsAlive' -Value $true
    Set-DeathObjectProperty -Object $entity -Name 'State' -Value 'idle'
    Set-DeathObjectProperty -Object $entity -Name 'AttackCooldown' -Value ([float]0.0)
    Set-DeathObjectProperty -Object $entity -Name 'Position' -Value (Copy-DeathVector3 -Vector $QueueEntry.SpawnPosition)

    return $entity
}

function Update-EnemyRespawnQueue {
    <#
    .SYNOPSIS
        Ticks queued enemy respawn timers and restores enemies when ready.
    #>
    param([float]$dt)

    if ($script:EnemyRespawnQueue.Count -eq 0) { return }

    for ($i = $script:EnemyRespawnQueue.Count - 1; $i -ge 0; $i--) {
        $entry = $script:EnemyRespawnQueue[$i]

        if ($null -eq $entry -or $null -eq $entry.Entity) {
            $script:EnemyRespawnQueue.RemoveAt($i)
            continue
        }

        # If entity is already alive by another system, drop queue entry.
        if ($null -ne $entry.Entity.PSObject.Properties['IsAlive'] -and [bool]$entry.Entity.IsAlive) {
            $script:EnemyRespawnQueue.RemoveAt($i)
            continue
        }

        $entry.RemainingSeconds = [float]([Math]::Max([float]0.0, [float]($entry.RemainingSeconds - $dt)))
        if ($entry.RemainingSeconds -le 0) {
            Invoke-QueuedEnemyRespawn -QueueEntry $entry | Out-Null
            $script:EnemyRespawnQueue.RemoveAt($i)
        }
    }
}

function Invoke-EnemyDeath {
    <#
    .SYNOPSIS
        Marks an enemy as dead, returns loot descriptor, and optionally queues respawn.
    .PARAMETER Entity
        Enemy entity object from combat system.
    .PARAMETER RespawnSeconds
        Optional respawn timer. 0 means no respawn queue entry.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Entity,

        [float]$RespawnSeconds = [float]0.0
    )

    Set-DeathObjectProperty -Object $Entity -Name 'HP' -Value ([float]0.0)
    Set-DeathObjectProperty -Object $Entity -Name 'IsAlive' -Value $false
    Set-DeathObjectProperty -Object $Entity -Name 'State' -Value 'dead'

    $loot = New-EnemyLootDescriptor -Entity $Entity

    if ($null -ne $script:DeathSystem) {
        $script:DeathSystem.LastEnemyLoot = $loot
    }

    if ($RespawnSeconds -gt 0) {
        Queue-EnemyRespawn -Entity $Entity -RespawnSeconds $RespawnSeconds | Out-Null
    }

    return $loot
}

function Get-EnemyRespawnQueue {
    <#
    .SYNOPSIS
        Returns queued enemy respawn entries.
    #>

    return ,$script:EnemyRespawnQueue
}

function Get-DeathSystem {
    <#
    .SYNOPSIS
        Returns current death system state object.
    #>

    return $script:DeathSystem
}
