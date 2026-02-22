# ============================================================================
# UI/StatusBar.ps1 - Player Status Bars Overlay
# ============================================================================
# Renders HP, Mana, Stamina, and XP bars using HUD overlay primitives.
# Uses lightweight interpolation for smooth fill and drain behavior.
#
# Public API:
# - Initialize-StatusBar
# - Update-StatusBar
# - Render-StatusBar
# - Get-StatusBarState
# ============================================================================

# --- Module State ---
$script:StatusBarInitialized = $false
$script:StatusBarUpdateRegistered = $false
$script:StatusBarRenderRegistered = $false
$script:StatusBarCmdCache = @{}

$script:StatusBarFillSpeed = [float]4.0
$script:StatusBarDrainSpeed = [float]8.0
$script:StatusBarLowHealthThreshold = [float]0.25
$script:StatusBarWarningTimer = [float]0.0

$script:StatusBarTargetRatios = [PSCustomObject]@{
    HP = [float]1.0
    Mana = [float]1.0
    Stamina = [float]1.0
    XP = [float]0.0
}

$script:StatusBarDisplayRatios = [PSCustomObject]@{
    HP = [float]1.0
    Mana = [float]1.0
    Stamina = [float]1.0
    XP = [float]0.0
}

$script:StatusBarRawValues = [PSCustomObject]@{
    HP = [float]100.0
    MaxHP = [float]100.0
    Mana = [float]50.0
    MaxMana = [float]50.0
    Stamina = [float]100.0
    MaxStamina = [float]100.0
    XPPercent = [float]0.0
    Level = [int]1
    IsMaxLevel = $false
}

