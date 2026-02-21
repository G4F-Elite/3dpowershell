# ============================================================================
# Game/Tools.ps1 - Tool/Weapon Effects System
# ============================================================================
# Calculates block break times based on equipped tool type matching block
# type, manages tool durability consumption, and provides weapon damage
# lookup. Event-driven module (called from Interaction.ps1), no update
# callback needed.
#
# Dependencies: Data/Items.ps1 (Get-ItemDefinition),
#               World/Blocks.ps1 (Get-BlockType, Get-BlockTypeById),
#               Game/Equipment.ps1 (Get-EquippedItem)
# ============================================================================

# --- Module State ---
$script:ToolDurability = @{}   # Hashtable: item name (lowercase) -> remaining durability

# ============================================================================
# Initialize-Tools - Reset tool durability tracking
# ============================================================================

function Initialize-Tools {
    <#
    .SYNOPSIS
        Initializes the tools system. Resets durability tracking.
    .DESCRIPTION
        Clears all tracked tool durabilities. No update callback needed
        since tool effects are event-driven via Interaction.ps1 calls.
    #>

    $script:ToolDurability = @{}

    Write-Host "[Tools] Tool/weapon effects system initialized." -ForegroundColor Green
}

# ============================================================================
# Public API - Break Time Calculation
# ============================================================================

function Get-BreakTime {
    <#
    .SYNOPSIS
        Calculates the time in seconds to break a block with the given tool.
    .DESCRIPTION
        Formula: BaseBreakTime = BlockHardness * 1.5
        If tool ToolType matches block ToolType, divide by tool MiningSpeed.
        If no tool equipped (empty ToolName), multiply by 2.0 (hand penalty).
        Minimum break time: 0.1 seconds.
    .PARAMETER BlockName
        Name of the block being broken.
    .PARAMETER ToolName
        Name of the equipped tool item, or empty string if bare-handed.
    .OUTPUTS
        Float break time in seconds (minimum 0.1).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlockName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ToolName
    )

    # Look up block definition
    $blockDef = Get-BlockType -Name $BlockName
    if ($null -eq $blockDef) {
        return [float]0.25
    }

    # Base break time from hardness
    [float]$baseTime = [float]$blockDef.Hardness * [float]1.5

    # If hardness is 0, instant break
    if ($baseTime -le 0) {
        return [float]0.1
    }

    # Check if we have a tool equipped
    if ([string]::IsNullOrEmpty($ToolName)) {
        # No tool - hand penalty
        [float]$breakTime = $baseTime * [float]2.0
    }
    else {
        # Look up tool definition
        $toolDef = Get-ItemDefinition -Name $ToolName
        if ($null -eq $toolDef) {
            # Unknown tool - treat as hand
            [float]$breakTime = $baseTime * [float]2.0
        }
        elseif ($toolDef.Type -eq 'Tool') {
            # Check if tool type matches block type
            $blockToolType = $blockDef.ToolType
            $itemToolType = $toolDef.ToolType

            if ($blockToolType -ne 'none' -and $blockToolType -ne 'hand' -and $blockToolType -eq $itemToolType) {
                # Correct tool - divide by mining speed
                [float]$miningSpeed = [float]$toolDef.MiningSpeed
                if ($miningSpeed -le 0) { $miningSpeed = [float]1.0 }
                [float]$breakTime = $baseTime / $miningSpeed
            }
            else {
                # Wrong tool type - no speed bonus, use base time
                [float]$breakTime = $baseTime
            }
        }
        else {
            # Weapon or other item in hand - no mining bonus, use base time
            [float]$breakTime = $baseTime
        }
    }

    # Enforce minimum break time
    if ($breakTime -lt [float]0.1) {
        $breakTime = [float]0.1
    }

    return [float]$breakTime
}

# ============================================================================
# Public API - Weapon Damage
# ============================================================================

function Get-WeaponDamage {
    <#
    .SYNOPSIS
        Returns the damage value for a weapon by name.
    .PARAMETER WeaponName
        Name of the weapon item.
    .OUTPUTS
        Int damage value, or 1 (fist damage) if not a weapon.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WeaponName
    )

    if ([string]::IsNullOrEmpty($WeaponName)) {
        return [int]1
    }

    $itemDef = Get-ItemDefinition -Name $WeaponName
    if ($null -eq $itemDef) {
        return [int]1
    }

    if ($null -ne $itemDef.Damage -and $itemDef.Damage -gt 0) {
        return [int]$itemDef.Damage
    }

    return [int]1
}

# ============================================================================
# Public API - Durability Management
# ============================================================================

function Invoke-DurabilityUse {
    <#
    .SYNOPSIS
        Consumes 1 durability from the equipped MainHand tool or weapon.
    .DESCRIPTION
        Tracks durability in a module-level hashtable keyed by item name.
        When a tool is first used, its max durability is loaded from the
        item definition. When durability reaches 0, the tool breaks
        (removed from equipment slot) and the player is notified.
    .PARAMETER ItemName
        Name of the equipped item to consume durability for.
    .OUTPUTS
        $true if item still has durability, $false if item broke.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemName
    )

    if ([string]::IsNullOrEmpty($ItemName)) {
        return $true
    }

    $itemDef = Get-ItemDefinition -Name $ItemName
    if ($null -eq $itemDef) {
        return $true
    }

    # Only tools and weapons have durability
    if ($itemDef.Type -ne 'Tool' -and $itemDef.Type -ne 'Weapon') {
        return $true
    }

    # Check if item has a Durability property
    if ($null -eq $itemDef.Durability -or $itemDef.Durability -le 0) {
        return $true
    }

    $key = $ItemName.ToLower()

    # Initialize durability tracking if not yet tracked
    if (-not $script:ToolDurability.ContainsKey($key)) {
        $script:ToolDurability[$key] = [int]$itemDef.Durability
    }

    # Consume 1 durability
    $script:ToolDurability[$key] = $script:ToolDurability[$key] - 1

    if ($script:ToolDurability[$key] -le 0) {
        # Tool broke - remove from equipment
        $script:ToolDurability.Remove($key)

        # Clear the MainHand slot directly (item is destroyed, not returned)
        # Use Unequip approach but item is lost
        $equipped = Get-EquippedItem -Slot 'MainHand'
        if ($equipped -eq $ItemName) {
            # Directly clear the slot (item is destroyed)
            $script:EquipmentSlots['MainHand'] = [string]''
        }

        Write-Host "[Tools] $ItemName broke!" -ForegroundColor Red
        return $false
    }

    return $true
}

function Get-ToolDurability {
    <#
    .SYNOPSIS
        Returns the remaining durability of a tracked tool.
    .PARAMETER ItemName
        Name of the tool/weapon item.
    .OUTPUTS
        Int remaining durability, or -1 if not tracked.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemName
    )

    $key = $ItemName.ToLower()
    if ($script:ToolDurability.ContainsKey($key)) {
        return [int]$script:ToolDurability[$key]
    }

    return [int]-1
}
