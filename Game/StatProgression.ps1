# ============================================================================
# Game/StatProgression.ps1 - Core Stat Progression (Task 40)
# ============================================================================
# Provides:
# - Four deterministic player stats: Strength, Dexterity, Vitality, Intelligence
# - Stat points earned on level up
# - Gameplay formulas for base damage, max HP, and max mana
# - Stat allocation gate APIs and UI-facing data model
# - Stat reset API with deterministic cost gate
#
# Notes:
# - This module keeps scope focused on progression/state only.
# - No level-up visuals and no active-skill effect logic are included.
# ============================================================================

# --- Module State ---
$script:StatProgressionInitialized = $false
$script:StatProgressionDefaultPlayer = $null
$script:StatPointsPerLevelDefault = [int]3
$script:StatResetBaseCost = [int]100
$script:StatResetCostPerLevel = [int]25
$script:StatMinimumValue = [int]1
$script:StatDefinitionOrder = @('Strength', 'Dexterity', 'Vitality', 'Intelligence')
$script:StatDefinitionMap = @{}

# Preserve upstream New-Player if another module already defined it.
if (-not (Get-Variable -Name StatProgressionUpstreamNewPlayer -Scope Script -ErrorAction SilentlyContinue)) {
    $script:StatProgressionUpstreamNewPlayer = $null
}

