# ============================================================================
# Data/Items.ps1  - Item Definitions Registry
# ============================================================================
# Centralized registry of all item types with their properties.
# Provides lookup functions by name for use by inventory, crafting,
# combat, and interaction systems.
#
# Item Types: Resource, Tool, Weapon, Armor, Consumable
# Dependencies: None (standalone data module)
# ============================================================================

# ---------------------------------------------------------------------------
# Module-level item registry
# ---------------------------------------------------------------------------

$script:ItemsByName = @{}   # [string] -> PSCustomObject (lowercase key)

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

function Initialize-Items {
    <#
    .SYNOPSIS
        Initializes the item registry with all defined items.
    .DESCRIPTION
        Creates PSCustomObject definitions for each item with type-specific
        properties. Items are registered in a name-based lookup table.
    #>

    $script:ItemsByName = @{}

    # Helper to register an item in the lookup table
    $registerItem = {
        param($Item)
        $script:ItemsByName[$Item.Name.ToLower()] = $Item
    }

    # ===================================================================
    # RESOURCES
    # ===================================================================

    # --- Stone ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Stone'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]2
        BlockId   = [byte]1
    })

    # --- Dirt ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Dirt'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]1
        BlockId   = [byte]2
    })

    # --- Sand ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Sand'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]1
        BlockId   = [byte]4
    })

    # --- Wood ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Wood'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]3
        BlockId   = [byte]5
    })

    # --- Cobblestone ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Cobblestone'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]2
        BlockId   = [byte]8
    })

    # --- Planks ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Planks'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]4
        BlockId   = [byte]9
    })

    # --- Glass ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Glass'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]3
        BlockId   = [byte]10
    })

    # --- Iron Ingot ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Iron Ingot'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]15
        BlockId   = [byte]0
    })

    # --- Gold Ingot ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Gold Ingot'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]25
        BlockId   = [byte]0
    })

    # --- Coal ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Coal'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]5
        BlockId   = [byte]0
    })

    # --- Diamond ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Diamond'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]50
        BlockId   = [byte]0
    })

    # --- Stick ---
    & $registerItem ([PSCustomObject]@{
        Name      = 'Stick'
        Type      = 'Resource'
        StackSize = [int]64
        Value     = [int]1
        BlockId   = [byte]0
    })

    # ===================================================================
    # TOOLS
    # ===================================================================

    # --- Wooden Pickaxe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Wooden Pickaxe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]10
        Damage      = [int]0
        Durability  = [int]60
        ToolType    = 'pickaxe'
        Tier        = 'wood'
        MiningSpeed = [float]1.0
    })

    # --- Stone Pickaxe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Stone Pickaxe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]15
        Damage      = [int]0
        Durability  = [int]132
        ToolType    = 'pickaxe'
        Tier        = 'stone'
        MiningSpeed = [float]2.0
    })

    # --- Iron Pickaxe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Iron Pickaxe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]50
        Damage      = [int]0
        Durability  = [int]251
        ToolType    = 'pickaxe'
        Tier        = 'iron'
        MiningSpeed = [float]4.0
    })

    # --- Wooden Axe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Wooden Axe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]10
        Damage      = [int]0
        Durability  = [int]60
        ToolType    = 'axe'
        Tier        = 'wood'
        MiningSpeed = [float]1.0
    })

    # --- Stone Axe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Stone Axe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]15
        Damage      = [int]0
        Durability  = [int]132
        ToolType    = 'axe'
        Tier        = 'stone'
        MiningSpeed = [float]2.0
    })

    # --- Iron Axe ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Iron Axe'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]50
        Damage      = [int]0
        Durability  = [int]251
        ToolType    = 'axe'
        Tier        = 'iron'
        MiningSpeed = [float]4.0
    })

    # --- Wooden Shovel ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Wooden Shovel'
        Type        = 'Tool'
        StackSize   = [int]1
        Value       = [int]8
        Damage      = [int]0
        Durability  = [int]60
        ToolType    = 'shovel'
        Tier        = 'wood'
        MiningSpeed = [float]1.0
    })

    # ===================================================================
    # WEAPONS
    # ===================================================================

    # --- Wooden Sword ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Wooden Sword'
        Type        = 'Weapon'
        StackSize   = [int]1
        Value       = [int]10
        Damage      = [int]5
        Durability  = [int]60
        AttackSpeed = [float]1.6
    })

    # --- Stone Sword ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Stone Sword'
        Type        = 'Weapon'
        StackSize   = [int]1
        Value       = [int]15
        Damage      = [int]7
        Durability  = [int]132
        AttackSpeed = [float]1.6
    })

    # --- Iron Sword ---
    & $registerItem ([PSCustomObject]@{
        Name        = 'Iron Sword'
        Type        = 'Weapon'
        StackSize   = [int]1
        Value       = [int]50
        Damage      = [int]10
        Durability  = [int]251
        AttackSpeed = [float]1.6
    })

    # ===================================================================
    # ARMOR
    # ===================================================================

    # --- Iron Helmet ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Iron Helmet'
        Type       = 'Armor'
        StackSize  = [int]1
        Value      = [int]40
        Defense    = [int]2
        Durability = [int]166
        Slot       = 'helmet'
    })

    # --- Iron Chestplate ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Iron Chestplate'
        Type       = 'Armor'
        StackSize  = [int]1
        Value      = [int]65
        Defense    = [int]6
        Durability = [int]241
        Slot       = 'chest'
    })

    # --- Iron Leggings ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Iron Leggings'
        Type       = 'Armor'
        StackSize  = [int]1
        Value      = [int]55
        Defense    = [int]5
        Durability = [int]226
        Slot       = 'legs'
    })

    # --- Iron Boots ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Iron Boots'
        Type       = 'Armor'
        StackSize  = [int]1
        Value      = [int]35
        Defense    = [int]2
        Durability = [int]196
        Slot       = 'boots'
    })

    # ===================================================================
    # CONSUMABLES
    # ===================================================================

    # --- Health Potion ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Health Potion'
        Type       = 'Consumable'
        StackSize  = [int]16
        Value      = [int]20
        HealAmount = [int]30
        ManaAmount = [int]0
        Effect     = ''
    })

    # --- Mana Potion ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Mana Potion'
        Type       = 'Consumable'
        StackSize  = [int]16
        Value      = [int]20
        HealAmount = [int]0
        ManaAmount = [int]30
        Effect     = ''
    })

    # --- Bread ---
    & $registerItem ([PSCustomObject]@{
        Name       = 'Bread'
        Type       = 'Consumable'
        StackSize  = [int]16
        Value      = [int]5
        HealAmount = [int]8
        ManaAmount = [int]0
        Effect     = ''
    })
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-ItemDefinition {
    <#
    .SYNOPSIS
        Returns an item definition by name.
    .PARAMETER Name
        Item name (case-insensitive). E.g. 'Iron Sword', 'Health Potion'.
    .OUTPUTS
        PSCustomObject with item properties, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:ItemsByName.Count -eq 0) {
        Initialize-Items
    }

    $key = $Name.ToLower()
    if ($script:ItemsByName.ContainsKey($key)) {
        return $script:ItemsByName[$key]
    }

    return $null
}

