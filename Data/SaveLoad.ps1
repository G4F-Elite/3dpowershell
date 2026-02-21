# ============================================================================
# Data/SaveLoad.ps1 - Slot-based Save/Load System (JSON)
# ============================================================================
# Provides deterministic local save slots with JSON envelope versioning,
# validation, atomic writes, and state restore for available game systems.
#
# Save scope:
# - Player position
# - Inventory slots + hotbar
# - Equipment slots
# - Quest states, objectives, and flags
# - Player stats
# - Experience (XP/Level)
# - Reputation factions
# - World seed + loaded chunk snapshot metadata
#
# Notes:
# - No external dependencies
# - PowerShell 5.1 compatible
# ============================================================================

$script:SaveLoadSchemaVersion = [int]1
$script:SaveLoadAutoSaveRegistered = $false
$script:SaveLoadAutoSaveSlot = [int]1

function Get-SaveProjectRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }

    return (Get-Location).Path
}

function Get-SaveDirectory {
    return (Join-Path (Get-SaveProjectRoot) '.saves')
}

function Resolve-SaveSlotNumber {
    param([int]$Slot)

    if ($Slot -lt 1) {
        throw 'Save slot must be >= 1.'
    }

    if ($Slot -gt 99) {
        throw 'Save slot must be <= 99.'
    }

    return [int]$Slot
}

function Get-SaveSlotPath {
    param([int]$Slot)

    [int]$safeSlot = Resolve-SaveSlotNumber -Slot $Slot
    [string]$name = 'slot-{0}.json' -f $safeSlot.ToString('00')
    return (Join-Path (Get-SaveDirectory) $name)
}

function Ensure-SaveDirectory {
    $saveDir = Get-SaveDirectory
    if (-not (Test-Path -LiteralPath $saveDir)) {
        New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
    }

    return $saveDir
}

function Get-SaveValue {
    param(
        $Source,
        [string[]]$Names,
        $Default = $null
    )

    if ($null -eq $Source) {
        return $Default
    }

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }

        if ($Source -is [System.Collections.IDictionary]) {
            try {
                if ($Source.Contains($name)) {
                    return $Source[$name]
                }
            }
            catch {
                # Ignore dictionary contains errors.
            }

            foreach ($key in $Source.Keys) {
                if ([string]::Equals([string]$key, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Source[$key]
                }
            }
        }
        else {
            foreach ($prop in $Source.PSObject.Properties) {
                if ([string]::Equals([string]$prop.Name, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $prop.Value
                }
            }
        }
    }

    return $Default
}

function Expand-SaveCollection {
    param($InputObject)

    if ($null -eq $InputObject) {
        return @()
    }

    $items = @($InputObject)
    if ($items.Count -eq 1) {
        $first = $items[0]
        if ($first -is [System.Array]) {
            return @($first)
        }

        if (($first -is [System.Collections.IList]) -and -not ($first -is [string])) {
            return @($first)
        }
    }

    return @($items)
}

function Get-SaveMapEntries {
    param($Map)

    $result = @{}
    if ($null -eq $Map) {
        return $result
    }

    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) {
            $result[[string]$key] = $Map[$key]
        }
        return $result
    }

    foreach ($prop in $Map.PSObject.Properties) {
        $result[[string]$prop.Name] = $prop.Value
    }

    return $result
}

function ConvertTo-SaveInt {
    param($Value, [int]$Default = 0)
    try {
        return [int]$Value
    }
    catch {
        return [int]$Default
    }
}

function ConvertTo-SaveFloat {
    param($Value, [float]$Default = 0.0)
    try {
        return [float]$Value
    }
    catch {
        return [float]$Default
    }
}

function ConvertTo-SaveBool {
    param($Value, [bool]$Default = $false)
    try {
        return [bool]$Value
    }
    catch {
        return [bool]$Default
    }
}

function Get-SnapshotPlayerPosition {
    $position = $null
    if (Get-Command -Name Get-PlayerPosition -ErrorAction SilentlyContinue) {
        try {
            $position = Get-PlayerPosition
        }
        catch {
            $position = $null
        }
    }

    [float]$x = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $position -Names @('X') -Default 0.0) -Default 0.0
    [float]$y = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $position -Names @('Y') -Default 0.0) -Default 0.0
    [float]$z = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $position -Names @('Z') -Default 0.0) -Default 0.0

    return [PSCustomObject]@{
        X = [float]$x
        Y = [float]$y
        Z = [float]$z
    }
}

