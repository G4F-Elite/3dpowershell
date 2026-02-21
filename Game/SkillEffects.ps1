# ============================================================================
# Game/SkillEffects.ps1 - Skill Effects and Cooldowns (Task 42)
# ============================================================================
# Provides:
# - Active skill execution (damage, heal, support)
# - Passive bonus aggregation from unlocked passive skills
# - Deterministic per-player cooldowns
# - Headless visual effect metadata for UI/HUD consumers
# - Player-facing skill APIs (UseSkill + cooldown queries)
#
# Integration:
# - Skill definitions/types/prerequisites from Skills.ps1
# - Damage calculation from Damage.ps1
# - Derived base damage hooks from StatProgression.ps1
# ============================================================================

# --- Dependency bootstrap (idempotent) ---
$script:SkillEffectsModuleRoot = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace([string]$script:SkillEffectsModuleRoot)) {
    $script:SkillEffectsModuleRoot = Join-Path (Get-Location).Path 'Game'
}

if ($null -eq (Get-Command -Name 'Get-Skills' -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SkillEffectsModuleRoot 'Skills.ps1')
}

if ($null -eq (Get-Command -Name 'Calculate-Damage' -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SkillEffectsModuleRoot 'Damage.ps1')
}

if ($null -eq (Get-Command -Name 'Get-PlayerBaseDamage' -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SkillEffectsModuleRoot 'StatProgression.ps1')
}

# --- Module state ---
$script:SkillEffectsInitialized = $false
$script:SkillEffectsDefaultPlayer = $null
$script:SkillEffectsDefaultVisualRetention = [int]64
$script:SkillEffectsDefaultStarterSkillPoints = [int]3
$script:SkillEffectsSkillCap = [int]30
$script:SkillActiveEffectMap = @{}
$script:SkillPassiveBonusMap = @{}

# Preserve upstream New-Player if already provided by another module.
if (-not (Get-Variable -Name SkillEffectsUpstreamNewPlayer -Scope Script -ErrorAction SilentlyContinue)) {
    $script:SkillEffectsUpstreamNewPlayer = $null
}

$existingNewPlayerCommand = Get-Command -Name 'New-Player' -CommandType Function -ErrorAction SilentlyContinue
if ($null -ne $existingNewPlayerCommand -and $null -eq $script:SkillEffectsUpstreamNewPlayer) {
    $existingFile = ''
    if ($null -ne $existingNewPlayerCommand.ScriptBlock) {
        $existingFile = [string]$existingNewPlayerCommand.ScriptBlock.File
    }

    if (-not [string]::Equals($existingFile, [string]$PSCommandPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:SkillEffectsUpstreamNewPlayer = $existingNewPlayerCommand.ScriptBlock
    }
}

# ============================================================================
# Internal helpers
# ============================================================================

function ConvertTo-SkillEffectInt {
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

function ConvertTo-SkillEffectDouble {
    param(
        $Value,
        [double]$Default = 0.0
    )

    if ($null -eq $Value) {
        return [double]$Default
    }

    try {
        return [double]$Value
    }
    catch {
        return [double]$Default
    }
}

function Normalize-SkillEffectKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return [string]$Name.Trim().ToLowerInvariant()
}

function Get-SkillTokenFragment {
    param([string]$SkillName)

    $normalized = Normalize-SkillEffectKey -Name $SkillName
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'unknown'
    }

    $fragment = ($normalized -replace '[^a-z0-9]+', '_')
    return [string]$fragment.Trim([char[]]'_')
}

function Add-SkillEffectObjectProperty {
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

function Get-SkillEffectFieldValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        Write-Output -NoEnumerate $Default
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            Write-Output -NoEnumerate $Object[$Name]
            return
        }

        Write-Output -NoEnumerate $Default
        return
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        Write-Output -NoEnumerate $prop.Value
        return
    }

    Write-Output -NoEnumerate $Default
}

function Get-PlayerNameSafe {
    param($Player)

    $name = [string](Get-SkillEffectFieldValue -Object $Player -Name 'Name' -Default 'Player')
    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'Player'
    }

    return [string]$name.Trim()
}

function Get-DefaultActiveSkillEffectRows {
    return @(
        [PSCustomObject]@{ Name = 'Power Strike';   Mode = 'Damage'; CooldownSeconds = 3.0;  DamageScale = 1.60; FlatDamage = 4; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 0.0 },
        [PSCustomObject]@{ Name = 'Guard Stance';   Mode = 'Buff';   CooldownSeconds = 6.0;  DamageScale = 0.00; FlatDamage = 0; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 4.0 },
        [PSCustomObject]@{ Name = 'Whirlwind';      Mode = 'Damage'; CooldownSeconds = 8.0;  DamageScale = 1.25; FlatDamage = 2; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 0.0 },
        [PSCustomObject]@{ Name = 'Execute';        Mode = 'Damage'; CooldownSeconds = 10.0; DamageScale = 1.20; FlatDamage = 5; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 0.0 },
        [PSCustomObject]@{ Name = 'Salvage';        Mode = 'Utility'; CooldownSeconds = 5.0; DamageScale = 0.00; FlatDamage = 0; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 0.0 },
        [PSCustomObject]@{ Name = 'Master Forging'; Mode = 'Buff';   CooldownSeconds = 14.0; DamageScale = 0.00; FlatDamage = 0; DamageType = 'Physical'; IntelligenceScale = 0.0; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 20.0 },
        [PSCustomObject]@{ Name = 'Campfire';       Mode = 'Heal';   CooldownSeconds = 12.0; DamageScale = 0.00; FlatDamage = 0; DamageType = 'Magic';    IntelligenceScale = 0.0; BaseHeal = 18; HealScale = 1.2; BuffSeconds = 0.0 },
        [PSCustomObject]@{ Name = 'Beast Lore';     Mode = 'Damage'; CooldownSeconds = 9.0;  DamageScale = 1.00; FlatDamage = 3; DamageType = 'Magic';    IntelligenceScale = 0.3; BaseHeal = 0;  HealScale = 0.0; BuffSeconds = 0.0 }
    )
}

function Get-DefaultPassiveSkillBonusRows {
    return @(
        [PSCustomObject]@{ Name = 'Veteran Conditioning'; DamageMultiplier = 0.25; DamageFlatBonus = 2; CooldownFactor = 1.00; HealingMultiplier = 0.10; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Counter Mastery';      DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 2; GuardReductionBonus = 0.10; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Battle Rhythm';        DamageMultiplier = 0.05; DamageFlatBonus = 0; CooldownFactor = 0.85; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Basic Smithing';       DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.05; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Efficient Crafting';   DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.15; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Precision Tools';      DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.20; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Forager';              DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.10 },
        [PSCustomObject]@{ Name = 'Trail Awareness';      DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.00; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.20 },
        [PSCustomObject]@{ Name = 'Endurance';            DamageMultiplier = 0.00; DamageFlatBonus = 0; CooldownFactor = 1.00; HealingMultiplier = 0.30; ArmorPenetration = 0; GuardReductionBonus = 0.05; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.00 },
        [PSCustomObject]@{ Name = 'Wilderness Mastery';   DamageMultiplier = 0.05; DamageFlatBonus = 0; CooldownFactor = 0.90; HealingMultiplier = 0.10; ArmorPenetration = 0; GuardReductionBonus = 0.00; CraftEfficiencyBonus = 0.00; ResourceYieldBonus = 0.20 }
    )
}

function Ensure-SkillEffectsSystem {
    if (-not $script:SkillEffectsInitialized) {
        Initialize-SkillEffectsSystem -Quiet | Out-Null
    }
}

