# ============================================================================
# UI/Minimap.ps1 - Chunk-Based Minimap Overlay
# ============================================================================
# Deterministic minimap overlay module.
#
# Provides:
# - Top-down chunk-grid world view centered around player chunk
# - Player position indicator inside center chunk cell
# - POI markers for NPCs and active quest objectives
# - Quest POI resolution via NPC ids/names and quest giver/location metadata
# - Discrete minimap zoom options (increment/decrement + set API)
# - Headless-safe render metadata
#
# Optional dependencies:
# - UI/HUD.ps1: Draw-HUDRect, Get-HUDState, Initialize-HUD
# - Engine/OpenGL.ps1: Register-UpdateCallback, Register-RenderCallback
# - Game/Player.ps1: Get-PlayerPosition
# - Game/NPC.ps1: Get-NPCs
# - Game/Quest.ps1: Get-ActiveQuests
# - Data/Quests.ps1: Get-QuestDefinition, Get-QuestGiver
# ============================================================================

# --- Module State ---
$script:MinimapInitialized = $false
$script:MinimapUpdateRegistered = $false
$script:MinimapRenderRegistered = $false
$script:MinimapCmdCache = @{}

$script:MinimapReadModel = $null
$script:MinimapLastPlayerChunkX = [int]0
$script:MinimapLastPlayerChunkZ = [int]0
$script:MinimapDirty = $true
$script:MinimapFrameCounter = [int]0
$script:MinimapRefreshInterval = [int]10  # Rebuild every N frames when not dirty

$script:MinimapChunkSize = [float]16.0
$script:MinimapBaseChunkPixels = [float]24.0
$script:MinimapMaxChunkRadius = [int]6
$script:MinimapPanelSize = [float]286.0
$script:MinimapPanelMargin = [float]18.0

$script:MinimapZoomLevels = @([float]0.75, [float]1.0, [float]1.4, [float]1.9)
$script:MinimapZoomIndex = [int]1

$script:MinimapLastRender = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
    DrawCallEstimate = [int]0
    ChunkCellsDrawn = [int]0
    NPCMarkersDrawn = [int]0
    QuestMarkersDrawn = [int]0
    ZoomLevel = [float]1.0
}

$script:MinimapTheme = [PSCustomObject]@{
    Panel = [PSCustomObject]@{ R = [float]0.03; G = [float]0.07; B = [float]0.09; A = [float]0.82 }
    PanelBorder = [PSCustomObject]@{ R = [float]0.56; G = [float]0.76; B = [float]0.74; A = [float]0.90 }
    Frame = [PSCustomObject]@{ R = [float]0.06; G = [float]0.13; B = [float]0.14; A = [float]0.88 }
    Header = [PSCustomObject]@{ R = [float]0.10; G = [float]0.25; B = [float]0.24; A = [float]0.74 }
    ZoomStrip = [PSCustomObject]@{ R = [float]0.07; G = [float]0.16; B = [float]0.18; A = [float]0.78 }
    ZoomInactive = [PSCustomObject]@{ R = [float]0.24; G = [float]0.39; B = [float]0.41; A = [float]0.64 }
    ZoomActive = [PSCustomObject]@{ R = [float]0.82; G = [float]0.92; B = [float]0.86; A = [float]0.92 }
    Player = [PSCustomObject]@{ R = [float]0.98; G = [float]0.32; B = [float]0.22; A = [float]0.96 }
    PlayerRing = [PSCustomObject]@{ R = [float]1.00; G = [float]0.84; B = [float]0.72; A = [float]0.94 }
    NPC = [PSCustomObject]@{ R = [float]0.34; G = [float]0.88; B = [float]0.95; A = [float]0.93 }
    Quest = [PSCustomObject]@{ R = [float]0.96; G = [float]0.79; B = [float]0.28; A = [float]0.96 }
    CenterCross = [PSCustomObject]@{ R = [float]0.82; G = [float]0.92; B = [float]0.90; A = [float]0.34 }
}

# Static location anchors used for quest location metadata.
$script:MinimapLocationAnchors = @{
    'village_square' = [PSCustomObject]@{ X = [float]0.0; Z = [float]0.0; Label = 'Village Square' }
    'hamlet_square' = [PSCustomObject]@{ X = [float]4.0; Z = [float]2.0; Label = 'Hamlet Square' }
    'forge_district' = [PSCustomObject]@{ X = [float]16.0; Z = [float]-10.0; Label = 'Forge District' }
    'north_gate' = [PSCustomObject]@{ X = [float]0.0; Z = [float]-48.0; Label = 'North Gate' }
    'east_watch' = [PSCustomObject]@{ X = [float]46.0; Z = [float]-20.0; Label = 'East Watch' }
    'west_watch' = [PSCustomObject]@{ X = [float]-46.0; Z = [float]-18.0; Label = 'West Watch' }
    'old_watchtower' = [PSCustomObject]@{ X = [float]34.0; Z = [float]-58.0; Label = 'Old Watchtower' }
    'crystal_spring' = [PSCustomObject]@{ X = [float]-34.0; Z = [float]44.0; Label = 'Crystal Spring' }
    'ancient_ruins' = [PSCustomObject]@{ X = [float]68.0; Z = [float]38.0; Label = 'Ancient Ruins' }
    'storm_beacon' = [PSCustomObject]@{ X = [float]94.0; Z = [float]-66.0; Label = 'Storm Beacon' }
    'cliffside_shrine' = [PSCustomObject]@{ X = [float]60.0; Z = [float]-28.0; Label = 'Cliffside Shrine' }
    'apothecary' = [PSCustomObject]@{ X = [float]-14.0; Z = [float]12.0; Label = 'Apothecary' }
    'guard_barracks' = [PSCustomObject]@{ X = [float]20.0; Z = [float]-24.0; Label = 'Guard Barracks' }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Test-MinimapCommand {
    param([string]$Name)
    if (-not $script:MinimapCmdCache.ContainsKey($Name)) {
        $script:MinimapCmdCache[$Name] = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
    return $script:MinimapCmdCache[$Name]
}

function Clamp-Minimap01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-MinimapPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function Clamp-MinimapInt {
    param(
        [int]$Value,
        [int]$Min,
        [int]$Max
    )

    [int]$v = [int]$Value
    if ($v -lt $Min) { $v = [int]$Min }
    if ($v -gt $Max) { $v = [int]$Max }
    return [int]$v
}

function Normalize-MinimapKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    [string]$key = $Value.Trim().ToLowerInvariant()
    $key = [regex]::Replace($key, '[^a-z0-9]+', '_')
    $key = $key.Trim('_')
    return [string]$key
}

function Get-MinimapValue {
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
                # Ignore contains errors on custom dictionaries.
            }

            foreach ($key in $Source.Keys) {
                if ([string]::Equals([string]$key, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Source[$key]
                }
            }
        }
        else {
            foreach ($prop in $Source.PSObject.Properties) {
                if ([string]::Equals([string]$prop.Name, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $prop.Value
                }
            }
        }
    }

    return $Default
}