$existingNewPlayerCommand = Get-Command -Name 'New-Player' -CommandType Function -ErrorAction SilentlyContinue
if ($null -ne $existingNewPlayerCommand -and $null -eq $script:StatProgressionUpstreamNewPlayer) {
    $existingFile = ''
    if ($null -ne $existingNewPlayerCommand.ScriptBlock) {
        $existingFile = [string]$existingNewPlayerCommand.ScriptBlock.File
    }

    if (-not [string]::Equals($existingFile, [string]$PSCommandPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:StatProgressionUpstreamNewPlayer = $existingNewPlayerCommand.ScriptBlock
    }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function ConvertTo-StatInt {
    param(
        $Value,
        [int]$Default = 0
    )

    if ($null -eq $Value) {
        return [int]$Default
    }

    try {
        return [int]$Value
    }
    catch {
        return [int]$Default
    }
}

function Add-StatObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    else {
        $Object.$Name = $Value
    }
}

function Get-NormalizedStatName {
    param([string]$StatName)

    if ([string]::IsNullOrWhiteSpace($StatName)) {
        return ''
    }

    foreach ($name in @($script:StatDefinitionOrder)) {
        if ([string]::Equals([string]$name, [string]$StatName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$name
        }
    }

    return ''
}

function Add-StatPlayerScriptMethods {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    $Player | Add-Member -MemberType ScriptMethod -Name GetBaseDamage -Value {
        return (Get-PlayerBaseDamage -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetMaxHP -Value {
        return (Get-PlayerMaxHP -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetMaxMana -Value {
        return (Get-PlayerMaxMana -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetDerivedStats -Value {
        return (Get-PlayerDerivedStats -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetStatPoints -Value {
        return (Get-PlayerStatPointSummary -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name AllocateStat -Value {
        param(
            [string]$StatName,
            [int]$Points = 1
        )

        return (Allocate-PlayerStat -Player $this -StatName $StatName -Points $Points)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name AllocateStats -Value {
        param($AllocationMap)

        return (Allocate-PlayerStats -Player $this -AllocationMap $AllocationMap)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetStatAllocationUI -Value {
        return (Get-StatAllocationUIModel -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name LevelUp -Value {
        param([int]$Levels = 1)

        return (Add-PlayerLevel -Player $this -Levels $Levels)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name SyncLevel -Value {
        return (Sync-PlayerStatProgression -Player $this -Source 'PlayerMethodSync')
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name CanResetStats -Value {
        param([int]$Currency = 0)

        return (Can-ResetPlayerStats -Player $this -Currency $Currency)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name ResetStats -Value {
        param([int]$Currency = 0)

        return (Reset-PlayerStats -Player $this -Currency $Currency)
    } -Force
}

function Ensure-StatProgressionSystem {
    if (-not $script:StatProgressionInitialized) {
        Initialize-StatProgressionSystem -Quiet | Out-Null
    }
}

function Ensure-StatProgressionPlayerShape {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-StatProgressionSystem

    if ($Player -is [System.Collections.IDictionary]) {
        if (-not $Player.Contains('Name')) { $Player['Name'] = 'Player' }
        if (-not $Player.Contains('Level')) { $Player['Level'] = [int]1 }
        if (-not $Player.Contains('XP')) { $Player['XP'] = [int]0 }
    }
    else {
        if ($null -eq $Player.PSObject.Properties['Name']) {
            Add-StatObjectProperty -Object $Player -Name 'Name' -Value 'Player'
        }

        if ($null -eq $Player.PSObject.Properties['Level']) {
            Add-StatObjectProperty -Object $Player -Name 'Level' -Value ([int]1)
        }

        if ($null -eq $Player.PSObject.Properties['XP']) {
            Add-StatObjectProperty -Object $Player -Name 'XP' -Value ([int]0)
        }
    }

    [int]$safeLevel = ConvertTo-StatInt -Value $Player.Level -Default 1
    if ($safeLevel -lt 1) {
        $safeLevel = [int]1
    }
    $Player.Level = [int]$safeLevel

    foreach ($statName in @($script:StatDefinitionOrder)) {
        [int]$safeValue = ConvertTo-StatInt -Value $Player.$statName -Default 5
        if ($safeValue -lt $script:StatMinimumValue) {
            $safeValue = [int]$script:StatMinimumValue
        }
        Add-StatObjectProperty -Object $Player -Name $statName -Value ([int]$safeValue)

        $baseName = "Base$statName"
        [int]$baseValue = ConvertTo-StatInt -Value $Player.$baseName -Default $safeValue
        if ($baseValue -lt $script:StatMinimumValue) {
            $baseValue = [int]$script:StatMinimumValue
        }
        Add-StatObjectProperty -Object $Player -Name $baseName -Value ([int]$baseValue)
    }

    [int]$pointsPerLevel = ConvertTo-StatInt -Value $Player.StatPointsPerLevel -Default $script:StatPointsPerLevelDefault
    if ($pointsPerLevel -lt 1) {
        $pointsPerLevel = [int]1
    }
    Add-StatObjectProperty -Object $Player -Name 'StatPointsPerLevel' -Value ([int]$pointsPerLevel)

    [int]$earnedDefault = [int]([Math]::Max(0, ($safeLevel - 1) * $pointsPerLevel))
    [int]$earned = ConvertTo-StatInt -Value $Player.TotalStatPointsEarned -Default $earnedDefault
    [int]$spent = ConvertTo-StatInt -Value $Player.TotalStatPointsSpent -Default 0
    [int]$available = ConvertTo-StatInt -Value $Player.UnspentStatPoints -Default ($earned - $spent)

    if ($earned -lt 0) { $earned = [int]0 }
    if ($spent -lt 0) { $spent = [int]0 }
    if ($available -lt 0) { $available = [int]0 }

    if ($earned -lt ($spent + $available)) {
        $earned = [int]($spent + $available)
    }

    [int]$lastKnownLevel = ConvertTo-StatInt -Value $Player.LastKnownLevel -Default $safeLevel
    if ($lastKnownLevel -lt 1) { $lastKnownLevel = [int]1 }
    if ($lastKnownLevel -gt $safeLevel) { $lastKnownLevel = [int]$safeLevel }

    Add-StatObjectProperty -Object $Player -Name 'TotalStatPointsEarned' -Value ([int]$earned)
    Add-StatObjectProperty -Object $Player -Name 'TotalStatPointsSpent' -Value ([int]$spent)
    Add-StatObjectProperty -Object $Player -Name 'UnspentStatPoints' -Value ([int]$available)
    Add-StatObjectProperty -Object $Player -Name 'LastKnownLevel' -Value ([int]$lastKnownLevel)

    Add-StatPlayerScriptMethods -Player $Player
}

function Resolve-StatProgressionPlayer {
    param(
        $Player = $null,
        [switch]$CreateIfMissing
    )

    Ensure-StatProgressionSystem

    if ($null -ne $Player) {
        Ensure-StatProgressionPlayerShape -Player $Player
        return $Player
    }

    if ($null -eq $script:StatProgressionDefaultPlayer -and $CreateIfMissing) {
        $script:StatProgressionDefaultPlayer = New-Player -Name 'Player' -Level 1 -XP 0
    }

    if ($null -ne $script:StatProgressionDefaultPlayer) {
        Ensure-StatProgressionPlayerShape -Player $script:StatProgressionDefaultPlayer
    }

    return $script:StatProgressionDefaultPlayer
}

function Sync-StatsModuleSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    $getStatsCommand = Get-Command -Name 'Get-PlayerStats' -ErrorAction SilentlyContinue
    if ($null -eq $getStatsCommand) {
        return $null
    }

    $stats = Get-PlayerStats
    if ($null -eq $stats) {
        return $null
    }

    foreach ($name in @($script:StatDefinitionOrder)) {
        Add-StatObjectProperty -Object $stats -Name $name -Value ([int](ConvertTo-StatInt -Value $Player.$name -Default 1))
    }

    [int]$maxHP = Get-PlayerMaxHP -Player $Player
    [int]$maxMana = Get-PlayerMaxMana -Player $Player

    Add-StatObjectProperty -Object $stats -Name 'MaxHP' -Value ([float]$maxHP)
    Add-StatObjectProperty -Object $stats -Name 'MaxMana' -Value ([float]$maxMana)

    if ($null -ne $stats.PSObject.Properties['HP']) {
        [double]$hp = [double]$stats.HP
        if ($hp -gt [double]$maxHP) {
            $stats.HP = [float]$maxHP
        }
    }

    if ($null -ne $stats.PSObject.Properties['Mana']) {
        [double]$mana = [double]$stats.Mana
        if ($mana -gt [double]$maxMana) {
            $stats.Mana = [float]$maxMana
        }
    }

    return $stats
}

# ============================================================================
# Public API - Initialization and Definitions
# ============================================================================

function Initialize-StatProgressionSystem {
    <#
    .SYNOPSIS
        Initializes deterministic stat progression metadata.
    #>
    param([switch]$Quiet)

    $script:StatProgressionInitialized = $true
    $script:StatPointsPerLevelDefault = [int]3
    $script:StatResetBaseCost = [int]100
    $script:StatResetCostPerLevel = [int]25
    $script:StatMinimumValue = [int]1
    $script:StatDefinitionOrder = @('Strength', 'Dexterity', 'Vitality', 'Intelligence')
    $script:StatDefinitionMap = @{}

    $rows = @(
        [PSCustomObject]@{ Name = 'Strength';     Description = 'Increases base damage.';      Affects = @('Damage') },
        [PSCustomObject]@{ Name = 'Dexterity';    Description = 'Improves precision scaling.';  Affects = @('Damage') },
        [PSCustomObject]@{ Name = 'Vitality';     Description = 'Increases maximum HP.';        Affects = @('MaxHP') },
        [PSCustomObject]@{ Name = 'Intelligence'; Description = 'Increases maximum Mana.';      Affects = @('MaxMana') }
    )

    foreach ($row in @($rows)) {
        $script:StatDefinitionMap[[string]$row.Name] = $row
    }

    if (-not $Quiet) {
        Write-Host '[StatProgression] Stat progression initialized.' -ForegroundColor Green
    }

    return [PSCustomObject]@{
        StatCount         = [int]$script:StatDefinitionOrder.Count
        StatNames         = @($script:StatDefinitionOrder)
        PointsPerLevel    = [int]$script:StatPointsPerLevelDefault
        ResetBaseCost     = [int]$script:StatResetBaseCost
        ResetCostPerLevel = [int]$script:StatResetCostPerLevel
    }
}

function Get-StatDefinitions {
    <#
    .SYNOPSIS
        Returns supported stat definitions in deterministic order.
    #>

    Ensure-StatProgressionSystem

    $result = @()
    foreach ($name in @($script:StatDefinitionOrder)) {
        if ($script:StatDefinitionMap.ContainsKey($name)) {
            $result += $script:StatDefinitionMap[$name]
        }
    }

    return @($result)
}

function Get-StatNames {
    <#
    .SYNOPSIS
        Returns stat names in deterministic order.
    #>

    Ensure-StatProgressionSystem
    return @($script:StatDefinitionOrder)
}

# ============================================================================
# Public API - Derived Gameplay Formulas
# ============================================================================

function Get-PlayerBaseDamage {
    <#
    .SYNOPSIS
        Computes deterministic base damage from stats.
    .DESCRIPTION
        Formula:
          baseDamage = 5 + (Strength * 2) + floor(Dexterity / 4)
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]1
    }

    [int]$strength = ConvertTo-StatInt -Value $resolved.Strength -Default 1
    [int]$dexterity = ConvertTo-StatInt -Value $resolved.Dexterity -Default 1

    if ($strength -lt $script:StatMinimumValue) { $strength = [int]$script:StatMinimumValue }
    if ($dexterity -lt $script:StatMinimumValue) { $dexterity = [int]$script:StatMinimumValue }

    [int]$dexterityBonus = [int][Math]::Floor(([double]$dexterity) / 4.0)
    return [int][Math]::Max(1, 5 + ($strength * 2) + $dexterityBonus)
}

function Get-PlayerMaxHP {
    <#
    .SYNOPSIS
        Computes deterministic max HP from vitality and level.
    .DESCRIPTION
        Formula:
          maxHP = 100 + (Vitality * 12) + ((Level - 1) * 2)
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]100
    }

    [int]$vitality = ConvertTo-StatInt -Value $resolved.Vitality -Default 1
    [int]$level = ConvertTo-StatInt -Value $resolved.Level -Default 1

    if ($vitality -lt $script:StatMinimumValue) { $vitality = [int]$script:StatMinimumValue }
    if ($level -lt 1) { $level = [int]1 }

    return [int](100 + ($vitality * 12) + (($level - 1) * 2))
}

function Get-PlayerMaxMana {
    <#
    .SYNOPSIS
        Computes deterministic max mana from intelligence and level.
    .DESCRIPTION
        Formula:
          maxMana = 50 + (Intelligence * 10) + ((Level - 1) * 2)
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]50
    }

    [int]$intelligence = ConvertTo-StatInt -Value $resolved.Intelligence -Default 1
    [int]$level = ConvertTo-StatInt -Value $resolved.Level -Default 1

    if ($intelligence -lt $script:StatMinimumValue) { $intelligence = [int]$script:StatMinimumValue }
    if ($level -lt 1) { $level = [int]1 }

    return [int](50 + ($intelligence * 10) + (($level - 1) * 2))
}

function Get-PlayerDerivedStats {
    <#
    .SYNOPSIS
        Returns the derived gameplay values from stats.
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            BaseDamage = [int]1
            MaxHP      = [int]100
            MaxMana    = [int]50
        }
    }

    return [PSCustomObject]@{
        BaseDamage = [int](Get-PlayerBaseDamage -Player $resolved)
        MaxHP      = [int](Get-PlayerMaxHP -Player $resolved)
        MaxMana    = [int](Get-PlayerMaxMana -Player $resolved)
    }
}

# ============================================================================
# Public API - Stat Point Progression and Allocation
# ============================================================================

function Sync-PlayerStatPointsWithLevel {
    <#
    .SYNOPSIS
        Grants stat points when player level grows.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [string]$Source = 'LevelSync'
    )

    Ensure-StatProgressionPlayerShape -Player $Player

    [int]$level = ConvertTo-StatInt -Value $Player.Level -Default 1
    [int]$lastKnownLevel = ConvertTo-StatInt -Value $Player.LastKnownLevel -Default 1
    [int]$pointsPerLevel = ConvertTo-StatInt -Value $Player.StatPointsPerLevel -Default $script:StatPointsPerLevelDefault

    if ($level -lt 1) { $level = [int]1 }
    if ($lastKnownLevel -lt 1) { $lastKnownLevel = [int]1 }
    if ($pointsPerLevel -lt 1) { $pointsPerLevel = [int]1 }

    if ($level -le $lastKnownLevel) {
        return [PSCustomObject]@{
            Source          = [string]$Source
            PreviousLevel   = [int]$lastKnownLevel
            CurrentLevel    = [int]$lastKnownLevel
            LevelsGained    = [int]0
            PointsGranted   = [int]0
            AvailablePoints = [int]$Player.UnspentStatPoints
            SpentPoints     = [int]$Player.TotalStatPointsSpent
            EarnedPoints    = [int]$Player.TotalStatPointsEarned
        }
    }

    [int]$levelsGained = [int]($level - $lastKnownLevel)
    [int]$pointsGranted = [int]($levelsGained * $pointsPerLevel)

    $Player.LastKnownLevel = [int]$level
    $Player.UnspentStatPoints = [int]($Player.UnspentStatPoints + $pointsGranted)
    $Player.TotalStatPointsEarned = [int]($Player.TotalStatPointsEarned + $pointsGranted)

    return [PSCustomObject]@{
        Source          = [string]$Source
        PreviousLevel   = [int]$lastKnownLevel
        CurrentLevel    = [int]$level
        LevelsGained    = [int]$levelsGained
        PointsGranted   = [int]$pointsGranted
        AvailablePoints = [int]$Player.UnspentStatPoints
        SpentPoints     = [int]$Player.TotalStatPointsSpent
        EarnedPoints    = [int]$Player.TotalStatPointsEarned
    }
}

function Sync-PlayerStatProgression {
    <#
    .SYNOPSIS
        Public sync wrapper for external level mutation flows.
    #>
    param(
        $Player = $null,
        [string]$Source = 'ManualSync'
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return $null
    }

    $result = Sync-PlayerStatPointsWithLevel -Player $resolved -Source $Source
    Sync-StatsModuleSnapshot -Player $resolved | Out-Null
    return $result
}

function Get-PlayerStatPointSummary {
    <#
    .SYNOPSIS
        Returns available/spent/earned stat point totals.
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            Available      = [int]0
            Spent          = [int]0
            Earned         = [int]0
            PointsPerLevel = [int]$script:StatPointsPerLevelDefault
            LastKnownLevel = [int]1
        }
    }

    Sync-PlayerStatPointsWithLevel -Player $resolved -Source 'SummarySync' | Out-Null

    return [PSCustomObject]@{
        Available      = [int]$resolved.UnspentStatPoints
        Spent          = [int]$resolved.TotalStatPointsSpent
        Earned         = [int]$resolved.TotalStatPointsEarned
        PointsPerLevel = [int]$resolved.StatPointsPerLevel
        LastKnownLevel = [int]$resolved.LastKnownLevel
    }
}

function Can-AllocatePlayerStat {
    <#
    .SYNOPSIS
        Validates a single stat allocation request.
    #>
    param(
        $Player = $null,
        [string]$StatName,
        [int]$Points = 1
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            CanAllocate     = $false
            Reason          = 'PlayerNotFound'
            StatName        = [string]$StatName
            PointsRequested = [int]0
            AvailablePoints = [int]0
            CurrentValue    = [int]0
        }
    }

    Sync-PlayerStatPointsWithLevel -Player $resolved -Source 'CanAllocateSync' | Out-Null

    $normalizedStat = Get-NormalizedStatName -StatName $StatName
    [int]$safePoints = ConvertTo-StatInt -Value $Points -Default 0
    [int]$available = [int]$resolved.UnspentStatPoints

    if ([string]::IsNullOrWhiteSpace($normalizedStat)) {
        return [PSCustomObject]@{
            CanAllocate     = $false
            Reason          = 'InvalidStatName'
            StatName        = [string]$StatName
            PointsRequested = [int]$safePoints
            AvailablePoints = [int]$available
            CurrentValue    = [int]0
        }
    }

    [int]$currentValue = ConvertTo-StatInt -Value $resolved.$normalizedStat -Default $script:StatMinimumValue

    if ($safePoints -lt 1) {
        return [PSCustomObject]@{
            CanAllocate     = $false
            Reason          = 'InvalidPointAmount'
            StatName        = [string]$normalizedStat
            PointsRequested = [int]$safePoints
            AvailablePoints = [int]$available
            CurrentValue    = [int]$currentValue
        }
    }

    if ($available -lt $safePoints) {
        return [PSCustomObject]@{
            CanAllocate     = $false
            Reason          = 'InsufficientStatPoints'
            StatName        = [string]$normalizedStat
            PointsRequested = [int]$safePoints
            AvailablePoints = [int]$available
            CurrentValue    = [int]$currentValue
        }
    }

    return [PSCustomObject]@{
        CanAllocate     = $true
        Reason          = 'OK'
        StatName        = [string]$normalizedStat
        PointsRequested = [int]$safePoints
        AvailablePoints = [int]$available
        CurrentValue    = [int]$currentValue
    }
}

function Allocate-PlayerStat {
    <#
    .SYNOPSIS
        Applies a single stat allocation if validation passes.
    #>
    param(
        $Player = $null,
        [string]$StatName,
        [int]$Points = 1
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            Applied         = $false
            Reason          = 'PlayerNotFound'
            StatName        = [string]$StatName
            PointsSpent     = [int]0
            NewValue        = [int]0
            AvailablePoints = [int]0
            SpentPoints     = [int]0
            EarnedPoints    = [int]0
        }
    }

    $gate = Can-AllocatePlayerStat -Player $resolved -StatName $StatName -Points $Points
    if (-not [bool]$gate.CanAllocate) {
        return [PSCustomObject]@{
            Applied         = $false
            Reason          = [string]$gate.Reason
            StatName        = [string]$gate.StatName
            PointsSpent     = [int]0
            NewValue        = [int]$gate.CurrentValue
            AvailablePoints = [int]$resolved.UnspentStatPoints
            SpentPoints     = [int]$resolved.TotalStatPointsSpent
            EarnedPoints    = [int]$resolved.TotalStatPointsEarned
        }
    }

    [int]$nextValue = [int](ConvertTo-StatInt -Value $resolved.$($gate.StatName) -Default $script:StatMinimumValue) + [int]$gate.PointsRequested
    $resolved.$($gate.StatName) = [int]$nextValue

    $resolved.UnspentStatPoints = [int]($resolved.UnspentStatPoints - $gate.PointsRequested)
    if ($resolved.UnspentStatPoints -lt 0) {
        $resolved.UnspentStatPoints = [int]0
    }

    $resolved.TotalStatPointsSpent = [int]($resolved.TotalStatPointsSpent + $gate.PointsRequested)

    Sync-StatsModuleSnapshot -Player $resolved | Out-Null

    return [PSCustomObject]@{
        Applied         = $true
        Reason          = 'Allocated'
        StatName        = [string]$gate.StatName
        PointsSpent     = [int]$gate.PointsRequested
        NewValue        = [int]$nextValue
        AvailablePoints = [int]$resolved.UnspentStatPoints
        SpentPoints     = [int]$resolved.TotalStatPointsSpent
        EarnedPoints    = [int]$resolved.TotalStatPointsEarned
        DerivedStats    = Get-PlayerDerivedStats -Player $resolved
    }
}

function Allocate-PlayerStats {
    <#
    .SYNOPSIS
        Applies a validated bulk stat allocation map.
    #>
    param(
        $Player = $null,
        $AllocationMap
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            Applied            = $false
            Reason             = 'PlayerNotFound'
            PointsSpent        = [int]0
            AvailablePoints    = [int]0
            SpentPoints        = [int]0
            EarnedPoints       = [int]0
            AppliedAllocations = @()
        }
    }

    if ($null -eq $AllocationMap) {
        return [PSCustomObject]@{
            Applied            = $false
            Reason             = 'NoAllocationData'
            PointsSpent        = [int]0
            AvailablePoints    = [int]$resolved.UnspentStatPoints
            SpentPoints        = [int]$resolved.TotalStatPointsSpent
            EarnedPoints       = [int]$resolved.TotalStatPointsEarned
            AppliedAllocations = @()
        }
    }

    Sync-PlayerStatPointsWithLevel -Player $resolved -Source 'BulkAllocateSync' | Out-Null

    $requestMap = @{}

    if ($AllocationMap -is [System.Collections.IDictionary]) {
        foreach ($key in @($AllocationMap.Keys)) {
            $normalized = Get-NormalizedStatName -StatName ([string]$key)
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                return [PSCustomObject]@{
                    Applied            = $false
                    Reason             = 'InvalidStatName'
                    InvalidStatName    = [string]$key
                    PointsSpent        = [int]0
                    AvailablePoints    = [int]$resolved.UnspentStatPoints
                    SpentPoints        = [int]$resolved.TotalStatPointsSpent
                    EarnedPoints       = [int]$resolved.TotalStatPointsEarned
                    AppliedAllocations = @()
                }
            }

            [int]$amount = ConvertTo-StatInt -Value $AllocationMap[$key] -Default 0
            if ($amount -lt 1) {
                return [PSCustomObject]@{
                    Applied            = $false
                    Reason             = 'InvalidPointAmount'
                    InvalidStatName    = [string]$normalized
                    PointsSpent        = [int]0
                    AvailablePoints    = [int]$resolved.UnspentStatPoints
                    SpentPoints        = [int]$resolved.TotalStatPointsSpent
                    EarnedPoints       = [int]$resolved.TotalStatPointsEarned
                    AppliedAllocations = @()
                }
            }

            if (-not $requestMap.ContainsKey($normalized)) {
                $requestMap[$normalized] = [int]0
            }
            $requestMap[$normalized] = [int]($requestMap[$normalized] + $amount)
        }
    }
    else {
        foreach ($prop in @($AllocationMap.PSObject.Properties)) {
            $normalized = Get-NormalizedStatName -StatName ([string]$prop.Name)
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                continue
            }

            [int]$amount = ConvertTo-StatInt -Value $prop.Value -Default 0
            if ($amount -lt 1) {
                return [PSCustomObject]@{
                    Applied            = $false
                    Reason             = 'InvalidPointAmount'
                    InvalidStatName    = [string]$normalized
                    PointsSpent        = [int]0
                    AvailablePoints    = [int]$resolved.UnspentStatPoints
                    SpentPoints        = [int]$resolved.TotalStatPointsSpent
                    EarnedPoints       = [int]$resolved.TotalStatPointsEarned
                    AppliedAllocations = @()
                }
            }

            if (-not $requestMap.ContainsKey($normalized)) {
                $requestMap[$normalized] = [int]0
            }
            $requestMap[$normalized] = [int]($requestMap[$normalized] + $amount)
        }
    }

    if ($requestMap.Count -eq 0) {
        return [PSCustomObject]@{
            Applied            = $false
            Reason             = 'NoAllocationData'
            PointsSpent        = [int]0
            AvailablePoints    = [int]$resolved.UnspentStatPoints
            SpentPoints        = [int]$resolved.TotalStatPointsSpent
            EarnedPoints       = [int]$resolved.TotalStatPointsEarned
            AppliedAllocations = @()
        }
    }

    [int]$totalRequested = 0
    foreach ($statName in @($script:StatDefinitionOrder)) {
        if ($requestMap.ContainsKey($statName)) {
            $totalRequested = [int]($totalRequested + [int]$requestMap[$statName])
        }
    }

    if ($resolved.UnspentStatPoints -lt $totalRequested) {
        return [PSCustomObject]@{
            Applied            = $false
            Reason             = 'InsufficientStatPoints'
            PointsSpent        = [int]0
            PointsRequested    = [int]$totalRequested
            AvailablePoints    = [int]$resolved.UnspentStatPoints
            SpentPoints        = [int]$resolved.TotalStatPointsSpent
            EarnedPoints       = [int]$resolved.TotalStatPointsEarned
            AppliedAllocations = @()
        }
    }

    $appliedRows = @()
    foreach ($statName in @($script:StatDefinitionOrder)) {
        if (-not $requestMap.ContainsKey($statName)) {
            continue
        }

        [int]$amount = [int]$requestMap[$statName]
        [int]$nextValue = [int](ConvertTo-StatInt -Value $resolved.$statName -Default $script:StatMinimumValue) + $amount
        $resolved.$statName = [int]$nextValue

        $appliedRows += [PSCustomObject]@{
            StatName = [string]$statName
            Points   = [int]$amount
            NewValue = [int]$nextValue
        }
    }

    $resolved.UnspentStatPoints = [int]($resolved.UnspentStatPoints - $totalRequested)
    if ($resolved.UnspentStatPoints -lt 0) {
        $resolved.UnspentStatPoints = [int]0
    }

    $resolved.TotalStatPointsSpent = [int]($resolved.TotalStatPointsSpent + $totalRequested)

    Sync-StatsModuleSnapshot -Player $resolved | Out-Null

    return [PSCustomObject]@{
        Applied            = $true
        Reason             = 'Allocated'
        PointsSpent        = [int]$totalRequested
        AvailablePoints    = [int]$resolved.UnspentStatPoints
        SpentPoints        = [int]$resolved.TotalStatPointsSpent
        EarnedPoints       = [int]$resolved.TotalStatPointsEarned
        AppliedAllocations = @($appliedRows)
        DerivedStats       = Get-PlayerDerivedStats -Player $resolved
    }
}

# ============================================================================
# Public API - Reset Gate and UI Model
# ============================================================================

function Get-StatResetCost {
    <#
    .SYNOPSIS
        Returns deterministic stat reset currency cost.
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]$script:StatResetBaseCost
    }

    [int]$level = ConvertTo-StatInt -Value $resolved.Level -Default 1
    if ($level -lt 1) {
        $level = [int]1
    }

    return [int]($script:StatResetBaseCost + ($level * $script:StatResetCostPerLevel))
}