function Get-ActiveSkillEffectConfig {
    param(
        [Parameter(Mandatory = $true)]$SkillDefinition
    )

    Ensure-SkillEffectsSystem

    $skillKey = Normalize-SkillEffectKey -Name ([string]$SkillDefinition.Name)
    if ($script:SkillActiveEffectMap.ContainsKey($skillKey)) {
        return $script:SkillActiveEffectMap[$skillKey]
    }

    return [PSCustomObject]@{
        Name              = [string]$SkillDefinition.Name
        Key               = [string]$skillKey
        Mode              = 'Utility'
        CooldownSeconds   = [double]5.0
        DamageScale       = [double]0.0
        FlatDamage        = [int]0
        DamageType        = 'Physical'
        IntelligenceScale = [double]0.0
        BaseHeal          = [int]0
        HealScale         = [double]0.0
        BuffSeconds       = [double]0.0
    }
}

function Add-SkillEffectsPlayerScriptMethods {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    $Player | Add-Member -MemberType ScriptMethod -Name UseSkill -Value {
        param(
            [string]$SkillName,
            $Target = $null
        )

        return (Use-PlayerSkill -Player $this -SkillName $SkillName -Target $Target)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name CanUseSkill -Value {
        param([string]$SkillName)
        return (Can-UsePlayerSkill -Player $this -SkillName $SkillName)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetSkillCooldown -Value {
        param([string]$SkillName)
        return (Get-PlayerSkillCooldownRemaining -Player $this -SkillName $SkillName)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetSkillCooldownInfo -Value {
        param([string]$SkillName)
        return (Get-PlayerSkillCooldownInfo -Player $this -SkillName $SkillName)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetSkillCooldowns -Value {
        return (Get-PlayerSkillCooldowns -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name AdvanceSkillTime -Value {
        param([double]$Seconds = 0)
        return (Advance-PlayerSkillTime -Player $this -Seconds $Seconds)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetPassiveBonuses -Value {
        return (Get-PlayerPassiveSkillBonuses -Player $this)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name GetSkillVisualEffects -Value {
        param([int]$MaxCount = 10)
        return (Get-PlayerSkillVisualHistory -Player $this -MaxCount $MaxCount)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name UnlockSkill -Value {
        param([string]$SkillName)
        return (Unlock-PlayerSkill -Player $this -SkillName $SkillName)
    } -Force

    $Player | Add-Member -MemberType ScriptMethod -Name HasSkill -Value {
        param([string]$SkillName)
        return (Test-PlayerHasSkill -Player $this -SkillName $SkillName)
    } -Force
}

function Ensure-PlayerSkillEffectsShape {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-SkillEffectsSystem

    $name = Get-PlayerNameSafe -Player $Player
    Add-SkillEffectObjectProperty -Object $Player -Name 'Name' -Value ([string]$name)

    [int]$safeLevel = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'Level' -Default 1) -Default 1
    if ($safeLevel -lt 1) {
        $safeLevel = [int]1
    }
    Add-SkillEffectObjectProperty -Object $Player -Name 'Level' -Value ([int]$safeLevel)

    Add-SkillEffectObjectProperty -Object $Player -Name 'SkillTimeSeconds' -Value ([double](ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Player -Name 'SkillTimeSeconds' -Default 0.0) -Default 0.0))

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'SkillCooldownReadyAt' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillCooldownReadyAt' -Value @{}
    }
    elseif (-not ((Get-SkillEffectFieldValue -Object $Player -Name 'SkillCooldownReadyAt' -Default $null) -is [System.Collections.IDictionary])) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillCooldownReadyAt' -Value @{}
    }

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualHistory' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillVisualHistory' -Value ([System.Collections.ArrayList]::new())
    }
    elseif (-not ((Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualHistory' -Default $null) -is [System.Collections.ArrayList])) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillVisualHistory' -Value ([System.Collections.ArrayList]::new())
    }

    [int]$visualRetention = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualRetention' -Default $script:SkillEffectsDefaultVisualRetention) -Default $script:SkillEffectsDefaultVisualRetention
    if ($visualRetention -lt 1) {
        $visualRetention = [int]$script:SkillEffectsDefaultVisualRetention
    }
    Add-SkillEffectObjectProperty -Object $Player -Name 'SkillVisualRetention' -Value ([int]$visualRetention)

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'SkillState' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillState' -Value @{}
    }

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'SkillTree' -Default $null)) {
        $tree = New-SkillTree -StartingSkillPoints $script:SkillEffectsDefaultStarterSkillPoints -CurrentLevel $safeLevel -PlayerName $name
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillTree' -Value $tree
    }

    $skillTree = Get-SkillEffectFieldValue -Object $Player -Name 'SkillTree' -Default $null
    if ($null -ne $skillTree -and $null -ne ($skillTree | Get-Member -Name 'PlayerName' -ErrorAction SilentlyContinue)) {
        $skillTree.PlayerName = [string]$name
    }

    if ($null -ne $skillTree -and $null -ne ($skillTree | Get-Member -Name 'SyncFromLevel' -ErrorAction SilentlyContinue)) {
        try {
            $skillTree.SyncFromLevel([int]$safeLevel, 'SkillEffectsSync') | Out-Null
        }
        catch {
        }
    }

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'MaxHP' -Default $null)) {
        [int]$derivedMaxHP = 100
        if ($null -ne (Get-Command -Name 'Get-PlayerMaxHP' -ErrorAction SilentlyContinue)) {
            try {
                $derivedMaxHP = [int](Get-PlayerMaxHP -Player $Player)
            }
            catch {
                $derivedMaxHP = [int]100
            }
        }
        Add-SkillEffectObjectProperty -Object $Player -Name 'MaxHP' -Value ([double][Math]::Max(1, $derivedMaxHP))
    }

    if ($null -eq (Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $Player -Name 'HP' -Value ([double](ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Player -Name 'MaxHP' -Default 100) -Default 100))
    }

    [double]$maxHP = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Player -Name 'MaxHP' -Default 100) -Default 100
    if ($maxHP -lt 1.0) {
        $maxHP = [double]1.0
    }
    Add-SkillEffectObjectProperty -Object $Player -Name 'MaxHP' -Value ([double]$maxHP)

    [double]$hp = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default $maxHP) -Default $maxHP
    if ($hp -lt 0.0) {
        $hp = [double]0.0
    }
    if ($hp -gt $maxHP) {
        $hp = [double]$maxHP
    }
    Add-SkillEffectObjectProperty -Object $Player -Name 'HP' -Value ([double]$hp)

    Add-SkillEffectObjectProperty -Object $Player -Name 'IsAlive' -Value ([bool]($hp -gt 0.0))

    Ensure-PlayerStarterSkills -Player $Player
    Add-SkillEffectsPlayerScriptMethods -Player $Player
}

function Ensure-PlayerStarterSkills {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    $skillTree = Get-SkillEffectFieldValue -Object $Player -Name 'SkillTree' -Default $null
    if ($null -eq $skillTree) {
        return
    }

    $hasSkillMethod = $null -ne ($skillTree | Get-Member -Name 'HasSkill' -ErrorAction SilentlyContinue)
    $canUnlockMethod = $null -ne ($skillTree | Get-Member -Name 'CanUnlockSkill' -ErrorAction SilentlyContinue)
    $unlockMethod = $null -ne ($skillTree | Get-Member -Name 'UnlockSkill' -ErrorAction SilentlyContinue)

    if (-not ($hasSkillMethod -and $canUnlockMethod -and $unlockMethod)) {
        return
    }

    [bool]$hasPowerStrike = $false
    try {
        $hasPowerStrike = [bool]$skillTree.HasSkill('Power Strike')
    }
    catch {
        $hasPowerStrike = $false
    }

    if ($hasPowerStrike) {
        return
    }

    $gate = $null
    try {
        $gate = $skillTree.CanUnlockSkill('Power Strike')
    }
    catch {
        $gate = $null
    }

    if (($null -ne $gate) -and (-not [bool]$gate.CanUnlock) -and ([string]$gate.Reason -eq 'InsufficientSkillPoints')) {
        if ($null -ne (Get-Command -Name 'Grant-SkillPoints' -ErrorAction SilentlyContinue)) {
            try {
                Grant-SkillPoints -SkillTree $skillTree -Amount ([int][Math]::Max(1, [int]$gate.Cost)) -Source 'SkillEffectsStarter' | Out-Null
                $gate = $skillTree.CanUnlockSkill('Power Strike')
            }
            catch {
            }
        }
    }

    if ($null -ne $gate -and [bool]$gate.CanUnlock) {
        try {
            $skillTree.UnlockSkill('Power Strike') | Out-Null
        }
        catch {
        }
    }
}

