# ============================================================================
# UI/Menu.ps1 - Deterministic Menu System Overlay
# ============================================================================
# Deterministic menu module.
#
# Provides:
# - Main menu (Start, Settings, Exit)
# - Pause menu (Resume, Settings, Exit)
# - Settings menu (Controls, Audio, Video)
# - Keyboard and mouse navigation
# - Lightweight menu transitions and pause/cursor capture control
#
# Optional dependencies:
# - UI/HUD.ps1: Draw-HUDRect, Get-HUDState, Initialize-HUD
# - Engine/OpenGL.ps1: Register-UpdateCallback, Register-RenderCallback, Get-MainForm
# - Engine/Input.ps1: Get-KeyDown, Get-MousePosition, Get-MouseButton, Get-MouseButtonDown, Set-MouseCapture
# ============================================================================

# --- Module State ---
$script:MenuInitialized = $false
$script:MenuUpdateRegistered = $false
$script:MenuRenderRegistered = $false

$script:MenuCurrentView = 'Main'       # Hidden | Main | Pause | Settings
$script:MenuPreviousView = 'Main'
$script:MenuLastVisibleView = 'Main'
$script:MenuSettingsReturnView = 'Main'

$script:MenuGameplayStarted = $false
$script:MenuPaused = $true
$script:MenuExitRequested = $false
$script:MenuPauseReason = 'Startup'

$script:MenuSelectionMainIndex = [int]0
$script:MenuSelectionPauseIndex = [int]0

$script:MenuSettingsCategoryOrder = @('Controls', 'Audio', 'Video')
$script:MenuSelectedSettingsCategory = 'Controls'
$script:MenuSettingsRowSelection = @{
    Controls = [int]0
    Audio = [int]0
    Video = [int]0
}

$script:MenuSettingsValues = @{
    Controls = @{
        MoveForward = 'W'
        Jump = 'Space'
        Inventory = 'E'
    }
    Audio = @{
        MasterVolume = [int]85
        MusicVolume = [int]70
        EffectsVolume = [int]80
        AudioBackendAvailable = $false
    }
    Video = @{
        Resolution = '1024x768'
        VSync = $true
        RenderDistance = [int]4
    }
}

$script:MenuSettingsPersistenceStatus = 'FileBackedPending_Task50'

$script:MenuMainItems = @(
    [PSCustomObject]@{ Id = 'main_start'; Label = 'Start'; Action = 'Start' },
    [PSCustomObject]@{ Id = 'main_settings'; Label = 'Settings'; Action = 'OpenSettings' },
    [PSCustomObject]@{ Id = 'main_exit'; Label = 'Exit'; Action = 'Exit' }
)

$script:MenuPauseItems = @(
    [PSCustomObject]@{ Id = 'pause_resume'; Label = 'Resume'; Action = 'Resume' },
    [PSCustomObject]@{ Id = 'pause_settings'; Label = 'Settings'; Action = 'OpenSettings' },
    [PSCustomObject]@{ Id = 'pause_exit'; Label = 'Exit'; Action = 'Exit' }
)

$script:MenuTransitionDuration = [float]0.18
$script:MenuTransition = [PSCustomObject]@{
    Active = $false
    Progress = [float]1.0
    Elapsed = [float]0.0
    Duration = [float]$script:MenuTransitionDuration
    FromView = 'Main'
    ToView = 'Main'
    Reason = 'Initialized'
}

$script:MenuLeftMouseWasHeld = $false
$script:MenuReadModel = $null

$script:MenuLastAction = [PSCustomObject]@{
    Action = 'None'
    Source = 'None'
    Success = $false
    Reason = 'NotAttempted'
    View = 'Main'
    TimestampUtc = [DateTime]::MinValue
}

$script:MenuLastRender = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
    DrawCallEstimate = [int]0
    View = 'Main'
    VisibleView = 'Main'
    TransitionActive = $false
    TransitionProgress = [float]1.0
}

