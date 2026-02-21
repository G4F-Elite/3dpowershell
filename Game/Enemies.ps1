# ============================================================================
# Game/Enemies.ps1 - Enemy Archetypes and Spawning
# ============================================================================
# Defines typed enemies on top of Game/Enemy.ps1 base AI:
# - Zombie: slow and tanky bruiser
# - Skeleton: faster ranged-oriented hunter
# - Spider: fast skirmisher with leap metadata
# - Slime: optional splitter metadata
#
# This module only composes the base API from Game/Enemy.ps1.
# It does not replace base AI update logic.
# ============================================================================

# --- Module State ---
$script:EnemyTypeRandom        = [System.Random]::new(2727)
$script:EnemyTypeDefinitions   = @{}
$script:EnemyTypeSpawnCounters = @{}

# ============================================================================
# Internal Helpers
# ============================================================================

function Set-EnemyTypeProperty {
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    $prop = $Entity.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Entity | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Entity.$Name = $Value
    }
}

function Initialize-EnemyTypeDefinitions {
    $script:EnemyTypeDefinitions = @{}
    $script:EnemyTypeSpawnCounters = @{}

    $script:EnemyTypeDefinitions['zombie'] = [PSCustomObject]@{
        Type              = 'Zombie'
        NamePrefix        = 'Zombie'
        HP                = [float]52
        Damage            = [int]6
        Defense           = [int]2
        DetectRange       = [float]11
        AttackRange       = [float]1.8
        AttackCooldownMax = [float]1.85
        MoveSpeed         = [float]1.25
        PatrolRadius      = [float]6
        FleeThreshold     = [float]0.10
        CombatStyle       = 'Bruiser'
        BehaviorTag       = 'SlowTank'
        PreferredRange    = [float]1.5
        CanLeap           = $false
        LeapCooldown      = [float]0.0
        SplitOnDeath      = $false
        SplitChildrenType = ''
        SplitChildrenCount = [int]0
    }

    $script:EnemyTypeDefinitions['skeleton'] = [PSCustomObject]@{
        Type              = 'Skeleton'
        NamePrefix        = 'Skeleton'
        HP                = [float]30
        Damage            = [int]5
        Defense           = [int]1
        DetectRange       = [float]16
        AttackRange       = [float]7.0
        AttackCooldownMax = [float]1.20
        MoveSpeed         = [float]2.60
        PatrolRadius      = [float]10
        FleeThreshold     = [float]0.25
        CombatStyle       = 'Ranged'
        BehaviorTag       = 'Kiter'
        PreferredRange    = [float]5.5
        CanLeap           = $false
        LeapCooldown      = [float]0.0
        SplitOnDeath      = $false
        SplitChildrenType = ''
        SplitChildrenCount = [int]0
    }

    $script:EnemyTypeDefinitions['spider'] = [PSCustomObject]@{
        Type              = 'Spider'
        NamePrefix        = 'Spider'
        HP                = [float]24
        Damage            = [int]4
        Defense           = [int]0
        DetectRange       = [float]13
        AttackRange       = [float]1.6
        AttackCooldownMax = [float]0.90
        MoveSpeed         = [float]3.80
        PatrolRadius      = [float]12
        FleeThreshold     = [float]0.18
        CombatStyle       = 'Skirmisher'
        BehaviorTag       = 'Pouncer'
        PreferredRange    = [float]1.2
        CanLeap           = $true
        LeapCooldown      = [float]2.75
        SplitOnDeath      = $false
        SplitChildrenType = ''
        SplitChildrenCount = [int]0
    }

    # Optional fourth archetype.
    $script:EnemyTypeDefinitions['slime'] = [PSCustomObject]@{
        Type              = 'Slime'
        NamePrefix        = 'Slime'
        HP                = [float]20
        Damage            = [int]3
        Defense           = [int]0
        DetectRange       = [float]9
        AttackRange       = [float]1.4
        AttackCooldownMax = [float]1.40
        MoveSpeed         = [float]1.90
        PatrolRadius      = [float]7
        FleeThreshold     = [float]0.20
        CombatStyle       = 'Swarm'
        BehaviorTag       = 'Splitter'
        PreferredRange    = [float]1.0
        CanLeap           = $false
        LeapCooldown      = [float]0.0
        SplitOnDeath      = $true
        SplitChildrenType = 'Slime'
        SplitChildrenCount = [int]2
    }
}

function Ensure-EnemyTypeDefinitions {
    if ($script:EnemyTypeDefinitions.Count -eq 0) {
        Initialize-EnemyTypeDefinitions
    }
}

function Get-EnemyTypeDefinition {
    param([Parameter(Mandatory = $true)][string]$Type)

    Ensure-EnemyTypeDefinitions

    if ([string]::IsNullOrWhiteSpace($Type)) {
        return $null
    }

    $key = $Type.Trim().ToLowerInvariant()
    if ($script:EnemyTypeDefinitions.ContainsKey($key)) {
        return $script:EnemyTypeDefinitions[$key]
    }

    return $null
}

