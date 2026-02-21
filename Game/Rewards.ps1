# ============================================================================
# Game/Rewards.ps1 - Quest Reward Payloads and Delivery
# ============================================================================
# Provides deterministic reward helpers for quest completion:
# - Reward payload creation and normalization
# - Reward delivery for Items, XP, Gold, and Reputation
# - Optional choice reward selection (pick one item from choices)
# - Quest completion reward hooks/helpers
#
# Integration hooks (optional):
# - Inventory: Add-InventoryItem
# - Experience: Add-PlayerXP / Add-XP / Add-Experience / Add-PlayerExperience
# - Gold: Add-PlayerGold / Add-Gold / Add-PlayerCurrency
# - Reputation: Add-Reputation
#
# This module is logic-only and includes graceful context fallback when optional
# modules are absent.
# ============================================================================

# --- Module State ---
$script:RewardSystemInitialized = $false
$script:RewardFallbackState = $null

# ============================================================================
# Internal Helpers - Core Utilities
# ============================================================================

function Initialize-RewardSystem {
    <#
    .SYNOPSIS
        Initializes reward fallback state.
    #>
    param([switch]$Quiet)

    $script:RewardSystemInitialized = $true
    $script:RewardFallbackState = [PSCustomObject]@{
        XP         = [int]0
        Gold       = [int]0
        Items      = @{}
        Reputation = @{}
    }

    if (-not $Quiet) {
        Write-Host '[Rewards] Reward system initialized.' -ForegroundColor Green
    }

    return $script:RewardFallbackState
}

function Ensure-RewardSystem {
    if (-not $script:RewardSystemInitialized -or $null -eq $script:RewardFallbackState) {
        Initialize-RewardSystem -Quiet | Out-Null
    }
}

function Get-RewardValue {
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
            foreach ($key in $Source.Keys) {
                if ([string]::Equals([string]$key, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Source[$key]
                }
            }
        }
        else {
            foreach ($prop in $Source.PSObject.Properties) {
                if ([string]::Equals([string]$prop.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $prop.Value
                }
            }
        }
    }

    return $Default
}

function Set-RewardObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $existingKey = Find-RewardDictionaryKey -Dictionary $Object -Name $Name
        if ($null -eq $existingKey) {
            $Object[$Name] = $Value
        }
        else {
            $Object[$existingKey] = $Value
        }
        return
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function ConvertTo-RewardInt {
    param(
        $Value,
        [int]$Default = 0
    )

    if ($null -eq $Value) {
        return [int]$Default
    }

    try {
        return [int]$Value
    }
    catch {
        return [int]$Default
    }
}

function ConvertTo-RewardBool {
    param($Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $false
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    switch ($text.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        default { return $false }
    }
}

function Find-RewardDictionaryKey {
    param(
        [System.Collections.IDictionary]$Dictionary,
        [string]$Name
    )

    if ($null -eq $Dictionary -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    foreach ($key in $Dictionary.Keys) {
        if ([string]::Equals([string]$key, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $key
        }
    }

    return $null
}

function Get-RewardDictionaryValue {
    param(
        [System.Collections.IDictionary]$Dictionary,
        [string]$Key,
        $Default = $null
    )

    if ($null -eq $Dictionary) {
        return $Default
    }

    $existingKey = Find-RewardDictionaryKey -Dictionary $Dictionary -Name $Key
    if ($null -eq $existingKey) {
        return $Default
    }

    return $Dictionary[$existingKey]
}

function Set-RewardDictionaryValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Dictionary,
        [Parameter(Mandatory = $true)][string]$Key,
        $Value
    )

    $existingKey = Find-RewardDictionaryKey -Dictionary $Dictionary -Name $Key
    if ($null -eq $existingKey) {
        $Dictionary[$Key] = $Value
    }
    else {
        $Dictionary[$existingKey] = $Value
    }

    return $Value
}

function Resolve-RewardContext {
    param($Context)

    Ensure-RewardSystem

    if ($null -eq $Context) {
        return $script:RewardFallbackState
    }

    return $Context
}

function Ensure-RewardContextMap {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($Context -is [System.Collections.IDictionary]) {
        $existing = Get-RewardDictionaryValue -Dictionary $Context -Key $PropertyName
        if ($existing -is [System.Collections.IDictionary]) {
            return $existing
        }

        $newMap = @{}
        Set-RewardDictionaryValue -Dictionary $Context -Key $PropertyName -Value $newMap | Out-Null
        return $newMap
    }

    $existingObjectValue = Get-RewardValue -Source $Context -Names @($PropertyName)
    if ($existingObjectValue -is [System.Collections.IDictionary]) {
        return $existingObjectValue
    }

    $newObjectMap = @{}
    Set-RewardObjectProperty -Object $Context -Name $PropertyName -Value $newObjectMap
    return $newObjectMap
}

function Add-RewardContextNumeric {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][int]$Amount
    )

    if ($Context -is [System.Collections.IDictionary]) {
        [int]$current = ConvertTo-RewardInt -Value (Get-RewardDictionaryValue -Dictionary $Context -Key $PropertyName -Default 0)
        [int]$next = [int]($current + $Amount)
        Set-RewardDictionaryValue -Dictionary $Context -Key $PropertyName -Value $next | Out-Null
        return $next
    }

    [int]$currentObject = ConvertTo-RewardInt -Value (Get-RewardValue -Source $Context -Names @($PropertyName) -Default 0)
    [int]$nextObject = [int]($currentObject + $Amount)
    Set-RewardObjectProperty -Object $Context -Name $PropertyName -Value $nextObject
    return $nextObject
}