$script:MenuTheme = [PSCustomObject]@{
    Overlay = [PSCustomObject]@{ R = [float]0.02; G = [float]0.04; B = [float]0.06; A = [float]0.64 }
    Panel = [PSCustomObject]@{ R = [float]0.04; G = [float]0.07; B = [float]0.10; A = [float]0.92 }
    PanelBorder = [PSCustomObject]@{ R = [float]0.63; G = [float]0.80; B = [float]0.91; A = [float]0.90 }
    Header = [PSCustomObject]@{ R = [float]0.11; G = [float]0.21; B = [float]0.30; A = [float]0.86 }
    HeaderAccent = [PSCustomObject]@{ R = [float]0.90; G = [float]0.80; B = [float]0.48; A = [float]0.84 }
    Item = [PSCustomObject]@{ R = [float]0.09; G = [float]0.13; B = [float]0.19; A = [float]0.90 }
    ItemHover = [PSCustomObject]@{ R = [float]0.20; G = [float]0.29; B = [float]0.40; A = [float]0.95 }
    ItemSelected = [PSCustomObject]@{ R = [float]0.84; G = [float]0.73; B = [float]0.35; A = [float]0.92 }
    ItemAccent = [PSCustomObject]@{ R = [float]0.96; G = [float]0.92; B = [float]0.74; A = [float]0.92 }
    Tab = [PSCustomObject]@{ R = [float]0.10; G = [float]0.15; B = [float]0.22; A = [float]0.84 }
    TabHover = [PSCustomObject]@{ R = [float]0.18; G = [float]0.25; B = [float]0.34; A = [float]0.90 }
    TabSelected = [PSCustomObject]@{ R = [float]0.79; G = [float]0.68; B = [float]0.30; A = [float]0.94 }
    ValueTrack = [PSCustomObject]@{ R = [float]0.07; G = [float]0.09; B = [float]0.12; A = [float]0.88 }
    ValueFill = [PSCustomObject]@{ R = [float]0.31; G = [float]0.79; B = [float]0.56; A = [float]0.94 }
    ToggleOff = [PSCustomObject]@{ R = [float]0.31; G = [float]0.35; B = [float]0.42; A = [float]0.88 }
    ToggleOn = [PSCustomObject]@{ R = [float]0.26; G = [float]0.73; B = [float]0.49; A = [float]0.94 }
    BackButton = [PSCustomObject]@{ R = [float]0.53; G = [float]0.20; B = [float]0.20; A = [float]0.90 }
    BackButtonHover = [PSCustomObject]@{ R = [float]0.72; G = [float]0.29; B = [float]0.29; A = [float]0.95 }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Clamp-Menu01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-MenuPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function Clamp-MenuInt {
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

function Get-MenuChoiceOptions {
    param(
        [string]$Category,
        [string]$SettingId
    )

    if ($Category -eq 'Controls') {
        if (Get-Command -Name Get-SettingsKeyBindingOptions -ErrorAction SilentlyContinue) {
            return @((Get-SettingsKeyBindingOptions))
        }

        return @('W', 'A', 'S', 'D', 'Space', 'ShiftKey', 'Escape', 'Return', 'Up', 'Down', 'Left', 'Right', 'E', 'F')
    }

    if ($Category -eq 'Video' -and $SettingId -eq 'Resolution') {
        if (Get-Command -Name Get-SettingsResolutionOptions -ErrorAction SilentlyContinue) {
            return @((Get-SettingsResolutionOptions))
        }

        return @('1024x768', '1280x720', '1366x768', '1600x900', '1920x1080')
    }

    return @()
}

function Import-MenuSettingsFromPersistence {
    if (-not (Get-Command -Name Get-Settings -ErrorAction SilentlyContinue)) {
        $script:MenuSettingsPersistenceStatus = 'InMemoryFallback_Task50'
        return $false
    }

    try {
        $settings = Get-Settings
        if ($null -eq $settings) {
            $script:MenuSettingsPersistenceStatus = 'InMemoryFallback_Task50'
            return $false
        }

        $script:MenuSettingsValues['Controls']['MoveForward'] = [string](Get-SettingsValue -Source $settings.Controls.KeyBindings -Names @('MoveForward') -Default 'W')
        $script:MenuSettingsValues['Controls']['Jump'] = [string](Get-SettingsValue -Source $settings.Controls.KeyBindings -Names @('Jump') -Default 'Space')
        $script:MenuSettingsValues['Controls']['Inventory'] = [string](Get-SettingsValue -Source $settings.Controls.KeyBindings -Names @('Inventory') -Default 'E')

        $script:MenuSettingsValues['Audio']['MasterVolume'] = [int](Get-SettingsValue -Source $settings.Audio -Names @('MasterVolume') -Default 85)
        $script:MenuSettingsValues['Audio']['MusicVolume'] = [int](Get-SettingsValue -Source $settings.Audio -Names @('MusicVolume') -Default 70)
        $script:MenuSettingsValues['Audio']['EffectsVolume'] = [int](Get-SettingsValue -Source $settings.Audio -Names @('EffectsVolume') -Default 80)
        $script:MenuSettingsValues['Audio']['AudioBackendAvailable'] = [bool](Get-SettingsValue -Source $settings.Audio -Names @('AudioBackendAvailable') -Default $false)

        $script:MenuSettingsValues['Video']['Resolution'] = [string](Get-SettingsValue -Source $settings.Video -Names @('Resolution') -Default '1024x768')
        $script:MenuSettingsValues['Video']['VSync'] = [bool](Get-SettingsValue -Source $settings.Video -Names @('VSync') -Default $true)
        $script:MenuSettingsValues['Video']['RenderDistance'] = [int](Get-SettingsValue -Source $settings.Video -Names @('RenderDistance') -Default 4)

        if (Get-Command -Name Get-SettingsPersistenceToken -ErrorAction SilentlyContinue) {
            $script:MenuSettingsPersistenceStatus = [string](Get-SettingsPersistenceToken)
        }
        else {
            $script:MenuSettingsPersistenceStatus = 'FileBacked_Task50'
        }

        return $true
    }
    catch {
        $script:MenuSettingsPersistenceStatus = 'InMemoryFallback_Task50'
        return $false
    }
}

function New-MenuRect {
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

function Test-MenuPointInRect {
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

function Get-MenuHUDMetrics {
    [float]$scale = [float]1.0
    [float]$windowWidth = [float]1024.0
    [float]$windowHeight = [float]768.0
    [bool]$hudInitialized = $true
    [string]$source = 'Fallback'

    if (Get-Command -Name Get-HUDState -ErrorAction SilentlyContinue) {
        $state = Get-HUDState
        if ($null -ne $state) {
            if ($null -ne $state.PSObject.Properties['Scale']) {
                $scale = Clamp-MenuPositive -Value ([double]$state.Scale) -Fallback 1.0
            }
            if ($null -ne $state.PSObject.Properties['WindowWidth']) {
                $windowWidth = Clamp-MenuPositive -Value ([double]$state.WindowWidth) -Fallback 1024.0
            }
            if ($null -ne $state.PSObject.Properties['WindowHeight']) {
                $windowHeight = Clamp-MenuPositive -Value ([double]$state.WindowHeight) -Fallback 768.0
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

function Get-MenuMousePositionInternal {
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

function Get-MenuMouseButtonHeldInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButton -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButton -Button $Button)
    }

    return $false
}

function Get-MenuMouseButtonDownInternal {
    param([int]$Button = 0)

    if (Get-Command -Name Get-MouseButtonDown -ErrorAction SilentlyContinue) {
        return [bool](Get-MouseButtonDown -Button $Button)
    }

    return $false
}

function Get-MenuKeyDownInternal {
    param([System.Windows.Forms.Keys]$Key)

    if (Get-Command -Name Get-KeyDown -ErrorAction SilentlyContinue) {
        return [bool](Get-KeyDown -Key $Key)
    }

    return $false
}

function Get-MenuLayout {
    param(
        [float]$Scale,
        [float]$WindowWidth,
        [float]$WindowHeight
    )

    [float]$s = Clamp-MenuPositive -Value $Scale -Fallback 1.0

    [float]$panelW = [float](620.0 * $s)
    [float]$panelH = [float](500.0 * $s)

    [float]$minPanelW = [float](360.0 * $s)
    [float]$minPanelH = [float](320.0 * $s)
    [float]$maxPanelW = [float][Math]::Max($minPanelW, $WindowWidth - (34.0 * $s))
    [float]$maxPanelH = [float][Math]::Max($minPanelH, $WindowHeight - (34.0 * $s))

    if ($panelW -gt $maxPanelW) { $panelW = [float]$maxPanelW }
    if ($panelH -gt $maxPanelH) { $panelH = [float]$maxPanelH }
    if ($panelW -lt $minPanelW) { $panelW = [float]$minPanelW }
    if ($panelH -lt $minPanelH) { $panelH = [float]$minPanelH }

    [float]$panelX = [float](($WindowWidth - $panelW) * 0.5)
    [float]$panelY = [float](($WindowHeight - $panelH) * 0.5)

    [float]$headerH = [float][Math]::Max(36.0, 62.0 * $s)

    [float]$menuRowW = [float]($panelW - (84.0 * $s))
    [float]$menuRowH = [float][Math]::Max(30.0, 52.0 * $s)
    [float]$menuRowGap = [float][Math]::Max(6.0, 12.0 * $s)
    [float]$menuRowX = [float]($panelX + (42.0 * $s))
    [float]$menuRowY = [float]($panelY + $headerH + (36.0 * $s))

    [float]$tabX = [float]($panelX + (32.0 * $s))
    [float]$tabY = [float]($panelY + $headerH + (16.0 * $s))
    [float]$tabW = [float]($panelW - (64.0 * $s))
    [float]$tabH = [float][Math]::Max(24.0, 36.0 * $s)
    [float]$tabGap = [float][Math]::Max(4.0, 8.0 * $s)

    [float]$settingRowX = [float]$tabX
    [float]$settingRowY = [float]($tabY + $tabH + (16.0 * $s))
    [float]$settingRowW = [float]$tabW
    [float]$settingRowH = [float][Math]::Max(28.0, 46.0 * $s)
    [float]$settingRowGap = [float][Math]::Max(6.0, 10.0 * $s)

    [float]$backW = [float][Math]::Max(84.0, 148.0 * $s)
    [float]$backH = [float][Math]::Max(26.0, 40.0 * $s)
    [float]$backX = [float]($panelX + $panelW - $backW - (32.0 * $s))
    [float]$backY = [float]($panelY + $panelH - $backH - (22.0 * $s))

    return [PSCustomObject]@{
        Scale = [float]$s
        Window = New-MenuRect -X 0 -Y 0 -Width $WindowWidth -Height $WindowHeight
        Panel = New-MenuRect -X $panelX -Y $panelY -Width $panelW -Height $panelH
        HeaderRect = New-MenuRect -X $panelX -Y $panelY -Width $panelW -Height $headerH
        MenuRowX = [float]$menuRowX
        MenuRowY = [float]$menuRowY
        MenuRowWidth = [float]$menuRowW
        MenuRowHeight = [float]$menuRowH
        MenuRowGap = [float]$menuRowGap
        SettingsTabX = [float]$tabX
        SettingsTabY = [float]$tabY
        SettingsTabWidth = [float]$tabW
        SettingsTabHeight = [float]$tabH
        SettingsTabGap = [float]$tabGap
        SettingsRowX = [float]$settingRowX
        SettingsRowY = [float]$settingRowY
        SettingsRowWidth = [float]$settingRowW
        SettingsRowHeight = [float]$settingRowH
        SettingsRowGap = [float]$settingRowGap
        SettingsBackRect = New-MenuRect -X $backX -Y $backY -Width $backW -Height $backH
    }
}

function Get-MenuSettingsSchema {
    param([string]$Category)

    switch ([string]$Category) {
        'Controls' {
            return @(
                [PSCustomObject]@{ Id = 'MoveForward'; Label = 'Move Forward Key'; Type = 'Choice'; DataType = 'String'; Min = [double]0.0; Max = [double]0.0; Step = [double]1.0 },
                [PSCustomObject]@{ Id = 'Jump'; Label = 'Jump Key'; Type = 'Choice'; DataType = 'String'; Min = [double]0.0; Max = [double]0.0; Step = [double]1.0 },
                [PSCustomObject]@{ Id = 'Inventory'; Label = 'Inventory Key'; Type = 'Choice'; DataType = 'String'; Min = [double]0.0; Max = [double]0.0; Step = [double]1.0 }
            )
        }
        'Audio' {
            return @(
                [PSCustomObject]@{ Id = 'MasterVolume'; Label = 'Master Volume'; Type = 'Range'; DataType = 'Int'; Min = [double]0.0; Max = [double]100.0; Step = [double]5.0 },
                [PSCustomObject]@{ Id = 'MusicVolume'; Label = 'Music Volume'; Type = 'Range'; DataType = 'Int'; Min = [double]0.0; Max = [double]100.0; Step = [double]5.0 },
                [PSCustomObject]@{ Id = 'EffectsVolume'; Label = 'Effects Volume'; Type = 'Range'; DataType = 'Int'; Min = [double]0.0; Max = [double]100.0; Step = [double]5.0 }
            )
        }
        'Video' {
            return @(
                [PSCustomObject]@{ Id = 'Resolution'; Label = 'Resolution'; Type = 'Choice'; DataType = 'String'; Min = [double]0.0; Max = [double]0.0; Step = [double]1.0 },
                [PSCustomObject]@{ Id = 'VSync'; Label = 'Vertical Sync'; Type = 'Toggle'; DataType = 'Bool'; Min = [double]0.0; Max = [double]1.0; Step = [double]1.0 },
                [PSCustomObject]@{ Id = 'RenderDistance'; Label = 'Render Distance'; Type = 'Range'; DataType = 'Int'; Min = [double]2.0; Max = [double]8.0; Step = [double]1.0 }
            )
        }
        default {
            return @()
        }
    }
}

function Get-MenuSettingValue {
    param(
        [string]$Category,
        [string]$SettingId,
        $Default = $null
    )

    if (-not $script:MenuSettingsValues.ContainsKey($Category)) {
        return $Default
    }

    $categoryValues = $script:MenuSettingsValues[$Category]
    if ($null -eq $categoryValues) {
        return $Default
    }

    if ($categoryValues.ContainsKey($SettingId)) {
        return $categoryValues[$SettingId]
    }

    return $Default
}

function Set-MenuSettingValue {
    param(
        [string]$Category,
        [string]$SettingId,
        $Value
    )

    if (-not $script:MenuSettingsValues.ContainsKey($Category)) {
        return $false
    }

    $categoryValues = $script:MenuSettingsValues[$Category]
    if ($null -eq $categoryValues) {
        return $false
    }

    $categoryValues[$SettingId] = $Value
    return $true
}

function Get-MenuRangeNormalized {
    param(
        [double]$Value,
        [double]$Min,
        [double]$Max
    )

    if ($Max -le $Min) {
        return [float]0.0
    }

    [double]$ratio = ($Value - $Min) / ($Max - $Min)
    return (Clamp-Menu01 -Value $ratio)
}

function Get-MenuSettingsRows {
    param([string]$Category)

    $rows = @()
    $schema = Get-MenuSettingsSchema -Category $Category

    foreach ($entry in @($schema)) {
        if ($null -eq $entry) { continue }

        [string]$id = [string]$entry.Id
        [string]$label = [string]$entry.Label
        [string]$type = [string]$entry.Type
        [string]$dataType = [string]$entry.DataType
        [double]$min = [double]$entry.Min
        [double]$max = [double]$entry.Max
        [double]$step = [double]$entry.Step

        $rawValue = Get-MenuSettingValue -Category $Category -SettingId $id
        [string]$display = ''
        [float]$normalized = [float]0.0

        if ($type -eq 'Toggle') {
            [bool]$toggleValue = [bool]$rawValue
            $display = if ($toggleValue) { 'On' } else { 'Off' }
            $normalized = if ($toggleValue) { [float]1.0 } else { [float]0.0 }
            $rawValue = [bool]$toggleValue
        }
        elseif ($type -eq 'Choice') {
            [string]$stringValue = [string]$rawValue
            $options = Get-MenuChoiceOptions -Category $Category -SettingId $id
            if ($options.Count -le 0) {
                if ([string]::IsNullOrWhiteSpace($stringValue)) {
                    $stringValue = ''
                }
            }
            else {
                [int]$choiceIndex = [Array]::IndexOf([object[]]$options, [object]$stringValue)
                if ($choiceIndex -lt 0) {
                    $choiceIndex = [int]0
                    $stringValue = [string]$options[0]
                }
                $normalized = Get-MenuRangeNormalized -Value ([double]$choiceIndex) -Min 0.0 -Max ([double]([Math]::Max(1, $options.Count - 1)))
            }

            $rawValue = [string]$stringValue
            $display = [string]$stringValue
        }
        else {
            [double]$number = [double]$rawValue
            if ($number -lt $min) { $number = [double]$min }
            if ($number -gt $max) { $number = [double]$max }

            if ($dataType -eq 'Int') {
                [int]$intValue = [int]([Math]::Round($number, 0))
                $rawValue = [int]$intValue
                $display = [string]$intValue
                $normalized = Get-MenuRangeNormalized -Value ([double]$intValue) -Min $min -Max $max
            }
            else {
                [double]$rounded = [Math]::Round($number, 2)
                $rawValue = [float]$rounded
                $display = [string]$rounded
                $normalized = Get-MenuRangeNormalized -Value $rounded -Min $min -Max $max
            }
        }

        $rows += [PSCustomObject]@{
            Category = [string]$Category
            Id = [string]$id
            Label = [string]$label
            Type = [string]$type
            DataType = [string]$dataType
            Value = $rawValue
            DisplayValue = [string]$display
            Min = [double]$min
            Max = [double]$max
            Step = [double]$step
            Normalized = [float]$normalized
        }
    }

    return @($rows)
}

function Ensure-MenuSettingsCategory {
    if ($script:MenuSettingsCategoryOrder.Count -le 0) {
        $script:MenuSettingsCategoryOrder = @('Controls', 'Audio', 'Video')
    }

    if ($script:MenuSettingsCategoryOrder -notcontains [string]$script:MenuSelectedSettingsCategory) {
        $script:MenuSelectedSettingsCategory = [string]$script:MenuSettingsCategoryOrder[0]
    }
}

function Set-MenuSettingsCategory {
    param([string]$Category)

    Ensure-MenuSettingsCategory
    if ([string]::IsNullOrWhiteSpace($Category)) {
        return $script:MenuSelectedSettingsCategory
    }

    if ($script:MenuSettingsCategoryOrder -contains [string]$Category) {
        $script:MenuSelectedSettingsCategory = [string]$Category
    }

    return $script:MenuSelectedSettingsCategory
}

function Cycle-MenuSettingsCategory {
    param([int]$Delta)

    Ensure-MenuSettingsCategory

    [int]$count = [int]$script:MenuSettingsCategoryOrder.Count
    if ($count -le 0) {
        return [string]$script:MenuSelectedSettingsCategory
    }

    [int]$index = [Array]::IndexOf([string[]]$script:MenuSettingsCategoryOrder, [string]$script:MenuSelectedSettingsCategory)
    if ($index -lt 0) { $index = 0 }

    [int]$newIndex = [int](($index + $Delta) % $count)
    if ($newIndex -lt 0) { $newIndex += $count }

    $script:MenuSelectedSettingsCategory = [string]$script:MenuSettingsCategoryOrder[$newIndex]
    return [string]$script:MenuSelectedSettingsCategory
}

function Set-MenuPauseState {
    param(
        [bool]$Paused,
        [string]$Reason = 'MenuPauseState'
    )

    $script:MenuPaused = [bool]$Paused
    $script:MenuPauseReason = [string]$Reason

    [bool]$capture = (-not $script:MenuPaused -and $script:MenuGameplayStarted)
    if (Get-Command -Name Set-MouseCapture -ErrorAction SilentlyContinue) {
        try {
            Set-MouseCapture -Captured $capture
        }
        catch {
            # Keep menu deterministic even if input module is not active.
        }
    }
}

function Start-MenuTransition {
    param(
        [string]$FromView,
        [string]$ToView,
        [string]$Reason = 'Transition'
    )

    $script:MenuTransition = [PSCustomObject]@{
        Active = $true
        Progress = [float]0.0
        Elapsed = [float]0.0
        Duration = Clamp-MenuPositive -Value ([double]$script:MenuTransitionDuration) -Fallback 0.18
        FromView = [string]$FromView
        ToView = [string]$ToView
        Reason = [string]$Reason
    }
}

function Update-MenuTransition {
    param([float]$DeltaSeconds)

    if (-not [bool]$script:MenuTransition.Active) {
        return
    }

    [float]$dt = [float]$DeltaSeconds
    if ($dt -lt 0.0) { $dt = [float]0.0 }
    if ($dt -gt 0.1) { $dt = [float]0.1 }

    $script:MenuTransition.Elapsed = [float]([double]$script:MenuTransition.Elapsed + [double]$dt)

    [float]$duration = Clamp-MenuPositive -Value ([double]$script:MenuTransition.Duration) -Fallback 0.18
    [float]$progress = Clamp-Menu01 -Value (([double]$script:MenuTransition.Elapsed) / ([double]$duration))
    $script:MenuTransition.Progress = [float]$progress

    if ($progress -ge 1.0) {
        $script:MenuTransition.Active = $false
    }
}

function Set-MenuView {
    param(
        [ValidateSet('Hidden', 'Main', 'Pause', 'Settings')]
        [string]$View,
        [string]$Reason = 'SetMenuView'
    )

    [string]$fromView = [string]$script:MenuCurrentView
    if ($fromView -eq $View) {
        return
    }

    $script:MenuPreviousView = [string]$fromView
    if ($fromView -ne 'Hidden') {
        $script:MenuLastVisibleView = [string]$fromView
    }

    $script:MenuCurrentView = [string]$View
    if ($View -ne 'Hidden') {
        $script:MenuLastVisibleView = [string]$View
    }

    Start-MenuTransition -FromView $fromView -ToView $View -Reason $Reason

    if ($View -eq 'Hidden') {
        Set-MenuPauseState -Paused $false -Reason $Reason
    }
    else {
        Set-MenuPauseState -Paused $true -Reason $Reason
    }
}

function Set-MenuMainSelection {
    param([int]$Index)

    [int]$count = [int]$script:MenuMainItems.Count
    if ($count -le 0) {
        $script:MenuSelectionMainIndex = [int]0
        return
    }

    [int]$i = [int]($Index % $count)
    if ($i -lt 0) { $i += $count }
    $script:MenuSelectionMainIndex = [int]$i
}

function Set-MenuPauseSelection {
    param([int]$Index)

    [int]$count = [int]$script:MenuPauseItems.Count
    if ($count -le 0) {
        $script:MenuSelectionPauseIndex = [int]0
        return
    }

    [int]$i = [int]($Index % $count)
    if ($i -lt 0) { $i += $count }
    $script:MenuSelectionPauseIndex = [int]$i
}

function Set-MenuSettingsRowSelection {
    param(
        [string]$Category,
        [int]$Index,
        [int]$MaxIndex
    )

    if (-not $script:MenuSettingsRowSelection.ContainsKey($Category)) {
        $script:MenuSettingsRowSelection[$Category] = [int]0
    }

    [int]$count = [int]($MaxIndex + 1)
    if ($count -le 0) {
        $script:MenuSettingsRowSelection[$Category] = [int]0
        return [int]0
    }

    [int]$next = [int]($Index % $count)
    if ($next -lt 0) { $next += $count }
    $script:MenuSettingsRowSelection[$Category] = [int]$next
    return [int]$next
}

function Set-MenuActionResult {
    param(
        [string]$Action,
        [string]$Source,
        [bool]$Success,
        [string]$Reason
    )

    $script:MenuLastAction = [PSCustomObject]@{
        Action = [string]$Action
        Source = [string]$Source
        Success = [bool]$Success
        Reason = [string]$Reason
        View = [string]$script:MenuCurrentView
        TimestampUtc = [DateTime]::UtcNow
    }

    return $script:MenuLastAction
}

function Invoke-MenuAction {
    param(
        [string]$Action,
        [string]$Source = 'Internal'
    )

    switch ([string]$Action) {
        'Start' {
            $script:MenuGameplayStarted = $true
            Set-MenuView -View 'Hidden' -Reason 'StartAction'
            return (Set-MenuActionResult -Action 'Start' -Source $Source -Success $true -Reason 'GameplayStarted')
        }
        'Resume' {
            if (-not $script:MenuGameplayStarted) {
                $script:MenuGameplayStarted = $true
            }
            Set-MenuView -View 'Hidden' -Reason 'ResumeAction'
            return (Set-MenuActionResult -Action 'Resume' -Source $Source -Success $true -Reason 'GameplayResumed')
        }
        'OpenPause' {
            if (-not $script:MenuGameplayStarted) {
                Set-MenuView -View 'Main' -Reason 'OpenPauseWithoutGameplay'
                return (Set-MenuActionResult -Action 'OpenPause' -Source $Source -Success $false -Reason 'GameplayNotStarted')
            }

            Set-MenuView -View 'Pause' -Reason 'PauseOpened'
            return (Set-MenuActionResult -Action 'OpenPause' -Source $Source -Success $true -Reason 'PauseOpened')
        }
        'OpenSettings' {
            if ($script:MenuCurrentView -eq 'Main' -or $script:MenuCurrentView -eq 'Pause') {
                $script:MenuSettingsReturnView = [string]$script:MenuCurrentView
            }
            elseif ([string]::IsNullOrWhiteSpace([string]$script:MenuSettingsReturnView)) {
                $script:MenuSettingsReturnView = if ($script:MenuGameplayStarted) { 'Pause' } else { 'Main' }
            }

            Set-MenuView -View 'Settings' -Reason 'OpenSettings'
            return (Set-MenuActionResult -Action 'OpenSettings' -Source $Source -Success $true -Reason 'SettingsOpened')
        }
        'BackFromSettings' {
            [string]$target = [string]$script:MenuSettingsReturnView
            if ([string]::IsNullOrWhiteSpace($target) -or ($target -ne 'Main' -and $target -ne 'Pause')) {
                $target = if ($script:MenuGameplayStarted) { 'Pause' } else { 'Main' }
            }

            Set-MenuView -View $target -Reason 'SettingsBack'
            return (Set-MenuActionResult -Action 'BackFromSettings' -Source $Source -Success $true -Reason 'ReturnedFromSettings')
        }
        'Exit' {
            $script:MenuExitRequested = $true
            [bool]$closed = $false

            if (Get-Command -Name Get-MainForm -ErrorAction SilentlyContinue) {
                try {
                    $form = Get-MainForm
                    if ($null -ne $form -and $null -ne $form.PSObject.Methods['Close']) {
                        $form.Close()
                        $closed = $true
                    }
                }
                catch {
                    $closed = $false
                }
            }

            [string]$reason = if ($closed) { 'ExitRequestedAndWindowCloseCalled' } else { 'ExitRequestedNoWindowClose' }
            return (Set-MenuActionResult -Action 'Exit' -Source $Source -Success $true -Reason $reason)
        }
        default {
            return (Set-MenuActionResult -Action ([string]$Action) -Source $Source -Success $false -Reason 'UnknownAction')
        }
    }
}

function Invoke-MenuSettingsAdjustment {
    param(
        [string]$Category,
        [string]$SettingId,
        [int]$Direction = 1,
        [string]$Source = 'Internal'
    )

    $schema = Get-MenuSettingsSchema -Category $Category
    $entry = $null
    foreach ($candidate in @($schema)) {
        if ($null -eq $candidate) { continue }
        if ([string]$candidate.Id -eq [string]$SettingId) {
            $entry = $candidate
            break
        }
    }

    if ($null -eq $entry) {
        return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $false -Reason 'SettingSchemaMissing')
    }

    [string]$type = [string]$entry.Type
    [string]$dataType = [string]$entry.DataType
    [double]$min = [double]$entry.Min
    [double]$max = [double]$entry.Max
    [double]$step = [double]$entry.Step

    if ($type -eq 'Toggle') {
        [bool]$current = [bool](Get-MenuSettingValue -Category $Category -SettingId $SettingId -Default $false)
        [bool]$next = -not $current
        [void](Set-MenuSettingValue -Category $Category -SettingId $SettingId -Value $next)

        if (Get-Command -Name Set-SettingValue -ErrorAction SilentlyContinue) {
            [void](Set-SettingValue -Category $Category -Name $SettingId -Value $next -Save -ApplyRuntime)
            Import-MenuSettingsFromPersistence | Out-Null
        }

        return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $true -Reason ('{0}.{1}={2}' -f $Category, $SettingId, $next))
    }

    if ($type -eq 'Choice') {
        [string]$currentValue = [string](Get-MenuSettingValue -Category $Category -SettingId $SettingId -Default '')
        $options = Get-MenuChoiceOptions -Category $Category -SettingId $SettingId
        if ($options.Count -le 0) {
            return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $false -Reason 'ChoiceOptionsMissing')
        }

        [int]$currentIndex = [Array]::IndexOf([object[]]$options, [object]$currentValue)
        if ($currentIndex -lt 0) { $currentIndex = [int]0 }

        [int]$nextIndex = [int](($currentIndex + $Direction) % $options.Count)
        if ($nextIndex -lt 0) { $nextIndex += $options.Count }

        [string]$nextValue = [string]$options[$nextIndex]
        [void](Set-MenuSettingValue -Category $Category -SettingId $SettingId -Value $nextValue)

        if (Get-Command -Name Set-SettingValue -ErrorAction SilentlyContinue) {
            [void](Set-SettingValue -Category $Category -Name $SettingId -Value $nextValue -Save -ApplyRuntime)
            Import-MenuSettingsFromPersistence | Out-Null
        }

        return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $true -Reason ('{0}.{1}={2}' -f $Category, $SettingId, $nextValue))
    }

    [double]$currentNumber = [double](Get-MenuSettingValue -Category $Category -SettingId $SettingId -Default $min)
    [double]$nextNumber = $currentNumber + ($step * [double]$Direction)

    if ($nextNumber -gt $max) { $nextNumber = [double]$min }
    if ($nextNumber -lt $min) { $nextNumber = [double]$max }

    if ($dataType -eq 'Int') {
        [int]$intValue = [int]([Math]::Round($nextNumber, 0))
        [void](Set-MenuSettingValue -Category $Category -SettingId $SettingId -Value $intValue)

        if (Get-Command -Name Set-SettingValue -ErrorAction SilentlyContinue) {
            [void](Set-SettingValue -Category $Category -Name $SettingId -Value $intValue -Save -ApplyRuntime)
            Import-MenuSettingsFromPersistence | Out-Null
        }

        return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $true -Reason ('{0}.{1}={2}' -f $Category, $SettingId, $intValue))
    }

    [float]$floatValue = [float]([Math]::Round($nextNumber, 2))
    [void](Set-MenuSettingValue -Category $Category -SettingId $SettingId -Value $floatValue)

    if (Get-Command -Name Set-SettingValue -ErrorAction SilentlyContinue) {
        [void](Set-SettingValue -Category $Category -Name $SettingId -Value $floatValue -Save -ApplyRuntime)
        Import-MenuSettingsFromPersistence | Out-Null
    }

    return (Set-MenuActionResult -Action 'AdjustSetting' -Source $Source -Success $true -Reason ('{0}.{1}={2}' -f $Category, $SettingId, $floatValue))
}

function Build-MenuReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    Ensure-MenuSettingsCategory

    $metrics = Get-MenuHUDMetrics
    $layout = Get-MenuLayout -Scale ([float]$metrics.Scale) -WindowWidth ([float]$metrics.WindowWidth) -WindowHeight ([float]$metrics.WindowHeight)

    Set-MenuMainSelection -Index ([int]$script:MenuSelectionMainIndex)
    Set-MenuPauseSelection -Index ([int]$script:MenuSelectionPauseIndex)

    [string]$selectedCategory = [string]$script:MenuSelectedSettingsCategory
    $settingsRowsBase = Get-MenuSettingsRows -Category $selectedCategory

    [int]$settingsMaxIndex = [int]$settingsRowsBase.Count
    if ($settingsMaxIndex -lt 0) { $settingsMaxIndex = 0 }

    if (-not $script:MenuSettingsRowSelection.ContainsKey($selectedCategory)) {
        $script:MenuSettingsRowSelection[$selectedCategory] = [int]0
    }

    [int]$selectedSettingsRow = Set-MenuSettingsRowSelection -Category $selectedCategory -Index ([int]$script:MenuSettingsRowSelection[$selectedCategory]) -MaxIndex $settingsMaxIndex

    $mainRows = @()
    for ($i = 0; $i -lt $script:MenuMainItems.Count; $i++) {
        $item = $script:MenuMainItems[$i]
        $rect = New-MenuRect -X ([float]$layout.MenuRowX) -Y ([float]($layout.MenuRowY + ($i * ($layout.MenuRowHeight + $layout.MenuRowGap)))) -Width ([float]$layout.MenuRowWidth) -Height ([float]$layout.MenuRowHeight)
        [bool]$isHovered = Test-MenuPointInRect -X $CursorX -Y $CursorY -Rect $rect
        $mainRows += [PSCustomObject]@{
            Index = [int]$i
            Id = [string]$item.Id
            Label = [string]$item.Label
            Action = [string]$item.Action
            Rect = $rect
            IsSelected = ([int]$i -eq [int]$script:MenuSelectionMainIndex)
            IsHovered = [bool]$isHovered
        }
    }

    $pauseRows = @()
    for ($i = 0; $i -lt $script:MenuPauseItems.Count; $i++) {
        $item = $script:MenuPauseItems[$i]
        $rect = New-MenuRect -X ([float]$layout.MenuRowX) -Y ([float]($layout.MenuRowY + ($i * ($layout.MenuRowHeight + $layout.MenuRowGap)))) -Width ([float]$layout.MenuRowWidth) -Height ([float]$layout.MenuRowHeight)
        [bool]$isHovered = Test-MenuPointInRect -X $CursorX -Y $CursorY -Rect $rect
        $pauseRows += [PSCustomObject]@{
            Index = [int]$i
            Id = [string]$item.Id
            Label = [string]$item.Label
            Action = [string]$item.Action
            Rect = $rect
            IsSelected = ([int]$i -eq [int]$script:MenuSelectionPauseIndex)
            IsHovered = [bool]$isHovered
        }
    }

    $settingsTabs = @()
    [int]$tabCount = [int]$script:MenuSettingsCategoryOrder.Count
    [float]$tabSlotWidth = [float]$layout.SettingsTabWidth
    if ($tabCount -gt 0) {
        $tabSlotWidth = [float](($layout.SettingsTabWidth - (($tabCount - 1) * $layout.SettingsTabGap)) / $tabCount)
        if ($tabSlotWidth -lt 8.0) { $tabSlotWidth = [float]8.0 }
    }

    for ($i = 0; $i -lt $tabCount; $i++) {
        [string]$category = [string]$script:MenuSettingsCategoryOrder[$i]
        $tabRect = New-MenuRect -X ([float]($layout.SettingsTabX + ($i * ($tabSlotWidth + $layout.SettingsTabGap)))) -Y ([float]$layout.SettingsTabY) -Width $tabSlotWidth -Height ([float]$layout.SettingsTabHeight)
        [bool]$hovered = Test-MenuPointInRect -X $CursorX -Y $CursorY -Rect $tabRect

        $settingsTabs += [PSCustomObject]@{
            Index = [int]$i
            Name = [string]$category
            Rect = $tabRect
            IsSelected = ([string]$category -eq [string]$selectedCategory)
            IsHovered = [bool]$hovered
        }
    }

    $settingsRows = @()
    for ($i = 0; $i -lt $settingsRowsBase.Count; $i++) {
        $entry = $settingsRowsBase[$i]
        $rowRect = New-MenuRect -X ([float]$layout.SettingsRowX) -Y ([float]($layout.SettingsRowY + ($i * ($layout.SettingsRowHeight + $layout.SettingsRowGap)))) -Width ([float]$layout.SettingsRowWidth) -Height ([float]$layout.SettingsRowHeight)
        [bool]$hovered = Test-MenuPointInRect -X $CursorX -Y $CursorY -Rect $rowRect

        $settingsRows += [PSCustomObject]@{
            Index = [int]$i
            Category = [string]$entry.Category
            Id = [string]$entry.Id
            Label = [string]$entry.Label
            Type = [string]$entry.Type
            DataType = [string]$entry.DataType
            Value = $entry.Value
            DisplayValue = [string]$entry.DisplayValue
            Min = [double]$entry.Min
            Max = [double]$entry.Max
            Step = [double]$entry.Step
            Normalized = [float]$entry.Normalized
            Rect = $rowRect
            IsSelected = ([int]$i -eq [int]$selectedSettingsRow)
            IsHovered = [bool]$hovered
        }
    }

    $backRect = $layout.SettingsBackRect
    [bool]$backHovered = Test-MenuPointInRect -X $CursorX -Y $CursorY -Rect $backRect
    [bool]$backSelected = ([int]$selectedSettingsRow -eq [int]$settingsRows.Count)

    [string]$visibleView = 'None'
    if ($script:MenuCurrentView -eq 'Hidden') {
        if ([bool]$script:MenuTransition.Active -and [string]$script:MenuTransition.FromView -ne 'Hidden') {
            $visibleView = [string]$script:MenuTransition.FromView
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$script:MenuLastVisibleView)) {
            $visibleView = [string]$script:MenuLastVisibleView
        }
    }
    else {
        $visibleView = [string]$script:MenuCurrentView
    }

    [string]$hoverKind = 'None'
    [int]$hoverIndex = -1
    [string]$hoverId = ''
    [string]$hoverLabel = ''
    [string]$hoverCategory = ''
    [string]$hoverAction = ''

    switch ([string]$script:MenuCurrentView) {
        'Main' {
            foreach ($row in $mainRows) {
                if ($null -eq $row) { continue }
                if ([bool]$row.IsHovered) {
                    $hoverKind = 'MainItem'
                    $hoverIndex = [int]$row.Index
                    $hoverId = [string]$row.Id
                    $hoverLabel = [string]$row.Label
                    $hoverAction = [string]$row.Action
                    break
                }
            }
        }
        'Pause' {
            foreach ($row in $pauseRows) {
                if ($null -eq $row) { continue }
                if ([bool]$row.IsHovered) {
                    $hoverKind = 'PauseItem'
                    $hoverIndex = [int]$row.Index
                    $hoverId = [string]$row.Id
                    $hoverLabel = [string]$row.Label
                    $hoverAction = [string]$row.Action
                    break
                }
            }
        }
        'Settings' {
            foreach ($tab in $settingsTabs) {
                if ($null -eq $tab) { continue }
                if ([bool]$tab.IsHovered) {
                    $hoverKind = 'SettingsCategory'
                    $hoverIndex = [int]$tab.Index
                    $hoverId = [string]$tab.Name
                    $hoverLabel = [string]$tab.Name
                    $hoverCategory = [string]$tab.Name
                    break
                }
            }

            if ($hoverKind -eq 'None') {
                foreach ($row in $settingsRows) {
                    if ($null -eq $row) { continue }
                    if ([bool]$row.IsHovered) {
                        $hoverKind = 'SettingsRow'
                        $hoverIndex = [int]$row.Index
                        $hoverId = [string]$row.Id
                        $hoverLabel = [string]$row.Label
                        $hoverCategory = [string]$row.Category
                        break
                    }
                }
            }

            if ($hoverKind -eq 'None' -and $backHovered) {
                $hoverKind = 'SettingsBack'
                $hoverIndex = [int]$settingsRows.Count
                $hoverId = 'settings_back'
                $hoverLabel = 'Back'
            }
        }
    }

    return [PSCustomObject]@{
        Initialized = [bool]$script:MenuInitialized
        UpdateRegistered = [bool]$script:MenuUpdateRegistered
        RenderRegistered = [bool]$script:MenuRenderRegistered
        View = [string]$script:MenuCurrentView
        VisibleView = [string]$visibleView
        PreviousView = [string]$script:MenuPreviousView
        GameplayStarted = [bool]$script:MenuGameplayStarted
        Paused = [bool]$script:MenuPaused
        PauseReason = [string]$script:MenuPauseReason
        ExitRequested = [bool]$script:MenuExitRequested
        Cursor = [PSCustomObject]@{
            X = [float]$CursorX
            Y = [float]$CursorY
        }
        Layout = $layout
        Navigation = [PSCustomObject]@{
            MainSelectedIndex = [int]$script:MenuSelectionMainIndex
            PauseSelectedIndex = [int]$script:MenuSelectionPauseIndex
            SettingsCategory = [string]$selectedCategory
            SettingsSelectedRowIndex = [int]$selectedSettingsRow
        }
        MainMenu = [PSCustomObject]@{
            Visible = ([string]$script:MenuCurrentView -eq 'Main')
            Items = @($mainRows)
        }
        PauseMenu = [PSCustomObject]@{
            Visible = ([string]$script:MenuCurrentView -eq 'Pause')
            Items = @($pauseRows)
        }
        Settings = [PSCustomObject]@{
            Visible = ([string]$script:MenuCurrentView -eq 'Settings')
            ReturnView = [string]$script:MenuSettingsReturnView
            Categories = @($settingsTabs)
            Rows = @($settingsRows)
            BackButtonRect = $backRect
            BackButtonHovered = [bool]$backHovered
            BackButtonSelected = [bool]$backSelected
            Persistence = [string]$script:MenuSettingsPersistenceStatus
            Values = [PSCustomObject]@{
                Controls = [PSCustomObject]@{
                    MoveForward = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'MoveForward' -Default 'W')
                    Jump = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'Jump' -Default 'Space')
                    Inventory = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'Inventory' -Default 'E')
                }
                Audio = [PSCustomObject]@{
                    MasterVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'MasterVolume' -Default 85)
                    MusicVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'MusicVolume' -Default 70)
                    EffectsVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'EffectsVolume' -Default 80)
                    AudioBackendAvailable = [bool](Get-MenuSettingValue -Category 'Audio' -SettingId 'AudioBackendAvailable' -Default $false)
                }
                Video = [PSCustomObject]@{
                    Resolution = [string](Get-MenuSettingValue -Category 'Video' -SettingId 'Resolution' -Default '1024x768')
                    VSync = [bool](Get-MenuSettingValue -Category 'Video' -SettingId 'VSync' -Default $true)
                    RenderDistance = [int](Get-MenuSettingValue -Category 'Video' -SettingId 'RenderDistance' -Default 4)
                }
            }
        }
        Hover = [PSCustomObject]@{
            Kind = [string]$hoverKind
            Index = [int]$hoverIndex
            Id = [string]$hoverId
            Label = [string]$hoverLabel
            Category = [string]$hoverCategory
            Action = [string]$hoverAction
        }
        Transition = [PSCustomObject]@{
            Active = [bool]$script:MenuTransition.Active
            Progress = [float]$script:MenuTransition.Progress
            FromView = [string]$script:MenuTransition.FromView
            ToView = [string]$script:MenuTransition.ToView
            Duration = [float]$script:MenuTransition.Duration
            Reason = [string]$script:MenuTransition.Reason
        }
        LastAction = $script:MenuLastAction
        LastRender = $script:MenuLastRender
    }
}

