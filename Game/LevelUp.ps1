# ============================================================================
# Game/LevelUp.ps1 - Level-up Mechanics Integration (Task 41)
# ============================================================================
# Provides:
# - Deterministic level-up notification model for UI/HUD
# - Lightweight level-up effect token and sound cue metadata
# - Experience callback wiring for level-up events
# - Skill point grant bridge (Skills.ps1)
# - Stat point grant bridge (StatProgression.ps1)
#
# Scope notes:
# - No cutscene logic
# - Headless-friendly data/event model
# ============================================================================

# --- Module State ---
$script:LevelUpSystemInitialized = $false
$script:LevelUpNotificationHistory = [System.Collections.ArrayList]::new()
$script:LevelUpNotificationCallbacks = @()
$script:LevelUpProcessedEventKeys = @{}
$script:LevelUpPlayerContextByKey = @{}
$script:LevelUpNotificationRetention = [int]100
$script:LevelUpExperienceHookRegistered = $false
$script:LevelUpExperienceHookId = [int]0

# ============================================================================
# Internal Helpers
# ============================================================================

function ConvertTo-LevelUpInt {
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

function Add-LevelUpObjectProperty {
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

function Get-LevelUpFieldValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $Default
}

function Normalize-LevelUpPlayerName {
    param([string]$PlayerName)

    if ([string]::IsNullOrWhiteSpace($PlayerName)) {
        return 'Player'
    }

    return [string]$PlayerName.Trim()
}

function Get-LevelUpPlayerKey {
    param([string]$PlayerName)

    return ([string](Normalize-LevelUpPlayerName -PlayerName $PlayerName)).ToLowerInvariant()
}

function Get-LevelUpEventKey {
    param(
        [Parameter(Mandatory = $true)]$EventRecord
    )

    [string]$playerName = Normalize-LevelUpPlayerName -PlayerName ([string](Get-LevelUpFieldValue -Object $EventRecord -Name 'PlayerName' -Default 'Player'))
    [int]$fromLevel = ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $EventRecord -Name 'FromLevel' -Default 0) -Default 0
    [int]$toLevel = ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $EventRecord -Name 'ToLevel' -Default 0) -Default 0
    [string]$source = [string](Get-LevelUpFieldValue -Object $EventRecord -Name 'Source' -Default 'LevelUp')

    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = 'LevelUp'
    }

    [datetime]$timestampUtc = [datetime]::MinValue
    $timestampRaw = Get-LevelUpFieldValue -Object $EventRecord -Name 'TimestampUtc' -Default $null
    if ($null -ne $timestampRaw) {
        try {
            $timestampUtc = [datetime]$timestampRaw
        }
        catch {
            $timestampUtc = [datetime]::MinValue
        }
    }

    return ('{0}|{1}|{2}|{3}|{4}' -f $playerName, $fromLevel, $toLevel, $source, ([int64]$timestampUtc.Ticks))
}

function New-LevelUpEffectDescriptor {
    param(
        [int]$FromLevel,
        [int]$ToLevel
    )

    [int]$levelsGained = [int]([Math]::Max(1, ($ToLevel - $FromLevel)))

    return [PSCustomObject]@{
        TokenId      = 'fx.levelup.pulse'
        Animation    = 'PulseRing'
        DurationMs   = [int](650 + (($levelsGained - 1) * 50))
        Theme        = 'LevelUpGold'
        EventMarker  = 'LEVELUP_EFFECT_QUEUED'
        LevelsGained = [int]$levelsGained
    }
}