function Add-RewardContextMapCount {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$EntryKey,
        [Parameter(Mandatory = $true)][int]$Amount
    )

    $map = Ensure-RewardContextMap -Context $Context -PropertyName $PropertyName
    [int]$current = ConvertTo-RewardInt -Value (Get-RewardDictionaryValue -Dictionary $map -Key $EntryKey -Default 0)
    [int]$next = [int]($current + $Amount)
    Set-RewardDictionaryValue -Dictionary $map -Key $EntryKey -Value $next | Out-Null
    return $next
}

# ============================================================================
# Internal Helpers - Reward Normalization
# ============================================================================

function ConvertTo-RewardItem {
    param($Item)

    if ($null -eq $Item) {
        return $null
    }

    [string]$name = ''
    [int]$count = [int]1

    if ($Item -is [string]) {
        $name = $Item.Trim()
    }
    else {
        $name = [string](Get-RewardValue -Source $Item -Names @('Name', 'Item', 'ItemName', 'Id') -Default '')
        $count = ConvertTo-RewardInt -Value (Get-RewardValue -Source $Item -Names @('Count', 'Amount', 'Quantity', 'Value') -Default 1) -Default 1
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    if ($count -lt 1) {
        $count = [int]1
    }

    return [PSCustomObject]@{
        Name  = [string]$name
        Count = [int]$count
    }
}

function ConvertTo-RewardItemArray {
    param($Items)

    $result = @()
    if ($null -eq $Items) {
        return ,$result
    }

    $sourceItems = @()
    if ($Items -is [System.Collections.IDictionary]) {
        $hasNamedShape =
            $null -ne (Find-RewardDictionaryKey -Dictionary $Items -Name 'Name') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Items -Name 'Item') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Items -Name 'ItemName') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Items -Name 'Id')

        if ($hasNamedShape) {
            $sourceItems += $Items
        }
        else {
            foreach ($key in $Items.Keys) {
                $sourceItems += [PSCustomObject]@{
                    Name  = [string]$key
                    Count = ConvertTo-RewardInt -Value $Items[$key] -Default 1
                }
            }
        }
    }
    elseif ($Items -is [string] -or $Items -isnot [System.Collections.IEnumerable]) {
        $sourceItems += $Items
    }
    else {
        foreach ($entry in $Items) {
            $sourceItems += $entry
        }
    }

    foreach ($entry in $sourceItems) {
        $normalized = ConvertTo-RewardItem -Item $entry
        if ($null -ne $normalized) {
            $result += $normalized
        }
    }

    return $result
}

function ConvertTo-ReputationRewardEntry {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    [string]$faction = 'Global'
    [int]$delta = [int]0

    if ($Entry -is [int] -or $Entry -is [long] -or $Entry -is [double] -or $Entry -is [decimal]) {
        $delta = ConvertTo-RewardInt -Value $Entry -Default 0
    }
    elseif ($Entry -is [string]) {
        $text = $Entry.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        $match = [regex]::Match($text, '^([^:]+):\s*([-+]?\d+)$')
        if ($match.Success) {
            $faction = [string]$match.Groups[1].Value.Trim()
            $delta = ConvertTo-RewardInt -Value $match.Groups[2].Value -Default 0
        }
        else {
            [int]$parsed = [int]0
            if ([int]::TryParse($text, [ref]$parsed)) {
                $delta = [int]$parsed
            }
            else {
                return $null
            }
        }
    }
    else {
        $faction = [string](Get-RewardValue -Source $Entry -Names @('Faction', 'Name', 'Key') -Default 'Global')
        $delta = ConvertTo-RewardInt -Value (Get-RewardValue -Source $Entry -Names @('Delta', 'Amount', 'Value', 'Count') -Default 0) -Default 0
    }

    if ([string]::IsNullOrWhiteSpace($faction)) {
        $faction = 'Global'
    }

    return [PSCustomObject]@{
        Faction = [string]$faction
        Delta   = [int]$delta
    }
}

