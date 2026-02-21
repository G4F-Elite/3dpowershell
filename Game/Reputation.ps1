# ============================================================================
# Game/Reputation.ps1 - Faction Reputation Tracking and Gates
# ============================================================================
# Provides a simple faction reputation system with:
# - Deterministic reputation level mapping
# - Up to 5 tracked factions by default
# - Gain and loss APIs
# - Gate helpers for dialog/content checks
# - Dialog compatibility hooks: Get-Reputation, Set-Reputation, Add-Reputation
# ============================================================================

# --- Module State ---
$script:ReputationInitialized = $false
$script:ReputationFactions = @{}
$script:ReputationDefaultFaction = 'Global'
$script:ReputationMaxFactions = [int]5
$script:ReputationMinValue = [int]-1000
$script:ReputationMaxValue = [int]1000

# ============================================================================
# Internal Helpers
# ============================================================================

function Get-ReputationFactionKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return $Name.Trim().ToLowerInvariant()
}

function Resolve-ReputationFactionName {
    param([string]$Faction)

    if ([string]::IsNullOrWhiteSpace($Faction)) {
        return [string]$script:ReputationDefaultFaction
    }

    return [string]$Faction.Trim()
}

function Clamp-ReputationValue {
    param([int]$Value)

    if ($Value -lt $script:ReputationMinValue) {
        return [int]$script:ReputationMinValue
    }

    if ($Value -gt $script:ReputationMaxValue) {
        return [int]$script:ReputationMaxValue
    }

    return [int]$Value
}

function ConvertTo-ReputationLevelName {
    param([string]$Level)

    if ([string]::IsNullOrWhiteSpace($Level)) {
        return ''
    }

    switch ($Level.Trim().ToLowerInvariant()) {
        'hated' { return 'Hated' }
        'hostile' { return 'Hostile' }
        'neutral' { return 'Neutral' }
        'friendly' { return 'Friendly' }
        'honored' { return 'Honored' }
        'exalted' { return 'Exalted' }
        default { return '' }
    }
}

function Get-ReputationLevelRankInternal {
    param([string]$Level)

    $levelName = ConvertTo-ReputationLevelName -Level $Level
    switch ($levelName) {
        'Hated' { return [int]0 }
        'Hostile' { return [int]1 }
        'Neutral' { return [int]2 }
        'Friendly' { return [int]3 }
        'Honored' { return [int]4 }
        'Exalted' { return [int]5 }
        default { return [int]-1 }
    }
}

function New-ReputationFactionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Value = 0
    )

    $safeName = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'Faction'
    }

    $safeValue = Clamp-ReputationValue -Value $Value

    return [PSCustomObject]@{
        Name  = [string]$safeName
        Key   = (Get-ReputationFactionKey -Name $safeName)
        Value = [int]$safeValue
        Level = (Resolve-ReputationLevel -Value $safeValue)
    }
}

function Set-ReputationFactionValueInternal {
    param(
        [Parameter(Mandatory = $true)]$FactionRecord,
        [int]$Value
    )

    $clampedValue = Clamp-ReputationValue -Value $Value
    $FactionRecord.Value = [int]$clampedValue
    $FactionRecord.Level = Resolve-ReputationLevel -Value $clampedValue

    return $FactionRecord
}

function Ensure-ReputationSystem {
    if (-not $script:ReputationInitialized) {
        Initialize-ReputationSystem -Quiet
    }
}

# ============================================================================
# Public API - Initialization and Faction Management
# ============================================================================

function Initialize-ReputationSystem {
    <#
    .SYNOPSIS
        Initializes faction reputation state.
    .DESCRIPTION
        Resets all tracked factions and creates the default faction entry.
        Max factions are clamped to 1..5 to keep scope constrained.
    #>
    param(
        [int]$MaxFactions = 5,
        [string]$DefaultFaction = 'Global',
        [int]$DefaultReputation = 0,
        [switch]$Quiet
    )

    if ($MaxFactions -lt 1) { $MaxFactions = 1 }
    if ($MaxFactions -gt 5) { $MaxFactions = 5 }

    if ([string]::IsNullOrWhiteSpace($DefaultFaction)) {
        $DefaultFaction = 'Global'
    }

    $script:ReputationInitialized = $true
    $script:ReputationFactions = @{}
    $script:ReputationMaxFactions = [int]$MaxFactions
    $script:ReputationDefaultFaction = [string]$DefaultFaction.Trim()

    $defaultRecord = New-ReputationFactionRecord -Name $script:ReputationDefaultFaction -Value $DefaultReputation
    $script:ReputationFactions[$defaultRecord.Key] = $defaultRecord

    if (-not $Quiet) {
        Write-Host "[Reputation] Reputation system initialized (max factions: $($script:ReputationMaxFactions))." -ForegroundColor Green
    }

    return $defaultRecord
}