function Get-SnapshotInventory {
    $slotsOut = @()
    if (Get-Command -Name Get-InventorySlots -ErrorAction SilentlyContinue) {
        try {
            $slots = Expand-SaveCollection -InputObject (Get-InventorySlots)
            [int]$index = 0
            foreach ($slot in @($slots)) {
                if ($null -eq $slot) {
                    $slotsOut += [PSCustomObject]@{ Index = [int]$index; ItemName = ''; Count = [int]0 }
                    $index++
                    continue
                }

                [string]$itemName = [string](Get-SaveValue -Source $slot -Names @('ItemName') -Default '')
                [int]$count = ConvertTo-SaveInt -Value (Get-SaveValue -Source $slot -Names @('Count') -Default 0) -Default 0
                if ($count -lt 0) { $count = [int]0 }

                $slotsOut += [PSCustomObject]@{
                    Index = [int]$index
                    ItemName = [string]$itemName
                    Count = [int]$count
                }
                $index++
            }
        }
        catch {
            $slotsOut = @()
        }
    }

    [int]$hotbarSelection = [int]0
    if (Get-Command -Name Get-HotbarSelection -ErrorAction SilentlyContinue) {
        try {
            $hotbarSelection = ConvertTo-SaveInt -Value (Get-HotbarSelection) -Default 0
        }
        catch {
            $hotbarSelection = [int]0
        }
    }

    return [PSCustomObject]@{
        Slots = @($slotsOut)
        HotbarSelection = [int]$hotbarSelection
    }
}

function Get-SnapshotEquipment {
    $slots = @{}
    if (Get-Command -Name Get-AllEquipment -ErrorAction SilentlyContinue) {
        try {
            $equipment = Get-AllEquipment
            if ($equipment -is [System.Collections.IDictionary]) {
                foreach ($key in $equipment.Keys) {
                    $slots[[string]$key] = [string]$equipment[$key]
                }
            }
            else {
                foreach ($prop in $equipment.PSObject.Properties) {
                    $slots[[string]$prop.Name] = [string]$prop.Value
                }
            }
        }
        catch {
            $slots = @{}
        }
    }

    return [PSCustomObject]@{
        Slots = $slots
    }
}

function Get-SnapshotQuests {
    $quests = @()
    if (Get-Command -Name Get-AllQuests -ErrorAction SilentlyContinue) {
        try {
            foreach ($quest in (Expand-SaveCollection -InputObject (Get-AllQuests))) {
                if ($null -eq $quest) { continue }

                $objectiveRows = @()
                foreach ($objective in @((Get-SaveValue -Source $quest -Names @('Objectives') -Default @()))) {
                    if ($null -eq $objective) { continue }
                    $objectiveRows += [PSCustomObject]@{
                        Id = [string](Get-SaveValue -Source $objective -Names @('Id') -Default '')
                        CurrentCount = [int](ConvertTo-SaveInt -Value (Get-SaveValue -Source $objective -Names @('CurrentCount') -Default 0) -Default 0)
                        RequiredCount = [int](ConvertTo-SaveInt -Value (Get-SaveValue -Source $objective -Names @('RequiredCount') -Default 1) -Default 1)
                        IsCompleted = [bool](ConvertTo-SaveBool -Value (Get-SaveValue -Source $objective -Names @('IsCompleted') -Default $false) -Default $false)
                    }
                }

                $quests += [PSCustomObject]@{
                    Id = [string](Get-SaveValue -Source $quest -Names @('Id') -Default '')
                    State = [string](Get-SaveValue -Source $quest -Names @('State') -Default 'NotStarted')
                    Objectives = @($objectiveRows)
                }
            }
        }
        catch {
            $quests = @()
        }
    }

    $flags = @{}
    $flagsVar = Get-Variable -Scope Script -Name QuestFlags -ErrorAction SilentlyContinue
    if ($null -ne $flagsVar -and $null -ne $flagsVar.Value -and $flagsVar.Value -is [System.Collections.IDictionary]) {
        foreach ($key in $flagsVar.Value.Keys) {
            $flags[[string]$key] = $flagsVar.Value[$key]
        }
    }

    return [PSCustomObject]@{
        Quests = @($quests)
        Flags = $flags
    }
}

function Get-SnapshotStats {
    $stats = $null
    if (Get-Command -Name Get-PlayerStats -ErrorAction SilentlyContinue) {
        try {
            $stats = Get-PlayerStats
        }
        catch {
            $stats = $null
        }
    }

    if ($null -eq $stats) {
        return [PSCustomObject]@{
            HP = [float]0.0; MaxHP = [float]0.0
            Mana = [float]0.0; MaxMana = [float]0.0
            Stamina = [float]0.0; MaxStamina = [float]0.0
            IsAlive = $true
        }
    }

    return [PSCustomObject]@{
        HP = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('HP') -Default 0.0) -Default 0.0)
        MaxHP = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('MaxHP') -Default 0.0) -Default 0.0)
        Mana = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('Mana') -Default 0.0) -Default 0.0)
        MaxMana = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('MaxMana') -Default 0.0) -Default 0.0)
        Stamina = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('Stamina') -Default 0.0) -Default 0.0)
        MaxStamina = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $stats -Names @('MaxStamina') -Default 0.0) -Default 0.0)
        IsAlive = [bool](ConvertTo-SaveBool -Value (Get-SaveValue -Source $stats -Names @('IsAlive') -Default $true) -Default $true)
    }
}