function Get-LevelUpSoundDescriptor {
    param(
        [string]$PlayerName,
        [int]$ToLevel
    )

    $audioCommand = $null
    foreach ($candidate in @('Invoke-GameSoundCue', 'Invoke-AudioCue', 'Play-Sound')) {
        $resolved = Get-Command -Name $candidate -ErrorAction SilentlyContinue
        if ($null -ne $resolved) {
            $audioCommand = $resolved
            break
        }
    }

    if ($null -eq $audioCommand) {
        return [PSCustomObject]@{
            CueId        = 'ui.levelup.chime'
            Status       = 'fallback'
            EventMarker  = 'AUDIO_BACKEND_UNAVAILABLE'
            Backend      = ''
            PlayerName   = [string](Normalize-LevelUpPlayerName -PlayerName $PlayerName)
            Level        = [int]$ToLevel
        }
    }

    return [PSCustomObject]@{
        CueId        = 'ui.levelup.chime'
        Status       = 'queued'
        EventMarker  = 'AUDIO_CUE_QUEUED'
        Backend      = [string]$audioCommand.Name
        PlayerName   = [string](Normalize-LevelUpPlayerName -PlayerName $PlayerName)
        Level        = [int]$ToLevel
    }
}

function Invoke-LevelUpNotificationCallbacks {
    param(
        [Parameter(Mandatory = $true)]$Notification
    )

    foreach ($callback in @($script:LevelUpNotificationCallbacks)) {
        if ($null -eq $callback) {
            continue
        }

        try {
            & $callback $Notification | Out-Null
        }
        catch {
            Write-Warning ("[LevelUp] Notification callback failed: {0}" -f $_.Exception.Message)
        }
    }
}

function Get-LevelUpPointsGranted {
    param($GrantResult)

    if ($null -eq $GrantResult) {
        return [int]0
    }

    if ($GrantResult -is [System.Collections.IDictionary]) {
        if ($GrantResult.Contains('PointsGranted')) {
            return [int](ConvertTo-LevelUpInt -Value $GrantResult['PointsGranted'] -Default 0)
        }

        return [int]0
    }

    if ($null -ne $GrantResult.PSObject.Properties['PointsGranted']) {
        return [int](ConvertTo-LevelUpInt -Value $GrantResult.PointsGranted -Default 0)
    }

    return [int]0
}

function Invoke-LevelUpStatGrant {
    param(
        $Player,
        [int]$ToLevel,
        [string]$Source = 'LevelUpEvent'
    )

    if ($null -eq $Player) {
        return $null
    }

    $syncCommand = Get-Command -Name 'Sync-PlayerStatProgression' -ErrorAction SilentlyContinue
    if ($null -eq $syncCommand) {
        return $null
    }

    $enableCommand = Get-Command -Name 'Enable-PlayerStatProgression' -ErrorAction SilentlyContinue
    if ($null -ne $enableCommand) {
        try {
            Enable-PlayerStatProgression -Player $Player | Out-Null
        }
        catch {
        }
    }

    [int]$targetLevel = ConvertTo-LevelUpInt -Value $ToLevel -Default 1
    if ($targetLevel -lt 1) {
        $targetLevel = [int]1
    }

    [int]$originalLevel = ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $Player -Name 'Level' -Default $targetLevel) -Default $targetLevel
    [bool]$restoreOriginalLevel = $false

    if ($originalLevel -gt $targetLevel) {
        $restoreOriginalLevel = $true
        $Player.Level = [int]$targetLevel
    }
    elseif ($originalLevel -lt $targetLevel) {
        $Player.Level = [int]$targetLevel
    }

    $syncResult = $null
    try {
        $syncResult = Sync-PlayerStatProgression -Player $Player -Source $Source
    }
    catch {
        $syncResult = [PSCustomObject]@{
            Source        = [string]$Source
            PointsGranted = [int]0
            Reason        = "StatSyncFailed:$($_.Exception.Message)"
        }
    }

    if ($restoreOriginalLevel) {
        $Player.Level = [int]$originalLevel

        $snapshotCommand = Get-Command -Name 'Sync-StatsModuleSnapshot' -ErrorAction SilentlyContinue
        if ($null -ne $snapshotCommand) {
            try {
                Sync-StatsModuleSnapshot -Player $Player | Out-Null
            }
            catch {
            }
        }
    }

    return $syncResult
}