function Resolve-PlayerSkillTree {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [switch]$CreateIfMissing
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $tree = Get-SkillEffectFieldValue -Object $Player -Name 'SkillTree' -Default $null
    if ($null -eq $tree -and $CreateIfMissing) {
        $tree = New-SkillTree -StartingSkillPoints $script:SkillEffectsDefaultStarterSkillPoints -CurrentLevel ([int]$Player.Level) -PlayerName (Get-PlayerNameSafe -Player $Player)
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillTree' -Value $tree
        Ensure-PlayerStarterSkills -Player $Player
    }

    return $tree
}

function Get-PlayerSkillTime {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-PlayerSkillEffectsShape -Player $Player
    return [double](ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Player -Name 'SkillTimeSeconds' -Default 0.0) -Default 0.0)
}

function Advance-PlayerSkillTime {
    <#
    .SYNOPSIS
        Advances deterministic player-local skill time for cooldown testing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [double]$Seconds = 0.0
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    [double]$delta = ConvertTo-SkillEffectDouble -Value $Seconds -Default 0.0
    if ($delta -lt 0.0) {
        $delta = [double]0.0
    }

    [double]$before = Get-PlayerSkillTime -Player $Player
    [double]$after = [double]($before + $delta)

    Add-SkillEffectObjectProperty -Object $Player -Name 'SkillTimeSeconds' -Value ([double]$after)

    return [PSCustomObject]@{
        PreviousTime = [double]$before
        CurrentTime  = [double]$after
        Delta        = [double]$delta
    }
}

function Get-PlayerSkillCooldownRemaining {
    <#
    .SYNOPSIS
        Returns remaining cooldown seconds for one skill.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $skillKey = Normalize-SkillEffectKey -Name $SkillName
    if ([string]::IsNullOrWhiteSpace($skillKey)) {
        return [double]0.0
    }

    $cooldownMap = Get-SkillEffectFieldValue -Object $Player -Name 'SkillCooldownReadyAt' -Default @{}
    if (-not $cooldownMap.ContainsKey($skillKey)) {
        return [double]0.0
    }

    [double]$readyAt = ConvertTo-SkillEffectDouble -Value $cooldownMap[$skillKey] -Default 0.0
    [double]$currentTime = Get-PlayerSkillTime -Player $Player
    [double]$remaining = [double]($readyAt - $currentTime)

    if ($remaining -le 0.0) {
        $cooldownMap.Remove($skillKey)
        return [double]0.0
    }

    return [double][Math]::Round($remaining, 3)
}

function Get-PlayerSkillCooldownInfo {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    [double]$remaining = Get-PlayerSkillCooldownRemaining -Player $Player -SkillName $SkillName
    [double]$currentTime = Get-PlayerSkillTime -Player $Player

    return [PSCustomObject]@{
        SkillName        = [string]$SkillName
        RemainingSeconds = [double]$remaining
        IsReady          = [bool]($remaining -le 0.0)
        CurrentTime      = [double]$currentTime
    }
}

function Get-PlayerSkillCooldowns {
    <#
    .SYNOPSIS
        Returns cooldown status for all active skills.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $rows = @()
    foreach ($skill in @(Get-Skills -SkillType 'Active')) {
        $rows += (Get-PlayerSkillCooldownInfo -Player $Player -SkillName ([string]$skill.Name))
    }

    return @($rows)
}

function Test-PlayerHasSkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    $tree = Resolve-PlayerSkillTree -Player $Player -CreateIfMissing
    if ($null -eq $tree) {
        return $false
    }

    if ($null -eq ($tree | Get-Member -Name 'HasSkill' -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        return [bool]$tree.HasSkill($SkillName)
    }
    catch {
        return $false
    }
}

function Unlock-PlayerSkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    $tree = Resolve-PlayerSkillTree -Player $Player -CreateIfMissing
    if ($null -eq $tree -or $null -eq ($tree | Get-Member -Name 'UnlockSkill' -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            Unlocked = $false
            Reason   = 'SkillTreeUnavailable'
            SkillName = [string]$SkillName
        }
    }

    try {
        return ($tree.UnlockSkill($SkillName))
    }
    catch {
        return [PSCustomObject]@{
            Unlocked = $false
            Reason   = "UnlockFailed:$($_.Exception.Message)"
            SkillName = [string]$SkillName
        }
    }
}

function Get-PlayerPassiveSkillBonuses {
    <#
    .SYNOPSIS
        Aggregates passive bonuses from currently unlocked passive skills.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Ensure-PlayerSkillEffectsShape -Player $Player
    $tree = Resolve-PlayerSkillTree -Player $Player -CreateIfMissing

    $bonus = [ordered]@{
        DamageMultiplier    = [double]0.0
        DamageFlatBonus     = [int]0
        HealingMultiplier   = [double]0.0
        CooldownMultiplier  = [double]1.0
        ArmorPenetration    = [int]0
        GuardReductionBonus = [double]0.0
        CraftEfficiencyBonus = [double]0.0
        ResourceYieldBonus  = [double]0.0
        PassiveSkills       = @()
    }

    if ($null -eq $tree -or $null -eq ($tree | Get-Member -Name 'GetUnlockedSkills' -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]$bonus
    }

    $unlocked = @()
    try {
        $unlocked = @($tree.GetUnlockedSkills())
    }
    catch {
        $unlocked = @()
    }

    foreach ($skill in @($unlocked)) {
        if ([string]$skill.SkillType -ne 'Passive') {
            continue
        }

        $skillKey = Normalize-SkillEffectKey -Name ([string]$skill.Name)
        if (-not $script:SkillPassiveBonusMap.ContainsKey($skillKey)) {
            continue
        }

        $row = $script:SkillPassiveBonusMap[$skillKey]

        $bonus.DamageMultiplier = [double]($bonus.DamageMultiplier + (ConvertTo-SkillEffectDouble -Value $row.DamageMultiplier -Default 0.0))
        $bonus.DamageFlatBonus = [int]($bonus.DamageFlatBonus + (ConvertTo-SkillEffectInt -Value $row.DamageFlatBonus -Default 0))
        $bonus.HealingMultiplier = [double]($bonus.HealingMultiplier + (ConvertTo-SkillEffectDouble -Value $row.HealingMultiplier -Default 0.0))
        $bonus.CooldownMultiplier = [double]($bonus.CooldownMultiplier * (ConvertTo-SkillEffectDouble -Value $row.CooldownFactor -Default 1.0))
        $bonus.ArmorPenetration = [int]($bonus.ArmorPenetration + (ConvertTo-SkillEffectInt -Value $row.ArmorPenetration -Default 0))
        $bonus.GuardReductionBonus = [double]($bonus.GuardReductionBonus + (ConvertTo-SkillEffectDouble -Value $row.GuardReductionBonus -Default 0.0))
        $bonus.CraftEfficiencyBonus = [double]($bonus.CraftEfficiencyBonus + (ConvertTo-SkillEffectDouble -Value $row.CraftEfficiencyBonus -Default 0.0))
        $bonus.ResourceYieldBonus = [double]($bonus.ResourceYieldBonus + (ConvertTo-SkillEffectDouble -Value $row.ResourceYieldBonus -Default 0.0))
        $bonus.PassiveSkills += [string]$skill.Name
    }

    if ($bonus.CooldownMultiplier -lt 0.25) {
        $bonus.CooldownMultiplier = [double]0.25
    }

    $bonus.DamageMultiplier = [double][Math]::Round($bonus.DamageMultiplier, 4)
    $bonus.HealingMultiplier = [double][Math]::Round($bonus.HealingMultiplier, 4)
    $bonus.CooldownMultiplier = [double][Math]::Round($bonus.CooldownMultiplier, 4)
    $bonus.GuardReductionBonus = [double][Math]::Round($bonus.GuardReductionBonus, 4)
    $bonus.CraftEfficiencyBonus = [double][Math]::Round($bonus.CraftEfficiencyBonus, 4)
    $bonus.ResourceYieldBonus = [double][Math]::Round($bonus.ResourceYieldBonus, 4)

    return [PSCustomObject]$bonus
}

