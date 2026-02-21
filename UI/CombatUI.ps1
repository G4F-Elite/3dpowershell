# ============================================================================
# UI/CombatUI.ps1 - Combat Feedback Data Model
# ============================================================================
# Data-oriented combat UI feedback primitives.
#
# Provides:
# - Damage number events with lifetime tracking
# - Screen flash state for player damage feedback
# - Enemy health bar data extraction for active enemies
# - Attack cooldown indicator extraction
# - Combat log message buffer
#
# This module is render-agnostic. It only prepares state for a downstream HUD
# renderer. No complex animation system is used.
#
# Optional dependencies:
# - Engine/OpenGL.ps1: Register-UpdateCallback
# - Game/Combat.ps1: Get-CombatEntities, Get-NearbyEnemies, Get-CombatState
# - Game/Player.ps1: Get-PlayerPosition
# - Game/Stats.ps1: Get-PlayerStats
# ============================================================================

# --- Module State ---
$script:CombatUIInitialized = $false
$script:CombatUIUpdateRegistered = $false

$script:CombatUIDamageNumbers = [System.Collections.ArrayList]::new()
$script:CombatUIDamageNumberNextId = [int]1
$script:CombatUIDamageNumberDefaultLifetime = [float]1.0
$script:CombatUIDamageNumberRiseSpeed = [float]1.5

$script:CombatUIDamageFlashState = [PSCustomObject]@{
    IsActive     = $false
    ColorR       = [float]1.0
    ColorG       = [float]0.18
    ColorB       = [float]0.18
    MaxIntensity = [float]0.0
    Intensity    = [float]0.0
    Duration     = [float]0.0
    Remaining    = [float]0.0
}

$script:CombatUIEnemyHealthBars = @()
$script:CombatUIEnemyHPSeen = @{}
$script:CombatUIEnemyBarDistance = [float]32.0

$script:CombatUIAttackCooldownState = [PSCustomObject]@{
    State               = [string]'idle'
    IsReady             = $true
    CooldownRemaining   = [float]0.0
    CooldownMax         = [float]0.625
    CooldownProgress    = [float]1.0
    AttackTimerRemaining = [float]0.0
    AttackSwingDuration = [float]0.3
    AttackProgress      = [float]0.0
    TimestampUtc        = [DateTime]::UtcNow
}

$script:CombatUILogEntries = [System.Collections.ArrayList]::new()
$script:CombatUILogNextId = [int]1
$script:CombatUILogMaxEntries = [int]24
$script:CombatUILogDefaultLifetime = [float]8.0

$script:CombatUIPlayerLastHP = $null

# ============================================================================
# Internal Helpers
# ============================================================================

function Clamp-CombatUI01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function New-CombatUIVector3 {
    param(
        [float]$X = 0,
        [float]$Y = 0,
        [float]$Z = 0
    )

    return [PSCustomObject]@{
        X = [float]$X
        Y = [float]$Y
        Z = [float]$Z
    }
}

function Copy-CombatUIVector3 {
    param($Value)

    if ($null -eq $Value) {
        return (New-CombatUIVector3)
    }

    [float]$x = 0
    [float]$y = 0
    [float]$z = 0

    if ($null -ne $Value.PSObject.Properties['X']) { $x = [float]$Value.X }
    if ($null -ne $Value.PSObject.Properties['Y']) { $y = [float]$Value.Y }
    if ($null -ne $Value.PSObject.Properties['Z']) { $z = [float]$Value.Z }

    return (New-CombatUIVector3 -X $x -Y $y -Z $z)
}

function Get-CombatUIEntityKey {
    param($Entity)

    if ($null -eq $Entity) {
        return ''
    }

    try {
        [int]$refId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Entity)
        return [string]("ref:{0}" -f $refId)
    }
    catch {
        return [string]("obj:{0}" -f $Entity.GetHashCode())
    }
}