$script:StatusBarLastRender = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
    LowHealthWarningVisible = $false
    DrawCallEstimate = [int]0
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Test-StatusBarCommand {
    param([string]$Name)
    if (-not $script:StatusBarCmdCache.ContainsKey($Name)) {
        $script:StatusBarCmdCache[$Name] = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
    return $script:StatusBarCmdCache[$Name]
}

function Clamp-StatusBar01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-StatusBarPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function Resolve-StatusBarRatio {
    param(
        [double]$Current,
        [double]$Max
    )

    if ($Max -le 0.0) {
        return [float]0.0
    }

    return (Clamp-StatusBar01 -Value ($Current / $Max))
}

function Get-StatusBarHUDMetrics {
    [float]$scale = [float]1.0
    [float]$windowWidth = [float]1024.0
    [float]$windowHeight = [float]768.0
    [bool]$hudInitialized = $true
    [string]$source = 'Fallback'

    if (Test-StatusBarCommand -Name 'Get-HUDState') {
        $state = Get-HUDState
        if ($null -ne $state) {
            if ($null -ne $state.PSObject.Properties['Scale']) {
                $scale = Clamp-StatusBarPositive -Value ([double]$state.Scale) -Fallback 1.0
            }
            if ($null -ne $state.PSObject.Properties['WindowWidth']) {
                $windowWidth = Clamp-StatusBarPositive -Value ([double]$state.WindowWidth) -Fallback 1024.0
            }
            if ($null -ne $state.PSObject.Properties['WindowHeight']) {
                $windowHeight = Clamp-StatusBarPositive -Value ([double]$state.WindowHeight) -Fallback 768.0
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

function Get-StatusBarLiveSnapshot {
    [float]$hp = [float]$script:StatusBarRawValues.HP
    [float]$maxHP = [float]$script:StatusBarRawValues.MaxHP
    [float]$mana = [float]$script:StatusBarRawValues.Mana
    [float]$maxMana = [float]$script:StatusBarRawValues.MaxMana
    [float]$stamina = [float]$script:StatusBarRawValues.Stamina
    [float]$maxStamina = [float]$script:StatusBarRawValues.MaxStamina

    [float]$xpRatio = [float]$script:StatusBarTargetRatios.XP
    [float]$xpPercent = [float]$script:StatusBarRawValues.XPPercent
    [int]$level = [int]$script:StatusBarRawValues.Level
    [bool]$isMaxLevel = [bool]$script:StatusBarRawValues.IsMaxLevel

    if (Test-StatusBarCommand -Name 'Get-PlayerStats') {
        $stats = Get-PlayerStats
        if ($null -ne $stats) {
            if ($null -ne $stats.PSObject.Properties['HP']) { $hp = [float]$stats.HP }
            if ($null -ne $stats.PSObject.Properties['MaxHP']) { $maxHP = [float]$stats.MaxHP }
            if ($null -ne $stats.PSObject.Properties['Mana']) { $mana = [float]$stats.Mana }
            if ($null -ne $stats.PSObject.Properties['MaxMana']) { $maxMana = [float]$stats.MaxMana }
            if ($null -ne $stats.PSObject.Properties['Stamina']) { $stamina = [float]$stats.Stamina }
            if ($null -ne $stats.PSObject.Properties['MaxStamina']) { $maxStamina = [float]$stats.MaxStamina }
        }
    }

    if (Test-StatusBarCommand -Name 'Get-PlayerXPProgress') {
        $xpProgress = Get-PlayerXPProgress
        if ($null -ne $xpProgress) {
            if ($null -ne $xpProgress.PSObject.Properties['ProgressPercent']) {
                $xpPercent = [float]$xpProgress.ProgressPercent
                $xpRatio = Clamp-StatusBar01 -Value (($xpPercent) / 100.0)
            }
            elseif (
                $null -ne $xpProgress.PSObject.Properties['XPToNextLevel'] -and
                $null -ne $xpProgress.PSObject.Properties['XPIntoCurrentLevel'] -and
                [double]$xpProgress.XPToNextLevel -gt 0.0
            ) {
                $xpRatio = Clamp-StatusBar01 -Value (([double]$xpProgress.XPIntoCurrentLevel) / ([double]$xpProgress.XPToNextLevel))
                $xpPercent = [float]([Math]::Round($xpRatio * 100.0, 2))
            }

            if ($null -ne $xpProgress.PSObject.Properties['Level']) {
                $level = [int]$xpProgress.Level
            }
            if ($null -ne $xpProgress.PSObject.Properties['IsMaxLevel']) {
                $isMaxLevel = [bool]$xpProgress.IsMaxLevel
            }
        }
    }

    return [PSCustomObject]@{
        HP = [float]$hp
        MaxHP = [float](Clamp-StatusBarPositive -Value $maxHP -Fallback 1.0)
        Mana = [float]$mana
        MaxMana = [float](Clamp-StatusBarPositive -Value $maxMana -Fallback 1.0)
        Stamina = [float]$stamina
        MaxStamina = [float](Clamp-StatusBarPositive -Value $maxStamina -Fallback 1.0)
        XPRatio = [float](Clamp-StatusBar01 -Value $xpRatio)
        XPPercent = [float]$xpPercent
        Level = [int]$level
        IsMaxLevel = [bool]$isMaxLevel
        HPRatio = [float](Resolve-StatusBarRatio -Current $hp -Max $maxHP)
        ManaRatio = [float](Resolve-StatusBarRatio -Current $mana -Max $maxMana)
        StaminaRatio = [float](Resolve-StatusBarRatio -Current $stamina -Max $maxStamina)
    }
}

function Step-StatusBarInterpolation {
    param(
        [float]$Current,
        [float]$Target,
        [float]$Step
    )

    [float]$delta = [float]($Target - $Current)
    if ([Math]::Abs($delta) -le 0.0005) {
        return [float]$Target
    }

    [float]$speed = [float]$script:StatusBarFillSpeed
    if ($delta -lt 0.0) {
        $speed = [float]$script:StatusBarDrainSpeed
    }

    [float]$alpha = Clamp-StatusBar01 -Value ($Step * $speed)
    return [float]($Current + ($delta * $alpha))
}

function Draw-StatusBarLine {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Z,
        [float]$FillRatio,
        [float]$R,
        [float]$G,
        [float]$B,
        [float]$A,
        [float]$TrackA = [float]0.54
    )

    [float]$innerPad = [float][Math]::Max(1.0, $Height * 0.16)
    [float]$trackX = [float]($X + $innerPad)
    [float]$trackY = [float]($Y + $innerPad)
    [float]$trackW = [float][Math]::Max(1.0, $Width - ($innerPad * 2.0))
    [float]$trackH = [float][Math]::Max(1.0, $Height - ($innerPad * 2.0))

    Draw-HUDRect -X $X -Y $Y -Width $Width -Height $Height -Z $Z -R 0.04 -G 0.05 -B 0.07 -A 0.82
    Draw-HUDRect -X $trackX -Y $trackY -Width $trackW -Height $trackH -Z ($Z - 0.0001) -R 0.08 -G 0.09 -B 0.12 -A $TrackA

    [float]$fillW = [float]($trackW * (Clamp-StatusBar01 -Value $FillRatio))
    if ($fillW -gt 0.0) {
        Draw-HUDRect -X $trackX -Y $trackY -Width $fillW -Height $trackH -Z ($Z - 0.0002) -R $R -G $G -B $B -A $A

        [float]$shineH = [float][Math]::Max(1.0, $trackH * 0.25)
        Draw-HUDRect -X $trackX -Y $trackY -Width $fillW -Height $shineH -Z ($Z - 0.0003) -R ([float][Math]::Min(1.0, $R + 0.08)) -G ([float][Math]::Min(1.0, $G + 0.08)) -B ([float][Math]::Min(1.0, $B + 0.08)) -A ([float][Math]::Min(1.0, $A + 0.12))
    }
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-StatusBar {
    <#
    .SYNOPSIS
        Initializes status bar state and callback wiring.
    #>
    param(
        [float]$FillSpeed = [float]4.0,
        [float]$DrainSpeed = [float]8.0,
        [float]$LowHealthThreshold = [float]0.25
    )

    $script:StatusBarFillSpeed = Clamp-StatusBarPositive -Value $FillSpeed -Fallback 4.0
    $script:StatusBarDrainSpeed = Clamp-StatusBarPositive -Value $DrainSpeed -Fallback 8.0
    $script:StatusBarLowHealthThreshold = Clamp-StatusBar01 -Value $LowHealthThreshold
    $script:StatusBarWarningTimer = [float]0.0

    if (Test-StatusBarCommand -Name 'Initialize-HUD') {
        [bool]$needsInit = $true
        if (Test-StatusBarCommand -Name 'Get-HUDState') {
            $hudState = Get-HUDState
            if ($null -ne $hudState -and $null -ne $hudState.PSObject.Properties['Initialized']) {
                $needsInit = -not [bool]$hudState.Initialized
            }
        }

        if ($needsInit) {
            Initialize-HUD -DesignWidth 1920 -DesignHeight 1080 -ScaleMode Fit -MaxScale 2.0
        }
    }

    $snapshot = Get-StatusBarLiveSnapshot

    $script:StatusBarTargetRatios.HP = [float]$snapshot.HPRatio
    $script:StatusBarTargetRatios.Mana = [float]$snapshot.ManaRatio
    $script:StatusBarTargetRatios.Stamina = [float]$snapshot.StaminaRatio
    $script:StatusBarTargetRatios.XP = [float]$snapshot.XPRatio

    $script:StatusBarDisplayRatios.HP = [float]$snapshot.HPRatio
    $script:StatusBarDisplayRatios.Mana = [float]$snapshot.ManaRatio
    $script:StatusBarDisplayRatios.Stamina = [float]$snapshot.StaminaRatio
    $script:StatusBarDisplayRatios.XP = [float]$snapshot.XPRatio

    $script:StatusBarRawValues = [PSCustomObject]@{
        HP = [float]$snapshot.HP
        MaxHP = [float]$snapshot.MaxHP
        Mana = [float]$snapshot.Mana
        MaxMana = [float]$snapshot.MaxMana
        Stamina = [float]$snapshot.Stamina
        MaxStamina = [float]$snapshot.MaxStamina
        XPPercent = [float]$snapshot.XPPercent
        Level = [int]$snapshot.Level
        IsMaxLevel = [bool]$snapshot.IsMaxLevel
    }

    $script:StatusBarInitialized = $true

    if (-not $script:StatusBarUpdateRegistered) {
        if (Test-StatusBarCommand -Name 'Register-UpdateCallback') {
            Register-UpdateCallback ${function:Update-StatusBar}
            $script:StatusBarUpdateRegistered = $true
            Write-Host '[StatusBar] Update callback registered.' -ForegroundColor DarkGray
        }
    }

    if (-not $script:StatusBarRenderRegistered) {
        if (Test-StatusBarCommand -Name 'Register-RenderCallback') {
            Register-RenderCallback ${function:Render-StatusBar}
            $script:StatusBarRenderRegistered = $true
            Write-Host '[StatusBar] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    $script:StatusBarLastRender = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
        LowHealthWarningVisible = $false
        DrawCallEstimate = [int]0
    }

    Write-Host '[StatusBar] Status bars initialized.' -ForegroundColor Green
}

function Update-StatusBar {
    <#
    .SYNOPSIS
        Updates status bar targets from game state and applies smoothing.
    #>
    param($dt)

    if (-not $script:StatusBarInitialized) {
        return
    }

    [float]$step = [float]0.016
    if ($null -ne $dt) {
        $step = [float]$dt
    }

    if ($step -lt 0.0) { $step = [float]0.0 }
    if ($step -gt 0.1) { $step = [float]0.1 }

    $snapshot = Get-StatusBarLiveSnapshot

    $script:StatusBarRawValues = [PSCustomObject]@{
        HP = [float]$snapshot.HP
        MaxHP = [float]$snapshot.MaxHP
        Mana = [float]$snapshot.Mana
        MaxMana = [float]$snapshot.MaxMana
        Stamina = [float]$snapshot.Stamina
        MaxStamina = [float]$snapshot.MaxStamina
        XPPercent = [float]$snapshot.XPPercent
        Level = [int]$snapshot.Level
        IsMaxLevel = [bool]$snapshot.IsMaxLevel
    }

    $script:StatusBarTargetRatios.HP = [float]$snapshot.HPRatio
    $script:StatusBarTargetRatios.Mana = [float]$snapshot.ManaRatio
    $script:StatusBarTargetRatios.Stamina = [float]$snapshot.StaminaRatio
    $script:StatusBarTargetRatios.XP = [float]$snapshot.XPRatio

    $script:StatusBarDisplayRatios.HP = Step-StatusBarInterpolation -Current ([float]$script:StatusBarDisplayRatios.HP) -Target ([float]$script:StatusBarTargetRatios.HP) -Step $step
    $script:StatusBarDisplayRatios.Mana = Step-StatusBarInterpolation -Current ([float]$script:StatusBarDisplayRatios.Mana) -Target ([float]$script:StatusBarTargetRatios.Mana) -Step $step
    $script:StatusBarDisplayRatios.Stamina = Step-StatusBarInterpolation -Current ([float]$script:StatusBarDisplayRatios.Stamina) -Target ([float]$script:StatusBarTargetRatios.Stamina) -Step $step
    $script:StatusBarDisplayRatios.XP = Step-StatusBarInterpolation -Current ([float]$script:StatusBarDisplayRatios.XP) -Target ([float]$script:StatusBarTargetRatios.XP) -Step $step

    if ([float]$script:StatusBarTargetRatios.HP -le [float]$script:StatusBarLowHealthThreshold) {
        $script:StatusBarWarningTimer = [float]($script:StatusBarWarningTimer + $step)
    }
    else {
        $script:StatusBarWarningTimer = [float]0.0
    }
}

function Render-StatusBar {
    <#
    .SYNOPSIS
        Draws status bars as a HUD overlay panel.
    #>
    param($dt)

    if (-not $script:StatusBarInitialized) {
        $script:StatusBarLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
            LowHealthWarningVisible = $false
            DrawCallEstimate = [int]0
        }
        return
    }

    if (-not (Test-StatusBarCommand -Name 'Draw-HUDRect')) {
        $script:StatusBarLastRender = [PSCustomObject]@{
            Mode = 'HeadlessNoDrawAPI'
            Rendered = $false
            Reason = 'DrawHUDRectMissing'
            LowHealthWarningVisible = $false
            DrawCallEstimate = [int]0
        }
        return
    }

    $metrics = Get-StatusBarHUDMetrics
    if (-not [bool]$metrics.HUDInitialized) {
        $script:StatusBarLastRender = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'HUDNotInitialized'
            LowHealthWarningVisible = $false
            DrawCallEstimate = [int]0
        }
        return
    }

    [float]$scale = Clamp-StatusBarPositive -Value ([double]$metrics.Scale) -Fallback 1.0
    [float]$panelX = [float](22.0 * $scale)
    [float]$panelY = [float](20.0 * $scale)
    [float]$panelW = [float](442.0 * $scale)
    [float]$panelH = [float](152.0 * $scale)
    [float]$contentPad = [float][Math]::Max(4.0, 12.0 * $scale)
    [float]$barH = [float][Math]::Max(8.0, 24.0 * $scale)
    [float]$barGap = [float][Math]::Max(3.0, 7.0 * $scale)
    [float]$barW = [float][Math]::Max(40.0, $panelW - ($contentPad * 2.0))
    [float]$startY = [float]($panelY + $contentPad)

    [float]$z = [float]-0.96
    [int]$drawCount = [int]0
    [bool]$warningVisible = $false

    Begin-HUDBatch
    try {
        Draw-HUDRect -X $panelX -Y $panelY -Width $panelW -Height $panelH -Z $z -R 0.03 -G 0.04 -B 0.06 -A 0.72
        $drawCount++

        [float]$panelBorder = [float][Math]::Max(1.0, [Math]::Round($scale))
        Draw-HUDRect -X $panelX -Y $panelY -Width $panelW -Height $panelBorder -Z ($z - 0.0001) -R 0.61 -G 0.69 -B 0.80 -A 0.84
        $drawCount++
        Draw-HUDRect -X $panelX -Y ($panelY + $panelH - $panelBorder) -Width $panelW -Height $panelBorder -Z ($z - 0.0001) -R 0.61 -G 0.69 -B 0.80 -A 0.84
        $drawCount++
        Draw-HUDRect -X $panelX -Y $panelY -Width $panelBorder -Height $panelH -Z ($z - 0.0001) -R 0.61 -G 0.69 -B 0.80 -A 0.84
        $drawCount++
        Draw-HUDRect -X ($panelX + $panelW - $panelBorder) -Y $panelY -Width $panelBorder -Height $panelH -Z ($z - 0.0001) -R 0.61 -G 0.69 -B 0.80 -A 0.84
        $drawCount++

        [float]$hpY = [float]$startY
        [float]$manaY = [float]($hpY + $barH + $barGap)
        [float]$staminaY = [float]($manaY + $barH + $barGap)
        [float]$xpY = [float]($staminaY + $barH + $barGap)

        Draw-StatusBarLine -X ($panelX + $contentPad) -Y $hpY -Width $barW -Height $barH -Z ($z - 0.0002) -FillRatio ([float]$script:StatusBarDisplayRatios.HP) -R 0.87 -G 0.16 -B 0.19 -A 0.92
        $drawCount += 4

        Draw-StatusBarLine -X ($panelX + $contentPad) -Y $manaY -Width $barW -Height $barH -Z ($z - 0.0003) -FillRatio ([float]$script:StatusBarDisplayRatios.Mana) -R 0.20 -G 0.48 -B 0.94 -A 0.90
        $drawCount += 4

        Draw-StatusBarLine -X ($panelX + $contentPad) -Y $staminaY -Width $barW -Height $barH -Z ($z - 0.0004) -FillRatio ([float]$script:StatusBarDisplayRatios.Stamina) -R 0.16 -G 0.76 -B 0.35 -A 0.90
        $drawCount += 4

        Draw-StatusBarLine -X ($panelX + $contentPad) -Y $xpY -Width $barW -Height $barH -Z ($z - 0.0005) -FillRatio ([float]$script:StatusBarDisplayRatios.XP) -R 0.93 -G 0.79 -B 0.16 -A 0.92
        $drawCount += 4

        if ([float]$script:StatusBarDisplayRatios.HP -le [float]$script:StatusBarLowHealthThreshold) {
            [float]$pulse = [float](0.45 + ([Math]::Abs([Math]::Sin($script:StatusBarWarningTimer * 6.0)) * 0.55))
            [float]$warningAlpha = [float](0.14 + (0.16 * $pulse))
            [float]$warningBorderAlpha = [float](0.22 + (0.58 * $pulse))

            Draw-HUDRect -X ($panelX + ($contentPad * 0.4)) -Y ($hpY - ($contentPad * 0.35)) -Width ($barW + ($contentPad * 1.2)) -Height ($barH + ($contentPad * 0.7)) -Z ($z - 0.0006) -R 0.93 -G 0.08 -B 0.08 -A $warningAlpha
            $drawCount++

            [float]$warningBorder = [float][Math]::Max(1.0, [Math]::Round($scale * 1.2))
            Draw-HUDRect -X ($panelX + ($contentPad * 0.4)) -Y ($hpY - ($contentPad * 0.35)) -Width ($barW + ($contentPad * 1.2)) -Height $warningBorder -Z ($z - 0.0007) -R 1.0 -G 0.18 -B 0.18 -A $warningBorderAlpha
            $drawCount++
            Draw-HUDRect -X ($panelX + ($contentPad * 0.4)) -Y ($hpY + $barH + ($contentPad * 0.35) - $warningBorder) -Width ($barW + ($contentPad * 1.2)) -Height $warningBorder -Z ($z - 0.0007) -R 1.0 -G 0.18 -B 0.18 -A $warningBorderAlpha
            $drawCount++

            [float]$beaconW = [float][Math]::Max(8.0, 14.0 * $scale)
            [float]$beaconH = [float][Math]::Max(8.0, 14.0 * $scale)
            Draw-HUDRect -X ($panelX + $panelW - $contentPad - $beaconW) -Y ($panelY + $contentPad) -Width $beaconW -Height $beaconH -Z ($z - 0.0008) -R 1.0 -G 0.14 -B 0.14 -A ([float](0.28 + (0.52 * $pulse)))
            $drawCount++

            $warningVisible = $true
        }

        $script:StatusBarLastRender = [PSCustomObject]@{
            Mode = 'HUDOverlay'
            Rendered = $true
            Reason = 'Rendered'
            LowHealthWarningVisible = [bool]$warningVisible
            DrawCallEstimate = [int]$drawCount
        }
    }
    catch {
        $script:StatusBarLastRender = [PSCustomObject]@{
            Mode = 'DrawFailed'
            Rendered = $false
            Reason = [string]$_.Exception.Message
            LowHealthWarningVisible = $false
            DrawCallEstimate = [int]$drawCount
        }
    }
    finally {
        End-HUDBatch
    }
}

function Get-StatusBarState {
    <#
    .SYNOPSIS
        Returns deterministic status bar runtime state.
    #>

    return [PSCustomObject]@{
        Initialized = [bool]$script:StatusBarInitialized
        UpdateRegistered = [bool]$script:StatusBarUpdateRegistered
        RenderRegistered = [bool]$script:StatusBarRenderRegistered
        FillSpeed = [float]$script:StatusBarFillSpeed
        DrainSpeed = [float]$script:StatusBarDrainSpeed
        LowHealthThreshold = [float]$script:StatusBarLowHealthThreshold
        WarningTimer = [float]$script:StatusBarWarningTimer
        TargetRatios = [PSCustomObject]@{
            HP = [float]$script:StatusBarTargetRatios.HP
            Mana = [float]$script:StatusBarTargetRatios.Mana
            Stamina = [float]$script:StatusBarTargetRatios.Stamina
            XP = [float]$script:StatusBarTargetRatios.XP
        }
        DisplayRatios = [PSCustomObject]@{
            HP = [float]$script:StatusBarDisplayRatios.HP
            Mana = [float]$script:StatusBarDisplayRatios.Mana
            Stamina = [float]$script:StatusBarDisplayRatios.Stamina
            XP = [float]$script:StatusBarDisplayRatios.XP
        }
        RawValues = [PSCustomObject]@{
            HP = [float]$script:StatusBarRawValues.HP
            MaxHP = [float]$script:StatusBarRawValues.MaxHP
            Mana = [float]$script:StatusBarRawValues.Mana
            MaxMana = [float]$script:StatusBarRawValues.MaxMana
            Stamina = [float]$script:StatusBarRawValues.Stamina
            MaxStamina = [float]$script:StatusBarRawValues.MaxStamina
            XPPercent = [float]$script:StatusBarRawValues.XPPercent
            Level = [int]$script:StatusBarRawValues.Level
            IsMaxLevel = [bool]$script:StatusBarRawValues.IsMaxLevel
        }
        LastRender = $script:StatusBarLastRender
    }
}
