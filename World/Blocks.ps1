# ============================================================================
# World/Blocks.ps1  - Block Type Registry
# ============================================================================
# Centralized registry of all block types with their properties.
# Provides lookup functions by ID or name for use by world generation,
# rendering, block interaction, and resource gathering systems.
# ============================================================================

# ---------------------------------------------------------------------------
# Module-level block registry
# ---------------------------------------------------------------------------

$script:BlockTypesById   = @{}   # [byte] -> PSCustomObject
$script:BlockTypesByName = @{}   # [string] -> PSCustomObject (lowercase key)

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

function Initialize-BlockTypes {
    <#
    .SYNOPSIS
        Initializes the block type registry with all defined block types.
    .DESCRIPTION
        Creates PSCustomObject definitions for each block type with properties
        including solidity, transparency, hardness, tool type, and texture mapping.
    #>

    $script:BlockTypesById   = @{}
    $script:BlockTypesByName = @{}

    # Helper to register a block type in both lookup tables
    $registerBlock = {
        param($Block)
        $script:BlockTypesById[$Block.Id]                    = $Block
        $script:BlockTypesByName[$Block.Name.ToLower()]      = $Block
    }

    # --- ID 0: Air ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]0
        Name          = 'Air'
        TextureName   = 'air'
        IsSolid       = $false
        IsTransparent = $true
        IsBreakable   = $false
        Hardness      = [float]0.0
        ToolType      = 'none'
        DropId        = [byte]0
        LightLevel    = [int]0
    })

    # --- ID 1: Stone ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]1
        Name          = 'Stone'
        TextureName   = 'stone'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]1.5
        ToolType      = 'pickaxe'
        DropId        = [byte]8    # Drops cobblestone
        LightLevel    = [int]0
    })

    # --- ID 2: Dirt ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]2
        Name          = 'Dirt'
        TextureName   = 'dirt'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]0.5
        ToolType      = 'shovel'
        DropId        = [byte]2
        LightLevel    = [int]0
    })

    # --- ID 3: Grass ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]3
        Name          = 'Grass'
        TextureName   = 'grass'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]0.6
        ToolType      = 'shovel'
        DropId        = [byte]2    # Drops dirt
        LightLevel    = [int]0
    })

    # --- ID 4: Sand ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]4
        Name          = 'Sand'
        TextureName   = 'sand'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]0.5
        ToolType      = 'shovel'
        DropId        = [byte]4
        LightLevel    = [int]0
    })

    # --- ID 5: Wood ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]5
        Name          = 'Wood'
        TextureName   = 'wood_side'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]2.0
        ToolType      = 'axe'
        DropId        = [byte]5
        LightLevel    = [int]0
    })

    # --- ID 6: Leaves ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]6
        Name          = 'Leaves'
        TextureName   = 'leaves'
        IsSolid       = $true
        IsTransparent = $true
        IsBreakable   = $true
        Hardness      = [float]0.2
        ToolType      = 'shears'
        DropId        = [byte]0    # Drops nothing (or saplings later)
        LightLevel    = [int]0
    })

    # --- ID 7: Water ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]7
        Name          = 'Water'
        TextureName   = 'stone'
        IsSolid       = $false
        IsTransparent = $true
        IsBreakable   = $false
        Hardness      = [float]0.0
        ToolType      = 'none'
        DropId        = [byte]0
        LightLevel    = [int]0
    })

    # --- ID 8: Cobblestone ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]8
        Name          = 'Cobblestone'
        TextureName   = 'stone'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]2.0
        ToolType      = 'pickaxe'
        DropId        = [byte]8
        LightLevel    = [int]0
    })

    # --- ID 9: Planks ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]9
        Name          = 'Planks'
        TextureName   = 'wood_side'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]1.5
        ToolType      = 'axe'
        DropId        = [byte]9
        LightLevel    = [int]0
    })

    # --- ID 10: Glass ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]10
        Name          = 'Glass'
        TextureName   = 'leaves'
        IsSolid       = $true
        IsTransparent = $true
        IsBreakable   = $true
        Hardness      = [float]0.3
        ToolType      = 'hand'
        DropId        = [byte]0    # Glass drops nothing
        LightLevel    = [int]0
    })

    # --- ID 11: Iron Ore ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]11
        Name          = 'Iron Ore'
        TextureName   = 'stone'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]3.0
        ToolType      = 'pickaxe'
        DropId        = [byte]11
        LightLevel    = [int]0
    })

    # --- ID 12: Gold Ore ---
    & $registerBlock ([PSCustomObject]@{
        Id            = [byte]12
        Name          = 'Gold Ore'
        TextureName   = 'stone'
        IsSolid       = $true
        IsTransparent = $false
        IsBreakable   = $true
        Hardness      = [float]3.0
        ToolType      = 'pickaxe'
        DropId        = [byte]12
        LightLevel    = [int]0
    })
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-BlockType {
    <#
    .SYNOPSIS
        Returns a block type definition by name.
    .PARAMETER Name
        Block type name (case-insensitive). E.g. 'Stone', 'Dirt', 'Iron Ore'.
    .OUTPUTS
        PSCustomObject with block properties, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:BlockTypesByName.Count -eq 0) {
        Initialize-BlockTypes
    }

    $key = $Name.ToLower()
    if ($script:BlockTypesByName.ContainsKey($key)) {
        return $script:BlockTypesByName[$key]
    }

    Write-Warning "Block type '$Name' not found."
    return $null
}

function Get-BlockTypeById {
    <#
    .SYNOPSIS
        Returns a block type definition by its byte ID.
    .PARAMETER Id
        Byte block ID (0-255).
    .OUTPUTS
        PSCustomObject with block properties, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte]$Id
    )

    if ($script:BlockTypesById.Count -eq 0) {
        Initialize-BlockTypes
    }

    if ($script:BlockTypesById.ContainsKey($Id)) {
        return $script:BlockTypesById[$Id]
    }

    return $null
}

function Get-AllBlockTypes {
    <#
    .SYNOPSIS
        Returns all block type definitions.
    .OUTPUTS
        Array of PSCustomObject block type definitions sorted by Id.
    #>

    if ($script:BlockTypesById.Count -eq 0) {
        Initialize-BlockTypes
    }

    $sorted = $script:BlockTypesById.Values | Sort-Object -Property Id
    return @($sorted)
}

function Test-BlockSolid {
    <#
    .SYNOPSIS
        Quick check whether a block ID is solid.
    .PARAMETER Id
        Byte block ID.
    .OUTPUTS
        Boolean. $true if solid, $false otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte]$Id
    )

    if ($script:BlockTypesById.Count -eq 0) {
        Initialize-BlockTypes
    }

    if ($script:BlockTypesById.ContainsKey($Id)) {
        return $script:BlockTypesById[$Id].IsSolid
    }

    return $false
}

function Test-BlockTransparent {
    <#
    .SYNOPSIS
        Quick check whether a block ID is transparent.
    .PARAMETER Id
        Byte block ID.
    .OUTPUTS
        Boolean. $true if transparent, $false otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte]$Id
    )

    if ($script:BlockTypesById.Count -eq 0) {
        Initialize-BlockTypes
    }

    if ($script:BlockTypesById.ContainsKey($Id)) {
        return $script:BlockTypesById[$Id].IsTransparent
    }

    return $false
}

# ---------------------------------------------------------------------------
# Auto-initialize on dot-source
# ---------------------------------------------------------------------------
Initialize-BlockTypes