function Get-CombatUIPlayerPosition {
    if (Get-Command -Name Get-PlayerPosition -ErrorAction SilentlyContinue) {
        return (Copy-CombatUIVector3 -Value (Get-PlayerPosition))
    }

    $playerPosVar = Get-Variable -Scope Script -Name PlayerPosition -ErrorAction SilentlyContinue
    if ($null -ne $playerPosVar) {
        return (Copy-CombatUIVector3 -Value $playerPosVar.Value)
    }

    return $null
}

function Get-CombatUIEntities {
    $raw = @()

    if (Get-Command -Name Get-CombatEntities -ErrorAction SilentlyContinue) {
        $raw = @(Get-CombatEntities)
    }
    else {
        $combatVar = Get-Variable -Scope Script -Name CombatEntities -ErrorAction SilentlyContinue
        if ($null -ne $combatVar -and $null -ne $combatVar.Value) {
            $raw = @($combatVar.Value)
        }
    }

    $flattened = @()
    foreach ($item in $raw) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [System.Array] -or $item -is [System.Collections.ArrayList]) {
            foreach ($nested in $item) {
                if ($null -ne $nested) {
                    $flattened += $nested
                }
            }
            continue
        }

        $flattened += $item
    }

    return @($flattened)
}

function Get-CombatUIScriptFloat {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [float]$DefaultValue = [float]0.0
    )

    $valueVar = Get-Variable -Scope Script -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $valueVar) {
        return [float]$DefaultValue
    }

    try {
        return [float]$valueVar.Value
    }
    catch {
        return [float]$DefaultValue
    }
}

function Get-CombatUICombatState {
    if (Get-Command -Name Get-CombatState -ErrorAction SilentlyContinue) {
        return [string](Get-CombatState)
    }

    $stateVar = Get-Variable -Scope Script -Name PlayerCombatState -ErrorAction SilentlyContinue
    if ($null -ne $stateVar -and -not [string]::IsNullOrWhiteSpace([string]$stateVar.Value)) {
        return [string]$stateVar.Value
    }

    return 'idle'
}

function Update-CombatUIPlayerDamageDetection {
    if (-not (Get-Command -Name Get-PlayerStats -ErrorAction SilentlyContinue)) {
        return
    }

    $stats = Get-PlayerStats
    if ($null -eq $stats) {
        return
    }

    [float]$hp = [float]0.0
    if ($null -ne $stats.PSObject.Properties['HP']) {
        $hp = [float]$stats.HP
    }

    if ($null -eq $script:CombatUIPlayerLastHP) {
        $script:CombatUIPlayerLastHP = [float]$hp
        return
    }

    [float]$lastHP = [float]$script:CombatUIPlayerLastHP
    if ($hp -lt $lastHP) {
        [float]$taken = [float]($lastHP - $hp)
        [float]$flashIntensity = [float]([Math]::Min(1.0, 0.2 + ($taken / 20.0)))

        Trigger-DamageFlash -Duration 0.22 -Intensity $flashIntensity | Out-Null
        Add-CombatLogEntry -Message ("Player took {0} damage." -f [int][Math]::Round($taken)) -Category 'PlayerDamage' -Lifetime 4.0 | Out-Null
    }

    $script:CombatUIPlayerLastHP = [float]$hp
}