function Can-ResetPlayerStats {
    <#
    .SYNOPSIS
        Evaluates reset gate status using provided currency.
    #>
    param(
        $Player = $null,
        [int]$Currency = 0
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            CanReset       = $false
            Reason         = 'PlayerNotFound'
            ResetCost      = [int]0
            CurrencyPaid   = [int]0
            CurrencyNeeded = [int]0
            RefundPoints   = [int]0
        }
    }

    Sync-PlayerStatPointsWithLevel -Player $resolved -Source 'CanResetSync' | Out-Null

    [int]$cost = Get-StatResetCost -Player $resolved
    [int]$paid = ConvertTo-StatInt -Value $Currency -Default 0
    if ($paid -lt 0) {
        $paid = [int]0
    }

    [int]$refundPoints = [int]$resolved.TotalStatPointsSpent

    if ($paid -lt $cost) {
        return [PSCustomObject]@{
            CanReset       = $false
            Reason         = 'ResetCostNotPaid'
            ResetCost      = [int]$cost
            CurrencyPaid   = [int]$paid
            CurrencyNeeded = [int]($cost - $paid)
            RefundPoints   = [int]$refundPoints
        }
    }

    return [PSCustomObject]@{
        CanReset       = $true
        Reason         = 'OK'
        ResetCost      = [int]$cost
        CurrencyPaid   = [int]$paid
        CurrencyNeeded = [int]0
        RefundPoints   = [int]$refundPoints
    }
}

