# ============================================================================
# Game/Stats.ps1 - Player Stats System (HP, Mana, Stamina)
# ============================================================================
# Manages player stats with current/max values, regeneration over time,
# and stat modification functions. Used by combat, death/respawn, and UI.
#
# Dependencies: Engine/OpenGL.ps1 (Register-UpdateCallback)
# ============================================================================

# --- Module State ---
$script:PlayerStats = $null
$script:StaminaRegenCooldown = [float]0.0    # Seconds until stamina regen resumes

# ============================================================================
# Initialize-PlayerStats - Reset stats and register update callback
# ============================================================================

function Initialize-PlayerStats {
    <#
    .SYNOPSIS
        Initializes player stats to defaults and registers Update-PlayerStats callback.
    .DESCRIPTION
        Creates the PlayerStats PSCustomObject with HP, Mana, Stamina and their
        max values, regen rates, and IsAlive flag. Must be called AFTER Initialize-Player.
    #>

    $script:PlayerStats = [PSCustomObject]@{
        HP          = [float]100.0
        MaxHP       = [float]100.0
        Mana        = [float]50.0
        MaxMana     = [float]50.0
        Stamina     = [float]100.0
        MaxStamina  = [float]100.0
        HPRegen     = [float]1.0     # Per second
        ManaRegen   = [float]2.0     # Per second
        StaminaRegen = [float]10.0   # Per second
        IsAlive     = $true
    }

    $script:StaminaRegenCooldown = [float]0.0

    Register-UpdateCallback ${function:Update-PlayerStats}

    Write-Host "[Stats] Player stats initialized (HP:100 Mana:50 Stamina:100)." -ForegroundColor Green
}

# ============================================================================
# Update-PlayerStats - Per-frame stat regeneration
# ============================================================================

function Update-PlayerStats {
    <#
    .SYNOPSIS
        Per-frame update. Handles HP, Mana, and Stamina regeneration.
    #>
    param($dt)

    if (-not $script:PlayerStats.IsAlive) { return }

    # --- HP Regeneration ---
    if ($script:PlayerStats.HP -lt $script:PlayerStats.MaxHP) {
        $script:PlayerStats.HP = [Math]::Min(
            $script:PlayerStats.HP + $script:PlayerStats.HPRegen * $dt,
            $script:PlayerStats.MaxHP
        )
    }

    # --- Mana Regeneration ---
    if ($script:PlayerStats.Mana -lt $script:PlayerStats.MaxMana) {
        $script:PlayerStats.Mana = [Math]::Min(
            $script:PlayerStats.Mana + $script:PlayerStats.ManaRegen * $dt,
            $script:PlayerStats.MaxMana
        )
    }

    # --- Stamina Regeneration (with cooldown after use) ---
    if ($script:StaminaRegenCooldown -gt 0) {
        $script:StaminaRegenCooldown -= $dt
    } else {
        if ($script:PlayerStats.Stamina -lt $script:PlayerStats.MaxStamina) {
            $script:PlayerStats.Stamina = [Math]::Min(
                $script:PlayerStats.Stamina + $script:PlayerStats.StaminaRegen * $dt,
                $script:PlayerStats.MaxStamina
            )
        }
    }
}

# ============================================================================
# Public API - Getters
# ============================================================================

function Get-PlayerStats {
    <#
    .SYNOPSIS
        Returns the player stats PSCustomObject.
    #>
    return $script:PlayerStats
}

# ============================================================================
# Public API - Absolute Setters
# ============================================================================

function Set-PlayerHP {
    <#
    .SYNOPSIS
        Sets HP to an absolute value, clamped between 0 and MaxHP.
    #>
    param([float]$Amount)

    $script:PlayerStats.HP = [Math]::Max(0, [Math]::Min($Amount, $script:PlayerStats.MaxHP))
    $script:PlayerStats.IsAlive = ($script:PlayerStats.HP -gt 0)
}

function Set-PlayerMana {
    <#
    .SYNOPSIS
        Sets Mana to an absolute value, clamped between 0 and MaxMana.
    #>
    param([float]$Amount)

    $script:PlayerStats.Mana = [Math]::Max(0, [Math]::Min($Amount, $script:PlayerStats.MaxMana))
}

function Set-PlayerStamina {
    <#
    .SYNOPSIS
        Sets Stamina to an absolute value, clamped between 0 and MaxStamina.
    #>
    param([float]$Amount)

    $script:PlayerStats.Stamina = [Math]::Max(0, [Math]::Min($Amount, $script:PlayerStats.MaxStamina))
}

# ============================================================================
# Public API - Relative Modifiers (Delta)
# ============================================================================

function Add-PlayerHP {
    <#
    .SYNOPSIS
        Modifies HP by a delta value. Positive heals, negative damages.
    #>
    param([float]$Delta)

    $newHP = $script:PlayerStats.HP + $Delta
    $script:PlayerStats.HP = [Math]::Max(0, [Math]::Min($newHP, $script:PlayerStats.MaxHP))
    $script:PlayerStats.IsAlive = ($script:PlayerStats.HP -gt 0)
}

function Add-PlayerMana {
    <#
    .SYNOPSIS
        Modifies Mana by a delta value. Positive restores, negative consumes.
    #>
    param([float]$Delta)

    $newMana = $script:PlayerStats.Mana + $Delta
    $script:PlayerStats.Mana = [Math]::Max(0, [Math]::Min($newMana, $script:PlayerStats.MaxMana))
}

function Add-PlayerStamina {
    <#
    .SYNOPSIS
        Modifies Stamina by a delta value. Positive restores, negative consumes.
    #>
    param([float]$Delta)

    $newStamina = $script:PlayerStats.Stamina + $Delta
    $script:PlayerStats.Stamina = [Math]::Max(0, [Math]::Min($newStamina, $script:PlayerStats.MaxStamina))
}

# ============================================================================
# Public API - Stamina Usage
# ============================================================================

function Use-Stamina {
    <#
    .SYNOPSIS
        Attempts to consume stamina. Returns $true if enough, $false if not.
    .DESCRIPTION
        If the player has enough stamina, consumes the cost and triggers
        a 0.5 second regen cooldown. Returns $false without consuming if
        not enough stamina available.
    #>
    param([float]$Cost)

    if ($script:PlayerStats.Stamina -ge $Cost) {
        $script:PlayerStats.Stamina -= $Cost
        $script:StaminaRegenCooldown = [float]0.5
        return $true
    }

    return $false
}
