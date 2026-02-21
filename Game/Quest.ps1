# ============================================================================
# Game/Quest.ps1 - Quest State and Objective Tracking System
# ============================================================================
# Provides:
# - Quest entities with objective lists and rewards payload data
# - Quest state flow (NotStarted, InProgress, Completed, Failed)
# - Objective event tracking (Kill, Gather, Talk, Explore)
# - Query helpers for active/completed/failed quest views
# - Optional compatibility hooks for Dialog.ps1 (Get/Set-QuestState, Get/Set-QuestFlag)
#
# Dependencies:
# - None required. Event driven module.
# ============================================================================

# --- Module State ---
$script:QuestSystemInitialized = $false
$script:QuestById = @{}
$script:QuestOrder = @()
$script:QuestNextId = [int]1
$script:QuestFlags = @{}

# ============================================================================
# Internal Helpers
# ============================================================================

function Normalize-QuestKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.Trim().ToLowerInvariant()
}

function Get-QuestValue {
    param(
        $Source,
        [string[]]$Names,
        $Default = $null
    )

    if ($null -eq $Source) {
        return $Default
    }

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }

        if ($Source -is [System.Collections.IDictionary]) {
            try {
                if ($Source.Contains($name)) {
                    return $Source[$name]
                }
            }
            catch {
                # Ignore dictionary-specific contains errors.
            }

            foreach ($key in $Source.Keys) {
                if ([string]::Equals([string]$key, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Source[$key]
                }
            }
        }
        else {
            foreach ($prop in $Source.PSObject.Properties) {
                if ([string]::Equals([string]$prop.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $prop.Value
                }
            }
        }
    }

    return $Default
}

function Set-QuestObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function ConvertTo-QuestObjectiveType {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [switch]$ThrowOnInvalid
    )

    $raw = [string]$Type
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($ThrowOnInvalid) {
            throw "Objective type is required."
        }
        return ''
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    switch ($normalized) {
        'kill' { return 'Kill' }
        'gather' { return 'Gather' }
        'talk' { return 'Talk' }
        'explore' { return 'Explore' }
        default {
            if ($ThrowOnInvalid) {
                throw "Unsupported objective type '$Type'. Allowed: Kill, Gather, Talk, Explore."
            }
            return ''
        }
    }
}

function ConvertFrom-QuestObjectiveText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $trimmed = $Text.Trim()
    $result = @{
        Type         = 'Explore'
        Target       = $trimmed
        RequiredCount = [int]1
        Description  = $trimmed
    }

    $match = [regex]::Match($trimmed, '^(?i)(Kill|Gather|Talk|Explore)\s+([0-9]+)?\s*(.*)$')
    if ($match.Success) {
        $typeText = [string]$match.Groups[1].Value
        $countText = [string]$match.Groups[2].Value
        $targetText = [string]$match.Groups[3].Value

        $result.Type = ConvertTo-QuestObjectiveType -Type $typeText

        if ([string]::IsNullOrWhiteSpace($targetText)) {
            $targetText = $trimmed
        }

        $result.Target = $targetText.Trim()

        [int]$requiredCount = [int]1
        if (-not [string]::IsNullOrWhiteSpace($countText)) {
            try {
                $requiredCount = [int]$countText
            }
            catch {
                $requiredCount = [int]1
            }
        }

        if ($requiredCount -lt 1) {
            $requiredCount = [int]1
        }

        $result.RequiredCount = $requiredCount
    }

    return $result
}