function Get-PlayerSkillBaseDamage {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    [int]$baseDamage = 1

    if ($null -ne (Get-Command -Name 'Get-PlayerBaseDamage' -ErrorAction SilentlyContinue)) {
        try {
            $baseDamage = [int](Get-PlayerBaseDamage -Player $Player)
        }
        catch {
            $baseDamage = [int]1
        }
    }
    elseif ($null -ne ($Player | Get-Member -Name 'GetBaseDamage' -ErrorAction SilentlyContinue)) {
        try {
            $baseDamage = [int]$Player.GetBaseDamage()
        }
        catch {
            $baseDamage = [int]1
        }
    }
    else {
        [int]$strength = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'Strength' -Default 5) -Default 5
        [int]$dexterity = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'Dexterity' -Default 5) -Default 5
        [int]$dexBonus = [int][Math]::Floor(([double]$dexterity) / 4.0)
        $baseDamage = [int](5 + ($strength * 2) + $dexBonus)
    }

    if ($baseDamage -lt 1) {
        $baseDamage = [int]1
    }

    return [int]$baseDamage
}

function Get-PlayerIntelligenceValue {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    [int]$value = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'Intelligence' -Default 5) -Default 5
    if ($value -lt 1) {
        $value = [int]1
    }

    return [int]$value
}

function Resolve-TargetArmorValue {
    param($Target)

    [double]$armor = 0.0
    if ($null -ne $Target) {
        $armor = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Target -Name 'Defense' -Default 0) -Default 0.0
    }

    if ($armor -lt 0.0) {
        $armor = [double]0.0
    }

    return [double]$armor
}

function Resolve-TargetMagicResistanceValue {
    param($Target)

    [double]$value = 0.0
    if ($null -ne $Target) {
        $value = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Target -Name 'MagicResistance' -Default 0.0) -Default 0.0
    }

    if ($value -lt 0.0) {
        $value = [double]0.0
    }

    if ($value -gt 1.0) {
        $value = [double]1.0
    }

    return [double]$value
}

function Resolve-SkillDamageCalculation {
    param(
        [Parameter(Mandatory = $true)]$Player,
        $Target = $null,
        [double]$DamageScale = 1.0,
        [int]$FlatDamage = 0,
        [double]$IntelligenceScale = 0.0,
        [ValidateSet('Physical', 'Magic')]
        [string]$DamageType = 'Physical',
        $PassiveBonuses = $null,
        [double]$ExecuteScaleBonus = 1.0
    )

    [int]$baseDamage = Get-PlayerSkillBaseDamage -Player $Player
    [int]$intelligence = Get-PlayerIntelligenceValue -Player $Player

    [double]$damageScaleSafe = ConvertTo-SkillEffectDouble -Value $DamageScale -Default 1.0
    if ($damageScaleSafe -lt 0.0) {
        $damageScaleSafe = [double]0.0
    }

    [double]$executeBonus = ConvertTo-SkillEffectDouble -Value $ExecuteScaleBonus -Default 1.0
    if ($executeBonus -lt 0.0) {
        $executeBonus = [double]0.0
    }

    [double]$flatDamageSafe = [double](ConvertTo-SkillEffectInt -Value $FlatDamage -Default 0)
    [double]$intelligenceContribution = ([double]$intelligence) * (ConvertTo-SkillEffectDouble -Value $IntelligenceScale -Default 0.0)

    [double]$passiveDamageMultiplier = 0.0
    [int]$passiveDamageFlat = 0
    [int]$passiveArmorPen = 0

    if ($null -ne $PassiveBonuses) {
        $passiveDamageMultiplier = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.DamageMultiplier -Default 0.0
        $passiveDamageFlat = ConvertTo-SkillEffectInt -Value $PassiveBonuses.DamageFlatBonus -Default 0
        $passiveArmorPen = ConvertTo-SkillEffectInt -Value $PassiveBonuses.ArmorPenetration -Default 0
    }

    [double]$prePassive = (($baseDamage * $damageScaleSafe * $executeBonus) + $flatDamageSafe + $intelligenceContribution + $passiveDamageFlat)
    if ($prePassive -lt 1.0) {
        $prePassive = [double]1.0
    }

    [double]$postPassiveBase = $prePassive * (1.0 + $passiveDamageMultiplier)
    if ($postPassiveBase -lt 1.0) {
        $postPassiveBase = [double]1.0
    }

    [double]$targetArmor = Resolve-TargetArmorValue -Target $Target
    [double]$magicResistance = Resolve-TargetMagicResistanceValue -Target $Target
    [double]$effectiveArmor = [double]([Math]::Max(0.0, $targetArmor - [double]$passiveArmorPen))

    $calculated = Calculate-Damage -BaseDamage $postPassiveBase -Strength 0 -EnemyArmor $effectiveArmor -DamageType $DamageType -CriticalChance 0.0 -CriticalMultiplier 1.0 -MagicResistance $magicResistance

    return [PSCustomObject]@{
        FinalDamage       = [int](ConvertTo-SkillEffectInt -Value $calculated.FinalDamage -Default 1)
        DamageType        = [string]$DamageType
        BaseDamage        = [int]$baseDamage
        Intelligence      = [int]$intelligence
        DamageScale       = [double]$damageScaleSafe
        ExecuteScaleBonus = [double]$executeBonus
        FlatDamage        = [int](ConvertTo-SkillEffectInt -Value $FlatDamage -Default 0)
        IntelligenceScale = [double](ConvertTo-SkillEffectDouble -Value $IntelligenceScale -Default 0.0)
        PreMitigation     = [double][Math]::Round($postPassiveBase, 4)
        TargetArmor       = [double][Math]::Round($effectiveArmor, 4)
        MagicResistance   = [double][Math]::Round($magicResistance, 4)
        DamageResult      = $calculated
    }
}

function Apply-SkillDamageToTarget {
    param(
        $Target,
        [int]$Damage
    )

    if ($null -eq $Target) {
        return [PSCustomObject]@{
            Applied     = $false
            Reason      = 'TargetRequired'
            DamageDone  = [int]0
            HPBefore    = [double]0.0
            HPAfter     = [double]0.0
            Defeated    = $false
        }
    }

    $hpRaw = Get-SkillEffectFieldValue -Object $Target -Name 'HP' -Default $null
    if ($null -eq $hpRaw) {
        return [PSCustomObject]@{
            Applied     = $false
            Reason      = 'TargetMissingHP'
            DamageDone  = [int]0
            HPBefore    = [double]0.0
            HPAfter     = [double]0.0
            Defeated    = $false
        }
    }

    [double]$hpBefore = ConvertTo-SkillEffectDouble -Value $hpRaw -Default 0.0
    [double]$maxHP = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Target -Name 'MaxHP' -Default $hpBefore) -Default $hpBefore
    if ($maxHP -lt 1.0) {
        $maxHP = [double]1.0
    }

    [int]$safeDamage = ConvertTo-SkillEffectInt -Value $Damage -Default 0
    if ($safeDamage -lt 0) {
        $safeDamage = [int]0
    }

    [double]$hpAfter = [double]([Math]::Max(0.0, $hpBefore - [double]$safeDamage))
    Add-SkillEffectObjectProperty -Object $Target -Name 'HP' -Value ([double]$hpAfter)
    Add-SkillEffectObjectProperty -Object $Target -Name 'MaxHP' -Value ([double]$maxHP)

    [bool]$defeated = ($hpAfter -le 0.0)
    if ($null -ne (Get-SkillEffectFieldValue -Object $Target -Name 'IsAlive' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $Target -Name 'IsAlive' -Value ([bool](-not $defeated))
    }

    return [PSCustomObject]@{
        Applied     = $true
        Reason      = 'DamageApplied'
        DamageDone  = [int]$safeDamage
        HPBefore    = [double]$hpBefore
        HPAfter     = [double]$hpAfter
        Defeated    = [bool]$defeated
    }
}

