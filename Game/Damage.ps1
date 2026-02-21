# ============================================================================
# Game/Damage.ps1 - Standalone Damage Calculation
# ============================================================================
# Simple reusable damage calculation shared by combat and skill systems.
# Rules:
#   1) BaseDamage is modified by Strength
#   2) EnemyArmor mitigates damage (magic uses half armor)
#   3) MagicDamage can be reduced by MagicResistance
#   4) Critical hits multiply post-mitigation damage
#   5) FinalDamage is always at least 1
# ============================================================================

if ($null -eq $script:DamageRandom) {
    $script:DamageRandom = [System.Random]::new()
}

function Calculate-Damage {
    <#
    .SYNOPSIS
        Calculates final damage with strength, armor, crit, and damage type.
    .PARAMETER BaseDamage
        Base attack damage before modifiers.
    .PARAMETER Strength
        Flat bonus added to base damage.
    .PARAMETER EnemyArmor
        Target armor used for mitigation.
    .PARAMETER DamageType
        Damage type: Physical or Magic.
    .PARAMETER CriticalChance
        Critical hit chance in range 0.0 to 1.0.
    .PARAMETER CriticalMultiplier
        Critical damage multiplier (minimum 1.0).
    .PARAMETER MagicResistance
        Additional magic resistance in range 0.0 to 1.0.
        Applied only when DamageType is Magic.
    .OUTPUTS
        PSCustomObject:
        - FinalDamage
        - WasCritical
        - DamageType
        - BaseDamage
        - ModifiedDamage
        - MitigatedDamage
    #>
    param(
        [Parameter(Mandatory = $true)]
        [double]$BaseDamage,

        [double]$Strength = 0,
        [double]$EnemyArmor = 0,

        [ValidateSet('Physical', 'Magic')]
        [string]$DamageType = 'Physical',

        [double]$CriticalChance = 0.0,
        [double]$CriticalMultiplier = 2.0,
        [double]$MagicResistance = 0.0
    )

    [double]$armor = [Math]::Max(0.0, $EnemyArmor)
    [double]$critChanceClamped = [Math]::Max(0.0, [Math]::Min(1.0, $CriticalChance))
    [double]$critMultiplierClamped = [Math]::Max(1.0, $CriticalMultiplier)
    [double]$magicResistanceClamped = [Math]::Max(0.0, [Math]::Min(1.0, $MagicResistance))

    [double]$modifiedDamage = $BaseDamage + $Strength
    [double]$mitigatedDamage = $modifiedDamage

    if ($DamageType -eq 'Physical') {
        $mitigatedDamage = $modifiedDamage - $armor
    }
    else {
        $mitigatedDamage = $modifiedDamage - ($armor * 0.5)
        $mitigatedDamage = $mitigatedDamage * (1.0 - $magicResistanceClamped)
    }

    if ($mitigatedDamage -lt 0.0) {
        $mitigatedDamage = 0.0
    }

    [bool]$wasCritical = $false
    [double]$rawFinalDamage = $mitigatedDamage

    if ($critChanceClamped -gt 0.0) {
        if ($script:DamageRandom.NextDouble() -lt $critChanceClamped) {
            $wasCritical = $true
            $rawFinalDamage = $rawFinalDamage * $critMultiplierClamped
        }
    }

    [int]$finalDamage = [Math]::Max(1, [int][Math]::Floor($rawFinalDamage))

    return [PSCustomObject]@{
        FinalDamage     = [int]$finalDamage
        WasCritical     = [bool]$wasCritical
        DamageType      = [string]$DamageType
        BaseDamage      = [double]$BaseDamage
        ModifiedDamage  = [double]$modifiedDamage
        MitigatedDamage = [double]$mitigatedDamage
    }
}
