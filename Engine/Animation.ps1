# ============================================================================
# Engine/Animation.ps1 - Combat Animation State and Timing
# ============================================================================
# Lightweight animation system for combat entities.
#
# Supported states:
# - Idle
# - Attack
# - HitReaction
# - Death
#
# Features:
# - Per-entity animator registry
# - State playback with normalized progress [0..1]
# - Safe transitions (Death dominates)
# - Per-state timing overrides
# - Simple event callbacks and timing hooks for combat sync
#
# Optional dependency:
#   Engine/OpenGL.ps1 (Register-UpdateCallback)
# ============================================================================

# --- Module State ---
$script:AnimationInitialized      = $false
$script:AnimationUpdateRegistered = $false
$script:EntityAnimators           = @{}
$script:AnimationEventCallbacks   = [System.Collections.ArrayList]::new()

$script:AnimationDefaultDurations = @{
    Idle        = [float]1.00
    Attack      = [float]0.30
    HitReaction = [float]0.22
    Death       = [float]0.85
}

$script:AnimationLoopingStates = @{
    Idle        = $true
    Attack      = $false
    HitReaction = $false
    Death       = $false
}

$script:AnimationAutoReturnStates = @{
    Idle        = 'Idle'
    Attack      = 'Idle'
    HitReaction = 'Idle'
    Death       = 'Death'
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Ensure-AnimationSystemReady {
    if (-not $script:AnimationInitialized) {
        Initialize-AnimationSystem
    }
}

function Set-AnimationProperty {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    $prop = $Target.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Target.$Name = $Value
    }
}

function Get-AnimatorEntityKey {
    param([Parameter(Mandatory = $true)]$Entity)

    if ($null -eq $Entity) {
        return ''
    }

    try {
        [int]$refId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Entity)
        return [string]("ref:{0}" -f $refId)
    }
    catch {
        return [string]("obj:{0}" -f $Entity.GetHashCode())
    }
}

function Get-AnimatorStateDuration {
    param(
        [Parameter(Mandatory = $true)]$Animator,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State
    )

    [float]$duration = [float]0.0
    if ($null -ne $Animator.StateDurations -and $Animator.StateDurations.ContainsKey($State)) {
        $duration = [float]$Animator.StateDurations[$State]
    }

    if ($duration -le 0.0) {
        $duration = [float]$script:AnimationDefaultDurations[$State]
    }

    if ($duration -le 0.0) {
        $duration = [float]0.0001
    }

    return [float]$duration
}

function Sync-AnimatorToEntity {
    param([Parameter(Mandatory = $true)]$Animator)

    if ($null -eq $Animator.Entity) {
        return
    }

    Set-AnimationProperty -Target $Animator.Entity -Name 'AnimationState' -Value ([string]$Animator.CurrentState)
    Set-AnimationProperty -Target $Animator.Entity -Name 'AnimationProgress' -Value ([float]$Animator.Progress)
    Set-AnimationProperty -Target $Animator.Entity -Name 'AnimationElapsedTime' -Value ([float]$Animator.ElapsedTime)
    Set-AnimationProperty -Target $Animator.Entity -Name 'AnimationDuration' -Value ([float]$Animator.Duration)
    Set-AnimationProperty -Target $Animator.Entity -Name 'AnimationLoopCount' -Value ([int]$Animator.LoopCount)
}

function New-AnimationEventPayload {
    param(
        [Parameter(Mandatory = $true)]$Animator,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$EventName = '',
        [string]$Cause = ''
    )

    return [PSCustomObject]@{
        EventType    = [string]$EventType
        EventName    = [string]$EventName
        Cause        = [string]$Cause
        Entity       = $Animator.Entity
        EntityKey    = [string]$Animator.EntityKey
        State        = [string]$Animator.CurrentState
        PreviousState = [string]$Animator.PreviousState
        Progress     = [float]$Animator.Progress
        ElapsedTime  = [float]$Animator.ElapsedTime
        Duration     = [float]$Animator.Duration
        LoopCount    = [int]$Animator.LoopCount
        TimestampUtc = [DateTime]::UtcNow
    }
}