function Resolve-SkillHealingAmount {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [int]$BaseHeal,
        [double]$HealScale,
        $PassiveBonuses = $null
    )

    [int]$intelligence = Get-PlayerIntelligenceValue -Player $Player
    [int]$baseHealSafe = ConvertTo-SkillEffectInt -Value $BaseHeal -Default 0
    [double]$scaleSafe = ConvertTo-SkillEffectDouble -Value $HealScale -Default 0.0

    [double]$passiveHealMultiplier = 0.0
    if ($null -ne $PassiveBonuses) {
        $passiveHealMultiplier = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.HealingMultiplier -Default 0.0
    }

    [double]$raw = [double]$baseHealSafe + (([double]$intelligence) * $scaleSafe)
    if ($raw -lt 1.0) {
        $raw = [double]1.0
    }

    [double]$withPassive = $raw * (1.0 + $passiveHealMultiplier)
    if ($withPassive -lt 1.0) {
        $withPassive = [double]1.0
    }

    return [int][Math]::Max(1, [int][Math]::Floor($withPassive))
}

function Apply-SkillHealingToTarget {
    param(
        $Target,
        [int]$Healing
    )

    if ($null -eq $Target) {
        return [PSCustomObject]@{
            Applied      = $false
            Reason       = 'TargetRequired'
            HealingDone  = [int]0
            HPBefore     = [double]0.0
            HPAfter      = [double]0.0
        }
    }

    $hpRaw = Get-SkillEffectFieldValue -Object $Target -Name 'HP' -Default $null
    if ($null -eq $hpRaw) {
        return [PSCustomObject]@{
            Applied      = $false
            Reason       = 'TargetMissingHP'
            HealingDone  = [int]0
            HPBefore     = [double]0.0
            HPAfter      = [double]0.0
        }
    }

    [double]$hpBefore = ConvertTo-SkillEffectDouble -Value $hpRaw -Default 0.0
    [double]$maxHP = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Target -Name 'MaxHP' -Default $hpBefore) -Default $hpBefore
    if ($maxHP -lt 1.0) {
        $maxHP = [double]1.0
    }

    [int]$healSafe = ConvertTo-SkillEffectInt -Value $Healing -Default 0
    if ($healSafe -lt 0) {
        $healSafe = [int]0
    }

    [double]$hpAfter = [double]([Math]::Min($maxHP, ($hpBefore + [double]$healSafe)))
    Add-SkillEffectObjectProperty -Object $Target -Name 'HP' -Value ([double]$hpAfter)
    Add-SkillEffectObjectProperty -Object $Target -Name 'MaxHP' -Value ([double]$maxHP)
    Add-SkillEffectObjectProperty -Object $Target -Name 'IsAlive' -Value ([bool]($hpAfter -gt 0.0))

    [int]$actualHealing = [int][Math]::Floor($hpAfter - $hpBefore)
    if ($actualHealing -lt 0) {
        $actualHealing = [int]0
    }

    return [PSCustomObject]@{
        Applied      = $true
        Reason       = 'HealingApplied'
        HealingDone  = [int]$actualHealing
        HPBefore     = [double]$hpBefore
        HPAfter      = [double]$hpAfter
    }
}

function New-SkillVisualEffectMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$SkillName,
        [Parameter(Mandatory = $true)][string]$Mode,
        [double]$SkillTime,
        [int]$Magnitude = 0
    )

    $fragment = Get-SkillTokenFragment -SkillName $SkillName
    $modeKey = (Normalize-SkillEffectKey -Name $Mode)
    if ([string]::IsNullOrWhiteSpace($modeKey)) {
        $modeKey = 'utility'
    }

    $theme = 'Utility'
    switch ($modeKey) {
        'damage' { $theme = 'CombatImpact' }
        'heal' { $theme = 'SupportHealing' }
        'buff' { $theme = 'StatusBuff' }
        default { $theme = 'Utility' }
    }

    [int]$durationMs = 500
    if ($modeKey -eq 'damage') {
        $durationMs = 420
    }
    elseif ($modeKey -eq 'heal') {
        $durationMs = 620
    }
    elseif ($modeKey -eq 'buff') {
        $durationMs = 700
    }

    return [PSCustomObject]@{
        TokenId      = ('fx.skill.{0}.{1}' -f $fragment, $modeKey)
        EventMarker  = ('SKILL_EFFECT_QUEUED:{0}:{1}' -f $fragment, [int][Math]::Floor($SkillTime * 1000.0))
        Theme        = [string]$theme
        DurationMs   = [int]$durationMs
        Mode         = [string]$modeKey
        Magnitude    = [int]$Magnitude
        SkillTime    = [double][Math]::Round($SkillTime, 3)
        Status       = 'queued'
    }
}

function Push-PlayerSkillVisualEffect {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)]$Visual
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $history = Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualHistory' -Default ([System.Collections.ArrayList]::new())
    if (-not ($history -is [System.Collections.ArrayList])) {
        $history = [System.Collections.ArrayList]::new()
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillVisualHistory' -Value $history
    }

    $history.Add($Visual) | Out-Null

    [int]$retention = ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualRetention' -Default $script:SkillEffectsDefaultVisualRetention) -Default $script:SkillEffectsDefaultVisualRetention
    if ($retention -lt 1) {
        $retention = [int]$script:SkillEffectsDefaultVisualRetention
    }

    while ($history.Count -gt $retention) {
        $history.RemoveAt(0)
    }

    return $Visual
}

function Get-PlayerSkillVisualHistory {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [int]$MaxCount = 10
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    [int]$safeMax = ConvertTo-SkillEffectInt -Value $MaxCount -Default 10
    if ($safeMax -lt 1) {
        $safeMax = [int]1
    }

    $history = Get-SkillEffectFieldValue -Object $Player -Name 'SkillVisualHistory' -Default ([System.Collections.ArrayList]::new())
    if (-not ($history -is [System.Collections.ArrayList])) {
        return @()
    }

    $rows = [System.Collections.ArrayList]::new()
    for ([int]$i = $history.Count - 1; $i -ge 0; $i--) {
        $rows.Add($history[$i]) | Out-Null
        if ($rows.Count -ge $safeMax) {
            break
        }
    }

    return @($rows)
}

function Set-PlayerSkillCooldown {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName,
        [double]$BaseCooldown,
        $PassiveBonuses = $null
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    [double]$base = ConvertTo-SkillEffectDouble -Value $BaseCooldown -Default 0.0
    if ($base -lt 0.0) {
        $base = [double]0.0
    }

    [double]$cooldownMultiplier = 1.0
    if ($null -ne $PassiveBonuses) {
        $cooldownMultiplier = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.CooldownMultiplier -Default 1.0
    }
    if ($cooldownMultiplier -lt 0.25) {
        $cooldownMultiplier = [double]0.25
    }

    [double]$finalCooldown = [double]([Math]::Round(($base * $cooldownMultiplier), 3))
    if ($finalCooldown -lt 0.0) {
        $finalCooldown = [double]0.0
    }

    [double]$currentTime = Get-PlayerSkillTime -Player $Player
    [double]$readyAt = [double]($currentTime + $finalCooldown)

    $cooldownMap = Get-SkillEffectFieldValue -Object $Player -Name 'SkillCooldownReadyAt' -Default @{}
    if (-not ($cooldownMap -is [System.Collections.IDictionary])) {
        $cooldownMap = @{}
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillCooldownReadyAt' -Value $cooldownMap
    }

    $skillKey = Normalize-SkillEffectKey -Name $SkillName
    $cooldownMap[$skillKey] = [double]$readyAt

    return [double]$finalCooldown
}

