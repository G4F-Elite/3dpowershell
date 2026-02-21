# ============================================================================
# Data/Settings.ps1 - Settings and Options Persistence
# ============================================================================
# Provides deterministic JSON settings persistence with best-effort runtime
# application for video, controls, and audio configuration.
#
# Persistence path (default): .saves/settings.json
# Scope:
# - Video: Resolution, VSync, RenderDistance
# - Controls: KeyBindings model for core player/menu actions
# - Audio: Master/Music/Effects volume + AudioBackendAvailable flag
#
# Notes:
# - PowerShell 5.1 compatible
# - No external dependencies
# ============================================================================

$script:SettingsSchemaVersion = [int]1
$script:SettingsSchemaName = 'voxel-rpg-settings'
$script:SettingsFileRelativePath = '.saves\settings.json'
$script:SettingsFilePathOverride = $null

$script:SettingsResolutionOptions = @(
    '1024x768',
    '1280x720',
    '1366x768',
    '1600x900',
    '1920x1080'
)

$script:SettingsKeyBindingOptions = @(
    'W',
    'A',
    'S',
    'D',
    'Space',
    'ShiftKey',
    'Escape',
    'Return',
    'Up',
    'Down',
    'Left',
    'Right',
    'E',
    'F'
)

$script:SettingsDefaultKeyBindings = [ordered]@{
    MoveForward = 'W'
    MoveBackward = 'S'
    MoveLeft = 'A'
    MoveRight = 'D'
    Jump = 'Space'
    Sprint = 'ShiftKey'
    PauseMenu = 'Escape'
    MenuAccept = 'Return'
    MenuUp = 'Up'
    MenuDown = 'Down'
    MenuLeft = 'Left'
    MenuRight = 'Right'
    Inventory = 'E'
    Attack = 'F'
}

$script:SettingsInitialized = $false
$script:SettingsData = $null

$script:SettingsStatus = [ordered]@{
    PersistenceMode = 'FileBacked'
    Initialized = $false
    FilePath = ''
    FilePathRelative = ''
    FileExists = $false
    LastLoadUsedDefaults = $false
    LastLoadError = ''
    LastSaveSucceeded = $false
    LastSaveError = ''
    Runtime = [ordered]@{
        RenderDistanceApplied = $false
        RenderDistancePending = $true
        RenderDistanceValue = [int]4
        ResolutionApplied = $false
        ResolutionPending = $true
        ResolutionValue = '1024x768'
        VSyncApplied = $false
        VSyncPending = $true
        VSyncValue = $true
        AudioBackendAvailable = $false
        LastAppliedUtc = ''
    }
}

function Get-SettingsProjectRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }

    return (Get-Location).Path
}

function Get-SettingsDefaultFilePath {
    return (Join-Path (Get-SettingsProjectRoot) $script:SettingsFileRelativePath)
}

function Get-SettingsFilePath {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:SettingsFilePathOverride)) {
        return [string]$script:SettingsFilePathOverride
    }

    return (Get-SettingsDefaultFilePath)
}

function Get-SettingsFilePathRelative {
    [string]$fullPath = [System.IO.Path]::GetFullPath((Get-SettingsFilePath))
    [string]$projectRoot = [System.IO.Path]::GetFullPath((Get-SettingsProjectRoot))

    if ($fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        [string]$relative = $fullPath.Substring($projectRoot.Length)
        $relative = $relative.TrimStart([char]92, [char]47)
        if ([string]::IsNullOrWhiteSpace($relative)) {
            return '.'
        }

        return ($relative -replace '/', '\\')
    }

    return $fullPath
}

function Ensure-SettingsDirectory {
    [string]$filePath = Get-SettingsFilePath
    [string]$parentPath = Split-Path -Parent $filePath

    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    }
}

function ConvertTo-SettingsInt {
    param($Value, [int]$Default = 0)

    try {
        return [int]$Value
    }
    catch {
        return [int]$Default
    }
}

function ConvertTo-SettingsBool {
    param($Value, [bool]$Default = $false)

    try {
        return [bool]$Value
    }
    catch {
        return [bool]$Default
    }
}