function Invoke-AnimationEvent {
    param([Parameter(Mandatory = $true)]$Event)

    foreach ($callback in @($script:AnimationEventCallbacks)) {
        try {
            & $callback $Event
        }
        catch {
            Write-Warning "[Animation] Event callback error: $_"
        }
    }
}

function Reset-AnimatorTimingHooks {
    param(
        [Parameter(Mandatory = $true)]$Animator,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State
    )

    foreach ($hook in @($Animator.TimingHooks)) {
        if ($hook.State -eq $State) {
            $hook.Fired = $false
        }
    }
}

function Invoke-AnimatorTimingHooks {
    param(
        [Parameter(Mandatory = $true)]$Animator,
        [Parameter(Mandatory = $true)][float]$PreviousProgress,
        [Parameter(Mandatory = $true)][float]$CurrentProgress,
        [bool]$Looped = $false
    )

    foreach ($hook in @($Animator.TimingHooks)) {
        if ($hook.State -ne $Animator.CurrentState) { continue }
        if ($hook.Fired) { continue }

        [float]$threshold = [float]$hook.Progress
        $crossed = $false

        if ($Looped) {
            if ($threshold -gt $PreviousProgress -or $threshold -le $CurrentProgress) {
                $crossed = $true
            }
        }
        else {
            if ($threshold -gt $PreviousProgress -and $threshold -le $CurrentProgress) {
                $crossed = $true
            }
        }

        if (-not $crossed) { continue }

        $hook.Fired = $true

        $event = New-AnimationEventPayload `
            -Animator $Animator `
            -EventType 'TimingHook' `
            -EventName ([string]$hook.EventName) `
            -Cause 'ProgressThreshold'

        if ($null -ne $hook.Callback) {
            try {
                & $hook.Callback $event
            }
            catch {
                Write-Warning "[Animation] Timing hook callback error: $_"
            }
        }

        Invoke-AnimationEvent -Event $event
    }
}

function Set-AnimatorStateInternal {
    param(
        [Parameter(Mandatory = $true)]$Animator,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State,
        [string]$Cause = 'Play',
        [switch]$ForceRestart
    )

    # Death dominates: once dead, no transitions except death itself.
    if ($Animator.CurrentState -eq 'Death' -and $State -ne 'Death') {
        return $false
    }

    if (-not $ForceRestart -and $Animator.CurrentState -eq $State) {
        return $false
    }

    $Animator.PreviousState = [string]$Animator.CurrentState
    $Animator.CurrentState = [string]$State
    $Animator.Duration = Get-AnimatorStateDuration -Animator $Animator -State $State
    $Animator.ElapsedTime = [float]0.0
    $Animator.Progress = [float]0.0
    $Animator.IsComplete = $false
    $Animator.IsLooping = [bool]$script:AnimationLoopingStates[$State]

    if ($Animator.PreviousState -ne $State) {
        $Animator.LoopCount = [int]0
    }

    Reset-AnimatorTimingHooks -Animator $Animator -State $State
    Sync-AnimatorToEntity -Animator $Animator

    $startedEvent = New-AnimationEventPayload `
        -Animator $Animator `
        -EventType 'AnimationStarted' `
        -EventName $State `
        -Cause $Cause

    Invoke-AnimationEvent -Event $startedEvent

    return $true
}

# ============================================================================
# Public API - Initialization and Registration
# ============================================================================

function Initialize-AnimationSystem {
    <#
    .SYNOPSIS
        Initializes animation state and registers the update callback.
    #>

    $script:EntityAnimators = @{}
    $script:AnimationEventCallbacks = [System.Collections.ArrayList]::new()
    $script:AnimationInitialized = $true

    if (-not $script:AnimationUpdateRegistered) {
        if (Get-Command -Name Register-UpdateCallback -ErrorAction SilentlyContinue) {
            Register-UpdateCallback ${function:Update-Animations}
            $script:AnimationUpdateRegistered = $true
        }
    }

    Write-Host "[Animation] Animation system initialized." -ForegroundColor Green
}

function Register-AnimationEventCallback {
    <#
    .SYNOPSIS
        Registers a callback for animation events.
    .DESCRIPTION
        Callback receives a single event object with state and timing details.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )

    Ensure-AnimationSystemReady

    $script:AnimationEventCallbacks.Add($Callback) | Out-Null
    return [int]$script:AnimationEventCallbacks.Count
}

