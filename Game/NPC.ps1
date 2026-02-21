# ============================================================================
# Game/NPC.ps1 - NPC Entity System Foundations
# ============================================================================
# Provides a simple NPC entity model with:
# - Position + appearance data
# - States: Idle, Talking, Trading
# - Local wander movement around spawn position
# - Proximity interaction helper (approach + interact concept)
# - Spawn point registration and spawn helpers
#
# Dependencies (optional when available):
#   Engine/OpenGL.ps1 (Register-UpdateCallback)
#   Game/Player.ps1 (Get-PlayerPosition)
# ============================================================================

# --- Module State ---
$script:NPCInitialized                 = $false
$script:NPCUpdateRegistered            = $false
$script:NPCEntities                    = @()
$script:NPCSpawnPoints                 = @{}
$script:NPCRandom                      = [System.Random]::new(4242)
$script:NPCNextId                      = [int]1

$script:NPCDefaultWanderRadius         = [float]6.0
$script:NPCDefaultWanderSpeed          = [float]1.2
$script:NPCDefaultInteractionDistance  = [float]3.0
$script:NPCDefaultPauseMin             = [float]1.0
$script:NPCDefaultPauseMax             = [float]2.5
$script:NPCTalkDuration                = [float]2.5
$script:NPCTradeDuration               = [float]4.0

# ============================================================================
# Internal Helpers
# ============================================================================

function New-NPCPosition {
    param(
        [float]$X,
        [float]$Y,
        [float]$Z
    )

    return [PSCustomObject]@{
        X = [float]$X
        Y = [float]$Y
        Z = [float]$Z
    }
}

function Copy-NPCPosition {
    param($Position)

    if ($null -eq $Position) {
        return (New-NPCPosition -X 0 -Y 70 -Z 0)
    }

    return (New-NPCPosition -X ([float]$Position.X) -Y ([float]$Position.Y) -Z ([float]$Position.Z))
}

function Set-NPCProperty {
    param(
        [Parameter(Mandatory = $true)]$NPC,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    $prop = $NPC.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $NPC | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $NPC.$Name = $Value
    }
}

function Get-NPCPauseDuration {
    [float]$range = [float]($script:NPCDefaultPauseMax - $script:NPCDefaultPauseMin)
    if ($range -lt 0) { $range = [float]0.0 }

    return [float]($script:NPCDefaultPauseMin + ($script:NPCRandom.NextDouble() * $range))
}

function Get-NPCDistance {
    param(
        [Parameter(Mandatory = $true)]$From,
        [Parameter(Mandatory = $true)]$To
    )

    [float]$dx = [float]$To.X - [float]$From.X
    [float]$dy = [float]$To.Y - [float]$From.Y
    [float]$dz = [float]$To.Z - [float]$From.Z
    return [float][System.Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)
}

function Get-NPCPlayerPosition {
    param($PlayerPosition)

    if ($null -ne $PlayerPosition) {
        return (Copy-NPCPosition -Position $PlayerPosition)
    }

    if (Get-Command -Name Get-PlayerPosition -ErrorAction SilentlyContinue) {
        return (Copy-NPCPosition -Position (Get-PlayerPosition))
    }

    $playerVar = Get-Variable -Scope Script -Name PlayerPosition -ErrorAction SilentlyContinue
    if ($null -ne $playerVar -and $null -ne $playerVar.Value) {
        return (Copy-NPCPosition -Position $playerVar.Value)
    }

    return $null
}