function Update-CombatUIEnemyHealthBarsInternal {
    $playerPos = Get-CombatUIPlayerPosition
    $entities = Get-CombatUIEntities

    $bars = @()
    $activeKeys = @{}

    foreach ($entity in $entities) {
        if ($null -eq $entity) { continue }

        if ($null -eq $entity.PSObject.Properties['IsAlive'] -or -not [bool]$entity.IsAlive) {
            continue
        }

        [float]$hp = [float]0.0
        [float]$maxHp = [float]1.0

        if ($null -ne $entity.PSObject.Properties['HP']) {
            $hp = [float]$entity.HP
        }

        if ($null -ne $entity.PSObject.Properties['MaxHP'] -and [float]$entity.MaxHP -gt 0) {
            $maxHp = [float]$entity.MaxHP
        }
        elseif ($hp -gt 0) {
            $maxHp = [float]$hp
        }

        if ($maxHp -le 0) { $maxHp = [float]1.0 }

        [float]$distance = [float]0.0
        if ($null -ne $playerPos -and $null -ne $entity.PSObject.Properties['Position']) {
            [float]$dx = [float]$entity.Position.X - [float]$playerPos.X
            [float]$dy = [float]$entity.Position.Y - [float]$playerPos.Y
            [float]$dz = [float]$entity.Position.Z - [float]$playerPos.Z
            $distance = [float][Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)

            if ($distance -gt $script:CombatUIEnemyBarDistance) {
                continue
            }
        }

        $entityKey = Get-CombatUIEntityKey -Entity $entity
        if ([string]::IsNullOrWhiteSpace($entityKey)) {
            continue
        }

        $activeKeys[$entityKey] = $true

        if ($script:CombatUIEnemyHPSeen.ContainsKey($entityKey)) {
            [float]$prevHP = [float]$script:CombatUIEnemyHPSeen[$entityKey]
            if ($hp -lt $prevHP) {
                [int]$damage = [int][Math]::Max(1, [Math]::Round($prevHP - $hp))

                $damagePos = $null
                if ($null -ne $entity.PSObject.Properties['Position']) {
                    $damagePos = Copy-CombatUIVector3 -Value $entity.Position
                    $damagePos.Y = [float]($damagePos.Y + 1.3)
                }

                [string]$targetName = 'Enemy'
                if ($null -ne $entity.PSObject.Properties['Name']) {
                    $targetName = [string]$entity.Name
                }

                Add-DamageNumber -Amount $damage -WorldPosition $damagePos -TargetName $targetName | Out-Null

                if ($hp -le 0) {
                    Add-CombatLogEntry -Message ("{0} defeated." -f $targetName) -Category 'EnemyDefeated' -Lifetime 6.0 | Out-Null
                }
            }
        }

        $script:CombatUIEnemyHPSeen[$entityKey] = [float]$hp

        [float]$ratio = [float]0.0
        if ($maxHp -gt 0) {
            $ratio = Clamp-CombatUI01 -Value ($hp / $maxHp)
        }

        $position = New-CombatUIVector3
        $anchor = New-CombatUIVector3

        if ($null -ne $entity.PSObject.Properties['Position']) {
            $position = Copy-CombatUIVector3 -Value $entity.Position
            $anchor = Copy-CombatUIVector3 -Value $entity.Position
            $anchor.Y = [float]($anchor.Y + 1.6)
        }

        [string]$name = 'Enemy'
        if ($null -ne $entity.PSObject.Properties['Name']) {
            $name = [string]$entity.Name
        }

        [string]$state = 'active'
        if ($null -ne $entity.PSObject.Properties['AIState']) {
            $state = [string]$entity.AIState
        }
        elseif ($null -ne $entity.PSObject.Properties['State']) {
            $state = [string]$entity.State
        }

        $bars += [PSCustomObject]@{
            Name           = $name
            CurrentHP      = [float]$hp
            MaxHP          = [float]$maxHp
            HealthRatio    = [float]$ratio
            Distance       = [float]$distance
            Position       = $position
            AnchorPosition = $anchor
            State          = $state
            Entity         = $entity
        }
    }

    $staleKeys = @()
    foreach ($existingKey in @($script:CombatUIEnemyHPSeen.Keys)) {
        if (-not $activeKeys.ContainsKey($existingKey)) {
            $staleKeys += $existingKey
        }
    }

    foreach ($stale in $staleKeys) {
        $script:CombatUIEnemyHPSeen.Remove($stale)
    }

    $script:CombatUIEnemyHealthBars = @($bars)
}