function Register-EntityAnimator {
    <#
    .SYNOPSIS
        Creates and stores an animator for an entity.
    .PARAMETER Entity
        Entity object, usually a mutable PSCustomObject.
    .PARAMETER IdleDuration
        Duration of the Idle loop in seconds.
    .PARAMETER AttackDuration
        Duration of the Attack animation in seconds.
    .PARAMETER HitReactionDuration
        Duration of the HitReaction animation in seconds.
    .PARAMETER DeathDuration
        Duration of the Death animation in seconds.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [float]$IdleDuration = 1.00,
        [float]$AttackDuration = 0.30,
        [float]$HitReactionDuration = 0.22,
        [float]$DeathDuration = 0.85
    )

    Ensure-AnimationSystemReady

    $entityKey = Get-AnimatorEntityKey -Entity $Entity
    if ([string]::IsNullOrWhiteSpace($entityKey)) {
        return $null
    }

    if ($script:EntityAnimators.ContainsKey($entityKey)) {
        return $script:EntityAnimators[$entityKey]
    }

    [float]$safeIdle = [float][Math]::Max(0.0001, $IdleDuration)
    [float]$safeAttack = [float][Math]::Max(0.0001, $AttackDuration)
    [float]$safeHit = [float][Math]::Max(0.0001, $HitReactionDuration)
    [float]$safeDeath = [float][Math]::Max(0.0001, $DeathDuration)

    $stateDurations = @{
        Idle        = [float]$safeIdle
        Attack      = [float]$safeAttack
        HitReaction = [float]$safeHit
        Death       = [float]$safeDeath
    }

    $animator = [PSCustomObject]@{
        Entity        = $Entity
        EntityKey     = [string]$entityKey
        CurrentState  = [string]'Idle'
        PreviousState = [string]'Idle'
        Duration      = [float]$safeIdle
        ElapsedTime   = [float]0.0
        Progress      = [float]0.0
        IsLooping     = $true
        IsComplete    = $false
        LoopCount     = [int]0
        StateDurations = $stateDurations
        TimingHooks   = [System.Collections.ArrayList]::new()
    }

    $script:EntityAnimators[$entityKey] = $animator
    Sync-AnimatorToEntity -Animator $animator

    return $animator
}

function Unregister-EntityAnimator {
    <#
    .SYNOPSIS
        Removes an entity animator from the registry.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity
    )

    Ensure-AnimationSystemReady

    $entityKey = Get-AnimatorEntityKey -Entity $Entity
    if ([string]::IsNullOrWhiteSpace($entityKey)) {
        return $false
    }

    if ($script:EntityAnimators.ContainsKey($entityKey)) {
        $script:EntityAnimators.Remove($entityKey)
        return $true
    }

    return $false
}

function Get-EntityAnimator {
    <#
    .SYNOPSIS
        Returns the animator for an entity.
    .PARAMETER AutoCreate
        If set, creates a default animator when missing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [switch]$AutoCreate
    )

    Ensure-AnimationSystemReady

    $entityKey = Get-AnimatorEntityKey -Entity $Entity
    if ([string]::IsNullOrWhiteSpace($entityKey)) {
        return $null
    }

    if ($script:EntityAnimators.ContainsKey($entityKey)) {
        return $script:EntityAnimators[$entityKey]
    }

    if ($AutoCreate) {
        return Register-EntityAnimator -Entity $Entity
    }

    return $null
}

# ============================================================================
# Public API - Playback and Timing Hooks
# ============================================================================

function Play-EntityAnimation {
    <#
    .SYNOPSIS
        Plays an animation state on an entity animator.
    .DESCRIPTION
        Death state dominates and cannot be overridden by non-death states.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State,
        [switch]$ForceRestart
    )

    $animator = Get-EntityAnimator -Entity $Entity -AutoCreate
    if ($null -eq $animator) {
        return $false
    }

    return (Set-AnimatorStateInternal -Animator $animator -State $State -Cause 'Play' -ForceRestart:$ForceRestart)
}