function Get-ReputationDefaultFaction {
    <#
    .SYNOPSIS
        Gets the current default faction used by unnamed calls.
    #>

    Ensure-ReputationSystem
    return [string]$script:ReputationDefaultFaction
}

function Set-ReputationDefaultFaction {
    <#
    .SYNOPSIS
        Sets the default faction for dialog/global hook calls.
    .PARAMETER Faction
        Faction to become default.
    .PARAMETER CreateIfMissing
        Creates faction if it does not exist and capacity allows.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Faction,
        [switch]$CreateIfMissing
    )

    Ensure-ReputationSystem

    $resolvedName = Resolve-ReputationFactionName -Faction $Faction
    $key = Get-ReputationFactionKey -Name $resolvedName

    if (-not $script:ReputationFactions.ContainsKey($key)) {
        if ($CreateIfMissing) {
            $created = New-ReputationFaction -Name $resolvedName
            if ($null -eq $created) {
                return $false
            }
        }
        else {
            Write-Warning "[Reputation] Cannot set default faction. '$resolvedName' is not tracked."
            return $false
        }
    }

    $script:ReputationDefaultFaction = [string]$script:ReputationFactions[$key].Name
    return $true
}

function New-ReputationFaction {
    <#
    .SYNOPSIS
        Creates a faction reputation record.
    .DESCRIPTION
        Does not create duplicates. Enforces max faction count.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$InitialValue = 0
    )

    Ensure-ReputationSystem

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Warning '[Reputation] New-ReputationFaction requires a faction name.'
        return $null
    }

    $safeName = $Name.Trim()
    $key = Get-ReputationFactionKey -Name $safeName

    if ($script:ReputationFactions.ContainsKey($key)) {
        return $script:ReputationFactions[$key]
    }

    if ($script:ReputationFactions.Count -ge $script:ReputationMaxFactions) {
        Write-Warning "[Reputation] Faction limit reached ($($script:ReputationMaxFactions)). Cannot add '$safeName'."
        return $null
    }

    $record = New-ReputationFactionRecord -Name $safeName -Value $InitialValue
    $script:ReputationFactions[$record.Key] = $record
    return $record
}

function Get-ReputationFaction {
    <#
    .SYNOPSIS
        Gets a faction reputation record by name.
    .PARAMETER Name
        Faction name. Uses default faction when omitted.
    .PARAMETER CreateIfMissing
        Creates faction if missing and capacity allows.
    #>
    param(
        [string]$Name = '',
        [switch]$CreateIfMissing
    )

    Ensure-ReputationSystem

    $resolvedName = Resolve-ReputationFactionName -Faction $Name
    $key = Get-ReputationFactionKey -Name $resolvedName

    if ($script:ReputationFactions.ContainsKey($key)) {
        return $script:ReputationFactions[$key]
    }

    if ($CreateIfMissing) {
        return (New-ReputationFaction -Name $resolvedName)
    }

    return $null
}

function Get-ReputationFactions {
    <#
    .SYNOPSIS
        Returns all tracked factions.
    #>

    Ensure-ReputationSystem

    $result = @()
    foreach ($entry in $script:ReputationFactions.Values) {
        if ($null -ne $entry) {
            $result += $entry
        }
    }

    return ,$result
}

function Remove-ReputationFaction {
    <#
    .SYNOPSIS
        Removes a non-default faction record.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Force
    )

    Ensure-ReputationSystem

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $key = Get-ReputationFactionKey -Name $Name
    if (-not $script:ReputationFactions.ContainsKey($key)) {
        return $false
    }

    $defaultKey = Get-ReputationFactionKey -Name $script:ReputationDefaultFaction
    if ($key -eq $defaultKey -and -not $Force) {
        Write-Warning '[Reputation] Cannot remove default faction without -Force.'
        return $false
    }

    $null = $script:ReputationFactions.Remove($key)

    if ($script:ReputationFactions.Count -le 0) {
        $script:ReputationDefaultFaction = 'Global'
        $record = New-ReputationFactionRecord -Name $script:ReputationDefaultFaction -Value 0
        $script:ReputationFactions[$record.Key] = $record
    }

    return $true
}