function Ensure-NPCEntityDefaults {
    param([Parameter(Mandatory = $true)]$NPC)

    if ($null -eq $NPC.PSObject.Properties['Position']) {
        Set-NPCProperty -NPC $NPC -Name 'Position' -Value (New-NPCPosition -X 0 -Y 70 -Z 0)
    }
    else {
        $NPC.Position = Copy-NPCPosition -Position $NPC.Position
    }

    if ($null -eq $NPC.PSObject.Properties['SpawnPosition']) {
        Set-NPCProperty -NPC $NPC -Name 'SpawnPosition' -Value (Copy-NPCPosition -Position $NPC.Position)
    }
    else {
        $NPC.SpawnPosition = Copy-NPCPosition -Position $NPC.SpawnPosition
    }

    if ($null -eq $NPC.PSObject.Properties['Id']) {
        Set-NPCProperty -NPC $NPC -Name 'Id' -Value ([int]$script:NPCNextId)
        $script:NPCNextId++
    }

    if ($null -eq $NPC.PSObject.Properties['Name']) {
        Set-NPCProperty -NPC $NPC -Name 'Name' -Value ([string]("NPC {0}" -f $NPC.Id))
    }

    if ($null -eq $NPC.PSObject.Properties['Appearance']) {
        Set-NPCProperty -NPC $NPC -Name 'Appearance' -Value ([PSCustomObject]@{
            Model          = 'Villager'
            Outfit         = 'Default'
            PrimaryColor   = 'Brown'
            SecondaryColor = 'Beige'
        })
    }

    if ($null -eq $NPC.PSObject.Properties['State']) {
        Set-NPCProperty -NPC $NPC -Name 'State' -Value 'Idle'
    }

    if ([string]::IsNullOrWhiteSpace([string]$NPC.State)) {
        $NPC.State = 'Idle'
    }

    if ($NPC.State -notin @('Idle', 'Talking', 'Trading')) {
        $NPC.State = 'Idle'
    }

    if ($null -eq $NPC.PSObject.Properties['CanTrade']) {
        Set-NPCProperty -NPC $NPC -Name 'CanTrade' -Value ([bool]$false)
    }

    if ($null -eq $NPC.PSObject.Properties['WanderRadius']) {
        Set-NPCProperty -NPC $NPC -Name 'WanderRadius' -Value ([float]$script:NPCDefaultWanderRadius)
    }

    if ($null -eq $NPC.PSObject.Properties['WanderSpeed']) {
        Set-NPCProperty -NPC $NPC -Name 'WanderSpeed' -Value ([float]$script:NPCDefaultWanderSpeed)
    }

    if ($null -eq $NPC.PSObject.Properties['WanderTarget']) {
        Set-NPCProperty -NPC $NPC -Name 'WanderTarget' -Value $null
    }

    if ($null -eq $NPC.PSObject.Properties['WanderPauseTimer']) {
        Set-NPCProperty -NPC $NPC -Name 'WanderPauseTimer' -Value (Get-NPCPauseDuration)
    }

    if ($null -eq $NPC.PSObject.Properties['InteractionDistance']) {
        Set-NPCProperty -NPC $NPC -Name 'InteractionDistance' -Value ([float]$script:NPCDefaultInteractionDistance)
    }

    if ($null -eq $NPC.PSObject.Properties['InteractionTimer']) {
        Set-NPCProperty -NPC $NPC -Name 'InteractionTimer' -Value ([float]0.0)
    }

    if ($null -eq $NPC.PSObject.Properties['SpawnPointName']) {
        Set-NPCProperty -NPC $NPC -Name 'SpawnPointName' -Value ''
    }

    if ($null -eq $NPC.PSObject.Properties['IsSpawned']) {
        Set-NPCProperty -NPC $NPC -Name 'IsSpawned' -Value ([bool]$false)
    }

    if ($NPC.WanderRadius -lt 0) { $NPC.WanderRadius = [float]0.0 }
    if ($NPC.WanderSpeed -lt 0) { $NPC.WanderSpeed = [float]0.0 }
    if ($NPC.InteractionDistance -lt 0) { $NPC.InteractionDistance = [float]0.0 }
}