function Can-UsePlayerSkill {
    <#
    .SYNOPSIS
        Returns deterministic gate status before skill use.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $skill = Get-Skill -Name $SkillName
    if ($null -eq $skill) {
        return [PSCustomObject]@{
            CanUse            = $false
            Reason            = 'SkillNotFound'
            SkillName         = [string]$SkillName
            SkillType         = ''
            CooldownRemaining = [double]0.0
        }
    }

    if ([string]$skill.SkillType -ne 'Active') {
        return [PSCustomObject]@{
            CanUse            = $false
            Reason            = 'SkillIsPassive'
            SkillName         = [string]$skill.Name
            SkillType         = [string]$skill.SkillType
            CooldownRemaining = [double]0.0
        }
    }

    [bool]$isAlive = [bool](Get-SkillEffectFieldValue -Object $Player -Name 'IsAlive' -Default $true)
    if (-not $isAlive) {
        return [PSCustomObject]@{
            CanUse            = $false
            Reason            = 'PlayerDead'
            SkillName         = [string]$skill.Name
            SkillType         = [string]$skill.SkillType
            CooldownRemaining = [double]0.0
        }
    }

    if (-not (Test-PlayerHasSkill -Player $Player -SkillName $skill.Name)) {
        return [PSCustomObject]@{
            CanUse            = $false
            Reason            = 'SkillLocked'
            SkillName         = [string]$skill.Name
            SkillType         = [string]$skill.SkillType
            CooldownRemaining = [double]0.0
        }
    }

    [double]$remaining = Get-PlayerSkillCooldownRemaining -Player $Player -SkillName $skill.Name
    if ($remaining -gt 0.0) {
        return [PSCustomObject]@{
            CanUse            = $false
            Reason            = 'OnCooldown'
            SkillName         = [string]$skill.Name
            SkillType         = [string]$skill.SkillType
            CooldownRemaining = [double]$remaining
        }
    }

    return [PSCustomObject]@{
        CanUse            = $true
        Reason            = 'OK'
        SkillName         = [string]$skill.Name
        SkillType         = [string]$skill.SkillType
        CooldownRemaining = [double]0.0
    }
}

function Invoke-PlayerDamageSkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)]$Skill,
        [Parameter(Mandatory = $true)]$Config,
        $Target,
        $PassiveBonuses
    )

    if ($null -eq $Target) {
        return [PSCustomObject]@{
            Applied       = $false
            Reason        = 'TargetRequired'
            DamageDone    = [int]0
            HealingDone   = [int]0
            Target        = $null
            Calculation   = $null
        }
    }

    $targetHP = Get-SkillEffectFieldValue -Object $Target -Name 'HP' -Default $null
    if ($null -eq $targetHP) {
        return [PSCustomObject]@{
            Applied       = $false
            Reason        = 'TargetMissingHP'
            DamageDone    = [int]0
            HealingDone   = [int]0
            Target        = $Target
            Calculation   = $null
        }
    }

    [double]$executeScaleBonus = 1.0
    if ([string]$Skill.Name -eq 'Execute') {
        [double]$hpNow = ConvertTo-SkillEffectDouble -Value $targetHP -Default 0.0
        [double]$targetMaxHP = ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $Target -Name 'MaxHP' -Default $hpNow) -Default $hpNow
        if ($targetMaxHP -gt 0.0) {
            [double]$missingRatio = [double]([Math]::Max(0.0, [Math]::Min(1.0, (($targetMaxHP - $hpNow) / $targetMaxHP))))
            $executeScaleBonus = [double](1.0 + ($missingRatio * 1.10))
        }
    }

    $calculation = Resolve-SkillDamageCalculation -Player $Player -Target $Target -DamageScale $Config.DamageScale -FlatDamage $Config.FlatDamage -IntelligenceScale $Config.IntelligenceScale -DamageType $Config.DamageType -PassiveBonuses $PassiveBonuses -ExecuteScaleBonus $executeScaleBonus
    $apply = Apply-SkillDamageToTarget -Target $Target -Damage ([int]$calculation.FinalDamage)

    return [PSCustomObject]@{
        Applied       = [bool]$apply.Applied
        Reason        = [string]$apply.Reason
        DamageDone    = [int]$apply.DamageDone
        HealingDone   = [int]0
        Target        = $Target
        TargetHPBefore = [double]$apply.HPBefore
        TargetHPAfter  = [double]$apply.HPAfter
        Defeated      = [bool]$apply.Defeated
        Calculation   = $calculation
    }
}

function Invoke-PlayerHealSkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)]$Config,
        $Target,
        $PassiveBonuses
    )

    $recipient = $Target
    if ($null -eq $recipient) {
        $recipient = $Player
    }

    if ($null -eq (Get-SkillEffectFieldValue -Object $recipient -Name 'HP' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $recipient -Name 'HP' -Value ([double]100.0)
    }
    if ($null -eq (Get-SkillEffectFieldValue -Object $recipient -Name 'MaxHP' -Default $null)) {
        Add-SkillEffectObjectProperty -Object $recipient -Name 'MaxHP' -Value ([double]100.0)
    }

    [int]$healAmount = Resolve-SkillHealingAmount -Player $Player -BaseHeal $Config.BaseHeal -HealScale $Config.HealScale -PassiveBonuses $PassiveBonuses
    $apply = Apply-SkillHealingToTarget -Target $recipient -Healing $healAmount

    return [PSCustomObject]@{
        Applied        = [bool]$apply.Applied
        Reason         = [string]$apply.Reason
        DamageDone     = [int]0
        HealingDone    = [int]$apply.HealingDone
        Target         = $recipient
        TargetHPBefore = [double]$apply.HPBefore
        TargetHPAfter  = [double]$apply.HPAfter
        Defeated       = $false
        Calculation    = [PSCustomObject]@{
            BaseHeal      = [int]$Config.BaseHeal
            HealScale     = [double]$Config.HealScale
            HealResolved  = [int]$healAmount
        }
    }
}