function Expand-MinimapCollection {
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

function New-MinimapRect {
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

function Test-MinimapPointInRect {
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

function ConvertTo-MinimapZoomLevels {
    param([object[]]$Levels)

    $result = @()

    foreach ($raw in @($Levels)) {
        [float]$value = [float]0.0
        try {
            $value = [float]$raw
        }
        catch {
            continue
        }

        $value = Clamp-MinimapPositive -Value $value -Fallback 0.0
        if ($value -le 0.0) { continue }

        [float]$rounded = [float]([Math]::Round($value, 2))
        if ($result -notcontains $rounded) {
            $result += $rounded
        }
    }

    if ($result.Count -eq 0) {
        $result = @([float]0.75, [float]1.0, [float]1.4, [float]1.9)
    }

    $sorted = @($result | Sort-Object)
    return @($sorted)
}

function Get-MinimapZoomLevelInternal {
    if ($script:MinimapZoomLevels.Count -le 0) {
        $script:MinimapZoomLevels = @([float]1.0)
        $script:MinimapZoomIndex = [int]0
    }

    $maxIndex = [int]($script:MinimapZoomLevels.Count - 1)
    $script:MinimapZoomIndex = Clamp-MinimapInt -Value ([int]$script:MinimapZoomIndex) -Min 0 -Max $maxIndex
    return [float]$script:MinimapZoomLevels[$script:MinimapZoomIndex]
}

function Get-MinimapHUDMetrics {
    [float]$scale = [float]1.0
    [float]$windowWidth = [float]1024.0
    [float]$windowHeight = [float]768.0
    [bool]$hudInitialized = $true
    [string]$source = 'Fallback'

    if (Test-MinimapCommand -Name 'Get-HUDState') {
        $state = Get-HUDState
        if ($null -ne $state) {
            if ($null -ne $state.PSObject.Properties['Scale']) {
                $scale = Clamp-MinimapPositive -Value ([double]$state.Scale) -Fallback 1.0
            }
            if ($null -ne $state.PSObject.Properties['WindowWidth']) {
                $windowWidth = Clamp-MinimapPositive -Value ([double]$state.WindowWidth) -Fallback 1024.0
            }
            if ($null -ne $state.PSObject.Properties['WindowHeight']) {
                $windowHeight = Clamp-MinimapPositive -Value ([double]$state.WindowHeight) -Fallback 768.0
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

function Get-MinimapLayout {
    param(
        [float]$Scale,
        [float]$WindowWidth,
        [float]$WindowHeight
    )

    [float]$s = Clamp-MinimapPositive -Value $Scale -Fallback 1.0
    [float]$panelSize = [float]($script:MinimapPanelSize * $s)
    [float]$margin = [float]($script:MinimapPanelMargin * $s)

    [float]$panelX = [float][Math]::Max(8.0, $WindowWidth - $panelSize - $margin)
    [float]$panelY = [float][Math]::Max(8.0, $WindowHeight - $panelSize - $margin)
    [float]$padding = [float][Math]::Max(4.0, 9.0 * $s)

    $panelRect = New-MinimapRect -X $panelX -Y $panelY -Width $panelSize -Height $panelSize
    $mapRect = New-MinimapRect -X ([float]($panelX + $padding)) -Y ([float]($panelY + $padding)) -Width ([float]($panelSize - ($padding * 2.0))) -Height ([float]($panelSize - ($padding * 2.0)))

    [float]$headerH = [float][Math]::Max(14.0, 24.0 * $s)
    [float]$zoomH = [float][Math]::Max(12.0, 18.0 * $s)
    [float]$innerPad = [float][Math]::Max(2.0, 3.0 * $s)

    [float]$worldAvailX = [float]($mapRect.X + $innerPad)
    [float]$worldAvailY = [float]($mapRect.Y + $headerH + $innerPad)
    [float]$worldAvailW = [float][Math]::Max(48.0, $mapRect.Width - ($innerPad * 2.0))
    [float]$worldAvailH = [float][Math]::Max(48.0, $mapRect.Height - $headerH - $zoomH - ($innerPad * 2.0))

    [float]$worldSize = [float][Math]::Min($worldAvailW, $worldAvailH)
    [float]$worldX = [float]($worldAvailX + (($worldAvailW - $worldSize) * 0.5))
    [float]$worldY = [float]($worldAvailY + (($worldAvailH - $worldSize) * 0.5))

    $worldRect = New-MinimapRect -X $worldX -Y $worldY -Width $worldSize -Height $worldSize
    $headerRect = New-MinimapRect -X ([float]($mapRect.X + $innerPad)) -Y ([float]($mapRect.Y + $innerPad)) -Width ([float]($mapRect.Width - ($innerPad * 2.0))) -Height $headerH
    $zoomRect = New-MinimapRect -X ([float]($mapRect.X + $innerPad)) -Y ([float]($mapRect.Y + $mapRect.Height - $zoomH - $innerPad)) -Width ([float]($mapRect.Width - ($innerPad * 2.0))) -Height $zoomH

    return [PSCustomObject]@{
        Scale = [float]$s
        Panel = $panelRect
        MapRect = $mapRect
        WorldRect = $worldRect
        HeaderRect = $headerRect
        ZoomRect = $zoomRect
    }
}

function Get-MinimapPlayerPositionInternal {
    [float]$x = [float]0.0
    [float]$y = [float]70.0
    [float]$z = [float]0.0
    [string]$source = 'Fallback'

    if (Test-MinimapCommand -Name 'Get-PlayerPosition') {
        $position = Get-PlayerPosition
        if ($null -ne $position) {
            if ($null -ne $position.PSObject.Properties['X']) { $x = [float]$position.X }
            if ($null -ne $position.PSObject.Properties['Y']) { $y = [float]$position.Y }
            if ($null -ne $position.PSObject.Properties['Z']) { $z = [float]$position.Z }
            $source = 'GetPlayerPosition'
        }
    }
    else {
        $playerVar = Get-Variable -Scope Script -Name PlayerPosition -ErrorAction SilentlyContinue
        if ($null -ne $playerVar -and $null -ne $playerVar.Value) {
            $position = $playerVar.Value
            if ($null -ne $position.PSObject.Properties['X']) { $x = [float]$position.X }
            if ($null -ne $position.PSObject.Properties['Y']) { $y = [float]$position.Y }
            if ($null -ne $position.PSObject.Properties['Z']) { $z = [float]$position.Z }
            $source = 'ScriptPlayerPosition'
        }
    }

    return [PSCustomObject]@{
        X = [float]$x
        Y = [float]$y
        Z = [float]$z
        Source = [string]$source
    }
}

function Get-MinimapNPCsInternal {
    $npcs = @()
    if (Test-MinimapCommand -Name 'Get-NPCs') {
        try {
            $npcs = Expand-MinimapCollection -InputObject (Get-NPCs)
        }
        catch {
            $npcs = @()
        }
    }

    return @($npcs)
}

function Get-MinimapActiveQuestsInternal {
    $quests = @()
    if (Test-MinimapCommand -Name 'Get-ActiveQuests') {
        try {
            $quests = Expand-MinimapCollection -InputObject (Get-ActiveQuests)
        }
        catch {
            $quests = @()
        }
    }

    return @($quests)
}

function Get-MinimapLoadedChunkSet {
    $set = @{}

    $worldChunksVar = Get-Variable -Scope Script -Name WorldChunks -ErrorAction SilentlyContinue
    if ($null -ne $worldChunksVar -and $null -ne $worldChunksVar.Value) {
        if ($worldChunksVar.Value -is [System.Collections.IDictionary]) {
            foreach ($key in $worldChunksVar.Value.Keys) {
                $set[[string]$key] = $true
            }
        }
    }

    return $set
}

function Resolve-MinimapNPCPosition {
    param($NPC)

    if ($null -eq $NPC) {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Label = ''; Id = '' }
    }

    $position = Get-MinimapValue -Source $NPC -Names @('Position') -Default $null
    if ($null -eq $position) {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Label = ''; Id = '' }
    }

    $xVal = Get-MinimapValue -Source $position -Names @('X') -Default $null
    $zVal = Get-MinimapValue -Source $position -Names @('Z') -Default $null
    if ($null -eq $xVal -or $null -eq $zVal) {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Label = ''; Id = '' }
    }

    [float]$x = [float]0.0
    [float]$z = [float]0.0
    try {
        $x = [float]$xVal
        $z = [float]$zVal
    }
    catch {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Label = ''; Id = '' }
    }

    [string]$id = [string](Get-MinimapValue -Source $NPC -Names @('Id', 'NpcId') -Default '')
    [string]$label = [string](Get-MinimapValue -Source $NPC -Names @('Name', 'NpcName') -Default '')

    return [PSCustomObject]@{
        Resolved = $true
        X = [float]$x
        Z = [float]$z
        Label = [string]$label
        Id = [string]$id
    }
}

function Get-MinimapNPCLookup {
    param([object[]]$NPCs)

    $lookup = @{}
    foreach ($npc in @($NPCs)) {
        if ($null -eq $npc) { continue }

        $keys = @()
        foreach ($name in @('Id', 'NpcId', 'Name', 'NpcName')) {
            [string]$value = [string](Get-MinimapValue -Source $npc -Names @($name) -Default '')
            [string]$key = Normalize-MinimapKey -Value $value
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $keys += $key
            }
        }

        foreach ($k in @($keys)) {
            if (-not $lookup.ContainsKey($k)) {
                $lookup[$k] = $npc
            }
        }
    }

    return $lookup
}

function Resolve-MinimapLocationAnchor {
    param([string]$Name)

    [string]$key = Normalize-MinimapKey -Value $Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [PSCustomObject]@{
            Resolved = $false
            X = [float]0.0
            Z = [float]0.0
            Source = 'LocationAnchor'
            Label = ''
            Key = ''
        }
    }

    if ($script:MinimapLocationAnchors.ContainsKey($key)) {
        $anchor = $script:MinimapLocationAnchors[$key]
        return [PSCustomObject]@{
            Resolved = $true
            X = [float]$anchor.X
            Z = [float]$anchor.Z
            Source = 'LocationAnchor'
            Label = [string]$anchor.Label
            Key = [string]$key
        }
    }

    return [PSCustomObject]@{
        Resolved = $false
        X = [float]0.0
        Z = [float]0.0
        Source = 'LocationAnchor'
        Label = ''
        Key = [string]$key
    }
}

function Resolve-MinimapMetadataPosition {
    param($Metadata)

    if ($null -eq $Metadata) {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Source = 'Metadata'; Label = '' }
    }

    $xRaw = Get-MinimapValue -Source $Metadata -Names @('X', 'WorldX', 'MapX') -Default $null
    $zRaw = Get-MinimapValue -Source $Metadata -Names @('Z', 'WorldZ', 'MapZ') -Default $null

    if ($null -ne $xRaw -and $null -ne $zRaw) {
        try {
            [float]$x = [float]$xRaw
            [float]$z = [float]$zRaw
            return [PSCustomObject]@{ Resolved = $true; X = [float]$x; Z = [float]$z; Source = 'MetadataWorldPosition'; Label = '' }
        }
        catch {
            # Fall through to location-based metadata.
        }
    }

    [string]$location = [string](Get-MinimapValue -Source $Metadata -Names @('Location', 'MapLocation', 'Zone', 'Area') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        $anchor = Resolve-MinimapLocationAnchor -Name $location
        if ([bool]$anchor.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$anchor.X
                Z = [float]$anchor.Z
                Source = 'MetadataLocation'
                Label = [string]$anchor.Label
            }
        }
    }

    return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Source = 'Metadata'; Label = '' }
}

