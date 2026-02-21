# ============================================================================
# Data/Quests.ps1 - Quest Definitions and Query Helpers
# ============================================================================
# Centralized quest content registry for quest chains, lore, prerequisites,
# quest giver metadata, and reward payload definitions.
#
# This file is data-oriented and does not grant rewards.
# Reward delivery is handled by quest rewards systems.
#
# Optional dependencies:
#   Game/Quest.ps1 (Get-CompletedQuests, Get-ActiveQuests)
# ============================================================================

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

$script:QuestDefinitionOrder = @()
$script:QuestDefinitionsById = @{}
$script:QuestDefinitionsByName = @{}

$script:QuestGiverOrder = @()
$script:QuestGiversById = @{}
$script:QuestGiversByName = @{}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Normalize-QuestDefinitionKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.Trim().ToLowerInvariant()
}

function ConvertTo-QuestIdSet {
    param([string[]]$Ids)

    $set = @{}
    foreach ($id in @($Ids)) {
        $key = Normalize-QuestDefinitionKey -Value ([string]$id)
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        $set[$key] = $true
    }

    return $set
}

function New-QuestObjectiveDefinition {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Kill', 'Gather', 'Talk', 'Explore')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$RequiredCount = 1,
        [string]$Description = ''
    )

    if ($RequiredCount -lt 1) {
        $RequiredCount = [int]1
    }

    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = "$Type $RequiredCount $Target"
    }

    return [PSCustomObject]@{
        Type          = [string]$Type
        Target        = [string]$Target
        RequiredCount = [int]$RequiredCount
        Description   = [string]$Description
    }
}

function New-QuestRewardPayload {
    param(
        [int]$XP = 0,
        [int]$Gold = 0,
        [object[]]$Items = @(),
        [object[]]$Reputation = @(),
        [string[]]$Flags = @()
    )

    if ($XP -lt 0) { $XP = [int]0 }
    if ($Gold -lt 0) { $Gold = [int]0 }

    $normalizedItems = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }

        $name = [string]$item.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        [int]$count = [int]1
        try {
            $count = [int]$item.Count
        }
        catch {
            $count = [int]1
        }

        if ($count -lt 1) {
            $count = [int]1
        }

        $normalizedItems += [PSCustomObject]@{
            Name  = [string]$name
            Count = [int]$count
        }
    }

    $normalizedReputation = @()
    foreach ($entry in @($Reputation)) {
        if ($null -eq $entry) { continue }

        $faction = [string]$entry.Faction
        if ([string]::IsNullOrWhiteSpace($faction)) {
            continue
        }

        [int]$amount = [int]0
        try {
            $amount = [int]$entry.Amount
        }
        catch {
            $amount = [int]0
        }

        $normalizedReputation += [PSCustomObject]@{
            Faction = [string]$faction
            Amount  = [int]$amount
        }
    }

    $normalizedFlags = @()
    foreach ($flag in @($Flags)) {
        $flagText = [string]$flag
        if ([string]::IsNullOrWhiteSpace($flagText)) {
            continue
        }

        $normalizedFlags += $flagText.Trim()
    }

    return [PSCustomObject]@{
        XP         = [int]$XP
        Gold       = [int]$Gold
        Items      = @($normalizedItems)
        Reputation = @($normalizedReputation)
        Flags      = @($normalizedFlags)
    }
}

function Register-QuestGiver {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Location = '',
        [string]$Faction = '',
        [string[]]$Aliases = @(),
        [string]$Notes = ''
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw 'Quest giver Id is required.'
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Quest giver '$Id' requires a Name."
    }

    $idKey = Normalize-QuestDefinitionKey -Value $Id
    $nameKey = Normalize-QuestDefinitionKey -Value $Name

    if ($script:QuestGiversById.ContainsKey($idKey)) {
        throw "Duplicate quest giver id '$Id'."
    }

    $giver = [PSCustomObject]@{
        Id       = [string]$Id
        Name     = [string]$Name
        NpcId    = [string]$Id
        NpcName  = [string]$Name
        Location = [string]$Location
        Faction  = [string]$Faction
        Aliases  = @($Aliases)
        Notes    = [string]$Notes
    }

    $script:QuestGiverOrder += $idKey
    $script:QuestGiversById[$idKey] = $giver
    $script:QuestGiversByName[$nameKey] = $giver

    foreach ($alias in @($Aliases)) {
        $aliasKey = Normalize-QuestDefinitionKey -Value ([string]$alias)
        if ([string]::IsNullOrWhiteSpace($aliasKey)) {
            continue
        }

        $script:QuestGiversByName[$aliasKey] = $giver
    }

    return $giver
}