function Get-EnemyTypeNames {
    Ensure-EnemyTypeDefinitions

    $names = @()
    foreach ($definition in $script:EnemyTypeDefinitions.Values) {
        $names += [string]$definition.Type
    }

    return ,$names
}

function Get-EnemySpawnAnchorPosition {
    param([float]$PreferredY = 70)

    if (Get-Command -Name Get-PlayerPosition -ErrorAction SilentlyContinue) {
        $playerPos = Get-PlayerPosition
        if ($null -ne $playerPos) {
            return [PSCustomObject]@{
                X = [float]$playerPos.X
                Y = [float]$playerPos.Y
                Z = [float]$playerPos.Z
            }
        }
    }

    $playerVar = Get-Variable -Scope Script -Name PlayerPosition -ErrorAction SilentlyContinue
    if ($null -ne $playerVar -and $null -ne $playerVar.Value) {
        return [PSCustomObject]@{
            X = [float]$playerVar.Value.X
            Y = [float]$playerVar.Value.Y
            Z = [float]$playerVar.Value.Z
        }
    }

    return [PSCustomObject]@{
        X = [float]0
        Y = [float]$PreferredY
        Z = [float]0
    }
}

function Resolve-EnemySpawnPosition {
    param(
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [float]$PreferredY = 70
    )

    $anchor = Get-EnemySpawnAnchorPosition -PreferredY $PreferredY

    $resolvedX = if ($null -ne $X) { [float]$X } else { [float]$anchor.X }
    $resolvedY = if ($null -ne $Y) { [float]$Y } else { [float]$anchor.Y }
    $resolvedZ = if ($null -ne $Z) { [float]$Z } else { [float]$anchor.Z }

    return [PSCustomObject]@{
        X = [float]$resolvedX
        Y = [float]$resolvedY
        Z = [float]$resolvedZ
    }
}

function New-EnemyTypeName {
    param([Parameter(Mandatory = $true)][string]$Type)

    Ensure-EnemyTypeDefinitions

    $definition = Get-EnemyTypeDefinition -Type $Type
    if ($null -eq $definition) {
        return 'Enemy'
    }

    $key = $definition.Type.ToLowerInvariant()
    if (-not $script:EnemyTypeSpawnCounters.ContainsKey($key)) {
        $script:EnemyTypeSpawnCounters[$key] = [int]0
    }

    $script:EnemyTypeSpawnCounters[$key] = [int]$script:EnemyTypeSpawnCounters[$key] + 1
    return "{0} {1}" -f $definition.NamePrefix, $script:EnemyTypeSpawnCounters[$key]
}