function Refresh-MenuReadModel {
    param(
        [float]$CursorX,
        [float]$CursorY
    )

    $script:MenuReadModel = Build-MenuReadModel -CursorX $CursorX -CursorY $CursorY
    if ($null -ne $script:MenuReadModel) {
        $script:MenuReadModel.LastRender = $script:MenuLastRender
    }

    return $script:MenuReadModel
}

function Draw-MenuRectInternal {
    param(
        $Rect,
        [float]$OffsetX,
        [float]$OffsetY,
        [float]$Z,
        $Color,
        [float]$AlphaMultiplier = 1.0
    )

    if ($null -eq $Rect) { return [int]0 }
    if ($null -eq $Color) { return [int]0 }

    [float]$alpha = Clamp-Menu01 -Value (([double]$Color.A) * ([double]$AlphaMultiplier))
    if ($alpha -le 0.0) { return [int]0 }

    Draw-HUDRect -X ([float]($Rect.X + $OffsetX)) -Y ([float]($Rect.Y + $OffsetY)) -Width ([float]$Rect.Width) -Height ([float]$Rect.Height) -Z $Z -R ([float]$Color.R) -G ([float]$Color.G) -B ([float]$Color.B) -A $alpha
    return [int]1
}

function Get-MenuVisualTransitionState {
    [float]$alpha = [float]0.0
    [float]$offsetY = [float]0.0

    [string]$fromView = [string]$script:MenuTransition.FromView
    [string]$toView = [string]$script:MenuTransition.ToView
    [float]$progress = Clamp-Menu01 -Value ([double]$script:MenuTransition.Progress)

    if ([bool]$script:MenuTransition.Active) {
        if ($fromView -eq 'Hidden' -and $toView -ne 'Hidden') {
            $alpha = [float]$progress
            $offsetY = [float]((1.0 - $progress) * 24.0)
        }
        elseif ($toView -eq 'Hidden' -and $fromView -ne 'Hidden') {
            $alpha = [float](1.0 - $progress)
            $offsetY = [float]($progress * 16.0)
        }
        else {
            $alpha = [float]1.0
            $offsetY = [float]0.0
        }
    }
    else {
        if ($script:MenuCurrentView -eq 'Hidden') {
            $alpha = [float]0.0
        }
        else {
            $alpha = [float]1.0
        }
    }

    $alpha = Clamp-Menu01 -Value ([double]$alpha)

    return [PSCustomObject]@{
        Alpha = [float]$alpha
        OffsetY = [float]$offsetY
        OffsetX = [float]0.0
    }
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-Menu {
    <#
    .SYNOPSIS
        Initializes deterministic menu state and callback wiring.
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

    $script:MenuCurrentView = 'Main'
    $script:MenuPreviousView = 'Main'
    $script:MenuLastVisibleView = 'Main'
    $script:MenuSettingsReturnView = 'Main'

    $script:MenuGameplayStarted = $false
    $script:MenuExitRequested = $false

    $script:MenuSelectionMainIndex = [int]0
    $script:MenuSelectionPauseIndex = [int]0
    $script:MenuSelectedSettingsCategory = 'Controls'
    $script:MenuSettingsRowSelection['Controls'] = [int]0
    $script:MenuSettingsRowSelection['Audio'] = [int]0
    $script:MenuSettingsRowSelection['Video'] = [int]0

    $script:MenuSettingsValues['Controls']['MoveForward'] = 'W'
    $script:MenuSettingsValues['Controls']['Jump'] = 'Space'
    $script:MenuSettingsValues['Controls']['Inventory'] = 'E'
    $script:MenuSettingsValues['Audio']['MasterVolume'] = [int]85
    $script:MenuSettingsValues['Audio']['MusicVolume'] = [int]70
    $script:MenuSettingsValues['Audio']['EffectsVolume'] = [int]80
    $script:MenuSettingsValues['Audio']['AudioBackendAvailable'] = $false
    $script:MenuSettingsValues['Video']['Resolution'] = '1024x768'
    $script:MenuSettingsValues['Video']['VSync'] = $true
    $script:MenuSettingsValues['Video']['RenderDistance'] = [int]4

    Import-MenuSettingsFromPersistence | Out-Null

    $script:MenuTransition = [PSCustomObject]@{
        Active = $false
        Progress = [float]1.0
        Elapsed = [float]0.0
        Duration = Clamp-MenuPositive -Value ([double]$script:MenuTransitionDuration) -Fallback 0.18
        FromView = 'Main'
        ToView = 'Main'
        Reason = 'Initialized'
    }

    $script:MenuLastAction = [PSCustomObject]@{
        Action = 'None'
        Source = 'None'
        Success = $false
        Reason = 'NotAttempted'
        View = 'Main'
        TimestampUtc = [DateTime]::MinValue
    }

    $script:MenuLastRender = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
        DrawCallEstimate = [int]0
        View = 'Main'
        VisibleView = 'Main'
        TransitionActive = $false
        TransitionProgress = [float]1.0
    }

    $script:MenuLeftMouseWasHeld = $false
    $script:MenuInitialized = $true

    Set-MenuPauseState -Paused $true -Reason 'InitializeMenu'

    if (-not $script:MenuUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-Menu}
            $script:MenuUpdateRegistered = $true
            Write-Host '[Menu] Update callback registered.' -ForegroundColor DarkGray
        }
    }

    if (-not $script:MenuRenderRegistered) {
        if (Get-Command -Name Register-RenderCallback -ErrorAction SilentlyContinue) {
            Register-RenderCallback ${function:Render-Menu}
            $script:MenuRenderRegistered = $true
            Write-Host '[Menu] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    $mouse = Get-MenuMousePositionInternal
    Refresh-MenuReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y) | Out-Null

    Write-Host '[Menu] Menu system initialized.' -ForegroundColor Green
}