function New-NPCWanderTarget {
    param([Parameter(Mandatory = $true)]$NPC)

    [float]$radius = [float]$NPC.WanderRadius
    if ($radius -le 0) {
        return (Copy-NPCPosition -Position $NPC.SpawnPosition)
    }

    [float]$angle = [float]($script:NPCRandom.NextDouble() * [System.Math]::PI * 2.0)
    [float]$distance = [float]($script:NPCRandom.NextDouble() * $radius)

    return (New-NPCPosition `
        -X ([float]($NPC.SpawnPosition.X + [System.Math]::Cos($angle) * $distance)) `
        -Y ([float]$NPC.SpawnPosition.Y) `
        -Z ([float]($NPC.SpawnPosition.Z + [System.Math]::Sin($angle) * $distance)))
}

function Move-NPCTowardTarget {
    param(
        [Parameter(Mandatory = $true)]$NPC,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][float]$dt
    )

    [float]$dx = [float]$Target.X - [float]$NPC.Position.X
    [float]$dz = [float]$Target.Z - [float]$NPC.Position.Z
    [float]$dist = [float][System.Math]::Sqrt($dx * $dx + $dz * $dz)

    if ($dist -le 0.001) {
        $NPC.Position = Copy-NPCPosition -Position $Target
        return $true
    }

    [float]$step = [float]$NPC.WanderSpeed * $dt
    if ($step -ge $dist) {
        $NPC.Position = Copy-NPCPosition -Position $Target
        return $true
    }

    [float]$nx = $dx / $dist
    [float]$nz = $dz / $dist
    $NPC.Position = New-NPCPosition `
        -X ([float]($NPC.Position.X + $nx * $step)) `
        -Y ([float]$NPC.Position.Y) `
        -Z ([float]($NPC.Position.Z + $nz * $step))

    return $false
}

function Get-NPCSpawnPointInternal {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $key = $Name.Trim().ToLowerInvariant()

    if ($script:NPCSpawnPoints.ContainsKey($key)) {
        return $script:NPCSpawnPoints[$key]
    }

    return $null
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-NPCSystem {
    <#
    .SYNOPSIS
        Initializes NPC state and registers Update-NPCSystem when available.
    #>

    $script:NPCInitialized = $true
    $script:NPCEntities = @()
    $script:NPCSpawnPoints = @{}
    $script:NPCRandom = [System.Random]::new(4242)
    $script:NPCNextId = [int]1

    if (-not $script:NPCUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-NPCSystem}
            $script:NPCUpdateRegistered = $true
        }
    }

    Write-Host "[NPC] NPC system initialized." -ForegroundColor Green
}

function New-NPC {
    <#
    .SYNOPSIS
        Creates an NPC entity object with position and appearance data.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [float]$X = 0,
        [float]$Y = 70,
        [float]$Z = 0,
        [float]$WanderRadius = $script:NPCDefaultWanderRadius,
        [float]$WanderSpeed = $script:NPCDefaultWanderSpeed,
        [float]$InteractionDistance = $script:NPCDefaultInteractionDistance,
        [ValidateSet('Idle', 'Talking', 'Trading')][string]$InitialState = 'Idle',
        [bool]$CanTrade = $false,
        [string]$Model = 'Villager',
        [string]$Outfit = 'Default',
        [string]$PrimaryColor = 'Brown',
        [string]$SecondaryColor = 'Beige'
    )

    if ($WanderRadius -lt 0) { $WanderRadius = [float]0.0 }
    if ($WanderSpeed -lt 0) { $WanderSpeed = [float]0.0 }
    if ($InteractionDistance -lt 0) { $InteractionDistance = [float]0.0 }

    [int]$id = [int]$script:NPCNextId
    $script:NPCNextId++

    $position = New-NPCPosition -X $X -Y $Y -Z $Z
    $npc = [PSCustomObject]@{
        Id                  = [int]$id
        Name                = [string]$Name
        Position            = $position
        SpawnPosition       = Copy-NPCPosition -Position $position
        Appearance          = [PSCustomObject]@{
            Model          = [string]$Model
            Outfit         = [string]$Outfit
            PrimaryColor   = [string]$PrimaryColor
            SecondaryColor = [string]$SecondaryColor
        }
        State               = [string]$InitialState
        CanTrade            = [bool]$CanTrade
        WanderRadius        = [float]$WanderRadius
        WanderSpeed         = [float]$WanderSpeed
        WanderTarget        = $null
        WanderPauseTimer    = (Get-NPCPauseDuration)
        InteractionDistance = [float]$InteractionDistance
        InteractionTimer    = [float]0.0
        SpawnPointName      = ''
        IsSpawned           = [bool]$false
    }

    if ($npc.State -eq 'Talking') {
        $npc.InteractionTimer = [float]$script:NPCTalkDuration
    }
    elseif ($npc.State -eq 'Trading') {
        $npc.InteractionTimer = [float]$script:NPCTradeDuration
    }

    return $npc
}