# ============================================================================
# Public API - Reputation Values and Levels
# ============================================================================

function Resolve-ReputationLevel {
    <#
    .SYNOPSIS
        Maps a numeric reputation value to a deterministic level.
    .DESCRIPTION
        Thresholds:
        -1000..-500 = Hated
        -499..-100  = Hostile
        -99..99     = Neutral
        100..499    = Friendly
        500..999    = Honored
        1000+       = Exalted
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Value
    )

    $safeValue = Clamp-ReputationValue -Value $Value

    if ($safeValue -le -500) { return 'Hated' }
    if ($safeValue -le -100) { return 'Hostile' }
    if ($safeValue -lt 100) { return 'Neutral' }
    if ($safeValue -lt 500) { return 'Friendly' }
    if ($safeValue -lt 1000) { return 'Honored' }
    return 'Exalted'
}

function Get-ReputationLevel {
    <#
    .SYNOPSIS
        Gets reputation level for a faction or explicit value.
    #>
    param(
        [Parameter(ParameterSetName = 'Faction')][string]$Faction = '',
        [Parameter(Mandatory = $true, ParameterSetName = 'Value')][int]$Value
    )

    if ($PSCmdlet.ParameterSetName -eq 'Value') {
        return (Resolve-ReputationLevel -Value $Value)
    }

    return (Get-Reputation -Faction $Faction -AsLevel -CreateIfMissing)
}

function Get-Reputation {
    <#
    .SYNOPSIS
        Gets numeric reputation (or level with -AsLevel).
    .DESCRIPTION
        This is a dialog compatibility hook. If called without faction,
        the default faction value is returned.
    #>
    param(
        [string]$Faction = '',
        [switch]$AsLevel,
        [switch]$CreateIfMissing
    )

    $record = Get-ReputationFaction -Name $Faction -CreateIfMissing:$CreateIfMissing
    if ($null -eq $record) {
        if ($AsLevel) {
            return (Resolve-ReputationLevel -Value 0)
        }
        return [int]0
    }

    if ($AsLevel) {
        return [string]$record.Level
    }

    return [int]$record.Value
}

function Set-Reputation {
    <#
    .SYNOPSIS
        Sets faction reputation to an absolute value.
    .DESCRIPTION
        This is a dialog compatibility hook. Positional call `Set-Reputation 25`
        updates the default faction.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][int]$Value,
        [string]$Faction = '',
        [switch]$PassThru
    )

    $record = Get-ReputationFaction -Name $Faction -CreateIfMissing
    if ($null -eq $record) {
        return $null
    }

    $updated = Set-ReputationFactionValueInternal -FactionRecord $record -Value $Value
    if ($PassThru) {
        return $updated
    }

    return [int]$updated.Value
}

function Add-Reputation {
    <#
    .SYNOPSIS
        Adds (or subtracts) reputation for a faction.
    .DESCRIPTION
        Positive values gain reputation. Negative values lose reputation.
        This is a dialog compatibility hook. Positional call `Add-Reputation 5`
        updates the default faction.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][int]$Delta,
        [string]$Faction = '',
        [switch]$PassThru
    )

    $record = Get-ReputationFaction -Name $Faction -CreateIfMissing
    if ($null -eq $record) {
        return $null
    }

    [int]$nextValue = [int]$record.Value + [int]$Delta
    $updated = Set-ReputationFactionValueInternal -FactionRecord $record -Value $nextValue

    if ($PassThru) {
        return $updated
    }

    return [int]$updated.Value
}

function Remove-Reputation {
    <#
    .SYNOPSIS
        Removes reputation using a positive amount.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][int]$Amount,
        [string]$Faction = '',
        [switch]$PassThru
    )

    if ($Amount -lt 0) {
        $Amount = [int][System.Math]::Abs($Amount)
    }

    return (Add-Reputation -Delta (-1 * $Amount) -Faction $Faction -PassThru:$PassThru)
}

# ============================================================================
# Public API - Reputation Gates (Dialog and Content)
# ============================================================================