function Reset-PlayerStats {
    <#
    .SYNOPSIS
        Resets current stats to base values when cost is paid.
    #>
    param(
        $Player = $null,
        [int]$Currency = 0
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            Reset           = $false
            Reason          = 'PlayerNotFound'
            ResetCost       = [int]0
            CurrencyPaid    = [int]0
            CurrencyNeeded  = [int]0
            RefundedPoints  = [int]0
            AvailablePoints = [int]0
            SpentPoints     = [int]0
        }
    }

    $gate = Can-ResetPlayerStats -Player $resolved -Currency $Currency
    if (-not [bool]$gate.CanReset) {
        return [PSCustomObject]@{
            Reset           = $false
            Reason          = [string]$gate.Reason
            ResetCost       = [int]$gate.ResetCost
            CurrencyPaid    = [int]$gate.CurrencyPaid
            CurrencyNeeded  = [int]$gate.CurrencyNeeded
            RefundedPoints  = [int]0
            AvailablePoints = [int]$resolved.UnspentStatPoints
            SpentPoints     = [int]$resolved.TotalStatPointsSpent
        }
    }

    [int]$refunded = [int]$resolved.TotalStatPointsSpent

    foreach ($statName in @($script:StatDefinitionOrder)) {
        $baseName = "Base$statName"
        [int]$baseValue = ConvertTo-StatInt -Value $resolved.$baseName -Default $script:StatMinimumValue
        if ($baseValue -lt $script:StatMinimumValue) {
            $baseValue = [int]$script:StatMinimumValue
        }

        $resolved.$statName = [int]$baseValue
    }

    $resolved.UnspentStatPoints = [int]($resolved.UnspentStatPoints + $refunded)
    $resolved.TotalStatPointsSpent = [int]0

    Sync-StatsModuleSnapshot -Player $resolved | Out-Null

    return [PSCustomObject]@{
        Reset           = $true
        Reason          = 'ResetComplete'
        ResetCost       = [int]$gate.ResetCost
        CurrencyPaid    = [int]$gate.CurrencyPaid
        CurrencyNeeded  = [int]0
        RefundedPoints  = [int]$refunded
        AvailablePoints = [int]$resolved.UnspentStatPoints
        SpentPoints     = [int]$resolved.TotalStatPointsSpent
        DerivedStats    = Get-PlayerDerivedStats -Player $resolved
    }
}