function Invoke-LevelUpSkillGrant {
    param(
        $SkillTree,
        [int]$ToLevel,
        [int]$LevelsGained = 1,
        [string]$Source = 'LevelUpEvent'
    )

    if ($null -eq $SkillTree) {
        return $null
    }

    $syncCommand = Get-Command -Name 'Sync-SkillTreeLevel' -ErrorAction SilentlyContinue
    if ($null -ne $syncCommand) {
        try {
            return (Sync-SkillTreeLevel -SkillTree $SkillTree -Level $ToLevel -Source $Source)
        }
        catch {
            return [PSCustomObject]@{
                Source        = [string]$Source
                PointsGranted = [int]0
                Reason        = "SkillSyncFailed:$($_.Exception.Message)"
            }
        }
    }

    $grantCommand = Get-Command -Name 'Grant-SkillPointsFromLevelUp' -ErrorAction SilentlyContinue
    if ($null -ne $grantCommand) {
        try {
            return (Grant-SkillPointsFromLevelUp -SkillTree $SkillTree -LevelsGained $LevelsGained -Source $Source)
        }
        catch {
            return [PSCustomObject]@{
                Source        = [string]$Source
                PointsGranted = [int]0
                Reason        = "SkillGrantFailed:$($_.Exception.Message)"
            }
        }
    }

    return $null
}

function Trim-LevelUpNotificationHistory {
    while ($script:LevelUpNotificationHistory.Count -gt $script:LevelUpNotificationRetention) {
        $script:LevelUpNotificationHistory.RemoveAt(0)
    }
}

# ============================================================================
# Public API - Initialization and Wiring
# ============================================================================

function Initialize-LevelUpSystem {
    <#
    .SYNOPSIS
        Initializes deterministic level-up mechanics integration state.
    #>
    param([switch]$Quiet)

    $script:LevelUpSystemInitialized = $true
    $script:LevelUpNotificationHistory = [System.Collections.ArrayList]::new()
    $script:LevelUpNotificationCallbacks = @()
    $script:LevelUpProcessedEventKeys = @{}
    $script:LevelUpPlayerContextByKey = @{}
    $script:LevelUpNotificationRetention = [int]100
    $script:LevelUpExperienceHookRegistered = $false
    $script:LevelUpExperienceHookId = [int]0

    Connect-LevelUpExperience -Quiet | Out-Null

    if (-not $Quiet) {
        Write-Host '[LevelUp] Level-up system initialized.' -ForegroundColor Green
    }

    return (Get-LevelUpSystemStatus)
}

function Ensure-LevelUpSystem {
    if (-not $script:LevelUpSystemInitialized) {
        Initialize-LevelUpSystem -Quiet | Out-Null
    }
}

function Connect-LevelUpExperience {
    <#
    .SYNOPSIS
        Registers LevelUp callback with Experience level-up events.
    #>
    param([switch]$Quiet)

    Ensure-LevelUpSystem

    if ([bool]$script:LevelUpExperienceHookRegistered) {
        return [PSCustomObject]@{
            HookRegistered   = $true
            AlreadyRegistered = $true
            HookId           = [int]$script:LevelUpExperienceHookId
            Reason           = 'AlreadyConnected'
        }
    }

    $registerCallbackCommand = Get-Command -Name 'Register-LevelUpCallback' -ErrorAction SilentlyContinue
    if ($null -eq $registerCallbackCommand) {
        return [PSCustomObject]@{
            HookRegistered   = $false
            AlreadyRegistered = $false
            HookId           = [int]0
            Reason           = 'Register-LevelUpCallbackUnavailable'
        }
    }

    $callback = {
        param($EventRecord)

        return (Invoke-LevelUpEvent -EventRecord $EventRecord)
    }.GetNewClosure()

    try {
        $hookId = Register-LevelUpCallback -Callback $callback
        $script:LevelUpExperienceHookRegistered = $true
        $script:LevelUpExperienceHookId = [int](ConvertTo-LevelUpInt -Value $hookId -Default 0)

        if (-not $Quiet) {
            Write-Host ('[LevelUp] Connected to Experience callbacks (hook id: {0}).' -f $script:LevelUpExperienceHookId) -ForegroundColor Green
        }

        return [PSCustomObject]@{
            HookRegistered   = $true
            AlreadyRegistered = $false
            HookId           = [int]$script:LevelUpExperienceHookId
            Reason           = 'Connected'
        }
    }
    catch {
        return [PSCustomObject]@{
            HookRegistered   = $false
            AlreadyRegistered = $false
            HookId           = [int]0
            Reason           = "RegisterFailed:$($_.Exception.Message)"
        }
    }
}

