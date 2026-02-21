# ============================================================================
# Game/Equipment.ps1 - Player Equipment System
# ============================================================================
# Manages 6 equipment slots: MainHand, OffHand, Helmet, Chest, Legs, Boots.
# Handles equip/unequip operations with inventory integration, slot type
# validation, and aggregated equipment stat computation.
#
# Dependencies: Data/Items.ps1 (Get-ItemDefinition),
#               Game/Inventory.ps1 (Add-InventoryItem, Remove-InventoryItem)
# ============================================================================

# --- Module State ---
$script:EquipmentSlots = $null    # Hashtable: slot name -> item name string ('' if empty)

# --- Valid slot names ---
$script:EquipmentSlotNames = @('MainHand', 'OffHand', 'Helmet', 'Chest', 'Legs', 'Boots')

# --- Armor slot to item Slot property mapping (lowercase) ---
$script:EquipmentArmorSlotMap = @{
    'Helmet' = 'helmet'
    'Chest'  = 'chest'
    'Legs'   = 'legs'
    'Boots'  = 'boots'
}

# ============================================================================
# Initialize-Equipment - Reset all equipment slots
# ============================================================================

function Initialize-Equipment {
    <#
    .SYNOPSIS
        Initializes all equipment slots to empty. No update callback needed
        since equipment changes are event-driven via Equip/Unequip calls.
    #>

    $script:EquipmentSlots = @{
        'MainHand' = [string]''
        'OffHand'  = [string]''
        'Helmet'   = [string]''
        'Chest'    = [string]''
        'Legs'     = [string]''
        'Boots'    = [string]''
    }

    Write-Host "[Equipment] Equipment system initialized (6 slots)." -ForegroundColor Green
}

# ============================================================================
# Slot Validation
# ============================================================================

function Test-EquipmentSlotValid {
    <#
    .SYNOPSIS
        Returns $true if the given slot name is a valid equipment slot.
    #>
    param([string]$Slot)

    foreach ($name in $script:EquipmentSlotNames) {
        if ($name -eq $Slot) { return $true }
    }
    return $false
}

function Test-ItemFitsSlot {
    <#
    .SYNOPSIS
        Returns $true if the given item definition can be equipped in the given slot.
    .DESCRIPTION
        MainHand accepts Tool or Weapon types.
        OffHand is reserved for future use (currently rejects all items).
        Armor slots (Helmet, Chest, Legs, Boots) accept Armor type with matching Slot property.
    #>
    param(
        [PSCustomObject]$ItemDef,
        [string]$Slot
    )

    if ($null -eq $ItemDef) { return $false }

    switch ($Slot) {
        'MainHand' {
            return ($ItemDef.Type -eq 'Tool' -or $ItemDef.Type -eq 'Weapon')
        }
        'OffHand' {
            # Reserved for future shield/offhand items
            return $false
        }
        default {
            # Armor slots: Helmet, Chest, Legs, Boots
            if ($ItemDef.Type -ne 'Armor') { return $false }

            $requiredSlot = $script:EquipmentArmorSlotMap[$Slot]
            if ($null -eq $requiredSlot) { return $false }

            return ($ItemDef.Slot -eq $requiredSlot)
        }
    }
}

# ============================================================================
# Public API - Equip / Unequip
# ============================================================================

function Equip-Item {
    <#
    .SYNOPSIS
        Equips an item from inventory into the specified equipment slot.
    .DESCRIPTION
        1. Validates item exists via Get-ItemDefinition
        2. Validates item can go in the requested slot
        3. If slot already occupied, returns current item to inventory
        4. Removes new item from inventory
        5. Sets the slot to the new item name
    .PARAMETER ItemName
        Name of the item to equip (must exist in inventory).
    .PARAMETER Slot
        Equipment slot name: MainHand, OffHand, Helmet, Chest, Legs, Boots.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemName,

        [Parameter(Mandatory = $true)]
        [string]$Slot
    )

    # Validate slot name
    if (-not (Test-EquipmentSlotValid -Slot $Slot)) {
        Write-Host "[Equipment] Invalid slot: $Slot" -ForegroundColor Red
        return $false
    }

    # Look up item definition
    $itemDef = Get-ItemDefinition -Name $ItemName
    if ($null -eq $itemDef) {
        Write-Host "[Equipment] Unknown item: $ItemName" -ForegroundColor Red
        return $false
    }

    # Validate item fits this slot
    if (-not (Test-ItemFitsSlot -ItemDef $itemDef -Slot $Slot)) {
        Write-Host "[Equipment] $ItemName cannot be equipped in $Slot" -ForegroundColor Red
        return $false
    }

    # Check item is in inventory
    $invCount = Get-InventoryItemCount -Name $ItemName
    if ($invCount -lt 1) {
        Write-Host "[Equipment] $ItemName not in inventory" -ForegroundColor Red
        return $false
    }

    # If slot already has an item, return it to inventory first
    $currentItem = $script:EquipmentSlots[$Slot]
    if (-not [string]::IsNullOrEmpty($currentItem)) {
        $added = Add-InventoryItem -Name $currentItem -Count 1
        if (-not $added) {
            Write-Host "[Equipment] Inventory full, cannot unequip $currentItem" -ForegroundColor Red
            return $false
        }
    }

    # Remove new item from inventory
    $removed = Remove-InventoryItem -Name $ItemName -Count 1
    if (-not $removed) {
        # Rollback: if we already returned the old item, remove it again
        if (-not [string]::IsNullOrEmpty($currentItem)) {
            Remove-InventoryItem -Name $currentItem -Count 1 | Out-Null
            $script:EquipmentSlots[$Slot] = $currentItem
        }
        Write-Host "[Equipment] Failed to remove $ItemName from inventory" -ForegroundColor Red
        return $false
    }

    # Equip the item
    $script:EquipmentSlots[$Slot] = $ItemName

    Write-Host "[Equipment] Equipped $ItemName in $Slot" -ForegroundColor Cyan
    return $true
}