function Resolve-MinimapQuestDefinition {
    param($Quest)

    if (-not (Test-MinimapCommand -Name 'Get-QuestDefinition')) {
        return $null
    }

    [string]$id = [string](Get-MinimapValue -Source $Quest -Names @('Id') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        try {
            $found = Get-QuestDefinition -IdOrName $id
            if ($null -ne $found) { return $found }
        }
        catch {
            # Ignore and continue to name lookup.
        }
    }

    [string]$name = [string](Get-MinimapValue -Source $Quest -Names @('Name') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        try {
            return (Get-QuestDefinition -IdOrName $name)
        }
        catch {
            return $null
        }
    }

    return $null
}

function Resolve-MinimapQuestGiverPosition {
    param(
        [string]$IdOrName,
        [hashtable]$NPCLookup
    )

    [string]$key = Normalize-MinimapKey -Value $IdOrName
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Source = 'QuestGiver'; Label = '' }
    }

    if ($null -ne $NPCLookup -and $NPCLookup.ContainsKey($key)) {
        $npcPos = Resolve-MinimapNPCPosition -NPC $NPCLookup[$key]
        if ([bool]$npcPos.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$npcPos.X
                Z = [float]$npcPos.Z
                Source = 'QuestGiverNPC'
                Label = [string]$npcPos.Label
            }
        }
    }

    if (Test-MinimapCommand -Name 'Get-QuestGiver') {
        try {
            $giver = Get-QuestGiver -IdOrName $IdOrName
            if ($null -ne $giver) {
                [string]$giverId = [string](Get-MinimapValue -Source $giver -Names @('Id', 'NpcId') -Default '')
                [string]$giverName = [string](Get-MinimapValue -Source $giver -Names @('Name', 'NpcName') -Default '')

                foreach ($candidate in @($giverId, $giverName)) {
                    [string]$candidateKey = Normalize-MinimapKey -Value $candidate
                    if ([string]::IsNullOrWhiteSpace($candidateKey)) { continue }

                    if ($null -ne $NPCLookup -and $NPCLookup.ContainsKey($candidateKey)) {
                        $npcPos = Resolve-MinimapNPCPosition -NPC $NPCLookup[$candidateKey]
                        if ([bool]$npcPos.Resolved) {
                            return [PSCustomObject]@{
                                Resolved = $true
                                X = [float]$npcPos.X
                                Z = [float]$npcPos.Z
                                Source = 'QuestGiverNPC'
                                Label = [string]$npcPos.Label
                            }
                        }
                    }
                }

                [string]$location = [string](Get-MinimapValue -Source $giver -Names @('Location', 'MapLocation') -Default '')
                if (-not [string]::IsNullOrWhiteSpace($location)) {
                    $anchor = Resolve-MinimapLocationAnchor -Name $location
                    if ([bool]$anchor.Resolved) {
                        return [PSCustomObject]@{
                            Resolved = $true
                            X = [float]$anchor.X
                            Z = [float]$anchor.Z
                            Source = 'QuestGiverLocation'
                            Label = [string]$anchor.Label
                        }
                    }
                }
            }
        }
        catch {
            # Ignore resolution errors from optional quest-giver data module.
        }
    }

    return [PSCustomObject]@{ Resolved = $false; X = [float]0.0; Z = [float]0.0; Source = 'QuestGiver'; Label = '' }
}