function Play-EntityAttackAnimation {
    <#
    .SYNOPSIS
        Convenience wrapper for attack swing playback.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [switch]$ForceRestart
    )

    return (Play-EntityAnimation -Entity $Entity -State 'Attack' -ForceRestart:$ForceRestart)
}

function Play-EntityHitReactionAnimation {
    <#
    .SYNOPSIS
        Convenience wrapper for hit reaction playback.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [switch]$ForceRestart
    )

    return (Play-EntityAnimation -Entity $Entity -State 'HitReaction' -ForceRestart:$ForceRestart)
}

function Play-EntityDeathAnimation {
    <#
    .SYNOPSIS
        Convenience wrapper for death playback.
    .DESCRIPTION
        Death dominates and cannot be overridden by non-death states.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [switch]$ForceRestart
    )

    return (Play-EntityAnimation -Entity $Entity -State 'Death' -ForceRestart:$ForceRestart)
}

function Play-EntityIdleAnimation {
    <#
    .SYNOPSIS
        Convenience wrapper for idle playback.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [switch]$ForceRestart
    )

    return (Play-EntityAnimation -Entity $Entity -State 'Idle' -ForceRestart:$ForceRestart)
}

function Set-EntityAnimationStateDuration {
    <#
    .SYNOPSIS
        Sets one animation state duration for an entity animator.
    .DESCRIPTION
        Duration is clamped to a safe positive value.
        If the state is currently active, the running duration is updated too.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State,
        [Parameter(Mandatory = $true)][double]$DurationSeconds
    )

    $animator = Get-EntityAnimator -Entity $Entity -AutoCreate
    if ($null -eq $animator) {
        return $false
    }

    [float]$safeDuration = [float][Math]::Max(0.0001, $DurationSeconds)
    $animator.StateDurations[$State] = [float]$safeDuration

    if ($animator.CurrentState -eq $State) {
        $animator.Duration = [float]$safeDuration

        if ($animator.ElapsedTime -gt $animator.Duration) {
            $animator.ElapsedTime = [float]$animator.Duration
        }

        if ($animator.Duration -le 0.0) {
            $animator.Progress = [float]1.0
        }
        else {
            $animator.Progress = [float]([Math]::Min(1.0, [Math]::Max(0.0, ($animator.ElapsedTime / $animator.Duration))))
        }

        Sync-AnimatorToEntity -Animator $animator
    }

    return $true
}

function Set-EntityCombatAnimationTiming {
    <#
    .SYNOPSIS
        Applies simple combat timing defaults to an entity animator.
    .DESCRIPTION
        Keeps combat-relevant states explicit:
        - Attack syncs to combat swing duration
        - HitReaction, Death, and Idle get predictable defaults
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [double]$AttackDuration = 0.30,
        [double]$HitReactionDuration = 0.22,
        [double]$DeathDuration = 0.85,
        [double]$IdleDuration = 1.00
    )

    Set-EntityAnimationStateDuration -Entity $Entity -State 'Attack' -DurationSeconds $AttackDuration | Out-Null
    Set-EntityAnimationStateDuration -Entity $Entity -State 'HitReaction' -DurationSeconds $HitReactionDuration | Out-Null
    Set-EntityAnimationStateDuration -Entity $Entity -State 'Death' -DurationSeconds $DeathDuration | Out-Null
    Set-EntityAnimationStateDuration -Entity $Entity -State 'Idle' -DurationSeconds $IdleDuration | Out-Null

    return (Get-EntityAnimator -Entity $Entity)
}

function Register-AnimationTimingHook {
    <#
    .SYNOPSIS
        Registers a progress threshold hook for an entity animation state.
    .DESCRIPTION
        Hook is fired once per state entry. For looping states (Idle),
        hooks reset each loop.
    .PARAMETER Progress
        Normalized threshold [0..1].
    #>
    param(
        [Parameter(Mandatory = $true)]$Entity,
        [Parameter(Mandatory = $true)][ValidateSet('Idle', 'Attack', 'HitReaction', 'Death')][string]$State,
        [Parameter(Mandatory = $true)][double]$Progress,
        [string]$EventName = '',
        [scriptblock]$Callback = $null
    )

    $animator = Get-EntityAnimator -Entity $Entity -AutoCreate
    if ($null -eq $animator) {
        return $null
    }

    [float]$clampedProgress = [float][Math]::Max(0.0, [Math]::Min(1.0, $Progress))
    if ([string]::IsNullOrWhiteSpace($EventName)) {
        $EventName = [string]("{0}@{1:0.00}" -f $State, $clampedProgress)
    }

    $hook = [PSCustomObject]@{
        State     = [string]$State
        Progress  = [float]$clampedProgress
        EventName = [string]$EventName
        Callback  = $Callback
        Fired     = $false
    }

    if ($animator.CurrentState -eq $State -and $animator.Progress -ge $clampedProgress) {
        $hook.Fired = $true
    }

    $animator.TimingHooks.Add($hook) | Out-Null
    return $hook
}