function Register-QuestDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$GiverId,
        [string]$Description = '',
        [string]$Lore = '',
        [string[]]$Requires = @(),
        [object[]]$Objectives = @(),
        $Rewards = $null,
        [string]$ChainId = '',
        [int]$ChainStep = 1,
        [int]$RecommendedLevel = 1,
        $Metadata = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw 'Quest definition Id is required.'
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Quest definition '$Id' requires a Name."
    }

    if ([string]::IsNullOrWhiteSpace($GiverId)) {
        throw "Quest definition '$Id' requires GiverId."
    }

    $idKey = Normalize-QuestDefinitionKey -Value $Id
    $nameKey = Normalize-QuestDefinitionKey -Value $Name

    if ($script:QuestDefinitionsById.ContainsKey($idKey)) {
        throw "Duplicate quest definition id '$Id'."
    }

    $giver = Get-QuestGiver -IdOrName $GiverId
    if ($null -eq $giver) {
        throw "Quest definition '$Id' references unknown giver '$GiverId'."
    }

    if ($ChainStep -lt 1) {
        $ChainStep = [int]1
    }

    if ($RecommendedLevel -lt 1) {
        $RecommendedLevel = [int]1
    }

    $normalizedRequires = @()
    foreach ($requiredId in @($Requires)) {
        $requiredText = [string]$requiredId
        if ([string]::IsNullOrWhiteSpace($requiredText)) {
            continue
        }

        $requiredText = $requiredText.Trim()
        if ([string]::Equals($requiredText, $Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($normalizedRequires -contains $requiredText) {
            continue
        }

        $normalizedRequires += $requiredText
    }

    $normalizedObjectives = @()
    foreach ($objective in @($Objectives)) {
        if ($null -eq $objective) { continue }
        $normalizedObjectives += $objective
    }

    if ($null -eq $Rewards) {
        $Rewards = New-QuestRewardPayload
    }

    if ($null -eq $Metadata) {
        $Metadata = @{}
    }

    $quest = [PSCustomObject]@{
        Id               = [string]$Id
        Name             = [string]$Name
        GiverId          = [string]$giver.Id
        GiverName        = [string]$giver.Name
        Description      = [string]$Description
        Lore             = [string]$Lore
        Requires         = @($normalizedRequires)
        Objectives       = @($normalizedObjectives)
        Rewards          = $Rewards
        ChainId          = [string]$ChainId
        ChainStep        = [int]$ChainStep
        RecommendedLevel = [int]$RecommendedLevel
        Metadata         = $Metadata
    }

    $script:QuestDefinitionOrder += $idKey
    $script:QuestDefinitionsById[$idKey] = $quest
    $script:QuestDefinitionsByName[$nameKey] = $quest

    return $quest
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

function Initialize-QuestDefinitions {
    <#
    .SYNOPSIS
        Loads all quest giver definitions and quest definitions.
    #>

    $script:QuestDefinitionOrder = @()
    $script:QuestDefinitionsById = @{}
    $script:QuestDefinitionsByName = @{}

    $script:QuestGiverOrder = @()
    $script:QuestGiversById = @{}
    $script:QuestGiversByName = @{}

    # -------------------------------------------------------------------
    # Quest givers
    # -------------------------------------------------------------------

    Register-QuestGiver -Id 'elder_rowan' -Name 'Elder Rowan' -Location 'Village Square' -Faction 'Village' -Aliases @('rowan', 'elder') -Notes 'Village elder and story lead.' | Out-Null
    Register-QuestGiver -Id 'blacksmith_brom' -Name 'Blacksmith Brom' -Location 'Forge District' -Faction 'Blacksmiths' -Aliases @('brom', 'smith') -Notes 'Equipment and supply quests.' | Out-Null
    Register-QuestGiver -Id 'scout_lena' -Name 'Scout Lena' -Location 'North Gate' -Faction 'Wardens' -Aliases @('lena', 'scout') -Notes 'Threat tracking and beacon routes.' | Out-Null
    Register-QuestGiver -Id 'alchemist_mira' -Name 'Alchemist Mira' -Location 'Apothecary' -Faction 'Alchemists' -Aliases @('mira', 'alchemist') -Notes 'Potion and field sample quests.' | Out-Null
    Register-QuestGiver -Id 'captain_thorne' -Name 'Captain Thorne' -Location 'Guard Barracks' -Faction 'Wardens' -Aliases @('thorne', 'captain') -Notes 'Defense and perimeter orders.' | Out-Null
    Register-QuestGiver -Id 'hermit_iora' -Name 'Hermit Iora' -Location 'Cliffside Shrine' -Faction 'HermitCircle' -Aliases @('iora', 'hermit') -Notes 'Ancient ruins and shard lore.' | Out-Null

    # -------------------------------------------------------------------
    # Quest definitions (12 total)
    # -------------------------------------------------------------------

    Register-QuestDefinition `
        -Id 'q_tutorial_first_steps' `
        -Name 'First Steps' `
        -GiverId 'elder_rowan' `
        -Description 'Meet the village elder and learn where survivors gather each dusk.' `
        -Lore 'The hamlet endured the long storm by keeping watchfires lit in the square.' `
        -Requires @() `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'elder_rowan' -Description 'Speak with Elder Rowan in the village square.'),
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'village_square' -Description 'Walk the marked ring in the village square.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 50 -Gold 10 -Items @(
            [PSCustomObject]@{ Name = 'Bread'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Village'; Amount = 5 }
        ) -Flags @('tutorial_started')) `
        -ChainId 'tutorial_path' `
        -ChainStep 1 `
        -RecommendedLevel 1 | Out-Null

    Register-QuestDefinition `
        -Id 'q_tutorial_tools_of_trade' `
        -Name 'Tools of Trade' `
        -GiverId 'blacksmith_brom' `
        -Description 'Gather timber so the forge can repair broken handles and frames.' `
        -Lore 'Brom says the forge can survive on sparks, but never without dry wood.' `
        -Requires @('q_tutorial_first_steps') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'wood' -RequiredCount 8 -Description 'Collect 8 wood for the blacksmith.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'blacksmith_brom' -Description 'Return to Blacksmith Brom with supplies.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 70 -Gold 15 -Items @(
            [PSCustomObject]@{ Name = 'Stick'; Count = 4 },
            [PSCustomObject]@{ Name = 'Planks'; Count = 6 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Village'; Amount = 4 },
            [PSCustomObject]@{ Faction = 'Blacksmiths'; Amount = 6 }
        ) -Flags @('tutorial_tools_complete')) `
        -ChainId 'tutorial_path' `
        -ChainStep 2 `
        -RecommendedLevel 1 | Out-Null

    Register-QuestDefinition `
        -Id 'q_tutorial_hunting_call' `
        -Name 'Hunting Call' `
        -GiverId 'scout_lena' `
        -Description 'Thin nearby slimes and scout the old watchtower trail.' `
        -Lore 'Lena maps every creature route before the moon crosses the ridge.' `
        -Requires @('q_tutorial_tools_of_trade') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Kill' -Target 'slime' -RequiredCount 5 -Description 'Defeat 5 slimes near the old road.'),
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'old_watchtower' -Description 'Reach the old watchtower trail marker.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 95 -Gold 20 -Items @(
            [PSCustomObject]@{ Name = 'Wooden Sword'; Count = 1 },
            [PSCustomObject]@{ Name = 'Health Potion'; Count = 1 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 5 },
            [PSCustomObject]@{ Faction = 'Village'; Amount = 3 }
        ) -Flags @('tutorial_hunt_complete')) `
        -ChainId 'tutorial_path' `
        -ChainStep 3 `
        -RecommendedLevel 2 | Out-Null

    Register-QuestDefinition `
        -Id 'q_village_herbal_remedy' `
        -Name 'Herbal Remedy' `
        -GiverId 'alchemist_mira' `
        -Description 'Gather field herbs before tonight''s treatment rounds begin.' `
        -Lore 'Mira treats fever and poison with tinctures brewed at sunset.' `
        -Requires @('q_tutorial_first_steps') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'herb' -RequiredCount 6 -Description 'Collect 6 fresh herbs from meadow patches.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'alchemist_mira' -Description 'Return the herbs to Alchemist Mira.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 80 -Gold 18 -Items @(
            [PSCustomObject]@{ Name = 'Health Potion'; Count = 2 },
            [PSCustomObject]@{ Name = 'Mana Potion'; Count = 1 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Village'; Amount = 4 },
            [PSCustomObject]@{ Faction = 'Alchemists'; Amount = 6 }
        ) -Flags @('herbal_batches_complete')) `
        -ChainId 'village_recovery' `
        -ChainStep 1 `
        -RecommendedLevel 2 | Out-Null

    Register-QuestDefinition `
        -Id 'q_village_water_test' `
        -Name 'Water Test' `
        -GiverId 'alchemist_mira' `
        -Description 'Inspect the spring and bring fuel for a purity distillation.' `
        -Lore 'Recent rain carried ash from the hills into lower wells.' `
        -Requires @('q_village_herbal_remedy') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'crystal_spring' -Description 'Inspect the crystal spring source.'),
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'coal' -RequiredCount 3 -Description 'Collect 3 coal for the distillation burner.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'alchemist_mira' -Description 'Report findings to Alchemist Mira.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 120 -Gold 25 -Items @(
            [PSCustomObject]@{ Name = 'Mana Potion'; Count = 2 },
            [PSCustomObject]@{ Name = 'Bread'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Alchemists'; Amount = 8 }
        ) -Flags @('spring_scouted')) `
        -ChainId 'village_recovery' `
        -ChainStep 2 `
        -RecommendedLevel 3 | Out-Null

    Register-QuestDefinition `
        -Id 'q_blacksmith_supply_run' `
        -Name 'Forge Supply Run' `
        -GiverId 'blacksmith_brom' `
        -Description 'Refill forge stone and fuel so armor repairs can continue.' `
        -Lore 'The guard reserve cracked during the last raider siege.' `
        -Requires @('q_tutorial_tools_of_trade') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'cobblestone' -RequiredCount 20 -Description 'Collect 20 cobblestone blocks for the forge wall.'),
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'coal' -RequiredCount 6 -Description 'Collect 6 coal to keep the furnace hot.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'blacksmith_brom' -Description 'Deliver supplies to Blacksmith Brom.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 140 -Gold 30 -Items @(
            [PSCustomObject]@{ Name = 'Stone Pickaxe'; Count = 1 },
            [PSCustomObject]@{ Name = 'Iron Ingot'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Blacksmiths'; Amount = 10 },
            [PSCustomObject]@{ Faction = 'Village'; Amount = 3 }
        ) -Flags @('forge_resupplied')) `
        -ChainId 'village_recovery' `
        -ChainStep 3 `
        -RecommendedLevel 3 | Out-Null

    Register-QuestDefinition `
        -Id 'q_guard_perimeter_patrol' `
        -Name 'Perimeter Patrol' `
        -GiverId 'captain_thorne' `
        -Description 'Confirm all outposts still signal and report weak points.' `
        -Lore 'The captain rotates patrol routes daily to hide guard patterns.' `
        -Requires @('q_tutorial_hunting_call') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'north_gate' -Description 'Inspect the north gate beacon.'),
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'east_watch' -Description 'Inspect the east watch outpost.'),
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'west_watch' -Description 'Inspect the west watch outpost.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'captain_thorne' -Description 'Report patrol results to Captain Thorne.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 110 -Gold 22 -Items @(
            [PSCustomObject]@{ Name = 'Bread'; Count = 3 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 8 }
        ) -Flags @('perimeter_patrolled')) `
        -ChainId 'wardens_guard' `
        -ChainStep 1 `
        -RecommendedLevel 3 | Out-Null

    Register-QuestDefinition `
        -Id 'q_guard_wolf_threat' `
        -Name 'Wolf Threat' `
        -GiverId 'captain_thorne' `
        -Description 'Drive back the wolf pack stalking supply runners.' `
        -Lore 'Tracks suggest the pack was displaced by cave noise in the upper hills.' `
        -Requires @('q_guard_perimeter_patrol') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Kill' -Target 'wolf' -RequiredCount 8 -Description 'Defeat 8 wolves on the ridge approach.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'captain_thorne' -Description 'Report the hunt to Captain Thorne.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 180 -Gold 40 -Items @(
            [PSCustomObject]@{ Name = 'Stone Sword'; Count = 1 },
            [PSCustomObject]@{ Name = 'Health Potion'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 12 },
            [PSCustomObject]@{ Faction = 'Village'; Amount = 6 }
        ) -Flags @('wolf_threat_cleared')) `
        -ChainId 'wardens_guard' `
        -ChainStep 2 `
        -RecommendedLevel 4 | Out-Null

    Register-QuestDefinition `
        -Id 'q_hermit_whispers_in_stone' `
        -Name 'Whispers in Stone' `
        -GiverId 'hermit_iora' `
        -Description 'Search the ancient ruins where the old signal mirrors stood.' `
        -Lore 'Iora believes the ruins answer only those who keep their oaths.' `
        -Requires @('q_guard_perimeter_patrol', 'q_village_water_test') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'ancient_ruins' -Description 'Reach the sealed arch in the ancient ruins.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'hermit_iora' -Description 'Share what you found with Hermit Iora.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 160 -Gold 35 -Items @(
            [PSCustomObject]@{ Name = 'Mana Potion'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'HermitCircle'; Amount = 10 },
            [PSCustomObject]@{ Faction = 'Village'; Amount = 3 }
        ) -Flags @('ruins_discovered')) `
        -ChainId 'ancient_signal' `
        -ChainStep 1 `
        -RecommendedLevel 4 | Out-Null

    Register-QuestDefinition `
        -Id 'q_hermit_echo_shards' `
        -Name 'Echo Shards' `
        -GiverId 'hermit_iora' `
        -Description 'Recover resonant shards and clear cave bats around the shrine.' `
        -Lore 'The shard hum can rekindle broken signal braziers from afar.' `
        -Requires @('q_hermit_whispers_in_stone') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'echo_shard' -RequiredCount 3 -Description 'Collect 3 echo shards from the lower ruins caverns.'),
            (New-QuestObjectiveDefinition -Type 'Kill' -Target 'cave_bat' -RequiredCount 6 -Description 'Defeat 6 cave bats in the lower caverns.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'hermit_iora' -Description 'Return the shards to Hermit Iora.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 220 -Gold 55 -Items @(
            [PSCustomObject]@{ Name = 'Iron Ingot'; Count = 4 },
            [PSCustomObject]@{ Name = 'Health Potion'; Count = 1 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'HermitCircle'; Amount = 14 },
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 4 }
        ) -Flags @('echo_shards_recovered')) `
        -ChainId 'ancient_signal' `
        -ChainStep 2 `
        -RecommendedLevel 5 | Out-Null

    Register-QuestDefinition `
        -Id 'q_main_rekindle_beacon' `
        -Name 'Rekindle the Beacon' `
        -GiverId 'scout_lena' `
        -Description 'Restore the storm beacon before raider scouts return at dawn.' `
        -Lore 'A lit beacon can summon allied patrols from across the valley routes.' `
        -Requires @('q_guard_wolf_threat', 'q_hermit_echo_shards') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'storm_beacon' -Description 'Reach the storm beacon platform.'),
            (New-QuestObjectiveDefinition -Type 'Gather' -Target 'coal' -RequiredCount 10 -Description 'Gather 10 coal to fuel the beacon brazier.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'scout_lena' -Description 'Report beacon status to Scout Lena.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 300 -Gold 80 -Items @(
            [PSCustomObject]@{ Name = 'Iron Sword'; Count = 1 },
            [PSCustomObject]@{ Name = 'Bread'; Count = 4 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Village'; Amount = 10 },
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 8 }
        ) -Flags @('beacon_rekindled')) `
        -ChainId 'ancient_signal' `
        -ChainStep 3 `
        -RecommendedLevel 6 | Out-Null

    Register-QuestDefinition `
        -Id 'q_main_defend_hamlet' `
        -Name 'Defend the Hamlet' `
        -GiverId 'captain_thorne' `
        -Description 'Repel the raider push and secure the square before nightfall.' `
        -Lore 'This stand decides whether the hamlet keeps the valley routes open.' `
        -Requires @('q_main_rekindle_beacon') `
        -Objectives @(
            (New-QuestObjectiveDefinition -Type 'Kill' -Target 'raider' -RequiredCount 12 -Description 'Defeat 12 raiders during the assault.'),
            (New-QuestObjectiveDefinition -Type 'Explore' -Target 'hamlet_square' -Description 'Secure the hamlet square perimeter.'),
            (New-QuestObjectiveDefinition -Type 'Talk' -Target 'elder_rowan' -Description 'Report to Elder Rowan after the battle.')
        ) `
        -Rewards (New-QuestRewardPayload -XP 450 -Gold 120 -Items @(
            [PSCustomObject]@{ Name = 'Health Potion'; Count = 3 },
            [PSCustomObject]@{ Name = 'Mana Potion'; Count = 2 },
            [PSCustomObject]@{ Name = 'Gold Ingot'; Count = 2 }
        ) -Reputation @(
            [PSCustomObject]@{ Faction = 'Village'; Amount = 20 },
            [PSCustomObject]@{ Faction = 'Wardens'; Amount = 15 }
        ) -Flags @('hamlet_defended')) `
        -ChainId 'ancient_signal' `
        -ChainStep 4 `
        -RecommendedLevel 7 | Out-Null

    Write-Host "[Quests] Loaded $($script:QuestDefinitionOrder.Count) quest definitions and $($script:QuestGiverOrder.Count) quest givers." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Public query API
# ---------------------------------------------------------------------------

function Get-QuestGiver {
    <#
    .SYNOPSIS
        Returns a quest giver by id, npc id, name, or alias.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IdOrName
    )

    $key = Normalize-QuestDefinitionKey -Value $IdOrName
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    if ($script:QuestGiversById.ContainsKey($key)) {
        return $script:QuestGiversById[$key]
    }

    if ($script:QuestGiversByName.ContainsKey($key)) {
        return $script:QuestGiversByName[$key]
    }

    return $null
}

function Get-AllQuestGivers {
    <#
    .SYNOPSIS
        Returns all quest givers in registration order.
    #>

    $result = @()
    foreach ($key in @($script:QuestGiverOrder)) {
        if ($script:QuestGiversById.ContainsKey($key)) {
            $result += $script:QuestGiversById[$key]
        }
    }

    return @($result)
}

function Get-QuestDefinition {
    <#
    .SYNOPSIS
        Returns a quest definition by id or name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IdOrName
    )

    $key = Normalize-QuestDefinitionKey -Value $IdOrName
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    if ($script:QuestDefinitionsById.ContainsKey($key)) {
        return $script:QuestDefinitionsById[$key]
    }

    if ($script:QuestDefinitionsByName.ContainsKey($key)) {
        return $script:QuestDefinitionsByName[$key]
    }

    return $null
}

function Get-AllQuestDefinitions {
    <#
    .SYNOPSIS
        Returns all quest definitions in registration order.
    #>

    $result = @()
    foreach ($key in @($script:QuestDefinitionOrder)) {
        if ($script:QuestDefinitionsById.ContainsKey($key)) {
            $result += $script:QuestDefinitionsById[$key]
        }
    }

    return @($result)
}

function Get-QuestDefinitionsByGiver {
    <#
    .SYNOPSIS
        Returns all quests assigned to a specific quest giver.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$GiverIdOrName
    )

    $giver = Get-QuestGiver -IdOrName $GiverIdOrName
    if ($null -eq $giver) {
        return @()
    }

    $result = @()
    foreach ($quest in @(Get-AllQuestDefinitions)) {
        if ([string]::Equals([string]$quest.GiverId, [string]$giver.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result += $quest
        }
    }

    return @($result)
}

function Get-QuestPrerequisites {
    <#
    .SYNOPSIS
        Returns prerequisite quest ids, or full definitions when requested.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$QuestIdOrName,
        [switch]$AsDefinitions
    )

    $quest = Get-QuestDefinition -IdOrName $QuestIdOrName
    if ($null -eq $quest) {
        return $null
    }

    if (-not $AsDefinitions) {
        return @($quest.Requires)
    }

    $result = @()
    foreach ($requiredId in @($quest.Requires)) {
        $requiredQuest = Get-QuestDefinition -IdOrName $requiredId
        if ($null -ne $requiredQuest) {
            $result += $requiredQuest
        }
    }

    return @($result)
}

function Get-QuestDependents {
    <#
    .SYNOPSIS
        Returns quests that directly require the provided quest.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$QuestIdOrName
    )

    $quest = Get-QuestDefinition -IdOrName $QuestIdOrName
    if ($null -eq $quest) {
        return @()
    }

    $questId = [string]$quest.Id

    $result = @()
    foreach ($candidate in @(Get-AllQuestDefinitions)) {
        if (@($candidate.Requires) -contains $questId) {
            $result += $candidate
        }
    }

    return @($result)
}

function Get-QuestChain {
    <#
    .SYNOPSIS
        Returns quests in a chain, ordered by ChainStep then Name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ChainId
    )

    $chainKey = Normalize-QuestDefinitionKey -Value $ChainId
    if ([string]::IsNullOrWhiteSpace($chainKey)) {
        return @()
    }

    $result = @()
    foreach ($quest in @(Get-AllQuestDefinitions)) {
        $candidateChainKey = Normalize-QuestDefinitionKey -Value ([string]$quest.ChainId)
        if ($candidateChainKey -eq $chainKey) {
            $result += $quest
        }
    }

    $sorted = $result | Sort-Object -Property ChainStep, Name
    return @($sorted)
}

function Test-QuestDefinitionAvailable {
    <#
    .SYNOPSIS
        Tests if a quest can be offered given completed and active sets.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [string[]]$CompletedQuestIds = @(),
        [string[]]$ActiveQuestIds = @(),
        [string]$GiverIdOrName = ''
    )

    $questObj = $Quest
    if ($Quest -is [string]) {
        $questObj = Get-QuestDefinition -IdOrName ([string]$Quest)
    }

    if ($null -eq $questObj) {
        return $false
    }

    $completedSet = ConvertTo-QuestIdSet -Ids @($CompletedQuestIds)
    $activeSet = ConvertTo-QuestIdSet -Ids @($ActiveQuestIds)

    $questKey = Normalize-QuestDefinitionKey -Value ([string]$questObj.Id)
    if ($completedSet.ContainsKey($questKey)) {
        return $false
    }

    if ($activeSet.ContainsKey($questKey)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($GiverIdOrName)) {
        $giver = Get-QuestGiver -IdOrName $GiverIdOrName
        if ($null -eq $giver) {
            return $false
        }

        if (-not [string]::Equals([string]$questObj.GiverId, [string]$giver.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    foreach ($requiredId in @($questObj.Requires)) {
        $requiredKey = Normalize-QuestDefinitionKey -Value ([string]$requiredId)
        if (-not $completedSet.ContainsKey($requiredKey)) {
            return $false
        }
    }

    return $true
}

function Get-AvailableQuestDefinitions {
    <#
    .SYNOPSIS
        Lists currently available quests from prerequisites and runtime state.
    .DESCRIPTION
        If no CompletedQuestIds or ActiveQuestIds are supplied and Game/Quest.ps1
        is loaded, this function reads state from Get-CompletedQuests and
        Get-ActiveQuests automatically.
    #>
    param(
        [string[]]$CompletedQuestIds = @(),
        [string[]]$ActiveQuestIds = @(),
        [string]$GiverIdOrName = ''
    )

    $completedIdsToUse = @($CompletedQuestIds)
    $activeIdsToUse = @($ActiveQuestIds)

    if ($completedIdsToUse.Count -eq 0) {
        if (Get-Command -Name Get-CompletedQuests -ErrorAction SilentlyContinue) {
            try {
                $completedIdsToUse = @((Get-CompletedQuests) | ForEach-Object { [string]$_.Id })
            }
            catch {
                $completedIdsToUse = @()
            }
        }
    }

    if ($activeIdsToUse.Count -eq 0) {
        if (Get-Command -Name Get-ActiveQuests -ErrorAction SilentlyContinue) {
            try {
                $activeIdsToUse = @((Get-ActiveQuests) | ForEach-Object { [string]$_.Id })
            }
            catch {
                $activeIdsToUse = @()
            }
        }
    }

    $result = @()
    foreach ($quest in @(Get-AllQuestDefinitions)) {
        if (Test-QuestDefinitionAvailable -Quest $quest -CompletedQuestIds $completedIdsToUse -ActiveQuestIds $activeIdsToUse -GiverIdOrName $GiverIdOrName) {
            $result += $quest
        }
    }

    return @($result)
}

# ---------------------------------------------------------------------------
# Auto-initialize on dot-source
# ---------------------------------------------------------------------------

Initialize-QuestDefinitions