function Register-LevelUpPlayerContext {
    <#
    .SYNOPSIS
        Registers player and optional skill tree references for level-up grants.
    #>
    param(
        $Player = $null,
        $SkillTree = $null,
        [string]$PlayerName = ''
    )

    Ensure-LevelUpSystem

    [string]$resolvedName = ''

    if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
        $resolvedName = [string]$PlayerName
    }

    if ([string]::IsNullOrWhiteSpace($resolvedName) -and ($null -ne $Player)) {
        $resolvedName = [string](Get-LevelUpFieldValue -Object $Player -Name 'Name' -Default '')
    }

    if ([string]::IsNullOrWhiteSpace($resolvedName) -and ($null -ne $SkillTree)) {
        $resolvedName = [string](Get-LevelUpFieldValue -Object $SkillTree -Name 'PlayerName' -Default '')
    }

    $resolvedName = Normalize-LevelUpPlayerName -PlayerName $resolvedName
    [string]$key = Get-LevelUpPlayerKey -PlayerName $resolvedName

    $context = $null
    if ($script:LevelUpPlayerContextByKey.ContainsKey($key)) {
        $context = $script:LevelUpPlayerContextByKey[$key]
    }
    else {
        $context = [PSCustomObject]@{
            PlayerName    = [string]$resolvedName
            Player        = $null
            SkillTree     = $null
            RegisteredUtc = [datetime]::UtcNow
            UpdatedUtc    = [datetime]::UtcNow
        }
    }

    if ($null -ne $Player) {
        $context.Player = $Player
        if ([string]::IsNullOrWhiteSpace([string](Get-LevelUpFieldValue -Object $Player -Name 'Name' -Default ''))) {
            Add-LevelUpObjectProperty -Object $Player -Name 'Name' -Value ([string]$resolvedName)
        }
    }

    if ($null -ne $SkillTree) {
        $context.SkillTree = $SkillTree
        Add-LevelUpObjectProperty -Object $SkillTree -Name 'PlayerName' -Value ([string]$resolvedName)
    }

    $context.PlayerName = [string]$resolvedName
    $context.UpdatedUtc = [datetime]::UtcNow

    $script:LevelUpPlayerContextByKey[$key] = $context

    return [PSCustomObject]@{
        PlayerName     = [string]$context.PlayerName
        PlayerBound    = [bool]($null -ne $context.Player)
        SkillTreeBound = [bool]($null -ne $context.SkillTree)
        UpdatedUtc     = [datetime]$context.UpdatedUtc
    }
}

function Unregister-LevelUpPlayerContext {
    <#
    .SYNOPSIS
        Removes player integration context by player name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PlayerName
    )

    Ensure-LevelUpSystem

    [string]$key = Get-LevelUpPlayerKey -PlayerName $PlayerName
    if ($script:LevelUpPlayerContextByKey.ContainsKey($key)) {
        $script:LevelUpPlayerContextByKey.Remove($key)
        return $true
    }

    return $false
}

function Get-LevelUpPlayerContexts {
    <#
    .SYNOPSIS
        Returns registered level-up player contexts.
    #>

    Ensure-LevelUpSystem

    $rows = @()
    foreach ($key in @($script:LevelUpPlayerContextByKey.Keys | Sort-Object)) {
        $entry = $script:LevelUpPlayerContextByKey[$key]
        $rows += [PSCustomObject]@{
            PlayerName     = [string]$entry.PlayerName
            PlayerBound    = [bool]($null -ne $entry.Player)
            SkillTreeBound = [bool]($null -ne $entry.SkillTree)
            RegisteredUtc  = [datetime]$entry.RegisteredUtc
            UpdatedUtc     = [datetime]$entry.UpdatedUtc
        }
    }

    return @($rows)
}