function Invoke-PlayerBuffSkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)]$Skill,
        [Parameter(Mandatory = $true)]$Config,
        $PassiveBonuses
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $state = Get-SkillEffectFieldValue -Object $Player -Name 'SkillState' -Default @{}
    if (-not ($state -is [System.Collections.IDictionary])) {
        $state = @{}
        Add-SkillEffectObjectProperty -Object $Player -Name 'SkillState' -Value $state
    }

    [double]$currentTime = Get-PlayerSkillTime -Player $Player
    [double]$duration = ConvertTo-SkillEffectDouble -Value $Config.BuffSeconds -Default 0.0
    if ($duration -lt 0.0) {
        $duration = [double]0.0
    }

    $stateKey = Normalize-SkillEffectKey -Name ([string]$Skill.Name)
    $state[$stateKey] = [PSCustomObject]@{
        SkillName    = [string]$Skill.Name
        ActiveFrom   = [double]$currentTime
        ActiveUntil  = [double]($currentTime + $duration)
    }

    if ([string]$Skill.Name -eq 'Guard Stance') {
        [double]$baseReduction = 0.35
        [double]$bonusReduction = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.GuardReductionBonus -Default 0.0
        [double]$totalReduction = [double]([Math]::Min(0.85, ($baseReduction + $bonusReduction)))
        Add-SkillEffectObjectProperty -Object $Player -Name 'GuardDamageReduction' -Value ([double][Math]::Round($totalReduction, 3))
        Add-SkillEffectObjectProperty -Object $Player -Name 'GuardStanceUntil' -Value ([double]($currentTime + $duration))
    }

    if ([string]$Skill.Name -eq 'Master Forging') {
        [double]$craftBonus = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.CraftEfficiencyBonus -Default 0.0
        Add-SkillEffectObjectProperty -Object $Player -Name 'CraftingEmpowerUntil' -Value ([double]($currentTime + $duration))
        Add-SkillEffectObjectProperty -Object $Player -Name 'CraftingEmpowerBonus' -Value ([double][Math]::Round((0.15 + $craftBonus), 3))
    }

    return [PSCustomObject]@{
        Applied       = $true
        Reason        = 'BuffApplied'
        DamageDone    = [int]0
        HealingDone   = [int]0
        Target        = $Player
        TargetHPBefore = [double](Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default 0.0)
        TargetHPAfter  = [double](Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default 0.0)
        Defeated      = $false
        Calculation   = [PSCustomObject]@{
            DurationSeconds = [double]$duration
            ActiveUntil     = [double]($currentTime + $duration)
        }
    }
}

function Invoke-PlayerUtilitySkill {
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)]$Skill,
        [Parameter(Mandatory = $true)]$Config,
        $PassiveBonuses
    )

    [double]$yieldBonus = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.ResourceYieldBonus -Default 0.0
    [double]$craftBonus = ConvertTo-SkillEffectDouble -Value $PassiveBonuses.CraftEfficiencyBonus -Default 0.0

    [int]$utilityScore = 1
    if ([string]$Skill.Name -eq 'Salvage') {
        [int]$intelligence = Get-PlayerIntelligenceValue -Player $Player
        $utilityScore = [int][Math]::Max(1, [int][Math]::Floor((1 + ($intelligence / 10.0) + ($yieldBonus * 2.0))))
    }

    return [PSCustomObject]@{
        Applied        = $true
        Reason         = 'UtilityApplied'
        DamageDone     = [int]0
        HealingDone    = [int]0
        Target         = $Player
        TargetHPBefore = [double](Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default 0.0)
        TargetHPAfter  = [double](Get-SkillEffectFieldValue -Object $Player -Name 'HP' -Default 0.0)
        Defeated       = $false
        Calculation    = [PSCustomObject]@{
            UtilityScore          = [int]$utilityScore
            ResourceYieldBonus    = [double][Math]::Round($yieldBonus, 3)
            CraftEfficiencyBonus  = [double][Math]::Round($craftBonus, 3)
        }
    }
}

function Use-PlayerSkill {
    <#
    .SYNOPSIS
        Executes one active skill and applies cooldown if successful.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [Parameter(Mandatory = $true)][string]$SkillName,
        $Target = $null
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    $gate = Can-UsePlayerSkill -Player $Player -SkillName $SkillName
    if (-not [bool]$gate.CanUse) {
        return [PSCustomObject]@{
            Used             = $false
            Reason           = [string]$gate.Reason
            SkillName        = [string]$gate.SkillName
            DamageDone       = [int]0
            HealingDone      = [int]0
            CooldownApplied  = [double]0.0
            CooldownRemaining = [double]$gate.CooldownRemaining
            PassiveBonuses   = Get-PlayerPassiveSkillBonuses -Player $Player
            VisualEffect     = $null
            Calculation      = $null
            Target           = $Target
        }
    }

    $skill = Get-Skill -Name $gate.SkillName
    if ($null -eq $skill) {
        return [PSCustomObject]@{
            Used             = $false
            Reason           = 'SkillNotFound'
            SkillName        = [string]$SkillName
            DamageDone       = [int]0
            HealingDone      = [int]0
            CooldownApplied  = [double]0.0
            CooldownRemaining = [double]0.0
            PassiveBonuses   = Get-PlayerPassiveSkillBonuses -Player $Player
            VisualEffect     = $null
            Calculation      = $null
            Target           = $Target
        }
    }

    $config = Get-ActiveSkillEffectConfig -SkillDefinition $skill
    $passiveBonuses = Get-PlayerPassiveSkillBonuses -Player $Player

    $execution = $null
    switch ([string]$config.Mode) {
        'Damage' {
            $execution = Invoke-PlayerDamageSkill -Player $Player -Skill $skill -Config $config -Target $Target -PassiveBonuses $passiveBonuses
            break
        }
        'Heal' {
            $execution = Invoke-PlayerHealSkill -Player $Player -Config $config -Target $Target -PassiveBonuses $passiveBonuses
            break
        }
        'Buff' {
            $execution = Invoke-PlayerBuffSkill -Player $Player -Skill $skill -Config $config -PassiveBonuses $passiveBonuses
            break
        }
        default {
            $execution = Invoke-PlayerUtilitySkill -Player $Player -Skill $skill -Config $config -PassiveBonuses $passiveBonuses
            break
        }
    }

    if ($null -eq $execution -or -not [bool]$execution.Applied) {
        return [PSCustomObject]@{
            Used             = $false
            Reason           = [string](Get-SkillEffectFieldValue -Object $execution -Name 'Reason' -Default 'SkillFailed')
            SkillName        = [string]$skill.Name
            DamageDone       = [int](ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $execution -Name 'DamageDone' -Default 0) -Default 0)
            HealingDone      = [int](ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $execution -Name 'HealingDone' -Default 0) -Default 0)
            CooldownApplied  = [double]0.0
            CooldownRemaining = [double]0.0
            PassiveBonuses   = $passiveBonuses
            VisualEffect     = $null
            Calculation      = (Get-SkillEffectFieldValue -Object $execution -Name 'Calculation' -Default $null)
            Target           = (Get-SkillEffectFieldValue -Object $execution -Name 'Target' -Default $Target)
        }
    }

    [double]$cooldownApplied = Set-PlayerSkillCooldown -Player $Player -SkillName $skill.Name -BaseCooldown $config.CooldownSeconds -PassiveBonuses $passiveBonuses
    [double]$remainingCooldown = Get-PlayerSkillCooldownRemaining -Player $Player -SkillName $skill.Name

    [int]$magnitude = [int](ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $execution -Name 'DamageDone' -Default 0) -Default 0)
    if ($magnitude -lt 1) {
        $magnitude = [int](ConvertTo-SkillEffectInt -Value (Get-SkillEffectFieldValue -Object $execution -Name 'HealingDone' -Default 0) -Default 0)
    }

    [double]$skillTime = Get-PlayerSkillTime -Player $Player
    $visual = New-SkillVisualEffectMetadata -SkillName ([string]$skill.Name) -Mode ([string]$config.Mode) -SkillTime $skillTime -Magnitude $magnitude
    Push-PlayerSkillVisualEffect -Player $Player -Visual $visual | Out-Null

    return [PSCustomObject]@{
        Used             = $true
        Reason           = [string]$execution.Reason
        SkillName        = [string]$skill.Name
        SkillType        = [string]$skill.SkillType
        DamageDone       = [int](ConvertTo-SkillEffectInt -Value $execution.DamageDone -Default 0)
        HealingDone      = [int](ConvertTo-SkillEffectInt -Value $execution.HealingDone -Default 0)
        CooldownApplied  = [double]$cooldownApplied
        CooldownRemaining = [double]$remainingCooldown
        PassiveBonuses   = $passiveBonuses
        VisualEffect     = $visual
        Calculation      = $execution.Calculation
        Target           = $execution.Target
        TargetHPBefore   = [double](ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $execution -Name 'TargetHPBefore' -Default 0.0) -Default 0.0)
        TargetHPAfter    = [double](ConvertTo-SkillEffectDouble -Value (Get-SkillEffectFieldValue -Object $execution -Name 'TargetHPAfter' -Default 0.0) -Default 0.0)
        Defeated         = [bool](Get-SkillEffectFieldValue -Object $execution -Name 'Defeated' -Default $false)
        SkillTime        = [double]$skillTime
    }
}