function Update-CombatUIAttackCooldownInternal {
    [string]$state = Get-CombatUICombatState
    [string]$stateLower = $state.ToLowerInvariant()

    [float]$timer = Get-CombatUIScriptFloat -Name 'PlayerAttackTimer' -DefaultValue 0.0
    [float]$cooldownMax = Get-CombatUIScriptFloat -Name 'PlayerAttackCooldownMax' -DefaultValue 0.625
    [float]$swingMax = Get-CombatUIScriptFloat -Name 'PlayerAttackSwingTime' -DefaultValue 0.3

    [bool]$isReady = $true
    [float]$cooldownRemaining = [float]0.0
    [float]$cooldownProgress = [float]1.0
    [float]$attackProgress = [float]0.0

    switch ($stateLower) {
        'attacking' {
            $isReady = $false
            if ($swingMax -le 0.0) {
                $attackProgress = [float]1.0
            }
            else {
                $attackProgress = Clamp-CombatUI01 -Value (1.0 - ($timer / $swingMax))
            }
            $cooldownRemaining = [float]0.0
            $cooldownProgress = [float]0.0
        }
        'cooldown' {
            $isReady = $false
            $cooldownRemaining = [float][Math]::Max(0.0, $timer)
            if ($cooldownMax -le 0.0) {
                $cooldownProgress = [float]1.0
            }
            else {
                $cooldownProgress = Clamp-CombatUI01 -Value (1.0 - ($cooldownRemaining / $cooldownMax))
            }
            $attackProgress = [float]1.0
        }
        default {
            $isReady = $true
            $cooldownRemaining = [float]0.0
            $cooldownProgress = [float]1.0
            $attackProgress = [float]0.0
        }
    }

    $script:CombatUIAttackCooldownState = [PSCustomObject]@{
        State                = [string]$stateLower
        IsReady              = [bool]$isReady
        CooldownRemaining    = [float]$cooldownRemaining
        CooldownMax          = [float]$cooldownMax
        CooldownProgress     = [float]$cooldownProgress
        AttackTimerRemaining = [float][Math]::Max(0.0, $timer)
        AttackSwingDuration  = [float]$swingMax
        AttackProgress       = [float]$attackProgress
        TimestampUtc         = [DateTime]::UtcNow
    }
}

function Update-CombatUIDamageNumbers {
    param([float]$dt)

    if ($script:CombatUIDamageNumbers.Count -eq 0) {
        return
    }

    for ($i = $script:CombatUIDamageNumbers.Count - 1; $i -ge 0; $i--) {
        $entry = $script:CombatUIDamageNumbers[$i]
        if ($null -eq $entry) {
            $script:CombatUIDamageNumbers.RemoveAt($i)
            continue
        }

        $entry.Age = [float]($entry.Age + $dt)
        $entry.Remaining = [float]([Math]::Max(0.0, $entry.Remaining - $dt))
        $entry.VerticalOffset = [float]($entry.VerticalOffset + ($script:CombatUIDamageNumberRiseSpeed * $dt))

        if ($entry.Remaining -le 0.0) {
            $script:CombatUIDamageNumbers.RemoveAt($i)
        }
    }
}

function Update-CombatUIDamageFlash {
    param([float]$dt)

    if (-not $script:CombatUIDamageFlashState.IsActive) {
        return
    }

    $script:CombatUIDamageFlashState.Remaining = [float]([Math]::Max(0.0, $script:CombatUIDamageFlashState.Remaining - $dt))

    if ($script:CombatUIDamageFlashState.Duration -gt 0.0) {
        [float]$normalized = Clamp-CombatUI01 -Value ($script:CombatUIDamageFlashState.Remaining / $script:CombatUIDamageFlashState.Duration)
        $script:CombatUIDamageFlashState.Intensity = [float]($script:CombatUIDamageFlashState.MaxIntensity * $normalized)
    }
    else {
        $script:CombatUIDamageFlashState.Intensity = [float]0.0
    }

    if ($script:CombatUIDamageFlashState.Remaining -le 0.0) {
        $script:CombatUIDamageFlashState.IsActive = $false
        $script:CombatUIDamageFlashState.Intensity = [float]0.0
        $script:CombatUIDamageFlashState.MaxIntensity = [float]0.0
    }
}