function Resolve-MinimapQuestObjectivePosition {
    param(
        $Quest,
        $Objective,
        $QuestDefinition,
        [hashtable]$NPCLookup
    )

    [string]$target = [string](Get-MinimapValue -Source $Objective -Names @('Target', 'Name', 'Location', 'NpcId', 'NpcName') -Default '')
    [string]$objectiveType = [string](Get-MinimapValue -Source $Objective -Names @('Type', 'ObjectiveType') -Default '')

    $objectiveMeta = Get-MinimapValue -Source $Objective -Names @('Metadata', 'Data') -Default $null
    $metaPos = Resolve-MinimapMetadataPosition -Metadata $objectiveMeta
    if ([bool]$metaPos.Resolved) {
        return [PSCustomObject]@{
            Resolved = $true
            X = [float]$metaPos.X
            Z = [float]$metaPos.Z
            Source = [string]$metaPos.Source
            Label = [string]$metaPos.Label
            Target = [string]$target
            Type = [string]$objectiveType
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($target)) {
        $giverByTarget = Resolve-MinimapQuestGiverPosition -IdOrName $target -NPCLookup $NPCLookup
        if ([bool]$giverByTarget.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$giverByTarget.X
                Z = [float]$giverByTarget.Z
                Source = [string]$giverByTarget.Source
                Label = [string]$giverByTarget.Label
                Target = [string]$target
                Type = [string]$objectiveType
            }
        }

        $anchorByTarget = Resolve-MinimapLocationAnchor -Name $target
        if ([bool]$anchorByTarget.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$anchorByTarget.X
                Z = [float]$anchorByTarget.Z
                Source = 'ObjectiveTargetLocation'
                Label = [string]$anchorByTarget.Label
                Target = [string]$target
                Type = [string]$objectiveType
            }
        }
    }

    if ($null -ne $QuestDefinition) {
        [string]$giverId = [string](Get-MinimapValue -Source $QuestDefinition -Names @('GiverId') -Default '')
        [string]$giverName = [string](Get-MinimapValue -Source $QuestDefinition -Names @('GiverName') -Default '')

        foreach ($candidate in @($giverId, $giverName)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

            if (
                [string]::IsNullOrWhiteSpace($target) -or
                [string]::Equals([string](Normalize-MinimapKey -Value $candidate), [string](Normalize-MinimapKey -Value $target), [System.StringComparison]::Ordinal) -or
                [string]::Equals([string]$objectiveType, 'Talk', [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $giverPos = Resolve-MinimapQuestGiverPosition -IdOrName $candidate -NPCLookup $NPCLookup
                if ([bool]$giverPos.Resolved) {
                    return [PSCustomObject]@{
                        Resolved = $true
                        X = [float]$giverPos.X
                        Z = [float]$giverPos.Z
                        Source = [string]$giverPos.Source
                        Label = [string]$giverPos.Label
                        Target = [string]$target
                        Type = [string]$objectiveType
                    }
                }
            }
        }

        $questDefMeta = Get-MinimapValue -Source $QuestDefinition -Names @('Metadata', 'Data') -Default $null
        $questDefMetaPos = Resolve-MinimapMetadataPosition -Metadata $questDefMeta
        if ([bool]$questDefMetaPos.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$questDefMetaPos.X
                Z = [float]$questDefMetaPos.Z
                Source = 'QuestDefinitionMetadata'
                Label = [string]$questDefMetaPos.Label
                Target = [string]$target
                Type = [string]$objectiveType
            }
        }
    }

    $questMeta = Get-MinimapValue -Source $Quest -Names @('Metadata', 'Data') -Default $null
    $questMetaPos = Resolve-MinimapMetadataPosition -Metadata $questMeta
    if ([bool]$questMetaPos.Resolved) {
        return [PSCustomObject]@{
            Resolved = $true
            X = [float]$questMetaPos.X
            Z = [float]$questMetaPos.Z
            Source = 'QuestMetadata'
            Label = [string]$questMetaPos.Label
            Target = [string]$target
            Type = [string]$objectiveType
        }
    }

    [string]$questGiverFromMeta = [string](Get-MinimapValue -Source $questMeta -Names @('GiverId', 'QuestGiverId', 'Giver') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($questGiverFromMeta)) {
        $metaGiverPos = Resolve-MinimapQuestGiverPosition -IdOrName $questGiverFromMeta -NPCLookup $NPCLookup
        if ([bool]$metaGiverPos.Resolved) {
            return [PSCustomObject]@{
                Resolved = $true
                X = [float]$metaGiverPos.X
                Z = [float]$metaGiverPos.Z
                Source = [string]$metaGiverPos.Source
                Label = [string]$metaGiverPos.Label
                Target = [string]$target
                Type = [string]$objectiveType
            }
        }
    }

    return [PSCustomObject]@{
        Resolved = $false
        X = [float]0.0
        Z = [float]0.0
        Source = 'UnresolvedObjectiveTarget'
        Label = ''
        Target = [string]$target
        Type = [string]$objectiveType
    }
}

function Get-MinimapChunkColor {
    param(
        [int]$ChunkX,
        [int]$ChunkZ,
        [bool]$IsPlayerChunk,
        [bool]$IsLoaded,
        [int]$Distance
    )

    [long]$hash = [Math]::Abs(([long]$ChunkX * 73856093) -bxor ([long]$ChunkZ * 19349663))
    [float]$noise = [float](($hash % 33) / 100.0)

    [float]$r = [float](0.09 + $noise)
    [float]$g = [float](0.18 + ($noise * 0.9))
    [float]$b = [float](0.12 + ($noise * 0.6))
    [float]$a = [float]0.60

    if ($IsLoaded) {
        $a = [float]0.78
        $g = [float][Math]::Min(1.0, $g + 0.05)
    }

    if ($Distance -ge 4) {
        $a = [float]($a * 0.78)
    }

    if ($IsPlayerChunk) {
        $r = [float]0.24
        $g = [float]0.50
        $b = [float]0.47
        $a = [float]0.92
    }

    return [PSCustomObject]@{
        R = Clamp-Minimap01 -Value $r
        G = Clamp-Minimap01 -Value $g
        B = Clamp-Minimap01 -Value $b
        A = Clamp-Minimap01 -Value $a
    }
}

function Build-MinimapChunkGrid {
    param(
        [float]$PlayerX,
        [float]$PlayerZ,
        $Layout,
        [float]$ZoomLevel,
        [hashtable]$LoadedChunkSet
    )

    [float]$chunkSize = [float]$script:MinimapChunkSize
    [int]$centerChunkX = [int][Math]::Floor($PlayerX / $chunkSize)
    [int]$centerChunkZ = [int][Math]::Floor($PlayerZ / $chunkSize)

    [float]$cellSize = [float][Math]::Max(8.0, $script:MinimapBaseChunkPixels * [float]$Layout.Scale * [float]$ZoomLevel)
    [float]$worldSize = [float][Math]::Min($Layout.WorldRect.Width, $Layout.WorldRect.Height)

    [int]$viewRadius = [int][Math]::Floor(($worldSize * 0.5) / $cellSize)
    if ($viewRadius -lt 1) { $viewRadius = 1 }
    if ($viewRadius -gt $script:MinimapMaxChunkRadius) { $viewRadius = [int]$script:MinimapMaxChunkRadius }

    while (((($viewRadius * 2) + 1) * $cellSize) -gt ($worldSize + 0.0001) -and $viewRadius -gt 1) {
        $viewRadius--
    }

    [float]$centerX = [float]($Layout.WorldRect.X + ($Layout.WorldRect.Width * 0.5))
    [float]$centerY = [float]($Layout.WorldRect.Y + ($Layout.WorldRect.Height * 0.5))

    $centerCellRect = New-MinimapRect -X ([float]($centerX - ($cellSize * 0.5))) -Y ([float]($centerY - ($cellSize * 0.5))) -Width $cellSize -Height $cellSize

    $cells = @()
    for ($dz = -$viewRadius; $dz -le $viewRadius; $dz++) {
        for ($dx = -$viewRadius; $dx -le $viewRadius; $dx++) {
            [int]$chunkX = [int]($centerChunkX + $dx)
            [int]$chunkZ = [int]($centerChunkZ + $dz)
            [float]$x = [float]($centerX + ($dx * $cellSize) - ($cellSize * 0.5))
            [float]$y = [float]($centerY + ($dz * $cellSize) - ($cellSize * 0.5))
            [string]$chunkKey = ('{0},{1}' -f $chunkX, $chunkZ)

            [bool]$isPlayerChunk = ($dx -eq 0 -and $dz -eq 0)
            [bool]$isLoaded = $false
            if ($null -ne $LoadedChunkSet) {
                $isLoaded = $LoadedChunkSet.ContainsKey($chunkKey)
            }

            [int]$dist = [int][Math]::Max([Math]::Abs($dx), [Math]::Abs($dz))
            $color = Get-MinimapChunkColor -ChunkX $chunkX -ChunkZ $chunkZ -IsPlayerChunk:$isPlayerChunk -IsLoaded:$isLoaded -Distance $dist

            $cells += [PSCustomObject]@{
                ChunkX = [int]$chunkX
                ChunkZ = [int]$chunkZ
                Key = [string]$chunkKey
                DX = [int]$dx
                DZ = [int]$dz
                Distance = [int]$dist
                IsPlayerChunk = [bool]$isPlayerChunk
                IsLoaded = [bool]$isLoaded
                Rect = (New-MinimapRect -X $x -Y $y -Width $cellSize -Height $cellSize)
                Color = $color
            }
        }
    }

    return [PSCustomObject]@{
        ChunkSize = [float]$chunkSize
        CenterChunkX = [int]$centerChunkX
        CenterChunkZ = [int]$centerChunkZ
        CenterChunkOriginX = [float]($centerChunkX * $chunkSize)
        CenterChunkOriginZ = [float]($centerChunkZ * $chunkSize)
        CellSize = [float]$cellSize
        ViewRadius = [int]$viewRadius
        CellCount = [int]$cells.Count
        WorldRect = $Layout.WorldRect
        CenterCellRect = $centerCellRect
        Cells = @($cells)
    }
}

function Convert-MinimapWorldToMapPoint {
    param(
        [float]$WorldX,
        [float]$WorldZ,
        $ChunkGrid
    )

    [float]$x = [float]($ChunkGrid.CenterCellRect.X + (($WorldX - $ChunkGrid.CenterChunkOriginX) / $ChunkGrid.ChunkSize) * $ChunkGrid.CellSize)
    [float]$y = [float]($ChunkGrid.CenterCellRect.Y + (($WorldZ - $ChunkGrid.CenterChunkOriginZ) / $ChunkGrid.ChunkSize) * $ChunkGrid.CellSize)
    [bool]$visible = Test-MinimapPointInRect -X $x -Y $y -Rect $ChunkGrid.WorldRect

    return [PSCustomObject]@{
        X = [float]$x
        Y = [float]$y
        Visible = [bool]$visible
    }
}