function Unequip-Item {
    <#
    .SYNOPSIS
        Unequips an item from the specified slot back to inventory.
    .DESCRIPTION
        1. Checks slot has an item
        2. Tries to add item back to inventory
        3. If inventory full, returns $false
        4. Clears the slot
    .PARAMETER Slot
        Equipment slot name: MainHand, OffHand, Helmet, Chest, Legs, Boots.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slot
    )

    # Validate slot name
    if (-not (Test-EquipmentSlotValid -Slot $Slot)) {
        Write-Host "[Equipment] Invalid slot: $Slot" -ForegroundColor Red
        return $false
    }

    # Check slot has an item
    $currentItem = $script:EquipmentSlots[$Slot]
    if ([string]::IsNullOrEmpty($currentItem)) {
        return $false
    }

    # Try to add item back to inventory
    $added = Add-InventoryItem -Name $currentItem -Count 1
    if (-not $added) {
        Write-Host "[Equipment] Inventory full, cannot unequip $currentItem" -ForegroundColor Red
        return $false
    }

    # Clear the slot
    $script:EquipmentSlots[$Slot] = [string]''

    Write-Host "[Equipment] Unequipped $currentItem from $Slot" -ForegroundColor Cyan
    return $true
}

# ============================================================================
# Public API - Getters
# ============================================================================

function Get-EquippedItem {
    <#
    .SYNOPSIS
        Returns the item name equipped in the given slot, or '' if empty.
    .PARAMETER Slot
        Equipment slot name: MainHand, OffHand, Helmet, Chest, Legs, Boots.
    .OUTPUTS
        Item name string, or '' if slot is empty or invalid.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slot
    )

    if (-not (Test-EquipmentSlotValid -Slot $Slot)) { return '' }

    $item = $script:EquipmentSlots[$Slot]
    if ($null -eq $item) { return '' }
    return $item
}

function Get-AllEquipment {
    <#
    .SYNOPSIS
        Returns a hashtable of all equipment slots and their item names.
    .OUTPUTS
        Hashtable with keys: MainHand, OffHand, Helmet, Chest, Legs, Boots.
        Values are item name strings ('' if empty).
    #>

    # Return a copy to prevent external modification
    $copy = @{}
    foreach ($slotName in $script:EquipmentSlotNames) {
        $copy[$slotName] = $script:EquipmentSlots[$slotName]
    }
    return $copy
}

function Get-EquipmentStats {
    <#
    .SYNOPSIS
        Returns aggregated stats from all equipped items.
    .DESCRIPTION
        TotalDamage: sum of Damage from MainHand weapon/tool.
        TotalDefense: sum of Defense from all equipped armor pieces.
        MiningSpeed: MiningSpeed from MainHand tool (1.0 if no tool).
    .OUTPUTS
        PSCustomObject with TotalDamage, TotalDefense, MiningSpeed.
    #>

    $totalDamage = [int]0
    $totalDefense = [int]0
    $miningSpeed = [float]1.0

    # --- MainHand ---
    $mainHandName = $script:EquipmentSlots['MainHand']
    if (-not [string]::IsNullOrEmpty($mainHandName)) {
        $mainHandDef = Get-ItemDefinition -Name $mainHandName
        if ($null -ne $mainHandDef) {
            # Damage from weapon or tool
            if ($null -ne $mainHandDef.Damage) {
                $totalDamage += $mainHandDef.Damage
            }
            # MiningSpeed from tool
            if ($mainHandDef.Type -eq 'Tool' -and $null -ne $mainHandDef.MiningSpeed) {
                $miningSpeed = [float]$mainHandDef.MiningSpeed
            }
        }
    }

    # --- Armor slots: Helmet, Chest, Legs, Boots ---
    $armorSlots = @('Helmet', 'Chest', 'Legs', 'Boots')
    foreach ($slotName in $armorSlots) {
        $itemName = $script:EquipmentSlots[$slotName]
        if (-not [string]::IsNullOrEmpty($itemName)) {
            $itemDef = Get-ItemDefinition -Name $itemName
            if ($null -ne $itemDef -and $null -ne $itemDef.Defense) {
                $totalDefense += $itemDef.Defense
            }
        }
    }

    return [PSCustomObject]@{
        TotalDamage  = [int]$totalDamage
        TotalDefense = [int]$totalDefense
        MiningSpeed  = [float]$miningSpeed
    }
}