function Update-CombatUICombatLog {
    param([float]$dt)

    if ($script:CombatUILogEntries.Count -eq 0) {
        return
    }

    for ($i = $script:CombatUILogEntries.Count - 1; $i -ge 0; $i--) {
        $entry = $script:CombatUILogEntries[$i]
        if ($null -eq $entry) {
            $script:CombatUILogEntries.RemoveAt($i)
            continue
        }

        if ($entry.Lifetime -le 0.0) {
            continue
        }

        $entry.Age = [float]($entry.Age + $dt)
        $entry.Remaining = [float]([Math]::Max(0.0, $entry.Remaining - $dt))

        if ($entry.Remaining -le 0.0) {
            $script:CombatUILogEntries.RemoveAt($i)
        }
    }
}

# ============================================================================
# Public API - Initialize and Update
# ============================================================================

function Initialize-CombatUI {
    <#
    .SYNOPSIS
        Initializes combat UI feedback state and registers update callback.
    #>

    $script:CombatUIDamageNumbers = [System.Collections.ArrayList]::new()
    $script:CombatUIDamageNumberNextId = [int]1

    $script:CombatUIDamageFlashState = [PSCustomObject]@{
        IsActive     = $false
        ColorR       = [float]1.0
        ColorG       = [float]0.18
        ColorB       = [float]0.18
        MaxIntensity = [float]0.0
        Intensity    = [float]0.0
        Duration     = [float]0.0
        Remaining    = [float]0.0
    }

    $script:CombatUIEnemyHealthBars = @()
    $script:CombatUIEnemyHPSeen = @{}

    $script:CombatUIAttackCooldownState = [PSCustomObject]@{
        State                = [string]'idle'
        IsReady              = $true
        CooldownRemaining    = [float]0.0
        CooldownMax          = [float]0.625
        CooldownProgress     = [float]1.0
        AttackTimerRemaining = [float]0.0
        AttackSwingDuration  = [float]0.3
        AttackProgress       = [float]0.0
        TimestampUtc         = [DateTime]::UtcNow
    }

    $script:CombatUILogEntries = [System.Collections.ArrayList]::new()
    $script:CombatUILogNextId = [int]1

    $script:CombatUIPlayerLastHP = $null

    $script:CombatUIInitialized = $true

    if (-not $script:CombatUIUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-CombatUI}
            $script:CombatUIUpdateRegistered = $true
            Write-Host "[CombatUI] Update callback registered." -ForegroundColor DarkGray
        }
    }

    Write-Host "[CombatUI] Combat UI model initialized." -ForegroundColor Green
}

function Update-CombatUI {
    <#
    .SYNOPSIS
        Per-frame combat UI feedback update.
    #>
    param($dt)

    if (-not $script:CombatUIInitialized) {
        return
    }

    [float]$step = [float]0.0
    if ($null -ne $dt) {
        $step = [float]$dt
    }

    if ($step -lt 0.0) { $step = [float]0.0 }
    if ($step -gt 0.1) { $step = [float]0.1 }

    if ($step -gt 0.0) {
        Update-CombatUIDamageNumbers -dt $step
        Update-CombatUIDamageFlash -dt $step
        Update-CombatUICombatLog -dt $step
    }

    Update-CombatUIPlayerDamageDetection
    Update-CombatUIEnemyHealthBarsInternal
    Update-CombatUIAttackCooldownInternal
}

# ============================================================================
# Public API - Event Writers
# ============================================================================

