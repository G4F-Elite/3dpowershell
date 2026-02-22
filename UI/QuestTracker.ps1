# ============================================================================
# UI/QuestTracker.ps1 - Active Quest Tracker Overlay
# ============================================================================
# Deterministic quest tracker HUD module.
#
# Provides:
# - Active quest list read model
# - Objective progress and completion marker model
# - Mouse-click quest selection for details
# - Explicit quest abandonment action for selected quest
# - Headless-safe render state metadata
#
# Optional dependencies:
# - UI/HUD.ps1: Draw-HUDRect, Get-HUDState, Initialize-HUD
# - Engine/OpenGL.ps1: Register-UpdateCallback, Register-RenderCallback
# - Engine/Input.ps1: Get-MousePosition, Get-MouseButton, Get-MouseButtonDown
# - Game/Quest.ps1: Get-ActiveQuests, Get-QuestProgress, Set-QuestState
# ============================================================================

# --- Module State ---
$script:QuestTrackerInitialized = $false
$script:QuestTrackerUpdateRegistered = $false
$script:QuestTrackerRenderRegistered = $false

$script:QuestTrackerReadModel = $null
$script:QuestTrackerLeftMouseWasHeld = $false
$script:QuestTrackerSelectedQuestId = ''

$script:QuestTrackerLastAction = [PSCustomObject]@{
    Action = 'None'
    Success = $false
    Reason = 'NotAttempted'
    QuestId = ''
    TimestampUtc = [DateTime]::MinValue
}

$script:QuestTrackerLastRender = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
    DrawCallEstimate = [int]0
    ListVisible = $false
    DetailsVisible = $false
}

$script:QuestTrackerTheme = [PSCustomObject]@{
    Panel = [PSCustomObject]@{ R = [float]0.04; G = [float]0.07; B = [float]0.10; A = [float]0.84 }
    PanelBorder = [PSCustomObject]@{ R = [float]0.66; G = [float]0.78; B = [float]0.91; A = [float]0.90 }
    Header = [PSCustomObject]@{ R = [float]0.10; G = [float]0.20; B = [float]0.29; A = [float]0.76 }
    QuestRow = [PSCustomObject]@{ R = [float]0.08; G = [float]0.12; B = [float]0.17; A = [float]0.88 }
    QuestRowSelected = [PSCustomObject]@{ R = [float]0.18; G = [float]0.30; B = [float]0.40; A = [float]0.93 }
    QuestRowHover = [PSCustomObject]@{ R = [float]0.22; G = [float]0.35; B = [float]0.46; A = [float]0.90 }
    ProgressTrack = [PSCustomObject]@{ R = [float]0.07; G = [float]0.09; B = [float]0.12; A = [float]0.88 }
    ProgressFill = [PSCustomObject]@{ R = [float]0.26; G = [float]0.77; B = [float]0.48; A = [float]0.94 }
    ProgressDone = [PSCustomObject]@{ R = [float]0.95; G = [float]0.84; B = [float]0.30; A = [float]0.96 }
    DetailPanel = [PSCustomObject]@{ R = [float]0.05; G = [float]0.08; B = [float]0.12; A = [float]0.90 }
    DetailAccent = [PSCustomObject]@{ R = [float]0.80; G = [float]0.88; B = [float]0.96; A = [float]0.92 }
    AbandonButton = [PSCustomObject]@{ R = [float]0.59; G = [float]0.17; B = [float]0.17; A = [float]0.90 }
    AbandonButtonHover = [PSCustomObject]@{ R = [float]0.76; G = [float]0.24; B = [float]0.24; A = [float]0.94 }
    CompleteBadge = [PSCustomObject]@{ R = [float]0.95; G = [float]0.84; B = [float]0.34; A = [float]0.96 }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Clamp-QuestTracker01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-QuestTrackerPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function New-QuestTrackerRect {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height
    )

    return [PSCustomObject]@{
        X = [float]$X
        Y = [float]$Y
        Width = [float]$Width
        Height = [float]$Height
    }
}

function Test-QuestTrackerPointInRect {
    param(
        [float]$X,
        [float]$Y,
        $Rect
    )

    if ($null -eq $Rect) { return $false }
    if ($X -lt [float]$Rect.X) { return $false }
    if ($Y -lt [float]$Rect.Y) { return $false }
    if ($X -gt [float]($Rect.X + $Rect.Width)) { return $false }
    if ($Y -gt [float]($Rect.Y + $Rect.Height)) { return $false }
    return $true
}

function Get-QuestTrackerHUDMetrics {
    [float]$scale = [float]1.0
    [float]$windowWidth = [float]1024.0
    [float]$windowHeight = [float]768.0
    [bool]$hudInitialized = $true
    [string]$source = 'Fallback'

    if (Get-Command -Name Get-HUDState -ErrorAction SilentlyContinue) {
        $state = Get-HUDState
        if ($null -ne $state) {
            if ($null -ne $state.PSObject.Properties['Scale']) {
                $scale = Clamp-QuestTrackerPositive -Value ([double]$state.Scale) -Fallback 1.0
            }
            if ($null -ne $state.PSObject.Properties['WindowWidth']) {
                $windowWidth = Clamp-QuestTrackerPositive -Value ([double]$state.WindowWidth) -Fallback 1024.0
            }
            if ($null -ne $state.PSObject.Properties['WindowHeight']) {
                $windowHeight = Clamp-QuestTrackerPositive -Value ([double]$state.WindowHeight) -Fallback 768.0
            }
            if ($null -ne $state.PSObject.Properties['Initialized']) {
                $hudInitialized = [bool]$state.Initialized
            }
            $source = 'HUDState'
        }
    }

    return [PSCustomObject]@{
        Scale = [float]$scale
        WindowWidth = [float]$windowWidth
        WindowHeight = [float]$windowHeight
        HUDInitialized = [bool]$hudInitialized
        Source = [string]$source
    }
}