function Spawn-NPC {
    <#
    .SYNOPSIS
        Adds an NPC to the active NPC system.
    .DESCRIPTION
        Accepts an existing NPC object or creates one from parameters.
    #>
    param(
        $NPC = $null,
        [string]$Name = '',
        [float]$X = 0,
        [float]$Y = 70,
        [float]$Z = 0,
        [float]$WanderRadius = $script:NPCDefaultWanderRadius,
        [float]$WanderSpeed = $script:NPCDefaultWanderSpeed,
        [float]$InteractionDistance = $script:NPCDefaultInteractionDistance,
        [bool]$CanTrade = $false,
        [string]$Model = 'Villager',
        [string]$Outfit = 'Default',
        [string]$PrimaryColor = 'Brown',
        [string]$SecondaryColor = 'Beige'
    )

    if ($null -eq $NPC) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $Name = "NPC $($script:NPCNextId)"
        }

        $NPC = New-NPC `
            -Name $Name `
            -X $X -Y $Y -Z $Z `
            -WanderRadius $WanderRadius `
            -WanderSpeed $WanderSpeed `
            -InteractionDistance $InteractionDistance `
            -CanTrade:$CanTrade `
            -Model $Model `
            -Outfit $Outfit `
            -PrimaryColor $PrimaryColor `
            -SecondaryColor $SecondaryColor
    }

    if ($null -eq $NPC) { return $null }

    Ensure-NPCEntityDefaults -NPC $NPC
    $NPC.IsSpawned = $true

    $alreadyTracked = $false
    foreach ($existing in $script:NPCEntities) {
        if ($null -ne $existing -and [int]$existing.Id -eq [int]$NPC.Id) {
            $alreadyTracked = $true
            break
        }
    }

    if (-not $alreadyTracked) {
        $script:NPCEntities += $NPC
    }

    return $NPC
}

function Register-NPCSpawnPoint {
    <#
    .SYNOPSIS
        Registers or replaces a named NPC spawn point.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][float]$X,
        [float]$Y = 70,
        [Parameter(Mandatory = $true)][float]$Z,
        [float]$Radius = $script:NPCDefaultWanderRadius,
        [string[]]$Tags = @()
    )

    if ($Radius -lt 0) { $Radius = [float]0.0 }

    $spawnPoint = [PSCustomObject]@{
        Name     = [string]$Name
        Position = New-NPCPosition -X $X -Y $Y -Z $Z
        Radius   = [float]$Radius
        Tags     = @($Tags)
    }

    $key = $Name.Trim().ToLowerInvariant()
    $script:NPCSpawnPoints[$key] = $spawnPoint
    return $spawnPoint
}

function Get-NPCSpawnPoints {
    <#
    .SYNOPSIS
        Returns all registered NPC spawn points.
    #>

    $result = @()
    foreach ($point in $script:NPCSpawnPoints.Values) {
        $result += $point
    }

    return ,$result
}