function Add-DamageNumber {
    <#
    .SYNOPSIS
        Adds a timed damage number event for HUD overlay rendering.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Amount,

        $WorldPosition = $null,
        [string]$TargetName = '',
        [float]$Lifetime = [float]-1.0,
        [bool]$IsCritical = $false,
        [string]$Style = 'damage'
    )

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    [float]$resolvedLifetime = [float]$Lifetime
    if ($resolvedLifetime -le 0.0) {
        $resolvedLifetime = [float]$script:CombatUIDamageNumberDefaultLifetime
    }

    $resolvedPosition = $null
    if ($null -ne $WorldPosition) {
        $resolvedPosition = Copy-CombatUIVector3 -Value $WorldPosition
    }
    else {
        $resolvedPosition = Get-CombatUIPlayerPosition
        if ($null -eq $resolvedPosition) {
            $resolvedPosition = New-CombatUIVector3
        }
    }

    $entry = [PSCustomObject]@{
        Id             = [int]$script:CombatUIDamageNumberNextId
        Amount         = [int]$Amount
        Text           = [string]$Amount
        TargetName     = [string]$TargetName
        Position       = $resolvedPosition
        VerticalOffset = [float]0.0
        Lifetime       = [float]$resolvedLifetime
        Remaining      = [float]$resolvedLifetime
        Age            = [float]0.0
        IsCritical     = [bool]$IsCritical
        Style          = [string]$Style
        CreatedUtc     = [DateTime]::UtcNow
    }

    $script:CombatUIDamageNumbers.Add($entry) | Out-Null
    $script:CombatUIDamageNumberNextId = [int]$script:CombatUIDamageNumberNextId + 1

    return $entry
}

function Trigger-DamageFlash {
    <#
    .SYNOPSIS
        Triggers or refreshes full-screen damage flash state.
    #>
    param(
        [float]$Duration = [float]0.2,
        [float]$Intensity = [float]0.8,
        [float]$ColorR = [float]1.0,
        [float]$ColorG = [float]0.18,
        [float]$ColorB = [float]0.18
    )

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    if ($Duration -le 0.0) {
        $Duration = [float]0.01
    }

    [float]$clampedIntensity = Clamp-CombatUI01 -Value $Intensity

    $script:CombatUIDamageFlashState.IsActive = $true
    $script:CombatUIDamageFlashState.Duration = [float]$Duration
    $script:CombatUIDamageFlashState.Remaining = [float]$Duration
    $script:CombatUIDamageFlashState.MaxIntensity = [float]$clampedIntensity
    $script:CombatUIDamageFlashState.Intensity = [float]$clampedIntensity
    $script:CombatUIDamageFlashState.ColorR = Clamp-CombatUI01 -Value $ColorR
    $script:CombatUIDamageFlashState.ColorG = Clamp-CombatUI01 -Value $ColorG
    $script:CombatUIDamageFlashState.ColorB = Clamp-CombatUI01 -Value $ColorB

    return $script:CombatUIDamageFlashState
}

function Add-CombatLogEntry {
    <#
    .SYNOPSIS
        Adds a combat log entry to the fixed-size message buffer.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Category = 'Combat',
        [float]$Lifetime = [float]-1.0
    )

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $null
    }

    [float]$resolvedLifetime = [float]$Lifetime
    if ($resolvedLifetime -lt 0.0) {
        $resolvedLifetime = [float]$script:CombatUILogDefaultLifetime
    }

    $entry = [PSCustomObject]@{
        Id         = [int]$script:CombatUILogNextId
        Message    = [string]$Message
        Category   = [string]$Category
        Lifetime   = [float]$resolvedLifetime
        Remaining  = [float]$resolvedLifetime
        Age        = [float]0.0
        CreatedUtc = [DateTime]::UtcNow
    }

    $script:CombatUILogEntries.Add($entry) | Out-Null
    $script:CombatUILogNextId = [int]$script:CombatUILogNextId + 1

    while ($script:CombatUILogEntries.Count -gt $script:CombatUILogMaxEntries) {
        $script:CombatUILogEntries.RemoveAt(0)
    }

    return $entry
}

# ============================================================================
# Public API - Read Models for HUD Rendering
# ============================================================================

