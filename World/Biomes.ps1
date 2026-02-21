# Biomes.ps1 - Biome definitions for voxel world generation
# Block IDs: 0=air, 1=stone, 2=dirt, 3=grass, 4=sand, 5=wood, 6=leaves, 7=water

# ---------------------------------------------------------------------------
# Module-level biome definitions
# ---------------------------------------------------------------------------

$script:Biomes = @{}

function Initialize-Biomes {
    <#
    .SYNOPSIS
        Initializes the biome definitions hashtable.
    .DESCRIPTION
        Creates PSCustomObject definitions for each biome type with terrain
        parameters, block assignments, and decoration settings.
    #>

    $script:Biomes = @{}

    # Plains - moderate temperature, moderate moisture (default/fallback)
    $script:Biomes['Plains'] = [PSCustomObject]@{
        Name            = 'Plains'
        SurfaceBlock    = [byte]3   # grass
        SubSurfaceBlock = [byte]2   # dirt
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]36
        HeightVariation = [float]0.3
        TreeDensity     = [float]0.02
        WaterLevel      = [int]32
    }

    # Forest - moderate temperature, high moisture
    $script:Biomes['Forest'] = [PSCustomObject]@{
        Name            = 'Forest'
        SurfaceBlock    = [byte]3   # grass
        SubSurfaceBlock = [byte]2   # dirt
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]38
        HeightVariation = [float]0.5
        TreeDensity     = [float]0.15
        WaterLevel      = [int]32
    }

    # Desert - high temperature, low moisture
    $script:Biomes['Desert'] = [PSCustomObject]@{
        Name            = 'Desert'
        SurfaceBlock    = [byte]4   # sand
        SubSurfaceBlock = [byte]4   # sand
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]34
        HeightVariation = [float]0.2
        TreeDensity     = [float]0.0
        WaterLevel      = [int]28
    }

    # Mountains - low-moderate temperature, low-moderate moisture
    $script:Biomes['Mountains'] = [PSCustomObject]@{
        Name            = 'Mountains'
        SurfaceBlock    = [byte]1   # stone
        SubSurfaceBlock = [byte]1   # stone
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]56
        HeightVariation = [float]1.0
        TreeDensity     = [float]0.01
        WaterLevel      = [int]32
    }

    # Snow - low temperature
    $script:Biomes['Snow'] = [PSCustomObject]@{
        Name            = 'Snow'
        SurfaceBlock    = [byte]3   # grass (snow block not available, use grass as placeholder)
        SubSurfaceBlock = [byte]2   # dirt
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]42
        HeightVariation = [float]0.6
        TreeDensity     = [float]0.03
        WaterLevel      = [int]32
    }

    # Swamp - moderate temperature, very high moisture
    $script:Biomes['Swamp'] = [PSCustomObject]@{
        Name            = 'Swamp'
        SurfaceBlock    = [byte]2   # dirt
        SubSurfaceBlock = [byte]2   # dirt
        FillerBlock     = [byte]1   # stone
        BaseHeight      = [int]30
        HeightVariation = [float]0.15
        TreeDensity     = [float]0.08
        WaterLevel      = [int]34
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-Biome {
    <#
    .SYNOPSIS
        Selects the best matching biome based on temperature and moisture.
    .PARAMETER Temperature
        Temperature value from 0.0 (cold) to 1.0 (hot).
    .PARAMETER Moisture
        Moisture value from 0.0 (dry) to 1.0 (wet).
    .OUTPUTS
        PSCustomObject with biome properties.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [float]$Temperature,

        [Parameter(Mandatory=$true)]
        [float]$Moisture
    )

    # Ensure biomes are initialized
    

    # Clamp inputs to 0.0-1.0
    if ($Temperature -lt 0.0) { $Temperature = 0.0 }
    if ($Temperature -gt 1.0) { $Temperature = 1.0 }
    if ($Moisture -lt 0.0) { $Moisture = 0.0 }
    if ($Moisture -gt 1.0) { $Moisture = 1.0 }

    # Biome selection rules (evaluated in priority order)
    # Snow: cold temperatures (temp < 0.3)
    if ($Temperature -lt 0.3) {
        return $script:Biomes['Snow']
    }

    # Desert: hot and dry (temp >= 0.7, moisture < 0.3)
    if ($Temperature -ge 0.7 -and $Moisture -lt 0.3) {
        return $script:Biomes['Desert']
    }

    # Mountains: low-moderate temp, low-moderate moisture (temp 0.3-0.5, moisture < 0.4)
    if ($Temperature -ge 0.3 -and $Temperature -lt 0.5 -and $Moisture -lt 0.4) {
        return $script:Biomes['Mountains']
    }

    # Swamp: moderate temp, very high moisture (temp 0.3-0.7, moisture >= 0.85)
    if ($Temperature -ge 0.3 -and $Temperature -lt 0.7 -and $Moisture -ge 0.85) {
        return $script:Biomes['Swamp']
    }

    # Forest: moderate temp, high moisture (temp 0.3-0.7, moisture >= 0.55)
    if ($Temperature -ge 0.3 -and $Temperature -lt 0.7 -and $Moisture -ge 0.55) {
        return $script:Biomes['Forest']
    }

    # Plains: default fallback for everything else
    return $script:Biomes['Plains']
}

function Get-AllBiomes {
    <#
    .SYNOPSIS
        Returns the full biome definitions hashtable.
    .OUTPUTS
        Hashtable of all biome PSCustomObjects keyed by name.
    #>

    # Ensure biomes are initialized
    

    return $script:Biomes
}

function Get-BiomeByName {
    <#
    .SYNOPSIS
        Returns a specific biome by its name.
    .PARAMETER Name
        The biome name (Plains, Forest, Desert, Mountains, Snow, Swamp).
    .OUTPUTS
        PSCustomObject with biome properties, or $null if not found.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    # Ensure biomes are initialized
    

    if ($script:Biomes.ContainsKey($Name)) {
        return $script:Biomes[$Name]
    }

    Write-Warning "Biome '$Name' not found. Available: $($script:Biomes.Keys -join ', ')"
    return $null
}

# ---------------------------------------------------------------------------
# Auto-initialize on dot-source
# ---------------------------------------------------------------------------
Initialize-Biomes