function ConvertTo-QuestObjective {
    param(
        $Objective,
        [int]$Index = 1
    )

    if ($null -eq $Objective) {
        return $null
    }

    $source = $Objective
    if ($Objective -is [string]) {
        $source = ConvertFrom-QuestObjectiveText -Text ([string]$Objective)
    }

    if ($null -eq $source) {
        return $null
    }

    $type = [string](Get-QuestValue -Source $source -Names @('Type', 'ObjectiveType', 'Kind') -Default '')
    if ([string]::IsNullOrWhiteSpace($type)) {
        $type = 'Explore'
    }

    $objectiveType = ConvertTo-QuestObjectiveType -Type $type -ThrowOnInvalid

    $target = [string](Get-QuestValue -Source $source -Names @('Target', 'Name', 'Enemy', 'Item', 'NPC', 'Npc', 'Location') -Default '')

    $requiredRaw = Get-QuestValue -Source $source -Names @('RequiredCount', 'Required', 'Count', 'Goal', 'Amount') -Default ([int]1)
    [int]$requiredCount = [int]1
    try {
        $requiredCount = [int]$requiredRaw
    }
    catch {
        $requiredCount = [int]1
    }

    if ($requiredCount -lt 1) {
        $requiredCount = [int]1
    }

    $currentRaw = Get-QuestValue -Source $source -Names @('CurrentCount', 'Current', 'Progress', 'Value') -Default ([int]0)
    [int]$currentCount = [int]0
    try {
        $currentCount = [int]$currentRaw
    }
    catch {
        $currentCount = [int]0
    }

    if ($currentCount -lt 0) {
        $currentCount = [int]0
    }

    $description = [string](Get-QuestValue -Source $source -Names @('Description', 'Text', 'Label') -Default '')
    if ([string]::IsNullOrWhiteSpace($description)) {
        if ([string]::IsNullOrWhiteSpace($target)) {
            $description = "$objectiveType objective"
        }
        else {
            $description = "$objectiveType $requiredCount $target"
        }
    }

    $objectiveId = [string](Get-QuestValue -Source $source -Names @('Id', 'ObjectiveId') -Default '')
    if ([string]::IsNullOrWhiteSpace($objectiveId)) {
        $objectiveId = "Objective_$Index"
    }

    $metadata = Get-QuestValue -Source $source -Names @('Metadata', 'Data') -Default @{}
    if ($null -eq $metadata) {
        $metadata = @{}
    }

    [bool]$isCompleted = [bool](Get-QuestValue -Source $source -Names @('IsCompleted', 'Completed', 'Done') -Default $false)
    if ($currentCount -ge $requiredCount) {
        $isCompleted = $true
        $currentCount = $requiredCount
    }

    return [PSCustomObject]@{
        Id            = [string]$objectiveId
        Type          = [string]$objectiveType
        Target        = [string]$target
        RequiredCount = [int]$requiredCount
        CurrentCount  = [int]$currentCount
        IsCompleted   = [bool]$isCompleted
        Description   = [string]$description
        Metadata      = $metadata
    }
}

function Resolve-Quest {
    param($Quest)

    if ($null -eq $Quest) {
        return $null
    }

    if ($Quest -is [string]) {
        $key = Normalize-QuestKey -Value $Quest
        if ($script:QuestById.ContainsKey($key)) {
            return $script:QuestById[$key]
        }
        return $null
    }

    if ($null -ne $Quest.PSObject.Properties['Id']) {
        $id = [string]$Quest.Id
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $key = Normalize-QuestKey -Value $id
            if ($script:QuestById.ContainsKey($key)) {
                return $script:QuestById[$key]
            }
        }
    }

    return $Quest
}

function Reset-QuestObjectives {
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    foreach ($objective in @($Quest.Objectives)) {
        if ($null -eq $objective) {
            continue
        }

        $objective.CurrentCount = [int]0
        $objective.IsCompleted = $false
    }
}

function Set-QuestLifecycleState {
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [Parameter(Mandatory = $true)][ValidateSet('NotStarted', 'InProgress', 'Completed', 'Failed')][string]$State,
        [string]$FailureReason = ''
    )

    $utcNow = [datetime]::UtcNow
    $Quest.State = [string]$State
    $Quest.LastUpdatedAt = $utcNow

    switch ($State) {
        'NotStarted' {
            $Quest.StartedAt = $null
            $Quest.CompletedAt = $null
            $Quest.FailedAt = $null
            $Quest.FailureReason = ''
        }
        'InProgress' {
            if ($null -eq $Quest.StartedAt) {
                $Quest.StartedAt = $utcNow
            }
            $Quest.CompletedAt = $null
            $Quest.FailedAt = $null
            $Quest.FailureReason = ''
        }
        'Completed' {
            if ($null -eq $Quest.StartedAt) {
                $Quest.StartedAt = $utcNow
            }
            $Quest.CompletedAt = $utcNow
            $Quest.FailedAt = $null
            $Quest.FailureReason = ''
        }
        'Failed' {
            if ($null -eq $Quest.StartedAt) {
                $Quest.StartedAt = $utcNow
            }
            $Quest.FailedAt = $utcNow
            $Quest.CompletedAt = $null
            $Quest.FailureReason = [string]$FailureReason
        }
    }
}