function Get-SnapshotExperience {
    [int]$xp = [int]0
    [int]$level = [int]1

    if (Get-Command -Name Get-PlayerXP -ErrorAction SilentlyContinue) {
        try {
            $xp = ConvertTo-SaveInt -Value (Get-PlayerXP) -Default 0
        }
        catch {
            $xp = [int]0
        }
    }

    if (Get-Command -Name Get-PlayerLevel -ErrorAction SilentlyContinue) {
        try {
            $level = ConvertTo-SaveInt -Value (Get-PlayerLevel) -Default 1
        }
        catch {
            $level = [int]1
        }
    }

    if ($level -lt 1) { $level = [int]1 }
    if ($xp -lt 0) { $xp = [int]0 }

    return [PSCustomObject]@{
        XP = [int]$xp
        Level = [int]$level
    }
}

function Get-SnapshotReputation {
    $factions = @()
    if (Get-Command -Name Get-ReputationFactions -ErrorAction SilentlyContinue) {
        try {
            foreach ($entry in (Expand-SaveCollection -InputObject (Get-ReputationFactions))) {
                if ($null -eq $entry) { continue }
                $factions += [PSCustomObject]@{
                    Name = [string](Get-SaveValue -Source $entry -Names @('Name') -Default '')
                    Value = [int](ConvertTo-SaveInt -Value (Get-SaveValue -Source $entry -Names @('Value') -Default 0) -Default 0)
                }
            }
        }
        catch {
            $factions = @()
        }
    }

    return [PSCustomObject]@{
        Factions = @($factions)
    }
}

function Get-SnapshotWorld {
    [int]$seed = [int]12345
    $seedVar = Get-Variable -Scope Script -Name WorldSeed -ErrorAction SilentlyContinue
    if ($null -ne $seedVar) {
        $seed = ConvertTo-SaveInt -Value $seedVar.Value -Default 12345
    }

    $chunks = @()
    $worldChunksVar = Get-Variable -Scope Script -Name WorldChunks -ErrorAction SilentlyContinue
    if ($null -ne $worldChunksVar -and $worldChunksVar.Value -is [System.Collections.IDictionary]) {
        foreach ($key in $worldChunksVar.Value.Keys) {
            $chunk = $worldChunksVar.Value[$key]
            [int]$chunkX = ConvertTo-SaveInt -Value (Get-SaveValue -Source $chunk -Names @('ChunkX') -Default ([int]::MinValue)) -Default ([int]::MinValue)
            [int]$chunkZ = ConvertTo-SaveInt -Value (Get-SaveValue -Source $chunk -Names @('ChunkZ') -Default ([int]::MinValue)) -Default ([int]::MinValue)

            if ($chunkX -eq [int]::MinValue -or $chunkZ -eq [int]::MinValue) {
                $parts = [string]$key -split ','
                if ($parts.Count -ge 2) {
                    $chunkX = ConvertTo-SaveInt -Value $parts[0] -Default 0
                    $chunkZ = ConvertTo-SaveInt -Value $parts[1] -Default 0
                }
                else {
                    $chunkX = [int]0
                    $chunkZ = [int]0
                }
            }

            [bool]$hasMesh = ($null -ne (Get-SaveValue -Source $chunk -Names @('Mesh') -Default $null))
            [int]$indexCount = ConvertTo-SaveInt -Value (Get-SaveValue -Source (Get-SaveValue -Source $chunk -Names @('Mesh') -Default $null) -Names @('IndexCount') -Default 0) -Default 0

            $chunks += [PSCustomObject]@{
                Key = [string]$key
                ChunkX = [int]$chunkX
                ChunkZ = [int]$chunkZ
                HasMesh = [bool]$hasMesh
                MeshIndexCount = [int]$indexCount
            }
        }
    }

    return [PSCustomObject]@{
        Seed = [int]$seed
        LoadedChunks = @($chunks)
    }
}

function New-SaveEnvelope {
    param([int]$Slot)

    $requiredDomains = @(
        'PlayerPosition',
        'Inventory',
        'Equipment',
        'Quests',
        'Stats',
        'Experience',
        'Reputation',
        'World'
    )

    return [PSCustomObject]@{
        Schema = [PSCustomObject]@{
            Name = 'voxel-rpg-save'
            Version = [int]$script:SaveLoadSchemaVersion
        }
        Slot = [int]$Slot
        SavedAtUtc = [datetime]::UtcNow.ToString('o')
        Data = [PSCustomObject]@{
            PlayerPosition = Get-SnapshotPlayerPosition
            Inventory = Get-SnapshotInventory
            Equipment = Get-SnapshotEquipment
            Quests = Get-SnapshotQuests
            Stats = Get-SnapshotStats
            Experience = Get-SnapshotExperience
            Reputation = Get-SnapshotReputation
            World = Get-SnapshotWorld
        }
        Validation = [PSCustomObject]@{
            RequiredDomains = @($requiredDomains)
            WorldRestoreMode = 'SeedAndChunkQueueFallback'
        }
    }
}