function Enable-LevelUpIntegration {
    <#
    .SYNOPSIS
        Convenience wrapper to register context and connect callbacks.
    #>
    param(
        [Parameter(Mandatory = $true)]$Player,
        $SkillTree = $null,
        [switch]$ConnectExperience
    )

    Ensure-LevelUpSystem

    $context = Register-LevelUpPlayerContext -Player $Player -SkillTree $SkillTree
    $hook = if ($ConnectExperience) { Connect-LevelUpExperience -Quiet } else { Get-LevelUpSystemStatus }

    return [PSCustomObject]@{
        Context = $context
        Hook    = $hook
    }
}

# ============================================================================
# Public API - Event Handling and Notifications
# ============================================================================

function Register-LevelUpNotificationCallback {
    <#
    .SYNOPSIS
        Registers a callback receiving one level-up notification object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )

    Ensure-LevelUpSystem
    $script:LevelUpNotificationCallbacks += $Callback
    return [int]$script:LevelUpNotificationCallbacks.Count
}

function Invoke-LevelUpEvent {
    <#
    .SYNOPSIS
        Processes one level-up event from Experience callback history.
    #>
    param(
        [Parameter(Mandatory = $true)]$EventRecord,
        [switch]$SuppressDisplay
    )

    Ensure-LevelUpSystem

    if ($null -eq $EventRecord) {
        return [PSCustomObject]@{
            Processed      = $false
            Reason         = 'NullEvent'
            EventKey       = ''
            NotificationId = ''
            Notification   = $null
        }
    }

    [string]$eventKey = Get-LevelUpEventKey -EventRecord $EventRecord
    if ($script:LevelUpProcessedEventKeys.ContainsKey($eventKey)) {
        return [PSCustomObject]@{
            Processed      = $false
            Reason         = 'DuplicateEvent'
            EventKey       = [string]$eventKey
            NotificationId = [string]$script:LevelUpProcessedEventKeys[$eventKey]
            Notification   = $null
        }
    }

    [string]$playerName = Normalize-LevelUpPlayerName -PlayerName ([string](Get-LevelUpFieldValue -Object $EventRecord -Name 'PlayerName' -Default 'Player'))
    [int]$fromLevel = ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $EventRecord -Name 'FromLevel' -Default 0) -Default 0
    [int]$toLevel = ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $EventRecord -Name 'ToLevel' -Default 1) -Default 1

    if ($toLevel -lt 1) {
        $toLevel = [int]1
    }

    [int]$levelsGained = [int]($toLevel - $fromLevel)
    if ($levelsGained -lt 1) {
        $levelsGained = [int]1
    }

    [string]$source = [string](Get-LevelUpFieldValue -Object $EventRecord -Name 'Source' -Default 'LevelUp')
    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = 'LevelUp'
    }

    [datetime]$timestampUtc = [datetime]::UtcNow
    $timestampRaw = Get-LevelUpFieldValue -Object $EventRecord -Name 'TimestampUtc' -Default $null
    if ($null -ne $timestampRaw) {
        try {
            $timestampUtc = [datetime]$timestampRaw
        }
        catch {
            $timestampUtc = [datetime]::UtcNow
        }
    }

    [string]$contextKey = Get-LevelUpPlayerKey -PlayerName $playerName
    $context = $null
    if ($script:LevelUpPlayerContextByKey.ContainsKey($contextKey)) {
        $context = $script:LevelUpPlayerContextByKey[$contextKey]
    }

    $statGrantResult = $null
    $skillGrantResult = $null
    [int]$statPointsGranted = [int]0
    [int]$skillPointsGranted = [int]0

    if ($null -ne $context) {
        if ($null -ne $context.Player) {
            $statGrantResult = Invoke-LevelUpStatGrant -Player $context.Player -ToLevel $toLevel -Source 'LevelUpEvent'
            $statPointsGranted = [int](Get-LevelUpPointsGranted -GrantResult $statGrantResult)
        }

        if ($null -ne $context.SkillTree) {
            $skillGrantResult = Invoke-LevelUpSkillGrant -SkillTree $context.SkillTree -ToLevel $toLevel -LevelsGained $levelsGained -Source 'LevelUpEvent'
            $skillPointsGranted = [int](Get-LevelUpPointsGranted -GrantResult $skillGrantResult)
        }
    }

    $effect = New-LevelUpEffectDescriptor -FromLevel $fromLevel -ToLevel $toLevel
    $sound = Get-LevelUpSoundDescriptor -PlayerName $playerName -ToLevel $toLevel

    [string]$message = if ($levelsGained -gt 1) {
        '{0} reached level {1} (+{2} levels)' -f $playerName, $toLevel, $levelsGained
    }
    else {
        '{0} reached level {1}' -f $playerName, $toLevel
    }

    [string]$notificationId = [string]([guid]::NewGuid())

    $notification = [PSCustomObject]@{
        NotificationId = [string]$notificationId
        EventKey       = [string]$eventKey
        TimestampUtc   = [datetime]$timestampUtc
        PlayerName     = [string]$playerName
        FromLevel      = [int]$fromLevel
        ToLevel        = [int]$toLevel
        LevelsGained   = [int]$levelsGained
        Source         = [string]$source
        NotificationType = 'LevelUp'
        Message        = [string]$message
        Effect         = $effect
        Sound          = $sound
        Grants         = [PSCustomObject]@{
            StatPointsGranted  = [int]$statPointsGranted
            SkillPointsGranted = [int]$skillPointsGranted
            StatGrantResult    = $statGrantResult
            SkillGrantResult   = $skillGrantResult
        }
        UI             = [PSCustomObject]@{
            CurrentLevel      = [int]$toLevel
            Message           = [string]$message
            NotificationType  = 'LevelUp'
            DisplayPriority   = [int]100
            EffectToken       = [string]$effect.TokenId
            SoundCueId        = [string]$sound.CueId
        }
    }

    $script:LevelUpNotificationHistory.Add($notification) | Out-Null
    $script:LevelUpProcessedEventKeys[$eventKey] = [string]$notificationId
    Trim-LevelUpNotificationHistory

    if (-not $SuppressDisplay) {
        Write-Host ('[LevelUp] {0}' -f $message) -ForegroundColor Cyan
    }

    Invoke-LevelUpNotificationCallbacks -Notification $notification

    return [PSCustomObject]@{
        Processed      = $true
        Reason         = 'Processed'
        EventKey       = [string]$eventKey
        NotificationId = [string]$notificationId
        Notification   = $notification
    }
}