function Test-ReputationGate {
    <#
    .SYNOPSIS
        Tests value and/or level requirements for content gates.
    .DESCRIPTION
        Examples:
        - Test-ReputationGate -Faction 'Village' -MinLevel Friendly
        - Test-ReputationGate -Faction 'Guild' -MinValue 200
        - Test-ReputationGate -Faction 'Raiders' -MaxLevel Hostile
    #>
    param(
        [string]$Faction = '',
        [string]$RequiredLevel = '',
        [Alias('MinimumLevel')][string]$MinLevel = '',
        [Alias('MaximumLevel')][string]$MaxLevel = '',
        [Alias('MinimumReputation')][int]$MinValue = [int]::MinValue,
        [Alias('MaximumReputation')][int]$MaxValue = [int]::MaxValue
    )

    [int]$value = [int](Get-Reputation -Faction $Faction -CreateIfMissing)
    [string]$currentLevel = Resolve-ReputationLevel -Value $value

    if ($value -lt $MinValue) { return $false }
    if ($value -gt $MaxValue) { return $false }

    if (-not [string]::IsNullOrWhiteSpace($RequiredLevel)) {
        $requiredLevelName = ConvertTo-ReputationLevelName -Level $RequiredLevel
        if ([string]::IsNullOrWhiteSpace($requiredLevelName)) {
            return $false
        }

        if ($currentLevel -ne $requiredLevelName) {
            return $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($MinLevel)) {
        $minLevelName = ConvertTo-ReputationLevelName -Level $MinLevel
        if ([string]::IsNullOrWhiteSpace($minLevelName)) {
            return $false
        }

        if ((Get-ReputationLevelRankInternal -Level $currentLevel) -lt (Get-ReputationLevelRankInternal -Level $minLevelName)) {
            return $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($MaxLevel)) {
        $maxLevelName = ConvertTo-ReputationLevelName -Level $MaxLevel
        if ([string]::IsNullOrWhiteSpace($maxLevelName)) {
            return $false
        }

        if ((Get-ReputationLevelRankInternal -Level $currentLevel) -gt (Get-ReputationLevelRankInternal -Level $maxLevelName)) {
            return $false
        }
    }

    return $true
}

function Test-ReputationAtLeast {
    <#
    .SYNOPSIS
        Convenience gate: faction level must be at least a level.
    #>
    param(
        [string]$Faction = '',
        [Parameter(Mandatory = $true)][string]$Level
    )

    return (Test-ReputationGate -Faction $Faction -MinLevel $Level)
}

function Test-ReputationAtMost {
    <#
    .SYNOPSIS
        Convenience gate: faction level must be at most a level.
    #>
    param(
        [string]$Faction = '',
        [Parameter(Mandatory = $true)][string]$Level
    )

    return (Test-ReputationGate -Faction $Faction -MaxLevel $Level)
}

# ============================================================================
# Optional Wrapper API (Plan Smoke Compatibility)
# ============================================================================

function New-Reputation {
    <#
    .SYNOPSIS
        Creates a lightweight reputation API wrapper object.
    .DESCRIPTION
        Supports smoke patterns like:
        $rep = New-Reputation
        $rep.AddReputation('Village', 100)
        $rep.GetLevel('Village')
    #>
    param(
        [switch]$Reset,
        [int]$MaxFactions = 5
    )

    if ($Reset -or -not $script:ReputationInitialized) {
        Initialize-ReputationSystem -MaxFactions $MaxFactions -Quiet | Out-Null
    }

    $api = [PSCustomObject]@{
        DefaultFaction = (Get-ReputationDefaultFaction)
        MaxFactions    = [int]$script:ReputationMaxFactions
    }

    $api | Add-Member -MemberType ScriptMethod -Name AddReputation -Value {
        param([string]$Faction, [int]$Amount)
        return (Add-Reputation -Faction $Faction -Delta $Amount)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name RemoveReputation -Value {
        param([string]$Faction, [int]$Amount)
        return (Remove-Reputation -Faction $Faction -Amount $Amount)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name SetReputation -Value {
        param([string]$Faction, [int]$Value)
        return (Set-Reputation -Faction $Faction -Value $Value)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name GetReputation -Value {
        param([string]$Faction)
        return (Get-Reputation -Faction $Faction)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name GetLevel -Value {
        param([string]$Faction)
        return (Get-ReputationLevel -Faction $Faction)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name TestGate -Value {
        param([string]$Faction, [string]$MinLevel)
        return (Test-ReputationGate -Faction $Faction -MinLevel $MinLevel)
    } -Force

    $api | Add-Member -MemberType ScriptMethod -Name GetFactions -Value {
        return (Get-ReputationFactions)
    } -Force

    return $api
}