function Build-MinimapPlayerIndicator {
    param(
        $PlayerPosition,
        $ChunkGrid,
        [float]$Scale
    )

    $point = Convert-MinimapWorldToMapPoint -WorldX ([float]$PlayerPosition.X) -WorldZ ([float]$PlayerPosition.Z) -ChunkGrid $ChunkGrid
    [float]$size = [float][Math]::Max(4.0, 7.0 * $Scale)

    return [PSCustomObject]@{
        X = [float]$point.X
        Y = [float]$point.Y
        Size = [float]$size
        Visible = [bool]$point.Visible
        Rect = (New-MinimapRect -X ([float]($point.X - ($size * 0.5))) -Y ([float]($point.Y - ($size * 0.5))) -Width $size -Height $size)
    }
}

function Build-MinimapNPCMarkers {
    param(
        [object[]]$NPCs,
        $ChunkGrid,
        [float]$Scale
    )

    $markers = @()
    [float]$size = [float][Math]::Max(3.0, 5.5 * $Scale)

    foreach ($npc in @($NPCs)) {
        if ($null -eq $npc) { continue }

        $npcPos = Resolve-MinimapNPCPosition -NPC $npc
        if (-not [bool]$npcPos.Resolved) { continue }

        $point = Convert-MinimapWorldToMapPoint -WorldX ([float]$npcPos.X) -WorldZ ([float]$npcPos.Z) -ChunkGrid $ChunkGrid
        if (-not [bool]$point.Visible) { continue }

        [string]$id = [string](Get-MinimapValue -Source $npc -Names @('Id', 'NpcId') -Default '')
        [string]$name = [string](Get-MinimapValue -Source $npc -Names @('Name', 'NpcName') -Default '')

        $markers += [PSCustomObject]@{
            Type = 'NPC'
            Id = [string]$id
            Name = [string]$name
            Source = 'NPCSystem'
            WorldX = [float]$npcPos.X
            WorldZ = [float]$npcPos.Z
            X = [float]$point.X
            Y = [float]$point.Y
            Size = [float]$size
            Rect = (New-MinimapRect -X ([float]($point.X - ($size * 0.5))) -Y ([float]($point.Y - ($size * 0.5))) -Width $size -Height $size)
        }
    }

    return @($markers)
}

function Build-MinimapQuestMarkers {
    param(
        [object[]]$Quests,
        $ChunkGrid,
        [hashtable]$NPCLookup,
        [float]$Scale
    )

    $markers = @()
    $unresolved = @()
    $seen = @{}
    [float]$size = [float][Math]::Max(4.0, 6.5 * $Scale)

    foreach ($quest in @($Quests)) {
        if ($null -eq $quest) { continue }

        [string]$questId = [string](Get-MinimapValue -Source $quest -Names @('Id') -Default '')
        [string]$questName = [string](Get-MinimapValue -Source $quest -Names @('Name') -Default '')
        $questDefinition = Resolve-MinimapQuestDefinition -Quest $quest

        foreach ($objective in @(Get-MinimapValue -Source $quest -Names @('Objectives') -Default @())) {
            if ($null -eq $objective) { continue }

            [bool]$isCompleted = [bool](Get-MinimapValue -Source $objective -Names @('IsCompleted', 'Completed') -Default $false)
            if ($isCompleted) { continue }

            [string]$target = [string](Get-MinimapValue -Source $objective -Names @('Target', 'Name', 'Location') -Default '')
            [string]$type = [string](Get-MinimapValue -Source $objective -Names @('Type', 'ObjectiveType') -Default '')

            $resolved = Resolve-MinimapQuestObjectivePosition -Quest $quest -Objective $objective -QuestDefinition $questDefinition -NPCLookup $NPCLookup
            if (-not [bool]$resolved.Resolved) {
                $unresolved += [PSCustomObject]@{
                    QuestId = [string]$questId
                    QuestName = [string]$questName
                    ObjectiveType = [string]$type
                    Target = [string]$target
                    Reason = [string]$resolved.Source
                }
                continue
            }

            [string]$targetKey = Normalize-MinimapKey -Value $target
            [string]$dedupeKey = ('{0}|{1}|{2}|{3}' -f (Normalize-MinimapKey -Value $questId), $targetKey, (Normalize-MinimapKey -Value $type), (Normalize-MinimapKey -Value $resolved.Source))
            if ($seen.ContainsKey($dedupeKey)) {
                continue
            }
            $seen[$dedupeKey] = $true

            $point = Convert-MinimapWorldToMapPoint -WorldX ([float]$resolved.X) -WorldZ ([float]$resolved.Z) -ChunkGrid $ChunkGrid
            if (-not [bool]$point.Visible) { continue }

            [string]$label = [string]$resolved.Label
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = [string]$target
            }

            $markers += [PSCustomObject]@{
                Type = 'Quest'
                QuestId = [string]$questId
                QuestName = [string]$questName
                ObjectiveType = [string]$type
                Target = [string]$target
                Label = [string]$label
                Source = [string]$resolved.Source
                WorldX = [float]$resolved.X
                WorldZ = [float]$resolved.Z
                X = [float]$point.X
                Y = [float]$point.Y
                Size = [float]$size
                Rect = (New-MinimapRect -X ([float]($point.X - ($size * 0.5))) -Y ([float]($point.Y - ($size * 0.5))) -Width $size -Height $size)
            }
        }
    }

    return [PSCustomObject]@{
        Markers = @($markers)
        Unresolved = @($unresolved)
    }
}

function Get-MinimapZoomOptionRects {
    param(
        $Layout,
        [float[]]$Levels,
        [int]$ActiveIndex
    )

    $result = @()
    [int]$count = [int]$Levels.Count
    if ($count -le 0) {
        return @()
    }

    [float]$gap = [float][Math]::Max(2.0, 4.0 * [float]$Layout.Scale)
    [float]$stripWidth = [float]$Layout.ZoomRect.Width
    [float]$slotWidth = [float][Math]::Max(4.0, ($stripWidth - (($count + 1) * $gap)) / $count)

    for ($i = 0; $i -lt $count; $i++) {
        [float]$x = [float]($Layout.ZoomRect.X + $gap + ($i * ($slotWidth + $gap)))
        [float]$y = [float]($Layout.ZoomRect.Y + $gap)
        [float]$h = [float][Math]::Max(3.0, $Layout.ZoomRect.Height - ($gap * 2.0))

        $result += [PSCustomObject]@{
            Index = [int]$i
            Level = [float]$Levels[$i]
            IsActive = ([int]$i -eq [int]$ActiveIndex)
            Rect = (New-MinimapRect -X $x -Y $y -Width $slotWidth -Height $h)
        }
    }

    return @($result)
}

