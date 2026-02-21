# ============================================================================
# UI/InventoryUI.ps1 - Inventory Surface and Interaction Model
# ============================================================================
# Deterministic inventory overlay module.
#
# Provides:
# - 9x4 inventory grid display model and HUD overlay rendering
# - Procedural item icon descriptors and icon rendering
# - Hover tooltip model for inventory/equipment/crafting entries
# - Drag and drop state machine for inventory and equipment movement
# - Equipment slot display model
# - Crafting surface integration hooks (selection and craft invoke)
#
# Optional dependencies:
# - UI/HUD.ps1: Draw-HUDRect, Get-HUDState, Initialize-HUD
# - Engine/OpenGL.ps1: Register-UpdateCallback, Register-RenderCallback
# - Engine/Input.ps1: Get-MousePosition, Get-MouseButton, Get-MouseButtonDown
# - Game/Inventory.ps1: Get-InventorySlots, Get-InventoryOpen, Get-HotbarSelection
# - Game/Equipment.ps1: Get-AllEquipment, Get-EquippedItem, Equip-Item, Unequip-Item
# - Game/Crafting.ps1: Get-AllCraftingRecipes, Test-CanCraft, Get-MaxCraftCount, Invoke-Craft
# - Data/Items.ps1: Get-ItemDefinition, Get-ItemStackSize
# ============================================================================

# --- Module State ---
$script:InventoryUIInitialized = $false
$script:InventoryUIUpdateRegistered = $false
$script:InventoryUIRenderRegistered = $false

$script:InventoryUIGridColumns = [int]9
$script:InventoryUIGridRows = [int]4
$script:InventoryUIHotbarSize = [int]9
$script:InventoryUIEquipmentSlotOrder = @('MainHand', 'OffHand', 'Helmet', 'Chest', 'Legs', 'Boots')

$script:InventoryUICraftingSelection = [int]-1
$script:InventoryUICraftingLastAttempt = [PSCustomObject]@{
    Success = $false
    RecipeName = ''
    Count = [int]0
    Reason = 'NotAttempted'
    TimestampUtc = [DateTime]::MinValue
}

$script:InventoryUIHoverState = [PSCustomObject]@{
    Kind = 'None'
    Index = [int]-1
    SlotName = ''
    ItemName = ''
    Count = [int]0
    Tooltip = $null
    CursorX = [float]0.0
    CursorY = [float]0.0
}

$script:InventoryUIDragState = [PSCustomObject]@{
    Phase = 'Idle'
    SourceKind = 'None'
    SourceIndex = [int]-1
    SourceSlotName = ''
    ItemName = ''
    Count = [int]0
    StartedAtUtc = [DateTime]::MinValue
    LastDropResult = [PSCustomObject]@{
        Success = $false
        Action = 'None'
        Reason = 'NotAttempted'
        SourceKind = 'None'
        SourceIndex = [int]-1
        SourceSlotName = ''
        TargetKind = 'None'
        TargetIndex = [int]-1
        TargetSlotName = ''
        TimestampUtc = [DateTime]::MinValue
    }
}

$script:InventoryUILeftMouseWasHeld = $false

$script:InventoryUIReadModel = $null

$script:InventoryUILastRender = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
    DrawCallEstimate = [int]0
    TooltipVisible = $false
    DragVisualVisible = $false
}

$script:InventoryUITheme = [PSCustomObject]@{
    Panel = [PSCustomObject]@{ R = [float]0.05; G = [float]0.07; B = [float]0.10; A = [float]0.82 }
    PanelBorder = [PSCustomObject]@{ R = [float]0.62; G = [float]0.72; B = [float]0.85; A = [float]0.90 }
    Section = [PSCustomObject]@{ R = [float]0.07; G = [float]0.10; B = [float]0.14; A = [float]0.72 }
    SlotEmpty = [PSCustomObject]@{ R = [float]0.08; G = [float]0.10; B = [float]0.14; A = [float]0.88 }
    SlotFilled = [PSCustomObject]@{ R = [float]0.13; G = [float]0.17; B = [float]0.24; A = [float]0.95 }
    SlotHover = [PSCustomObject]@{ R = [float]0.24; G = [float]0.31; B = [float]0.42; A = [float]0.92 }
    SlotSelected = [PSCustomObject]@{ R = [float]0.83; G = [float]0.68; B = [float]0.20; A = [float]0.92 }
    CraftReady = [PSCustomObject]@{ R = [float]0.20; G = [float]0.68; B = [float]0.36; A = [float]0.90 }
    CraftBlocked = [PSCustomObject]@{ R = [float]0.60; G = [float]0.22; B = [float]0.22; A = [float]0.88 }
    TooltipPanel = [PSCustomObject]@{ R = [float]0.03; G = [float]0.05; B = [float]0.08; A = [float]0.95 }
    TooltipBorder = [PSCustomObject]@{ R = [float]0.70; G = [float]0.78; B = [float]0.90; A = [float]0.94 }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Clamp-InventoryUI01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-InventoryUIPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function New-InventoryUIColor {
    param(
        [double]$R,
        [double]$G,
        [double]$B,
        [double]$A
    )

    return [PSCustomObject]@{
        R = Clamp-InventoryUI01 -Value $R
        G = Clamp-InventoryUI01 -Value $G
        B = Clamp-InventoryUI01 -Value $B
        A = Clamp-InventoryUI01 -Value $A
    }
}

function New-InventoryUIRect {
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

function Test-InventoryUIPointInRect {
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

function New-InventoryUIDropResult {
    param(
        [bool]$Success,
        [string]$Action,
        [string]$Reason,
        [string]$SourceKind = 'None',
        [int]$SourceIndex = -1,
        [string]$SourceSlotName = '',
        [string]$TargetKind = 'None',
        [int]$TargetIndex = -1,
        [string]$TargetSlotName = ''
    )

    return [PSCustomObject]@{
        Success = [bool]$Success
        Action = [string]$Action
        Reason = [string]$Reason
        SourceKind = [string]$SourceKind
        SourceIndex = [int]$SourceIndex
        SourceSlotName = [string]$SourceSlotName
        TargetKind = [string]$TargetKind
        TargetIndex = [int]$TargetIndex
        TargetSlotName = [string]$TargetSlotName
        TimestampUtc = [DateTime]::UtcNow
    }
}

function Expand-InventoryUICollection {
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

function Get-InventoryUISlotCount {
    [int]$count = [int]($script:InventoryUIGridColumns * $script:InventoryUIGridRows)

    $slotCountVar = Get-Variable -Scope Script -Name InventorySlotCount -ErrorAction SilentlyContinue
    if ($null -ne $slotCountVar) {
        try {
            $count = [int]$slotCountVar.Value
        }
        catch {
            $count = [int]($script:InventoryUIGridColumns * $script:InventoryUIGridRows)
        }
    }

    if ($count -lt 1) {
        $count = [int]($script:InventoryUIGridColumns * $script:InventoryUIGridRows)
    }

    return [int]$count
}

function Get-InventoryUIHotbarSize {
    [int]$size = [int]$script:InventoryUIHotbarSize

    $hotbarSizeVar = Get-Variable -Scope Script -Name InventoryHotbarSize -ErrorAction SilentlyContinue
    if ($null -ne $hotbarSizeVar) {
        try {
            $size = [int]$hotbarSizeVar.Value
        }
        catch {
            $size = [int]$script:InventoryUIHotbarSize
        }
    }

    if ($size -lt 0) { $size = 0 }
    return [int]$size
}

function Get-InventoryUIInventoryOpenState {
    if (Get-Command -Name Get-InventoryOpen -ErrorAction SilentlyContinue) {
        return [bool](Get-InventoryOpen)
    }

    $openVar = Get-Variable -Scope Script -Name InventoryOpen -ErrorAction SilentlyContinue
    if ($null -ne $openVar) {
        return [bool]$openVar.Value
    }

    return $false
}

function Get-InventoryUIInventorySlots {
    $slots = @()

    if (Get-Command -Name Get-InventorySlots -ErrorAction SilentlyContinue) {
        $slots = Expand-InventoryUICollection -InputObject (Get-InventorySlots)
    }

    [int]$slotCount = Get-InventoryUISlotCount
    if ($slots.Count -lt $slotCount) {
        for ($i = $slots.Count; $i -lt $slotCount; $i++) {
            $slots += [PSCustomObject]@{
                ItemName = ''
                Count = [int]0
            }
        }
    }

    return @($slots)
}

function Get-InventoryUIEquipmentMap {
    $equipment = @{}

    if (Get-Command -Name Get-AllEquipment -ErrorAction SilentlyContinue) {
        $raw = Get-AllEquipment
        if ($raw -is [hashtable]) {
            $equipment = @{}
            foreach ($k in $raw.Keys) {
                $equipment[$k] = [string]$raw[$k]
            }
        }
    }

    foreach ($slotName in $script:InventoryUIEquipmentSlotOrder) {
        if (-not $equipment.ContainsKey($slotName)) {
            $equipment[$slotName] = ''
        }
    }

    return $equipment
}

function Get-InventoryUIAllRecipes {
    $recipes = @()

    if (Get-Command -Name Get-AllCraftingRecipes -ErrorAction SilentlyContinue) {
        $recipes = Expand-InventoryUICollection -InputObject (Get-AllCraftingRecipes)
    }

    if ($recipes.Count -eq 0 -and (Get-Command -Name Get-CraftableItems -ErrorAction SilentlyContinue)) {
        $recipes = Expand-InventoryUICollection -InputObject (Get-CraftableItems)
    }

    $clean = @()
    foreach ($recipe in $recipes) {
        if ($null -eq $recipe) { continue }
        if ($null -eq $recipe.PSObject.Properties['Name']) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$recipe.Name)) { continue }
        $clean += $recipe
    }

    $ordered = @($clean | Sort-Object -Property Name)
    return @($ordered)
}

function Get-InventoryUIMousePositionInternal {
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

function Get-InventoryUIMouseButtonHeldInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButton -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButton -Button $Button)
    }

    return $false
}

function Get-InventoryUIMouseButtonDownInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButtonDown -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButtonDown -Button $Button)
    }

    return $false
}

function Get-InventoryUIHUDMetrics {
    [float]$scale = [float]1.0
    [float]$windowWidth = [float]1024.0
    [float]$windowHeight = [float]768.0
    [bool]$hudInitialized = $true
    [string]$source = 'Fallback'

    if (Get-Command -Name Get-HUDState -ErrorAction SilentlyContinue) {
        $state = Get-HUDState
        if ($null -ne $state) {
            if ($null -ne $state.PSObject.Properties['Scale']) {
                $scale = Clamp-InventoryUIPositive -Value ([double]$state.Scale) -Fallback 1.0
            }
            if ($null -ne $state.PSObject.Properties['WindowWidth']) {
                $windowWidth = Clamp-InventoryUIPositive -Value ([double]$state.WindowWidth) -Fallback 1024.0
            }
            if ($null -ne $state.PSObject.Properties['WindowHeight']) {
                $windowHeight = Clamp-InventoryUIPositive -Value ([double]$state.WindowHeight) -Fallback 768.0
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

function Get-InventoryUIStringHash {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [int]0
    }

    [int64]$hash = 17
    foreach ($ch in $Value.ToCharArray()) {
        $hash = (($hash * 31) -bxor [int64][char]$ch)
        $hash = ($hash -band 2147483647)
    }

    return [int]$hash
}

function Get-InventoryUIItemIconDescriptor {
    param(
        [string]$ItemName,
        [int]$Count
    )

    if ([string]::IsNullOrWhiteSpace($ItemName) -or $Count -le 0) {
        return $null
    }

    $itemDef = $null
    if (Get-Command -Name Get-ItemDefinition -ErrorAction SilentlyContinue) {
        $itemDef = Get-ItemDefinition -Name $ItemName
    }

    [string]$itemType = 'Unknown'
    if ($null -ne $itemDef -and $null -ne $itemDef.PSObject.Properties['Type']) {
        $itemType = [string]$itemDef.Type
    }

    $baseColor = New-InventoryUIColor -R 0.50 -G 0.50 -B 0.52 -A 0.95
    $accentColor = New-InventoryUIColor -R 0.86 -G 0.86 -B 0.90 -A 0.96

    switch ($itemType.ToLowerInvariant()) {
        'resource' {
            $baseColor = New-InventoryUIColor -R 0.38 -G 0.34 -B 0.29 -A 0.95
            $accentColor = New-InventoryUIColor -R 0.83 -G 0.73 -B 0.52 -A 0.96
        }
        'tool' {
            $baseColor = New-InventoryUIColor -R 0.25 -G 0.32 -B 0.42 -A 0.95
            $accentColor = New-InventoryUIColor -R 0.62 -G 0.84 -B 0.95 -A 0.96
        }
        'weapon' {
            $baseColor = New-InventoryUIColor -R 0.43 -G 0.20 -B 0.22 -A 0.95
            $accentColor = New-InventoryUIColor -R 0.95 -G 0.46 -B 0.44 -A 0.96
        }
        'armor' {
            $baseColor = New-InventoryUIColor -R 0.21 -G 0.36 -B 0.34 -A 0.95
            $accentColor = New-InventoryUIColor -R 0.55 -G 0.92 -B 0.79 -A 0.96
        }
        'consumable' {
            $baseColor = New-InventoryUIColor -R 0.36 -G 0.23 -B 0.38 -A 0.95
            $accentColor = New-InventoryUIColor -R 0.94 -G 0.63 -B 0.90 -A 0.96
        }
    }

    [int]$hash = Get-InventoryUIStringHash -Value $ItemName
    [int]$rot = [int]($hash % 9)
    [System.Collections.ArrayList]$cells = [System.Collections.ArrayList]::new()

    for ($y = 0; $y -lt 3; $y++) {
        for ($x = 0; $x -lt 3; $x++) {
            [int]$index = [int](($x + ($y * 3) + $rot) % 16)
            if (((($hash -shr $index) -band 1) -eq 1)) {
                $cells.Add([PSCustomObject]@{ X = [int]$x; Y = [int]$y }) | Out-Null
            }
        }
    }

    if ($cells.Count -eq 0) {
        $cells.Add([PSCustomObject]@{ X = [int]1; Y = [int]1 }) | Out-Null
    }

    [int]$stackSize = [int]64
    if (Get-Command -Name Get-ItemStackSize -ErrorAction SilentlyContinue) {
        try {
            $stackSize = [int](Get-ItemStackSize -Name $ItemName)
        }
        catch {
            $stackSize = [int]64
        }
    }

    if ($stackSize -lt 1) { $stackSize = 1 }

    return [PSCustomObject]@{
        ItemName = [string]$ItemName
        ItemType = [string]$itemType
        Count = [int]$Count
        StackSize = [int]$stackSize
        CountRatio = [float](Clamp-InventoryUI01 -Value (([double]$Count) / ([double]$stackSize)))
        Seed = [int]$hash
        BaseColor = $baseColor
        AccentColor = $accentColor
        Cells = @($cells)
    }
}

function Get-InventoryUILayout {
    param(
        [float]$Scale,
        [float]$WindowWidth,
        [float]$WindowHeight
    )

    [float]$resolvedScale = Clamp-InventoryUIPositive -Value $Scale -Fallback 1.0
    [float]$w = Clamp-InventoryUIPositive -Value $WindowWidth -Fallback 1024.0
    [float]$h = Clamp-InventoryUIPositive -Value $WindowHeight -Fallback 768.0

    [float]$panelW = [float][Math]::Min($w - (26.0 * $resolvedScale), 1080.0 * $resolvedScale)
    [float]$panelH = [float][Math]::Min($h - (26.0 * $resolvedScale), 640.0 * $resolvedScale)

    if ($panelW -lt 760.0) { $panelW = [float][Math]::Min($w - 4.0, 760.0) }
    if ($panelH -lt 460.0) { $panelH = [float][Math]::Min($h - 4.0, 460.0) }
    if ($panelW -lt 1.0) { $panelW = [float]1.0 }
    if ($panelH -lt 1.0) { $panelH = [float]1.0 }

    [float]$panelX = [float](($w - $panelW) * 0.5)
    [float]$panelY = [float](($h - $panelH) * 0.5)

    [float]$outerPad = [float][Math]::Max(8.0, 16.0 * $resolvedScale)
    [float]$sectionGap = [float][Math]::Max(6.0, 12.0 * $resolvedScale)
    [float]$slotSize = [float][Math]::Max(24.0, 48.0 * $resolvedScale)
    [float]$slotGap = [float][Math]::Max(3.0, 7.0 * $resolvedScale)
    [float]$headerH = [float][Math]::Max(12.0, 22.0 * $resolvedScale)

    [float]$gridW = [float](($script:InventoryUIGridColumns * $slotSize) + (($script:InventoryUIGridColumns - 1) * $slotGap))
    [float]$gridH = [float](($script:InventoryUIGridRows * $slotSize) + (($script:InventoryUIGridRows - 1) * $slotGap))
    [float]$gridX = [float]($panelX + $outerPad)
    [float]$gridY = [float]($panelY + $outerPad + $headerH)

    [float]$rightX = [float]($gridX + $gridW + $sectionGap)
    [float]$rightW = [float](($panelX + $panelW - $outerPad) - $rightX)
    if ($rightW -lt 120.0) {
        $rightW = [float]120.0
    }

    [float]$equipmentSlotSize = [float][Math]::Min($slotSize, (($rightW - $slotGap) * 0.5))
    if ($equipmentSlotSize -lt 18.0) { $equipmentSlotSize = [float]18.0 }
    [float]$equipmentX = [float]$rightX
    [float]$equipmentY = [float]$gridY
    [float]$equipmentW = [float](($equipmentSlotSize * 2.0) + $slotGap)
    [float]$equipmentH = [float](($equipmentSlotSize * 3.0) + ($slotGap * 2.0))

    [float]$craftX = [float]$rightX
    [float]$craftY = [float]($equipmentY + $equipmentH + $sectionGap)
    [float]$craftW = [float][Math]::Max(80.0, $rightW)
    [float]$craftRowH = [float][Math]::Max(16.0, 26.0 * $resolvedScale)

    [float]$craftBottom = [float]($panelY + $panelH - $outerPad)
    [int]$craftRowsVisible = [int][Math]::Floor(($craftBottom - $craftY + $slotGap) / ($craftRowH + $slotGap))
    if ($craftRowsVisible -lt 1) { $craftRowsVisible = 1 }
    if ($craftRowsVisible -gt 10) { $craftRowsVisible = 10 }

    return [PSCustomObject]@{
        Scale = [float]$resolvedScale
        Panel = (New-InventoryUIRect -X $panelX -Y $panelY -Width $panelW -Height $panelH)
        OuterPad = [float]$outerPad
        SectionGap = [float]$sectionGap
        SlotSize = [float]$slotSize
        SlotGap = [float]$slotGap
        HeaderHeight = [float]$headerH
        GridRect = (New-InventoryUIRect -X $gridX -Y $gridY -Width $gridW -Height $gridH)
        RightRect = (New-InventoryUIRect -X $rightX -Y $gridY -Width $rightW -Height ($gridH + $headerH))
        EquipmentRect = (New-InventoryUIRect -X $equipmentX -Y $equipmentY -Width $equipmentW -Height $equipmentH)
        EquipmentSlotSize = [float]$equipmentSlotSize
        CraftRect = (New-InventoryUIRect -X $craftX -Y $craftY -Width $craftW -Height ([float]($craftRowsVisible * ($craftRowH + $slotGap))))
        CraftRowHeight = [float]$craftRowH
        CraftRowsVisible = [int]$craftRowsVisible
    }
}

function Get-InventoryUIGridSlotsModel {
    param($Layout)

    $slotsData = Get-InventoryUIInventorySlots
    [int]$hotbarSize = Get-InventoryUIHotbarSize
    [int]$selectedHotbar = [int]-1

    if (Get-Command -Name Get-HotbarSelection -ErrorAction SilentlyContinue) {
        try {
            $selectedHotbar = [int](Get-HotbarSelection)
        }
        catch {
            $selectedHotbar = [int]-1
        }
    }

    [int]$maxSlots = [Math]::Min($slotsData.Count, $script:InventoryUIGridColumns * $script:InventoryUIGridRows)
    $result = @()

    for ($i = 0; $i -lt $maxSlots; $i++) {
        [int]$row = [int][Math]::Floor($i / $script:InventoryUIGridColumns)
        [int]$col = [int]($i % $script:InventoryUIGridColumns)

        [float]$x = [float]($Layout.GridRect.X + ($col * ($Layout.SlotSize + $Layout.SlotGap)))
        [float]$y = [float]($Layout.GridRect.Y + ($row * ($Layout.SlotSize + $Layout.SlotGap)))

        $slotData = $slotsData[$i]
        [string]$itemName = ''
        [int]$count = [int]0

        if ($null -ne $slotData) {
            if ($null -ne $slotData.PSObject.Properties['ItemName']) { $itemName = [string]$slotData.ItemName }
            if ($null -ne $slotData.PSObject.Properties['Count']) { $count = [int]$slotData.Count }
        }

        if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) {
            $itemName = ''
            $count = [int]0
        }

        [bool]$isHotbar = ($i -lt $hotbarSize)
        [bool]$isSelected = ($isHotbar -and $i -eq $selectedHotbar)

        $result += [PSCustomObject]@{
            Index = [int]$i
            Row = [int]$row
            Column = [int]$col
            ItemName = [string]$itemName
            Count = [int]$count
            IsEmpty = [bool]([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0)
            IsHotbar = [bool]$isHotbar
            IsSelected = [bool]$isSelected
            Rect = (New-InventoryUIRect -X $x -Y $y -Width ([float]$Layout.SlotSize) -Height ([float]$Layout.SlotSize))
            Icon = (Get-InventoryUIItemIconDescriptor -ItemName $itemName -Count $count)
        }
    }

    return @($result)
}

function Get-InventoryUIEquipmentSlotsModel {
    param($Layout)

    $equipmentMap = Get-InventoryUIEquipmentMap
    $result = @()

    for ($i = 0; $i -lt $script:InventoryUIEquipmentSlotOrder.Count; $i++) {
        [int]$row = [int][Math]::Floor($i / 2)
        [int]$col = [int]($i % 2)

        [float]$x = [float]($Layout.EquipmentRect.X + ($col * ($Layout.EquipmentSlotSize + $Layout.SlotGap)))
        [float]$y = [float]($Layout.EquipmentRect.Y + ($row * ($Layout.EquipmentSlotSize + $Layout.SlotGap)))

        [string]$slotName = [string]$script:InventoryUIEquipmentSlotOrder[$i]
        [string]$itemName = ''
        if ($equipmentMap.ContainsKey($slotName)) {
            $itemName = [string]$equipmentMap[$slotName]
        }

        [int]$count = 0
        if (-not [string]::IsNullOrWhiteSpace($itemName)) {
            $count = 1
        }

        $result += [PSCustomObject]@{
            Index = [int]$i
            SlotName = [string]$slotName
            ItemName = [string]$itemName
            Count = [int]$count
            IsEmpty = [bool]([string]::IsNullOrWhiteSpace($itemName))
            Rect = (New-InventoryUIRect -X $x -Y $y -Width ([float]$Layout.EquipmentSlotSize) -Height ([float]$Layout.EquipmentSlotSize))
            Icon = (Get-InventoryUIItemIconDescriptor -ItemName $itemName -Count $count)
        }
    }

    return @($result)
}

function Get-InventoryUICraftingEntriesModel {
    param($Layout)

    $recipes = Get-InventoryUIAllRecipes
    [int]$visible = [Math]::Min($recipes.Count, [int]$Layout.CraftRowsVisible)
    $result = @()

    for ($i = 0; $i -lt $visible; $i++) {
        $recipe = $recipes[$i]
        [string]$recipeName = [string]$recipe.Name

        [bool]$canCraft = $false
        if (Get-Command -Name Test-CanCraft -ErrorAction SilentlyContinue) {
            try {
                $canCraft = [bool](Test-CanCraft -Name $recipeName -Count 1)
            }
            catch {
                $canCraft = $false
            }
        }

        [int]$maxCraftCount = 0
        if (Get-Command -Name Get-MaxCraftCount -ErrorAction SilentlyContinue) {
            try {
                $maxCraftCount = [int](Get-MaxCraftCount -Name $recipeName)
            }
            catch {
                $maxCraftCount = 0
            }
        }
        elseif ($canCraft) {
            $maxCraftCount = 1
        }

        [float]$x = [float]$Layout.CraftRect.X
        [float]$y = [float]($Layout.CraftRect.Y + ($i * ($Layout.CraftRowHeight + $Layout.SlotGap)))

        $ingredients = @()
        if ($null -ne $recipe.PSObject.Properties['Ingredients'] -and $null -ne $recipe.Ingredients) {
            $ingredients = Expand-InventoryUICollection -InputObject $recipe.Ingredients
        }

        [bool]$selected = ($i -eq $script:InventoryUICraftingSelection)

        $result += [PSCustomObject]@{
            Index = [int]$i
            RecipeName = [string]$recipeName
            ResultCount = [int]$recipe.ResultCount
            Ingredients = @($ingredients)
            CanCraft = [bool]$canCraft
            MaxCraftCount = [int]$maxCraftCount
            IsSelected = [bool]$selected
            Rect = (New-InventoryUIRect -X $x -Y $y -Width ([float]$Layout.CraftRect.Width) -Height ([float]$Layout.CraftRowHeight))
        }
    }

    return @($result)
}

function Get-InventoryUITooltipForHover {
    param(
        $HoverState,
        $ReadModel
    )

    if ($null -eq $HoverState) { return $null }

    [string]$kind = [string]$HoverState.Kind
    if ($kind -eq 'None') { return $null }

    [string]$title = ''
    $lines = @()
    [string]$tooltipKind = $kind
    $accent = New-InventoryUIColor -R 0.72 -G 0.80 -B 0.93 -A 0.96

    if ($kind -eq 'InventorySlot' -or $kind -eq 'EquipmentSlot') {
        [string]$itemName = [string]$HoverState.ItemName
        [int]$count = [int]$HoverState.Count
        if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) {
            return $null
        }

        $itemDef = $null
        if (Get-Command -Name Get-ItemDefinition -ErrorAction SilentlyContinue) {
            $itemDef = Get-ItemDefinition -Name $itemName
        }

        $icon = Get-InventoryUIItemIconDescriptor -ItemName $itemName -Count $count
        if ($null -ne $icon -and $null -ne $icon.PSObject.Properties['AccentColor']) {
            $accent = $icon.AccentColor
        }

        $title = [string]$itemName
        $lines += ('Count: {0}' -f $count)

        if ($null -ne $itemDef) {
            if ($null -ne $itemDef.PSObject.Properties['Type']) {
                $lines += ('Type: {0}' -f [string]$itemDef.Type)
            }
            if ($null -ne $itemDef.PSObject.Properties['Value']) {
                $lines += ('Value: {0}' -f [int]$itemDef.Value)
            }
            if ($null -ne $itemDef.PSObject.Properties['StackSize']) {
                $lines += ('Stack: {0}' -f [int]$itemDef.StackSize)
            }
        }

        if ($kind -eq 'EquipmentSlot') {
            $lines += ('Equipped: {0}' -f [string]$HoverState.SlotName)
        }
    }
    elseif ($kind -eq 'CraftingEntry') {
        [int]$idx = [int]$HoverState.Index
        if ($idx -lt 0 -or $idx -ge $ReadModel.Crafting.Entries.Count) {
            return $null
        }

        $entry = $ReadModel.Crafting.Entries[$idx]
        $title = [string]$entry.RecipeName
        $lines += ('Can Craft: {0}' -f [string]$entry.CanCraft)
        $lines += ('Max Craft: {0}' -f [int]$entry.MaxCraftCount)

        foreach ($ingredient in $entry.Ingredients) {
            if ($null -eq $ingredient) { continue }
            [string]$ingName = ''
            [int]$ingCount = 0
            if ($null -ne $ingredient.PSObject.Properties['ItemName']) { $ingName = [string]$ingredient.ItemName }
            if ($null -ne $ingredient.PSObject.Properties['Count']) { $ingCount = [int]$ingredient.Count }
            if (-not [string]::IsNullOrWhiteSpace($ingName)) {
                $lines += ('- {0} x{1}' -f $ingName, $ingCount)
            }
        }

        if ([bool]$entry.CanCraft) {
            $accent = New-InventoryUIColor -R 0.35 -G 0.86 -B 0.47 -A 0.95
        }
        else {
            $accent = New-InventoryUIColor -R 0.90 -G 0.34 -B 0.34 -A 0.95
        }
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        return $null
    }

    return [PSCustomObject]@{
        Kind = [string]$tooltipKind
        Title = [string]$title
        Lines = @($lines)
        AccentColor = $accent
    }
}

function Resolve-InventoryUIHoverState {
    param(
        $ReadModel,
        [float]$CursorX,
        [float]$CursorY
    )

    $hover = [PSCustomObject]@{
        Kind = 'None'
        Index = [int]-1
        SlotName = ''
        ItemName = ''
        Count = [int]0
        Tooltip = $null
        CursorX = [float]$CursorX
        CursorY = [float]$CursorY
    }

    if ($null -eq $ReadModel -or -not [bool]$ReadModel.IsOpen) {
        return $hover
    }

    foreach ($slot in $ReadModel.Grid.Slots) {
        if (Test-InventoryUIPointInRect -X $CursorX -Y $CursorY -Rect $slot.Rect) {
            $hover.Kind = 'InventorySlot'
            $hover.Index = [int]$slot.Index
            $hover.ItemName = [string]$slot.ItemName
            $hover.Count = [int]$slot.Count
            break
        }
    }

    if ($hover.Kind -eq 'None') {
        foreach ($slot in $ReadModel.Equipment.Slots) {
            if (Test-InventoryUIPointInRect -X $CursorX -Y $CursorY -Rect $slot.Rect) {
                $hover.Kind = 'EquipmentSlot'
                $hover.Index = [int]$slot.Index
                $hover.SlotName = [string]$slot.SlotName
                $hover.ItemName = [string]$slot.ItemName
                $hover.Count = [int]$slot.Count
                break
            }
        }
    }

    if ($hover.Kind -eq 'None') {
        foreach ($entry in $ReadModel.Crafting.Entries) {
            if (Test-InventoryUIPointInRect -X $CursorX -Y $CursorY -Rect $entry.Rect) {
                $hover.Kind = 'CraftingEntry'
                $hover.Index = [int]$entry.Index
                $hover.ItemName = [string]$entry.RecipeName
                $hover.Count = [int]$entry.ResultCount
                break
            }
        }
    }

    $hover.Tooltip = Get-InventoryUITooltipForHover -HoverState $hover -ReadModel $ReadModel
    return $hover
}

function Build-InventoryUIReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    $metrics = Get-InventoryUIHUDMetrics
    $layout = Get-InventoryUILayout -Scale ([float]$metrics.Scale) -WindowWidth ([float]$metrics.WindowWidth) -WindowHeight ([float]$metrics.WindowHeight)
    $gridSlots = Get-InventoryUIGridSlotsModel -Layout $layout
    $equipmentSlots = Get-InventoryUIEquipmentSlotsModel -Layout $layout
    $craftEntries = Get-InventoryUICraftingEntriesModel -Layout $layout

    if ($script:InventoryUICraftingSelection -ge $craftEntries.Count) {
        $script:InventoryUICraftingSelection = [int]-1
    }

    [string]$selectedRecipeName = ''
    if ($script:InventoryUICraftingSelection -ge 0 -and $script:InventoryUICraftingSelection -lt $craftEntries.Count) {
        $selectedRecipeName = [string]$craftEntries[$script:InventoryUICraftingSelection].RecipeName
    }

    return [PSCustomObject]@{
        Initialized = [bool]$script:InventoryUIInitialized
        IsOpen = [bool](Get-InventoryUIInventoryOpenState)
        UpdateRegistered = [bool]$script:InventoryUIUpdateRegistered
        RenderRegistered = [bool]$script:InventoryUIRenderRegistered
        Layout = [PSCustomObject]@{
            Scale = [float]$layout.Scale
            Panel = $layout.Panel
            GridRect = $layout.GridRect
            RightRect = $layout.RightRect
            EquipmentRect = $layout.EquipmentRect
            CraftRect = $layout.CraftRect
            SlotSize = [float]$layout.SlotSize
            SlotGap = [float]$layout.SlotGap
            CraftRowHeight = [float]$layout.CraftRowHeight
            CraftRowsVisible = [int]$layout.CraftRowsVisible
        }
        Grid = [PSCustomObject]@{
            Columns = [int]$script:InventoryUIGridColumns
            Rows = [int]$script:InventoryUIGridRows
            SlotCount = [int]$gridSlots.Count
            Slots = @($gridSlots)
        }
        Equipment = [PSCustomObject]@{
            SlotCount = [int]$equipmentSlots.Count
            Slots = @($equipmentSlots)
        }
        Crafting = [PSCustomObject]@{
            Entries = @($craftEntries)
            SelectedIndex = [int]$script:InventoryUICraftingSelection
            SelectedRecipeName = [string]$selectedRecipeName
            LastAttempt = $script:InventoryUICraftingLastAttempt
        }
        Hover = $script:InventoryUIHoverState
        DragDrop = $script:InventoryUIDragState
        Cursor = [PSCustomObject]@{
            X = [float]$CursorX
            Y = [float]$CursorY
        }
        LastRender = $script:InventoryUILastRender
    }
}

function Clear-InventoryUIDragPayload {
    $script:InventoryUIDragState.Phase = 'Idle'
    $script:InventoryUIDragState.SourceKind = 'None'
    $script:InventoryUIDragState.SourceIndex = [int]-1
    $script:InventoryUIDragState.SourceSlotName = ''
    $script:InventoryUIDragState.ItemName = ''
    $script:InventoryUIDragState.Count = [int]0
    $script:InventoryUIDragState.StartedAtUtc = [DateTime]::MinValue
}

function Try-InventoryUIBeginDrag {
    param($Hover)

    if ($null -eq $Hover) { return $false }
    if ([string]$Hover.Kind -eq 'None') { return $false }

    [string]$itemName = [string]$Hover.ItemName
    [int]$count = [int]$Hover.Count

    if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) {
        return $false
    }

    $script:InventoryUIDragState.Phase = 'Dragging'
    $script:InventoryUIDragState.SourceKind = [string]$Hover.Kind
    $script:InventoryUIDragState.SourceIndex = [int]$Hover.Index
    $script:InventoryUIDragState.SourceSlotName = [string]$Hover.SlotName
    $script:InventoryUIDragState.ItemName = [string]$itemName
    $script:InventoryUIDragState.Count = [int]$count
    $script:InventoryUIDragState.StartedAtUtc = [DateTime]::UtcNow

    return $true
}