function Get-QuestTrackerMousePositionInternal {
    [float]$x = [float]0.0
    [float]$y = [float]0.0

    if (Get-Command -Name Get-MousePosition -ErrorAction SilentlyContinue) {
        $pos = Get-MousePosition
        if ($null -ne $pos) {
            if ($null -ne $pos.PSObject.Properties['X']) { $x = [float]$pos.X }
            if ($null -ne $pos.PSObject.Properties['Y']) { $y = [float]$pos.Y }
        }
    }

    return [PSCustomObject]@{
        X = [float]$x
        Y = [float]$y
    }
}

function Get-QuestTrackerMouseButtonHeldInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButton -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButton -Button $Button)
    }

    return $false
}

function Get-QuestTrackerMouseButtonDownInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButtonDown -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButtonDown -Button $Button)
    }

    return $false
}

function Expand-QuestTrackerCollection {
    param($InputObject)

    $flat = @()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [System.Array] -or $item -is [System.Collections.ArrayList]) {
            foreach ($nested in $item) {
                if ($null -ne $nested) {
                    $flat += $nested
                }
            }
            continue
        }

        $flat += $item
    }

    return @($flat)
}

function Get-QuestTrackerActiveQuests {
    $quests = @()

    if (Get-Command -Name Get-ActiveQuests -ErrorAction SilentlyContinue) {
        try {
            $quests = Expand-QuestTrackerCollection -InputObject (Get-ActiveQuests)
        }
        catch {
            $quests = @()
        }
    }

    return @($quests)
}

function Get-QuestTrackerQuestProgress {
    param($Quest)

    [int]$completedObjectives = 0
    [int]$totalObjectives = 0
    [bool]$isComplete = $false

    if (Get-Command -Name Get-QuestProgress -ErrorAction SilentlyContinue) {
        try {
            $progress = Get-QuestProgress -Quest $Quest
            if ($null -ne $progress) {
                if ($null -ne $progress.PSObject.Properties['CompletedObjectives']) {
                    $completedObjectives = [int]$progress.CompletedObjectives
                }
                if ($null -ne $progress.PSObject.Properties['TotalObjectives']) {
                    $totalObjectives = [int]$progress.TotalObjectives
                }
                if ($null -ne $progress.PSObject.Properties['IsComplete']) {
                    $isComplete = [bool]$progress.IsComplete
                }
            }
        }
        catch {
            $completedObjectives = 0
            $totalObjectives = 0
            $isComplete = $false
        }
    }

    if ($totalObjectives -le 0 -and $null -ne $Quest -and $null -ne $Quest.PSObject.Properties['Objectives']) {
        foreach ($objective in @($Quest.Objectives)) {
            if ($null -eq $objective) { continue }

            $totalObjectives++

            [int]$required = 1
            [int]$current = 0
            [bool]$objectiveDone = $false

            if ($null -ne $objective.PSObject.Properties['RequiredCount']) {
                $required = [int]$objective.RequiredCount
            }
            if ($required -lt 1) { $required = 1 }

            if ($null -ne $objective.PSObject.Properties['CurrentCount']) {
                $current = [int]$objective.CurrentCount
            }
            if ($current -lt 0) { $current = 0 }

            if ($null -ne $objective.PSObject.Properties['IsCompleted']) {
                $objectiveDone = [bool]$objective.IsCompleted
            }

            if ($objectiveDone -or $current -ge $required) {
                $completedObjectives++
            }
        }

        if ($totalObjectives -gt 0 -and $completedObjectives -ge $totalObjectives) {
            $isComplete = $true
        }
    }

    [float]$ratio = [float]0.0
    if ($totalObjectives -gt 0) {
        $ratio = Clamp-QuestTracker01 -Value (([double]$completedObjectives) / ([double]$totalObjectives))
    }

    return [PSCustomObject]@{
        CompletedObjectives = [int]$completedObjectives
        TotalObjectives = [int]$totalObjectives
        IsComplete = [bool]$isComplete
        Ratio = [float]$ratio
    }
}