function Test-SaveEnvelope {
    param(
        [Parameter(Mandatory = $true)]$Envelope,
        [ref]$ValidationErrors
    )

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $Envelope) {
        $errors.Add('Save envelope is null.') | Out-Null
    }
    else {
        $schema = Get-SaveValue -Source $Envelope -Names @('Schema') -Default $null
        if ($null -eq $schema) {
            $errors.Add('Missing Schema object.') | Out-Null
        }
        else {
            [string]$schemaName = [string](Get-SaveValue -Source $schema -Names @('Name') -Default '')
            if (-not [string]::Equals($schemaName, 'voxel-rpg-save', [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add('Schema.Name must be voxel-rpg-save.') | Out-Null
            }

            [int]$schemaVersion = ConvertTo-SaveInt -Value (Get-SaveValue -Source $schema -Names @('Version') -Default 0) -Default 0
            if ($schemaVersion -ne $script:SaveLoadSchemaVersion) {
                $errors.Add("Schema.Version unsupported: $schemaVersion") | Out-Null
            }
        }

        [int]$slot = ConvertTo-SaveInt -Value (Get-SaveValue -Source $Envelope -Names @('Slot') -Default 0) -Default 0
        if ($slot -lt 1 -or $slot -gt 99) {
            $errors.Add('Slot must be in range 1..99.') | Out-Null
        }

        $data = Get-SaveValue -Source $Envelope -Names @('Data') -Default $null
        if ($null -eq $data) {
            $errors.Add('Missing Data object.') | Out-Null
        }
        else {
            $required = @('PlayerPosition', 'Inventory', 'Equipment', 'Quests', 'Stats', 'Experience', 'Reputation', 'World')
            foreach ($name in $required) {
                $value = Get-SaveValue -Source $data -Names @($name) -Default $null
                if ($null -eq $value) {
                    $errors.Add("Missing Data.$name") | Out-Null
                }
            }

            $playerPosition = Get-SaveValue -Source $data -Names @('PlayerPosition') -Default $null
            if ($null -ne $playerPosition) {
                [float]$x = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $playerPosition -Names @('X') -Default [double]::NaN) -Default ([float][double]::NaN)
                [float]$y = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $playerPosition -Names @('Y') -Default [double]::NaN) -Default ([float][double]::NaN)
                [float]$z = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $playerPosition -Names @('Z') -Default [double]::NaN) -Default ([float][double]::NaN)
                if ([float]::IsNaN($x) -or [float]::IsNaN($y) -or [float]::IsNaN($z)) {
                    $errors.Add('PlayerPosition must contain numeric X/Y/Z.') | Out-Null
                }
            }

            $experience = Get-SaveValue -Source $data -Names @('Experience') -Default $null
            if ($null -ne $experience) {
                [int]$xp = ConvertTo-SaveInt -Value (Get-SaveValue -Source $experience -Names @('XP') -Default -1) -Default -1
                [int]$level = ConvertTo-SaveInt -Value (Get-SaveValue -Source $experience -Names @('Level') -Default -1) -Default -1
                if ($xp -lt 0) { $errors.Add('Experience.XP must be >= 0.') | Out-Null }
                if ($level -lt 1) { $errors.Add('Experience.Level must be >= 1.') | Out-Null }
            }

            $world = Get-SaveValue -Source $data -Names @('World') -Default $null
            if ($null -ne $world) {
                [int]$seed = ConvertTo-SaveInt -Value (Get-SaveValue -Source $world -Names @('Seed') -Default ([int]::MinValue)) -Default ([int]::MinValue)
                if ($seed -eq [int]::MinValue) {
                    $errors.Add('World.Seed must be an integer.') | Out-Null
                }

                $loadedChunks = @(Get-SaveValue -Source $world -Names @('LoadedChunks') -Default @())
                foreach ($entry in $loadedChunks) {
                    if ($null -eq $entry) { continue }
                    [int]$cx = ConvertTo-SaveInt -Value (Get-SaveValue -Source $entry -Names @('ChunkX') -Default ([int]::MinValue)) -Default ([int]::MinValue)
                    [int]$cz = ConvertTo-SaveInt -Value (Get-SaveValue -Source $entry -Names @('ChunkZ') -Default ([int]::MinValue)) -Default ([int]::MinValue)
                    if ($cx -eq [int]::MinValue -or $cz -eq [int]::MinValue) {
                        $errors.Add('World.LoadedChunks entries must contain integer ChunkX/ChunkZ.') | Out-Null
                        break
                    }
                }
            }
        }
    }

    $ValidationErrors.Value = @($errors)
    return ($errors.Count -eq 0)
}