function Move-InventoryUISlotToSlot {
    param(
        [int]$SourceIndex,
        [int]$TargetIndex
    )

    if ($SourceIndex -eq $TargetIndex) {
        return (New-InventoryUIDropResult -Success $true -Action 'NoOp' -Reason 'SameSlot' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
    }

    $slots = Get-InventoryUIInventorySlots
    if ($SourceIndex -lt 0 -or $SourceIndex -ge $slots.Count) {
        return (New-InventoryUIDropResult -Success $false -Action 'SwapInventorySlots' -Reason 'SourceOutOfRange' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
    }
    if ($TargetIndex -lt 0 -or $TargetIndex -ge $slots.Count) {
        return (New-InventoryUIDropResult -Success $false -Action 'SwapInventorySlots' -Reason 'TargetOutOfRange' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
    }

    $source = $slots[$SourceIndex]
    $target = $slots[$TargetIndex]

    [string]$tmpName = [string]$source.ItemName
    [int]$tmpCount = [int]$source.Count

    $source.ItemName = [string]$target.ItemName
    $source.Count = [int]$target.Count
    $target.ItemName = [string]$tmpName
    $target.Count = [int]$tmpCount

    return (New-InventoryUIDropResult -Success $true -Action 'SwapInventorySlots' -Reason 'Swapped' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
}

function Move-InventoryUIInventoryToEquipment {
    param(
        [int]$SourceIndex,
        [string]$TargetSlotName
    )

    if (-not (Get-Command -Name Equip-Item -ErrorAction SilentlyContinue)) {
        return (New-InventoryUIDropResult -Success $false -Action 'EquipItem' -Reason 'EquipCommandMissing' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    $slots = Get-InventoryUIInventorySlots
    if ($SourceIndex -lt 0 -or $SourceIndex -ge $slots.Count) {
        return (New-InventoryUIDropResult -Success $false -Action 'EquipItem' -Reason 'SourceOutOfRange' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    $source = $slots[$SourceIndex]
    [string]$itemName = [string]$source.ItemName
    [int]$count = [int]$source.Count

    if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) {
        return (New-InventoryUIDropResult -Success $false -Action 'EquipItem' -Reason 'SourceEmpty' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    $ok = $false
    try {
        $ok = [bool](Equip-Item -ItemName $itemName -Slot $TargetSlotName)
    }
    catch {
        $ok = $false
    }

    if ($ok) {
        return (New-InventoryUIDropResult -Success $true -Action 'EquipItem' -Reason 'Equipped' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    return (New-InventoryUIDropResult -Success $false -Action 'EquipItem' -Reason 'EquipFailed' -SourceKind 'InventorySlot' -SourceIndex $SourceIndex -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
}

function Move-InventoryUIEquipmentToInventory {
    param(
        [string]$SourceSlotName,
        [int]$TargetIndex
    )

    if (-not (Get-Command -Name Unequip-Item -ErrorAction SilentlyContinue)) {
        return (New-InventoryUIDropResult -Success $false -Action 'UnequipItem' -Reason 'UnequipCommandMissing' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
    }

    $ok = $false
    try {
        $ok = [bool](Unequip-Item -Slot $SourceSlotName)
    }
    catch {
        $ok = $false
    }

    if ($ok) {
        return (New-InventoryUIDropResult -Success $true -Action 'UnequipItem' -Reason 'UnequippedToInventory' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
    }

    return (New-InventoryUIDropResult -Success $false -Action 'UnequipItem' -Reason 'UnequipFailed' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'InventorySlot' -TargetIndex $TargetIndex)
}

function Move-InventoryUIEquipmentToEquipment {
    param(
        [string]$SourceSlotName,
        [string]$TargetSlotName
    )

    if ($SourceSlotName -eq $TargetSlotName) {
        return (New-InventoryUIDropResult -Success $true -Action 'NoOp' -Reason 'SameEquipmentSlot' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    if (-not (Get-Command -Name Get-EquippedItem -ErrorAction SilentlyContinue)) {
        return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'GetEquippedItemMissing' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }
    if (-not (Get-Command -Name Unequip-Item -ErrorAction SilentlyContinue)) {
        return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'UnequipCommandMissing' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }
    if (-not (Get-Command -Name Equip-Item -ErrorAction SilentlyContinue)) {
        return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'EquipCommandMissing' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    [string]$itemName = [string](Get-EquippedItem -Slot $SourceSlotName)
    if ([string]::IsNullOrWhiteSpace($itemName)) {
        return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'SourceEmpty' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    [bool]$unequipped = [bool](Unequip-Item -Slot $SourceSlotName)
    if (-not $unequipped) {
        return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'UnequipFailed' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    [bool]$equipped = [bool](Equip-Item -ItemName $itemName -Slot $TargetSlotName)
    if ($equipped) {
        return (New-InventoryUIDropResult -Success $true -Action 'MoveEquipmentItem' -Reason 'Moved' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
    }

    # Best effort rollback
    [void](Equip-Item -ItemName $itemName -Slot $SourceSlotName)
    return (New-InventoryUIDropResult -Success $false -Action 'MoveEquipmentItem' -Reason 'EquipTargetFailedRollbackApplied' -SourceKind 'EquipmentSlot' -SourceSlotName $SourceSlotName -TargetKind 'EquipmentSlot' -TargetSlotName $TargetSlotName)
}

function Invoke-InventoryUIDropInternal {
    param($TargetHover)

    if ([string]$script:InventoryUIDragState.Phase -ne 'Dragging') {
        return (New-InventoryUIDropResult -Success $false -Action 'Drop' -Reason 'NotDragging')
    }

    [string]$sourceKind = [string]$script:InventoryUIDragState.SourceKind
    [int]$sourceIndex = [int]$script:InventoryUIDragState.SourceIndex
    [string]$sourceSlotName = [string]$script:InventoryUIDragState.SourceSlotName

    if ($null -eq $TargetHover -or [string]$TargetHover.Kind -eq 'None') {
        return (New-InventoryUIDropResult -Success $false -Action 'Drop' -Reason 'NoTarget' -SourceKind $sourceKind -SourceIndex $sourceIndex -SourceSlotName $sourceSlotName)
    }

    [string]$targetKind = [string]$TargetHover.Kind
    [int]$targetIndex = [int]$TargetHover.Index
    [string]$targetSlotName = [string]$TargetHover.SlotName

    if ($sourceKind -eq 'InventorySlot' -and $targetKind -eq 'InventorySlot') {
        return (Move-InventoryUISlotToSlot -SourceIndex $sourceIndex -TargetIndex $targetIndex)
    }

    if ($sourceKind -eq 'InventorySlot' -and $targetKind -eq 'EquipmentSlot') {
        return (Move-InventoryUIInventoryToEquipment -SourceIndex $sourceIndex -TargetSlotName $targetSlotName)
    }

    if ($sourceKind -eq 'EquipmentSlot' -and $targetKind -eq 'InventorySlot') {
        return (Move-InventoryUIEquipmentToInventory -SourceSlotName $sourceSlotName -TargetIndex $targetIndex)
    }

    if ($sourceKind -eq 'EquipmentSlot' -and $targetKind -eq 'EquipmentSlot') {
        return (Move-InventoryUIEquipmentToEquipment -SourceSlotName $sourceSlotName -TargetSlotName $targetSlotName)
    }

    return (New-InventoryUIDropResult -Success $false -Action 'Drop' -Reason 'UnsupportedDropRoute' -SourceKind $sourceKind -SourceIndex $sourceIndex -SourceSlotName $sourceSlotName -TargetKind $targetKind -TargetIndex $targetIndex -TargetSlotName $targetSlotName)
}

function Draw-InventoryUIIcon {
    param(
        $Icon,
        $Rect,
        [float]$Z
    )

    if ($null -eq $Icon -or $null -eq $Rect) {
        return [int]0
    }

    [int]$draws = 0

    [float]$pad = [float][Math]::Max(2.0, $Rect.Width * 0.14)
    [float]$iconX = [float]($Rect.X + $pad)
    [float]$iconY = [float]($Rect.Y + $pad)
    [float]$iconW = [float][Math]::Max(4.0, $Rect.Width - ($pad * 2.0))
    [float]$iconH = [float][Math]::Max(4.0, $Rect.Height - ($pad * 2.0))

    Draw-HUDRect -X $iconX -Y $iconY -Width $iconW -Height $iconH -Z $Z -R ([float]$Icon.BaseColor.R) -G ([float]$Icon.BaseColor.G) -B ([float]$Icon.BaseColor.B) -A ([float]$Icon.BaseColor.A)
    $draws++

    [float]$cellW = [float]($iconW / 3.0)
    [float]$cellH = [float]($iconH / 3.0)

    foreach ($cell in $Icon.Cells) {
        if ($null -eq $cell) { continue }

        [float]$cx = [float]($iconX + ([int]$cell.X * $cellW) + ($cellW * 0.16))
        [float]$cy = [float]($iconY + ([int]$cell.Y * $cellH) + ($cellH * 0.16))
        [float]$cw = [float][Math]::Max(1.0, $cellW * 0.68)
        [float]$ch = [float][Math]::Max(1.0, $cellH * 0.68)

        Draw-HUDRect -X $cx -Y $cy -Width $cw -Height $ch -Z ($Z - 0.0001) -R ([float]$Icon.AccentColor.R) -G ([float]$Icon.AccentColor.G) -B ([float]$Icon.AccentColor.B) -A ([float]$Icon.AccentColor.A)
        $draws++
    }

    [float]$meterH = [float][Math]::Max(1.0, $Rect.Height * 0.10)
    [float]$meterW = [float][Math]::Max(2.0, $iconW * [float]$Icon.CountRatio)
    [float]$meterY = [float]($Rect.Y + $Rect.Height - $meterH - 1.0)

    Draw-HUDRect -X $iconX -Y $meterY -Width $iconW -Height $meterH -Z ($Z - 0.0002) -R 0.02 -G 0.02 -B 0.03 -A 0.72
    $draws++

    Draw-HUDRect -X $iconX -Y $meterY -Width $meterW -Height $meterH -Z ($Z - 0.0003) -R ([float]$Icon.AccentColor.R) -G ([float]$Icon.AccentColor.G) -B ([float]$Icon.AccentColor.B) -A 0.92
    $draws++

    return [int]$draws
}

function Draw-InventoryUITooltip {
    param(
        $Tooltip,
        [float]$CursorX,
        [float]$CursorY,
        [float]$WindowWidth,
        [float]$WindowHeight,
        [float]$Scale,
        [float]$Z
    )

    if ($null -eq $Tooltip) {
        return [int]0
    }

    [int]$lineCount = [int]$Tooltip.Lines.Count
    [float]$tooltipW = [float][Math]::Max(150.0 * $Scale, 220.0 * $Scale)
    [float]$tooltipH = [float]([Math]::Max(46.0 * $Scale, (26.0 * $Scale) + ($lineCount * 14.0 * $Scale)))
    [float]$offset = [float][Math]::Max(8.0, 14.0 * $Scale)

    [float]$x = [float]($CursorX + $offset)
    [float]$y = [float]($CursorY + $offset)

    if (($x + $tooltipW) -gt $WindowWidth) {
        $x = [float]($CursorX - $tooltipW - $offset)
    }
    if (($y + $tooltipH) -gt $WindowHeight) {
        $y = [float]($WindowHeight - $tooltipH - $offset)
    }
    if ($x -lt 0.0) { $x = [float]0.0 }
    if ($y -lt 0.0) { $y = [float]0.0 }

    [int]$draws = 0
    Draw-HUDRect -X $x -Y $y -Width $tooltipW -Height $tooltipH -Z $Z -R ([float]$script:InventoryUITheme.TooltipPanel.R) -G ([float]$script:InventoryUITheme.TooltipPanel.G) -B ([float]$script:InventoryUITheme.TooltipPanel.B) -A ([float]$script:InventoryUITheme.TooltipPanel.A)
    $draws++

    [float]$b = [float][Math]::Max(1.0, [Math]::Round($Scale))
    Draw-HUDRect -X $x -Y $y -Width $tooltipW -Height $b -Z ($Z - 0.0001) -R ([float]$script:InventoryUITheme.TooltipBorder.R) -G ([float]$script:InventoryUITheme.TooltipBorder.G) -B ([float]$script:InventoryUITheme.TooltipBorder.B) -A ([float]$script:InventoryUITheme.TooltipBorder.A)
    $draws++
    Draw-HUDRect -X $x -Y ($y + $tooltipH - $b) -Width $tooltipW -Height $b -Z ($Z - 0.0001) -R ([float]$script:InventoryUITheme.TooltipBorder.R) -G ([float]$script:InventoryUITheme.TooltipBorder.G) -B ([float]$script:InventoryUITheme.TooltipBorder.B) -A ([float]$script:InventoryUITheme.TooltipBorder.A)
    $draws++
    Draw-HUDRect -X $x -Y $y -Width $b -Height $tooltipH -Z ($Z - 0.0001) -R ([float]$script:InventoryUITheme.TooltipBorder.R) -G ([float]$script:InventoryUITheme.TooltipBorder.G) -B ([float]$script:InventoryUITheme.TooltipBorder.B) -A ([float]$script:InventoryUITheme.TooltipBorder.A)
    $draws++
    Draw-HUDRect -X ($x + $tooltipW - $b) -Y $y -Width $b -Height $tooltipH -Z ($Z - 0.0001) -R ([float]$script:InventoryUITheme.TooltipBorder.R) -G ([float]$script:InventoryUITheme.TooltipBorder.G) -B ([float]$script:InventoryUITheme.TooltipBorder.B) -A ([float]$script:InventoryUITheme.TooltipBorder.A)
    $draws++

    Draw-HUDRect -X ($x + $b) -Y ($y + $b) -Width ([float]($tooltipW - ($b * 2.0))) -Height ([float][Math]::Max(2.0, 8.0 * $Scale)) -Z ($Z - 0.0002) -R ([float]$Tooltip.AccentColor.R) -G ([float]$Tooltip.AccentColor.G) -B ([float]$Tooltip.AccentColor.B) -A 0.95
    $draws++

    for ($i = 0; $i -lt $Tooltip.Lines.Count; $i++) {
        [float]$lineY = [float]($y + (16.0 * $Scale) + ($i * 12.0 * $Scale))
        [float]$lineW = [float][Math]::Max(6.0, ($tooltipW - (12.0 * $Scale)) * (0.55 + (0.42 * ((($i + 1) % 5) / 5.0))))
        Draw-HUDRect -X ([float]($x + (6.0 * $Scale))) -Y $lineY -Width $lineW -Height ([float][Math]::Max(1.0, 3.0 * $Scale)) -Z ($Z - 0.0003) -R ([float]$Tooltip.AccentColor.R) -G ([float]$Tooltip.AccentColor.G) -B ([float]$Tooltip.AccentColor.B) -A 0.58
        $draws++
    }

    return [int]$draws
}

function Draw-InventoryUIDragGhost {
    param(
        [float]$CursorX,
        [float]$CursorY,
        [float]$Scale,
        [float]$Z
    )

    if ([string]$script:InventoryUIDragState.Phase -ne 'Dragging') {
        return [int]0
    }

    [string]$itemName = [string]$script:InventoryUIDragState.ItemName
    [int]$count = [int]$script:InventoryUIDragState.Count
    if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) {
        return [int]0
    }

    $icon = Get-InventoryUIItemIconDescriptor -ItemName $itemName -Count $count
    if ($null -eq $icon) {
        return [int]0
    }

    [float]$size = [float][Math]::Max(20.0, 44.0 * $Scale)
    [float]$x = [float]($CursorX - ($size * 0.42))
    [float]$y = [float]($CursorY - ($size * 0.42))
    $rect = New-InventoryUIRect -X $x -Y $y -Width $size -Height $size

    Draw-HUDRect -X $x -Y $y -Width $size -Height $size -Z $Z -R 0.05 -G 0.07 -B 0.10 -A 0.78
    [int]$draws = 1
    $draws += Draw-InventoryUIIcon -Icon $icon -Rect $rect -Z ($Z - 0.0001)

    return [int]$draws
}

function Refresh-InventoryUIReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    $script:InventoryUIReadModel = Build-InventoryUIReadModel -CursorX $CursorX -CursorY $CursorY
    $script:InventoryUIHoverState = Resolve-InventoryUIHoverState -ReadModel $script:InventoryUIReadModel -CursorX $CursorX -CursorY $CursorY
    $script:InventoryUIReadModel.Hover = $script:InventoryUIHoverState
    $script:InventoryUIReadModel.DragDrop = $script:InventoryUIDragState
    $script:InventoryUIReadModel.Crafting.LastAttempt = $script:InventoryUICraftingLastAttempt
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-InventoryUI {
    <#
    .SYNOPSIS
        Initializes inventory UI state and callback registration.
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

    $script:InventoryUIHoverState = [PSCustomObject]@{
        Kind = 'None'
        Index = [int]-1
        SlotName = ''
        ItemName = ''
        Count = [int]0
        Tooltip = $null
        CursorX = [float]0.0
        CursorY = [float]0.0
    }

    $script:InventoryUIDragState = [PSCustomObject]@{
        Phase = 'Idle'
        SourceKind = 'None'
        SourceIndex = [int]-1
        SourceSlotName = ''
        ItemName = ''
        Count = [int]0
        StartedAtUtc = [DateTime]::MinValue
        LastDropResult = New-InventoryUIDropResult -Success $false -Action 'None' -Reason 'NotAttempted'
    }

    $script:InventoryUILeftMouseWasHeld = $false
    $script:InventoryUICraftingSelection = [int]-1
    $script:InventoryUICraftingLastAttempt = [PSCustomObject]@{
        Success = $false
        RecipeName = ''
        Count = [int]0
        Reason = 'NotAttempted'
        TimestampUtc = [DateTime]::MinValue
    }

    $script:InventoryUIInitialized = $true

    if (-not $script:InventoryUIUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-InventoryUI}
            $script:InventoryUIUpdateRegistered = $true
            Write-Host '[InventoryUI] Update callback registered.' -ForegroundColor DarkGray
        }
    }

    if (-not $script:InventoryUIRenderRegistered) {
        if (Get-Command -Name Register-RenderCallback -ErrorAction SilentlyContinue) {
            Register-RenderCallback ${function:Render-InventoryUI}
            $script:InventoryUIRenderRegistered = $true
            Write-Host '[InventoryUI] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    $mouse = Get-InventoryUIMousePositionInternal
    Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    $script:InventoryUILastRender = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
        DrawCallEstimate = [int]0
        TooltipVisible = $false
        DragVisualVisible = $false
    }

    Write-Host '[InventoryUI] Inventory UI initialized.' -ForegroundColor Green
}

function Set-InventoryUICraftingSelection {
    <#
    .SYNOPSIS
        Sets the selected crafting entry index.
    #>
    param([int]$Index)

    if (-not $script:InventoryUIInitialized) {
        Initialize-InventoryUI
    }

    if ($null -eq $script:InventoryUIReadModel) {
        $mouse = Get-InventoryUIMousePositionInternal
        Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)
    }

    if ($Index -lt 0 -or $Index -ge $script:InventoryUIReadModel.Crafting.Entries.Count) {
        $script:InventoryUICraftingSelection = [int]-1
        return $null
    }

    $script:InventoryUICraftingSelection = [int]$Index
    $mouse = Get-InventoryUIMousePositionInternal
    Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    return $script:InventoryUIReadModel.Crafting.Entries[$Index]
}

function Invoke-InventoryUICraftSelection {
    <#
    .SYNOPSIS
        Attempts to craft the currently selected recipe.
    #>
    param([int]$Count = 1)

    if (-not $script:InventoryUIInitialized) {
        Initialize-InventoryUI
    }

    if ($Count -le 0) {
        $Count = 1
    }

    if ($null -eq $script:InventoryUIReadModel) {
        $mouse = Get-InventoryUIMousePositionInternal
        Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)
    }

    if ($script:InventoryUICraftingSelection -lt 0 -or $script:InventoryUICraftingSelection -ge $script:InventoryUIReadModel.Crafting.Entries.Count) {
        $script:InventoryUICraftingLastAttempt = [PSCustomObject]@{
            Success = $false
            RecipeName = ''
            Count = [int]$Count
            Reason = 'NoSelection'
            TimestampUtc = [DateTime]::UtcNow
        }
        return $script:InventoryUICraftingLastAttempt
    }

    if (-not (Get-Command -Name Invoke-Craft -ErrorAction SilentlyContinue)) {
        $script:InventoryUICraftingLastAttempt = [PSCustomObject]@{
            Success = $false
            RecipeName = [string]$script:InventoryUIReadModel.Crafting.Entries[$script:InventoryUICraftingSelection].RecipeName
            Count = [int]$Count
            Reason = 'InvokeCraftMissing'
            TimestampUtc = [DateTime]::UtcNow
        }
        return $script:InventoryUICraftingLastAttempt
    }

    [string]$recipeName = [string]$script:InventoryUIReadModel.Crafting.Entries[$script:InventoryUICraftingSelection].RecipeName
    [bool]$ok = $false
    try {
        $ok = [bool](Invoke-Craft -Name $recipeName -Count $Count)
    }
    catch {
        $ok = $false
    }

    [string]$attemptReason = 'CraftFailed'
    if ($ok) {
        $attemptReason = 'Crafted'
    }

    $script:InventoryUICraftingLastAttempt = [PSCustomObject]@{
        Success = [bool]$ok
        RecipeName = [string]$recipeName
        Count = [int]$Count
        Reason = [string]$attemptReason
        TimestampUtc = [DateTime]::UtcNow
    }

    $mouse = Get-InventoryUIMousePositionInternal
    Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    return $script:InventoryUICraftingLastAttempt
}

function Update-InventoryUI {
    <#
    .SYNOPSIS
        Per-frame inventory UI update, hover, drag-drop, and crafting interactions.
    #>
    param($dt)

    if (-not $script:InventoryUIInitialized) {
        return
    }

    [float]$step = [float]0.0
    if ($null -ne $dt) {
        $step = [float]$dt
    }
    if ($step -lt 0.0) { $step = [float]0.0 }
    if ($step -gt 0.1) { $step = [float]0.1 }

    $mouse = Get-InventoryUIMousePositionInternal
    [float]$cursorX = [float]$mouse.X
    [float]$cursorY = [float]$mouse.Y

    Refresh-InventoryUIReadModel -CursorX $cursorX -CursorY $cursorY

    [bool]$isOpen = [bool]$script:InventoryUIReadModel.IsOpen
    [bool]$leftHeld = Get-InventoryUIMouseButtonHeldInternal -Button 0
    [bool]$leftDown = Get-InventoryUIMouseButtonDownInternal -Button 0
    if (-not $leftDown -and $leftHeld -and -not $script:InventoryUILeftMouseWasHeld) {
        $leftDown = $true
    }

    if (-not $isOpen) {
        $script:InventoryUIHoverState = [PSCustomObject]@{
            Kind = 'None'
            Index = [int]-1
            SlotName = ''
            ItemName = ''
            Count = [int]0
            Tooltip = $null
            CursorX = [float]$cursorX
            CursorY = [float]$cursorY
        }
        Clear-InventoryUIDragPayload
        $script:InventoryUILeftMouseWasHeld = [bool]$leftHeld
        Refresh-InventoryUIReadModel -CursorX $cursorX -CursorY $cursorY
        return
    }

    if ([string]$script:InventoryUIDragState.Phase -eq 'Dragging') {
        if (-not $leftHeld -and $script:InventoryUILeftMouseWasHeld) {
            $dropResult = Invoke-InventoryUIDropInternal -TargetHover $script:InventoryUIHoverState
            $script:InventoryUIDragState.LastDropResult = $dropResult
            Clear-InventoryUIDragPayload
        }
    }
    else {
        if ($leftDown) {
            if ([string]$script:InventoryUIHoverState.Kind -eq 'CraftingEntry') {
                if ($script:InventoryUICraftingSelection -eq [int]$script:InventoryUIHoverState.Index) {
                    Invoke-InventoryUICraftSelection -Count 1 | Out-Null
                }
                else {
                    Set-InventoryUICraftingSelection -Index ([int]$script:InventoryUIHoverState.Index) | Out-Null
                }
            }
            else {
                [void](Try-InventoryUIBeginDrag -Hover $script:InventoryUIHoverState)
            }
        }
    }

    $script:InventoryUILeftMouseWasHeld = [bool]$leftHeld
    Refresh-InventoryUIReadModel -CursorX $cursorX -CursorY $cursorY
}

function Render-InventoryUI {
    <#
    .SYNOPSIS
        Draws inventory UI overlay using HUD rectangle primitives.
    #>
    param($dt)

    if (-not $script:InventoryUIInitialized) {
        $script:InventoryUILastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
            DrawCallEstimate = [int]0
            TooltipVisible = $false
            DragVisualVisible = $false
        }
        return
    }

    if (-not (Get-Command -Name Draw-HUDRect -ErrorAction SilentlyContinue)) {
        $script:InventoryUILastRender = [PSCustomObject]@{
            Mode = 'HeadlessNoDrawAPI'
            Rendered = $false
            Reason = 'DrawHUDRectMissing'
            DrawCallEstimate = [int]0
            TooltipVisible = $false
            DragVisualVisible = $false
        }
        return
    }

    $mouse = Get-InventoryUIMousePositionInternal
    Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    if (-not [bool]$script:InventoryUIReadModel.IsOpen) {
        $script:InventoryUILastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'InventoryClosed'
            DrawCallEstimate = [int]0
            TooltipVisible = $false
            DragVisualVisible = $false
        }
        return
    }

    [float]$scale = [float]$script:InventoryUIReadModel.Layout.Scale
    [float]$panelX = [float]$script:InventoryUIReadModel.Layout.Panel.X
    [float]$panelY = [float]$script:InventoryUIReadModel.Layout.Panel.Y
    [float]$panelW = [float]$script:InventoryUIReadModel.Layout.Panel.Width
    [float]$panelH = [float]$script:InventoryUIReadModel.Layout.Panel.Height
    [float]$z = [float]-0.93
    [float]$border = [float][Math]::Max(1.0, [Math]::Round($scale))

    [int]$drawCount = 0

    Draw-HUDRect -X $panelX -Y $panelY -Width $panelW -Height $panelH -Z $z -R ([float]$script:InventoryUITheme.Panel.R) -G ([float]$script:InventoryUITheme.Panel.G) -B ([float]$script:InventoryUITheme.Panel.B) -A ([float]$script:InventoryUITheme.Panel.A)
    $drawCount++

    Draw-HUDRect -X $panelX -Y $panelY -Width $panelW -Height $border -Z ($z - 0.0001) -R ([float]$script:InventoryUITheme.PanelBorder.R) -G ([float]$script:InventoryUITheme.PanelBorder.G) -B ([float]$script:InventoryUITheme.PanelBorder.B) -A ([float]$script:InventoryUITheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X $panelX -Y ($panelY + $panelH - $border) -Width $panelW -Height $border -Z ($z - 0.0001) -R ([float]$script:InventoryUITheme.PanelBorder.R) -G ([float]$script:InventoryUITheme.PanelBorder.G) -B ([float]$script:InventoryUITheme.PanelBorder.B) -A ([float]$script:InventoryUITheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X $panelX -Y $panelY -Width $border -Height $panelH -Z ($z - 0.0001) -R ([float]$script:InventoryUITheme.PanelBorder.R) -G ([float]$script:InventoryUITheme.PanelBorder.G) -B ([float]$script:InventoryUITheme.PanelBorder.B) -A ([float]$script:InventoryUITheme.PanelBorder.A)
    $drawCount++
    Draw-HUDRect -X ($panelX + $panelW - $border) -Y $panelY -Width $border -Height $panelH -Z ($z - 0.0001) -R ([float]$script:InventoryUITheme.PanelBorder.R) -G ([float]$script:InventoryUITheme.PanelBorder.G) -B ([float]$script:InventoryUITheme.PanelBorder.B) -A ([float]$script:InventoryUITheme.PanelBorder.A)
    $drawCount++

    Draw-HUDRect -X ([float]$script:InventoryUIReadModel.Layout.GridRect.X - (4.0 * $scale)) -Y ([float]$script:InventoryUIReadModel.Layout.GridRect.Y - (4.0 * $scale)) -Width ([float]$script:InventoryUIReadModel.Layout.GridRect.Width + (8.0 * $scale)) -Height ([float]$script:InventoryUIReadModel.Layout.GridRect.Height + (8.0 * $scale)) -Z ($z - 0.0002) -R ([float]$script:InventoryUITheme.Section.R) -G ([float]$script:InventoryUITheme.Section.G) -B ([float]$script:InventoryUITheme.Section.B) -A ([float]$script:InventoryUITheme.Section.A)
    $drawCount++

    Draw-HUDRect -X ([float]$script:InventoryUIReadModel.Layout.RightRect.X - (4.0 * $scale)) -Y ([float]$script:InventoryUIReadModel.Layout.RightRect.Y - (4.0 * $scale)) -Width ([float]$script:InventoryUIReadModel.Layout.RightRect.Width + (8.0 * $scale)) -Height ([float]$script:InventoryUIReadModel.Layout.RightRect.Height + (8.0 * $scale)) -Z ($z - 0.0002) -R ([float]$script:InventoryUITheme.Section.R) -G ([float]$script:InventoryUITheme.Section.G) -B ([float]$script:InventoryUITheme.Section.B) -A ([float]$script:InventoryUITheme.Section.A)
    $drawCount++

    foreach ($slot in $script:InventoryUIReadModel.Grid.Slots) {
        if ($null -eq $slot) { continue }

        $slotColor = $script:InventoryUITheme.SlotEmpty
        if (-not [bool]$slot.IsEmpty) {
            $slotColor = $script:InventoryUITheme.SlotFilled
        }
        if ([bool]$slot.IsSelected) {
            $slotColor = $script:InventoryUITheme.SlotSelected
        }
        if ([string]$script:InventoryUIHoverState.Kind -eq 'InventorySlot' -and [int]$script:InventoryUIHoverState.Index -eq [int]$slot.Index) {
            $slotColor = $script:InventoryUITheme.SlotHover
        }

        Draw-HUDRect -X ([float]$slot.Rect.X) -Y ([float]$slot.Rect.Y) -Width ([float]$slot.Rect.Width) -Height ([float]$slot.Rect.Height) -Z ($z - 0.0003) -R ([float]$slotColor.R) -G ([float]$slotColor.G) -B ([float]$slotColor.B) -A ([float]$slotColor.A)
        $drawCount++

        if ($null -ne $slot.Icon) {
            $drawCount += Draw-InventoryUIIcon -Icon $slot.Icon -Rect $slot.Rect -Z ($z - 0.0004)
        }
    }

    foreach ($slot in $script:InventoryUIReadModel.Equipment.Slots) {
        if ($null -eq $slot) { continue }

        $slotColor = $script:InventoryUITheme.SlotEmpty
        if (-not [bool]$slot.IsEmpty) {
            $slotColor = $script:InventoryUITheme.SlotFilled
        }
        if ([string]$script:InventoryUIHoverState.Kind -eq 'EquipmentSlot' -and [int]$script:InventoryUIHoverState.Index -eq [int]$slot.Index) {
            $slotColor = $script:InventoryUITheme.SlotHover
        }

        Draw-HUDRect -X ([float]$slot.Rect.X) -Y ([float]$slot.Rect.Y) -Width ([float]$slot.Rect.Width) -Height ([float]$slot.Rect.Height) -Z ($z - 0.0003) -R ([float]$slotColor.R) -G ([float]$slotColor.G) -B ([float]$slotColor.B) -A ([float]$slotColor.A)
        $drawCount++

        if ($null -ne $slot.Icon) {
            $drawCount += Draw-InventoryUIIcon -Icon $slot.Icon -Rect $slot.Rect -Z ($z - 0.0004)
        }
    }

    foreach ($entry in $script:InventoryUIReadModel.Crafting.Entries) {
        if ($null -eq $entry) { continue }

        $rowColor = $script:InventoryUITheme.CraftBlocked
        if ([bool]$entry.CanCraft) {
            $rowColor = $script:InventoryUITheme.CraftReady
        }

        [float]$alpha = [float]0.36
        if ([bool]$entry.IsSelected) { $alpha = [float]0.78 }
        if ([string]$script:InventoryUIHoverState.Kind -eq 'CraftingEntry' -and [int]$script:InventoryUIHoverState.Index -eq [int]$entry.Index) {
            $alpha = [float]0.88
        }

        Draw-HUDRect -X ([float]$entry.Rect.X) -Y ([float]$entry.Rect.Y) -Width ([float]$entry.Rect.Width) -Height ([float]$entry.Rect.Height) -Z ($z - 0.00035) -R ([float]$rowColor.R) -G ([float]$rowColor.G) -B ([float]$rowColor.B) -A $alpha
        $drawCount++

        [float]$chipW = [float][Math]::Max(3.0, ([float]$entry.Rect.Width - 4.0) * [float](Clamp-InventoryUI01 -Value (([double][Math]::Min(10, [int]$entry.MaxCraftCount)) / 10.0)))
        Draw-HUDRect -X ([float]($entry.Rect.X + 2.0)) -Y ([float]($entry.Rect.Y + $entry.Rect.Height - [Math]::Max(1.0, 3.0 * $scale))) -Width $chipW -Height ([float][Math]::Max(1.0, 3.0 * $scale)) -Z ($z - 0.00036) -R 0.95 -G 0.95 -B 0.97 -A 0.76
        $drawCount++
    }

    [bool]$tooltipVisible = $false
    if ($null -ne $script:InventoryUIHoverState.Tooltip) {
        $drawCount += Draw-InventoryUITooltip -Tooltip $script:InventoryUIHoverState.Tooltip -CursorX ([float]$script:InventoryUIHoverState.CursorX) -CursorY ([float]$script:InventoryUIHoverState.CursorY) -WindowWidth ([float]$script:InventoryUIReadModel.Layout.Panel.Width + $script:InventoryUIReadModel.Layout.Panel.X * 2.0) -WindowHeight ([float]$script:InventoryUIReadModel.Layout.Panel.Height + $script:InventoryUIReadModel.Layout.Panel.Y * 2.0) -Scale $scale -Z ($z - 0.0006)
        $tooltipVisible = $true
    }

    [int]$dragDraws = Draw-InventoryUIDragGhost -CursorX ([float]$script:InventoryUIReadModel.Cursor.X) -CursorY ([float]$script:InventoryUIReadModel.Cursor.Y) -Scale $scale -Z ($z - 0.0007)
    $drawCount += $dragDraws

    [bool]$dragVisible = ($dragDraws -gt 0)

    $script:InventoryUILastRender = [PSCustomObject]@{
        Mode = 'HUDOverlay'
        Rendered = $true
        Reason = 'Rendered'
        DrawCallEstimate = [int]$drawCount
        TooltipVisible = [bool]$tooltipVisible
        DragVisualVisible = [bool]$dragVisible
    }

    $script:InventoryUIReadModel.LastRender = $script:InventoryUILastRender
}

function Get-InventoryUIState {
    <#
    .SYNOPSIS
        Returns deterministic inventory UI state for verification and downstream UI.
    #>

    if (-not $script:InventoryUIInitialized) {
        return [PSCustomObject]@{
            Initialized = $false
            UpdateRegistered = [bool]$script:InventoryUIUpdateRegistered
            RenderRegistered = [bool]$script:InventoryUIRenderRegistered
            IsOpen = $false
            Grid = [PSCustomObject]@{ Columns = [int]$script:InventoryUIGridColumns; Rows = [int]$script:InventoryUIGridRows; SlotCount = [int]0; Slots = @() }
            Equipment = [PSCustomObject]@{ SlotCount = [int]0; Slots = @() }
            Crafting = [PSCustomObject]@{ Entries = @(); SelectedIndex = [int]-1; SelectedRecipeName = ''; LastAttempt = $script:InventoryUICraftingLastAttempt }
            Hover = $script:InventoryUIHoverState
            DragDrop = $script:InventoryUIDragState
            LastRender = $script:InventoryUILastRender
        }
    }

    $mouse = Get-InventoryUIMousePositionInternal
    Refresh-InventoryUIReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y)

    return $script:InventoryUIReadModel
}

function Get-InventoryUITooltipState {
    <#
    .SYNOPSIS
        Returns current hover tooltip model for inventory surface integration.
    #>

    $state = Get-InventoryUIState
    return $state.Hover.Tooltip
}

function Get-InventoryUIDragDropState {
    <#
    .SYNOPSIS
        Returns current drag and drop state machine snapshot.
    #>

    $state = Get-InventoryUIState
    return $state.DragDrop
}

function Get-InventoryUICraftingSurface {
    <#
    .SYNOPSIS
        Returns crafting entries and selection model for crafting UI integration.
    #>

    $state = Get-InventoryUIState
    return $state.Crafting
}