function ConvertTo-ReputationRewardArray {
    param($Reputation)

    $result = @()
    if ($null -eq $Reputation) {
        return ,$result
    }

    $sourceEntries = @()
    if ($Reputation -is [System.Collections.IDictionary]) {
        $hasNamedShape =
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Faction') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Name') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Key') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Delta') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Amount') -or
            $null -ne (Find-RewardDictionaryKey -Dictionary $Reputation -Name 'Value')

        if ($hasNamedShape) {
            $sourceEntries += $Reputation
        }
        else {
            foreach ($key in $Reputation.Keys) {
                $sourceEntries += [PSCustomObject]@{
                    Faction = [string]$key
                    Delta   = ConvertTo-RewardInt -Value $Reputation[$key] -Default 0
                }
            }
        }
    }
    elseif (
        $Reputation -is [string] -or
        $Reputation -is [int] -or
        $Reputation -is [long] -or
        $Reputation -is [double] -or
        $Reputation -is [decimal] -or
        $Reputation -isnot [System.Collections.IEnumerable]
    ) {
        $sourceEntries += $Reputation
    }
    else {
        foreach ($entry in $Reputation) {
            $sourceEntries += $entry
        }
    }

    foreach ($entry in $sourceEntries) {
        $normalized = ConvertTo-ReputationRewardEntry -Entry $entry
        if ($null -ne $normalized) {
            $result += $normalized
        }
    }

    return $result
}

function Resolve-RewardChoice {
    param(
        [object[]]$ChoiceItems,
        [Nullable[int]]$ChoiceIndex = $null,
        [string]$ChoiceItemName = ''
    )

    $choices = @($ChoiceItems)
    if ($choices.Count -le 0) {
        return [PSCustomObject]@{
            HasChoices     = $false
            SelectedIndex  = [int]-1
            SelectedItem   = $null
            Error          = ''
        }
    }

    [int]$selectedIndex = [int]-1

    if (-not [string]::IsNullOrWhiteSpace($ChoiceItemName)) {
        for ([int]$i = 0; $i -lt $choices.Count; $i++) {
            if ([string]::Equals([string]$choices[$i].Name, [string]$ChoiceItemName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $selectedIndex = $i
                break
            }
        }

        if ($selectedIndex -lt 0) {
            return [PSCustomObject]@{
                HasChoices     = $true
                SelectedIndex  = [int]-1
                SelectedItem   = $null
                Error          = "Choice item '$ChoiceItemName' does not exist."
            }
        }
    }
    elseif ($null -ne $ChoiceIndex) {
        [int]$indexValue = [int]$ChoiceIndex.Value
        if ($indexValue -lt 0 -or $indexValue -ge $choices.Count) {
            return [PSCustomObject]@{
                HasChoices     = $true
                SelectedIndex  = [int]-1
                SelectedItem   = $null
                Error          = "Choice index $indexValue is out of range."
            }
        }

        $selectedIndex = [int]$indexValue
    }
    else {
        # Deterministic default choice.
        $selectedIndex = [int]0
    }

    return [PSCustomObject]@{
        HasChoices     = $true
        SelectedIndex  = [int]$selectedIndex
        SelectedItem   = $choices[$selectedIndex]
        Error          = ''
    }
}

# ============================================================================
# Internal Helpers - Hook Invocation and Grant Entries
# ============================================================================

function New-RewardGrantEntry {
    param(
        [string]$Type,
        [string]$Name,
        [int]$Amount,
        [bool]$Applied,
        [string]$Source,
        [string]$Detail
    )

    return [PSCustomObject]@{
        Type    = [string]$Type
        Name    = [string]$Name
        Amount  = [int]$Amount
        Applied = [bool]$Applied
        Source  = [string]$Source
        Detail  = [string]$Detail
    }
}

function Invoke-RewardAmountHook {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][int]$Amount,
        [hashtable]$NamedArguments = @{}
    )

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [PSCustomObject]@{
            Invoked = $false
            Error   = 'Command not found.'
        }
    }

    $invokeArgs = @{}

    foreach ($entry in $NamedArguments.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            continue
        }

        if ($command.Parameters.ContainsKey($entry.Key)) {
            $invokeArgs[$entry.Key] = $entry.Value
        }
    }

    $amountParameterNames = @('Amount', 'Delta', 'XP', 'Value', 'Points', 'Count')
    $usedAmountParameter = ''
    foreach ($paramName in $amountParameterNames) {
        if ($command.Parameters.ContainsKey($paramName)) {
            $usedAmountParameter = $paramName
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($usedAmountParameter)) {
        $invokeArgs[$usedAmountParameter] = [int]$Amount
    }

    try {
        if ([string]::IsNullOrWhiteSpace($usedAmountParameter)) {
            & $CommandName $Amount @invokeArgs | Out-Null
        }
        else {
            & $CommandName @invokeArgs | Out-Null
        }

        return [PSCustomObject]@{
            Invoked = $true
            Error   = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Invoked = $false
            Error   = [string]$_.Exception.Message
        }
    }
}