function Write-SaveFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Json
    )

    Ensure-SaveDirectory | Out-Null

    $tempPath = "$Path.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Json, $utf8NoBom)

    if (Test-Path -LiteralPath $Path) {
        $backupPath = "$Path.bak"
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }

        [System.IO.File]::Replace($tempPath, $Path, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
    else {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
}

function Read-SaveEnvelope {
    param([int]$Slot)

    [int]$safeSlot = Resolve-SaveSlotNumber -Slot $Slot
    $path = Get-SaveSlotPath -Slot $safeSlot
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Save slot $safeSlot not found at $path"
    }

    $json = [System.IO.File]::ReadAllText($path)
    $parsed = $json | ConvertFrom-Json

    $validationErrors = $null
    if (-not (Test-SaveEnvelope -Envelope $parsed -ValidationErrors ([ref]$validationErrors))) {
        $joined = (@($validationErrors) -join '; ')
        throw "Save validation failed for slot ${safeSlot}: $joined"
    }

    return $parsed
}

function Clear-RuntimeInventoryForLoad {
    $slotsVar = Get-Variable -Scope Script -Name InventorySlots -ErrorAction SilentlyContinue
    if ($null -eq $slotsVar -or $null -eq $slotsVar.Value) {
        return $false
    }

    $slots = @($slotsVar.Value)
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($null -eq $slots[$i]) {
            $slots[$i] = [PSCustomObject]@{ ItemName = ''; Count = [int]0 }
            continue
        }

        $slots[$i].ItemName = [string]''
        $slots[$i].Count = [int]0
    }

    return $true
}

function Restore-PlayerPosition {
    param($PlayerPosition)

    if (-not (Get-Command -Name Set-PlayerPosition -ErrorAction SilentlyContinue)) {
        return
    }

    [float]$x = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $PlayerPosition -Names @('X') -Default 0.0) -Default 0.0
    [float]$y = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $PlayerPosition -Names @('Y') -Default 0.0) -Default 0.0
    [float]$z = ConvertTo-SaveFloat -Value (Get-SaveValue -Source $PlayerPosition -Names @('Z') -Default 0.0) -Default 0.0

    Set-PlayerPosition -Position (New-Vector3 -X $x -Y $y -Z $z)
}

function Restore-Inventory {
    param($InventorySnapshot)

    $savedSlots = @(Get-SaveValue -Source $InventorySnapshot -Names @('Slots') -Default @())

    $usedDirectWrite = $false
    $slotsVar = Get-Variable -Scope Script -Name InventorySlots -ErrorAction SilentlyContinue
    if ($null -ne $slotsVar -and $null -ne $slotsVar.Value) {
        $runtimeSlots = @($slotsVar.Value)
        if ($runtimeSlots.Count -gt 0) {
            $usedDirectWrite = Clear-RuntimeInventoryForLoad

            foreach ($savedSlot in $savedSlots) {
                if ($null -eq $savedSlot) { continue }
                [int]$index = ConvertTo-SaveInt -Value (Get-SaveValue -Source $savedSlot -Names @('Index') -Default -1) -Default -1
                if ($index -lt 0 -or $index -ge $runtimeSlots.Count) { continue }

                [string]$itemName = [string](Get-SaveValue -Source $savedSlot -Names @('ItemName') -Default '')
                [int]$count = ConvertTo-SaveInt -Value (Get-SaveValue -Source $savedSlot -Names @('Count') -Default 0) -Default 0
                if ($count -lt 0) { $count = [int]0 }

                $runtimeSlots[$index].ItemName = [string]$itemName
                $runtimeSlots[$index].Count = [int]$count
            }
        }
    }

    if (-not $usedDirectWrite -and (Get-Command -Name Add-InventoryItem -ErrorAction SilentlyContinue)) {
        foreach ($savedSlot in $savedSlots) {
            if ($null -eq $savedSlot) { continue }
            [string]$itemName = [string](Get-SaveValue -Source $savedSlot -Names @('ItemName') -Default '')
            [int]$count = ConvertTo-SaveInt -Value (Get-SaveValue -Source $savedSlot -Names @('Count') -Default 0) -Default 0
            if ([string]::IsNullOrWhiteSpace($itemName) -or $count -le 0) { continue }
            Add-InventoryItem -Name $itemName -Count $count | Out-Null
        }
    }

    if (Get-Command -Name Set-HotbarSelection -ErrorAction SilentlyContinue) {
        [int]$hotbarSelection = ConvertTo-SaveInt -Value (Get-SaveValue -Source $InventorySnapshot -Names @('HotbarSelection') -Default 0) -Default 0
        Set-HotbarSelection -Index $hotbarSelection
    }
}

function Restore-Equipment {
    param($EquipmentSnapshot)

    $slots = Get-SaveValue -Source $EquipmentSnapshot -Names @('Slots') -Default @{}
    if ($null -eq $slots) { return }

    $equipmentVar = Get-Variable -Scope Script -Name EquipmentSlots -ErrorAction SilentlyContinue
    if ($null -ne $equipmentVar -and $equipmentVar.Value -is [System.Collections.IDictionary]) {
        if ($slots -is [System.Collections.IDictionary]) {
            foreach ($key in $slots.Keys) {
                $equipmentVar.Value[[string]$key] = [string]$slots[$key]
            }
        }
        else {
            foreach ($prop in $slots.PSObject.Properties) {
                $equipmentVar.Value[[string]$prop.Name] = [string]$prop.Value
            }
        }
    }
}