function Update-Menu {
    <#
    .SYNOPSIS
        Per-frame menu update for keyboard/mouse navigation and actions.
    #>
    param($dt)

    if (-not $script:MenuInitialized) {
        return
    }

    [float]$step = [float]0.016
    if ($null -ne $dt) {
        $step = [float]$dt
    }
    if ($step -lt 0.0) { $step = [float]0.0 }
    if ($step -gt 0.1) { $step = [float]0.1 }

    Update-MenuTransition -DeltaSeconds $step

    $mouse = Get-MenuMousePositionInternal
    [float]$cursorX = [float]$mouse.X
    [float]$cursorY = [float]$mouse.Y

    Refresh-MenuReadModel -CursorX $cursorX -CursorY $cursorY | Out-Null

    [bool]$leftHeld = Get-MenuMouseButtonHeldInternal -Button 0
    [bool]$leftDown = Get-MenuMouseButtonDownInternal -Button 0
    if (-not $leftDown -and $leftHeld -and -not $script:MenuLeftMouseWasHeld) {
        $leftDown = $true
    }

    [bool]$escapeDown = (Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Escape))

    if ($script:MenuCurrentView -eq 'Hidden') {
        if ($escapeDown -and $script:MenuGameplayStarted) {
            Invoke-MenuAction -Action 'OpenPause' -Source 'KeyboardEscape' | Out-Null
        }

        $script:MenuLeftMouseWasHeld = [bool]$leftHeld
        Refresh-MenuReadModel -CursorX $cursorX -CursorY $cursorY | Out-Null
        return
    }

    [bool]$upDown = Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Up
)
    [bool]$downDown = Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Down)
    [bool]$leftKey = Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Left)
    [bool]$rightKey = Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Right)
    [bool]$enterDown = (Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Enter)) -or (Get-MenuKeyDownInternal -Key ([System.Windows.Forms.Keys]::Space))

    # Hover guides selection for mouse-first navigation.
    if ($script:MenuReadModel.Hover.Kind -eq 'MainItem') {
        Set-MenuMainSelection -Index ([int]$script:MenuReadModel.Hover.Index)
    }
    elseif ($script:MenuReadModel.Hover.Kind -eq 'PauseItem') {
        Set-MenuPauseSelection -Index ([int]$script:MenuReadModel.Hover.Index)
    }
    elseif ($script:MenuReadModel.Hover.Kind -eq 'SettingsRow') {
        [string]$hoverCategory = [string]$script:MenuReadModel.Hover.Category
        if ([string]::IsNullOrWhiteSpace($hoverCategory)) {
            $hoverCategory = [string]$script:MenuSelectedSettingsCategory
        }
        Set-MenuSettingsRowSelection -Category $hoverCategory -Index ([int]$script:MenuReadModel.Hover.Index) -MaxIndex ([int]$script:MenuReadModel.Settings.Rows.Count) | Out-Null
    }
    elseif ($script:MenuReadModel.Hover.Kind -eq 'SettingsBack') {
        Set-MenuSettingsRowSelection -Category ([string]$script:MenuSelectedSettingsCategory) -Index ([int]$script:MenuReadModel.Settings.Rows.Count) -MaxIndex ([int]$script:MenuReadModel.Settings.Rows.Count) | Out-Null
    }

    if ($script:MenuCurrentView -eq 'Main') {
        if ($upDown) {
            Set-MenuMainSelection -Index ([int]$script:MenuSelectionMainIndex - 1)
        }
        if ($downDown) {
            Set-MenuMainSelection -Index ([int]$script:MenuSelectionMainIndex + 1)
        }

        if ($escapeDown) {
            Invoke-MenuAction -Action 'Exit' -Source 'KeyboardEscape' | Out-Null
        }

        if ($enterDown) {
            if ($script:MenuSelectionMainIndex -ge 0 -and $script:MenuSelectionMainIndex -lt $script:MenuMainItems.Count) {
                $action = [string]$script:MenuMainItems[$script:MenuSelectionMainIndex].Action
                Invoke-MenuAction -Action $action -Source 'KeyboardActivate' | Out-Null
            }
        }
    }
    elseif ($script:MenuCurrentView -eq 'Pause') {
        if ($upDown) {
            Set-MenuPauseSelection -Index ([int]$script:MenuSelectionPauseIndex - 1)
        }
        if ($downDown) {
            Set-MenuPauseSelection -Index ([int]$script:MenuSelectionPauseIndex + 1)
        }

        if ($escapeDown) {
            Invoke-MenuAction -Action 'Resume' -Source 'KeyboardEscape' | Out-Null
        }

        if ($enterDown) {
            if ($script:MenuSelectionPauseIndex -ge 0 -and $script:MenuSelectionPauseIndex -lt $script:MenuPauseItems.Count) {
                $action = [string]$script:MenuPauseItems[$script:MenuSelectionPauseIndex].Action
                Invoke-MenuAction -Action $action -Source 'KeyboardActivate' | Out-Null
            }
        }
    }
    elseif ($script:MenuCurrentView -eq 'Settings') {
        [string]$category = [string]$script:MenuSelectedSettingsCategory
        [int]$rowCount = [int]$script:MenuReadModel.Settings.Rows.Count
        [int]$maxIndex = [int]$rowCount

        [int]$selectedRow = [int]$script:MenuSettingsRowSelection[$category]
        $selectedRow = Set-MenuSettingsRowSelection -Category $category -Index $selectedRow -MaxIndex $maxIndex

        if ($leftKey) {
            Cycle-MenuSettingsCategory -Delta -1 | Out-Null
            Set-MenuActionResult -Action 'CategorySelect' -Source 'KeyboardLeft' -Success $true -Reason ('SelectedCategory={0}' -f $script:MenuSelectedSettingsCategory) | Out-Null
        }
        if ($rightKey) {
            Cycle-MenuSettingsCategory -Delta 1 | Out-Null
            Set-MenuActionResult -Action 'CategorySelect' -Source 'KeyboardRight' -Success $true -Reason ('SelectedCategory={0}' -f $script:MenuSelectedSettingsCategory) | Out-Null
        }

        if ($upDown) {
            Set-MenuSettingsRowSelection -Category ([string]$script:MenuSelectedSettingsCategory) -Index ([int]$script:MenuSettingsRowSelection[[string]$script:MenuSelectedSettingsCategory] - 1) -MaxIndex ([int]$maxIndex) | Out-Null
        }
        if ($downDown) {
            Set-MenuSettingsRowSelection -Category ([string]$script:MenuSelectedSettingsCategory) -Index ([int]$script:MenuSettingsRowSelection[[string]$script:MenuSelectedSettingsCategory] + 1) -MaxIndex ([int]$maxIndex) | Out-Null
        }

        if ($escapeDown) {
            Invoke-MenuAction -Action 'BackFromSettings' -Source 'KeyboardEscape' | Out-Null
        }

        if ($enterDown) {
            [string]$activeCategory = [string]$script:MenuSelectedSettingsCategory
            [int]$activeIndex = [int]$script:MenuSettingsRowSelection[$activeCategory]
            if ($activeIndex -ge $rowCount) {
                Invoke-MenuAction -Action 'BackFromSettings' -Source 'KeyboardActivate' | Out-Null
            }
            elseif ($activeIndex -ge 0 -and $activeIndex -lt $rowCount) {
                $row = $script:MenuReadModel.Settings.Rows[$activeIndex]
                Invoke-MenuSettingsAdjustment -Category ([string]$row.Category) -SettingId ([string]$row.Id) -Direction 1 -Source 'KeyboardActivate' | Out-Null
            }
        }
    }

    if ($leftDown) {
        switch ([string]$script:MenuReadModel.Hover.Kind) {
            'MainItem' {
                Set-MenuMainSelection -Index ([int]$script:MenuReadModel.Hover.Index)
                Invoke-MenuAction -Action ([string]$script:MenuReadModel.Hover.Action) -Source 'MouseClick' | Out-Null
            }
            'PauseItem' {
                Set-MenuPauseSelection -Index ([int]$script:MenuReadModel.Hover.Index)
                Invoke-MenuAction -Action ([string]$script:MenuReadModel.Hover.Action) -Source 'MouseClick' | Out-Null
            }
            'SettingsCategory' {
                Set-MenuSettingsCategory -Category ([string]$script:MenuReadModel.Hover.Category) | Out-Null
                Set-MenuActionResult -Action 'CategorySelect' -Source 'MouseClick' -Success $true -Reason ('SelectedCategory={0}' -f $script:MenuSelectedSettingsCategory) | Out-Null
            }
            'SettingsRow' {
                [string]$rowCategory = [string]$script:MenuReadModel.Hover.Category
                if ([string]::IsNullOrWhiteSpace($rowCategory)) {
                    $rowCategory = [string]$script:MenuSelectedSettingsCategory
                }

                Set-MenuSettingsRowSelection -Category $rowCategory -Index ([int]$script:MenuReadModel.Hover.Index) -MaxIndex ([int]$script:MenuReadModel.Settings.Rows.Count) | Out-Null

                [int]$idx = [int]$script:MenuReadModel.Hover.Index
                if ($idx -ge 0 -and $idx -lt $script:MenuReadModel.Settings.Rows.Count) {
                    $row = $script:MenuReadModel.Settings.Rows[$idx]
                    Invoke-MenuSettingsAdjustment -Category ([string]$row.Category) -SettingId ([string]$row.Id) -Direction 1 -Source 'MouseClick' | Out-Null
                }
            }
            'SettingsBack' {
                Invoke-MenuAction -Action 'BackFromSettings' -Source 'MouseClick' | Out-Null
            }
        }
    }

    $script:MenuLeftMouseWasHeld = [bool]$leftHeld
    Refresh-MenuReadModel -CursorX $cursorX -CursorY $cursorY | Out-Null
}