function Get-StatAllocationUIModel {
    <#
    .SYNOPSIS
        Returns UI-facing stat allocation metadata and API map.
    #>
    param($Player = $null)

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [PSCustomObject]@{
            StatCount = [int]$script:StatDefinitionOrder.Count
            Stats     = @()
            Points    = [PSCustomObject]@{ Available = 0; Spent = 0; Earned = 0; PointsPerLevel = $script:StatPointsPerLevelDefault }
            Reset     = [PSCustomObject]@{ Cost = $script:StatResetBaseCost; LastFailReason = 'ResetCostNotPaid' }
            Api       = [PSCustomObject]@{}
        }
    }

    Sync-PlayerStatPointsWithLevel -Player $resolved -Source 'UISync' | Out-Null

    $rows = @()
    foreach ($name in @($script:StatDefinitionOrder)) {
        $definition = $script:StatDefinitionMap[$name]
        $rows += [PSCustomObject]@{
            Name        = [string]$name
            Value       = [int](ConvertTo-StatInt -Value $resolved.$name -Default $script:StatMinimumValue)
            BaseValue   = [int](ConvertTo-StatInt -Value $resolved."Base$name" -Default $script:StatMinimumValue)
            MinValue    = [int]$script:StatMinimumValue
            Description = [string]$definition.Description
            Affects     = @($definition.Affects)
        }
    }

    return [PSCustomObject]@{
        StatCount = [int]$rows.Count
        Stats     = @($rows)
        Points    = [PSCustomObject]@{
            Available      = [int]$resolved.UnspentStatPoints
            Spent          = [int]$resolved.TotalStatPointsSpent
            Earned         = [int]$resolved.TotalStatPointsEarned
            PointsPerLevel = [int]$resolved.StatPointsPerLevel
            LastKnownLevel = [int]$resolved.LastKnownLevel
        }
        Reset     = [PSCustomObject]@{
            Cost           = [int](Get-StatResetCost -Player $resolved)
            LastFailReason = 'ResetCostNotPaid'
        }
        Derived   = Get-PlayerDerivedStats -Player $resolved
        Api       = [PSCustomObject]@{
            AllocateStat    = 'Allocate-PlayerStat'
            AllocateStats   = 'Allocate-PlayerStats'
            CanAllocateStat = 'Can-AllocatePlayerStat'
            ResetStats      = 'Reset-PlayerStats'
            CanResetStats   = 'Can-ResetPlayerStats'
            SyncLevel       = 'Sync-PlayerStatProgression'
        }
    }
}