function Restore-Quests {
    param($QuestSnapshot)

    foreach ($questEntry in @(Get-SaveValue -Source $QuestSnapshot -Names @('Quests') -Default @())) {
        if ($null -eq $questEntry) { continue }

        [string]$questId = [string](Get-SaveValue -Source $questEntry -Names @('Id') -Default '')
        [string]$state = [string](Get-SaveValue -Source $questEntry -Names @('State') -Default 'NotStarted')
        if ([string]::IsNullOrWhiteSpace($questId)) { continue }

        if (Get-Command -Name Set-QuestState -ErrorAction SilentlyContinue) {
            try {
                Set-QuestState -Name $questId -Value $state | Out-Null
            }
            catch {
                # Keep restoring remaining fields.
            }
        }

        if (Get-Command -Name Get-Quest -ErrorAction SilentlyContinue) {
            $questObj = $null
            try {
                $questObj = Get-Quest -Quest $questId
            }
            catch {
                $questObj = $null
            }

            if ($null -ne $questObj) {
                $objectiveById = @{}
                foreach ($objective in @((Get-SaveValue -Source $questObj -Names @('Objectives') -Default @()))) {
                    if ($null -eq $objective) { continue }
                    [string]$objectiveId = [string](Get-SaveValue -Source $objective -Names @('Id') -Default '')
                    if ([string]::IsNullOrWhiteSpace($objectiveId)) { continue }
                    $objectiveById[$objectiveId] = $objective
                }

                foreach ($savedObjective in @(Get-SaveValue -Source $questEntry -Names @('Objectives') -Default @())) {
                    if ($null -eq $savedObjective) { continue }
                    [string]$objectiveId = [string](Get-SaveValue -Source $savedObjective -Names @('Id') -Default '')
                    if ([string]::IsNullOrWhiteSpace($objectiveId)) { continue }
                    if (-not $objectiveById.ContainsKey($objectiveId)) { continue }

                    $target = $objectiveById[$objectiveId]
                    [int]$current = ConvertTo-SaveInt -Value (Get-SaveValue -Source $savedObjective -Names @('CurrentCount') -Default 0) -Default 0
                    [int]$required = ConvertTo-SaveInt -Value (Get-SaveValue -Source $savedObjective -Names @('RequiredCount') -Default 1) -Default 1
                    [bool]$isCompleted = ConvertTo-SaveBool -Value (Get-SaveValue -Source $savedObjective -Names @('IsCompleted') -Default $false) -Default $false
                    if ($required -lt 1) { $required = [int]1 }
                    if ($current -lt 0) { $current = [int]0 }
                    if ($current -gt $required) { $current = [int]$required }

                    $target.CurrentCount = [int]$current
                    $target.IsCompleted = [bool]($isCompleted -or ($current -ge $required))
                }
            }
        }
    }

    $flagsMap = Get-SaveValue -Source $QuestSnapshot -Names @('Flags') -Default @{}
    $flagsMap = Get-SaveMapEntries -Map $flagsMap

    foreach ($flagKey in $flagsMap.Keys) {
        if (Get-Command -Name Set-QuestFlag -ErrorAction SilentlyContinue) {
            Set-QuestFlag -Name ([string]$flagKey) -Value $flagsMap[$flagKey] | Out-Null
        }
    }
}

function Restore-Stats {
    param($StatsSnapshot)

    $statsVar = Get-Variable -Scope Script -Name PlayerStats -ErrorAction SilentlyContinue
    if ($null -ne $statsVar -and $null -ne $statsVar.Value) {
        $statsVar.Value.MaxHP = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('MaxHP') -Default $statsVar.Value.MaxHP) -Default $statsVar.Value.MaxHP)
        $statsVar.Value.MaxMana = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('MaxMana') -Default $statsVar.Value.MaxMana) -Default $statsVar.Value.MaxMana)
        $statsVar.Value.MaxStamina = [float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('MaxStamina') -Default $statsVar.Value.MaxStamina) -Default $statsVar.Value.MaxStamina)
    }

    if (Get-Command -Name Set-PlayerHP -ErrorAction SilentlyContinue) {
        Set-PlayerHP -Amount ([float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('HP') -Default 0.0) -Default 0.0))
    }
    if (Get-Command -Name Set-PlayerMana -ErrorAction SilentlyContinue) {
        Set-PlayerMana -Amount ([float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('Mana') -Default 0.0) -Default 0.0))
    }
    if (Get-Command -Name Set-PlayerStamina -ErrorAction SilentlyContinue) {
        Set-PlayerStamina -Amount ([float](ConvertTo-SaveFloat -Value (Get-SaveValue -Source $StatsSnapshot -Names @('Stamina') -Default 0.0) -Default 0.0))
    }

    if ($null -ne $statsVar -and $null -ne $statsVar.Value) {
        $statsVar.Value.IsAlive = [bool](ConvertTo-SaveBool -Value (Get-SaveValue -Source $StatsSnapshot -Names @('IsAlive') -Default $true) -Default $true)
    }
}

