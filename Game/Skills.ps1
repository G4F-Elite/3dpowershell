# ============================================================================
# Game/Skills.ps1 - Skill Tree Data Model and Unlock Logic
# ============================================================================
# Provides:
# - Deterministic skill catalog for Combat, Crafting, Survival
# - Active and Passive skill metadata
# - Prerequisite-aware unlock flow and skill point accounting
# - UI-ready tree layout model (tier/column/row data only)
# - Optional integration surface for Experience.ps1 level-up callbacks
#
# Scope guardrails:
# - Model-focused only (no effects/cooldowns/combat math)
# - Skill definition count capped at 30
# ============================================================================

# --- Module State ---
$script:SkillSystemInitialized = $false
$script:SkillDefinitionsByKey = @{}
$script:SkillDefinitionList = @()
$script:SkillCategoryOrder = @('Combat', 'Crafting', 'Survival')
$script:SkillTypeOrder = @('Active', 'Passive')
$script:SkillMaxDefinitionCount = [int]30
$script:SkillDefaultStartingPoints = [int]1
$script:SkillDefaultPointsPerLevel = [int]1

# ============================================================================
# Internal Helpers
# ============================================================================

function ConvertTo-SkillInt {
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

function Normalize-SkillKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return [string]$Name.Trim().ToLowerInvariant()
}