function Invoke-RewardItemGrant {
    param(
        [Parameter(Mandatory = $true)]$ItemReward,
        [Parameter(Mandatory = $true)]$Context,
        [string]$Type = 'Item'
    )

    $itemName = [string](Get-RewardValue -Source $ItemReward -Names @('Name', 'Item', 'ItemName') -Default '')
    [int]$itemCount = ConvertTo-RewardInt -Value (Get-RewardValue -Source $ItemReward -Names @('Count', 'Amount', 'Quantity', 'Value') -Default 0)

    if ([string]::IsNullOrWhiteSpace($itemName) -or $itemCount -le 0) {
        return (New-RewardGrantEntry -Type $Type -Name $itemName -Amount $itemCount -Applied $true -Source 'Skip' -Detail 'No item reward to apply.')
    }

    $addInventoryCmd = Get-Command -Name Add-InventoryItem -ErrorAction SilentlyContinue
    if ($null -ne $addInventoryCmd) {
        try {
            $added = [bool](Add-InventoryItem -Name $itemName -Count $itemCount)
            if ($added) {
                return (New-RewardGrantEntry -Type $Type -Name $itemName -Amount $itemCount -Applied $true -Source 'InventoryHook' -Detail 'Granted through inventory hook.')
            }

            return (New-RewardGrantEntry -Type $Type -Name $itemName -Amount $itemCount -Applied $false -Source 'InventoryHook' -Detail 'Inventory hook rejected item reward.')
        }
        catch {
            return (New-RewardGrantEntry -Type $Type -Name $itemName -Amount $itemCount -Applied $false -Source 'InventoryHook' -Detail ([string]$_.Exception.Message))
        }
    }

    Add-RewardContextMapCount -Context $Context -PropertyName 'Items' -EntryKey $itemName -Amount $itemCount | Out-Null
    return (New-RewardGrantEntry -Type $Type -Name $itemName -Amount $itemCount -Applied $true -Source 'ContextFallback' -Detail 'Recorded in fallback item map.')
}

function Invoke-RewardXPGrant {
    param(
        [int]$Amount,
        [Parameter(Mandatory = $true)]$Context
    )

    if ($Amount -le 0) {
        return (New-RewardGrantEntry -Type 'XP' -Name 'XP' -Amount $Amount -Applied $true -Source 'Skip' -Detail 'No XP reward to apply.')
    }

    $hookNames = @('Add-PlayerXP', 'Add-XP', 'Add-Experience', 'Add-PlayerExperience')
    [bool]$hookFound = $false
    $lastHookError = ''

    foreach ($hookName in $hookNames) {
        $command = Get-Command -Name $hookName -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }

        $hookFound = $true
        $invokeResult = Invoke-RewardAmountHook -CommandName $hookName -Amount $Amount
        if ($invokeResult.Invoked) {
            return (New-RewardGrantEntry -Type 'XP' -Name 'XP' -Amount $Amount -Applied $true -Source $hookName -Detail 'Granted through XP hook.')
        }

        $lastHookError = [string]$invokeResult.Error
    }

    if ($hookFound) {
        return (New-RewardGrantEntry -Type 'XP' -Name 'XP' -Amount $Amount -Applied $false -Source 'XPHook' -Detail "XP hook invocation failed: $lastHookError")
    }

    Add-RewardContextNumeric -Context $Context -PropertyName 'XP' -Amount $Amount | Out-Null
    return (New-RewardGrantEntry -Type 'XP' -Name 'XP' -Amount $Amount -Applied $true -Source 'ContextFallback' -Detail 'Recorded in fallback XP value.')
}

function Invoke-RewardGoldGrant {
    param(
        [int]$Amount,
        [Parameter(Mandatory = $true)]$Context
    )

    if ($Amount -eq 0) {
        return (New-RewardGrantEntry -Type 'Gold' -Name 'Gold' -Amount $Amount -Applied $true -Source 'Skip' -Detail 'No gold reward to apply.')
    }

    $hookNames = @('Add-PlayerGold', 'Add-Gold', 'Add-PlayerCurrency')
    [bool]$hookFound = $false
    $lastHookError = ''

    foreach ($hookName in $hookNames) {
        $command = Get-Command -Name $hookName -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }

        $hookFound = $true
        $invokeResult = Invoke-RewardAmountHook -CommandName $hookName -Amount $Amount
        if ($invokeResult.Invoked) {
            return (New-RewardGrantEntry -Type 'Gold' -Name 'Gold' -Amount $Amount -Applied $true -Source $hookName -Detail 'Granted through gold hook.')
        }

        $lastHookError = [string]$invokeResult.Error
    }

    if ($hookFound) {
        return (New-RewardGrantEntry -Type 'Gold' -Name 'Gold' -Amount $Amount -Applied $false -Source 'GoldHook' -Detail "Gold hook invocation failed: $lastHookError")
    }

    Add-RewardContextNumeric -Context $Context -PropertyName 'Gold' -Amount $Amount | Out-Null
    return (New-RewardGrantEntry -Type 'Gold' -Name 'Gold' -Amount $Amount -Applied $true -Source 'ContextFallback' -Detail 'Recorded in fallback gold value.')
}