function Get-AllItemDefinitions {
    <#
    .SYNOPSIS
        Returns all item definitions.
    .OUTPUTS
        Array of PSCustomObject item definitions sorted by Name.
    #>

    if ($script:ItemsByName.Count -eq 0) {
        Initialize-Items
    }

    $sorted = $script:ItemsByName.Values | Sort-Object -Property Name
    return @($sorted)
}

function Get-ItemsByType {
    <#
    .SYNOPSIS
        Returns all items of a given type.
    .PARAMETER Type
        Item type string: 'Resource', 'Tool', 'Weapon', 'Armor', 'Consumable'.
    .OUTPUTS
        Array of PSCustomObject items matching the type, or empty array.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type
    )

    if ($script:ItemsByName.Count -eq 0) {
        Initialize-Items
    }

    $results = @()
    foreach ($item in $script:ItemsByName.Values) {
        if ($item.Type -eq $Type) {
            $results += $item
        }
    }
    return @($results)
}

function Get-ItemStackSize {
    <#
    .SYNOPSIS
        Returns the stack size for a named item.
    .PARAMETER Name
        Item name (case-insensitive).
    .OUTPUTS
        Int stack size. Returns 64 if item not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $item = Get-ItemDefinition -Name $Name
    if ($null -ne $item) {
        return $item.StackSize
    }

    return [int]64
}

# ---------------------------------------------------------------------------
# Auto-initialize on dot-source
# ---------------------------------------------------------------------------
Initialize-Items