function New-EnemyFromType {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    $definition = Get-EnemyTypeDefinition -Type $Type
    if ($null -eq $definition) {
        Write-Warning "[Enemies] Unknown enemy type '$Type'."
        return $null
    }

    $spawnPos = Resolve-EnemySpawnPosition -X $X -Y $Y -Z $Z

    $resolvedName = $Name
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $resolvedName = New-EnemyTypeName -Type $definition.Type
    }

    $enemy = $null

    if (Get-Command -Name Spawn-Enemy -ErrorAction SilentlyContinue) {
        $enemy = Spawn-Enemy `
            -Type $definition.Type `
            -Name $resolvedName `
            -X $spawnPos.X `
            -Y $spawnPos.Y `
            -Z $spawnPos.Z `
            -GroundCheck:$GroundCheck `
            -HP $definition.HP `
            -Damage $definition.Damage `
            -Defense $definition.Defense `
            -DetectRange $definition.DetectRange `
            -AttackRange $definition.AttackRange `
            -AttackCooldownMax $definition.AttackCooldownMax `
            -MoveSpeed $definition.MoveSpeed `
            -PatrolRadius $definition.PatrolRadius `
            -FleeThreshold $definition.FleeThreshold
    }
    elseif (Get-Command -Name New-Enemy -ErrorAction SilentlyContinue) {
        $enemy = New-Enemy `
            -Type $definition.Type `
            -Name $resolvedName `
            -Position $spawnPos `
            -HP $definition.HP `
            -Damage $definition.Damage `
            -Defense $definition.Defense `
            -DetectRange $definition.DetectRange `
            -AttackRange $definition.AttackRange `
            -AttackCooldownMax $definition.AttackCooldownMax `
            -MoveSpeed $definition.MoveSpeed `
            -PatrolRadius $definition.PatrolRadius `
            -FleeThreshold $definition.FleeThreshold
    }

    if ($null -eq $enemy) {
        return $null
    }

    Set-EnemyTypeProperty -Entity $enemy -Name 'Archetype' -Value ([string]$definition.Type)
    Set-EnemyTypeProperty -Entity $enemy -Name 'AIBehaviorTag' -Value ([string]$definition.BehaviorTag)
    Set-EnemyTypeProperty -Entity $enemy -Name 'CombatStyle' -Value ([string]$definition.CombatStyle)
    Set-EnemyTypeProperty -Entity $enemy -Name 'PreferredRange' -Value ([float]$definition.PreferredRange)
    Set-EnemyTypeProperty -Entity $enemy -Name 'CanLeap' -Value ([bool]$definition.CanLeap)
    Set-EnemyTypeProperty -Entity $enemy -Name 'LeapCooldownMax' -Value ([float]$definition.LeapCooldown)
    Set-EnemyTypeProperty -Entity $enemy -Name 'LeapCooldown' -Value ([float]0.0)
    Set-EnemyTypeProperty -Entity $enemy -Name 'SplitOnDeath' -Value ([bool]$definition.SplitOnDeath)
    Set-EnemyTypeProperty -Entity $enemy -Name 'SplitChildrenType' -Value ([string]$definition.SplitChildrenType)
    Set-EnemyTypeProperty -Entity $enemy -Name 'SplitChildrenCount' -Value ([int]$definition.SplitChildrenCount)

    return $enemy
}

# ============================================================================
# Public API - Enemy Constructors
# ============================================================================

function New-Zombie {
    param(
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    return New-EnemyFromType -Type 'Zombie' -X $X -Y $Y -Z $Z -GroundCheck:$GroundCheck -Name $Name
}

function New-Skeleton {
    param(
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    return New-EnemyFromType -Type 'Skeleton' -X $X -Y $Y -Z $Z -GroundCheck:$GroundCheck -Name $Name
}

function New-Spider {
    param(
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    return New-EnemyFromType -Type 'Spider' -X $X -Y $Y -Z $Z -GroundCheck:$GroundCheck -Name $Name
}

function New-Slime {
    param(
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    return New-EnemyFromType -Type 'Slime' -X $X -Y $Y -Z $Z -GroundCheck:$GroundCheck -Name $Name
}

# ============================================================================
# Public API - Spawning Helpers
# ============================================================================

function Spawn-EnemyArchetype {
    <#
    .SYNOPSIS
        Spawns one enemy from a named archetype.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Nullable[float]]$X = $null,
        [Nullable[float]]$Y = $null,
        [Nullable[float]]$Z = $null,
        [bool]$GroundCheck = $true,
        [string]$Name = ''
    )

    return New-EnemyFromType -Type $Type -X $X -Y $Y -Z $Z -GroundCheck:$GroundCheck -Name $Name
}

function Spawn-EnemyWaveAroundPlayer {
    <#
    .SYNOPSIS
        Spawns a wave of enemies around the player or world origin.
    .DESCRIPTION
        Picks random archetypes from -Types and places each enemy on a ring
        around the anchor position using random angle and distance.
    #>
    param(
        [int]$Count = 3,
        [string[]]$Types = @('Zombie', 'Skeleton', 'Spider'),
        [float]$MinDistance = 10,
        [float]$MaxDistance = 24,
        [float]$PreferredY = 70,
        [bool]$GroundCheck = $true
    )

    if ($Count -le 0) {
        return ,@()
    }

    if ($MaxDistance -lt $MinDistance) {
        $swap = [float]$MaxDistance
        $MaxDistance = [float]$MinDistance
        $MinDistance = [float]$swap
    }

    Ensure-EnemyTypeDefinitions

    $validTypes = @()
    foreach ($candidate in $Types) {
        $definition = Get-EnemyTypeDefinition -Type $candidate
        if ($null -ne $definition) {
            $validTypes += [string]$definition.Type
        }
    }

    if ($validTypes.Count -eq 0) {
        $validTypes = @('Zombie', 'Skeleton', 'Spider')
    }

    $anchor = Get-EnemySpawnAnchorPosition -PreferredY $PreferredY
    $spawned = @()

    [float]$distanceRange = [float]($MaxDistance - $MinDistance)
    if ($distanceRange -lt 0) {
        $distanceRange = [float]0
    }

    for ([int]$i = 0; $i -lt $Count; $i++) {
        $typeIndex = $script:EnemyTypeRandom.Next(0, $validTypes.Count)
        $type = [string]$validTypes[$typeIndex]

        [float]$angle = [float]($script:EnemyTypeRandom.NextDouble() * [System.Math]::PI * 2.0)
        [float]$distance = [float]($MinDistance + ($script:EnemyTypeRandom.NextDouble() * $distanceRange))

        [float]$spawnX = [float]($anchor.X + [System.Math]::Cos($angle) * $distance)
        [float]$spawnZ = [float]($anchor.Z + [System.Math]::Sin($angle) * $distance)

        $enemy = New-EnemyFromType `
            -Type $type `
            -X $spawnX `
            -Y ([float]$anchor.Y) `
            -Z $spawnZ `
            -GroundCheck:$GroundCheck

        if ($null -ne $enemy) {
            $spawned += $enemy
        }
    }

    return ,$spawned
}

function Get-EnemyArchetypes {
    <#
    .SYNOPSIS
        Returns all enemy archetype definitions.
    #>

    Ensure-EnemyTypeDefinitions

    $result = @()
    foreach ($definition in $script:EnemyTypeDefinitions.Values) {
        $result += $definition
    }

    return ,$result
}

# Initialize definitions on dot-source.
Ensure-EnemyTypeDefinitions