function Build-MinimapReadModel {
    $metrics = Get-MinimapHUDMetrics
    $layout = Get-MinimapLayout -Scale ([float]$metrics.Scale) -WindowWidth ([float]$metrics.WindowWidth) -WindowHeight ([float]$metrics.WindowHeight)
    $player = Get-MinimapPlayerPositionInternal

    [float]$zoomLevel = Get-MinimapZoomLevelInternal
    $loadedChunkSet = Get-MinimapLoadedChunkSet
    $chunkGrid = Build-MinimapChunkGrid -PlayerX ([float]$player.X) -PlayerZ ([float]$player.Z) -Layout $layout -ZoomLevel $zoomLevel -LoadedChunkSet $loadedChunkSet
    $playerIndicator = Build-MinimapPlayerIndicator -PlayerPosition $player -ChunkGrid $chunkGrid -Scale ([float]$layout.Scale)

    $npcs = Get-MinimapNPCsInternal
    $npcLookup = Get-MinimapNPCLookup -NPCs $npcs
    $npcMarkers = Build-MinimapNPCMarkers -NPCs $npcs -ChunkGrid $chunkGrid -Scale ([float]$layout.Scale)

    $activeQuests = Get-MinimapActiveQuestsInternal
    $questPOI = Build-MinimapQuestMarkers -Quests $activeQuests -ChunkGrid $chunkGrid -NPCLookup $npcLookup -Scale ([float]$layout.Scale)

    $zoomOptions = Get-MinimapZoomOptionRects -Layout $layout -Levels $script:MinimapZoomLevels -ActiveIndex ([int]$script:MinimapZoomIndex)

    return [PSCustomObject]@{
        Initialized = [bool]$script:MinimapInitialized
        UpdateRegistered = [bool]$script:MinimapUpdateRegistered
        RenderRegistered = [bool]$script:MinimapRenderRegistered
        Layout = $layout
        Zoom = [PSCustomObject]@{
            Levels = @($script:MinimapZoomLevels)
            Index = [int]$script:MinimapZoomIndex
            Level = [float]$zoomLevel
            Options = @($zoomOptions)
        }
        Player = [PSCustomObject]@{
            Position = [PSCustomObject]@{
                X = [float]$player.X
                Y = [float]$player.Y
                Z = [float]$player.Z
                Source = [string]$player.Source
            }
            ChunkX = [int]$chunkGrid.CenterChunkX
            ChunkZ = [int]$chunkGrid.CenterChunkZ
            Indicator = $playerIndicator
        }
        ChunkGrid = [PSCustomObject]@{
            ChunkSize = [float]$chunkGrid.ChunkSize
            CellSize = [float]$chunkGrid.CellSize
            ViewRadius = [int]$chunkGrid.ViewRadius
            CellCount = [int]$chunkGrid.CellCount
            CenterChunkX = [int]$chunkGrid.CenterChunkX
            CenterChunkZ = [int]$chunkGrid.CenterChunkZ
            WorldRect = $chunkGrid.WorldRect
            CenterCellRect = $chunkGrid.CenterCellRect
            Cells = @($chunkGrid.Cells)
        }
        POI = [PSCustomObject]@{
            NPCCount = [int]$npcMarkers.Count
            QuestCount = [int]$questPOI.Markers.Count
            NPCMarkers = @($npcMarkers)
            QuestMarkers = @($questPOI.Markers)
            UnresolvedQuestTargets = @($questPOI.Unresolved)
        }
        LastRender = $script:MinimapLastRender
    }
}