function Render-Menu {
    <#
    .SYNOPSIS
        Draws menu overlays for current menu mode with simple transitions.
    #>
    param($dt)

    if (-not $script:MenuInitialized) {
        $script:MenuLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
            DrawCallEstimate = [int]0
            View = [string]$script:MenuCurrentView
            VisibleView = 'None'
            TransitionActive = [bool]$script:MenuTransition.Active
            TransitionProgress = [float]$script:MenuTransition.Progress
        }
        return
    }

    if (-not (Get-Command -Name Draw-HUDRect -ErrorAction SilentlyContinue)) {
        $script:MenuLastRender = [PSCustomObject]@{
            Mode = 'HeadlessNoDrawAPI'
            Rendered = $false
            Reason = 'DrawHUDRectMissing'
            DrawCallEstimate = [int]0
            View = [string]$script:MenuCurrentView
            VisibleView = [string]$script:MenuReadModel.VisibleView
            TransitionActive = [bool]$script:MenuTransition.Active
            TransitionProgress = [float]$script:MenuTransition.Progress
        }
        return
    }

    $metrics = Get-MenuHUDMetrics
    if (-not [bool]$metrics.HUDInitialized) {
        $script:MenuLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'HUDNotInitialized'
            DrawCallEstimate = [int]0
            View = [string]$script:MenuCurrentView
            VisibleView = [string]$script:MenuReadModel.VisibleView
            TransitionActive = [bool]$script:MenuTransition.Active
            TransitionProgress = [float]$script:MenuTransition.Progress
        }
        return
    }

    $mouse = Get-MenuMousePositionInternal
    Refresh-MenuReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y) | Out-Null

    $visual = Get-MenuVisualTransitionState
    [float]$alpha = [float]$visual.Alpha
    [float]$offsetY = [float]$visual.OffsetY
    [float]$offsetX = [float]$visual.OffsetX

    if ($alpha -le 0.001) {
        $script:MenuLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'MenuHidden'
            DrawCallEstimate = [int]0
            View = [string]$script:MenuCurrentView
            VisibleView = [string]$script:MenuReadModel.VisibleView
            TransitionActive = [bool]$script:MenuTransition.Active
            TransitionProgress = [float]$script:MenuTransition.Progress
        }
        $script:MenuReadModel.LastRender = $script:MenuLastRender
        return
    }

    [int]$drawCount = 0
    [float]$z = [float]-0.935

    # Global dim overlay.
    $drawCount += Draw-MenuRectInternal -Rect $script:MenuReadModel.Layout.Window -OffsetX 0 -OffsetY 0 -Z $z -Color $script:MenuTheme.Overlay -AlphaMultiplier $alpha

    $panelRect = $script:MenuReadModel.Layout.Panel
    [float]$border = [float][Math]::Max(1.0, [Math]::Round([double]$script:MenuReadModel.Layout.Scale))

    $drawCount += Draw-MenuRectInternal -Rect $panelRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.0001) -Color $script:MenuTheme.Panel -AlphaMultiplier $alpha

    $topBorder = New-MenuRect -X ([float]$panelRect.X) -Y ([float]$panelRect.Y) -Width ([float]$panelRect.Width) -Height $border
    $bottomBorder = New-MenuRect -X ([float]$panelRect.X) -Y ([float]($panelRect.Y + $panelRect.Height - $border)) -Width ([float]$panelRect.Width) -Height $border
    $leftBorder = New-MenuRect -X ([float]$panelRect.X) -Y ([float]$panelRect.Y) -Width $border -Height ([float]$panelRect.Height)
    $rightBorder = New-MenuRect -X ([float]($panelRect.X + $panelRect.Width - $border)) -Y ([float]$panelRect.Y) -Width $border -Height ([float]$panelRect.Height)

    $drawCount += Draw-MenuRectInternal -Rect $topBorder -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00011) -Color $script:MenuTheme.PanelBorder -AlphaMultiplier $alpha
    $drawCount += Draw-MenuRectInternal -Rect $bottomBorder -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00011) -Color $script:MenuTheme.PanelBorder -AlphaMultiplier $alpha
    $drawCount += Draw-MenuRectInternal -Rect $leftBorder -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00011) -Color $script:MenuTheme.PanelBorder -AlphaMultiplier $alpha
    $drawCount += Draw-MenuRectInternal -Rect $rightBorder -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00011) -Color $script:MenuTheme.PanelBorder -AlphaMultiplier $alpha

    $drawCount += Draw-MenuRectInternal -Rect $script:MenuReadModel.Layout.HeaderRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00012) -Color $script:MenuTheme.Header -AlphaMultiplier $alpha

    [float]$accentW = [float][Math]::Max(14.0, $script:MenuReadModel.Layout.HeaderRect.Width * 0.42)
    [float]$accentH = [float][Math]::Max(2.0, $script:MenuReadModel.Layout.HeaderRect.Height * 0.08)
    $headerAccent = New-MenuRect -X ([float]($script:MenuReadModel.Layout.HeaderRect.X + (16.0 * $script:MenuReadModel.Layout.Scale))) -Y ([float]($script:MenuReadModel.Layout.HeaderRect.Y + $script:MenuReadModel.Layout.HeaderRect.Height - $accentH - (6.0 * $script:MenuReadModel.Layout.Scale))) -Width $accentW -Height $accentH
    $drawCount += Draw-MenuRectInternal -Rect $headerAccent -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00013) -Color $script:MenuTheme.HeaderAccent -AlphaMultiplier $alpha

    [string]$visibleView = [string]$script:MenuReadModel.VisibleView
    if ([string]::IsNullOrWhiteSpace($visibleView) -or $visibleView -eq 'None') {
        $visibleView = [string]$script:MenuCurrentView
    }

    if ($visibleView -eq 'Main' -or $visibleView -eq 'Pause') {
        $rows = if ($visibleView -eq 'Main') { $script:MenuReadModel.MainMenu.Items } else { $script:MenuReadModel.PauseMenu.Items }

        foreach ($row in @($rows)) {
            if ($null -eq $row) { continue }

            $rowColor = $script:MenuTheme.Item
            if ([bool]$row.IsSelected) {
                $rowColor = $script:MenuTheme.ItemSelected
            }
            elseif ([bool]$row.IsHovered) {
                $rowColor = $script:MenuTheme.ItemHover
            }

            $drawCount += Draw-MenuRectInternal -Rect $row.Rect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.0002) -Color $rowColor -AlphaMultiplier $alpha

            if ([bool]$row.IsSelected -or [bool]$row.IsHovered) {
                [float]$accentWidth = [float][Math]::Max(2.0, 5.0 * $script:MenuReadModel.Layout.Scale)
                $itemAccent = New-MenuRect -X ([float]$row.Rect.X) -Y ([float]$row.Rect.Y) -Width $accentWidth -Height ([float]$row.Rect.Height)
                $drawCount += Draw-MenuRectInternal -Rect $itemAccent -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00021) -Color $script:MenuTheme.ItemAccent -AlphaMultiplier $alpha
            }
        }
    }
    elseif ($visibleView -eq 'Settings') {
        foreach ($tab in @($script:MenuReadModel.Settings.Categories)) {
            if ($null -eq $tab) { continue }

            $tabColor = $script:MenuTheme.Tab
            if ([bool]$tab.IsSelected) {
                $tabColor = $script:MenuTheme.TabSelected
            }
            elseif ([bool]$tab.IsHovered) {
                $tabColor = $script:MenuTheme.TabHover
            }

            $drawCount += Draw-MenuRectInternal -Rect $tab.Rect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.0002) -Color $tabColor -AlphaMultiplier $alpha
        }

        foreach ($row in @($script:MenuReadModel.Settings.Rows)) {
            if ($null -eq $row) { continue }

            $rowColor = $script:MenuTheme.Item
            if ([bool]$row.IsSelected) {
                $rowColor = $script:MenuTheme.ItemSelected
            }
            elseif ([bool]$row.IsHovered) {
                $rowColor = $script:MenuTheme.ItemHover
            }

            $drawCount += Draw-MenuRectInternal -Rect $row.Rect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.0003) -Color $rowColor -AlphaMultiplier $alpha

            if ([string]$row.Type -eq 'Range' -or [string]$row.Type -eq 'Choice') {
                [float]$trackX = [float]($row.Rect.X + (12.0 * $script:MenuReadModel.Layout.Scale))
                [float]$trackW = [float][Math]::Max(12.0, $row.Rect.Width - (24.0 * $script:MenuReadModel.Layout.Scale))
                [float]$trackH = [float][Math]::Max(2.0, 4.0 * $script:MenuReadModel.Layout.Scale)
                [float]$trackY = [float]($row.Rect.Y + $row.Rect.Height - $trackH - (8.0 * $script:MenuReadModel.Layout.Scale))

                $trackRect = New-MenuRect -X $trackX -Y $trackY -Width $trackW -Height $trackH
                $fillRect = New-MenuRect -X $trackX -Y $trackY -Width ([float]($trackW * [float]$row.Normalized)) -Height $trackH

                $drawCount += Draw-MenuRectInternal -Rect $trackRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00031) -Color $script:MenuTheme.ValueTrack -AlphaMultiplier $alpha
                $drawCount += Draw-MenuRectInternal -Rect $fillRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00032) -Color $script:MenuTheme.ValueFill -AlphaMultiplier $alpha
            }
            else {
                [float]$toggleW = [float][Math]::Max(12.0, 34.0 * $script:MenuReadModel.Layout.Scale)
                [float]$toggleH = [float][Math]::Max(8.0, 18.0 * $script:MenuReadModel.Layout.Scale)
                [float]$toggleX = [float]($row.Rect.X + $row.Rect.Width - $toggleW - (12.0 * $script:MenuReadModel.Layout.Scale))
                [float]$toggleY = [float]($row.Rect.Y + (($row.Rect.Height - $toggleH) * 0.5))

                $toggleRect = New-MenuRect -X $toggleX -Y $toggleY -Width $toggleW -Height $toggleH
                $toggleColor = if ([bool]$row.Value) { $script:MenuTheme.ToggleOn } else { $script:MenuTheme.ToggleOff }
                $drawCount += Draw-MenuRectInternal -Rect $toggleRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00031) -Color $toggleColor -AlphaMultiplier $alpha

                [float]$knobSize = [float][Math]::Max(4.0, $toggleH - 2.0)
                [float]$knobX = if ([bool]$row.Value) { [float]($toggleX + $toggleW - $knobSize - 1.0) } else { [float]($toggleX + 1.0) }
                [float]$knobY = [float]($toggleY + 1.0)
                $knobRect = New-MenuRect -X $knobX -Y $knobY -Width $knobSize -Height $knobSize
                $drawCount += Draw-MenuRectInternal -Rect $knobRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.00032) -Color $script:MenuTheme.ItemAccent -AlphaMultiplier $alpha
            }
        }

        $backColor = $script:MenuTheme.BackButton
        if ([bool]$script:MenuReadModel.Settings.BackButtonHovered -or [bool]$script:MenuReadModel.Settings.BackButtonSelected) {
            $backColor = $script:MenuTheme.BackButtonHover
        }

        $drawCount += Draw-MenuRectInternal -Rect $script:MenuReadModel.Settings.BackButtonRect -OffsetX $offsetX -OffsetY $offsetY -Z ($z - 0.0005) -Color $backColor -AlphaMultiplier $alpha
    }

    $script:MenuLastRender = [PSCustomObject]@{
        Mode = 'HUDOverlay'
        Rendered = ($drawCount -gt 0)
        Reason = if ($drawCount -gt 0) { 'Rendered' } else { 'NoDrawCalls' }
        DrawCallEstimate = [int]$drawCount
        View = [string]$script:MenuCurrentView
        VisibleView = [string]$visibleView
        TransitionActive = [bool]$script:MenuTransition.Active
        TransitionProgress = [float]$script:MenuTransition.Progress
    }

    $script:MenuReadModel.LastRender = $script:MenuLastRender
}

