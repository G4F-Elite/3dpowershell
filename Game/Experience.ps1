# ============================================================================
# Game/Experience.ps1 - Experience and Level Progression System
# ============================================================================
# Provides:
# - Deterministic XP requirements per level
# - XP gain hooks for combat, quests, and gathering
# - Level-up notifications and event history
# - Feature unlock metadata by level
# - Max level cap enforcement (50)
#
# Compatibility hooks:
# - Add-PlayerXP / Add-XP / Add-Experience / Add-PlayerExperience
# - Get-PlayerXP
# ============================================================================

# --- Module State ---
$script:ExperienceSystemInitialized = $false
$script:ExperienceMaxLevel = [int]50
$script:ExperienceXPTable = @{}
$script:ExperienceUnlockMap = @{}
$script:ExperienceDefaultPlayer = $null
$script:ExperienceLevelUpHistory = [System.Collections.ArrayList]::new()
$script:ExperienceLevelUpCallbacks = @()

# ============================================================================
# Internal Helpers
# ============================================================================

function ConvertTo-ExperienceInt {
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

function Get-ExperiencePlayerName {
    param($Player)

    if ($null -eq $Player) {
        return 'Player'
    }

    if ($null -ne $Player.PSObject.Properties['Name']) {
        $name = [string]$Player.Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }
    }

    return 'Player'
}