function Spawn-NPCAtPoint {
    <#
    .SYNOPSIS
        Spawns an NPC at a registered spawn point.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SpawnPointName,
        [string]$Name = '',
        [float]$WanderRadius = -1,
        [float]$WanderSpeed = $script:NPCDefaultWanderSpeed,
        [float]$InteractionDistance = $script:NPCDefaultInteractionDistance,
        [bool]$CanTrade = $false,
        [string]$Model = 'Villager',
        [string]$Outfit = 'Default',
        [string]$PrimaryColor = 'Brown',
        [string]$SecondaryColor = 'Beige'
    )

    $spawnPoint = Get-NPCSpawnPointInternal -Name $SpawnPointName
    if ($null -eq $spawnPoint) {
        Write-Warning "[NPC] Spawn point '$SpawnPointName' not found."
        return $null
    }

    [float]$radiusToUse = [float]$WanderRadius
    if ($radiusToUse -lt 0) {
        $radiusToUse = [float]$spawnPoint.Radius
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = "NPC $($script:NPCNextId)"
    }

    $npc = Spawn-NPC `
        -Name $Name `
        -X ([float]$spawnPoint.Position.X) `
        -Y ([float]$spawnPoint.Position.Y) `
        -Z ([float]$spawnPoint.Position.Z) `
        -WanderRadius $radiusToUse `
        -WanderSpeed $WanderSpeed `
        -InteractionDistance $InteractionDistance `
        -CanTrade:$CanTrade `
        -Model $Model `
        -Outfit $Outfit `
        -PrimaryColor $PrimaryColor `
        -SecondaryColor $SecondaryColor

    if ($null -ne $npc) {
        $npc.SpawnPointName = [string]$spawnPoint.Name
    }

    return $npc
}

function Get-NPCs {
    <#
    .SYNOPSIS
        Returns all currently spawned NPC entities.
    #>

    $result = @()
    foreach ($npc in $script:NPCEntities) {
        if ($null -ne $npc) {
            $result += $npc
        }
    }

    return ,$result
}

function Get-NearestNPC {
    <#
    .SYNOPSIS
        Returns nearest NPC in range for interaction checks.
    #>
    param(
        $PlayerPosition = $null,
        [float]$MaxDistance = $script:NPCDefaultInteractionDistance,
        [switch]$IncludeBusy
    )

    if ($MaxDistance -lt 0) { $MaxDistance = [float]0.0 }

    $playerPos = Get-NPCPlayerPosition -PlayerPosition $PlayerPosition
    if ($null -eq $playerPos) { return $null }

    $bestNPC = $null
    [float]$bestDistance = [float]999999.0

    foreach ($npc in $script:NPCEntities) {
        if ($null -eq $npc) { continue }

        Ensure-NPCEntityDefaults -NPC $npc
        if (-not $npc.IsSpawned) { continue }

        if (-not $IncludeBusy -and ($npc.State -eq 'Talking' -or $npc.State -eq 'Trading')) {
            continue
        }

        [float]$distance = Get-NPCDistance -From $playerPos -To $npc.Position
        if ($distance -le $MaxDistance -and $distance -lt $bestDistance) {
            $bestDistance = [float]$distance
            $bestNPC = $npc
        }
    }

    if ($null -eq $bestNPC) { return $null }

    return [PSCustomObject]@{
        NPC      = $bestNPC
        Distance = [float]$bestDistance
    }
}