function Get-SettingsValue {
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
            if ($Source.Contains($name)) {
                return $Source[$name]
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

function Get-SettingsResolutionOptions {
    return @($script:SettingsResolutionOptions)
}

function Get-SettingsKeyBindingOptions {
    return @($script:SettingsKeyBindingOptions)
}

function Get-SettingsKeyBindingActions {
    return @($script:SettingsDefaultKeyBindings.Keys)
}

function Test-SettingsAudioBackendAvailable {
    foreach ($candidate in @('Invoke-GameSoundCue', 'Invoke-AudioCue', 'Play-Sound')) {
        if (Get-Command -Name $candidate -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    return $false
}

function Resolve-SettingsResolution {
    param(
        [string]$Value,
        [string]$Default = '1024x768'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [string]$Default
    }

    foreach ($candidate in @($script:SettingsResolutionOptions)) {
        if ([string]::Equals([string]$candidate, [string]$Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$candidate
        }
    }

    return [string]$Default
}

function Resolve-SettingsKeyBinding {
    param(
        [string]$Value,
        [string]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [string]$Default
    }

    foreach ($candidate in @($script:SettingsKeyBindingOptions)) {
        if ([string]::Equals([string]$candidate, [string]$Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$candidate
        }
    }

    return [string]$Default
}

function Resolve-SettingsRenderDistance {
    param($Value)

    [int]$renderDistance = ConvertTo-SettingsInt -Value $Value -Default 4
    if ($renderDistance -lt 2) { $renderDistance = [int]2 }
    if ($renderDistance -gt 8) { $renderDistance = [int]8 }
    return [int]$renderDistance
}

function Resolve-SettingsVolume {
    param($Value, [int]$Default)

    [int]$volume = ConvertTo-SettingsInt -Value $Value -Default $Default
    if ($volume -lt 0) { $volume = [int]0 }
    if ($volume -gt 100) { $volume = [int]100 }
    return [int]$volume
}

function New-SettingsDefaultData {
    $bindings = [ordered]@{}
    foreach ($action in @($script:SettingsDefaultKeyBindings.Keys)) {
        $bindings[[string]$action] = [string]$script:SettingsDefaultKeyBindings[$action]
    }

    return [ordered]@{
        Video = [ordered]@{
            Resolution = '1024x768'
            VSync = $true
            RenderDistance = [int]4
        }
        Controls = [ordered]@{
            KeyBindings = $bindings
        }
        Audio = [ordered]@{
            MasterVolume = [int]85
            MusicVolume = [int]70
            EffectsVolume = [int]80
            AudioBackendAvailable = [bool](Test-SettingsAudioBackendAvailable)
        }
    }
}

function Resolve-SettingsData {
    param($Source)

    $defaults = New-SettingsDefaultData

    $videoSource = Get-SettingsValue -Source $Source -Names @('Video') -Default $null
    $controlsSource = Get-SettingsValue -Source $Source -Names @('Controls') -Default $null
    $audioSource = Get-SettingsValue -Source $Source -Names @('Audio') -Default $null

    $resolvedBindings = [ordered]@{}
    $keyBindingSource = Get-SettingsValue -Source $controlsSource -Names @('KeyBindings', 'Bindings') -Default $null

    foreach ($action in @($script:SettingsDefaultKeyBindings.Keys)) {
        [string]$defaultBinding = [string]$defaults.Controls.KeyBindings[$action]
        $rawBinding = Get-SettingsValue -Source $keyBindingSource -Names @($action) -Default $null
        if ($null -eq $rawBinding) {
            $rawBinding = Get-SettingsValue -Source $controlsSource -Names @($action) -Default $defaultBinding
        }

        $resolvedBindings[[string]$action] = Resolve-SettingsKeyBinding -Value ([string]$rawBinding) -Default $defaultBinding
    }

    [bool]$audioBackendDetected = Test-SettingsAudioBackendAvailable
    [bool]$audioBackendValue = ConvertTo-SettingsBool -Value (Get-SettingsValue -Source $audioSource -Names @('AudioBackendAvailable') -Default $audioBackendDetected) -Default $audioBackendDetected
    if ($audioBackendDetected) {
        $audioBackendValue = $true
    }

    return [ordered]@{
        Video = [ordered]@{
            Resolution = Resolve-SettingsResolution -Value ([string](Get-SettingsValue -Source $videoSource -Names @('Resolution') -Default $defaults.Video.Resolution)) -Default $defaults.Video.Resolution
            VSync = [bool](ConvertTo-SettingsBool -Value (Get-SettingsValue -Source $videoSource -Names @('VSync') -Default $defaults.Video.VSync) -Default $defaults.Video.VSync)
            RenderDistance = [int](Resolve-SettingsRenderDistance -Value (Get-SettingsValue -Source $videoSource -Names @('RenderDistance') -Default $defaults.Video.RenderDistance))
        }
        Controls = [ordered]@{
            KeyBindings = $resolvedBindings
        }
        Audio = [ordered]@{
            MasterVolume = [int](Resolve-SettingsVolume -Value (Get-SettingsValue -Source $audioSource -Names @('MasterVolume') -Default $defaults.Audio.MasterVolume) -Default $defaults.Audio.MasterVolume)
            MusicVolume = [int](Resolve-SettingsVolume -Value (Get-SettingsValue -Source $audioSource -Names @('MusicVolume') -Default $defaults.Audio.MusicVolume) -Default $defaults.Audio.MusicVolume)
            EffectsVolume = [int](Resolve-SettingsVolume -Value (Get-SettingsValue -Source $audioSource -Names @('EffectsVolume') -Default $defaults.Audio.EffectsVolume) -Default $defaults.Audio.EffectsVolume)
            AudioBackendAvailable = [bool]$audioBackendValue
        }
    }
}

function Copy-SettingsData {
    param($Data)
    return (Resolve-SettingsData -Source $Data)
}

function New-SettingsEnvelope {
    param($Data)

    $resolved = Resolve-SettingsData -Source $Data

    return [ordered]@{
        Schema = [ordered]@{
            Name = [string]$script:SettingsSchemaName
            Version = [int]$script:SettingsSchemaVersion
        }
        UpdatedAtUtc = [datetime]::UtcNow.ToString('o')
        Data = $resolved
    }
}

function Test-SettingsEnvelope {
    param(
        [Parameter(Mandatory = $true)]$Envelope,
        [ref]$ValidationErrors
    )

    $errors = [System.Collections.ArrayList]::new()
    if ($null -eq $Envelope) {
        $errors.Add('Envelope is null.') | Out-Null
    }
    else {
        $schema = Get-SettingsValue -Source $Envelope -Names @('Schema') -Default $null
        [string]$schemaName = [string](Get-SettingsValue -Source $schema -Names @('Name') -Default '')
        [int]$schemaVersion = ConvertTo-SettingsInt -Value (Get-SettingsValue -Source $schema -Names @('Version') -Default 0) -Default 0

        if (-not [string]::Equals($schemaName, [string]$script:SettingsSchemaName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Schema.Name mismatch.') | Out-Null
        }

        if ($schemaVersion -ne $script:SettingsSchemaVersion) {
            $errors.Add('Schema.Version mismatch.') | Out-Null
        }

        $payload = Get-SettingsValue -Source $Envelope -Names @('Data') -Default $null
        if ($null -eq $payload) {
            $errors.Add('Missing Data payload.') | Out-Null
        }
    }

    $ValidationErrors.Value = @($errors)
    return ($errors.Count -eq 0)
}

function Write-SettingsFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Json
    )

    Ensure-SettingsDirectory

    [string]$tempPath = "$Path.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Json, $utf8NoBom)

    if (Test-Path -LiteralPath $Path) {
        [string]$backupPath = "$Path.bak"
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

function Read-SettingsFromDisk {
    [string]$path = Get-SettingsFilePath
    [bool]$usedDefaults = $false
    [string]$loadError = ''
    $resolvedData = $null

    if (-not (Test-Path -LiteralPath $path)) {
        $usedDefaults = $true
        $loadError = 'Settings file missing. Defaults loaded.'
        $resolvedData = New-SettingsDefaultData
    }
    else {
        try {
            [string]$json = [System.IO.File]::ReadAllText($path)
            $parsed = $json | ConvertFrom-Json

            $validationErrors = $null
            if (-not (Test-SettingsEnvelope -Envelope $parsed -ValidationErrors ([ref]$validationErrors))) {
                throw ('Settings validation failed: ' + (@($validationErrors) -join '; '))
            }

            $payload = Get-SettingsValue -Source $parsed -Names @('Data') -Default $null
            $resolvedData = Resolve-SettingsData -Source $payload
        }
        catch {
            $usedDefaults = $true
            $loadError = [string]$_.Exception.Message
            $resolvedData = New-SettingsDefaultData
        }
    }

    return [PSCustomObject]@{
        Path = [string]$path
        UsedDefaults = [bool]$usedDefaults
        LoadError = [string]$loadError
        Data = $resolvedData
    }
}

function Parse-ResolutionSetting {
    param([string]$Resolution)

    if ([string]::IsNullOrWhiteSpace($Resolution)) {
        return $null
    }

    $match = [regex]::Match([string]$Resolution, '^\s*([0-9]{3,5})x([0-9]{3,5})\s*$')
    if (-not $match.Success) {
        return $null
    }

    [int]$width = ConvertTo-SettingsInt -Value $match.Groups[1].Value -Default 0
    [int]$height = ConvertTo-SettingsInt -Value $match.Groups[2].Value -Default 0
    if ($width -lt 640 -or $height -lt 480) {
        return $null
    }

    return [PSCustomObject]@{
        Width = [int]$width
        Height = [int]$height
    }
}

function Set-SettingsStoragePathOverride {
    <#
    .SYNOPSIS
        Overrides settings file location (useful for isolated smoke tests).
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        $script:SettingsFilePathOverride = $null
    }
    else {
        $script:SettingsFilePathOverride = [string]$Path
    }

    $script:SettingsInitialized = $false
    $script:SettingsStatus.Initialized = $false
    $script:SettingsStatus.FileExists = $false
    $script:SettingsStatus.LastLoadError = ''
    $script:SettingsStatus.LastSaveError = ''

    return (Get-SettingsFilePath)
}

function Ensure-SettingsInitialized {
    if (-not $script:SettingsInitialized -or $null -eq $script:SettingsData) {
        Initialize-Settings | Out-Null
    }
}

function Save-Settings {
    <#
    .SYNOPSIS
        Saves current settings to deterministic JSON file.
    #>
    Ensure-SettingsInitialized

    [string]$path = Get-SettingsFilePath
    $envelope = New-SettingsEnvelope -Data $script:SettingsData
    [string]$json = ($envelope | ConvertTo-Json -Depth 25)

    try {
        Write-SettingsFileAtomic -Path $path -Json $json
        $script:SettingsStatus.LastSaveSucceeded = $true
        $script:SettingsStatus.LastSaveError = ''
        $script:SettingsStatus.FileExists = (Test-Path -LiteralPath $path)
    }
    catch {
        $script:SettingsStatus.LastSaveSucceeded = $false
        $script:SettingsStatus.LastSaveError = [string]$_.Exception.Message
        throw
    }

    return (Get-SettingsStatus)
}

function Load-Settings {
    <#
    .SYNOPSIS
        Loads settings from deterministic JSON file, with defaults fallback.
    #>
    param([switch]$ApplyRuntime)

    $result = Read-SettingsFromDisk
    $script:SettingsData = Copy-SettingsData -Data $result.Data
    $script:SettingsInitialized = $true

    [string]$filePath = Get-SettingsFilePath
    $script:SettingsStatus.Initialized = $true
    $script:SettingsStatus.FilePath = [string]$filePath
    $script:SettingsStatus.FilePathRelative = [string](Get-SettingsFilePathRelative)
    $script:SettingsStatus.FileExists = (Test-Path -LiteralPath $filePath)
    $script:SettingsStatus.LastLoadUsedDefaults = [bool]$result.UsedDefaults
    $script:SettingsStatus.LastLoadError = [string]$result.LoadError

    if ($result.UsedDefaults) {
        try {
            Save-Settings | Out-Null
        }
        catch {
            # Keep loaded defaults even if immediate persistence fails.
        }
    }

    if ($ApplyRuntime) {
        Apply-SettingsRuntime | Out-Null
    }

    return (Get-Settings)
}

function Initialize-Settings {
    <#
    .SYNOPSIS
        Initializes settings system and loads from disk.
    #>
    param([switch]$ApplyRuntime)

    if ($script:SettingsInitialized -and $null -ne $script:SettingsData) {
        if ($ApplyRuntime) {
            Apply-SettingsRuntime | Out-Null
        }

        return (Get-SettingsStatus)
    }

    Load-Settings -ApplyRuntime:$ApplyRuntime | Out-Null
    return (Get-SettingsStatus)
}

function Get-Settings {
    <#
    .SYNOPSIS
        Returns a safe copy of the current settings data.
    #>
    Ensure-SettingsInitialized
    return (Copy-SettingsData -Data $script:SettingsData)
}

function Get-SettingsStatus {
    <#
    .SYNOPSIS
        Returns persistence and runtime-application status.
    #>
    [string]$filePath = Get-SettingsFilePath

    $script:SettingsStatus.FilePath = [string]$filePath
    $script:SettingsStatus.FilePathRelative = [string](Get-SettingsFilePathRelative)
    $script:SettingsStatus.FileExists = (Test-Path -LiteralPath $filePath)
    $script:SettingsStatus.Initialized = [bool]$script:SettingsInitialized

    return [PSCustomObject]@{
        PersistenceMode = [string]$script:SettingsStatus.PersistenceMode
        Initialized = [bool]$script:SettingsStatus.Initialized
        FilePath = [string]$script:SettingsStatus.FilePath
        FilePathRelative = [string]$script:SettingsStatus.FilePathRelative
        FileExists = [bool]$script:SettingsStatus.FileExists
        LastLoadUsedDefaults = [bool]$script:SettingsStatus.LastLoadUsedDefaults
        LastLoadError = [string]$script:SettingsStatus.LastLoadError
        LastSaveSucceeded = [bool]$script:SettingsStatus.LastSaveSucceeded
        LastSaveError = [string]$script:SettingsStatus.LastSaveError
        Runtime = [PSCustomObject]@{
            RenderDistanceApplied = [bool]$script:SettingsStatus.Runtime.RenderDistanceApplied
            RenderDistancePending = [bool]$script:SettingsStatus.Runtime.RenderDistancePending
            RenderDistanceValue = [int]$script:SettingsStatus.Runtime.RenderDistanceValue
            ResolutionApplied = [bool]$script:SettingsStatus.Runtime.ResolutionApplied
            ResolutionPending = [bool]$script:SettingsStatus.Runtime.ResolutionPending
            ResolutionValue = [string]$script:SettingsStatus.Runtime.ResolutionValue
            VSyncApplied = [bool]$script:SettingsStatus.Runtime.VSyncApplied
            VSyncPending = [bool]$script:SettingsStatus.Runtime.VSyncPending
            VSyncValue = [bool]$script:SettingsStatus.Runtime.VSyncValue
            AudioBackendAvailable = [bool]$script:SettingsStatus.Runtime.AudioBackendAvailable
            LastAppliedUtc = [string]$script:SettingsStatus.Runtime.LastAppliedUtc
        }
    }
}

function Get-SettingsPersistenceToken {
    $status = Get-SettingsStatus
    if ([bool]$status.Initialized) {
        return ('FileBacked:{0}' -f [string]$status.FilePathRelative)
    }

    return ('FileBackedPending:{0}' -f [string]$status.FilePathRelative)
}

function Get-SettingValue {
    <#
    .SYNOPSIS
        Returns a single setting value by category and name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    Ensure-SettingsInitialized
    [string]$categoryKey = [string]$Category
    [string]$nameKey = [string]$Name

    switch ($categoryKey) {
        'Video' {
            if ($script:SettingsData.Video.Contains($nameKey)) {
                return $script:SettingsData.Video[$nameKey]
            }
        }
        'Audio' {
            if ($script:SettingsData.Audio.Contains($nameKey)) {
                return $script:SettingsData.Audio[$nameKey]
            }
        }
        'Controls' {
            if ([string]::Equals($nameKey, 'KeyBindings', [System.StringComparison]::OrdinalIgnoreCase)) {
                $copy = [ordered]@{}
                foreach ($action in @($script:SettingsData.Controls.KeyBindings.Keys)) {
                    $copy[[string]$action] = [string]$script:SettingsData.Controls.KeyBindings[$action]
                }
                return $copy
            }

            if ($script:SettingsData.Controls.KeyBindings.Contains($nameKey)) {
                return [string]$script:SettingsData.Controls.KeyBindings[$nameKey]
            }
        }
    }

    return $Default
}

function Set-SettingValue {
    <#
    .SYNOPSIS
        Sets one setting value with normalization and optional save/apply.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [switch]$Save,
        [switch]$ApplyRuntime
    )

    Ensure-SettingsInitialized

    [string]$categoryKey = [string]$Category
    [string]$nameKey = [string]$Name
    $normalized = $null

    switch ($categoryKey) {
        'Video' {
            switch ($nameKey) {
                'Resolution' {
                    $normalized = Resolve-SettingsResolution -Value ([string]$Value) -Default $script:SettingsData.Video.Resolution
                    $script:SettingsData.Video['Resolution'] = [string]$normalized
                }
                'VSync' {
                    $normalized = [bool](ConvertTo-SettingsBool -Value $Value -Default $script:SettingsData.Video.VSync)
                    $script:SettingsData.Video['VSync'] = [bool]$normalized
                }
                'RenderDistance' {
                    $normalized = [int](Resolve-SettingsRenderDistance -Value $Value)
                    $script:SettingsData.Video['RenderDistance'] = [int]$normalized
                }
                default {
                    throw "Unknown Video setting: $nameKey"
                }
            }
        }
        'Audio' {
            switch ($nameKey) {
                'MasterVolume' {
                    $normalized = [int](Resolve-SettingsVolume -Value $Value -Default $script:SettingsData.Audio.MasterVolume)
                    $script:SettingsData.Audio['MasterVolume'] = [int]$normalized
                }
                'MusicVolume' {
                    $normalized = [int](Resolve-SettingsVolume -Value $Value -Default $script:SettingsData.Audio.MusicVolume)
                    $script:SettingsData.Audio['MusicVolume'] = [int]$normalized
                }
                'EffectsVolume' {
                    $normalized = [int](Resolve-SettingsVolume -Value $Value -Default $script:SettingsData.Audio.EffectsVolume)
                    $script:SettingsData.Audio['EffectsVolume'] = [int]$normalized
                }
                'AudioBackendAvailable' {
                    $normalized = [bool](ConvertTo-SettingsBool -Value $Value -Default $script:SettingsData.Audio.AudioBackendAvailable)
                    $script:SettingsData.Audio['AudioBackendAvailable'] = [bool]$normalized
                }
                default {
                    throw "Unknown Audio setting: $nameKey"
                }
            }
        }
        'Controls' {
            if ($script:SettingsData.Controls.KeyBindings.Contains($nameKey)) {
                [string]$defaultBinding = [string]$script:SettingsData.Controls.KeyBindings[$nameKey]
                $normalized = Resolve-SettingsKeyBinding -Value ([string]$Value) -Default $defaultBinding
                $script:SettingsData.Controls.KeyBindings[$nameKey] = [string]$normalized
            }
            else {
                throw "Unknown Controls key binding: $nameKey"
            }
        }
        default {
            throw "Unknown settings category: $categoryKey"
        }
    }

    [bool]$saved = $false
    if ($Save) {
        Save-Settings | Out-Null
        $saved = $true
    }

    [bool]$applied = $false
    if ($ApplyRuntime) {
        Apply-SettingsRuntime | Out-Null
        $applied = $true
    }

    return [PSCustomObject]@{
        Category = [string]$categoryKey
        Name = [string]$nameKey
        Value = $normalized
        Saved = [bool]$saved
        Applied = [bool]$applied
    }
}

function Set-KeyBinding {
    <#
    .SYNOPSIS
        Convenience wrapper for controls key binding updates.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$Save
    )

    return (Set-SettingValue -Category 'Controls' -Name $Action -Value $Key -Save:$Save)
}

function Get-KeyBinding {
    <#
    .SYNOPSIS
        Returns a persisted key binding for one action.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Default = ''
    )

    return [string](Get-SettingValue -Category 'Controls' -Name $Action -Default $Default)
}

function Get-KeyBindings {
    <#
    .SYNOPSIS
        Returns a copy of persisted control key bindings.
    #>
    $bindings = Get-SettingValue -Category 'Controls' -Name 'KeyBindings' -Default @{}
    $copy = [ordered]@{}
    foreach ($key in @($bindings.Keys)) {
        $copy[[string]$key] = [string]$bindings[$key]
    }

    return $copy
}

function Resolve-SettingsKeyTarget {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace([string]$Key)) {
        return $null
    }

    [string]$normalized = [string]$Key

    switch -Regex ($normalized) {
        '^RenderDistance$' { return [PSCustomObject]@{ Category = 'Video'; Name = 'RenderDistance' } }
        '^Resolution$' { return [PSCustomObject]@{ Category = 'Video'; Name = 'Resolution' } }
        '^VSync$' { return [PSCustomObject]@{ Category = 'Video'; Name = 'VSync' } }
        '^MasterVolume$' { return [PSCustomObject]@{ Category = 'Audio'; Name = 'MasterVolume' } }
        '^MusicVolume$' { return [PSCustomObject]@{ Category = 'Audio'; Name = 'MusicVolume' } }
        '^EffectsVolume$' { return [PSCustomObject]@{ Category = 'Audio'; Name = 'EffectsVolume' } }
        '^KeyBinding\.(.+)$' {
            [string]$action = [string]$Matches[1]
            if ($script:SettingsDefaultKeyBindings.Contains($action)) {
                return [PSCustomObject]@{ Category = 'Controls'; Name = $action }
            }

            return $null
        }
        default {
            if ($script:SettingsDefaultKeyBindings.Contains($normalized)) {
                return [PSCustomObject]@{ Category = 'Controls'; Name = $normalized }
            }
        }
    }

    return $null
}

function Get-Setting {
    <#
    .SYNOPSIS
        Compatibility accessor by canonical setting key.
    .DESCRIPTION
        Supported keys include RenderDistance, Resolution, VSync,
        MasterVolume, MusicVolume, EffectsVolume, and key bindings via
        KeyBinding.<Action> or direct action name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        $Default = $null
    )

    $target = Resolve-SettingsKeyTarget -Key $Key
    if ($null -eq $target) {
        return $Default
    }

    return (Get-SettingValue -Category ([string]$target.Category) -Name ([string]$target.Name) -Default $Default)
}

function Set-Setting {
    <#
    .SYNOPSIS
        Compatibility mutator by canonical setting key.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Value,
        [switch]$Save,
        [switch]$ApplyRuntime
    )

    $target = Resolve-SettingsKeyTarget -Key $Key
    if ($null -eq $target) {
        throw "Unknown setting key: $Key"
    }

    return (Set-SettingValue -Category ([string]$target.Category) -Name ([string]$target.Name) -Value $Value -Save:$Save -ApplyRuntime:$ApplyRuntime)
}