# ============================================================================
# Public API - Update
# ============================================================================

function Update-Animations {
    <#
    .SYNOPSIS
        Updates all registered entity animators.
    .PARAMETER dt
        Delta time in seconds.
    #>
    param($dt)

    if ($null -eq $dt) { return }

    Ensure-AnimationSystemReady

    [float]$step = [float]$dt
    if ($step -le 0.0) { return }
    if ($step -gt 0.1) { $step = [float]0.1 }

    foreach ($animator in @($script:EntityAnimators.Values)) {
        if ($null -eq $animator) { continue }

        [float]$duration = [float]$animator.Duration
        if ($duration -le 0.0) {
            $duration = [float]0.0001
            $animator.Duration = [float]$duration
        }

        [float]$previousProgress = [float]$animator.Progress
        [float]$elapsed = [float]$animator.ElapsedTime + $step

        if ([bool]$animator.IsLooping) {
            $looped = $false

            while ($elapsed -ge $duration) {
                $elapsed = [float]($elapsed - $duration)
                $animator.LoopCount = [int]$animator.LoopCount + 1
                $looped = $true

                Reset-AnimatorTimingHooks -Animator $animator -State $animator.CurrentState

                $loopEvent = New-AnimationEventPayload `
                    -Animator $animator `
                    -EventType 'AnimationLoop' `
                    -EventName $animator.CurrentState `
                    -Cause 'Loop'

                Invoke-AnimationEvent -Event $loopEvent
            }

            $animator.ElapsedTime = [float]$elapsed
            $animator.Progress = [float]($elapsed / $duration)
            if ($animator.Progress -lt 0.0) { $animator.Progress = [float]0.0 }
            if ($animator.Progress -gt 1.0) { $animator.Progress = [float]1.0 }

            Invoke-AnimatorTimingHooks `
                -Animator $animator `
                -PreviousProgress $previousProgress `
                -CurrentProgress ([float]$animator.Progress) `
                -Looped:$looped

            Sync-AnimatorToEntity -Animator $animator
            continue
        }

        if ($elapsed -ge $duration) {
            $elapsed = [float]$duration
        }

        $animator.ElapsedTime = [float]$elapsed
        $animator.Progress = [float]($elapsed / $duration)
        if ($animator.Progress -lt 0.0) { $animator.Progress = [float]0.0 }
        if ($animator.Progress -gt 1.0) { $animator.Progress = [float]1.0 }

        Invoke-AnimatorTimingHooks `
            -Animator $animator `
            -PreviousProgress $previousProgress `
            -CurrentProgress ([float]$animator.Progress)

        Sync-AnimatorToEntity -Animator $animator

        if (-not $animator.IsComplete -and $animator.Progress -ge 1.0) {
            $animator.IsComplete = $true

            $completeEvent = New-AnimationEventPayload `
                -Animator $animator `
                -EventType 'AnimationCompleted' `
                -EventName $animator.CurrentState `
                -Cause 'DurationElapsed'

            Invoke-AnimationEvent -Event $completeEvent

            $nextState = [string]$script:AnimationAutoReturnStates[$animator.CurrentState]
            if ($animator.CurrentState -ne 'Death' -and -not [string]::IsNullOrWhiteSpace($nextState)) {
                Set-AnimatorStateInternal -Animator $animator -State $nextState -Cause 'AutoReturn' | Out-Null
            }
            else {
                Sync-AnimatorToEntity -Animator $animator
            }
        }
    }
}