# ============================================================================
# Public API - Player Construction and Leveling
# ============================================================================

function New-Player {
    <#
    .SYNOPSIS
        Creates or augments a player object with stat progression fields.
    .DESCRIPTION
        Compatibility behavior:
        - If an upstream New-Player constructor exists, it is used first.
        - This function then attaches stat progression properties and methods.
    #>
    param(
        [string]$Name = 'Player',
        [int]$Level = 1,
        [int]$XP = 0,
        [int]$Strength = 5,
        [int]$Dexterity = 5,
        [int]$Vitality = 5,
        [int]$Intelligence = 5,
        [int]$StatPointsPerLevel = 3,
        [int]$UnspentStatPoints = -1,
        [switch]$SetActive
    )

    Ensure-StatProgressionSystem

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'Player'
    }

    [int]$safeLevel = ConvertTo-StatInt -Value $Level -Default 1
    if ($safeLevel -lt 1) { $safeLevel = [int]1 }

    [int]$safeXP = ConvertTo-StatInt -Value $XP -Default 0
    if ($safeXP -lt 0) { $safeXP = [int]0 }

    [int]$safeStrength = ConvertTo-StatInt -Value $Strength -Default 5
    [int]$safeDexterity = ConvertTo-StatInt -Value $Dexterity -Default 5
    [int]$safeVitality = ConvertTo-StatInt -Value $Vitality -Default 5
    [int]$safeIntelligence = ConvertTo-StatInt -Value $Intelligence -Default 5

    if ($safeStrength -lt $script:StatMinimumValue) { $safeStrength = [int]$script:StatMinimumValue }
    if ($safeDexterity -lt $script:StatMinimumValue) { $safeDexterity = [int]$script:StatMinimumValue }
    if ($safeVitality -lt $script:StatMinimumValue) { $safeVitality = [int]$script:StatMinimumValue }
    if ($safeIntelligence -lt $script:StatMinimumValue) { $safeIntelligence = [int]$script:StatMinimumValue }

    [int]$safePointsPerLevel = ConvertTo-StatInt -Value $StatPointsPerLevel -Default $script:StatPointsPerLevelDefault
    if ($safePointsPerLevel -lt 1) {
        $safePointsPerLevel = [int]1
    }

    [int]$earnedByLevel = [int]([Math]::Max(0, ($safeLevel - 1) * $safePointsPerLevel))
    [int]$safeUnspent = ConvertTo-StatInt -Value $UnspentStatPoints -Default (-1)
    [int]$spentAtCreate = [int]0

    if ($safeUnspent -lt 0) {
        $safeUnspent = [int]$earnedByLevel
        $spentAtCreate = [int]0
    }
    else {
        if ($safeUnspent -lt 0) {
            $safeUnspent = [int]0
        }

        if ($safeUnspent -gt $earnedByLevel) {
            $earnedByLevel = [int]$safeUnspent
        }

        $spentAtCreate = [int]($earnedByLevel - $safeUnspent)
        if ($spentAtCreate -lt 0) {
            $spentAtCreate = [int]0
        }
    }

    $player = $null

    if ($null -ne $script:StatProgressionUpstreamNewPlayer) {
        try {
            $player = & $script:StatProgressionUpstreamNewPlayer -Name $Name -Level $safeLevel -XP $safeXP -SetActive:$SetActive
        }
        catch {
            $player = $null
        }
    }

    if ($null -eq $player) {
        $player = [PSCustomObject]@{
            Name  = [string]$Name.Trim()
            Level = [int]$safeLevel
            XP    = [int]$safeXP
        }
    }

    Add-StatObjectProperty -Object $player -Name 'Name' -Value ([string]$Name.Trim())
    Add-StatObjectProperty -Object $player -Name 'Level' -Value ([int]$safeLevel)
    Add-StatObjectProperty -Object $player -Name 'XP' -Value ([int]$safeXP)

    Add-StatObjectProperty -Object $player -Name 'Strength' -Value ([int]$safeStrength)
    Add-StatObjectProperty -Object $player -Name 'Dexterity' -Value ([int]$safeDexterity)
    Add-StatObjectProperty -Object $player -Name 'Vitality' -Value ([int]$safeVitality)
    Add-StatObjectProperty -Object $player -Name 'Intelligence' -Value ([int]$safeIntelligence)

    Add-StatObjectProperty -Object $player -Name 'BaseStrength' -Value ([int]$safeStrength)
    Add-StatObjectProperty -Object $player -Name 'BaseDexterity' -Value ([int]$safeDexterity)
    Add-StatObjectProperty -Object $player -Name 'BaseVitality' -Value ([int]$safeVitality)
    Add-StatObjectProperty -Object $player -Name 'BaseIntelligence' -Value ([int]$safeIntelligence)

    Add-StatObjectProperty -Object $player -Name 'StatPointsPerLevel' -Value ([int]$safePointsPerLevel)
    Add-StatObjectProperty -Object $player -Name 'TotalStatPointsEarned' -Value ([int]$earnedByLevel)
    Add-StatObjectProperty -Object $player -Name 'TotalStatPointsSpent' -Value ([int]$spentAtCreate)
    Add-StatObjectProperty -Object $player -Name 'UnspentStatPoints' -Value ([int]$safeUnspent)
    Add-StatObjectProperty -Object $player -Name 'LastKnownLevel' -Value ([int]$safeLevel)

    Ensure-StatProgressionPlayerShape -Player $player

    if ($SetActive -or $null -eq $script:StatProgressionDefaultPlayer) {
        $script:StatProgressionDefaultPlayer = $player
    }

    Sync-StatsModuleSnapshot -Player $player | Out-Null

    return $player
}