function Get-ActiveDamageNumbers {
    <#
    .SYNOPSIS
        Returns active damage numbers with normalized fade data.
    #>

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    $result = @()
    foreach ($entry in $script:CombatUIDamageNumbers) {
        if ($null -eq $entry) { continue }

        [float]$alpha = [float]1.0
        if ($entry.Lifetime -gt 0.0) {
            $alpha = Clamp-CombatUI01 -Value ($entry.Remaining / $entry.Lifetime)
        }

        $result += [PSCustomObject]@{
            Id             = [int]$entry.Id
            Amount         = [int]$entry.Amount
            Text           = [string]$entry.Text
            TargetName     = [string]$entry.TargetName
            Position       = (Copy-CombatUIVector3 -Value $entry.Position)
            VerticalOffset = [float]$entry.VerticalOffset
            Lifetime       = [float]$entry.Lifetime
            Remaining      = [float]$entry.Remaining
            Age            = [float]$entry.Age
            Alpha          = [float]$alpha
            IsCritical     = [bool]$entry.IsCritical
            Style          = [string]$entry.Style
            CreatedUtc     = [DateTime]$entry.CreatedUtc
        }
    }

    return ,$result
}

function Get-EnemyHealthBars {
    <#
    .SYNOPSIS
        Returns health bar data for active nearby enemies.
    #>

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    Update-CombatUIEnemyHealthBarsInternal

    $result = @()
    foreach ($bar in $script:CombatUIEnemyHealthBars) {
        if ($null -eq $bar) { continue }

        $result += [PSCustomObject]@{
            Name           = [string]$bar.Name
            CurrentHP      = [float]$bar.CurrentHP
            MaxHP          = [float]$bar.MaxHP
            HealthRatio    = [float]$bar.HealthRatio
            Distance       = [float]$bar.Distance
            Position       = (Copy-CombatUIVector3 -Value $bar.Position)
            AnchorPosition = (Copy-CombatUIVector3 -Value $bar.AnchorPosition)
            State          = [string]$bar.State
            Entity         = $bar.Entity
        }
    }

    return ,$result
}

function Get-AttackCooldownUI {
    <#
    .SYNOPSIS
        Returns player attack cooldown indicator data.
    #>

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    Update-CombatUIAttackCooldownInternal

    return [PSCustomObject]@{
        State                = [string]$script:CombatUIAttackCooldownState.State
        IsReady              = [bool]$script:CombatUIAttackCooldownState.IsReady
        CooldownRemaining    = [float]$script:CombatUIAttackCooldownState.CooldownRemaining
        CooldownMax          = [float]$script:CombatUIAttackCooldownState.CooldownMax
        CooldownProgress     = [float]$script:CombatUIAttackCooldownState.CooldownProgress
        AttackTimerRemaining = [float]$script:CombatUIAttackCooldownState.AttackTimerRemaining
        AttackSwingDuration  = [float]$script:CombatUIAttackCooldownState.AttackSwingDuration
        AttackProgress       = [float]$script:CombatUIAttackCooldownState.AttackProgress
        TimestampUtc         = [DateTime]$script:CombatUIAttackCooldownState.TimestampUtc
    }
}

function Get-CombatLogEntries {
    <#
    .SYNOPSIS
        Returns buffered combat log entries.
    #>

    if (-not $script:CombatUIInitialized) {
        Initialize-CombatUI
    }

    $result = @()
    foreach ($entry in $script:CombatUILogEntries) {
        if ($null -eq $entry) { continue }

        $result += [PSCustomObject]@{
            Id         = [int]$entry.Id
            Message    = [string]$entry.Message
            Category   = [string]$entry.Category
            Lifetime   = [float]$entry.Lifetime
            Remaining  = [float]$entry.Remaining
            Age        = [float]$entry.Age
            CreatedUtc = [DateTime]$entry.CreatedUtc
        }
    }

    return ,$result
}