function Apply-SettingsRuntime {
    <#
    .SYNOPSIS
        Best-effort runtime application for video and audio-related settings.
    #>
    Ensure-SettingsInitialized

    [int]$renderDistance = [int](Resolve-SettingsRenderDistance -Value $script:SettingsData.Video.RenderDistance)
    [string]$resolution = [string](Resolve-SettingsResolution -Value $script:SettingsData.Video.Resolution -Default '1024x768')
    [bool]$vsync = [bool](ConvertTo-SettingsBool -Value $script:SettingsData.Video.VSync -Default $true)
    [bool]$audioBackendAvailable = [bool](Test-SettingsAudioBackendAvailable)

    [bool]$renderDistanceApplied = $false
    [bool]$resolutionApplied = $false
    [bool]$vsyncApplied = $false

    $worldDistanceVariable = Get-Variable -Scope Script -Name WorldViewDistance -ErrorAction SilentlyContinue
    if ($null -ne $worldDistanceVariable) {
        try {
            Set-Variable -Scope Script -Name WorldViewDistance -Value ([int]$renderDistance) -Force
            $renderDistanceApplied = $true
        }
        catch {
            $renderDistanceApplied = $false
        }
    }

    $resolutionParsed = Parse-ResolutionSetting -Resolution $resolution
    if ($null -ne $resolutionParsed -and (Get-Command -Name Get-MainForm -ErrorAction SilentlyContinue)) {
        try {
            $mainForm = Get-MainForm
            if ($null -ne $mainForm -and $null -ne $mainForm.PSObject.Properties['Width'] -and $null -ne $mainForm.PSObject.Properties['Height']) {
                $mainForm.Width = [int]$resolutionParsed.Width
                $mainForm.Height = [int]$resolutionParsed.Height
                $resolutionApplied = $true
            }
        }
        catch {
            $resolutionApplied = $false
        }
    }

    if (Get-Command -Name Get-GlControl -ErrorAction SilentlyContinue) {
        try {
            $glControl = Get-GlControl
            if ($null -ne $glControl -and $null -ne $glControl.PSObject.Properties['SwapInterval']) {
                $glControl.SwapInterval = if ($vsync) { 1 } else { 0 }
                $vsyncApplied = $true
            }
        }
        catch {
            $vsyncApplied = $false
        }
    }

    $script:SettingsData.Video.RenderDistance = [int]$renderDistance
    $script:SettingsData.Video.Resolution = [string]$resolution
    $script:SettingsData.Video.VSync = [bool]$vsync
    $script:SettingsData.Audio.AudioBackendAvailable = [bool]$audioBackendAvailable

    $script:SettingsStatus.Runtime.RenderDistanceApplied = [bool]$renderDistanceApplied
    $script:SettingsStatus.Runtime.RenderDistancePending = -not [bool]$renderDistanceApplied
    $script:SettingsStatus.Runtime.RenderDistanceValue = [int]$renderDistance
    $script:SettingsStatus.Runtime.ResolutionApplied = [bool]$resolutionApplied
    $script:SettingsStatus.Runtime.ResolutionPending = -not [bool]$resolutionApplied
    $script:SettingsStatus.Runtime.ResolutionValue = [string]$resolution
    $script:SettingsStatus.Runtime.VSyncApplied = [bool]$vsyncApplied
    $script:SettingsStatus.Runtime.VSyncPending = -not [bool]$vsyncApplied
    $script:SettingsStatus.Runtime.VSyncValue = [bool]$vsync
    $script:SettingsStatus.Runtime.AudioBackendAvailable = [bool]$audioBackendAvailable
    $script:SettingsStatus.Runtime.LastAppliedUtc = [datetime]::UtcNow.ToString('o')

    return [PSCustomObject]@{
        RenderDistanceApplied = [bool]$script:SettingsStatus.Runtime.RenderDistanceApplied
        RenderDistancePending = [bool]$script:SettingsStatus.Runtime.RenderDistancePending
        RenderDistanceValue = [int]$script:SettingsStatus.Runtime.RenderDistanceValue
        ResolutionApplied = [bool]$script:SettingsStatus.Runtime.ResolutionApplied
        ResolutionPending = [bool]$script:SettingsStatus.Runtime.ResolutionPending
        ResolutionValue = [string]$script:SettingsStatus.Runtime.ResolutionValue
        VSyncApplied = [bool]$script:SettingsStatus.Runtime.VSyncApplied
        VSyncPending = [bool]$script:SettingsStatus.Runtime.VSyncPending
        VSyncValue = [bool]$script:SettingsStatus.Runtime.VSyncValue
        AudioBackendAvailable = [bool]$script:SettingsStatus.Runtime.AudioBackendAvailable
        LastAppliedUtc = [string]$script:SettingsStatus.Runtime.LastAppliedUtc
    }
}