function Test-QuestObjectiveEventMatch {
    param(
        [Parameter(Mandatory = $true)]$Objective,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$EventTarget = '',
        $Context = $null
    )

    $objectiveType = ConvertTo-QuestObjectiveType -Type ([string]$Objective.Type)
    $incomingType = ConvertTo-QuestObjectiveType -Type $EventType -ThrowOnInvalid

    if (-not [string]::Equals($objectiveType, $incomingType, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $objectiveTarget = Normalize-QuestKey -Value ([string]$Objective.Target)
    if ([string]::IsNullOrWhiteSpace($objectiveTarget)) {
        return $true
    }

    $incomingTarget = Normalize-QuestKey -Value ([string]$EventTarget)
    if ([string]::IsNullOrWhiteSpace($incomingTarget)) {
        return $false
    }

    return [string]::Equals($objectiveTarget, $incomingTarget, [System.StringComparison]::Ordinal)
}

function Get-QuestCollectionByState {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('NotStarted', 'InProgress', 'Completed', 'Failed')][string]$State
    )

    $result = @()
    foreach ($quest in (Get-AllQuests)) {
        if ($null -eq $quest) { continue }
        if ($quest.State -eq $State) {
            $result += $quest
        }
    }

    return @($result)
}

# ============================================================================
# Public API - Initialization and Construction
# ============================================================================

function Initialize-QuestSystem {
    <#
    .SYNOPSIS
        Initializes quest system state.
    #>

    $script:QuestSystemInitialized = $true
    $script:QuestById = @{}
    $script:QuestOrder = @()
    $script:QuestNextId = [int]1
    $script:QuestFlags = @{}

    Write-Host "[Quest] Quest system initialized." -ForegroundColor Green
}

function New-QuestObjective {
    <#
    .SYNOPSIS
        Creates a normalized quest objective object.
    .PARAMETER Type
        Objective type: Kill, Gather, Talk, Explore.
    .PARAMETER Target
        Target key for event matching (enemy, item, npc, location).
    .PARAMETER RequiredCount
        Required progress count.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Kill', 'Gather', 'Talk', 'Explore')][string]$Type,
        [string]$Target = '',
        [int]$RequiredCount = 1,
        [string]$Description = '',
        [string]$ObjectiveId = ''
    )

    $source = [PSCustomObject]@{
        Type          = $Type
        Target        = $Target
        RequiredCount = $RequiredCount
        Description   = $Description
        Id            = $ObjectiveId
    }

    return (ConvertTo-QuestObjective -Objective $source -Index 1)
}

function New-Quest {
    <#
    .SYNOPSIS
        Creates and registers a quest entity.
    .DESCRIPTION
        Rewards payload is stored on the quest object but not delivered here.
    #>
    param(
        [string]$Id = '',
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Description = '',
        [object[]]$Objectives = @(),
        $Rewards = $null,
        $Metadata = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        $Id = "Quest_$($script:QuestNextId)"
        $script:QuestNextId++
    }

    if ($null -eq $Metadata) {
        $Metadata = @{}
    }

    $normalizedObjectives = @()
    [int]$index = [int]1
    foreach ($objective in @($Objectives)) {
        $normalized = ConvertTo-QuestObjective -Objective $objective -Index $index
        if ($null -ne $normalized) {
            $normalizedObjectives += $normalized
            $index++
        }
    }

    $quest = [PSCustomObject]@{
        Id           = [string]$Id
        Name         = [string]$Name
        Description  = [string]$Description
        State        = 'NotStarted'
        Objectives   = @($normalizedObjectives)
        Rewards      = $Rewards
        Metadata     = $Metadata
        StartedAt    = $null
        CompletedAt  = $null
        FailedAt     = $null
        FailureReason = ''
        LastUpdatedAt = [datetime]::UtcNow
    }

    $key = Normalize-QuestKey -Value $quest.Id
    $isNew = (-not $script:QuestById.ContainsKey($key))
    $script:QuestById[$key] = $quest

    if ($isNew) {
        $script:QuestOrder += $key
    }

    return $quest
}

