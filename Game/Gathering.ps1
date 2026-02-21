# ============================================================================
# Game/Gathering.ps1 - Resource Gathering System
# ============================================================================
# When blocks are broken, this module determines what items drop and adds
# them to the player's inventory. Each block type has a drop table with
# primary and optional bonus drops with configurable chance.
#
# Dependencies: World/Blocks.ps1 (Get-BlockTypeById),
#               Game/Inventory.ps1 (Add-InventoryItem),
#               Data/Items.ps1 (item name validation)
# ============================================================================

# --- Module State ---
$script:GatheringRandom     = $null   # [System.Random] instance for drop rolls
$script:GatheringDropTables = $null   # Hashtable: [byte]BlockId -> array of drop entries

# ============================================================================
# Initialize-Gathering - Build drop tables and register callback
# ============================================================================

function Initialize-Gathering {
    <#
    .SYNOPSIS
        Initializes the resource gathering system with drop tables.
    .DESCRIPTION
        Creates drop table definitions for each breakable block type and
        initializes the random number generator for chance-based drops.
        Must be called AFTER Initialize-Inventory.
    #>

    $script:GatheringRandom = [System.Random]::new()
    $script:GatheringDropTables = @{}

    # -----------------------------------------------------------------
    # Drop Table Definitions
    # Each entry: PSCustomObject { ItemName, MinCount, MaxCount, Chance }
    #   - Chance is 0.0 to 1.0 (1.0 = 100%)
    #   - MinCount/MaxCount define random range (inclusive)
    # -----------------------------------------------------------------

    # Stone (ID 1) -> Cobblestone x1 (100%)
    $script:GatheringDropTables[[byte]1] = @(
        [PSCustomObject]@{ ItemName = 'Cobblestone'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Dirt (ID 2) -> Dirt x1 (100%)
    $script:GatheringDropTables[[byte]2] = @(
        [PSCustomObject]@{ ItemName = 'Dirt'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Grass (ID 3) -> Dirt x1 (100%)
    $script:GatheringDropTables[[byte]3] = @(
        [PSCustomObject]@{ ItemName = 'Dirt'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Sand (ID 4) -> Sand x1 (100%)
    $script:GatheringDropTables[[byte]4] = @(
        [PSCustomObject]@{ ItemName = 'Sand'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Wood (ID 5) -> Wood x1 (100%), Stick x1 (25%)
    $script:GatheringDropTables[[byte]5] = @(
        [PSCustomObject]@{ ItemName = 'Wood';  MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
        [PSCustomObject]@{ ItemName = 'Stick'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]0.25 }
    )

    # Leaves (ID 6) -> Stick x1 (15%)
    $script:GatheringDropTables[[byte]6] = @(
        [PSCustomObject]@{ ItemName = 'Stick'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]0.15 }
    )

    # Cobblestone (ID 8) -> Cobblestone x1 (100%)
    $script:GatheringDropTables[[byte]8] = @(
        [PSCustomObject]@{ ItemName = 'Cobblestone'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Planks (ID 9) -> Planks x1 (100%)
    $script:GatheringDropTables[[byte]9] = @(
        [PSCustomObject]@{ ItemName = 'Planks'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    # Glass (ID 10) -> nothing (glass shatters)
    # No entry needed; absence means no drops

    # Iron Ore (ID 11) -> Iron Ingot x1 (100%), Coal x1 (20%)
    $script:GatheringDropTables[[byte]11] = @(
        [PSCustomObject]@{ ItemName = 'Iron Ingot'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
        [PSCustomObject]@{ ItemName = 'Coal';       MinCount = [int]1; MaxCount = [int]1; Chance = [float]0.20 }
    )

    # Gold Ore (ID 12) -> Gold Ingot x1 (100%)
    $script:GatheringDropTables[[byte]12] = @(
        [PSCustomObject]@{ ItemName = 'Gold Ingot'; MinCount = [int]1; MaxCount = [int]1; Chance = [float]1.0 }
    )

    Write-Host "[Gathering] Resource gathering initialized ($($script:GatheringDropTables.Count) drop tables)." -ForegroundColor Green
}

# ============================================================================
# Get-BlockDrops - Query drop table for a block type
# ============================================================================

function Get-BlockDrops {
    <#
    .SYNOPSIS
        Returns the drop table entries for a given block ID.
    .PARAMETER BlockId
        Byte block ID to look up.
    .OUTPUTS
        Array of PSCustomObject {ItemName, MinCount, MaxCount, Chance}, or
        empty array if block has no drops.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte]$BlockId
    )

    if ($null -ne $script:GatheringDropTables -and $script:GatheringDropTables.ContainsKey($BlockId)) {
        return @($script:GatheringDropTables[$BlockId])
    }

    return @()
}

# ============================================================================
# Invoke-BlockDrop - Roll drops for a broken block and add to inventory
# ============================================================================

function Invoke-BlockDrop {
    <#
    .SYNOPSIS
        Rolls the drop table for a block ID and adds resulting items to
        the player inventory.
    .DESCRIPTION
        For each drop entry, rolls against Chance using the module RNG.
        If the roll succeeds, picks a random count between MinCount and
        MaxCount (inclusive) and calls Add-InventoryItem.
    .PARAMETER BlockId
        Byte block ID that was broken.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte]$BlockId
    )

    $drops = Get-BlockDrops -BlockId $BlockId
    if ($drops.Count -eq 0) { return }

    foreach ($drop in $drops) {
        # Roll for chance
        [float]$roll = [float]$script:GatheringRandom.NextDouble()
        if ($roll -gt $drop.Chance) { continue }

        # Determine count (random between Min and Max, inclusive)
        [int]$count = $drop.MinCount
        if ($drop.MaxCount -gt $drop.MinCount) {
            $count = $script:GatheringRandom.Next($drop.MinCount, $drop.MaxCount + 1)
        }

        # Add to inventory
        $added = Add-InventoryItem -Name $drop.ItemName -Count $count
        if ($added) {
            Write-Host "[Gathering] +$count $($drop.ItemName)" -ForegroundColor Yellow
        } else {
            Write-Host "[Gathering] Inventory full! Lost $count $($drop.ItemName)." -ForegroundColor Red
        }
    }
}