# ============================================================================
# Public API - Initialization and status
# ============================================================================

function Initialize-SkillEffectsSystem {
    <#
    .SYNOPSIS
        Initializes skill effect maps using existing Skills.ps1 catalog.
    #>
    param([switch]$Quiet)

    $allSkills = @(Get-Skills)
    if ($allSkills.Count -gt $script:SkillEffectsSkillCap) {
        throw "Skill definition count exceeds cap ($($allSkills.Count)/$($script:SkillEffectsSkillCap))."
    }

    $script:SkillActiveEffectMap = @{}
    foreach ($row in @(Get-DefaultActiveSkillEffectRows)) {
        $definition = Get-Skill -Name ([string]$row.Name)
        if ($null -eq $definition) {
            continue
        }

        if ([string]$definition.SkillType -ne 'Active') {
            continue
        }

        $script:SkillActiveEffectMap[$definition.Key] = [PSCustomObject]@{
            Name              = [string]$definition.Name
            Key               = [string]$definition.Key
            Mode              = [string]$row.Mode
            CooldownSeconds   = [double](ConvertTo-SkillEffectDouble -Value $row.CooldownSeconds -Default 0.0)
            DamageScale       = [double](ConvertTo-SkillEffectDouble -Value $row.DamageScale -Default 0.0)
            FlatDamage        = [int](ConvertTo-SkillEffectInt -Value $row.FlatDamage -Default 0)
            DamageType        = [string]$row.DamageType
            IntelligenceScale = [double](ConvertTo-SkillEffectDouble -Value $row.IntelligenceScale -Default 0.0)
            BaseHeal          = [int](ConvertTo-SkillEffectInt -Value $row.BaseHeal -Default 0)
            HealScale         = [double](ConvertTo-SkillEffectDouble -Value $row.HealScale -Default 0.0)
            BuffSeconds       = [double](ConvertTo-SkillEffectDouble -Value $row.BuffSeconds -Default 0.0)
        }
    }

    $script:SkillPassiveBonusMap = @{}
    foreach ($row in @(Get-DefaultPassiveSkillBonusRows)) {
        $definition = Get-Skill -Name ([string]$row.Name)
        if ($null -eq $definition) {
            continue
        }

        if ([string]$definition.SkillType -ne 'Passive') {
            continue
        }

        $script:SkillPassiveBonusMap[$definition.Key] = [PSCustomObject]@{
            Name                 = [string]$definition.Name
            Key                  = [string]$definition.Key
            DamageMultiplier     = [double](ConvertTo-SkillEffectDouble -Value $row.DamageMultiplier -Default 0.0)
            DamageFlatBonus      = [int](ConvertTo-SkillEffectInt -Value $row.DamageFlatBonus -Default 0)
            CooldownFactor       = [double](ConvertTo-SkillEffectDouble -Value $row.CooldownFactor -Default 1.0)
            HealingMultiplier    = [double](ConvertTo-SkillEffectDouble -Value $row.HealingMultiplier -Default 0.0)
            ArmorPenetration     = [int](ConvertTo-SkillEffectInt -Value $row.ArmorPenetration -Default 0)
            GuardReductionBonus  = [double](ConvertTo-SkillEffectDouble -Value $row.GuardReductionBonus -Default 0.0)
            CraftEfficiencyBonus = [double](ConvertTo-SkillEffectDouble -Value $row.CraftEfficiencyBonus -Default 0.0)
            ResourceYieldBonus   = [double](ConvertTo-SkillEffectDouble -Value $row.ResourceYieldBonus -Default 0.0)
        }
    }

    $script:SkillEffectsInitialized = $true

    if (-not $Quiet) {
        Write-Host ("[SkillEffects] Initialized with {0} active effects and {1} passive bonus rows." -f $script:SkillActiveEffectMap.Count, $script:SkillPassiveBonusMap.Count) -ForegroundColor Green
    }

    return [PSCustomObject]@{
        SkillCount         = [int]$allSkills.Count
        SkillCap           = [int]$script:SkillEffectsSkillCap
        ActiveEffectCount  = [int]$script:SkillActiveEffectMap.Count
        PassiveBonusCount  = [int]$script:SkillPassiveBonusMap.Count
    }
}

function Get-SkillEffectsSystemStatus {
    Ensure-SkillEffectsSystem

    return [PSCustomObject]@{
        Initialized        = [bool]$script:SkillEffectsInitialized
        ActiveEffectCount  = [int]$script:SkillActiveEffectMap.Count
        PassiveBonusCount  = [int]$script:SkillPassiveBonusMap.Count
        SkillCap           = [int]$script:SkillEffectsSkillCap
        DefaultPlayerBound = [bool]($null -ne $script:SkillEffectsDefaultPlayer)
    }
}

function Enable-SkillEffectsForPlayer {
    <#
    .SYNOPSIS
        Adds skill effects properties and script methods to a player object.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        [switch]$SetActive
    )

    Ensure-PlayerSkillEffectsShape -Player $Player

    if ($SetActive -or $null -eq $script:SkillEffectsDefaultPlayer) {
        $script:SkillEffectsDefaultPlayer = $Player
    }

    return [PSCustomObject]@{
        Player         = $Player
        PlayerName     = [string](Get-PlayerNameSafe -Player $Player)
        SkillTreeBound = [bool]($null -ne (Get-SkillEffectFieldValue -Object $Player -Name 'SkillTree' -Default $null))
        StarterSkill   = 'Power Strike'
    }
}

function Get-ActiveSkillEffectsPlayer {
    Ensure-SkillEffectsSystem
    if ($null -eq $script:SkillEffectsDefaultPlayer) {
        $script:SkillEffectsDefaultPlayer = New-Player -Name 'Player' -Level 1 -XP 0
    }

    return $script:SkillEffectsDefaultPlayer
}

function Set-ActiveSkillEffectsPlayer {
    param(
        [Parameter(Mandatory = $true)]$Player
    )

    Enable-SkillEffectsForPlayer -Player $Player -SetActive | Out-Null
    return $true
}

function New-Player {
    <#
    .SYNOPSIS
        Creates or augments a player with SkillEffects API surface.
    .DESCRIPTION
        Wraps upstream New-Player (typically StatProgression.ps1), then enables
        skill execution, cooldowns, passive bonuses, and visual effect metadata.
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

    Ensure-SkillEffectsSystem

    $player = $null
    if ($null -ne $script:SkillEffectsUpstreamNewPlayer) {
        try {
            $player = & $script:SkillEffectsUpstreamNewPlayer -Name $Name -Level $Level -XP $XP -Strength $Strength -Dexterity $Dexterity -Vitality $Vitality -Intelligence $Intelligence -StatPointsPerLevel $StatPointsPerLevel -UnspentStatPoints $UnspentStatPoints -SetActive:$SetActive
        }
        catch {
            $player = $null
        }
    }

    if ($null -eq $player) {
        $player = [PSCustomObject]@{
            Name         = [string]$Name
            Level        = [int]([Math]::Max(1, $Level))
            XP           = [int]([Math]::Max(0, $XP))
            Strength     = [int]([Math]::Max(1, $Strength))
            Dexterity    = [int]([Math]::Max(1, $Dexterity))
            Vitality     = [int]([Math]::Max(1, $Vitality))
            Intelligence = [int]([Math]::Max(1, $Intelligence))
        }
    }

    $enabled = Enable-SkillEffectsForPlayer -Player $player -SetActive:$SetActive
    return $enabled.Player
}

# Initialize on dot-source.
Initialize-SkillEffectsSystem -Quiet | Out-Null