# ============================================================================
# Public API - Query Helpers
# ============================================================================

function Get-Quest {
    <#
    .SYNOPSIS
        Gets a quest by id or returns resolved quest object.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    return (Resolve-Quest -Quest $Quest)
}

function Get-AllQuests {
    <#
    .SYNOPSIS
        Returns all registered quests in insertion order.
    #>

    $result = @()
    foreach ($key in @($script:QuestOrder)) {
        if ($script:QuestById.ContainsKey($key)) {
            $result += $script:QuestById[$key]
        }
    }

    return @($result)
}

function Get-ActiveQuests {
    <#
    .SYNOPSIS
        Returns all quests with state InProgress.
    #>

    return @(Get-QuestCollectionByState -State 'InProgress')
}

function Get-CompletedQuests {
    <#
    .SYNOPSIS
        Returns all quests with state Completed.
    #>

    return @(Get-QuestCollectionByState -State 'Completed')
}

function Get-FailedQuests {
    <#
    .SYNOPSIS
        Returns all quests with state Failed.
    #>

    return @(Get-QuestCollectionByState -State 'Failed')
}

function Get-QuestProgress {
    <#
    .SYNOPSIS
        Returns quest progress summary.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    $questObj = Resolve-Quest -Quest $Quest
    if ($null -eq $questObj) {
        return $null
    }

    [int]$completedObjectives = [int]0
    [int]$totalObjectives = [int]0

    foreach ($objective in @($questObj.Objectives)) {
        if ($null -eq $objective) { continue }
        $totalObjectives++

        if ([bool]$objective.IsCompleted -or [int]$objective.CurrentCount -ge [int]$objective.RequiredCount) {
            $completedObjectives++
        }
    }

    return [PSCustomObject]@{
        QuestId             = [string]$questObj.Id
        State               = [string]$questObj.State
        CompletedObjectives = [int]$completedObjectives
        TotalObjectives     = [int]$totalObjectives
        IsComplete          = [bool]($totalObjectives -gt 0 -and $completedObjectives -eq $totalObjectives)
    }
}

# ============================================================================
# Public API - State Flow
# ============================================================================

function Test-QuestObjectivesComplete {
    <#
    .SYNOPSIS
        Returns true when all quest objectives satisfy required counts.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    $questObj = Resolve-Quest -Quest $Quest
    if ($null -eq $questObj) {
        return $false
    }

    $objectives = @($questObj.Objectives)
    if ($objectives.Count -le 0) {
        return $false
    }

    foreach ($objective in $objectives) {
        if ($null -eq $objective) {
            return $false
        }

        [int]$required = [int]$objective.RequiredCount
        if ($required -lt 1) { $required = [int]1 }

        [int]$current = [int]$objective.CurrentCount
        if ($current -lt 0) { $current = [int]0 }

        if ($current -ge $required) {
            $objective.CurrentCount = $required
            $objective.IsCompleted = $true
        }
        else {
            $objective.IsCompleted = $false
            return $false
        }
    }

    return $true
}

function Start-Quest {
    <#
    .SYNOPSIS
        Moves a quest from NotStarted to InProgress.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [switch]$ForceRestart
    )

    $questObj = Resolve-Quest -Quest $Quest
    if ($null -eq $questObj) {
        Write-Warning "[Quest] Start-Quest failed: quest not found."
        return $null
    }

    if ($questObj.State -eq 'Completed' -and -not $ForceRestart) {
        return $questObj
    }

    if ($questObj.State -eq 'InProgress' -and -not $ForceRestart) {
        return $questObj
    }

    if ($ForceRestart -or $questObj.State -eq 'Failed' -or $questObj.State -eq 'Completed') {
        Reset-QuestObjectives -Quest $questObj
    }

    Set-QuestLifecycleState -Quest $questObj -State 'InProgress'

    if (Test-QuestObjectivesComplete -Quest $questObj) {
        Complete-Quest -Quest $questObj | Out-Null
    }

    return $questObj
}