function Invoke-RewardReputationGrant {
    param(
        [Parameter(Mandatory = $true)]$ReputationReward,
        [Parameter(Mandatory = $true)]$Context
    )

    $faction = [string](Get-RewardValue -Source $ReputationReward -Names @('Faction', 'Name', 'Key') -Default 'Global')
    [int]$delta = ConvertTo-RewardInt -Value (Get-RewardValue -Source $ReputationReward -Names @('Delta', 'Amount', 'Value', 'Count') -Default 0)

    if ([string]::IsNullOrWhiteSpace($faction)) {
        $faction = 'Global'
    }

    if ($delta -eq 0) {
        return (New-RewardGrantEntry -Type 'Reputation' -Name $faction -Amount 0 -Applied $true -Source 'Skip' -Detail 'No reputation reward to apply.')
    }

    $command = Get-Command -Name Add-Reputation -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $invokeResult = Invoke-RewardAmountHook -CommandName 'Add-Reputation' -Amount $delta -NamedArguments @{ Faction = $faction }
        if ($invokeResult.Invoked) {
            return (New-RewardGrantEntry -Type 'Reputation' -Name $faction -Amount $delta -Applied $true -Source 'Add-Reputation' -Detail 'Granted through reputation hook.')
        }

        return (New-RewardGrantEntry -Type 'Reputation' -Name $faction -Amount $delta -Applied $false -Source 'Add-Reputation' -Detail "Reputation hook invocation failed: $($invokeResult.Error)")
    }

    Add-RewardContextMapCount -Context $Context -PropertyName 'Reputation' -EntryKey $faction -Amount $delta | Out-Null
    return (New-RewardGrantEntry -Type 'Reputation' -Name $faction -Amount $delta -Applied $true -Source 'ContextFallback' -Detail 'Recorded in fallback reputation map.')
}

# ============================================================================
# Public API - Reward Payload Creation and Normalization
# ============================================================================

function New-RewardItem {
    <#
    .SYNOPSIS
        Creates a normalized item reward entry.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Count = 1
    )

    return (ConvertTo-RewardItem -Item ([PSCustomObject]@{
        Name  = [string]$Name
        Count = [int]$Count
    }))
}

function New-ReputationReward {
    <#
    .SYNOPSIS
        Creates a normalized reputation reward entry.
    #>
    param(
        [string]$Faction = 'Global',
        [int]$Delta = 0
    )

    return (ConvertTo-ReputationRewardEntry -Entry ([PSCustomObject]@{
        Faction = [string]$Faction
        Delta   = [int]$Delta
    }))
}

function New-QuestRewardPayload {
    <#
    .SYNOPSIS
        Creates a normalized quest reward payload.
    .DESCRIPTION
        Supports fixed rewards (Items/XP/Gold/Reputation) and optional
        choice rewards (ChoiceItems, one selected item).
    #>
    param(
        $Items = @(),
        [int]$XP = 0,
        [int]$Gold = 0,
        $Reputation = $null,
        $ChoiceItems = @(),
        $Metadata = $null
    )

    $normalizedItems = @(ConvertTo-RewardItemArray -Items $Items)
    $normalizedChoiceItems = @(ConvertTo-RewardItemArray -Items $ChoiceItems)
    $normalizedReputation = @(ConvertTo-ReputationRewardArray -Reputation $Reputation)

    if ($null -eq $Metadata) {
        $Metadata = @{}
    }

    $payload = [PSCustomObject]@{
        Items       = @($normalizedItems)
        XP          = [int]$XP
        Gold        = [int]$Gold
        Reputation  = @($normalizedReputation)
        ChoiceItems = @($normalizedChoiceItems)
        Metadata    = $Metadata
    }

    $payload | Add-Member -MemberType ScriptMethod -Name Grant -Value {
        param(
            $Context = $null,
            [Nullable[int]]$ChoiceIndex = $null,
            [string]$ChoiceItemName = ''
        )

        return (Grant-RewardPayload -Rewards $this -Context $Context -ChoiceIndex $ChoiceIndex -ChoiceItemName $ChoiceItemName)
    } -Force

    return $payload
}

function New-Reward {
    <#
    .SYNOPSIS
        Compatibility wrapper for creating reward payloads.
    #>
    param(
        $Items = @(),
        [int]$XP = 0,
        [int]$Gold = 0,
        $Reputation = $null,
        $ChoiceItems = @(),
        $Metadata = $null
    )

    return (New-QuestRewardPayload -Items $Items -XP $XP -Gold $Gold -Reputation $Reputation -ChoiceItems $ChoiceItems -Metadata $Metadata)
}