function Get-QuestTrackerObjectivesModel {
    param(
        $Quest,
        [float]$Scale,
        [float]$DetailX,
        [float]$DetailY,
        [float]$DetailWidth,
        [float]$StartYOffset
    )

    $result = @()
    [float]$rowH = [float][Math]::Max(14.0, 22.0 * $Scale)
    [float]$gap = [float][Math]::Max(2.0, 5.0 * $Scale)
    [float]$objWidth = [float][Math]::Max(24.0, $DetailWidth - (24.0 * $Scale))

    $index = 0
    if ($null -ne $Quest -and $null -ne $Quest.PSObject.Properties['Objectives']) {
        foreach ($objective in @($Quest.Objectives)) {
            if ($null -eq $objective) { continue }

            [string]$desc = 'Objective'
            if ($null -ne $objective.PSObject.Properties['Description'] -and -not [string]::IsNullOrWhiteSpace([string]$objective.Description)) {
                $desc = [string]$objective.Description
            }

            [int]$required = 1
            [int]$current = 0
            if ($null -ne $objective.PSObject.Properties['RequiredCount']) {
                $required = [int]$objective.RequiredCount
            }
            if ($required -lt 1) { $required = 1 }

            if ($null -ne $objective.PSObject.Properties['CurrentCount']) {
                $current = [int]$objective.CurrentCount
            }
            if ($current -lt 0) { $current = 0 }
            if ($current -gt $required) { $current = $required }

            [bool]$objectiveComplete = $false
            if ($null -ne $objective.PSObject.Properties['IsCompleted']) {
                $objectiveComplete = [bool]$objective.IsCompleted
            }
            if ($current -ge $required) {
                $objectiveComplete = $true
            }

            [float]$objectiveRatio = Clamp-QuestTracker01 -Value (([double]$current) / ([double]$required))

            [float]$rowY = [float]($DetailY + $StartYOffset + ($index * ($rowH + $gap)))

            $result += [PSCustomObject]@{
                Index = [int]$index
                Description = [string]$desc
                Current = [int]$current
                Required = [int]$required
                IsCompleted = [bool]$objectiveComplete
                Ratio = [float]$objectiveRatio
                Rect = New-QuestTrackerRect -X ([float]($DetailX + (12.0 * $Scale))) -Y $rowY -Width $objWidth -Height $rowH
            }

            $index++
        }
    }

    return @($result)
}

function Get-QuestTrackerLayout {
    param(
        [float]$Scale,
        [float]$WindowWidth,
        [float]$WindowHeight
    )

    [float]$s = Clamp-QuestTrackerPositive -Value $Scale -Fallback 1.0
    [float]$listW = [float](388.0 * $s)
    [float]$listH = [float](340.0 * $s)
    [float]$panelGap = [float](18.0 * $s)
    [float]$listX = [float][Math]::Max(8.0, [float]($WindowWidth - $listW - (26.0 * $s)))
    [float]$listY = [float](22.0 * $s)
    [float]$detailW = [float](418.0 * $s)
    [float]$detailH = [float](340.0 * $s)
    [float]$detailX = [float]($listX - $panelGap - $detailW)
    [float]$detailY = [float]$listY

    if ($detailX -lt (8.0 * $s)) {
        $detailX = [float](8.0 * $s)
    }

    return [PSCustomObject]@{
        Scale = [float]$s
        ListPanel = New-QuestTrackerRect -X $listX -Y $listY -Width $listW -Height $listH
        DetailPanel = New-QuestTrackerRect -X $detailX -Y $detailY -Width $detailW -Height $detailH
        HeaderHeight = [float](34.0 * $s)
        RowHeight = [float](52.0 * $s)
        RowGap = [float](8.0 * $s)
        ContentPadding = [float](12.0 * $s)
    }
}