function Refresh-MinimapReadModel {
    $script:MinimapReadModel = Build-MinimapReadModel
    if ($null -ne $script:MinimapReadModel) {
        $script:MinimapReadModel.LastRender = $script:MinimapLastRender
    }

    return $script:MinimapReadModel
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-Minimap {
    <#
    .SYNOPSIS
        Initializes minimap state and callback wiring.
    #>
    param(
        [float[]]$ZoomLevels = @([float]0.75, [float]1.0, [float]1.4, [float]1.9),
        [int]$DefaultZoomIndex = 1,
        [float]$PanelSize = [float]286.0,
        [int]$MaxChunkRadius = 6
    )

    if (Test-MinimapCommand -Name 'Initialize-HUD') {
        [bool]$needsHUDInit = $true
        if (Test-MinimapCommand -Name 'Get-HUDState') {
            $hudState = Get-HUDState
            if ($null -ne $hudState -and $null -ne $hudState.PSObject.Properties['Initialized']) {
                $needsHUDInit = -not [bool]$hudState.Initialized
            }
        }

        if ($needsHUDInit) {
            Initialize-HUD -DesignWidth 1920 -DesignHeight 1080 -ScaleMode Fit -MaxScale 2.0
        }
    }

    $script:MinimapPanelSize = Clamp-MinimapPositive -Value $PanelSize -Fallback 286.0
    [int]$radius = [int]$MaxChunkRadius
    if ($radius -lt 1) { $radius = 1 }
    if ($radius -gt 12) { $radius = 12 }
    $script:MinimapMaxChunkRadius = [int]$radius

    $script:MinimapZoomLevels = ConvertTo-MinimapZoomLevels -Levels @($ZoomLevels)
    [int]$maxIndex = [int]($script:MinimapZoomLevels.Count - 1)
    $script:MinimapZoomIndex = Clamp-MinimapInt -Value ([int]$DefaultZoomIndex) -Min 0 -Max $maxIndex

    $script:MinimapInitialized = $true

    if (-not $script:MinimapUpdateRegistered) {
        if (Test-MinimapCommand -Name 'Register-UpdateCallback') {
            Register-UpdateCallback ${function:Update-Minimap}
            $script:MinimapUpdateRegistered = $true
            Write-Host '[Minimap] Update callback registered.' -ForegroundColor DarkGray
        }
    }

    if (-not $script:MinimapRenderRegistered) {
        if (Test-MinimapCommand -Name 'Register-RenderCallback') {
            Register-RenderCallback ${function:Render-Minimap}
            $script:MinimapRenderRegistered = $true
            Write-Host '[Minimap] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    $script:MinimapLastRender = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
        DrawCallEstimate = [int]0
        ChunkCellsDrawn = [int]0
        NPCMarkersDrawn = [int]0
        QuestMarkersDrawn = [int]0
        ZoomLevel = [float](Get-MinimapZoomLevelInternal)
    }

    Refresh-MinimapReadModel | Out-Null
    Write-Host '[Minimap] Minimap initialized.' -ForegroundColor Green
}

function Update-Minimap {
    <#
    .SYNOPSIS
        Per-frame minimap update. Only rebuilds read model when data changes
        or every MinimapRefreshInterval frames to avoid excessive computation.
    #>
    param($dt)

    if (-not $script:MinimapInitialized) {
        return
    }

    # Check if player moved to a different chunk (triggers full rebuild)
    $pos = Get-MinimapPlayerPositionInternal
    [int]$currentChunkX = [int][Math]::Floor([float]$pos.X / [float]$script:MinimapChunkSize)
    [int]$currentChunkZ = [int][Math]::Floor([float]$pos.Z / [float]$script:MinimapChunkSize)

    if ($currentChunkX -ne $script:MinimapLastPlayerChunkX -or $currentChunkZ -ne $script:MinimapLastPlayerChunkZ) {
        $script:MinimapLastPlayerChunkX = $currentChunkX
        $script:MinimapLastPlayerChunkZ = $currentChunkZ
        $script:MinimapDirty = $true
    }

    $script:MinimapFrameCounter++

    # Only rebuild when dirty or on periodic interval
    if ($script:MinimapDirty -or ($script:MinimapFrameCounter -ge $script:MinimapRefreshInterval)) {
        Refresh-MinimapReadModel | Out-Null
        $script:MinimapDirty = $false
        $script:MinimapFrameCounter = [int]0
    }
}

function Render-Minimap {
    <#
    .SYNOPSIS
        Draws minimap panel, chunk grid, player indicator, and POI markers.
    #>
    param($dt)

    if (-not $script:MinimapInitialized) {
        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
            DrawCallEstimate = [int]0
            ChunkCellsDrawn = [int]0
            NPCMarkersDrawn = [int]0
            QuestMarkersDrawn = [int]0
            ZoomLevel = [float](Get-MinimapZoomLevelInternal)
        }
        return
    }

    if (-not (Test-MinimapCommand -Name 'Draw-HUDRect')) {
        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'HeadlessNoDrawAPI'
            Rendered = $false
            Reason = 'DrawHUDRectMissing'
            DrawCallEstimate = [int]0
            ChunkCellsDrawn = [int]0
            NPCMarkersDrawn = [int]0
            QuestMarkersDrawn = [int]0
            ZoomLevel = [float](Get-MinimapZoomLevelInternal)
        }
        return
    }

    $metrics = Get-MinimapHUDMetrics
    if (-not [bool]$metrics.HUDInitialized) {
        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'HUDNotInitialized'
            DrawCallEstimate = [int]0
            ChunkCellsDrawn = [int]0
            NPCMarkersDrawn = [int]0
            QuestMarkersDrawn = [int]0
            ZoomLevel = [float](Get-MinimapZoomLevelInternal)
        }
        return
    }

    # Use cached read model from Update-Minimap instead of rebuilding
    $state = $script:MinimapReadModel
    if ($null -eq $state) {
        # First frame or no update yet — build once
        Refresh-MinimapReadModel | Out-Null
        $state = $script:MinimapReadModel
    }
    if ($null -eq $state) {
        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'ReadModelUnavailable'
            DrawCallEstimate = [int]0
            ChunkCellsDrawn = [int]0
            NPCMarkersDrawn = [int]0
            QuestMarkersDrawn = [int]0
            ZoomLevel = [float](Get-MinimapZoomLevelInternal)
        }
        return
    }

    [float]$z = [float]-0.94
    [int]$drawCount = 0
    [int]$chunkCellsDrawn = 0
    [int]$npcMarkersDrawn = 0
    [int]$questMarkersDrawn = 0

    try {
        [float]$border = [float][Math]::Max(1.0, [Math]::Round([float]$state.Layout.Scale))

        # Panel shell
        Draw-HUDRect -X ([float]$state.Layout.Panel.X) -Y ([float]$state.Layout.Panel.Y) -Width ([float]$state.Layout.Panel.Width) -Height ([float]$state.Layout.Panel.Height) -Z $z -R ([float]$script:MinimapTheme.Panel.R) -G ([float]$script:MinimapTheme.Panel.G) -B ([float]$script:MinimapTheme.Panel.B) -A ([float]$script:MinimapTheme.Panel.A)
        $drawCount++

        Draw-HUDRect -X ([float]$state.Layout.Panel.X) -Y ([float]$state.Layout.Panel.Y) -Width ([float]$state.Layout.Panel.Width) -Height $border -Z ($z - 0.0001) -R ([float]$script:MinimapTheme.PanelBorder.R) -G ([float]$script:MinimapTheme.PanelBorder.G) -B ([float]$script:MinimapTheme.PanelBorder.B) -A ([float]$script:MinimapTheme.PanelBorder.A)
        $drawCount++
        Draw-HUDRect -X ([float]$state.Layout.Panel.X) -Y ([float]($state.Layout.Panel.Y + $state.Layout.Panel.Height - $border)) -Width ([float]$state.Layout.Panel.Width) -Height $border -Z ($z - 0.0001) -R ([float]$script:MinimapTheme.PanelBorder.R) -G ([float]$script:MinimapTheme.PanelBorder.G) -B ([float]$script:MinimapTheme.PanelBorder.B) -A ([float]$script:MinimapTheme.PanelBorder.A)
        $drawCount++
        Draw-HUDRect -X ([float]$state.Layout.Panel.X) -Y ([float]$state.Layout.Panel.Y) -Width $border -Height ([float]$state.Layout.Panel.Height) -Z ($z - 0.0001) -R ([float]$script:MinimapTheme.PanelBorder.R) -G ([float]$script:MinimapTheme.PanelBorder.G) -B ([float]$script:MinimapTheme.PanelBorder.B) -A ([float]$script:MinimapTheme.PanelBorder.A)
        $drawCount++
        Draw-HUDRect -X ([float]($state.Layout.Panel.X + $state.Layout.Panel.Width - $border)) -Y ([float]$state.Layout.Panel.Y) -Width $border -Height ([float]$state.Layout.Panel.Height) -Z ($z - 0.0001) -R ([float]$script:MinimapTheme.PanelBorder.R) -G ([float]$script:MinimapTheme.PanelBorder.G) -B ([float]$script:MinimapTheme.PanelBorder.B) -A ([float]$script:MinimapTheme.PanelBorder.A)
        $drawCount++

        # Map frame + overlays
        Draw-HUDRect -X ([float]$state.Layout.MapRect.X) -Y ([float]$state.Layout.MapRect.Y) -Width ([float]$state.Layout.MapRect.Width) -Height ([float]$state.Layout.MapRect.Height) -Z ($z - 0.0002) -R ([float]$script:MinimapTheme.Frame.R) -G ([float]$script:MinimapTheme.Frame.G) -B ([float]$script:MinimapTheme.Frame.B) -A ([float]$script:MinimapTheme.Frame.A)
        $drawCount++

        Draw-HUDRect -X ([float]$state.Layout.HeaderRect.X) -Y ([float]$state.Layout.HeaderRect.Y) -Width ([float]$state.Layout.HeaderRect.Width) -Height ([float]$state.Layout.HeaderRect.Height) -Z ($z - 0.0003) -R ([float]$script:MinimapTheme.Header.R) -G ([float]$script:MinimapTheme.Header.G) -B ([float]$script:MinimapTheme.Header.B) -A ([float]$script:MinimapTheme.Header.A)
        $drawCount++

        Draw-HUDRect -X ([float]$state.Layout.ZoomRect.X) -Y ([float]$state.Layout.ZoomRect.Y) -Width ([float]$state.Layout.ZoomRect.Width) -Height ([float]$state.Layout.ZoomRect.Height) -Z ($z - 0.0003) -R ([float]$script:MinimapTheme.ZoomStrip.R) -G ([float]$script:MinimapTheme.ZoomStrip.G) -B ([float]$script:MinimapTheme.ZoomStrip.B) -A ([float]$script:MinimapTheme.ZoomStrip.A)
        $drawCount++

        Draw-HUDRect -X ([float]$state.ChunkGrid.CenterCellRect.X) -Y ([float]$state.ChunkGrid.WorldRect.Y) -Width ([float]$state.ChunkGrid.CenterCellRect.Width) -Height ([float]$state.ChunkGrid.WorldRect.Height) -Z ($z - 0.00035) -R ([float]$script:MinimapTheme.CenterCross.R) -G ([float]$script:MinimapTheme.CenterCross.G) -B ([float]$script:MinimapTheme.CenterCross.B) -A ([float]$script:MinimapTheme.CenterCross.A)
        $drawCount++

        Draw-HUDRect -X ([float]$state.ChunkGrid.WorldRect.X) -Y ([float]$state.ChunkGrid.CenterCellRect.Y) -Width ([float]$state.ChunkGrid.WorldRect.Width) -Height ([float]$state.ChunkGrid.CenterCellRect.Height) -Z ($z - 0.00035) -R ([float]$script:MinimapTheme.CenterCross.R) -G ([float]$script:MinimapTheme.CenterCross.G) -B ([float]$script:MinimapTheme.CenterCross.B) -A ([float]$script:MinimapTheme.CenterCross.A)
        $drawCount++

        foreach ($cell in $state.ChunkGrid.Cells) {
            if ($null -eq $cell) { continue }

            Draw-HUDRect -X ([float]$cell.Rect.X) -Y ([float]$cell.Rect.Y) -Width ([float]$cell.Rect.Width) -Height ([float]$cell.Rect.Height) -Z ($z - 0.0004) -R ([float]$cell.Color.R) -G ([float]$cell.Color.G) -B ([float]$cell.Color.B) -A ([float]$cell.Color.A)
            $drawCount++
            $chunkCellsDrawn++
        }

        foreach ($questMarker in $state.POI.QuestMarkers) {
            if ($null -eq $questMarker) { continue }

            Draw-HUDRect -X ([float]$questMarker.Rect.X) -Y ([float]$questMarker.Rect.Y) -Width ([float]$questMarker.Rect.Width) -Height ([float]$questMarker.Rect.Height) -Z ($z - 0.0006) -R ([float]$script:MinimapTheme.Quest.R) -G ([float]$script:MinimapTheme.Quest.G) -B ([float]$script:MinimapTheme.Quest.B) -A ([float]$script:MinimapTheme.Quest.A)
            $drawCount++
            $questMarkersDrawn++

            [float]$innerW = [float][Math]::Max(1.0, $questMarker.Rect.Width * 0.42)
            [float]$innerH = [float][Math]::Max(1.0, $questMarker.Rect.Height * 0.42)
            Draw-HUDRect -X ([float]($questMarker.X - ($innerW * 0.5))) -Y ([float]($questMarker.Y - ($innerH * 0.5))) -Width $innerW -Height $innerH -Z ($z - 0.00061) -R 0.12 -G 0.10 -B 0.08 -A 0.65
            $drawCount++
        }

        foreach ($npcMarker in $state.POI.NPCMarkers) {
            if ($null -eq $npcMarker) { continue }

            Draw-HUDRect -X ([float]$npcMarker.Rect.X) -Y ([float]$npcMarker.Rect.Y) -Width ([float]$npcMarker.Rect.Width) -Height ([float]$npcMarker.Rect.Height) -Z ($z - 0.00062) -R ([float]$script:MinimapTheme.NPC.R) -G ([float]$script:MinimapTheme.NPC.G) -B ([float]$script:MinimapTheme.NPC.B) -A ([float]$script:MinimapTheme.NPC.A)
            $drawCount++
            $npcMarkersDrawn++
        }

        if ([bool]$state.Player.Indicator.Visible) {
            Draw-HUDRect -X ([float]($state.Player.Indicator.Rect.X - 1.0)) -Y ([float]($state.Player.Indicator.Rect.Y - 1.0)) -Width ([float]($state.Player.Indicator.Rect.Width + 2.0)) -Height ([float]($state.Player.Indicator.Rect.Height + 2.0)) -Z ($z - 0.0008) -R ([float]$script:MinimapTheme.PlayerRing.R) -G ([float]$script:MinimapTheme.PlayerRing.G) -B ([float]$script:MinimapTheme.PlayerRing.B) -A ([float]$script:MinimapTheme.PlayerRing.A)
            $drawCount++

            Draw-HUDRect -X ([float]$state.Player.Indicator.Rect.X) -Y ([float]$state.Player.Indicator.Rect.Y) -Width ([float]$state.Player.Indicator.Rect.Width) -Height ([float]$state.Player.Indicator.Rect.Height) -Z ($z - 0.00081) -R ([float]$script:MinimapTheme.Player.R) -G ([float]$script:MinimapTheme.Player.G) -B ([float]$script:MinimapTheme.Player.B) -A ([float]$script:MinimapTheme.Player.A)
            $drawCount++
        }

        foreach ($zoomOption in $state.Zoom.Options) {
            if ($null -eq $zoomOption) { continue }

            $color = $script:MinimapTheme.ZoomInactive
            if ([bool]$zoomOption.IsActive) {
                $color = $script:MinimapTheme.ZoomActive
            }

            Draw-HUDRect -X ([float]$zoomOption.Rect.X) -Y ([float]$zoomOption.Rect.Y) -Width ([float]$zoomOption.Rect.Width) -Height ([float]$zoomOption.Rect.Height) -Z ($z - 0.0009) -R ([float]$color.R) -G ([float]$color.G) -B ([float]$color.B) -A ([float]$color.A)
            $drawCount++
        }

        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'HUDOverlay'
            Rendered = $true
            Reason = 'Rendered'
            DrawCallEstimate = [int]$drawCount
            ChunkCellsDrawn = [int]$chunkCellsDrawn
            NPCMarkersDrawn = [int]$npcMarkersDrawn
            QuestMarkersDrawn = [int]$questMarkersDrawn
            ZoomLevel = [float]$state.Zoom.Level
        }
    }
    catch {
        $script:MinimapLastRender = [PSCustomObject]@{
            Mode = 'DrawFailed'
            Rendered = $false
            Reason = [string]$_.Exception.Message
            DrawCallEstimate = [int]$drawCount
            ChunkCellsDrawn = [int]$chunkCellsDrawn
            NPCMarkersDrawn = [int]$npcMarkersDrawn
            QuestMarkersDrawn = [int]$questMarkersDrawn
            ZoomLevel = [float](Get-MinimapZoomLevelInternal)
        }
    }

    $script:MinimapReadModel.LastRender = $script:MinimapLastRender
}