function Add-SkillObjectProperty {
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

function Get-SkillCategoryRank {
    param([string]$Category)

    for ([int]$i = 0; $i -lt $script:SkillCategoryOrder.Count; $i++) {
        if ([string]::Equals([string]$script:SkillCategoryOrder[$i], [string]$Category, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [int]$i
        }
    }

    return [int]999
}

function Get-SkillTypeRank {
    param([string]$SkillType)

    for ([int]$i = 0; $i -lt $script:SkillTypeOrder.Count; $i++) {
        if ([string]::Equals([string]$script:SkillTypeOrder[$i], [string]$SkillType, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [int]$i
        }
    }

    return [int]999
}

function ConvertTo-SkillCategory {
    param(
        [string]$Category,
        [switch]$ThrowOnInvalid
    )

    if ([string]::IsNullOrWhiteSpace($Category)) {
        if ($ThrowOnInvalid) {
            throw 'Skill category is required.'
        }

        return ''
    }

    switch ($Category.Trim().ToLowerInvariant()) {
        'combat' { return 'Combat' }
        'crafting' { return 'Crafting' }
        'survival' { return 'Survival' }
        default {
            if ($ThrowOnInvalid) {
                throw "Unsupported skill category '$Category'. Allowed: Combat, Crafting, Survival."
            }

            return ''
        }
    }
}

function ConvertTo-SkillType {
    param(
        [string]$SkillType,
        [switch]$ThrowOnInvalid
    )

    if ([string]::IsNullOrWhiteSpace($SkillType)) {
        if ($ThrowOnInvalid) {
            throw 'Skill type is required.'
        }

        return ''
    }

    switch ($SkillType.Trim().ToLowerInvariant()) {
        'active' { return 'Active' }
        'passive' { return 'Passive' }
        default {
            if ($ThrowOnInvalid) {
                throw "Unsupported skill type '$SkillType'. Allowed: Active, Passive."
            }

            return ''
        }
    }
}

function Resolve-SkillDefinition {
    param($Skill)

    Ensure-SkillSystem

    if ($null -eq $Skill) {
        return $null
    }

    if ($Skill -is [string]) {
        $key = Normalize-SkillKey -Name ([string]$Skill)
        if ($script:SkillDefinitionsByKey.ContainsKey($key)) {
            return $script:SkillDefinitionsByKey[$key]
        }

        return $null
    }

    if ($null -ne $Skill.PSObject.Properties['Key']) {
        $keyFromObject = Normalize-SkillKey -Name ([string]$Skill.Key)
        if ($script:SkillDefinitionsByKey.ContainsKey($keyFromObject)) {
            return $script:SkillDefinitionsByKey[$keyFromObject]
        }
    }

    if ($null -ne $Skill.PSObject.Properties['Name']) {
        $nameFromObject = Normalize-SkillKey -Name ([string]$Skill.Name)
        if ($script:SkillDefinitionsByKey.ContainsKey($nameFromObject)) {
            return $script:SkillDefinitionsByKey[$nameFromObject]
        }
    }

    return $null
}

function New-SkillDefinitionInternal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$SkillType,
        [string]$Description = '',
        [int]$Cost = 1,
        [string[]]$Prerequisites = @(),
        [int]$Tier = 1,
        [int]$Column = 1,
        [int]$Row = 1
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Skill name is required.'
    }

    $safeName = [string]$Name.Trim()
    $safeCategory = ConvertTo-SkillCategory -Category $Category -ThrowOnInvalid
    $safeSkillType = ConvertTo-SkillType -SkillType $SkillType -ThrowOnInvalid

    [int]$safeCost = ConvertTo-SkillInt -Value $Cost -Default 1
    if ($safeCost -lt 1) {
        $safeCost = [int]1
    }

    [int]$safeTier = ConvertTo-SkillInt -Value $Tier -Default 1
    if ($safeTier -lt 1) {
        $safeTier = [int]1
    }

    [int]$safeColumn = ConvertTo-SkillInt -Value $Column -Default 1
    if ($safeColumn -lt 1) {
        $safeColumn = [int]1
    }

    [int]$safeRow = ConvertTo-SkillInt -Value $Row -Default 1
    if ($safeRow -lt 1) {
        $safeRow = [int]1
    }

    $safePrerequisites = @()
    foreach ($prerequisite in @($Prerequisites)) {
        if ([string]::IsNullOrWhiteSpace([string]$prerequisite)) {
            continue
        }

        $trimmed = [string]$prerequisite.Trim()
        $trimmedKey = Normalize-SkillKey -Name $trimmed

        $alreadyIncluded = $false
        foreach ($existing in @($safePrerequisites)) {
            if ([string]::Equals((Normalize-SkillKey -Name $existing), $trimmedKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyIncluded = $true
                break
            }
        }

        if (-not $alreadyIncluded) {
            $safePrerequisites += $trimmed
        }
    }

    $safeDescription = [string]$Description
    if ([string]::IsNullOrWhiteSpace($safeDescription)) {
        $safeDescription = "$safeName skill"
    }

    return [PSCustomObject]@{
        Name          = [string]$safeName
        Key           = (Normalize-SkillKey -Name $safeName)
        Category      = [string]$safeCategory
        SkillType     = [string]$safeSkillType
        Description   = [string]$safeDescription.Trim()
        Cost          = [int]$safeCost
        Prerequisites = @($safePrerequisites)
        Tier          = [int]$safeTier
        UI            = [PSCustomObject]@{
            Tier   = [int]$safeTier
            Column = [int]$safeColumn
            Row    = [int]$safeRow
        }
    }
}

function Register-SkillDefinitionInternal {
    param(
        [Parameter(Mandatory = $true)]$Definition
    )

    $resolved = Resolve-SkillDefinition -Skill $Definition
    if ($null -ne $resolved) {
        throw "Duplicate skill definition '$($Definition.Name)'."
    }

    $key = Normalize-SkillKey -Name ([string]$Definition.Name)
    $script:SkillDefinitionsByKey[$key] = $Definition
    $script:SkillDefinitionList += $Definition
}

function Get-DefaultSkillDefinitionRows {
    return @(
        @{ Name = 'Power Strike';         Category = 'Combat';   SkillType = 'Active';  Cost = 1; Tier = 1; Column = 1; Row = 1; Description = 'Heavy single-target strike.';                     Prerequisites = @() },
        @{ Name = 'Guard Stance';         Category = 'Combat';   SkillType = 'Active';  Cost = 1; Tier = 1; Column = 2; Row = 1; Description = 'Prepared defensive posture.';                    Prerequisites = @() },
        @{ Name = 'Veteran Conditioning'; Category = 'Combat';   SkillType = 'Passive'; Cost = 1; Tier = 1; Column = 3; Row = 1; Description = 'Foundational combat conditioning.';              Prerequisites = @() },
        @{ Name = 'Whirlwind';            Category = 'Combat';   SkillType = 'Active';  Cost = 1; Tier = 2; Column = 1; Row = 2; Description = 'Wide arc melee attack.';                        Prerequisites = @('Power Strike') },
        @{ Name = 'Counter Mastery';      Category = 'Combat';   SkillType = 'Passive'; Cost = 1; Tier = 2; Column = 2; Row = 2; Description = 'Improved reaction timing.';                     Prerequisites = @('Guard Stance') },
        @{ Name = 'Battle Rhythm';        Category = 'Combat';   SkillType = 'Passive'; Cost = 1; Tier = 2; Column = 3; Row = 2; Description = 'Maintains momentum in extended fights.';         Prerequisites = @('Veteran Conditioning') },
        @{ Name = 'Execute';              Category = 'Combat';   SkillType = 'Active';  Cost = 1; Tier = 3; Column = 2; Row = 3; Description = 'High commitment finishing move.';                Prerequisites = @('Whirlwind', 'Battle Rhythm') },

        @{ Name = 'Basic Smithing';       Category = 'Crafting'; SkillType = 'Passive'; Cost = 1; Tier = 1; Column = 1; Row = 1; Description = 'Basic crafting discipline.';                     Prerequisites = @() },
        @{ Name = 'Efficient Crafting';   Category = 'Crafting'; SkillType = 'Passive'; Cost = 1; Tier = 2; Column = 1; Row = 2; Description = 'Reduce material waste in recipes.';              Prerequisites = @('Basic Smithing') },
        @{ Name = 'Salvage';              Category = 'Crafting'; SkillType = 'Active';  Cost = 1; Tier = 2; Column = 2; Row = 2; Description = 'Break down gear for resources.';                  Prerequisites = @('Basic Smithing') },
        @{ Name = 'Precision Tools';      Category = 'Crafting'; SkillType = 'Passive'; Cost = 1; Tier = 3; Column = 1; Row = 3; Description = 'Improved quality control in crafting.';          Prerequisites = @('Efficient Crafting') },
        @{ Name = 'Master Forging';       Category = 'Crafting'; SkillType = 'Active';  Cost = 1; Tier = 3; Column = 2; Row = 3; Description = 'Unlock advanced forge workflow.';                 Prerequisites = @('Precision Tools', 'Salvage') },

        @{ Name = 'Forager';              Category = 'Survival'; SkillType = 'Passive'; Cost = 1; Tier = 1; Column = 1; Row = 1; Description = 'Improved field resource awareness.';              Prerequisites = @() },
        @{ Name = 'Campfire';             Category = 'Survival'; SkillType = 'Active';  Cost = 1; Tier = 1; Column = 2; Row = 1; Description = 'Deploy a basic campsite.';                        Prerequisites = @() },
        @{ Name = 'Trail Awareness';      Category = 'Survival'; SkillType = 'Passive'; Cost = 1; Tier = 2; Column = 1; Row = 2; Description = 'Navigate terrain with better planning.';          Prerequisites = @('Forager') },
        @{ Name = 'Endurance';            Category = 'Survival'; SkillType = 'Passive'; Cost = 1; Tier = 2; Column = 2; Row = 2; Description = 'Steady stamina in long expeditions.';             Prerequisites = @('Campfire') },
        @{ Name = 'Beast Lore';           Category = 'Survival'; SkillType = 'Active';  Cost = 1; Tier = 3; Column = 1; Row = 3; Description = 'Active tracking and creature insight.';           Prerequisites = @('Trail Awareness') },
        @{ Name = 'Wilderness Mastery';   Category = 'Survival'; SkillType = 'Passive'; Cost = 1; Tier = 3; Column = 2; Row = 3; Description = 'Complete survival discipline mastery.';          Prerequisites = @('Endurance', 'Beast Lore') }
    )
}

function Add-DefaultSkillDefinitions {
    $rows = @(Get-DefaultSkillDefinitionRows)
    foreach ($row in @($rows)) {
        $definition = New-SkillDefinitionInternal -Name $row.Name -Category $row.Category -SkillType $row.SkillType -Description $row.Description -Cost $row.Cost -Prerequisites $row.Prerequisites -Tier $row.Tier -Column $row.Column -Row $row.Row
        Register-SkillDefinitionInternal -Definition $definition
    }

    foreach ($definition in @($script:SkillDefinitionList)) {
        $canonicalPrerequisites = @()

        foreach ($prerequisite in @($definition.Prerequisites)) {
            $preKey = Normalize-SkillKey -Name ([string]$prerequisite)
            if (-not $script:SkillDefinitionsByKey.ContainsKey($preKey)) {
                throw "Skill '$($definition.Name)' references unknown prerequisite '$prerequisite'."
            }

            $canonicalPrerequisites += [string]$script:SkillDefinitionsByKey[$preKey].Name
        }

        $definition.Prerequisites = @($canonicalPrerequisites)
    }
}

# ============================================================================
# Public API - Initialization and Metadata
# ============================================================================

function Initialize-SkillSystem {
    <#
    .SYNOPSIS
        Initializes deterministic skill definitions and metadata.
    #>
    param([switch]$Quiet)

    $script:SkillSystemInitialized = $true
    $script:SkillDefinitionsByKey = @{}
    $script:SkillDefinitionList = @()

    Add-DefaultSkillDefinitions

    if ($script:SkillDefinitionList.Count -gt $script:SkillMaxDefinitionCount) {
        throw "Skill definition count exceeds cap ($($script:SkillDefinitionList.Count)/$($script:SkillMaxDefinitionCount))."
    }

    if (-not $Quiet) {
        Write-Host "[Skills] Skill system initialized ($($script:SkillDefinitionList.Count) skills)." -ForegroundColor Green
    }

    return [PSCustomObject]@{
        SkillCount  = [int]$script:SkillDefinitionList.Count
        Categories  = @($script:SkillCategoryOrder)
        SkillTypes  = @($script:SkillTypeOrder)
        MaxSkills   = [int]$script:SkillMaxDefinitionCount
    }
}

function Ensure-SkillSystem {
    if (-not $script:SkillSystemInitialized) {
        Initialize-SkillSystem -Quiet | Out-Null
    }
}

function Get-SkillCategories {
    <#
    .SYNOPSIS
        Returns canonical skill categories.
    #>
    Ensure-SkillSystem
    return @($script:SkillCategoryOrder)
}

function Get-SkillTypes {
    <#
    .SYNOPSIS
        Returns canonical skill types.
    #>
    Ensure-SkillSystem
    return @($script:SkillTypeOrder)
}

function Get-Skills {
    <#
    .SYNOPSIS
        Returns deterministic skill definitions.
    #>
    param(
        [string]$Category = '',
        [string]$SkillType = ''
    )

    Ensure-SkillSystem

    $categoryFilter = ''
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $categoryFilter = ConvertTo-SkillCategory -Category $Category
        if ([string]::IsNullOrWhiteSpace($categoryFilter)) {
            return @()
        }
    }

    $skillTypeFilter = ''
    if (-not [string]::IsNullOrWhiteSpace($SkillType)) {
        $skillTypeFilter = ConvertTo-SkillType -SkillType $SkillType
        if ([string]::IsNullOrWhiteSpace($skillTypeFilter)) {
            return @()
        }
    }

    $ordered = @(
        $script:SkillDefinitionList |
            Sort-Object `
                @{ Expression = { Get-SkillCategoryRank -Category $_.Category }; Ascending = $true }, `
                @{ Expression = { [int]$_.Tier }; Ascending = $true }, `
                @{ Expression = { [int]$_.UI.Row }; Ascending = $true }, `
                @{ Expression = { [int]$_.UI.Column }; Ascending = $true }, `
                @{ Expression = { Get-SkillTypeRank -SkillType $_.SkillType }; Ascending = $true }, `
                @{ Expression = { [string]$_.Name }; Ascending = $true }
    )

    $result = @()
    foreach ($entry in @($ordered)) {
        if (-not [string]::IsNullOrWhiteSpace($categoryFilter) -and (-not [string]::Equals([string]$entry.Category, $categoryFilter, [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($skillTypeFilter) -and (-not [string]::Equals([string]$entry.SkillType, $skillTypeFilter, [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }

        $result += $entry
    }

    return @($result)
}

function Get-Skill {
    <#
    .SYNOPSIS
        Returns one skill definition by name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    return (Resolve-SkillDefinition -Skill $Name)
}

# ============================================================================
# Skill Tree Object Construction
# ============================================================================

function Add-SkillTreeScriptMethods {
    param(
        [Parameter(Mandatory = $true)]$SkillTree
    )

    $SkillTree | Add-Member -MemberType ScriptMethod -Name UnlockSkill -Value {
        param([string]$SkillName)
        return (Unlock-Skill -SkillTree $this -SkillName $SkillName)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name HasSkill -Value {
        param([string]$SkillName)
        return (Test-SkillUnlocked -SkillTree $this -SkillName $SkillName)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name CanUnlockSkill -Value {
        param([string]$SkillName)
        return (Can-UnlockSkill -SkillTree $this -SkillName $SkillName)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GetSkill -Value {
        param([string]$SkillName)
        return (Get-Skill -Name $SkillName)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GetUnlockedSkills -Value {
        return (Get-UnlockedSkills -SkillTree $this)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GetAvailableSkills -Value {
        return (Get-AvailableSkills -SkillTree $this)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GetSkillPoints -Value {
        return (Get-SkillPointSummary -SkillTree $this)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GrantSkillPointsFromLevelUp -Value {
        param(
            [int]$LevelsGained = 1,
            [string]$Source = 'LevelUp'
        )

        return (Grant-SkillPointsFromLevelUp -SkillTree $this -LevelsGained $LevelsGained -Source $Source)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name SyncFromLevel -Value {
        param(
            [int]$Level,
            [string]$Source = 'LevelSync'
        )

        return (Sync-SkillTreeLevel -SkillTree $this -Level $Level -Source $Source)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name GetUIStructure -Value {
        return (Get-SkillTreeUIStructure -SkillTree $this)
    } -Force

    $SkillTree | Add-Member -MemberType ScriptMethod -Name ConnectExperience -Value {
        param(
            $Player = $null,
            [switch]$SyncCurrentLevel
        )

        return (Connect-SkillTreeExperience -SkillTree $this -Player $Player -SyncCurrentLevel:$SyncCurrentLevel)
    } -Force
}

function Ensure-SkillTreeShape {
    param(
        [Parameter(Mandatory = $true)]$SkillTree
    )

    Ensure-SkillSystem

    if ($null -eq $SkillTree.PSObject.Properties['PlayerName']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'PlayerName' -Value ''
    }

    if ($null -eq $SkillTree.PSObject.Properties['SkillPointsAvailable']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'SkillPointsAvailable' -Value ([int]0)
    }

    if ($null -eq $SkillTree.PSObject.Properties['SkillPointsSpent']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'SkillPointsSpent' -Value ([int]0)
    }

    if ($null -eq $SkillTree.PSObject.Properties['SkillPointsEarned']) {
        [int]$derivedEarned = [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsAvailable -Default 0) + [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsSpent -Default 0)
        Add-SkillObjectProperty -Object $SkillTree -Name 'SkillPointsEarned' -Value ([int]$derivedEarned)
    }

    if ($null -eq $SkillTree.PSObject.Properties['SkillPointsPerLevel']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'SkillPointsPerLevel' -Value ([int]$script:SkillDefaultPointsPerLevel)
    }

    if ($null -eq $SkillTree.PSObject.Properties['LastKnownLevel']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'LastKnownLevel' -Value ([int]1)
    }

    if ($null -eq $SkillTree.PSObject.Properties['MaxSkills']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'MaxSkills' -Value ([int]$script:SkillMaxDefinitionCount)
    }

    if ($null -eq $SkillTree.PSObject.Properties['UnlockedSkillKeys']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'UnlockedSkillKeys' -Value @{}
    }

    if ($null -eq $SkillTree.PSObject.Properties['ExperienceHookRegistered']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'ExperienceHookRegistered' -Value $false
    }

    if ($null -eq $SkillTree.PSObject.Properties['ExperienceHookId']) {
        Add-SkillObjectProperty -Object $SkillTree -Name 'ExperienceHookId' -Value ([int]0)
    }

    $SkillTree.PlayerName = [string]$SkillTree.PlayerName

    $SkillTree.SkillPointsAvailable = [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsAvailable -Default 0)
    if ($SkillTree.SkillPointsAvailable -lt 0) {
        $SkillTree.SkillPointsAvailable = [int]0
    }

    $SkillTree.SkillPointsSpent = [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsSpent -Default 0)
    if ($SkillTree.SkillPointsSpent -lt 0) {
        $SkillTree.SkillPointsSpent = [int]0
    }

    $SkillTree.SkillPointsEarned = [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsEarned -Default 0)
    if ($SkillTree.SkillPointsEarned -lt ($SkillTree.SkillPointsAvailable + $SkillTree.SkillPointsSpent)) {
        $SkillTree.SkillPointsEarned = [int]($SkillTree.SkillPointsAvailable + $SkillTree.SkillPointsSpent)
    }

    $SkillTree.SkillPointsPerLevel = [int](ConvertTo-SkillInt -Value $SkillTree.SkillPointsPerLevel -Default $script:SkillDefaultPointsPerLevel)
    if ($SkillTree.SkillPointsPerLevel -lt 1) {
        $SkillTree.SkillPointsPerLevel = [int]1
    }

    $SkillTree.LastKnownLevel = [int](ConvertTo-SkillInt -Value $SkillTree.LastKnownLevel -Default 1)
    if ($SkillTree.LastKnownLevel -lt 1) {
        $SkillTree.LastKnownLevel = [int]1
    }

    $SkillTree.MaxSkills = [int](ConvertTo-SkillInt -Value $SkillTree.MaxSkills -Default $script:SkillMaxDefinitionCount)
    if ($SkillTree.MaxSkills -lt 1) {
        $SkillTree.MaxSkills = [int]1
    }

    if ($SkillTree.MaxSkills -gt $script:SkillMaxDefinitionCount) {
        $SkillTree.MaxSkills = [int]$script:SkillMaxDefinitionCount
    }

    if ($SkillTree.MaxSkills -gt $script:SkillDefinitionList.Count) {
        $SkillTree.MaxSkills = [int]$script:SkillDefinitionList.Count
    }

    $normalizedUnlockedMap = @{}
    if ($SkillTree.UnlockedSkillKeys -is [System.Collections.IDictionary]) {
        foreach ($entryKey in @($SkillTree.UnlockedSkillKeys.Keys)) {
            $entryName = [string]$SkillTree.UnlockedSkillKeys[$entryKey]
            $definition = Resolve-SkillDefinition -Skill $entryName
            if ($null -eq $definition) {
                $definition = Resolve-SkillDefinition -Skill ([string]$entryKey)
            }

            if ($null -ne $definition) {
                $normalizedUnlockedMap[$definition.Key] = [string]$definition.Name
            }
        }
    }
    else {
        foreach ($entry in @($SkillTree.UnlockedSkillKeys)) {
            $definition = Resolve-SkillDefinition -Skill $entry
            if ($null -ne $definition) {
                $normalizedUnlockedMap[$definition.Key] = [string]$definition.Name
            }
        }
    }

    $SkillTree.UnlockedSkillKeys = $normalizedUnlockedMap
    $SkillTree.ExperienceHookRegistered = [bool]$SkillTree.ExperienceHookRegistered
    $SkillTree.ExperienceHookId = [int](ConvertTo-SkillInt -Value $SkillTree.ExperienceHookId -Default 0)

    Add-SkillTreeScriptMethods -SkillTree $SkillTree
}

function New-SkillTree {
    <#
    .SYNOPSIS
        Creates a deterministic skill tree state object.
    #>
    param(
        [int]$StartingSkillPoints = 1,
        [int]$SkillPointsPerLevel = 1,
        [int]$CurrentLevel = 1,
        [int]$MaxSkills = 30,
        [string]$PlayerName = '',
        [switch]$AutoConnectExperience
    )

    Ensure-SkillSystem

    [int]$safeStartingPoints = ConvertTo-SkillInt -Value $StartingSkillPoints -Default $script:SkillDefaultStartingPoints
    if ($safeStartingPoints -lt 0) {
        $safeStartingPoints = [int]0
    }

    [int]$safePointsPerLevel = ConvertTo-SkillInt -Value $SkillPointsPerLevel -Default $script:SkillDefaultPointsPerLevel
    if ($safePointsPerLevel -lt 1) {
        $safePointsPerLevel = [int]1
    }

    [int]$safeCurrentLevel = ConvertTo-SkillInt -Value $CurrentLevel -Default 1
    if ($safeCurrentLevel -lt 1) {
        $safeCurrentLevel = [int]1
    }

    [int]$safeMaxSkills = ConvertTo-SkillInt -Value $MaxSkills -Default $script:SkillMaxDefinitionCount
    if ($safeMaxSkills -lt 1) {
        $safeMaxSkills = [int]1
    }

    if ($safeMaxSkills -gt $script:SkillMaxDefinitionCount) {
        $safeMaxSkills = [int]$script:SkillMaxDefinitionCount
    }

    if ($safeMaxSkills -gt $script:SkillDefinitionList.Count) {
        $safeMaxSkills = [int]$script:SkillDefinitionList.Count
    }

    $tree = [PSCustomObject]@{
        PlayerName             = [string]$PlayerName
        SkillPointsAvailable   = [int]$safeStartingPoints
        SkillPointsSpent       = [int]0
        SkillPointsEarned      = [int]$safeStartingPoints
        SkillPointsPerLevel    = [int]$safePointsPerLevel
        LastKnownLevel         = [int]$safeCurrentLevel
        MaxSkills              = [int]$safeMaxSkills
        UnlockedSkillKeys      = @{}
        ExperienceHookRegistered = $false
        ExperienceHookId       = [int]0
    }

    Ensure-SkillTreeShape -SkillTree $tree

    if ($AutoConnectExperience) {
        Connect-SkillTreeExperience -SkillTree $tree -SyncCurrentLevel | Out-Null
    }

    return $tree
}

# ============================================================================
# Skill Tree Query and Unlock APIs
# ============================================================================

function Get-SkillPointSummary {
    <#
    .SYNOPSIS
        Returns available/spent/earned skill point totals.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    return [PSCustomObject]@{
        Available      = [int]$SkillTree.SkillPointsAvailable
        Spent          = [int]$SkillTree.SkillPointsSpent
        Earned         = [int]$SkillTree.SkillPointsEarned
        PointsPerLevel = [int]$SkillTree.SkillPointsPerLevel
        LastKnownLevel = [int]$SkillTree.LastKnownLevel
    }
}

function Test-SkillUnlocked {
    <#
    .SYNOPSIS
        Returns true if a skill is unlocked in tree state.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $definition = Resolve-SkillDefinition -Skill $SkillName
    if ($null -eq $definition) {
        return $false
    }

    return [bool]$SkillTree.UnlockedSkillKeys.ContainsKey($definition.Key)
}

function Test-SkillPrerequisites {
    <#
    .SYNOPSIS
        Evaluates prerequisite status for a skill.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $definition = Resolve-SkillDefinition -Skill $SkillName
    if ($null -eq $definition) {
        return [PSCustomObject]@{
            SkillName            = [string]$SkillName
            SkillExists          = $false
            AllMet               = $false
            MissingPrerequisites = @()
        }
    }

    $missing = @()
    foreach ($prerequisite in @($definition.Prerequisites)) {
        if (-not (Test-SkillUnlocked -SkillTree $SkillTree -SkillName $prerequisite)) {
            $missing += [string]$prerequisite
        }
    }

    return [PSCustomObject]@{
        SkillName            = [string]$definition.Name
        SkillExists          = $true
        AllMet               = [bool]($missing.Count -eq 0)
        MissingPrerequisites = @($missing)
    }
}

function Can-UnlockSkill {
    <#
    .SYNOPSIS
        Returns unlock gate status and reason.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $definition = Resolve-SkillDefinition -Skill $SkillName
    if ($null -eq $definition) {
        return [PSCustomObject]@{
            SkillName            = [string]$SkillName
            SkillKey             = ''
            CanUnlock            = $false
            Reason               = 'SkillNotFound'
            Cost                 = [int]0
            AvailablePoints      = [int]$SkillTree.SkillPointsAvailable
            MissingPrerequisites = @()
            UnlockedCount        = [int]$SkillTree.UnlockedSkillKeys.Count
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    [int]$cost = ConvertTo-SkillInt -Value $definition.Cost -Default 1
    if ($cost -lt 1) {
        $cost = [int]1
    }

    [int]$availablePoints = [int]$SkillTree.SkillPointsAvailable
    [int]$unlockedCount = [int]$SkillTree.UnlockedSkillKeys.Count

    if (Test-SkillUnlocked -SkillTree $SkillTree -SkillName $definition.Name) {
        return [PSCustomObject]@{
            SkillName            = [string]$definition.Name
            SkillKey             = [string]$definition.Key
            CanUnlock            = $false
            Reason               = 'AlreadyUnlocked'
            Cost                 = [int]$cost
            AvailablePoints      = [int]$availablePoints
            MissingPrerequisites = @()
            UnlockedCount        = [int]$unlockedCount
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    if ($unlockedCount -ge $SkillTree.MaxSkills) {
        return [PSCustomObject]@{
            SkillName            = [string]$definition.Name
            SkillKey             = [string]$definition.Key
            CanUnlock            = $false
            Reason               = 'MaxSkillsReached'
            Cost                 = [int]$cost
            AvailablePoints      = [int]$availablePoints
            MissingPrerequisites = @()
            UnlockedCount        = [int]$unlockedCount
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    $prerequisiteResult = Test-SkillPrerequisites -SkillTree $SkillTree -SkillName $definition.Name
    if (-not [bool]$prerequisiteResult.AllMet) {
        return [PSCustomObject]@{
            SkillName            = [string]$definition.Name
            SkillKey             = [string]$definition.Key
            CanUnlock            = $false
            Reason               = 'MissingPrerequisites'
            Cost                 = [int]$cost
            AvailablePoints      = [int]$availablePoints
            MissingPrerequisites = @($prerequisiteResult.MissingPrerequisites)
            UnlockedCount        = [int]$unlockedCount
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    if ($availablePoints -lt $cost) {
        return [PSCustomObject]@{
            SkillName            = [string]$definition.Name
            SkillKey             = [string]$definition.Key
            CanUnlock            = $false
            Reason               = 'InsufficientSkillPoints'
            Cost                 = [int]$cost
            AvailablePoints      = [int]$availablePoints
            MissingPrerequisites = @()
            UnlockedCount        = [int]$unlockedCount
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    return [PSCustomObject]@{
        SkillName            = [string]$definition.Name
        SkillKey             = [string]$definition.Key
        CanUnlock            = $true
        Reason               = 'OK'
        Cost                 = [int]$cost
        AvailablePoints      = [int]$availablePoints
        MissingPrerequisites = @()
        UnlockedCount        = [int]$unlockedCount
        MaxSkills            = [int]$SkillTree.MaxSkills
    }
}

function Unlock-Skill {
    <#
    .SYNOPSIS
        Unlocks a skill if all gates pass.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [Parameter(Mandatory = $true)][string]$SkillName
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $gate = Can-UnlockSkill -SkillTree $SkillTree -SkillName $SkillName
    if (-not [bool]$gate.CanUnlock) {
        return [PSCustomObject]@{
            SkillName            = [string]$gate.SkillName
            SkillKey             = [string]$gate.SkillKey
            Unlocked             = $false
            Reason               = [string]$gate.Reason
            Cost                 = [int]$gate.Cost
            AvailablePoints      = [int]$SkillTree.SkillPointsAvailable
            SpentPoints          = [int]$SkillTree.SkillPointsSpent
            MissingPrerequisites = @($gate.MissingPrerequisites)
            UnlockedCount        = [int]$SkillTree.UnlockedSkillKeys.Count
            MaxSkills            = [int]$SkillTree.MaxSkills
        }
    }

    $definition = Resolve-SkillDefinition -Skill $gate.SkillName
    [int]$cost = [int]$gate.Cost

    $SkillTree.UnlockedSkillKeys[$definition.Key] = [string]$definition.Name
    $SkillTree.SkillPointsAvailable = [int]($SkillTree.SkillPointsAvailable - $cost)
    if ($SkillTree.SkillPointsAvailable -lt 0) {
        $SkillTree.SkillPointsAvailable = [int]0
    }

    $SkillTree.SkillPointsSpent = [int]($SkillTree.SkillPointsSpent + $cost)

    return [PSCustomObject]@{
        SkillName            = [string]$definition.Name
        SkillKey             = [string]$definition.Key
        Unlocked             = $true
        Reason               = 'Unlocked'
        Cost                 = [int]$cost
        AvailablePoints      = [int]$SkillTree.SkillPointsAvailable
        SpentPoints          = [int]$SkillTree.SkillPointsSpent
        MissingPrerequisites = @()
        UnlockedCount        = [int]$SkillTree.UnlockedSkillKeys.Count
        MaxSkills            = [int]$SkillTree.MaxSkills
    }
}

function Get-UnlockedSkills {
    <#
    .SYNOPSIS
        Gets unlocked skill definitions in deterministic order.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $result = @()
    foreach ($definition in @(Get-Skills)) {
        if ($SkillTree.UnlockedSkillKeys.ContainsKey($definition.Key)) {
            $result += $definition
        }
    }

    return @($result)
}

function Get-AvailableSkills {
    <#
    .SYNOPSIS
        Gets unlockable skills in deterministic order.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $result = @()
    foreach ($definition in @(Get-Skills)) {
        $gate = Can-UnlockSkill -SkillTree $SkillTree -SkillName $definition.Name
        if ([bool]$gate.CanUnlock) {
            $result += $definition
        }
    }

    return @($result)
}

function Get-SkillTreeUIStructure {
    <#
    .SYNOPSIS
        Returns UI-facing skill tree layout data model.
    .DESCRIPTION
        This is metadata-only: category columns + node tiers/positions.
    #>
    param($SkillTree = $null)

    Ensure-SkillSystem

    $hasTree = ($null -ne $SkillTree)
    if ($hasTree) {
        Ensure-SkillTreeShape -SkillTree $SkillTree
    }

    $categoryRows = @()
    foreach ($category in @($script:SkillCategoryOrder)) {
        $skillNodes = @()
        foreach ($definition in @(Get-Skills -Category $category)) {
            [bool]$isUnlocked = $false
            [bool]$isAvailable = $false
            $missing = @()

            if ($hasTree) {
                $isUnlocked = Test-SkillUnlocked -SkillTree $SkillTree -SkillName $definition.Name
                $gate = Can-UnlockSkill -SkillTree $SkillTree -SkillName $definition.Name
                $isAvailable = [bool]$gate.CanUnlock
                $missing = @($gate.MissingPrerequisites)
            }

            $skillNodes += [PSCustomObject]@{
                Name                 = [string]$definition.Name
                Category             = [string]$definition.Category
                SkillType            = [string]$definition.SkillType
                Cost                 = [int]$definition.Cost
                Tier                 = [int]$definition.Tier
                UI                   = [PSCustomObject]@{
                    Tier   = [int]$definition.UI.Tier
                    Column = [int]$definition.UI.Column
                    Row    = [int]$definition.UI.Row
                }
                Prerequisites        = @($definition.Prerequisites)
                MissingPrerequisites = @($missing)
                Description          = [string]$definition.Description
                IsUnlocked           = [bool]$isUnlocked
                IsAvailable          = [bool]$isAvailable
            }
        }

        $categoryRows += [PSCustomObject]@{
            Name   = [string]$category
            Skills = @($skillNodes)
        }
    }

    return [PSCustomObject]@{
        SkillCount    = [int]$script:SkillDefinitionList.Count
        CategoryCount = [int]$categoryRows.Count
        Categories    = @($categoryRows)
    }
}

# ============================================================================
# Skill Point Grant APIs (Level-up Integration Surface)
# ============================================================================

function Grant-SkillPoints {
    <#
    .SYNOPSIS
        Adds skill points directly.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [int]$Amount,
        [string]$Source = 'Generic'
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    [int]$safeAmount = ConvertTo-SkillInt -Value $Amount -Default 0
    if ($safeAmount -lt 0) {
        $safeAmount = [int]0
    }

    if ($safeAmount -eq 0) {
        return [PSCustomObject]@{
            Source          = [string]$Source
            PointsGranted   = [int]0
            AvailablePoints = [int]$SkillTree.SkillPointsAvailable
            SpentPoints     = [int]$SkillTree.SkillPointsSpent
            EarnedPoints    = [int]$SkillTree.SkillPointsEarned
        }
    }

    $SkillTree.SkillPointsAvailable = [int]($SkillTree.SkillPointsAvailable + $safeAmount)
    $SkillTree.SkillPointsEarned = [int]($SkillTree.SkillPointsEarned + $safeAmount)

    return [PSCustomObject]@{
        Source          = [string]$Source
        PointsGranted   = [int]$safeAmount
        AvailablePoints = [int]$SkillTree.SkillPointsAvailable
        SpentPoints     = [int]$SkillTree.SkillPointsSpent
        EarnedPoints    = [int]$SkillTree.SkillPointsEarned
    }
}

function Grant-SkillPointsFromLevelUp {
    <#
    .SYNOPSIS
        Grants skill points based on gained levels.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [int]$LevelsGained = 1,
        [string]$Source = 'LevelUp'
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    [int]$safeLevelsGained = ConvertTo-SkillInt -Value $LevelsGained -Default 0
    if ($safeLevelsGained -lt 0) {
        $safeLevelsGained = [int]0
    }

    [int]$beforeLevel = [int]$SkillTree.LastKnownLevel
    [int]$pointsPerLevel = [int]$SkillTree.SkillPointsPerLevel
    [int]$pointsToGrant = [int]($safeLevelsGained * $pointsPerLevel)

    if ($safeLevelsGained -gt 0) {
        $SkillTree.LastKnownLevel = [int]($beforeLevel + $safeLevelsGained)
    }

    $grantResult = Grant-SkillPoints -SkillTree $SkillTree -Amount $pointsToGrant -Source $Source

    return [PSCustomObject]@{
        Source          = [string]$Source
        LevelsGained    = [int]$safeLevelsGained
        PointsPerLevel  = [int]$pointsPerLevel
        PointsGranted   = [int]$grantResult.PointsGranted
        PreviousLevel   = [int]$beforeLevel
        CurrentLevel    = [int]$SkillTree.LastKnownLevel
        AvailablePoints = [int]$SkillTree.SkillPointsAvailable
        SpentPoints     = [int]$SkillTree.SkillPointsSpent
        EarnedPoints    = [int]$SkillTree.SkillPointsEarned
    }
}

function Sync-SkillTreeLevel {
    <#
    .SYNOPSIS
        Syncs tree points to a target level and grants delta points.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        [int]$Level,
        [string]$Source = 'LevelSync'
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    [int]$targetLevel = ConvertTo-SkillInt -Value $Level -Default 1
    if ($targetLevel -lt 1) {
        $targetLevel = [int]1
    }

    [int]$currentLevel = [int]$SkillTree.LastKnownLevel
    if ($targetLevel -le $currentLevel) {
        return [PSCustomObject]@{
            Source          = [string]$Source
            LevelsGained    = [int]0
            PointsGranted   = [int]0
            PreviousLevel   = [int]$currentLevel
            CurrentLevel    = [int]$currentLevel
            AvailablePoints = [int]$SkillTree.SkillPointsAvailable
            SpentPoints     = [int]$SkillTree.SkillPointsSpent
            EarnedPoints    = [int]$SkillTree.SkillPointsEarned
        }
    }

    [int]$levelsGained = [int]($targetLevel - $currentLevel)
    return (Grant-SkillPointsFromLevelUp -SkillTree $SkillTree -LevelsGained $levelsGained -Source $Source)
}

function Connect-SkillTreeExperience {
    <#
    .SYNOPSIS
        Optional bridge to Experience.ps1 level-up callbacks.
    .DESCRIPTION
        If Register-LevelUpCallback exists, this function registers a callback
        that grants points when matching player level-up events occur.
    #>
    param(
        [Parameter(Mandatory = $true)]$SkillTree,
        $Player = $null,
        [switch]$SyncCurrentLevel
    )

    Ensure-SkillTreeShape -SkillTree $SkillTree

    $resolvedPlayerName = ''
    [int]$resolvedPlayerLevel = [int]0

    if ($null -ne $Player) {
        if ($null -ne $Player.PSObject.Properties['Name']) {
            $candidateName = [string]$Player.Name
            if (-not [string]::IsNullOrWhiteSpace($candidateName)) {
                $resolvedPlayerName = [string]$candidateName.Trim()
            }
        }

        if ($null -ne $Player.PSObject.Properties['Level']) {
            $resolvedPlayerLevel = [int](ConvertTo-SkillInt -Value $Player.Level -Default 0)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedPlayerName)) {
        $SkillTree.PlayerName = [string]$resolvedPlayerName
    }

    if ($SyncCurrentLevel -and ($resolvedPlayerLevel -gt 0)) {
        Sync-SkillTreeLevel -SkillTree $SkillTree -Level $resolvedPlayerLevel -Source 'ExperienceSync' | Out-Null
    }

    if ([bool]$SkillTree.ExperienceHookRegistered) {
        return [PSCustomObject]@{
            HookRegistered = $true
            AlreadyRegistered = $true
            HookId = [int]$SkillTree.ExperienceHookId
            PlayerName = [string]$SkillTree.PlayerName
            Reason = 'AlreadyConnected'
        }
    }

    $registerCallbackCommand = Get-Command -Name 'Register-LevelUpCallback' -ErrorAction SilentlyContinue
    if ($null -eq $registerCallbackCommand) {
        return [PSCustomObject]@{
            HookRegistered = $false
            AlreadyRegistered = $false
            HookId = [int]0
            PlayerName = [string]$SkillTree.PlayerName
            Reason = 'Register-LevelUpCallbackUnavailable'
        }
    }

    $treeRef = $SkillTree
    $callback = {
        param($EventRecord)

        if ($null -eq $EventRecord) {
            return $null
        }

        [int]$toLevel = [int]0
        if ($EventRecord -is [System.Collections.IDictionary]) {
            if ($EventRecord.Contains('ToLevel')) {
                $toLevel = [int](ConvertTo-SkillInt -Value $EventRecord['ToLevel'] -Default 0)
            }
        }
        elseif ($null -ne $EventRecord.PSObject.Properties['ToLevel']) {
            $toLevel = [int](ConvertTo-SkillInt -Value $EventRecord.ToLevel -Default 0)
        }

        if ($toLevel -lt 1) {
            return $null
        }

        $targetName = [string]$treeRef.PlayerName
        if (-not [string]::IsNullOrWhiteSpace($targetName)) {
            $eventPlayerName = ''

            if ($EventRecord -is [System.Collections.IDictionary]) {
                if ($EventRecord.Contains('PlayerName')) {
                    $eventPlayerName = [string]$EventRecord['PlayerName']
                }
            }
            elseif ($null -ne $EventRecord.PSObject.Properties['PlayerName']) {
                $eventPlayerName = [string]$EventRecord.PlayerName
            }

            if (-not [string]::Equals($targetName.Trim(), $eventPlayerName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }
        }

        return (Sync-SkillTreeLevel -SkillTree $treeRef -Level $toLevel -Source 'ExperienceLevelUp')
    }.GetNewClosure()

    try {
        $hookId = Register-LevelUpCallback -Callback $callback
        $SkillTree.ExperienceHookRegistered = $true
        $SkillTree.ExperienceHookId = [int](ConvertTo-SkillInt -Value $hookId -Default 0)

        return [PSCustomObject]@{
            HookRegistered = $true
            AlreadyRegistered = $false
            HookId = [int]$SkillTree.ExperienceHookId
            PlayerName = [string]$SkillTree.PlayerName
            Reason = 'Connected'
        }
    }
    catch {
        return [PSCustomObject]@{
            HookRegistered = $false
            AlreadyRegistered = $false
            HookId = [int]0
            PlayerName = [string]$SkillTree.PlayerName
            Reason = "RegisterFailed:$($_.Exception.Message)"
        }
    }
}

# Initialize on dot-source.
Initialize-SkillSystem -Quiet | Out-Null
