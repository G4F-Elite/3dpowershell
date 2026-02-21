# ============================================================================
# Game/Crafting.ps1 - Player Crafting System
# ============================================================================
# Handles crafting operations: checking if player has required materials,
# consuming ingredients from inventory, and adding crafted results.
# Provides recipe discovery (list craftable items based on current inventory).
#
# Dependencies: Data/Items.ps1 (Get-ItemDefinition),
#               Data/Recipes.ps1 (Get-CraftingRecipe, Get-AllCraftingRecipes),
#               Game/Inventory.ps1 (Add-InventoryItem, Remove-InventoryItem,
#                                   Get-InventoryItemCount)
# ============================================================================

# --- Module State ---
$script:CraftingInitialized = $false

# ============================================================================
# Initialize-Crafting - Set up crafting system
# ============================================================================

function Initialize-Crafting {
    <#
    .SYNOPSIS
        Initializes the crafting system. Ensures recipe data is loaded.
    .DESCRIPTION
        Triggers recipe initialization if not already done. No update callback
        needed since crafting is event-driven via Invoke-Craft calls.
    #>

    # Ensure recipes are loaded (lazy init guard)
    $allRecipes = Get-AllCraftingRecipes
    $script:CraftingInitialized = $true

    Write-Host "[Crafting] Crafting system initialized ($($allRecipes.Count) recipes available)." -ForegroundColor Green
}

# ============================================================================
# Public API - Crafting Operations
# ============================================================================

function Test-CanCraft {
    <#
    .SYNOPSIS
        Checks if the player has enough materials to craft the named item.
    .PARAMETER Name
        Result item name (case-insensitive). Must match a recipe Name.
    .PARAMETER Count
        Number of times to craft (default 1). Multiplies ingredient requirements.
    .OUTPUTS
        $true if player has all required materials, $false otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Count = 1
    )

    if ($Count -le 0) { return $false }

    $recipe = Get-CraftingRecipe -Name $Name
    if ($null -eq $recipe) { return $false }

    # Check each ingredient
    foreach ($ingredient in $recipe.Ingredients) {
        $required = $ingredient.Count * $Count
        $available = Get-InventoryItemCount -Name $ingredient.ItemName
        if ($available -lt $required) {
            return $false
        }
    }

    return $true
}

function Invoke-Craft {
    <#
    .SYNOPSIS
        Crafts an item by consuming ingredients and adding the result to inventory.
    .DESCRIPTION
        1. Validates recipe exists
        2. Validates result item exists in item registry
        3. Checks player has all required ingredients
        4. Removes ingredients from inventory
        5. Adds crafted result to inventory
        Returns $false and rolls back if any step fails.
    .PARAMETER Name
        Result item name (case-insensitive). Must match a recipe Name.
    .PARAMETER Count
        Number of times to craft (default 1). Each craft produces ResultCount items.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Count = 1
    )

    if ($Count -le 0) { return $false }

    # Look up recipe
    $recipe = Get-CraftingRecipe -Name $Name
    if ($null -eq $recipe) {
        Write-Host "[Crafting] No recipe found for: $Name" -ForegroundColor Red
        return $false
    }

    # Validate result item exists in item registry
    $resultDef = Get-ItemDefinition -Name $recipe.Name
    if ($null -eq $resultDef) {
        Write-Host "[Crafting] Result item not in registry: $($recipe.Name)" -ForegroundColor Red
        return $false
    }

    # Check all ingredients available
    if (-not (Test-CanCraft -Name $Name -Count $Count)) {
        Write-Host "[Crafting] Not enough materials to craft $Name" -ForegroundColor Red
        return $false
    }

    # Remove ingredients (track for rollback)
    $removedIngredients = @()
    $removalFailed = $false

    foreach ($ingredient in $recipe.Ingredients) {
        $required = $ingredient.Count * $Count
        $removed = Remove-InventoryItem -Name $ingredient.ItemName -Count $required
        if (-not $removed) {
            $removalFailed = $true
            break
        }
        $removedIngredients += [PSCustomObject]@{
            ItemName = $ingredient.ItemName
            Count    = $required
        }
    }

    # Rollback if removal failed
    if ($removalFailed) {
        foreach ($item in $removedIngredients) {
            Add-InventoryItem -Name $item.ItemName -Count $item.Count | Out-Null
        }
        Write-Host "[Crafting] Failed to consume materials for $Name" -ForegroundColor Red
        return $false
    }

    # Add crafted result to inventory
    $totalResult = $recipe.ResultCount * $Count
    $added = Add-InventoryItem -Name $recipe.Name -Count $totalResult
    if (-not $added) {
        # Rollback: return all ingredients
        foreach ($item in $removedIngredients) {
            Add-InventoryItem -Name $item.ItemName -Count $item.Count | Out-Null
        }
        Write-Host "[Crafting] Inventory full, cannot add $($recipe.Name)" -ForegroundColor Red
        return $false
    }

    Write-Host "[Crafting] Crafted ${totalResult}x $($recipe.Name)" -ForegroundColor Cyan
    return $true
}

# ============================================================================
# Public API - Recipe Discovery
# ============================================================================

function Get-CraftableItems {
    <#
    .SYNOPSIS
        Returns all recipes the player can currently craft with their inventory.
    .DESCRIPTION
        Iterates all recipes and checks if the player has enough materials
        for at least one craft of each. Returns recipes that can be crafted.
    .OUTPUTS
        Array of PSCustomObject recipes that can be crafted right now.
    #>

    $allRecipes = Get-AllCraftingRecipes
    $craftable = @()

    foreach ($recipe in $allRecipes) {
        if (Test-CanCraft -Name $recipe.Name -Count 1) {
            $craftable += $recipe
        }
    }

    return ,$craftable
}

function Get-MaxCraftCount {
    <#
    .SYNOPSIS
        Returns the maximum number of times a recipe can be crafted.
    .PARAMETER Name
        Result item name (case-insensitive). Must match a recipe Name.
    .OUTPUTS
        Int maximum craft count (0 if recipe not found or no materials).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $recipe = Get-CraftingRecipe -Name $Name
    if ($null -eq $recipe) { return 0 }

    $maxCount = [int]::MaxValue

    foreach ($ingredient in $recipe.Ingredients) {
        $available = Get-InventoryItemCount -Name $ingredient.ItemName
        if ($ingredient.Count -le 0) { continue }
        $possible = [System.Math]::Floor($available / $ingredient.Count)
        if ($possible -lt $maxCount) {
            $maxCount = [int]$possible
        }
    }

    if ($maxCount -eq [int]::MaxValue) { $maxCount = 0 }

    return $maxCount
}

function Get-RecipeIngredients {
    <#
    .SYNOPSIS
        Returns the ingredient list for a named recipe.
    .PARAMETER Name
        Result item name (case-insensitive). Must match a recipe Name.
    .OUTPUTS
        Array of PSCustomObject {ItemName, Count}, or empty array if not found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $recipe = Get-CraftingRecipe -Name $Name
    if ($null -eq $recipe) { return ,@() }

    return ,$recipe.Ingredients
}