function Build-QuestTrackerReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    $metrics = Get-QuestTrackerHUDMetrics
    $layout = Get-QuestTrackerLayout -Scale ([float]$metrics.Scale) -WindowWidth ([float]$metrics.WindowWidth) -WindowHeight ([float]$metrics.WindowHeight)
    $quests = Get-QuestTrackerActiveQuests

    [float]$listStartX = [float]($layout.ListPanel.X + $layout.ContentPadding)
    [float]$listStartY = [float]($layout.ListPanel.Y + $layout.HeaderHeight + $layout.ContentPadding)
    [float]$rowW = [float]($layout.ListPanel.Width - ($layout.ContentPadding * 2.0))

    $questRows = @()
    $selectedQuest = $null
    $hoverQuestId = ''

    $rowIndex = 0
    foreach ($quest in @($quests)) {
        if ($null -eq $quest) { continue }

        [string]$questId = ''
        [string]$questName = 'Quest'
        [string]$questDescription = ''
        [string]$questState = 'InProgress'

        if ($null -ne $quest.PSObject.Properties['Id']) { $questId = [string]$quest.Id }
        if ($null -ne $quest.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$quest.Name)) {
            $questName = [string]$quest.Name
        }
        if ($null -ne $quest.PSObject.Properties['Description']) {
            $questDescription = [string]$quest.Description
        }
        if ($null -ne $quest.PSObject.Properties['State']) {
            $questState = [string]$quest.State
        }

        [float]$rowY = [float]($listStartY + ($rowIndex * ($layout.RowHeight + $layout.RowGap)))
        $rowRect = New-QuestTrackerRect -X $listStartX -Y $rowY -Width $rowW -Height $layout.RowHeight
        $progress = Get-QuestTrackerQuestProgress -Quest $quest

        [bool]$isSelected = (-not [string]::IsNullOrWhiteSpace($script:QuestTrackerSelectedQuestId) -and [string]$script:QuestTrackerSelectedQuestId -eq $questId)
        [bool]$isHovered = (Test-QuestTrackerPointInRect -X $CursorX -Y $CursorY -Rect $rowRect)

        if ($isHovered) {
            $hoverQuestId = [string]$questId
        }

        $row = [PSCustomObject]@{
            Index = [int]$rowIndex
            Id = [string]$questId
            Name = [string]$questName
            Description = [string]$questDescription
            State = [string]$questState
            Progress = $progress
            Rect = $rowRect
            IsSelected = [bool]$isSelected
            IsHovered = [bool]$isHovered
            IsComplete = [bool]$progress.IsComplete
        }

        if ($isSelected) {
            $selectedQuest = $row
        }

        $questRows += $row
        $rowIndex++
    }

    if ($null -eq $selectedQuest -and $questRows.Count -gt 0) {
        $script:QuestTrackerSelectedQuestId = [string]$questRows[0].Id
        $selectedQuest = $questRows[0]
        $selectedQuest.IsSelected = $true
    }

    if ($questRows.Count -eq 0) {
        $script:QuestTrackerSelectedQuestId = ''
    }

    $selectedQuestData = $null
    if ($null -ne $selectedQuest) {
        foreach ($quest in @($quests)) {
            if ($null -eq $quest) { continue }
            if ($null -eq $quest.PSObject.Properties['Id']) { continue }
            if ([string]$quest.Id -eq [string]$selectedQuest.Id) {
                $selectedQuestData = $quest
                break
            }
        }
    }

    $objectiveRows = @()
    $abandonRect = $null

    if ($null -ne $selectedQuestData) {
        $objectiveRows = Get-QuestTrackerObjectivesModel `
            -Quest $selectedQuestData `
            -Scale ([float]$layout.Scale) `
            -DetailX ([float]$layout.DetailPanel.X) `
            -DetailY ([float]$layout.DetailPanel.Y) `
            -DetailWidth ([float]$layout.DetailPanel.Width) `
            -StartYOffset ([float]($layout.HeaderHeight + (14.0 * $layout.Scale)))

        [float]$btnW = [float][Math]::Max(90.0, 132.0 * $layout.Scale)
        [float]$btnH = [float][Math]::Max(24.0, 30.0 * $layout.Scale)
        [float]$btnX = [float]($layout.DetailPanel.X + $layout.DetailPanel.Width - $btnW - (12.0 * $layout.Scale))
        [float]$btnY = [float]($layout.DetailPanel.Y + $layout.DetailPanel.Height - $btnH - (12.0 * $layout.Scale))

        $abandonRect = New-QuestTrackerRect -X $btnX -Y $btnY -Width $btnW -Height $btnH
    }

    [bool]$hoverAbandon = $false
    if ($null -ne $abandonRect) {
        $hoverAbandon = (Test-QuestTrackerPointInRect -X $CursorX -Y $CursorY -Rect $abandonRect)
    }

    return [PSCustomObject]@{
        Initialized = [bool]$script:QuestTrackerInitialized
        UpdateRegistered = [bool]$script:QuestTrackerUpdateRegistered
        RenderRegistered = [bool]$script:QuestTrackerRenderRegistered
        Layout = $layout
        Cursor = [PSCustomObject]@{
            X = [float]$CursorX
            Y = [float]$CursorY
        }
        Quests = [PSCustomObject]@{
            ActiveCount = [int]$questRows.Count
            SelectedQuestId = [string]$script:QuestTrackerSelectedQuestId
            HoverQuestId = [string]$hoverQuestId
            Rows = @($questRows)
        }
        Details = [PSCustomObject]@{
            Visible = ($null -ne $selectedQuest)
            Quest = $selectedQuest
            Objectives = @($objectiveRows)
            AbandonButtonRect = $abandonRect
            AbandonButtonHovered = [bool]$hoverAbandon
        }
        LastAction = $script:QuestTrackerLastAction
        LastRender = $script:QuestTrackerLastRender
    }
}

function Refresh-QuestTrackerReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    $script:QuestTrackerReadModel = Build-QuestTrackerReadModel -CursorX $CursorX -CursorY $CursorY
}

function Set-QuestTrackerSelectedQuest {
    param([string]$QuestId)

    if ([string]::IsNullOrWhiteSpace($QuestId)) {
        return $null
    }

    $questRows = @()
    if ($null -ne $script:QuestTrackerReadModel -and $null -ne $script:QuestTrackerReadModel.Quests) {
        $questRows = @($script:QuestTrackerReadModel.Quests.Rows)
    }

    foreach ($row in $questRows) {
        if ($null -eq $row) { continue }
        if ([string]$row.Id -eq [string]$QuestId) {
            $script:QuestTrackerSelectedQuestId = [string]$QuestId
            return $row
        }
    }

    return $null
}