function Enable-PlayerStatProgression {
    <#
    .SYNOPSIS
        Adds stat progression fields/methods to an existing player object.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [switch]$SetActive
    )

    Ensure-StatProgressionPlayerShape -Player $Player

    if ($SetActive -or $null -eq $script:StatProgressionDefaultPlayer) {
        $script:StatProgressionDefaultPlayer = $Player
    }

    Sync-StatsModuleSnapshot -Player $Player | Out-Null
    return $Player
}

function Get-ActivePlayer {
    <#
    .SYNOPSIS
        Gets active stat progression player.
    #>

    return (Resolve-StatProgressionPlayer -CreateIfMissing)
}

function Set-ActivePlayer {
    <#
    .SYNOPSIS
        Sets active stat progression player.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-StatProgressionPlayerShape -Player $Player
    $script:StatProgressionDefaultPlayer = $Player
    Sync-StatsModuleSnapshot -Player $Player | Out-Null
    return $true
}

function Add-PlayerLevel {
    <#
    .SYNOPSIS
        Levels up the player and grants stat points.
    #>
    param(
        $Player = $null,
        [int]$Levels = 1,
        [string]$Source = 'LevelUp'
    )

    $resolved = Resolve-StatProgressionPlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return $null
    }

    [int]$safeLevels = ConvertTo-StatInt -Value $Levels -Default 0
    if ($safeLevels -lt 0) {
        $safeLevels = [int]0
    }

    [int]$beforeLevel = ConvertTo-StatInt -Value $resolved.Level -Default 1
    if ($safeLevels -gt 0) {
        $resolved.Level = [int]($beforeLevel + $safeLevels)
    }

    $sync = Sync-PlayerStatPointsWithLevel -Player $resolved -Source $Source
    Sync-StatsModuleSnapshot -Player $resolved | Out-Null

    return [PSCustomObject]@{
        Source          = [string]$Source
        PreviousLevel   = [int]$beforeLevel
        CurrentLevel    = [int]$resolved.Level
        LevelsGained    = [int]$sync.LevelsGained
        PointsGranted   = [int]$sync.PointsGranted
        AvailablePoints = [int]$resolved.UnspentStatPoints
        SpentPoints     = [int]$resolved.TotalStatPointsSpent
        EarnedPoints    = [int]$resolved.TotalStatPointsEarned
    }
}

# Initialize on dot-source.
Initialize-StatProgressionSystem -Quiet | Out-Null