function Update-NPCSystem {
    <#
    .SYNOPSIS
        Per-frame NPC update with simple local wander behavior.
    .DESCRIPTION
        Talking and Trading temporarily suspend movement. Idle NPCs wander in
        random paths within WanderRadius around SpawnPosition.
    #>
    param($dt)

    if ($null -eq $dt) { return }
    if ($dt -le 0) { return }
    if ($dt -gt 0.1) { $dt = 0.1 }

    foreach ($npc in $script:NPCEntities) {
        if ($null -eq $npc) { continue }

        Ensure-NPCEntityDefaults -NPC $npc
        if (-not $npc.IsSpawned) { continue }

        if ($npc.State -eq 'Talking' -or $npc.State -eq 'Trading') {
            $npc.InteractionTimer = [float]($npc.InteractionTimer - $dt)
            if ($npc.InteractionTimer -le 0) {
                $npc.State = 'Idle'
                $npc.InteractionTimer = [float]0.0
                $npc.WanderPauseTimer = Get-NPCPauseDuration
            }
            continue
        }

        if ($npc.State -ne 'Idle') {
            $npc.State = 'Idle'
        }

        if ($npc.WanderPauseTimer -gt 0) {
            $npc.WanderPauseTimer = [float]($npc.WanderPauseTimer - $dt)
            if ($npc.WanderPauseTimer -lt 0) {
                $npc.WanderPauseTimer = [float]0.0
            }
        }

        if ($null -eq $npc.WanderTarget -and $npc.WanderPauseTimer -le 0) {
            $npc.WanderTarget = New-NPCWanderTarget -NPC $npc
        }

        if ($null -ne $npc.WanderTarget) {
            $reached = Move-NPCTowardTarget -NPC $npc -Target $npc.WanderTarget -dt ([float]$dt)
            if ($reached) {
                $npc.WanderTarget = $null
                $npc.WanderPauseTimer = Get-NPCPauseDuration
            }
        }
    }
}

function Try-InteractNPC {
    <#
    .SYNOPSIS
        Proximity interaction helper for NPCs.
    .DESCRIPTION
        Implements approach + interact behavior:
        - Approach: nearest NPC inside interaction distance is selected.
        - Interact: caller passes -InteractPressed to actually trigger state.
    #>
    param(
        $PlayerPosition = $null,
        [switch]$InteractPressed,
        [switch]$PreferTrading,
        [float]$InteractionDistance = $script:NPCDefaultInteractionDistance
    )

    if ($InteractionDistance -lt 0) { $InteractionDistance = [float]0.0 }

    $playerPos = Get-NPCPlayerPosition -PlayerPosition $PlayerPosition
    if ($null -eq $playerPos) {
        return [PSCustomObject]@{
            Success            = $false
            CanInteract        = $false
            RequiresInteractKey = $true
            Reason             = 'NoPlayerPosition'
            NPC                = $null
            Distance           = [float]0.0
        }
    }

    $candidate = Get-NearestNPC -PlayerPosition $playerPos -MaxDistance $InteractionDistance -IncludeBusy
    if ($null -eq $candidate) {
        return [PSCustomObject]@{
            Success            = $false
            CanInteract        = $false
            RequiresInteractKey = $true
            Reason             = 'NoNPCInRange'
            NPC                = $null
            Distance           = [float]0.0
        }
    }

    $npc = $candidate.NPC
    [float]$distance = [float]$candidate.Distance

    if (-not $InteractPressed) {
        return [PSCustomObject]@{
            Success            = $false
            CanInteract        = $true
            RequiresInteractKey = $true
            Reason             = 'InteractKeyNotPressed'
            NPC                = $npc
            Distance           = [float]$distance
        }
    }

    if ($PreferTrading -and $npc.CanTrade) {
        $npc.State = 'Trading'
        $npc.InteractionTimer = [float]$script:NPCTradeDuration
    }
    else {
        $npc.State = 'Talking'
        $npc.InteractionTimer = [float]$script:NPCTalkDuration
    }

    $npc.WanderTarget = $null
    $npc.WanderPauseTimer = Get-NPCPauseDuration

    return [PSCustomObject]@{
        Success            = $true
        CanInteract        = $true
        RequiresInteractKey = $true
        Reason             = 'Interacted'
        NPC                = $npc
        Distance           = [float]$distance
    }
}