function Set-MinimapZoomIndex {
    <#
    .SYNOPSIS
        Sets minimap zoom to a discrete level index.
    #>
    param([int]$Index)

    if ($script:MinimapZoomLevels.Count -le 0) {
        $script:MinimapZoomLevels = @([float]1.0)
    }

    [int]$maxIndex = [int]($script:MinimapZoomLevels.Count - 1)
    $script:MinimapZoomIndex = Clamp-MinimapInt -Value $Index -Min 0 -Max $maxIndex

    if ($script:MinimapInitialized) {
        Refresh-MinimapReadModel | Out-Null
    }

    return [PSCustomObject]@{
        Index = [int]$script:MinimapZoomIndex
        Level = [float](Get-MinimapZoomLevelInternal)
        Levels = @($script:MinimapZoomLevels)
    }
}

function Set-MinimapZoomLevel {
    <#
    .SYNOPSIS
        Sets minimap zoom to nearest discrete zoom level.
    #>
    param([float]$Level)

    if ($script:MinimapZoomLevels.Count -le 0) {
        $script:MinimapZoomLevels = @([float]1.0)
        $script:MinimapZoomIndex = [int]0
    }

    [float]$target = Clamp-MinimapPositive -Value $Level -Fallback 1.0
    [int]$bestIndex = [int]0
    [float]$bestDiff = [float]999999.0

    for ($i = 0; $i -lt $script:MinimapZoomLevels.Count; $i++) {
        [float]$candidate = [float]$script:MinimapZoomLevels[$i]
        [float]$diff = [float][Math]::Abs($candidate - $target)
        if ($diff -lt $bestDiff) {
            $bestDiff = $diff
            $bestIndex = [int]$i
        }
    }

    return (Set-MinimapZoomIndex -Index $bestIndex)
}

function Increase-MinimapZoom {
    <#
    .SYNOPSIS
        Moves minimap zoom to the next higher discrete level.
    #>

    return (Set-MinimapZoomIndex -Index ([int]$script:MinimapZoomIndex + 1))
}

function Decrease-MinimapZoom {
    <#
    .SYNOPSIS
        Moves minimap zoom to the next lower discrete level.
    #>

    return (Set-MinimapZoomIndex -Index ([int]$script:MinimapZoomIndex - 1))
}

function Get-MinimapZoomOptions {
    <#
    .SYNOPSIS
        Returns minimap zoom levels and active level metadata.
    #>

    return [PSCustomObject]@{
        Levels = @($script:MinimapZoomLevels)
        Index = [int]$script:MinimapZoomIndex
        Level = [float](Get-MinimapZoomLevelInternal)
    }
}

function Get-MinimapZoomLevel {
    <#
    .SYNOPSIS
        Returns the active minimap zoom level.
    #>

    return [float](Get-MinimapZoomLevelInternal)
}

function Get-MinimapState {
    <#
    .SYNOPSIS
        Returns deterministic minimap state for verification and UI integration.
    #>

    if (-not $script:MinimapInitialized) {
        return [PSCustomObject]@{
            Initialized = $false
            UpdateRegistered = [bool]$script:MinimapUpdateRegistered
            RenderRegistered = [bool]$script:MinimapRenderRegistered
            Layout = $null
            Zoom = [PSCustomObject]@{
                Levels = @($script:MinimapZoomLevels)
                Index = [int]$script:MinimapZoomIndex
                Level = [float](Get-MinimapZoomLevelInternal)
                Options = @()
            }
            Player = [PSCustomObject]@{
                Position = [PSCustomObject]@{ X = [float]0.0; Y = [float]70.0; Z = [float]0.0; Source = 'Fallback' }
                ChunkX = [int]0
                ChunkZ = [int]0
                Indicator = [PSCustomObject]@{
                    X = [float]0.0
                    Y = [float]0.0
                    Size = [float]0.0
                    Visible = $false
                    Rect = (New-MinimapRect -X 0 -Y 0 -Width 0 -Height 0)
                }
            }
            ChunkGrid = [PSCustomObject]@{
                ChunkSize = [float]$script:MinimapChunkSize
                CellSize = [float]0.0
                ViewRadius = [int]0
                CellCount = [int]0
                CenterChunkX = [int]0
                CenterChunkZ = [int]0
                Cells = @()
            }
            POI = [PSCustomObject]@{
                NPCCount = [int]0
                QuestCount = [int]0
                NPCMarkers = @()
                QuestMarkers = @()
                UnresolvedQuestTargets = @()
            }
            LastRender = $script:MinimapLastRender
        }
    }

    Refresh-MinimapReadModel | Out-Null
    return $script:MinimapReadModel
}
