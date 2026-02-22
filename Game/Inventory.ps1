# ============================================================================
# Game/Inventory.ps1 - Player Inventory System
# ============================================================================
# Manages a 36-slot inventory (9 hotbar + 27 storage) with item stacking,
# add/remove operations, hotbar selection via number keys, and inventory
# open/close toggle via E key.
#
# Dependencies: Engine/OpenGL.ps1 (Register-UpdateCallback),
#               Engine/Input.ps1 (Get-KeyDown)
# ============================================================================

# --- Module State ---
$script:InventorySlots = $null               # Array of 36 PSCustomObjects {ItemName, Count}
$script:InventorySlotCount = 36              # Total slots: 9 hotbar + 27 storage
$script:InventoryHotbarSize = 9              # Hotbar = slots 0-8
$script:HotbarSelection = [int]0             # Currently selected hotbar slot (0-8)
$script:InventoryOpen = $false               # Whether inventory UI is open
$script:DefaultMaxStackSize = [int]64        # Default max stack size for all items

function Resolve-InventoryKeyBinding {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Keys]$Fallback
    )

    if (Get-Command -Name Get-KeyBinding -ErrorAction SilentlyContinue) {
        try {
            [string]$bindingName = [string](Get-KeyBinding -Action $Action -Default ([string]$Fallback))
            if (-not [string]::IsNullOrWhiteSpace($bindingName)) {
                $parsed = [System.Enum]::Parse([System.Windows.Forms.Keys], $bindingName, $true)
                if ($null -ne $parsed) {
                    return [System.Windows.Forms.Keys]$parsed
                }
            }
        }
        catch {
        }
    }

    return [System.Windows.Forms.Keys]$Fallback
}

# ============================================================================
# Initialize-Inventory - Reset inventory and register update callback
# ============================================================================

function Initialize-Inventory {
    <#
    .SYNOPSIS
        Initializes inventory to empty slots and registers Update-Inventory callback.
    .DESCRIPTION
        Creates 36 empty inventory slots (9 hotbar + 27 storage) and registers
        the per-frame update for hotbar key input. Must be called AFTER
        Initialize-Interaction.
    #>

    # Create 36 empty slots
    $script:InventorySlots = @()
    for ($i = 0; $i -lt $script:InventorySlotCount; $i++) {
        $script:InventorySlots += [PSCustomObject]@{
            ItemName = [string]''
            Count    = [int]0
        }
    }

    $script:HotbarSelection = [int]0
    $script:InventoryOpen = $false

    Register-UpdateCallback ${function:Update-Inventory}

    Write-Host "[Inventory] Inventory initialized (36 slots, 9 hotbar)." -ForegroundColor Green
}

# ============================================================================
# Update-Inventory - Per-frame input handling
# ============================================================================

function Update-Inventory {
    <#
    .SYNOPSIS
        Per-frame update. Handles hotbar selection (1-9 keys) and inventory
        toggle (E key).
    #>
    param($dt)

    [System.Windows.Forms.Keys]$inventoryToggleKey = Resolve-InventoryKeyBinding -Action 'Inventory' -Fallback ([System.Windows.Forms.Keys]::E)

    # --- Hotbar Selection via Number Keys 1-9 ---
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D1)) { $script:HotbarSelection = 0 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D2)) { $script:HotbarSelection = 1 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D3)) { $script:HotbarSelection = 2 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D4)) { $script:HotbarSelection = 3 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D5)) { $script:HotbarSelection = 4 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D6)) { $script:HotbarSelection = 5 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D7)) { $script:HotbarSelection = 6 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D8)) { $script:HotbarSelection = 7 }
    if (Get-KeyDown ([System.Windows.Forms.Keys]::D9)) { $script:HotbarSelection = 8 }

    # --- Inventory Open/Close Toggle (E key) ---
    if (Get-KeyDown $inventoryToggleKey) {
        $script:InventoryOpen = -not $script:InventoryOpen
    }
}

# ============================================================================
# Public API - Add/Remove Items
# ============================================================================

function Add-InventoryItem {
    <#
    .SYNOPSIS
        Adds items to inventory with stacking. Returns $true if all items added.
    .DESCRIPTION
        First tries to stack onto existing slots with the same item, then fills
        empty slots. Uses default max stack size of 64. Returns $false if not
        all items could be added (inventory full).
    #>
    param(
        [string]$Name,
        [int]$Count = 1
    )

    if ([string]::IsNullOrEmpty($Name) -or $Count -le 0) { return $false }

    $remaining = $Count
    $maxStack = $script:DefaultMaxStackSize

    # Phase 1: Stack onto existing slots with same item
    for ($i = 0; $i -lt $script:InventorySlotCount; $i++) {
        if ($remaining -le 0) { break }

        $slot = $script:InventorySlots[$i]
        if ($slot.ItemName -eq $Name -and $slot.Count -lt $maxStack) {
            $canAdd = $maxStack - $slot.Count
            if ($canAdd -gt $remaining) { $canAdd = $remaining }
            $slot.Count += $canAdd
            $remaining -= $canAdd
        }
    }

    # Phase 2: Fill empty slots
    for ($i = 0; $i -lt $script:InventorySlotCount; $i++) {
        if ($remaining -le 0) { break }

        $slot = $script:InventorySlots[$i]
        if ([string]::IsNullOrEmpty($slot.ItemName) -or $slot.Count -le 0) {
            $canAdd = $maxStack
            if ($canAdd -gt $remaining) { $canAdd = $remaining }
            $slot.ItemName = $Name
            $slot.Count = $canAdd
            $remaining -= $canAdd
        }
    }

    return ($remaining -le 0)
}