function Invoke-QuestTrackerAbandonSelected {
    if (-not $script:QuestTrackerInitialized) {
        Initialize-QuestTracker
    }

    [string]$selectedId = [string]$script:QuestTrackerSelectedQuestId
    if ([string]::IsNullOrWhiteSpace($selectedId)) {
        $script:QuestTrackerLastAction = [PSCustomObject]@{
            Action = 'AbandonQuest'
            Success = $false
            Reason = 'NoSelection'
            QuestId = ''
            TimestampUtc = [DateTime]::UtcNow
        }
        return $script:QuestTrackerLastAction
    }

    if (-not (Get-Command -Name Set-QuestState -ErrorAction SilentlyContinue)) {
        $script:QuestTrackerLastAction = [PSCustomObject]@{
            Action = 'AbandonQuest'
            Success = $false
            Reason = 'SetQuestStateMissing'
            QuestId = [string]$selectedId
            TimestampUtc = [DateTime]::UtcNow
        }
        return $script:QuestTrackerLastAction
    }

    [bool]$ok = $false
    try {
        $stateResult = Set-QuestState -Name $selectedId -Value 'Failed'
        $ok = ([string]$stateResult -eq 'Failed')
    }
    catch {
        $ok = $false
    }

    [string]$reason = 'AbandonFailed'
    if ($ok) {
        $reason = 'Abandoned'
    }

    $script:QuestTrackerLastAction = [PSCustomObject]@{
        Action = 'AbandonQuest'
        Success = [bool]$ok
        Reason = [string]$reason
        QuestId = [string]$selectedId
        TimestampUtc = [DateTime]::UtcNow
    }

    $mouse = Get-QuestTrackerMousePositionInternal
    Refresh-QuestTrackerReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    return $script:QuestTrackerLastAction
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-QuestTracker {
    <#
    .SYNOPSIS
        Initializes quest tracker state and callback wiring.
    #>
    param()

    if (Get-Command -Name Initialize-HUD -ErrorAction SilentlyContinue) {
        [bool]$needsHUDInit = $true
        if (Get-Command -Name Get-HUDState -ErrorAction SilentlyContinue) {
            $hudState = Get-HUDState
            if ($null -ne $hudState -and $null -ne $hudState.PSObject.Properties['Initialized']) {
                $needsHUDInit = -not [bool]$hudState.Initialized
            }
        }

        if ($needsHUDInit) {
            Initialize-HUD -DesignWidth 1920 -DesignHeight 1080 -ScaleMode Fit -MaxScale 2.0
        }
    }

    $script:QuestTrackerLeftMouseWasHeld = $false
    $script:QuestTrackerSelectedQuestId = ''
    $script:QuestTrackerLastAction = [PSCustomObject]@{
        Action = 'None'
        Success = $false
        Reason = 'NotAttempted'
        QuestId = ''
        TimestampUtc = [DateTime]::MinValue
    }

    $script:QuestTrackerInitialized = $true

    if (-not $script:QuestTrackerUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-QuestTracker}
            $script:QuestTrackerUpdateRegistered = $true
            Write-Host '[QuestTracker] Update callback registered.' -ForegroundColor DarkGray
        }
    }

    if (-not $script:QuestTrackerRenderRegistered) {
        if (Get-Command -Name Register-RenderCallback -ErrorAction SilentlyContinue) {
            Register-RenderCallback ${function:Render-QuestTracker}
            $script:QuestTrackerRenderRegistered = $true
            Write-Host '[QuestTracker] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    $mouse = Get-QuestTrackerMousePositionInternal
    Refresh-QuestTrackerReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    $script:QuestTrackerLastRender = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
        DrawCallEstimate = [int]0
        ListVisible = $false
        DetailsVisible = $false
    }

    Write-Host '[QuestTracker] Quest tracker initialized.' -ForegroundColor Green
}

function Update-QuestTracker {
    <#
    .SYNOPSIS
        Per-frame quest tracker update for selection and abandon actions.
    #>
    param($dt)

    if (-not $script:QuestTrackerInitialized) {
        return
    }

    $mouse = Get-QuestTrackerMousePositionInternal
    [float]$cursorX = [float]$mouse.X
    [float]$cursorY = [float]$mouse.Y

    Refresh-QuestTrackerReadModel -CursorX $cursorX -CursorY $cursorY

    [bool]$leftHeld = Get-QuestTrackerMouseButtonHeldInternal -Button 0
    [bool]$leftDown = Get-QuestTrackerMouseButtonDownInternal -Button 0
    if (-not $leftDown -and $leftHeld -and -not $script:QuestTrackerLeftMouseWasHeld) {
        $leftDown = $true
    }

    if ($leftDown -and $null -ne $script:QuestTrackerReadModel) {
        [bool]$consumed = $false

        if ($script:QuestTrackerReadModel.Details.Visible -and $null -ne $script:QuestTrackerReadModel.Details.AbandonButtonRect) {
            if (Test-QuestTrackerPointInRect -X $cursorX -Y $cursorY -Rect $script:QuestTrackerReadModel.Details.AbandonButtonRect) {
                Invoke-QuestTrackerAbandonSelected | Out-Null
                $consumed = $true
            }
        }

        if (-not $consumed) {
            foreach ($row in $script:QuestTrackerReadModel.Quests.Rows) {
                if ($null -eq $row) { continue }
                if (Test-QuestTrackerPointInRect -X $cursorX -Y $cursorY -Rect $row.Rect) {
                    [void](Set-QuestTrackerSelectedQuest -QuestId ([string]$row.Id))
                    $script:QuestTrackerLastAction = [PSCustomObject]@{
                        Action = 'SelectQuest'
                        Success = $true
                        Reason = 'Selected'
                        QuestId = [string]$row.Id
                        TimestampUtc = [DateTime]::UtcNow
                    }
                    break
                }
            }
        }
    }

    $script:QuestTrackerLeftMouseWasHeld = [bool]$leftHeld
    Refresh-QuestTrackerReadModel -CursorX $cursorX -CursorY $cursorY
}