function Complete-Quest {
    <#
    .SYNOPSIS
        Completes a quest when all objectives are satisfied.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [switch]$Force
    )

    $questObj = Resolve-Quest -Quest $Quest
    if ($null -eq $questObj) {
        return $null
    }

    if ($questObj.State -eq 'Completed') {
        return $questObj
    }

    if (-not $Force -and $questObj.State -ne 'InProgress') {
        return $null
    }

    if (-not $Force -and -not (Test-QuestObjectivesComplete -Quest $questObj)) {
        return $null
    }

    Set-QuestLifecycleState -Quest $questObj -State 'Completed'
    return $questObj
}

function Fail-Quest {
    <#
    .SYNOPSIS
        Marks a quest as failed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [string]$Reason = 'Failed'
    )

    $questObj = Resolve-Quest -Quest $Quest
    if ($null -eq $questObj) {
        return $null
    }

    if ($questObj.State -eq 'Completed') {
        return $null
    }

    if ($questObj.State -eq 'Failed') {
        return $questObj
    }

    Set-QuestLifecycleState -Quest $questObj -State 'Failed' -FailureReason $Reason
    return $questObj
}

# ============================================================================
# Public API - Objective Tracking
# ============================================================================

function Update-QuestObjectiveEvent {
    <#
    .SYNOPSIS
        Applies objective progress updates for an event type and target.
    .DESCRIPTION
        Event-driven helper used by Kill/Gather/Talk/Explore wrappers.
        If -Quest is omitted, updates all active quests.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Kill', 'Gather', 'Talk', 'Explore')][string]$EventType,
        [string]$Target = '',
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    if ($Count -le 0) {
        return [PSCustomObject]@{
            EventType         = [string]$EventType
            Target            = [string]$Target
            Count             = [int]$Count
            UpdatedObjectives = @()
            CompletedQuests   = @()
        }
    }

    $questsToUpdate = @()
    if ($null -ne $Quest) {
        $resolved = Resolve-Quest -Quest $Quest
        if ($null -ne $resolved) {
            $questsToUpdate += $resolved
        }
    }
    else {
        $questsToUpdate = (Get-ActiveQuests)
    }

    $updatedObjectives = @()
    $completedQuests = @()

    foreach ($questObj in @($questsToUpdate)) {
        if ($null -eq $questObj) { continue }
        if ($questObj.State -ne 'InProgress') { continue }

        [bool]$questChanged = $false

        foreach ($objective in @($questObj.Objectives)) {
            if ($null -eq $objective) { continue }
            if ([bool]$objective.IsCompleted) { continue }

            if (-not (Test-QuestObjectiveEventMatch -Objective $objective -EventType $EventType -EventTarget $Target -Context $Context)) {
                continue
            }

            [int]$before = [int]$objective.CurrentCount
            [int]$required = [int]$objective.RequiredCount
            if ($required -lt 1) { $required = [int]1 }

            [int]$after = [int]($before + $Count)
            if ($after -lt 0) { $after = [int]0 }
            if ($after -gt $required) { $after = $required }

            $objective.CurrentCount = [int]$after
            $objective.IsCompleted = [bool]($after -ge $required)

            if ($before -ne $after) {
                $questChanged = $true
                $updatedObjectives += [PSCustomObject]@{
                    QuestId       = [string]$questObj.Id
                    ObjectiveId   = [string]$objective.Id
                    Type          = [string]$objective.Type
                    Target        = [string]$objective.Target
                    PreviousCount = [int]$before
                    CurrentCount  = [int]$after
                    RequiredCount = [int]$required
                    IsCompleted   = [bool]$objective.IsCompleted
                }
            }
        }

        if ($questChanged) {
            $questObj.LastUpdatedAt = [datetime]::UtcNow

            if (Test-QuestObjectivesComplete -Quest $questObj) {
                $completedQuest = Complete-Quest -Quest $questObj
                if ($null -ne $completedQuest -and $completedQuest.State -eq 'Completed') {
                    $completedQuests += $completedQuest
                }
            }
        }
    }

    return [PSCustomObject]@{
        EventType         = [string]$EventType
        Target            = [string]$Target
        Count             = [int]$Count
        UpdatedObjectives = @($updatedObjectives)
        CompletedQuests   = @($completedQuests)
    }
}