function Add-ExperienceObjectProperty {
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

function Get-XPRequiredForNextLevelRaw {
    param([int]$Level)

    if ($Level -lt 1) {
        $Level = [int]1
    }

    if ($Level -ge $script:ExperienceMaxLevel) {
        return [int]0
    }

    # Deterministic linear growth.
    return [int](100 + (($Level - 1) * 50))
}

function Clamp-ExperienceLevel {
    param([int]$Level)

    if ($Level -lt 1) {
        return [int]1
    }

    if ($Level -gt $script:ExperienceMaxLevel) {
        return [int]$script:ExperienceMaxLevel
    }

    return [int]$Level
}

function Clamp-ExperienceXP {
    param([int]$XP)

    [int]$maxXP = [int](Get-XPRequiredForLevel -Level $script:ExperienceMaxLevel)

    if ($XP -lt 0) {
        return [int]0
    }

    if ($XP -gt $maxXP) {
        return [int]$maxXP
    }

    return [int]$XP
}

function Add-ExperienceScriptMethods {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    $Player | Add-Member -MemberType ScriptMethod -Name AddXP -Value {
        param(
            [int]$Amount,
            [string]$Source = 'Generic'
        )

        return (Add-PlayerXP -Player $this -Amount $Amount -Source $Source)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetXPProgress -Value {
        return (Get-PlayerXPProgress -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetUnlockedFeatures -Value {
        return (Get-UnlockedFeatures -Level ([int]$this.Level))
    } -Force
}

function Ensure-ExperiencePlayerShape {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    if ($Player -is [System.Collections.IDictionary]) {
        if (-not $Player.Contains('Name')) { $Player['Name'] = 'Player' }
        if (-not $Player.Contains('Level')) { $Player['Level'] = [int]1 }
        if (-not $Player.Contains('XP')) { $Player['XP'] = [int]0 }
        if (-not $Player.Contains('MaxLevel')) { $Player['MaxLevel'] = [int]$script:ExperienceMaxLevel }
        return
    }

    if ($null -eq $Player.PSObject.Properties['Name']) {
        Add-ExperienceObjectProperty -Object $Player -Name 'Name' -Value 'Player'
    }

    if ($null -eq $Player.PSObject.Properties['Level']) {
        Add-ExperienceObjectProperty -Object $Player -Name 'Level' -Value ([int]1)
    }

    if ($null -eq $Player.PSObject.Properties['XP']) {
        Add-ExperienceObjectProperty -Object $Player -Name 'XP' -Value ([int]0)
    }

    Add-ExperienceObjectProperty -Object $Player -Name 'MaxLevel' -Value ([int]$script:ExperienceMaxLevel)

    Add-ExperienceScriptMethods -Player $Player
}

function Resolve-ExperiencePlayer {
    param(
        $Player = $null,
        [switch]$CreateIfMissing
    )

    if ($null -ne $Player) {
        Ensure-ExperiencePlayerShape -Player $Player
        return $Player
    }

    if ($null -eq $script:ExperienceDefaultPlayer -and $CreateIfMissing) {
        $script:ExperienceDefaultPlayer = New-Player -Name 'Player' -Level 1 -XP 0
    }

    if ($null -ne $script:ExperienceDefaultPlayer) {
        Ensure-ExperiencePlayerShape -Player $script:ExperienceDefaultPlayer
    }

    return $script:ExperienceDefaultPlayer
}

function Get-LevelForXP {
    param([int]$XP)

    Ensure-ExperienceSystem

    [int]$safeXP = Clamp-ExperienceXP -XP $XP
    [int]$level = [int]1

    for ([int]$candidate = 2; $candidate -le $script:ExperienceMaxLevel; $candidate++) {
        [int]$required = [int]$script:ExperienceXPTable[$candidate]
        if ($safeXP -ge $required) {
            $level = [int]$candidate
        }
        else {
            break
        }
    }

    return [int]$level
}

function Invoke-LevelUpNotification {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [int]$FromLevel,
        [int]$ToLevel,
        [string]$Source = 'Generic'
    )

    $playerName = Get-ExperiencePlayerName -Player $Player
    $unlockFeatures = @(Get-LevelUnlocks -Level $ToLevel)

    Write-Host ("[Experience] {0} leveled up: {1} -> {2}" -f $playerName, $FromLevel, $ToLevel) -ForegroundColor Green
    if ($unlockFeatures.Count -gt 0) {
        Write-Host ("[Experience] Unlocks at level {0}: {1}" -f $ToLevel, ($unlockFeatures -join ', ')) -ForegroundColor Yellow
    }

    $eventRecord = [PSCustomObject]@{
        TimestampUtc  = [datetime]::UtcNow
        PlayerName    = [string]$playerName
        FromLevel     = [int]$FromLevel
        ToLevel       = [int]$ToLevel
        Source        = [string]$Source
        Unlocks       = @($unlockFeatures)
    }

    $script:ExperienceLevelUpHistory.Add($eventRecord) | Out-Null

    foreach ($callback in @($script:ExperienceLevelUpCallbacks)) {
        if ($null -eq $callback) {
            continue
        }

        try {
            & $callback $eventRecord | Out-Null
        }
        catch {
            Write-Warning ("[Experience] Level-up callback failed: {0}" -f $_.Exception.Message)
        }
    }

    return $eventRecord
}

# ============================================================================
# Public API - Initialization and Metadata
# ============================================================================

function Initialize-ExperienceSystem {
    <#
    .SYNOPSIS
        Initializes deterministic XP progression and unlock metadata.
    #>
    param([switch]$Quiet)

    $script:ExperienceSystemInitialized = $true
    $script:ExperienceMaxLevel = [int]50
    $script:ExperienceXPTable = @{}
    $script:ExperienceUnlockMap = @{}
    $script:ExperienceLevelUpHistory = [System.Collections.ArrayList]::new()
    $script:ExperienceLevelUpCallbacks = @()

    [int]$runningTotal = [int]0
    $script:ExperienceXPTable[[int]1] = [int]0

    for ([int]$level = 1; $level -lt $script:ExperienceMaxLevel; $level++) {
        [int]$required = Get-XPRequiredForNextLevelRaw -Level $level
        $runningTotal = [int]($runningTotal + $required)
        $script:ExperienceXPTable[[int]($level + 1)] = [int]$runningTotal
    }

    $script:ExperienceUnlockMap[[int]1] = @('Basic Combat', 'Basic Gathering', 'Quest Journal')
    $script:ExperienceUnlockMap[[int]3] = @('Combat Finishers')
    $script:ExperienceUnlockMap[[int]5] = @('Daily Contracts')
    $script:ExperienceUnlockMap[[int]10] = @('Advanced Crafting')
    $script:ExperienceUnlockMap[[int]15] = @('Companion Slot')
    $script:ExperienceUnlockMap[[int]20] = @('Elite Quests')
    $script:ExperienceUnlockMap[[int]30] = @('Rare Resource Nodes')
    $script:ExperienceUnlockMap[[int]40] = @('Legendary Contracts')
    $script:ExperienceUnlockMap[[int]50] = @('Ascendant Rank')

    if ($null -eq $script:ExperienceDefaultPlayer) {
        $script:ExperienceDefaultPlayer = New-Player -Name 'Player' -Level 1 -XP 0
    }
    else {
        Ensure-ExperiencePlayerShape -Player $script:ExperienceDefaultPlayer
        $script:ExperienceDefaultPlayer.Level = [int](Get-LevelForXP -XP (ConvertTo-ExperienceInt -Value $script:ExperienceDefaultPlayer.XP -Default 0))
        $script:ExperienceDefaultPlayer.XP = [int](Clamp-ExperienceXP -XP (ConvertTo-ExperienceInt -Value $script:ExperienceDefaultPlayer.XP -Default 0))
    }

    if (-not $Quiet) {
        Write-Host ("[Experience] Experience system initialized (max level: {0})." -f $script:ExperienceMaxLevel) -ForegroundColor Green
    }

    return [PSCustomObject]@{
        MaxLevel = [int]$script:ExperienceMaxLevel
        MaxXP    = [int](Get-XPRequiredForLevel -Level $script:ExperienceMaxLevel)
    }
}

function Ensure-ExperienceSystem {
    if (-not $script:ExperienceSystemInitialized) {
        Initialize-ExperienceSystem -Quiet | Out-Null
    }
}

function Get-MaxPlayerLevel {
    Ensure-ExperienceSystem
    return [int]$script:ExperienceMaxLevel
}

function Get-XPRequiredForLevel {
    <#
    .SYNOPSIS
        Gets total cumulative XP required to be at a level.
    #>
    param([int]$Level)

    Ensure-ExperienceSystem

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    return [int]$script:ExperienceXPTable[$safeLevel]
}

function Get-XPRequiredForNextLevel {
    <#
    .SYNOPSIS
        Gets XP needed to move from a level to the next level.
    #>
    param([int]$Level)

    Ensure-ExperienceSystem

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    return [int](Get-XPRequiredForNextLevelRaw -Level $safeLevel)
}

function Get-FeatureUnlockMap {
    <#
    .SYNOPSIS
        Gets unlock metadata in deterministic level order.
    #>

    Ensure-ExperienceSystem

    $rows = @()
    foreach ($level in @($script:ExperienceUnlockMap.Keys | Sort-Object { [int]$_ })) {
        $rows += [PSCustomObject]@{
            Level    = [int]$level
            Features = @($script:ExperienceUnlockMap[$level])
        }
    }

    return ,$rows
}

function Get-LevelUnlocks {
    <#
    .SYNOPSIS
        Gets features unlocked exactly at a level.
    #>
    param([int]$Level)

    Ensure-ExperienceSystem

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    if (-not $script:ExperienceUnlockMap.ContainsKey($safeLevel)) {
        return @()
    }

    return @($script:ExperienceUnlockMap[$safeLevel])
}

function Get-UnlockedFeatures {
    <#
    .SYNOPSIS
        Gets cumulative unlocked features up to and including a level.
    #>
    param([int]$Level)

    Ensure-ExperienceSystem

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    $features = @()

    foreach ($unlockLevel in @($script:ExperienceUnlockMap.Keys | Sort-Object { [int]$_ })) {
        [int]$currentUnlockLevel = [int]$unlockLevel
        if ($currentUnlockLevel -gt $safeLevel) {
            continue
        }

        foreach ($feature in @($script:ExperienceUnlockMap[$currentUnlockLevel])) {
            if ($features -notcontains $feature) {
                $features += [string]$feature
            }
        }
    }

    return @($features)
}

function Test-FeatureUnlocked {
    <#
    .SYNOPSIS
        Returns true when a feature is unlocked by level.
    #>
    param(
        [int]$Level,
        [Parameter(Mandatory = $true)][string]$Feature
    )

    $unlocked = Get-UnlockedFeatures -Level $Level
    foreach ($entry in @($unlocked)) {
        if ([string]::Equals([string]$entry, [string]$Feature, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# ============================================================================
# Public API - Player Construction and Access
# ============================================================================

function New-Player {
    <#
    .SYNOPSIS
        Creates a lightweight player progression object.
    .DESCRIPTION
        This constructor is focused on level/XP progression state and hooks.
    #>
    param(
        [string]$Name = 'Player',
        [int]$Level = 1,
        [int]$XP = 0,
        [switch]$SetActive
    )

    Ensure-ExperienceSystem

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'Player'
    }

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    [int]$safeXP = Clamp-ExperienceXP -XP (ConvertTo-ExperienceInt -Value $XP -Default 0)

    # Keep level and XP deterministic and consistent.
    [int]$derivedFromXP = Get-LevelForXP -XP $safeXP
    if ($derivedFromXP -gt $safeLevel) {
        $safeLevel = [int]$derivedFromXP
    }

    [int]$requiredAtLevel = Get-XPRequiredForLevel -Level $safeLevel
    if ($safeXP -lt $requiredAtLevel) {
        $safeXP = [int]$requiredAtLevel
    }

    $player = [PSCustomObject]@{
        Name     = [string]$Name.Trim()
        Level    = [int]$safeLevel
        XP       = [int]$safeXP
        MaxLevel = [int]$script:ExperienceMaxLevel
    }

    Add-ExperienceScriptMethods -Player $player

    if ($SetActive -or $null -eq $script:ExperienceDefaultPlayer) {
        $script:ExperienceDefaultPlayer = $player
    }

    return $player
}

function Get-ActivePlayer {
    <#
    .SYNOPSIS
        Gets the current active player for hook-only calls.
    #>

    Ensure-ExperienceSystem
    return (Resolve-ExperiencePlayer -CreateIfMissing)
}

function Set-ActivePlayer {
    <#
    .SYNOPSIS
        Sets the active player used when hook calls omit -Player.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-ExperienceSystem
    Ensure-ExperiencePlayerShape -Player $Player

    $script:ExperienceDefaultPlayer = $Player
    return $true
}

function Get-PlayerXP {
    <#
    .SYNOPSIS
        Gets player XP (hook-compatible).
    #>
    param($Player = $null)

    Ensure-ExperienceSystem

    $resolved = Resolve-ExperiencePlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]0
    }

    return [int](ConvertTo-ExperienceInt -Value $resolved.XP -Default 0)
}

function Get-PlayerLevel {
    <#
    .SYNOPSIS
        Gets player level.
    #>
    param($Player = $null)

    Ensure-ExperienceSystem

    $resolved = Resolve-ExperiencePlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return [int]1
    }

    return [int](Clamp-ExperienceLevel -Level (ConvertTo-ExperienceInt -Value $resolved.Level -Default 1))
}

function Get-PlayerXPProgress {
    <#
    .SYNOPSIS
        Returns progress details for the current level.
    #>
    param($Player = $null)

    Ensure-ExperienceSystem

    $resolved = Resolve-ExperiencePlayer -Player $Player -CreateIfMissing
    [int]$level = Get-PlayerLevel -Player $resolved
    [int]$xp = Get-PlayerXP -Player $resolved

    [int]$currentLevelStartXP = Get-XPRequiredForLevel -Level $level
    [int]$nextLevelCost = Get-XPRequiredForNextLevel -Level $level

    if ($level -ge $script:ExperienceMaxLevel) {
        return [PSCustomObject]@{
            Level               = [int]$level
            XP                  = [int]$xp
            XPIntoCurrentLevel  = [int]0
            XPToNextLevel       = [int]0
            XPRemaining         = [int]0
            ProgressPercent     = [double]100.0
            IsMaxLevel          = $true
        }
    }

    [int]$xpIntoLevel = [int]($xp - $currentLevelStartXP)
    if ($xpIntoLevel -lt 0) {
        $xpIntoLevel = [int]0
    }

    [int]$remaining = [int]($nextLevelCost - $xpIntoLevel)
    if ($remaining -lt 0) {
        $remaining = [int]0
    }

    [double]$progressPercent = [double]0.0
    if ($nextLevelCost -gt 0) {
        $progressPercent = [Math]::Round(([double]$xpIntoLevel / [double]$nextLevelCost) * 100.0, 2)
    }

    return [PSCustomObject]@{
        Level               = [int]$level
        XP                  = [int]$xp
        XPIntoCurrentLevel  = [int]$xpIntoLevel
        XPToNextLevel       = [int]$nextLevelCost
        XPRemaining         = [int]$remaining
        ProgressPercent     = [double]$progressPercent
        IsMaxLevel          = $false
    }
}

# ============================================================================
# Public API - XP Mutation Hooks
# ============================================================================

function Add-PlayerXP {
    <#
    .SYNOPSIS
        Adds XP and resolves level-up transitions (hook-compatible).
    #>
    param(
        $Player = $null,
        [Alias('Delta', 'XP', 'Value', 'Points', 'Count')]
        [int]$Amount,
        [string]$Source = 'Generic',
        [switch]$SuppressNotification
    )

    Ensure-ExperienceSystem

    $resolved = Resolve-ExperiencePlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return $null
    }

    Ensure-ExperiencePlayerShape -Player $resolved

    [int]$beforeXP = Get-PlayerXP -Player $resolved
    [int]$beforeLevel = Get-PlayerLevel -Player $resolved

    [int]$afterXP = Clamp-ExperienceXP -XP ([int]($beforeXP + $Amount))
    [int]$afterLevel = Get-LevelForXP -XP $afterXP

    $resolved.XP = [int]$afterXP
    $resolved.Level = [int]$afterLevel
    $resolved.MaxLevel = [int]$script:ExperienceMaxLevel

    $levelUpEvents = @()
    if (($afterLevel -gt $beforeLevel) -and (-not $SuppressNotification)) {
        for ([int]$level = $beforeLevel + 1; $level -le $afterLevel; $level++) {
            $levelUpEvents += (Invoke-LevelUpNotification -Player $resolved -FromLevel ($level - 1) -ToLevel $level -Source $Source)
        }

        if ($afterLevel -eq $script:ExperienceMaxLevel) {
            Write-Host ("[Experience] {0} reached max level {1}." -f (Get-ExperiencePlayerName -Player $resolved), $script:ExperienceMaxLevel) -ForegroundColor Magenta
        }
    }

    return [PSCustomObject]@{
        Player          = $resolved
        Source          = [string]$Source
        AmountRequested = [int]$Amount
        PreviousXP      = [int]$beforeXP
        CurrentXP       = [int]$afterXP
        PreviousLevel   = [int]$beforeLevel
        CurrentLevel    = [int]$afterLevel
        LevelsGained    = [int]([Math]::Max(0, ($afterLevel - $beforeLevel)))
        ReachedMaxLevel = [bool]($afterLevel -ge $script:ExperienceMaxLevel)
        Unlocks         = @($levelUpEvents | ForEach-Object { @($_.Unlocks) } | ForEach-Object { $_ })
        LevelUpEvents   = @($levelUpEvents)
    }
}

function Set-PlayerXP {
    <#
    .SYNOPSIS
        Sets absolute XP and updates level accordingly.
    #>
    param(
        $Player = $null,
        [int]$XP,
        [switch]$SuppressNotification
    )

    Ensure-ExperienceSystem

    $resolved = Resolve-ExperiencePlayer -Player $Player -CreateIfMissing
    if ($null -eq $resolved) {
        return $null
    }

    [int]$current = Get-PlayerXP -Player $resolved
    [int]$target = Clamp-ExperienceXP -XP $XP
    [int]$delta = [int]($target - $current)

    return (Add-PlayerXP -Player $resolved -Amount $delta -Source 'SetXP' -SuppressNotification:$SuppressNotification)
}

function Set-PlayerLevel {
    <#
    .SYNOPSIS
        Sets absolute level by applying its minimum required XP.
    #>
    param(
        $Player = $null,
        [int]$Level,
        [switch]$SuppressNotification
    )

    Ensure-ExperienceSystem

    [int]$safeLevel = Clamp-ExperienceLevel -Level $Level
    [int]$targetXP = Get-XPRequiredForLevel -Level $safeLevel
    return (Set-PlayerXP -Player $Player -XP $targetXP -SuppressNotification:$SuppressNotification)
}

function Add-XP {
    <#
    .SYNOPSIS
        Compatibility alias for Add-PlayerXP.
    #>
    param(
        $Player = $null,
        [Alias('Delta', 'XP', 'Value', 'Points', 'Count')]
        [int]$Amount,
        [string]$Source = 'Generic'
    )

    return (Add-PlayerXP -Player $Player -Amount $Amount -Source $Source)
}

function Add-Experience {
    <#
    .SYNOPSIS
        Compatibility alias for Add-PlayerXP.
    #>
    param(
        $Player = $null,
        [Alias('Delta', 'XP', 'Value', 'Points', 'Count')]
        [int]$Amount,
        [string]$Source = 'Generic'
    )

    return (Add-PlayerXP -Player $Player -Amount $Amount -Source $Source)
}

function Add-PlayerExperience {
    <#
    .SYNOPSIS
        Compatibility alias for Add-PlayerXP.
    #>
    param(
        $Player = $null,
        [Alias('Delta', 'XP', 'Value', 'Points', 'Count')]
        [int]$Amount,
        [string]$Source = 'Generic'
    )

    return (Add-PlayerXP -Player $Player -Amount $Amount -Source $Source)
}

# ============================================================================
# Public API - Source-specific XP Helpers
# ============================================================================

function Add-CombatXP {
    <#
    .SYNOPSIS
        Grants deterministic XP for combat outcomes.
    #>
    param(
        $Player = $null,
        [int]$BaseXP = 0,
        [float]$DifficultyMultiplier = [float]1.0,
        [string]$EnemyName = ''
    )

    if ($BaseXP -lt 0) { $BaseXP = 0 }
    if ($DifficultyMultiplier -lt 0) { $DifficultyMultiplier = [float]0.0 }

    [int]$amount = [int][Math]::Floor(([double]$BaseXP) * ([double]$DifficultyMultiplier))
    $source = if ([string]::IsNullOrWhiteSpace($EnemyName)) { 'Combat' } else { "Combat:$EnemyName" }

    return (Add-PlayerXP -Player $Player -Amount $amount -Source $source)
}

function Add-QuestXP {
    <#
    .SYNOPSIS
        Grants deterministic XP for quest completion.
    #>
    param(
        $Player = $null,
        [int]$BaseXP = 0,
        [switch]$MainQuest,
        [int]$BonusXP = 0,
        [string]$QuestId = ''
    )

    if ($BaseXP -lt 0) { $BaseXP = 0 }
    if ($BonusXP -lt 0) { $BonusXP = 0 }

    [double]$multiplier = if ($MainQuest) { 1.5 } else { 1.0 }
    [int]$amount = [int][Math]::Floor((([double]$BaseXP) * $multiplier) + [double]$BonusXP)

    $source = if ([string]::IsNullOrWhiteSpace($QuestId)) { 'Quest' } else { "Quest:$QuestId" }
    return (Add-PlayerXP -Player $Player -Amount $amount -Source $source)
}

function Add-GatheringXP {
    <#
    .SYNOPSIS
        Grants deterministic XP for gathering actions.
    #>
    param(
        $Player = $null,
        [int]$NodeTier = 1,
        [int]$Count = 1,
        [string]$ResourceName = ''
    )

    if ($NodeTier -lt 1) { $NodeTier = 1 }
    if ($Count -lt 1) { $Count = 1 }

    [int]$amount = [int]($NodeTier * 5 * $Count)
    $source = if ([string]::IsNullOrWhiteSpace($ResourceName)) { 'Gathering' } else { "Gathering:$ResourceName" }

    return (Add-PlayerXP -Player $Player -Amount $amount -Source $source)
}

# ============================================================================
# Public API - Notification and Event Access
# ============================================================================

function Register-LevelUpCallback {
    <#
    .SYNOPSIS
        Registers a callback receiving one level-up event object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )

    Ensure-ExperienceSystem
    $script:ExperienceLevelUpCallbacks += $Callback
    return [int]$script:ExperienceLevelUpCallbacks.Count
}

function Get-LevelUpHistory {
    <#
    .SYNOPSIS
        Gets all recorded level-up events.
    #>

    Ensure-ExperienceSystem
    return @($script:ExperienceLevelUpHistory)
}

function Clear-LevelUpHistory {
    <#
    .SYNOPSIS
        Clears level-up event history.
    #>

    Ensure-ExperienceSystem
    $script:ExperienceLevelUpHistory = [System.Collections.ArrayList]::new()
}

# Initialize on dot-source.
Initialize-ExperienceSystem -Quiet | Out-Null