function Render-QuestTracker {
    <#
    .SYNOPSIS
        Draws quest tracker list, progress, details, and abandon action.
    #>
    param($dt)

    if (-not $script:QuestTrackerInitialized) {
        $script:QuestTrackerLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
            DrawCallEstimate = [int]0
            ListVisible = $false
            DetailsVisible = $false
        }
        return
    }

    if (-not (Get-Command -Name Draw-HUDRect -ErrorAction SilentlyContinue)) {
        $script:QuestTrackerLastRender = [PSCustomObject]@{
            Mode = 'HeadlessNoDrawAPI'
            Rendered = $false
            Reason = 'DrawHUDRectMissing'
            DrawCallEstimate = [int]0
            ListVisible = $false
            DetailsVisible = $false
        }
        return
    }

    $metrics = Get-QuestTrackerHUDMetrics
    if (-not [bool]$metrics.HUDInitialized) {
        $script:QuestTrackerLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'HUDNotInitialized'
            DrawCallEstimate = [int]0
            ListVisible = $false
            DetailsVisible = $false
        }
        return
    }

    $mouse = Get-QuestTrackerMousePositionInternal
    Refresh-QuestTrackerReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    [float]$z = [float]-0.945
    [int]$drawCount = 0

    $layout = $script:QuestTrackerReadModel.Layout
    [float]$scale = [float]$layout.Scale
    [float]$border = [float][Math]::Max(1.0, [Math]::Round($scale))

    Begin-HUDBatch
    try {
        # List panel
        Draw-HUDRect -X ([float]$layout.ListPanel.X) -Y ([float]$layout.ListPanel.Y) -Width ([float]$layout.ListPanel.Width) -Height ([float]$layout.ListPanel.Height) -Z $z -R ([float]$script:QuestTrackerTheme.Panel.R) -G ([float]$script:QuestTrackerTheme.Panel.G) -B ([float]$script:QuestTrackerTheme.Panel.B) -A ([float]$script:QuestTrackerTheme.Panel.A)
        $drawCount++

    Draw-HUDRect -X ([float]$layout.ListPanel.X) -Y ([float]$layout.ListPanel.Y) -Width ([float]$layout.ListPanel.Width) -Height $border -Z ($z - 0.0001) -R ([float]$script:QuestTrackerTheme.PanelBorder.R) -G ([float]$script:QuestTrackerTheme.PanelBorder.G) -B ([float]$script:QuestTrackerTheme.PanelBorder.B) -A ([float]$script:QuestTrackerTheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X ([float]$layout.ListPanel.X) -Y ([float]($layout.ListPanel.Y + $layout.ListPanel.Height - $border)) -Width ([float]$layout.ListPanel.Width) -Height $border -Z ($z - 0.0001) -R ([float]$script:QuestTrackerTheme.PanelBorder.R) -G ([float]$script:QuestTrackerTheme.PanelBorder.G) -B ([float]$script:QuestTrackerTheme.PanelBorder.B) -A ([float]$script:QuestTrackerTheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X ([float]$layout.ListPanel.X) -Y ([float]$layout.ListPanel.Y) -Width $border -Height ([float]$layout.ListPanel.Height) -Z ($z - 0.0001) -R ([float]$script:QuestTrackerTheme.PanelBorder.R) -G ([float]$script:QuestTrackerTheme.PanelBorder.G) -B ([float]$script:QuestTrackerTheme.PanelBorder.B) -A ([float]$script:QuestTrackerTheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X ([float]($layout.ListPanel.X + $layout.ListPanel.Width - $border)) -Y ([float]$layout.ListPanel.Y) -Width $border -Height ([float]$layout.ListPanel.Height) -Z ($z - 0.0001) -R ([float]$script:QuestTrackerTheme.PanelBorder.R) -G ([float]$script:QuestTrackerTheme.PanelBorder.G) -B ([float]$script:QuestTrackerTheme.PanelBorder.B) -A ([float]$script:QuestTrackerTheme.PanelBorder.A)
    $drawCount++

    Draw-HUDRect -X ([float]$layout.ListPanel.X + $border) -Y ([float]$layout.ListPanel.Y + $border) -Width ([float]($layout.ListPanel.Width - ($border * 2.0))) -Height ([float][Math]::Max(4.0, $layout.HeaderHeight - $border)) -Z ($z - 0.0002) -R ([float]$script:QuestTrackerTheme.Header.R) -G ([float]$script:QuestTrackerTheme.Header.G) -B ([float]$script:QuestTrackerTheme.Header.B) -A ([float]$script:QuestTrackerTheme.Header.A)
    $drawCount++

    foreach ($row in $script:QuestTrackerReadModel.Quests.Rows) {
        if ($null -eq $row) { continue }

        $rowColor = $script:QuestTrackerTheme.QuestRow
        if ([bool]$row.IsSelected) {
            $rowColor = $script:QuestTrackerTheme.QuestRowSelected
        }
        elseif ([bool]$row.IsHovered) {
            $rowColor = $script:QuestTrackerTheme.QuestRowHover
        }

        Draw-HUDRect -X ([float]$row.Rect.X) -Y ([float]$row.Rect.Y) -Width ([float]$row.Rect.Width) -Height ([float]$row.Rect.Height) -Z ($z - 0.0003) -R ([float]$rowColor.R) -G ([float]$rowColor.G) -B ([float]$rowColor.B) -A ([float]$rowColor.A)
        $drawCount++

        [float]$trackX = [float]($row.Rect.X + (10.0 * $scale))
        [float]$trackY = [float]($row.Rect.Y + $row.Rect.Height - (10.0 * $scale))
        [float]$trackW = [float][Math]::Max(10.0, $row.Rect.Width - (20.0 * $scale))
        [float]$trackH = [float][Math]::Max(2.0, 4.0 * $scale)
        [float]$fillW = [float]($trackW * [float]$row.Progress.Ratio)

        Draw-HUDRect -X $trackX -Y $trackY -Width $trackW -Height $trackH -Z ($z - 0.00035) -R ([float]$script:QuestTrackerTheme.ProgressTrack.R) -G ([float]$script:QuestTrackerTheme.ProgressTrack.G) -B ([float]$script:QuestTrackerTheme.ProgressTrack.B) -A ([float]$script:QuestTrackerTheme.ProgressTrack.A)
        $drawCount++

        if ($fillW -gt 0.0) {
            $progressColor = $script:QuestTrackerTheme.ProgressFill
            if ([bool]$row.IsComplete) {
                $progressColor = $script:QuestTrackerTheme.ProgressDone
            }

            Draw-HUDRect -X $trackX -Y $trackY -Width $fillW -Height $trackH -Z ($z - 0.00036) -R ([float]$progressColor.R) -G ([float]$progressColor.G) -B ([float]$progressColor.B) -A ([float]$progressColor.A)
            $drawCount++
        }

        if ([bool]$row.IsComplete) {
            [float]$badgeW = [float][Math]::Max(8.0, 12.0 * $scale)
            [float]$badgeH = [float][Math]::Max(8.0, 12.0 * $scale)
            Draw-HUDRect -X ([float]($row.Rect.X + $row.Rect.Width - $badgeW - (6.0 * $scale))) -Y ([float]($row.Rect.Y + (6.0 * $scale))) -Width $badgeW -Height $badgeH -Z ($z - 0.00037) -R ([float]$script:QuestTrackerTheme.CompleteBadge.R) -G ([float]$script:QuestTrackerTheme.CompleteBadge.G) -B ([float]$script:QuestTrackerTheme.CompleteBadge.B) -A ([float]$script:QuestTrackerTheme.CompleteBadge.A)
            $drawCount++
        }
    }

    [bool]$detailsVisible = [bool]$script:QuestTrackerReadModel.Details.Visible
    if ($detailsVisible) {
        # Detail panel
        Draw-HUDRect -X ([float]$layout.DetailPanel.X) -Y ([float]$layout.DetailPanel.Y) -Width ([float]$layout.DetailPanel.Width) -Height ([float]$layout.DetailPanel.Height) -Z ($z - 0.0004) -R ([float]$script:QuestTrackerTheme.DetailPanel.R) -G ([float]$script:QuestTrackerTheme.DetailPanel.G) -B ([float]$script:QuestTrackerTheme.DetailPanel.B) -A ([float]$script:QuestTrackerTheme.DetailPanel.A)
        $drawCount++

        Draw-HUDRect -X ([float]$layout.DetailPanel.X) -Y ([float]$layout.DetailPanel.Y) -Width ([float]$layout.DetailPanel.Width) -Height $border -Z ($z - 0.00041) -R ([float]$script:QuestTrackerTheme.DetailAccent.R) -G ([float]$script:QuestTrackerTheme.DetailAccent.G) -B ([float]$script:QuestTrackerTheme.DetailAccent.B) -A ([float]$script:QuestTrackerTheme.DetailAccent.A)
        $drawCount++

        Draw-HUDRect -X ([float]$layout.DetailPanel.X + (10.0 * $scale)) -Y ([float]($layout.DetailPanel.Y + ($layout.HeaderHeight * 0.5))) -Width ([float][Math]::Max(24.0, $layout.DetailPanel.Width - (20.0 * $scale))) -Height ([float][Math]::Max(2.0, 3.0 * $scale)) -Z ($z - 0.00042) -R ([float]$script:QuestTrackerTheme.DetailAccent.R) -G ([float]$script:QuestTrackerTheme.DetailAccent.G) -B ([float]$script:QuestTrackerTheme.DetailAccent.B) -A 0.58
        $drawCount++

        foreach ($objective in $script:QuestTrackerReadModel.Details.Objectives) {
            if ($null -eq $objective) { continue }

            $objectiveColor = $script:QuestTrackerTheme.QuestRow
            if ([bool]$objective.IsCompleted) {
                $objectiveColor = $script:QuestTrackerTheme.QuestRowSelected
            }

            Draw-HUDRect -X ([float]$objective.Rect.X) -Y ([float]$objective.Rect.Y) -Width ([float]$objective.Rect.Width) -Height ([float]$objective.Rect.Height) -Z ($z - 0.00043) -R ([float]$objectiveColor.R) -G ([float]$objectiveColor.G) -B ([float]$objectiveColor.B) -A ([float]$objectiveColor.A)
            $drawCount++

            [float]$objTrackX = [float]($objective.Rect.X + (7.0 * $scale))
            [float]$objTrackY = [float]($objective.Rect.Y + $objective.Rect.Height - (6.0 * $scale))
            [float]$objTrackW = [float][Math]::Max(8.0, $objective.Rect.Width - (14.0 * $scale))
            [float]$objTrackH = [float][Math]::Max(1.0, 3.0 * $scale)
            [float]$objFillW = [float]($objTrackW * [float]$objective.Ratio)

            Draw-HUDRect -X $objTrackX -Y $objTrackY -Width $objTrackW -Height $objTrackH -Z ($z - 0.00044) -R ([float]$script:QuestTrackerTheme.ProgressTrack.R) -G ([float]$script:QuestTrackerTheme.ProgressTrack.G) -B ([float]$script:QuestTrackerTheme.ProgressTrack.B) -A ([float]$script:QuestTrackerTheme.ProgressTrack.A)
            $drawCount++

            if ($objFillW -gt 0.0) {
                $objColor = $script:QuestTrackerTheme.ProgressFill
                if ([bool]$objective.IsCompleted) {
                    $objColor = $script:QuestTrackerTheme.ProgressDone
                }

                Draw-HUDRect -X $objTrackX -Y $objTrackY -Width $objFillW -Height $objTrackH -Z ($z - 0.00045) -R ([float]$objColor.R) -G ([float]$objColor.G) -B ([float]$objColor.B) -A ([float]$objColor.A)
                $drawCount++
            }

            if ([bool]$objective.IsCompleted) {
                [float]$objBadgeW = [float][Math]::Max(6.0, 10.0 * $scale)
                [float]$objBadgeH = [float][Math]::Max(6.0, 10.0 * $scale)
                Draw-HUDRect -X ([float]($objective.Rect.X + $objective.Rect.Width - $objBadgeW - (5.0 * $scale))) -Y ([float]($objective.Rect.Y + (5.0 * $scale))) -Width $objBadgeW -Height $objBadgeH -Z ($z - 0.000451) -R ([float]$script:QuestTrackerTheme.CompleteBadge.R) -G ([float]$script:QuestTrackerTheme.CompleteBadge.G) -B ([float]$script:QuestTrackerTheme.CompleteBadge.B) -A ([float]$script:QuestTrackerTheme.CompleteBadge.A)
                $drawCount++
            }
        }

        if ($null -ne $script:QuestTrackerReadModel.Details.AbandonButtonRect) {
            $btnColor = $script:QuestTrackerTheme.AbandonButton
            if ([bool]$script:QuestTrackerReadModel.Details.AbandonButtonHovered) {
                $btnColor = $script:QuestTrackerTheme.AbandonButtonHover
            }

            Draw-HUDRect -X ([float]$script:QuestTrackerReadModel.Details.AbandonButtonRect.X) -Y ([float]$script:QuestTrackerReadModel.Details.AbandonButtonRect.Y) -Width ([float]$script:QuestTrackerReadModel.Details.AbandonButtonRect.Width) -Height ([float]$script:QuestTrackerReadModel.Details.AbandonButtonRect.Height) -Z ($z - 0.00046) -R ([float]$btnColor.R) -G ([float]$btnColor.G) -B ([float]$btnColor.B) -A ([float]$btnColor.A)
            $drawCount++
        }
    }

        $script:QuestTrackerLastRender = [PSCustomObject]@{
            Mode = 'HUDOverlay'
            Rendered = $true
            Reason = 'Rendered'
            DrawCallEstimate = [int]$drawCount
            ListVisible = ($script:QuestTrackerReadModel.Quests.ActiveCount -ge 0)
            DetailsVisible = [bool]$detailsVisible
        }

        $script:QuestTrackerReadModel.LastRender = $script:QuestTrackerLastRender
    }
    catch {
        $script:QuestTrackerLastRender = [PSCustomObject]@{
            Mode = 'DrawFailed'
            Rendered = $false
            Reason = [string]$_.Exception.Message
            DrawCallEstimate = [int]$drawCount
            ListVisible = $false
            DetailsVisible = $false
        }
    }
    finally {
        End-HUDBatch
    }
}

function Get-QuestTrackerState {
    <#
    .SYNOPSIS
        Returns deterministic quest tracker state for verification and UI integration.
    #>

    if (-not $script:QuestTrackerInitialized) {
        return [PSCustomObject]@{
            Initialized = $false
            UpdateRegistered = [bool]$script:QuestTrackerUpdateRegistered
            RenderRegistered = [bool]$script:QuestTrackerRenderRegistered
            Layout = $null
            Cursor = [PSCustomObject]@{ X = [float]0.0; Y = [float]0.0 }
            Quests = [PSCustomObject]@{
                ActiveCount = [int]0
                SelectedQuestId = ''
                HoverQuestId = ''
                Rows = @()
            }
            Details = [PSCustomObject]@{
                Visible = $false
                Quest = $null
                Objectives = @()
                AbandonButtonRect = $null
                AbandonButtonHovered = $false
            }
            LastAction = $script:QuestTrackerLastAction
            LastRender = $script:QuestTrackerLastRender
        }
    }

    $mouse = Get-QuestTrackerMousePositionInternal
    Refresh-QuestTrackerReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)
    return $script:QuestTrackerReadModel
}