function Restore-Experience {
    param($ExperienceSnapshot)

    [int]$xp = ConvertTo-SaveInt -Value (Get-SaveValue -Source $ExperienceSnapshot -Names @('XP') -Default 0) -Default 0
    [int]$level = ConvertTo-SaveInt -Value (Get-SaveValue -Source $ExperienceSnapshot -Names @('Level') -Default 1) -Default 1

    if (Get-Command -Name Set-PlayerXP -ErrorAction SilentlyContinue) {
        Set-PlayerXP -XP $xp -SuppressNotification | Out-Null
    }

    if (Get-Command -Name Set-PlayerLevel -ErrorAction SilentlyContinue) {
        $currentLevel = $null
        if (Get-Command -Name Get-PlayerLevel -ErrorAction SilentlyContinue) {
            $currentLevel = ConvertTo-SaveInt -Value (Get-PlayerLevel) -Default $level
        }

        if ($null -eq $currentLevel -or $currentLevel -ne $level) {
            Set-PlayerLevel -Level $level -SuppressNotification | Out-Null
        }
    }
}

function Restore-Reputation {
    param($ReputationSnapshot)

    if (-not (Get-Command -Name Set-Reputation -ErrorAction SilentlyContinue)) {
        return
    }

    foreach ($entry in @(Get-SaveValue -Source $ReputationSnapshot -Names @('Factions') -Default @())) {
        if ($null -eq $entry) { continue }
        [string]$name = [string](Get-SaveValue -Source $entry -Names @('Name') -Default '')
        [int]$value = ConvertTo-SaveInt -Value (Get-SaveValue -Source $entry -Names @('Value') -Default 0) -Default 0
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Set-Reputation -Value $value -Faction $name | Out-Null
    }
}

function Restore-World {
    param($WorldSnapshot)

    [int]$seed = ConvertTo-SaveInt -Value (Get-SaveValue -Source $WorldSnapshot -Names @('Seed') -Default 12345) -Default 12345
    Set-Variable -Scope Script -Name WorldSeed -Value $seed -Force

    if (Get-Command -Name Initialize-PerlinPermutation -ErrorAction SilentlyContinue) {
        try {
            Initialize-PerlinPermutation -Seed $seed
        }
        catch {
            # Keep load process alive when world systems are not active.
        }
    }

    $queueVar = Get-Variable -Scope Script -Name WorldChunkGenQueue -ErrorAction SilentlyContinue
    $chunksVar = Get-Variable -Scope Script -Name WorldChunks -ErrorAction SilentlyContinue

    if ($null -ne $queueVar -and $null -ne $queueVar.Value -and $queueVar.Value -is [System.Collections.IList]) {
        $loadedChunkRows = @(Get-SaveValue -Source $WorldSnapshot -Names @('LoadedChunks') -Default @())
        $existingChunkSet = @{}
        if ($null -ne $chunksVar -and $chunksVar.Value -is [System.Collections.IDictionary]) {
            foreach ($k in $chunksVar.Value.Keys) {
                $existingChunkSet[[string]$k] = $true
            }
        }

        foreach ($row in $loadedChunkRows) {
            if ($null -eq $row) { continue }
            [int]$chunkX = ConvertTo-SaveInt -Value (Get-SaveValue -Source $row -Names @('ChunkX') -Default 0) -Default 0
            [int]$chunkZ = ConvertTo-SaveInt -Value (Get-SaveValue -Source $row -Names @('ChunkZ') -Default 0) -Default 0
            [string]$key = "$chunkX,$chunkZ"
            if ($existingChunkSet.ContainsKey($key)) { continue }

            $alreadyQueued = $false
            foreach ($item in @($queueVar.Value)) {
                if ($null -eq $item) { continue }
                if ((ConvertTo-SaveInt -Value (Get-SaveValue -Source $item -Names @('X') -Default 0) -Default 0) -eq $chunkX -and
                    (ConvertTo-SaveInt -Value (Get-SaveValue -Source $item -Names @('Z') -Default 0) -Default 0) -eq $chunkZ) {
                    $alreadyQueued = $true
                    break
                }
            }

            if (-not $alreadyQueued) {
                $queueVar.Value.Add([PSCustomObject]@{ X = [int]$chunkX; Z = [int]$chunkZ }) | Out-Null
            }
        }
    }
}

function Save-Game {
    <#
    .SYNOPSIS
        Saves game state to a deterministic local slot JSON file.
    #>
    param([int]$Slot = 1)

    [int]$safeSlot = Resolve-SaveSlotNumber -Slot $Slot
    $envelope = New-SaveEnvelope -Slot $safeSlot

    $validationErrors = $null
    if (-not (Test-SaveEnvelope -Envelope $envelope -ValidationErrors ([ref]$validationErrors))) {
        throw ('Save envelope build failed validation: ' + (@($validationErrors) -join '; '))
    }

    $json = $envelope | ConvertTo-Json -Depth 100
    $path = Get-SaveSlotPath -Slot $safeSlot
    Write-SaveFileAtomic -Path $path -Json $json

    Write-Host "[SaveLoad] Saved slot $safeSlot -> $path" -ForegroundColor Green
    return $envelope
}

