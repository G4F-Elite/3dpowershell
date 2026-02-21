# ============================================================================
# Data/Recipes.ps1 - Crafting Recipe Definitions
# ============================================================================
# Centralized registry of all crafting recipes. Each recipe defines the
# result item, required ingredients (with counts), and the number of items
# produced per craft.
#
# Dependencies: Data/Items.ps1 (Get-ItemDefinition for validation)
# ============================================================================

# ---------------------------------------------------------------------------
# Module-level recipe registry
# ---------------------------------------------------------------------------

$script:CraftingRecipes = @()   # Array of PSCustomObject recipes

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

function Initialize-CraftingRecipes {
    <#
    .SYNOPSIS
        Populates the crafting recipe registry with all defined recipes.
    .DESCRIPTION
        Creates PSCustomObject definitions for each recipe with Name (result),
        Ingredients (array of {ItemName, Count}), and ResultCount (int).
        Validates that all referenced items exist in the item registry.
    #>

    $script:CraftingRecipes = @()

    # ===================================================================
    # BASIC PROCESSING
    # ===================================================================

    # --- Wood -> Planks (4 planks from 1 wood) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Planks'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Wood'; Count = [int]1 }
        )
        ResultCount = [int]4
    }

    # --- Planks -> Stick (2 sticks from 1 plank) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stick'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Planks'; Count = [int]1 }
        )
        ResultCount = [int]2
    }

    # --- Cobblestone -> Stone (smelting equivalent) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stone'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Cobblestone'; Count = [int]1 }
        )
        ResultCount = [int]1
    }

    # ===================================================================
    # WOODEN TOOLS & WEAPONS
    # ===================================================================

    # --- Wooden Pickaxe (3 planks + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Wooden Pickaxe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Planks'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Wooden Axe (3 planks + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Wooden Axe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Planks'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Wooden Shovel (1 plank + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Wooden Shovel'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Planks'; Count = [int]1 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Wooden Sword (2 planks + 1 stick) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Wooden Sword'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Planks'; Count = [int]2 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]1 }
        )
        ResultCount = [int]1
    }

    # ===================================================================
    # STONE TOOLS & WEAPONS
    # ===================================================================

    # --- Stone Pickaxe (3 cobblestone + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stone Pickaxe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Cobblestone'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Stone Axe (3 cobblestone + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stone Axe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Cobblestone'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Stone Shovel (1 cobblestone + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stone Shovel'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Cobblestone'; Count = [int]1 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Stone Sword (2 cobblestone + 1 stick) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Stone Sword'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Cobblestone'; Count = [int]2 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]1 }
        )
        ResultCount = [int]1
    }

    # ===================================================================
    # IRON TOOLS & WEAPONS
    # ===================================================================

    # --- Iron Pickaxe (3 iron ingots + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Iron Pickaxe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Iron Ingot'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Iron Axe (3 iron ingots + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Iron Axe'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Iron Ingot'; Count = [int]3 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Iron Shovel (1 iron ingot + 2 sticks) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Iron Shovel'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Iron Ingot'; Count = [int]1 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]2 }
        )
        ResultCount = [int]1
    }

    # --- Iron Sword (2 iron ingots + 1 stick) ---
    $script:CraftingRecipes += [PSCustomObject]@{
        Name        = 'Iron Sword'
        Ingredients = @(
            [PSCustomObject]@{ ItemName = 'Iron Ingot'; Count = [int]2 }
            [PSCustomObject]@{ ItemName = 'Stick'; Count = [int]1 }
        )
        ResultCount = [int]1
    }

    # --- Validate all recipes reference valid items ---
    foreach ($recipe in $script:CraftingRecipes) {
        $resultDef = Get-ItemDefinition -Name $recipe.Name
        if ($null -eq $resultDef) {
            Write-Host "[Recipes] WARNING: Recipe result '$($recipe.Name)' not found in item registry" -ForegroundColor Yellow
        }
        foreach ($ingredient in $recipe.Ingredients) {
            $ingDef = Get-ItemDefinition -Name $ingredient.ItemName
            if ($null -eq $ingDef) {
                Write-Host "[Recipes] WARNING: Ingredient '$($ingredient.ItemName)' not found in item registry" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "[Recipes] Loaded $($script:CraftingRecipes.Count) crafting recipes." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-CraftingRecipe {
    <#
    .SYNOPSIS
        Returns a crafting recipe by result item name.
    .PARAMETER Name
        Result item name (case-insensitive).
    .OUTPUTS
        PSCustomObject with Name, Ingredients, ResultCount, or $null if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:CraftingRecipes.Count -eq 0) {
        Initialize-CraftingRecipes
    }

    foreach ($recipe in $script:CraftingRecipes) {
        if ($recipe.Name -eq $Name) {
            return $recipe
        }
    }

    return $null
}

function Get-AllCraftingRecipes {
    <#
    .SYNOPSIS
        Returns all crafting recipes.
    .OUTPUTS
        Array of PSCustomObject recipes.
    #>

    if ($script:CraftingRecipes.Count -eq 0) {
        Initialize-CraftingRecipes
    }

    return ,$script:CraftingRecipes
}