function ConvertTo-QuestRewardPayload {
    <#
    .SYNOPSIS
        Normalizes arbitrary reward data into a quest reward payload.
    #>
    param($Rewards)

    if ($null -eq $Rewards) {
        return (New-QuestRewardPayload)
    }

    $items = @()
    $choiceItems = @()
    $reputation = $null
    [int]$xp = [int]0
    [int]$gold = [int]0
    $metadata = @{}

    if ($Rewards -is [string]) {
        $items = @($Rewards)
    }
    elseif (
        $Rewards -isnot [System.Collections.IDictionary] -and
        $Rewards -is [System.Collections.IEnumerable] -and
        $Rewards -isnot [PSCustomObject]
    ) {
        $items = @($Rewards)
    }
    else {
        $items = Get-RewardValue -Source $Rewards -Names @('Items', 'ItemRewards', 'Item', 'Loot') -Default @()
        $choiceItems = Get-RewardValue -Source $Rewards -Names @('ChoiceItems', 'ItemChoices', 'ChoiceRewards', 'Choices') -Default @()
        $reputation = Get-RewardValue -Source $Rewards -Names @('Reputation', 'ReputationRewards', 'FactionReputation') -Default $null
        $xp = ConvertTo-RewardInt -Value (Get-RewardValue -Source $Rewards -Names @('XP', 'Experience', 'Exp') -Default 0) -Default 0
        $gold = ConvertTo-RewardInt -Value (Get-RewardValue -Source $Rewards -Names @('Gold', 'Money', 'Currency') -Default 0) -Default 0
        $metadata = Get-RewardValue -Source $Rewards -Names @('Metadata', 'Data') -Default @{}
    }

    return (New-QuestRewardPayload -Items $items -XP $xp -Gold $gold -Reputation $reputation -ChoiceItems $choiceItems -Metadata $metadata)
}

# ============================================================================
# Public API - Reward Granting and Reporting
# ============================================================================

function Grant-RewardPayload {
    <#
    .SYNOPSIS
        Grants a reward payload to game hooks or a fallback context.
    .DESCRIPTION
        Applies reward types in deterministic order:
        1) Items
        2) XP
        3) Gold
        4) Reputation
        5) ChoiceItems (single selected item)
    #>
    param(
        [Parameter(Mandatory = $true)]$Rewards,
        $Context = $null,
        [Nullable[int]]$ChoiceIndex = $null,
        [string]$ChoiceItemName = ''
    )

    $resolvedContext = Resolve-RewardContext -Context $Context
    $payload = ConvertTo-QuestRewardPayload -Rewards $Rewards

    $entries = @()
    [int]$itemsGranted = [int]0
    [int]$xpGranted = [int]0
    [int]$goldGranted = [int]0
    [int]$reputationGranted = [int]0
    $selectedChoice = $null

    foreach ($itemReward in @($payload.Items)) {
        $entry = Invoke-RewardItemGrant -ItemReward $itemReward -Context $resolvedContext -Type 'Item'
        $entries += $entry
        if ($entry.Applied) {
            $itemsGranted += [int]$entry.Amount
        }
    }

    $xpEntry = Invoke-RewardXPGrant -Amount ([int]$payload.XP) -Context $resolvedContext
    $entries += $xpEntry
    if ($xpEntry.Applied) {
        $xpGranted += [int]$xpEntry.Amount
    }

    $goldEntry = Invoke-RewardGoldGrant -Amount ([int]$payload.Gold) -Context $resolvedContext
    $entries += $goldEntry
    if ($goldEntry.Applied) {
        $goldGranted += [int]$goldEntry.Amount
    }

    foreach ($repReward in @($payload.Reputation)) {
        $repEntry = Invoke-RewardReputationGrant -ReputationReward $repReward -Context $resolvedContext
        $entries += $repEntry
        if ($repEntry.Applied) {
            $reputationGranted += [int]$repEntry.Amount
        }
    }

    $choiceResolution = Resolve-RewardChoice -ChoiceItems @($payload.ChoiceItems) -ChoiceIndex $ChoiceIndex -ChoiceItemName $ChoiceItemName
    if ($choiceResolution.HasChoices) {
        if (-not [string]::IsNullOrWhiteSpace($choiceResolution.Error)) {
            $entries += (New-RewardGrantEntry -Type 'ChoiceItem' -Name '' -Amount 0 -Applied $false -Source 'ChoiceSelection' -Detail $choiceResolution.Error)
        }
        else {
            $selectedChoice = $choiceResolution.SelectedItem
            $choiceEntry = Invoke-RewardItemGrant -ItemReward $selectedChoice -Context $resolvedContext -Type 'ChoiceItem'
            $entries += $choiceEntry
            if ($choiceEntry.Applied) {
                $itemsGranted += [int]$choiceEntry.Amount
            }
        }
    }

    [int]$failedCount = [int]0
    [int]$appliedCount = [int]0
    foreach ($entry in $entries) {
        if ([bool]$entry.Applied) {
            $appliedCount++
        }
        else {
            $failedCount++
        }
    }

    return [PSCustomObject]@{
        Success        = [bool]($failedCount -eq 0)
        Rewards        = $payload
        Entries        = @($entries)
        Summary        = [PSCustomObject]@{
            ItemsGranted       = [int]$itemsGranted
            XPGranted          = [int]$xpGranted
            GoldGranted        = [int]$goldGranted
            ReputationGranted  = [int]$reputationGranted
            AppliedEntryCount  = [int]$appliedCount
            FailedEntryCount   = [int]$failedCount
        }
        SelectedChoice = $selectedChoice
        TimestampUtc   = [datetime]::UtcNow
        Context        = $resolvedContext
    }
}