function Update-QuestObjective {
    <#
    .SYNOPSIS
        Generic objective update helper.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Kill', 'Gather', 'Talk', 'Explore')][string]$Type,
        [string]$Target = '',
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    return (Update-QuestObjectiveEvent -EventType $Type -Target $Target -Count $Count -Quest $Quest -Context $Context)
}

function Update-QuestKill {
    <#
    .SYNOPSIS
        Event helper for Kill objectives.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    return (Update-QuestObjectiveEvent -EventType 'Kill' -Target $Target -Count $Count -Quest $Quest -Context $Context)
}

function Update-QuestGather {
    <#
    .SYNOPSIS
        Event helper for Gather objectives.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    return (Update-QuestObjectiveEvent -EventType 'Gather' -Target $Target -Count $Count -Quest $Quest -Context $Context)
}

function Update-QuestTalk {
    <#
    .SYNOPSIS
        Event helper for Talk objectives.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    return (Update-QuestObjectiveEvent -EventType 'Talk' -Target $Target -Count $Count -Quest $Quest -Context $Context)
}

function Update-QuestExplore {
    <#
    .SYNOPSIS
        Event helper for Explore objectives.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Count = 1,
        $Quest = $null,
        $Context = $null
    )

    return (Update-QuestObjectiveEvent -EventType 'Explore' -Target $Target -Count $Count -Quest $Quest -Context $Context)
}

# ============================================================================
# Public API - Dialog Compatibility Hooks
# ============================================================================

function Get-QuestState {
    <#
    .SYNOPSIS
        Returns quest state by quest id/name.
        Falls back to quest flag value for non-quest keys.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $questObj = Resolve-Quest -Quest $Name
    if ($null -ne $questObj) {
        return [string]$questObj.State
    }

    $key = Normalize-QuestKey -Value $Name
    if ($script:QuestFlags.ContainsKey($key)) {
        return $script:QuestFlags[$key]
    }

    return $null
}

function Set-QuestState {
    <#
    .SYNOPSIS
        Sets quest state for known quest ids, or stores a generic quest flag.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $questObj = Resolve-Quest -Quest $Name
    if ($null -eq $questObj) {
        return (Set-QuestFlag -Name $Name -Value $Value)
    }

    [string]$stateText = [string]$Value
    if ($stateText -in @('NotStarted', 'InProgress', 'Completed', 'Failed')) {
        switch ($stateText) {
            'NotStarted' {
                Reset-QuestObjectives -Quest $questObj
                Set-QuestLifecycleState -Quest $questObj -State 'NotStarted'
            }
            'InProgress' {
                Start-Quest -Quest $questObj | Out-Null
            }
            'Completed' {
                Complete-Quest -Quest $questObj | Out-Null
            }
            'Failed' {
                Fail-Quest -Quest $questObj | Out-Null
            }
        }

        return [string]$questObj.State
    }

    return (Set-QuestFlag -Name $Name -Value $Value)
}

function Get-QuestFlag {
    <#
    .SYNOPSIS
        Gets a generic quest flag value.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $key = Normalize-QuestKey -Value $Name
    if ($script:QuestFlags.ContainsKey($key)) {
        return $script:QuestFlags[$key]
    }

    return $null
}

function Set-QuestFlag {
    <#
    .SYNOPSIS
        Sets a generic quest flag value.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $key = Normalize-QuestKey -Value $Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    $script:QuestFlags[$key] = $Value
    return $Value
}