function Remove-InventoryItem {
    <#
    .SYNOPSIS
        Removes items from inventory. Returns $true if all items removed.
    .DESCRIPTION
        Searches all slots for the named item and removes the requested count.
        Removes from higher-index slots first (main inventory before hotbar).
        Returns $false if not enough items in inventory.
    #>
    param(
        [string]$Name,
        [int]$Count = 1
    )

    if ([string]::IsNullOrEmpty($Name) -or $Count -le 0) { return $false }

    # Check total count first
    $totalAvailable = Get-InventoryItemCount -Name $Name
    if ($totalAvailable -lt $Count) { return $false }

    $remaining = $Count

    # Remove from highest index first (preserve hotbar items)
    for ($i = $script:InventorySlotCount - 1; $i -ge 0; $i--) {
        if ($remaining -le 0) { break }

        $slot = $script:InventorySlots[$i]
        if ($slot.ItemName -eq $Name -and $slot.Count -gt 0) {
            $canRemove = $slot.Count
            if ($canRemove -gt $remaining) { $canRemove = $remaining }
            $slot.Count -= $canRemove
            $remaining -= $canRemove

            # Clear slot if empty
            if ($slot.Count -le 0) {
                $slot.ItemName = ''
                $slot.Count = 0
            }
        }
    }

    return ($remaining -le 0)
}

# ============================================================================
# Public API - Stack Splitting
# ============================================================================

function Split-InventoryStack {
    <#
    .SYNOPSIS
        Splits a stack at the given slot, moving Amount items to first empty slot.
    .DESCRIPTION
        Takes Amount items from SlotIndex and places them in the first available
        empty slot. Returns $true if split succeeded, $false if not possible
        (invalid index, insufficient items, no empty slot).
    #>
    param(
        [int]$SlotIndex,
        [int]$Amount
    )

    # Validate slot index
    if ($SlotIndex -lt 0 -or $SlotIndex -ge $script:InventorySlotCount) { return $false }

    $sourceSlot = $script:InventorySlots[$SlotIndex]

    # Validate source has enough items
    if ([string]::IsNullOrEmpty($sourceSlot.ItemName) -or $sourceSlot.Count -le 0) { return $false }
    if ($Amount -le 0 -or $Amount -ge $sourceSlot.Count) { return $false }

    # Find first empty slot
    $emptyIndex = -1
    for ($i = 0; $i -lt $script:InventorySlotCount; $i++) {
        if ($i -eq $SlotIndex) { continue }
        $slot = $script:InventorySlots[$i]
        if ([string]::IsNullOrEmpty($slot.ItemName) -or $slot.Count -le 0) {
            $emptyIndex = $i
            break
        }
    }

    if ($emptyIndex -lt 0) { return $false }

    # Perform split
    $targetSlot = $script:InventorySlots[$emptyIndex]
    $targetSlot.ItemName = $sourceSlot.ItemName
    $targetSlot.Count = $Amount
    $sourceSlot.Count -= $Amount

    return $true
}

# ============================================================================
# Public API - Getters
# ============================================================================

function Get-InventoryItemCount {
    <#
    .SYNOPSIS
        Returns total count of a named item across all inventory slots.
    #>
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return 0 }

    $total = 0
    for ($i = 0; $i -lt $script:InventorySlotCount; $i++) {
        $slot = $script:InventorySlots[$i]
        if ($slot.ItemName -eq $Name) {
            $total += $slot.Count
        }
    }
    return $total
}

function Get-InventorySlot {
    <#
    .SYNOPSIS
        Returns the slot PSCustomObject at the given index (0-35).
    #>
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:InventorySlotCount) { return $null }
    return $script:InventorySlots[$Index]
}

function Get-InventorySlots {
    <#
    .SYNOPSIS
        Returns the full inventory slots array.
    #>
    return ,$script:InventorySlots
}

function Get-InventoryOpen {
    <#
    .SYNOPSIS
        Returns $true if the inventory UI is currently open.
    #>
    return $script:InventoryOpen
}

# ============================================================================
# Public API - Hotbar
# ============================================================================

function Set-HotbarSelection {
    <#
    .SYNOPSIS
        Sets the active hotbar slot index (0-8).
    #>
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:InventoryHotbarSize) { return }
    $script:HotbarSelection = $Index
}

function Get-HotbarSelection {
    <#
    .SYNOPSIS
        Returns the currently selected hotbar slot index (0-8).
    #>
    return $script:HotbarSelection
}

function Get-HotbarItem {
    <#
    .SYNOPSIS
        Returns the item in the currently selected hotbar slot.
    #>
    return $script:InventorySlots[$script:HotbarSelection]
}