function Grant-Rewards {
    <#
    .SYNOPSIS
        Alias wrapper for Grant-RewardPayload.
    #>
    param(
        [Parameter(Mandatory = $true)]$Rewards,
        $Context = $null,
        [Nullable[int]]$ChoiceIndex = $null,
        [string]$ChoiceItemName = ''
    )

    return (Grant-RewardPayload -Rewards $Rewards -Context $Context -ChoiceIndex $ChoiceIndex -ChoiceItemName $ChoiceItemName)
}

function Get-RewardFallbackState {
    <#
    .SYNOPSIS
        Returns the module fallback reward state.
    #>

    Ensure-RewardSystem
    return $script:RewardFallbackState
}

# ============================================================================
# Internal Helpers - Quest Reward Metadata
# ============================================================================

function Resolve-RewardQuest {
    param($Quest)

    if ($null -eq $Quest) {
        return $null
    }

    if ($Quest -is [string]) {
        $getQuestCmd = Get-Command -Name Get-Quest -ErrorAction SilentlyContinue
        if ($null -ne $getQuestCmd) {
            try {
                return (Get-Quest -Quest $Quest)
            }
            catch {
                return $null
            }
        }

        return $null
    }

    return $Quest
}

function Ensure-QuestRewardMetadata {
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    $metadata = Get-RewardValue -Source $Quest -Names @('Metadata') -Default $null
    if ($null -eq $metadata) {
        $metadata = @{}
        Set-RewardObjectProperty -Object $Quest -Name 'Metadata' -Value $metadata
    }

    return $metadata
}

function Get-QuestRewardMetadataValue {
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    $metadata = Ensure-QuestRewardMetadata -Quest $Quest
    return (Get-RewardValue -Source $metadata -Names @($Name) -Default $Default)
}

function Set-QuestRewardMetadataValue {
    param(
        [Parameter(Mandatory = $true)]$Quest,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    $metadata = Ensure-QuestRewardMetadata -Quest $Quest
    Set-RewardObjectProperty -Object $metadata -Name $Name -Value $Value
    return $Value
}

# ============================================================================
# Public API - Quest Completion Reward Hooks
# ============================================================================

function Test-QuestRewardGranted {
    <#
    .SYNOPSIS
        Returns true when rewards were already granted for a quest.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest
    )

    $questObj = Resolve-RewardQuest -Quest $Quest
    if ($null -eq $questObj) {
        return $false
    }

    $value = Get-QuestRewardMetadataValue -Quest $questObj -Name 'RewardsGranted' -Default $null
    if ($null -eq $value) {
        $value = Get-QuestRewardMetadataValue -Quest $questObj -Name 'RewardGranted' -Default $null
    }

    return (ConvertTo-RewardBool -Value $value)
}