function Load-Game {
    <#
    .SYNOPSIS
        Loads and restores game state from a deterministic local slot JSON file.
    #>
    param([int]$Slot = 1)

    $envelope = Read-SaveEnvelope -Slot $Slot
    $data = Get-SaveValue -Source $envelope -Names @('Data') -Default $null

    $limitations = @()

    Restore-PlayerPosition -PlayerPosition (Get-SaveValue -Source $data -Names @('PlayerPosition') -Default $null)
    Restore-Inventory -InventorySnapshot (Get-SaveValue -Source $data -Names @('Inventory') -Default $null)
    Restore-Equipment -EquipmentSnapshot (Get-SaveValue -Source $data -Names @('Equipment') -Default $null)
    Restore-Quests -QuestSnapshot (Get-SaveValue -Source $data -Names @('Quests') -Default $null)
    Restore-Stats -StatsSnapshot (Get-SaveValue -Source $data -Names @('Stats') -Default $null)
    Restore-Experience -ExperienceSnapshot (Get-SaveValue -Source $data -Names @('Experience') -Default $null)
    Restore-Reputation -ReputationSnapshot (Get-SaveValue -Source $data -Names @('Reputation') -Default $null)
    Restore-World -WorldSnapshot (Get-SaveValue -Source $data -Names @('World') -Default $null)

    $limitations += 'World chunk voxel block data is snapshot-only; load restores world seed and re-queues known chunk coordinates when queue API is available.'

    Write-Host "[SaveLoad] Loaded slot $($envelope.Slot)" -ForegroundColor Green
    return [PSCustomObject]@{
        Slot = [int]$envelope.Slot
        SavedAtUtc = [string](Get-SaveValue -Source $envelope -Names @('SavedAtUtc') -Default '')
        Envelope = $envelope
        Limitations = @($limitations)
    }
}

function Test-SaveSlot {
    <#
    .SYNOPSIS
        Validates a slot file and returns a validation report object.
    #>
    param([int]$Slot = 1)

    try {
        $envelope = Read-SaveEnvelope -Slot $Slot
        return [PSCustomObject]@{
            Valid = $true
            Slot = [int](ConvertTo-SaveInt -Value (Get-SaveValue -Source $envelope -Names @('Slot') -Default 0) -Default 0)
            Errors = @()
        }
    }
    catch {
        return [PSCustomObject]@{
            Valid = $false
            Slot = [int]$Slot
            Errors = @($_.Exception.Message)
        }
    }
}

function Get-SaveSlots {
    <#
    .SYNOPSIS
        Lists available deterministic save slot files.
    #>

    $saveDir = Get-SaveDirectory
    if (-not (Test-Path -LiteralPath $saveDir)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $saveDir -Filter 'slot-*.json' -File | Sort-Object Name)
    $rows = @()

    foreach ($file in $files) {
        $match = [regex]::Match($file.Name, '^slot-([0-9]{2})\.json$')
        if (-not $match.Success) { continue }
        [int]$slot = ConvertTo-SaveInt -Value $match.Groups[1].Value -Default 0

        $rows += [PSCustomObject]@{
            Slot = [int]$slot
            Path = [string]$file.FullName
            LastWriteTimeUtc = [datetime]$file.LastWriteTimeUtc
            Length = [int64]$file.Length
        }
    }

    return @($rows)
}

function Register-AutoSaveOnExit {
    <#
    .SYNOPSIS
        Registers a minimal autosave hook on main form closing.
    #>
    param([int]$Slot = 1)

    [int]$safeSlot = Resolve-SaveSlotNumber -Slot $Slot
    $script:SaveLoadAutoSaveSlot = [int]$safeSlot

    if ($script:SaveLoadAutoSaveRegistered) {
        return $true
    }

    if (-not (Get-Command -Name Get-MainForm -ErrorAction SilentlyContinue)) {
        return $false
    }

    $form = $null
    try {
        $form = Get-MainForm
    }
    catch {
        $form = $null
    }

    if ($null -eq $form) {
        return $false
    }

    if ($null -eq ($form.PSObject.Members['Add_FormClosing'])) {
        return $false
    }

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        try {
            Save-Game -Slot $script:SaveLoadAutoSaveSlot | Out-Null
            Write-Host "[SaveLoad] Auto-save completed for slot $script:SaveLoadAutoSaveSlot." -ForegroundColor DarkGreen
        }
        catch {
            Write-Warning ("[SaveLoad] Auto-save failed: " + $_.Exception.Message)
        }
    })

    $script:SaveLoadAutoSaveRegistered = $true
    Write-Host "[SaveLoad] Auto-save hook registered for slot $safeSlot." -ForegroundColor DarkGreen
    return $true
}