function Get-MenuState {
    <#
    .SYNOPSIS
        Returns deterministic menu state for verification and game integration.
    #>

    if (-not $script:MenuInitialized) {
        return [PSCustomObject]@{
            Initialized = $false
            UpdateRegistered = [bool]$script:MenuUpdateRegistered
            RenderRegistered = [bool]$script:MenuRenderRegistered
            View = [string]$script:MenuCurrentView
            VisibleView = 'None'
            PreviousView = [string]$script:MenuPreviousView
            GameplayStarted = [bool]$script:MenuGameplayStarted
            Paused = [bool]$script:MenuPaused
            PauseReason = [string]$script:MenuPauseReason
            ExitRequested = [bool]$script:MenuExitRequested
            Cursor = [PSCustomObject]@{ X = [float]0.0; Y = [float]0.0 }
            Layout = $null
            Navigation = [PSCustomObject]@{
                MainSelectedIndex = [int]0
                PauseSelectedIndex = [int]0
                SettingsCategory = 'Controls'
                SettingsSelectedRowIndex = [int]0
            }
            MainMenu = [PSCustomObject]@{ Visible = $false; Items = @() }
            PauseMenu = [PSCustomObject]@{ Visible = $false; Items = @() }
            Settings = [PSCustomObject]@{
                Visible = $false
                ReturnView = 'Main'
                Categories = @()
                Rows = @()
                BackButtonRect = $null
                BackButtonHovered = $false
                BackButtonSelected = $false
                Persistence = [string]$script:MenuSettingsPersistenceStatus
                Values = [PSCustomObject]@{
                    Controls = [PSCustomObject]@{
                        MoveForward = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'MoveForward' -Default 'W')
                        Jump = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'Jump' -Default 'Space')
                        Inventory = [string](Get-MenuSettingValue -Category 'Controls' -SettingId 'Inventory' -Default 'E')
                    }
                    Audio = [PSCustomObject]@{
                        MasterVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'MasterVolume' -Default 85)
                        MusicVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'MusicVolume' -Default 70)
                        EffectsVolume = [int](Get-MenuSettingValue -Category 'Audio' -SettingId 'EffectsVolume' -Default 80)
                        AudioBackendAvailable = [bool](Get-MenuSettingValue -Category 'Audio' -SettingId 'AudioBackendAvailable' -Default $false)
                    }
                    Video = [PSCustomObject]@{
                        Resolution = [string](Get-MenuSettingValue -Category 'Video' -SettingId 'Resolution' -Default '1024x768')
                        VSync = [bool](Get-MenuSettingValue -Category 'Video' -SettingId 'VSync' -Default $true)
                        RenderDistance = [int](Get-MenuSettingValue -Category 'Video' -SettingId 'RenderDistance' -Default 4)
                    }
                }
            }
            Hover = [PSCustomObject]@{
                Kind = 'None'
                Index = [int]-1
                Id = ''
                Label = ''
                Category = ''
                Action = ''
            }
            Transition = [PSCustomObject]@{
                Active = [bool]$script:MenuTransition.Active
                Progress = [float]$script:MenuTransition.Progress
                FromView = [string]$script:MenuTransition.FromView
                ToView = [string]$script:MenuTransition.ToView
                Duration = [float]$script:MenuTransition.Duration
                Reason = [string]$script:MenuTransition.Reason
            }
            LastAction = $script:MenuLastAction
            LastRender = $script:MenuLastRender
        }
    }

    $mouse = Get-MenuMousePositionInternal
    Refresh-MenuReadModel -CursorX ([float]$mouse.X) -CursorY ([float]$mouse.Y) | Out-Null
    return $script:MenuReadModel
}