function Grant-QuestCompletionRewards {
    <#
    .SYNOPSIS
        Grants a quest's reward payload when the quest is completed.
    .DESCRIPTION
        Uses quest metadata flag RewardsGranted to avoid duplicate grants unless
        -Force is used.
    #>
    param(
        [Parameter(Mandatory = $true)]$Quest,
        $Context = $null,
        [Nullable[int]]$ChoiceIndex = $null,
        [string]$ChoiceItemName = '',
        [switch]$Force
    )

    $questObj = Resolve-RewardQuest -Quest $Quest
    if ($null -eq $questObj) {
        return [PSCustomObject]@{
            QuestId        = ''
            QuestName      = ''
            QuestState     = ''
            Attempted      = $false
            Granted        = $false
            AlreadyGranted = $false
            RewardResult   = $null
            Reason         = 'Quest not found.'
        }
    }

    $questId = [string](Get-RewardValue -Source $questObj -Names @('Id') -Default '')
    $questName = [string](Get-RewardValue -Source $questObj -Names @('Name') -Default $questId)
    $questState = [string](Get-RewardValue -Source $questObj -Names @('State') -Default '')

    if (-not $Force -and -not [string]::Equals($questState, 'Completed', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{
            QuestId        = $questId
            QuestName      = $questName
            QuestState     = $questState
            Attempted      = $false
            Granted        = $false
            AlreadyGranted = $false
            RewardResult   = $null
            Reason         = 'Quest is not completed.'
        }
    }

    $alreadyGranted = Test-QuestRewardGranted -Quest $questObj
    if ($alreadyGranted -and -not $Force) {
        return [PSCustomObject]@{
            QuestId        = $questId
            QuestName      = $questName
            QuestState     = $questState
            Attempted      = $false
            Granted        = $false
            AlreadyGranted = $true
            RewardResult   = (Get-QuestRewardMetadataValue -Quest $questObj -Name 'RewardsLastResult' -Default $null)
            Reason         = 'Rewards already granted for quest.'
        }
    }

    $rewardPayloadRaw = Get-RewardValue -Source $questObj -Names @('Rewards') -Default $null
    $rewardPayload = ConvertTo-QuestRewardPayload -Rewards $rewardPayloadRaw

    $grantResult = Grant-RewardPayload -Rewards $rewardPayload -Context $Context -ChoiceIndex $ChoiceIndex -ChoiceItemName $ChoiceItemName

    Set-QuestRewardMetadataValue -Quest $questObj -Name 'RewardsLastResult' -Value $grantResult | Out-Null
    if ($grantResult.Success) {
        Set-QuestRewardMetadataValue -Quest $questObj -Name 'RewardsGranted' -Value $true | Out-Null
        Set-QuestRewardMetadataValue -Quest $questObj -Name 'RewardsGrantedAt' -Value ([datetime]::UtcNow) | Out-Null
    }

    return [PSCustomObject]@{
        QuestId        = $questId
        QuestName      = $questName
        QuestState     = $questState
        Attempted      = $true
        Granted        = [bool]$grantResult.Success
        AlreadyGranted = $alreadyGranted
        RewardResult   = $grantResult
        Reason         = if ($grantResult.Success) { 'Rewards granted.' } else { 'Reward grant had failures.' }
    }
}

function Grant-QuestRewardsFromObjectiveUpdate {
    <#
    .SYNOPSIS
        Grants rewards for completed quests in an objective update result.
    .DESCRIPTION
        Intended helper for quest completion hooks where caller passes the
        output of Update-QuestObjectiveEvent / Update-QuestObjective.
    .PARAMETER QuestUpdateResult
        Result object containing CompletedQuests.
    .PARAMETER ChoiceByQuestId
        Optional map of quest id -> choice selector.
        Value can be:
        - int    : ChoiceIndex
        - string : ChoiceItemName
        - object : { ChoiceIndex = n } or { ChoiceItemName = 'Item' }
    #>
    param(
        [Parameter(Mandatory = $true)]$QuestUpdateResult,
        $Context = $null,
        [hashtable]$ChoiceByQuestId = @{},
        [switch]$Force
    )

    $completedQuests = Get-RewardValue -Source $QuestUpdateResult -Names @('CompletedQuests', 'Completed', 'Quests') -Default @()
    $results = @()

    foreach ($quest in @($completedQuests)) {
        if ($null -eq $quest) {
            continue
        }

        $questId = [string](Get-RewardValue -Source $quest -Names @('Id') -Default '')

        $choiceSelector = $null
        if ($ChoiceByQuestId.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($questId)) {
            $selectorKey = Find-RewardDictionaryKey -Dictionary $ChoiceByQuestId -Name $questId
            if ($null -ne $selectorKey) {
                $choiceSelector = $ChoiceByQuestId[$selectorKey]
            }
        }

        [Nullable[int]]$choiceIndex = $null
        [string]$choiceItemName = ''

        if ($null -ne $choiceSelector) {
            if ($choiceSelector -is [int] -or $choiceSelector -is [long]) {
                $choiceIndex = [int]$choiceSelector
            }
            elseif ($choiceSelector -is [string]) {
                $choiceItemName = [string]$choiceSelector
            }
            else {
                $candidateIndex = Get-RewardValue -Source $choiceSelector -Names @('ChoiceIndex', 'Index') -Default $null
                if ($null -ne $candidateIndex) {
                    try {
                        $choiceIndex = [int]$candidateIndex
                    }
                    catch {
                        $choiceIndex = $null
                    }
                }

                $candidateName = [string](Get-RewardValue -Source $choiceSelector -Names @('ChoiceItemName', 'ItemName', 'Name') -Default '')
                if (-not [string]::IsNullOrWhiteSpace($candidateName)) {
                    $choiceItemName = $candidateName
                }
            }
        }

        $grantParams = @{
            Quest = $quest
            Context = $Context
        }

        if ($Force) {
            $grantParams['Force'] = $true
        }

        if ($null -ne $choiceIndex) {
            $grantParams['ChoiceIndex'] = [int]$choiceIndex.Value
        }

        if (-not [string]::IsNullOrWhiteSpace($choiceItemName)) {
            $grantParams['ChoiceItemName'] = $choiceItemName
        }

        $results += (Grant-QuestCompletionRewards @grantParams)
    }

    return ,$results
}

# Initialize reward state on dot-source.
Initialize-RewardSystem -Quiet | Out-Null