function Get-LevelUpNotificationHistory {
    <#
    .SYNOPSIS
        Returns recorded level-up notifications in chronological order.
    #>
    param(
        [string]$PlayerName = ''
    )

    Ensure-LevelUpSystem

    if ([string]::IsNullOrWhiteSpace($PlayerName)) {
        return @($script:LevelUpNotificationHistory)
    }

    [string]$target = Normalize-LevelUpPlayerName -PlayerName $PlayerName
    $rows = @()
    foreach ($entry in @($script:LevelUpNotificationHistory)) {
        if ([string]::Equals([string]$entry.PlayerName, [string]$target, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rows += $entry
        }
    }

    return @($rows)
}

function Get-RecentLevelUpNotifications {
    <#
    .SYNOPSIS
        Returns recent level-up notifications (most recent first).
    #>
    param(
        [string]$PlayerName = '',
        [int]$MaxCount = 10
    )

    Ensure-LevelUpSystem

    [int]$safeMaxCount = ConvertTo-LevelUpInt -Value $MaxCount -Default 10
    if ($safeMaxCount -lt 1) {
        $safeMaxCount = [int]1
    }

    [string]$target = ''
    [bool]$hasFilter = $false
    if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
        $target = Normalize-LevelUpPlayerName -PlayerName $PlayerName
        $hasFilter = $true
    }

    $rows = [System.Collections.ArrayList]::new()
    for ([int]$i = $script:LevelUpNotificationHistory.Count - 1; $i -ge 0; $i--) {
        $entry = $script:LevelUpNotificationHistory[$i]

        if ($hasFilter -and (-not [string]::Equals([string]$entry.PlayerName, [string]$target, [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }

        $rows.Add($entry) | Out-Null
        if ($rows.Count -ge $safeMaxCount) {
            break
        }
    }

    return @($rows)
}

function Get-LatestLevelUpNotification {
    <#
    .SYNOPSIS
        Gets the latest level-up notification for a player (or global).
    #>
    param(
        [string]$PlayerName = ''
    )

    $rows = @(Get-RecentLevelUpNotifications -PlayerName $PlayerName -MaxCount 1)
    if ($rows.Count -lt 1) {
        return $null
    }

    return $rows[0]
}

function Clear-LevelUpNotifications {
    <#
    .SYNOPSIS
        Clears level-up notification history and processed event keys.
    #>

    Ensure-LevelUpSystem

    $script:LevelUpNotificationHistory = [System.Collections.ArrayList]::new()
    $script:LevelUpProcessedEventKeys = @{}
}

function Get-LevelUpHUDState {
    <#
    .SYNOPSIS
        Returns UI/HUD-facing state for level-up notifications.
    #>
    param(
        [string]$PlayerName = ''
    )

    Ensure-LevelUpSystem

    [string]$resolvedPlayerName = ''
    if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
        $resolvedPlayerName = Normalize-LevelUpPlayerName -PlayerName $PlayerName
    }

    $latest = Get-LatestLevelUpNotification -PlayerName $resolvedPlayerName
    if ([string]::IsNullOrWhiteSpace($resolvedPlayerName) -and ($null -ne $latest)) {
        $resolvedPlayerName = [string]$latest.PlayerName
    }

    [int]$currentLevel = [int]1
    if ($null -ne $latest) {
        $currentLevel = [int](ConvertTo-LevelUpInt -Value $latest.ToLevel -Default 1)
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedPlayerName)) {
        [string]$contextKey = Get-LevelUpPlayerKey -PlayerName $resolvedPlayerName
        if ($script:LevelUpPlayerContextByKey.ContainsKey($contextKey)) {
            $context = $script:LevelUpPlayerContextByKey[$contextKey]
            if ($null -ne $context.Player) {
                $currentLevel = [int](ConvertTo-LevelUpInt -Value (Get-LevelUpFieldValue -Object $context.Player -Name 'Level' -Default $currentLevel) -Default $currentLevel)
            }
        }
    }

    [int]$notificationCount = [int](Get-LevelUpNotificationHistory -PlayerName $resolvedPlayerName).Count

    return [PSCustomObject]@{
        PlayerName         = [string](Normalize-LevelUpPlayerName -PlayerName $resolvedPlayerName)
        CurrentLevel       = [int]$currentLevel
        NotificationCount  = [int]$notificationCount
        LatestNotification = $latest
        HasNotification    = [bool]($null -ne $latest)
        Api                = [PSCustomObject]@{
            RecentNotifications = 'Get-RecentLevelUpNotifications'
            LatestNotification  = 'Get-LatestLevelUpNotification'
            ClearNotifications  = 'Clear-LevelUpNotifications'
            RegisterContext     = 'Register-LevelUpPlayerContext'
        }
    }
}

function Get-LevelUpSystemStatus {
    <#
    .SYNOPSIS
        Returns current system wiring and queue status.
    #>

    Ensure-LevelUpSystem

    return [PSCustomObject]@{
        Initialized               = [bool]$script:LevelUpSystemInitialized
        ExperienceHookRegistered  = [bool]$script:LevelUpExperienceHookRegistered
        ExperienceHookId          = [int]$script:LevelUpExperienceHookId
        ContextCount              = [int]$script:LevelUpPlayerContextByKey.Count
        NotificationCount         = [int]$script:LevelUpNotificationHistory.Count
        ProcessedEventCount       = [int]$script:LevelUpProcessedEventKeys.Count
        NotificationRetention     = [int]$script:LevelUpNotificationRetention
    }
}

# Initialize on dot-source.
Initialize-LevelUpSystem -Quiet | Out-Null
