# ============================================================================
# Game/Dialog.ps1 - Dialog Tree and Conversation Session System
# ============================================================================
# Provides a text-only dialog framework with:
# - Dialog tree/node/option data structures
# - Condition based option visibility
# - Consequence/effect handling on option selection
# - Runtime session state for active conversation flow
#
# Dependencies (optional when available):
#   Game/Inventory.ps1  (Add-InventoryItem, Remove-InventoryItem, Get-InventoryItemCount)
#   Game/Stats.ps1      (Get-PlayerStats)
#   Game/Reputation.ps1 (optional hook, if present)
#   Future quest system hooks (Set-QuestFlag, Get-QuestState)
# ============================================================================

# --- Module State ---
$script:DialogInitialized = $false
$script:DialogTrees = @{}
$script:DialogNextTreeId = [int]1
$script:ActiveDialogSession = $null
$script:DialogQuestFlags = @{}
$script:DialogFallbackReputation = [int]0

# ============================================================================
# Internal Helpers - Generic Access
# ============================================================================

function Normalize-DialogKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.Trim().ToLowerInvariant()
}

function Get-DialogValue {
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
                # Some dictionary types throw on Contains; continue with manual scan.
            }

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

function ConvertTo-DialogMap {
    param($Source)

    $map = @{}

    if ($null -eq $Source) {
        return $map
    }

    if ($Source -is [System.Collections.IDictionary]) {
        foreach ($key in $Source.Keys) {
            $map[[string]$key] = $Source[$key]
        }
        return $map
    }

    foreach ($prop in $Source.PSObject.Properties) {
        $map[[string]$prop.Name] = $prop.Value
    }

    return $map
}

function New-DialogContext {
    param($InputContext)

    $contextSource = $InputContext
    if ($null -eq $contextSource) {
        $contextSource = @{}
    }

    $stats = ConvertTo-DialogMap -Source (Get-DialogValue -Source $contextSource -Names @('Stats'))
    $inventory = ConvertTo-DialogMap -Source (Get-DialogValue -Source $contextSource -Names @('Inventory', 'Items'))
    $quests = ConvertTo-DialogMap -Source (Get-DialogValue -Source $contextSource -Names @('Quests', 'QuestFlags'))
    $data = ConvertTo-DialogMap -Source (Get-DialogValue -Source $contextSource -Names @('Data'))

    $repRaw = Get-DialogValue -Source $contextSource -Names @('Reputation')
    if ($null -eq $repRaw) {
        $repRaw = $script:DialogFallbackReputation
    }

    [int]$reputation = [int]0
    try {
        $reputation = [int]$repRaw
    }
    catch {
        $reputation = [int]$script:DialogFallbackReputation
    }

    return [PSCustomObject]@{
        Stats      = $stats
        Inventory  = $inventory
        Quests     = $quests
        Reputation = [int]$reputation
        Data       = $data
    }
}

function Resolve-DialogTree {
    param($Tree)

    if ($null -eq $Tree) {
        return $null
    }

    if ($Tree -is [string]) {
        $key = Normalize-DialogKey -Value $Tree
        if ($script:DialogTrees.ContainsKey($key)) {
            return $script:DialogTrees[$key]
        }
        return $null
    }

    if ($null -ne $Tree.PSObject.Properties['Nodes']) {
        return $Tree
    }

    $treeId = Get-DialogValue -Source $Tree -Names @('TreeId', 'Id')
    if (-not [string]::IsNullOrWhiteSpace([string]$treeId)) {
        return (Resolve-DialogTree -Tree ([string]$treeId))
    }

    return $null
}

function Resolve-DialogNode {
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [string]$NodeId
    )

    if ([string]::IsNullOrWhiteSpace($NodeId)) {
        return $null
    }

    $nodeKey = Normalize-DialogKey -Value $NodeId
    if ($Tree.Nodes.ContainsKey($nodeKey)) {
        return $Tree.Nodes[$nodeKey]
    }

    return $null
}

function Get-DialogFirstNode {
    param([Parameter(Mandatory = $true)]$Tree)

    foreach ($node in $Tree.Nodes.Values) {
        return $node
    }

    return $null
}

function Get-DialogSessionInternal {
    param($Session)

    if ($null -ne $Session) {
        return $Session
    }

    return $script:ActiveDialogSession
}

function Complete-DialogSession {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [string]$Reason = 'Completed'
    )

    $Session.IsActive = $false
    $Session.Completed = $true
    $Session.CompletionReason = [string]$Reason
    $Session.EndedAt = [datetime]::UtcNow

    if ($null -ne $script:ActiveDialogSession) {
        if ($script:ActiveDialogSession.TreeId -eq $Session.TreeId -and
            $script:ActiveDialogSession.StartedAt -eq $Session.StartedAt) {
            $script:ActiveDialogSession = $null
        }
    }
}

# ============================================================================
# Internal Helpers - Context Hooks (Stats/Items/Quests/Reputation)
# ============================================================================

function Get-DialogStatValue {
    param(
        $Session,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($null -ne $Session -and $null -ne $Session.Context -and $null -ne $Session.Context.Stats) {
        $contextValue = Get-DialogValue -Source $Session.Context.Stats -Names @($Name)
        if ($null -ne $contextValue) {
            return $contextValue
        }
    }

    if (Get-Command -Name Get-PlayerStats -ErrorAction SilentlyContinue) {
        try {
            $stats = Get-PlayerStats
            if ($null -ne $stats) {
                $statValue = Get-DialogValue -Source $stats -Names @($Name)
                if ($null -ne $statValue) {
                    return $statValue
                }
            }
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    return $null
}

function Set-DialogStatValue {
    param(
        $Session,
        [string]$Name,
        $Value
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($null -eq $Session -or $null -eq $Session.Context) {
        return
    }

    if ($null -eq $Session.Context.Stats) {
        $Session.Context.Stats = @{}
    }

    if ($Session.Context.Stats -is [System.Collections.IDictionary]) {
        $Session.Context.Stats[[string]$Name] = $Value
    }
}

function Get-DialogItemCount {
    param(
        $Session,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [int]0
    }

    if ($null -ne $Session -and $null -ne $Session.Context -and $null -ne $Session.Context.Inventory) {
        $value = Get-DialogValue -Source $Session.Context.Inventory -Names @($Name)
        if ($null -ne $value) {
            try {
                return [int]$value
            }
            catch {
                return [int]0
            }
        }
    }

    if (Get-Command -Name Get-InventoryItemCount -ErrorAction SilentlyContinue) {
        try {
            return [int](Get-InventoryItemCount -Name $Name)
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    return [int]0
}

function Set-DialogItemCount {
    param(
        $Session,
        [string]$Name,
        [int]$Count
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($Count -lt 0) {
        $Count = [int]0
    }

    if ($null -eq $Session -or $null -eq $Session.Context) {
        return
    }

    if ($null -eq $Session.Context.Inventory) {
        $Session.Context.Inventory = @{}
    }

    if ($Session.Context.Inventory -is [System.Collections.IDictionary]) {
        $Session.Context.Inventory[[string]$Name] = [int]$Count
    }
}

function Get-DialogQuestValue {
    param(
        $Session,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($null -ne $Session -and $null -ne $Session.Context -and $null -ne $Session.Context.Quests) {
        $contextValue = Get-DialogValue -Source $Session.Context.Quests -Names @($Name)
        if ($null -ne $contextValue) {
            return $contextValue
        }
    }

    if ($script:DialogQuestFlags.ContainsKey($Name)) {
        return $script:DialogQuestFlags[$Name]
    }

    if (Get-Command -Name Get-QuestState -ErrorAction SilentlyContinue) {
        try {
            return (Get-QuestState -Name $Name)
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    if (Get-Command -Name Get-QuestFlag -ErrorAction SilentlyContinue) {
        try {
            return (Get-QuestFlag -Name $Name)
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    return $null
}

function Set-DialogQuestValue {
    param(
        $Session,
        [string]$Name,
        $Value
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($null -ne $Session -and $null -ne $Session.Context) {
        if ($null -eq $Session.Context.Quests) {
            $Session.Context.Quests = @{}
        }

        if ($Session.Context.Quests -is [System.Collections.IDictionary]) {
            $Session.Context.Quests[[string]$Name] = $Value
        }
    }

    $script:DialogQuestFlags[[string]$Name] = $Value

    if (Get-Command -Name Set-QuestFlag -ErrorAction SilentlyContinue) {
        try {
            Set-QuestFlag $Name $Value | Out-Null
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    if (Get-Command -Name Set-QuestState -ErrorAction SilentlyContinue) {
        try {
            Set-QuestState $Name $Value | Out-Null
        }
        catch {
            # Ignore optional hook errors.
        }
    }
}

function Get-DialogReputationValue {
    param($Session)

    if ($null -ne $Session -and $null -ne $Session.Context) {
        $rep = Get-DialogValue -Source $Session.Context -Names @('Reputation')
        if ($null -ne $rep) {
            try {
                return [int]$rep
            }
            catch {
                # Fall through to hook/default.
            }
        }
    }

    if (Get-Command -Name Get-Reputation -ErrorAction SilentlyContinue) {
        try {
            return [int](Get-Reputation)
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    return [int]$script:DialogFallbackReputation
}

function Set-DialogReputationValue {
    param(
        $Session,
        [int]$Value
    )

    if ($null -ne $Session -and $null -ne $Session.Context) {
        $Session.Context.Reputation = [int]$Value
    }

    $script:DialogFallbackReputation = [int]$Value

    if (Get-Command -Name Set-Reputation -ErrorAction SilentlyContinue) {
        try {
            Set-Reputation $Value | Out-Null
        }
        catch {
            # Ignore optional hook errors.
        }
    }
}

function Add-DialogReputationValue {
    param(
        $Session,
        [int]$Delta
    )

    $current = [int](Get-DialogReputationValue -Session $Session)
    $updated = [int]($current + $Delta)

    Set-DialogReputationValue -Session $Session -Value $updated

    if (Get-Command -Name Add-Reputation -ErrorAction SilentlyContinue) {
        try {
            Add-Reputation $Delta | Out-Null
        }
        catch {
            # Ignore optional hook errors.
        }
    }

    return [int]$updated
}

# ============================================================================
# Internal Helpers - Conditions
# ============================================================================

function ConvertTo-DialogDouble {
    param(
        $Value,
        [ref]$OutValue
    )

    try {
        if ($Value -is [bool]) {
            if ($Value) {
                $OutValue.Value = [double]1.0
            }
            else {
                $OutValue.Value = [double]0.0
            }
            return $true
        }

        $OutValue.Value = [double]$Value
        return $true
    }
    catch {
        return $false
    }
}

function Compare-DialogValues {
    param(
        $Actual,
        $Expected,
        [string]$Operator = 'eq'
    )

    $op = 'eq'
    if (-not [string]::IsNullOrWhiteSpace($Operator)) {
        $op = $Operator.Trim().ToLowerInvariant()
    }

    switch ($op) {
        '==' { $op = 'eq' }
        '=' { $op = 'eq' }
        '!=' { $op = 'ne' }
        '<>' { $op = 'ne' }
        '>' { $op = 'gt' }
        '>=' { $op = 'ge' }
        '<' { $op = 'lt' }
        '<=' { $op = 'le' }
        default { }
    }

    [double]$actualNum = [double]0
    [double]$expectedNum = [double]0
    $actualIsNum = ConvertTo-DialogDouble -Value $Actual -OutValue ([ref]$actualNum)
    $expectedIsNum = ConvertTo-DialogDouble -Value $Expected -OutValue ([ref]$expectedNum)

    switch ($op) {
        'eq' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -eq $expectedNum) }
            return ($Actual -eq $Expected)
        }
        'ne' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -ne $expectedNum) }
            return ($Actual -ne $Expected)
        }
        'gt' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -gt $expectedNum) }
            return ([string]$Actual -gt [string]$Expected)
        }
        'ge' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -ge $expectedNum) }
            return ([string]$Actual -ge [string]$Expected)
        }
        'lt' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -lt $expectedNum) }
            return ([string]$Actual -lt [string]$Expected)
        }
        'le' {
            if ($actualIsNum -and $expectedIsNum) { return ($actualNum -le $expectedNum) }
            return ([string]$Actual -le [string]$Expected)
        }
        'contains' {
            if ($Actual -is [string]) {
                return $Actual.Contains([string]$Expected)
            }

            if ($Actual -is [System.Collections.IEnumerable]) {
                foreach ($entry in $Actual) {
                    if ($entry -eq $Expected) {
                        return $true
                    }
                }
            }

            return $false
        }
        'in' {
            if ($Expected -is [string]) {
                return $Expected.Contains([string]$Actual)
            }

            if ($Expected -is [System.Collections.IEnumerable]) {
                foreach ($entry in $Expected) {
                    if ($entry -eq $Actual) {
                        return $true
                    }
                }
            }

            return $false
        }
        default {
            return ($Actual -eq $Expected)
        }
    }
}

function Test-DialogComparisonSpec {
    param(
        $Spec,
        $Actual,
        [string]$DefaultOperator = 'eq',
        $DefaultExpected = $null
    )

    $minValue = Get-DialogValue -Source $Spec -Names @('Min', 'AtLeast', 'Minimum')
    if ($null -ne $minValue) {
        if (-not (Compare-DialogValues -Actual $Actual -Expected $minValue -Operator 'ge')) {
            return $false
        }
    }

    $maxValue = Get-DialogValue -Source $Spec -Names @('Max', 'AtMost', 'Maximum')
    if ($null -ne $maxValue) {
        if (-not (Compare-DialogValues -Actual $Actual -Expected $maxValue -Operator 'le')) {
            return $false
        }
    }

    $expected = Get-DialogValue -Source $Spec -Names @('Expected', 'Value', 'Target')
    if ($null -eq $expected -and $null -ne $DefaultExpected) {
        $expected = $DefaultExpected
    }

    if ($null -ne $expected) {
        $operator = Get-DialogValue -Source $Spec -Names @('Operator', 'Op')
        if ([string]::IsNullOrWhiteSpace([string]$operator)) {
            $operator = $DefaultOperator
        }

        if (-not (Compare-DialogValues -Actual $Actual -Expected $expected -Operator $operator)) {
            return $false
        }
    }

    return $true
}

function Test-DialogCondition {
    param(
        $Condition,
        $Session
    )

    if ($null -eq $Condition) {
        return $true
    }

    if ($Condition -is [bool]) {
        return [bool]$Condition
    }

    if ($Condition -is [ScriptBlock]) {
        try {
            return [bool](& $Condition $Session $Session.Context)
        }
        catch {
            return $false
        }
    }

    $predicate = Get-DialogValue -Source $Condition -Names @('Predicate', 'Test')
    if ($predicate -is [ScriptBlock]) {
        try {
            $predicateResult = [bool](& $predicate $Session $Session.Context $Condition)
            $negate = Get-DialogValue -Source $Condition -Names @('Not', 'Negate') -Default $false
            if ([bool]$negate) { return (-not $predicateResult) }
            return $predicateResult
        }
        catch {
            return $false
        }
    }

    $type = [string](Get-DialogValue -Source $Condition -Names @('Type', 'Kind', 'ConditionType') -Default '')
    if ([string]::IsNullOrWhiteSpace($type)) {
        if ($null -ne (Get-DialogValue -Source $Condition -Names @('Stat', 'StatName'))) {
            $type = 'stat'
        }
        elseif ($null -ne (Get-DialogValue -Source $Condition -Names @('Item', 'ItemName'))) {
            $type = 'item'
        }
        elseif ($null -ne (Get-DialogValue -Source $Condition -Names @('Quest', 'QuestId', 'Flag'))) {
            $type = 'quest'
        }
        elseif ($null -ne (Get-DialogValue -Source $Condition -Names @('Reputation'))) {
            $type = 'reputation'
        }
    }

    $type = $type.Trim().ToLowerInvariant()
    [bool]$result = $true

    switch ($type) {
        'stat' {
            $statName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Stat', 'StatName'))
            $actualValue = Get-DialogStatValue -Session $Session -Name $statName
            if ($null -eq $actualValue) {
                $actualValue = [int]0
            }

            $result = Test-DialogComparisonSpec -Spec $Condition -Actual $actualValue -DefaultOperator 'ge'
        }
        'stats' {
            $statName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Stat', 'StatName'))
            $actualValue = Get-DialogStatValue -Session $Session -Name $statName
            if ($null -eq $actualValue) {
                $actualValue = [int]0
            }

            $result = Test-DialogComparisonSpec -Spec $Condition -Actual $actualValue -DefaultOperator 'ge'
        }
        'item' {
            $itemName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Item', 'ItemName'))
            [int]$actualCount = [int](Get-DialogItemCount -Session $Session -Name $itemName)

            $requiredCount = Get-DialogValue -Source $Condition -Names @('Count', 'Amount', 'Expected', 'Value') -Default ([int]1)
            $result = Test-DialogComparisonSpec -Spec $Condition -Actual $actualCount -DefaultOperator 'ge' -DefaultExpected $requiredCount
        }
        'items' {
            $itemName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Item', 'ItemName'))
            [int]$actualCount = [int](Get-DialogItemCount -Session $Session -Name $itemName)

            $requiredCount = Get-DialogValue -Source $Condition -Names @('Count', 'Amount', 'Expected', 'Value') -Default ([int]1)
            $result = Test-DialogComparisonSpec -Spec $Condition -Actual $actualCount -DefaultOperator 'ge' -DefaultExpected $requiredCount
        }
        'quest' {
            $questName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Quest', 'QuestId', 'Flag'))
            $actualValue = Get-DialogQuestValue -Session $Session -Name $questName
            $expectedValue = Get-DialogValue -Source $Condition -Names @('Expected', 'Value', 'State') -Default $true
            $operator = Get-DialogValue -Source $Condition -Names @('Operator', 'Op') -Default 'eq'
            $result = Compare-DialogValues -Actual $actualValue -Expected $expectedValue -Operator $operator
        }
        'questflag' {
            $questName = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Quest', 'QuestId', 'Flag'))
            $actualValue = Get-DialogQuestValue -Session $Session -Name $questName
            $expectedValue = Get-DialogValue -Source $Condition -Names @('Expected', 'Value', 'State') -Default $true
            $operator = Get-DialogValue -Source $Condition -Names @('Operator', 'Op') -Default 'eq'
            $result = Compare-DialogValues -Actual $actualValue -Expected $expectedValue -Operator $operator
        }
        'reputation' {
            [int]$actualRep = [int](Get-DialogReputationValue -Session $Session)
            $result = Test-DialogComparisonSpec -Spec $Condition -Actual $actualRep -DefaultOperator 'ge'
        }
        default {
            $actualValue = Get-DialogValue -Source $Condition -Names @('Actual', 'Left')

            if ($null -eq $actualValue) {
                $name = [string](Get-DialogValue -Source $Condition -Names @('Name', 'Key'))
                if (-not [string]::IsNullOrWhiteSpace($name) -and $null -ne $Session -and $null -ne $Session.Context) {
                    $actualValue = Get-DialogValue -Source $Session.Context.Data -Names @($name)
                }
            }

            $expectedValue = Get-DialogValue -Source $Condition -Names @('Expected', 'Value')
            if ($null -eq $expectedValue) {
                $result = [bool]$actualValue
            }
            else {
                $operator = Get-DialogValue -Source $Condition -Names @('Operator', 'Op') -Default 'eq'
                $result = Compare-DialogValues -Actual $actualValue -Expected $expectedValue -Operator $operator
            }
        }
    }

    $negateCondition = Get-DialogValue -Source $Condition -Names @('Not', 'Negate') -Default $false
    if ([bool]$negateCondition) {
        return (-not $result)
    }

    return $result
}

function Test-DialogConditions {
    param(
        [object[]]$Conditions,
        $Session
    )

    foreach ($condition in @($Conditions)) {
        if (-not (Test-DialogCondition -Condition $condition -Session $Session)) {
            return $false
        }
    }

    return $true
}

# ============================================================================
# Internal Helpers - Effects/Consequences
# ============================================================================

function Invoke-DialogEffect {
    param(
        $Effect,
        $Session
    )

    if ($null -eq $Effect) {
        return [PSCustomObject]@{
            Success = $false
            Type    = 'None'
            Detail  = 'Effect is null.'
            Data    = $null
        }
    }

    if ($Effect -is [ScriptBlock]) {
        try {
            $output = & $Effect $Session $Session.Context
            return [PSCustomObject]@{
                Success = $true
                Type    = 'Script'
                Detail  = 'Script effect executed.'
                Data    = $output
            }
        }
        catch {
            return [PSCustomObject]@{
                Success = $false
                Type    = 'Script'
                Detail  = $_.Exception.Message
                Data    = $null
            }
        }
    }

    $handler = Get-DialogValue -Source $Effect -Names @('Handler', 'Script', 'Action')
    if ($handler -is [ScriptBlock]) {
        try {
            $output = & $handler $Session $Session.Context $Effect
            return [PSCustomObject]@{
                Success = $true
                Type    = 'Script'
                Detail  = 'Script effect executed.'
                Data    = $output
            }
        }
        catch {
            return [PSCustomObject]@{
                Success = $false
                Type    = 'Script'
                Detail  = $_.Exception.Message
                Data    = $null
            }
        }
    }

    $type = [string](Get-DialogValue -Source $Effect -Names @('Type', 'Kind', 'EffectType') -Default '')
    if ([string]::IsNullOrWhiteSpace($type)) {
        if ($null -ne (Get-DialogValue -Source $Effect -Names @('Item', 'ItemName'))) {
            $type = 'item'
        }
        elseif ($null -ne (Get-DialogValue -Source $Effect -Names @('Quest', 'QuestId', 'Flag'))) {
            $type = 'quest'
        }
        elseif ($null -ne (Get-DialogValue -Source $Effect -Names @('Stat', 'StatName'))) {
            $type = 'stat'
        }
        elseif ($null -ne (Get-DialogValue -Source $Effect -Names @('Reputation'))) {
            $type = 'reputation'
        }
    }

    $type = $type.Trim().ToLowerInvariant()

    switch ($type) {
        'reputation' {
            $mode = [string](Get-DialogValue -Source $Effect -Names @('Mode', 'Operation', 'Action') -Default 'Add')
            $mode = $mode.Trim().ToLowerInvariant()

            [int]$value = [int]0
            try {
                $value = [int](Get-DialogValue -Source $Effect -Names @('Delta', 'Amount', 'Value') -Default 0)
            }
            catch {
                $value = [int]0
            }

            [int]$updated = [int]0
            if ($mode -eq 'set') {
                $updated = [int]$value
                Set-DialogReputationValue -Session $Session -Value $updated
            }
            else {
                $updated = [int](Add-DialogReputationValue -Session $Session -Delta $value)
            }

            return [PSCustomObject]@{
                Success = $true
                Type    = 'Reputation'
                Detail  = "Reputation is now $updated."
                Data    = [PSCustomObject]@{
                    Reputation = [int]$updated
                }
            }
        }
        'item' {
            $itemName = [string](Get-DialogValue -Source $Effect -Names @('Name', 'Item', 'ItemName'))
            if ([string]::IsNullOrWhiteSpace($itemName)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Item'
                    Detail  = 'Missing item name.'
                    Data    = $null
                }
            }

            [int]$count = [int]1
            try {
                $count = [int](Get-DialogValue -Source $Effect -Names @('Count', 'Amount', 'Delta', 'Value') -Default 1)
            }
            catch {
                $count = [int]1
            }

            $mode = [string](Get-DialogValue -Source $Effect -Names @('Mode', 'Operation', 'Action') -Default '')
            if ([string]::IsNullOrWhiteSpace($mode)) {
                if ($count -lt 0) {
                    $mode = 'remove'
                }
                else {
                    $mode = 'add'
                }
            }

            $mode = $mode.Trim().ToLowerInvariant()
            if ($count -lt 0) {
                $count = [int]([System.Math]::Abs($count))
            }

            $applied = $true
            if ($mode -eq 'remove') {
                if (Get-Command -Name Remove-InventoryItem -ErrorAction SilentlyContinue) {
                    try {
                        $applied = [bool](Remove-InventoryItem -Name $itemName -Count $count)
                    }
                    catch {
                        $applied = $false
                    }
                }

                [int]$currentCount = [int](Get-DialogItemCount -Session $Session -Name $itemName)
                [int]$newCount = [int]($currentCount - $count)
                if ($newCount -lt 0) { $newCount = [int]0 }
                Set-DialogItemCount -Session $Session -Name $itemName -Count $newCount
            }
            else {
                if (Get-Command -Name Add-InventoryItem -ErrorAction SilentlyContinue) {
                    try {
                        $applied = [bool](Add-InventoryItem -Name $itemName -Count $count)
                    }
                    catch {
                        $applied = $false
                    }
                }

                [int]$currentCount = [int](Get-DialogItemCount -Session $Session -Name $itemName)
                Set-DialogItemCount -Session $Session -Name $itemName -Count ([int]($currentCount + $count))
            }

            [int]$updatedCount = [int](Get-DialogItemCount -Session $Session -Name $itemName)
            return [PSCustomObject]@{
                Success = [bool]$applied
                Type    = 'Item'
                Detail  = "$itemName count is now $updatedCount."
                Data    = [PSCustomObject]@{
                    Name  = [string]$itemName
                    Count = [int]$updatedCount
                    Mode  = [string]$mode
                }
            }
        }
        'quest' {
            $questName = [string](Get-DialogValue -Source $Effect -Names @('Name', 'Quest', 'QuestId', 'Flag'))
            if ([string]::IsNullOrWhiteSpace($questName)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Quest'
                    Detail  = 'Missing quest/flag name.'
                    Data    = $null
                }
            }

            $questValue = Get-DialogValue -Source $Effect -Names @('Value', 'State', 'SetTo') -Default $true
            Set-DialogQuestValue -Session $Session -Name $questName -Value $questValue

            return [PSCustomObject]@{
                Success = $true
                Type    = 'Quest'
                Detail  = "Quest flag '$questName' updated."
                Data    = [PSCustomObject]@{
                    Name  = [string]$questName
                    Value = $questValue
                }
            }
        }
        'questflag' {
            $questName = [string](Get-DialogValue -Source $Effect -Names @('Name', 'Quest', 'QuestId', 'Flag'))
            if ([string]::IsNullOrWhiteSpace($questName)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Quest'
                    Detail  = 'Missing quest/flag name.'
                    Data    = $null
                }
            }

            $questValue = Get-DialogValue -Source $Effect -Names @('Value', 'State', 'SetTo') -Default $true
            Set-DialogQuestValue -Session $Session -Name $questName -Value $questValue

            return [PSCustomObject]@{
                Success = $true
                Type    = 'Quest'
                Detail  = "Quest flag '$questName' updated."
                Data    = [PSCustomObject]@{
                    Name  = [string]$questName
                    Value = $questValue
                }
            }
        }
        'stat' {
            $statName = [string](Get-DialogValue -Source $Effect -Names @('Name', 'Stat', 'StatName'))
            if ([string]::IsNullOrWhiteSpace($statName)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Stat'
                    Detail  = 'Missing stat name.'
                    Data    = $null
                }
            }

            $mode = [string](Get-DialogValue -Source $Effect -Names @('Mode', 'Operation', 'Action') -Default 'Add')
            $mode = $mode.Trim().ToLowerInvariant()

            $delta = Get-DialogValue -Source $Effect -Names @('Delta', 'Amount') -Default $null
            $setValue = Get-DialogValue -Source $Effect -Names @('Value', 'SetTo') -Default $null

            $current = Get-DialogStatValue -Session $Session -Name $statName
            if ($null -eq $current) {
                $current = [int]0
            }

            if ($mode -eq 'set' -and $null -ne $setValue) {
                Set-DialogStatValue -Session $Session -Name $statName -Value $setValue

                if ($statName -eq 'HP' -and (Get-Command -Name Set-PlayerHP -ErrorAction SilentlyContinue)) {
                    try { Set-PlayerHP $setValue | Out-Null } catch { }
                }
                elseif ($statName -eq 'Mana' -and (Get-Command -Name Set-PlayerMana -ErrorAction SilentlyContinue)) {
                    try { Set-PlayerMana $setValue | Out-Null } catch { }
                }
                elseif ($statName -eq 'Stamina' -and (Get-Command -Name Set-PlayerStamina -ErrorAction SilentlyContinue)) {
                    try { Set-PlayerStamina $setValue | Out-Null } catch { }
                }
            }
            else {
                if ($null -eq $delta) {
                    $delta = Get-DialogValue -Source $Effect -Names @('Value', 'Amount') -Default 0
                }

                [double]$nextValue = [double]$current + [double]$delta
                Set-DialogStatValue -Session $Session -Name $statName -Value $nextValue

                if ($statName -eq 'HP' -and (Get-Command -Name Add-PlayerHP -ErrorAction SilentlyContinue)) {
                    try { Add-PlayerHP $delta | Out-Null } catch { }
                }
                elseif ($statName -eq 'Mana' -and (Get-Command -Name Add-PlayerMana -ErrorAction SilentlyContinue)) {
                    try { Add-PlayerMana $delta | Out-Null } catch { }
                }
                elseif ($statName -eq 'Stamina' -and (Get-Command -Name Add-PlayerStamina -ErrorAction SilentlyContinue)) {
                    try { Add-PlayerStamina $delta | Out-Null } catch { }
                }
            }

            $updatedStatValue = Get-DialogStatValue -Session $Session -Name $statName
            return [PSCustomObject]@{
                Success = $true
                Type    = 'Stat'
                Detail  = "$statName updated to $updatedStatValue."
                Data    = [PSCustomObject]@{
                    Name  = [string]$statName
                    Value = $updatedStatValue
                }
            }
        }
        'data' {
            $key = [string](Get-DialogValue -Source $Effect -Names @('Key', 'Name'))
            $value = Get-DialogValue -Source $Effect -Names @('Value')

            if ([string]::IsNullOrWhiteSpace($key)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Data'
                    Detail  = 'Missing data key.'
                    Data    = $null
                }
            }

            if ($null -ne $Session -and $null -ne $Session.Context) {
                if ($null -eq $Session.Context.Data) {
                    $Session.Context.Data = @{}
                }

                if ($Session.Context.Data -is [System.Collections.IDictionary]) {
                    $Session.Context.Data[[string]$key] = $value
                }
            }

            return [PSCustomObject]@{
                Success = $true
                Type    = 'Data'
                Detail  = "Data key '$key' updated."
                Data    = [PSCustomObject]@{
                    Key   = [string]$key
                    Value = $value
                }
            }
        }
        'set' {
            $key = [string](Get-DialogValue -Source $Effect -Names @('Key', 'Name'))
            $value = Get-DialogValue -Source $Effect -Names @('Value')

            if ([string]::IsNullOrWhiteSpace($key)) {
                return [PSCustomObject]@{
                    Success = $false
                    Type    = 'Data'
                    Detail  = 'Missing data key.'
                    Data    = $null
                }
            }

            if ($null -ne $Session -and $null -ne $Session.Context) {
                if ($null -eq $Session.Context.Data) {
                    $Session.Context.Data = @{}
                }

                if ($Session.Context.Data -is [System.Collections.IDictionary]) {
                    $Session.Context.Data[[string]$key] = $value
                }
            }

            return [PSCustomObject]@{
                Success = $true
                Type    = 'Data'
                Detail  = "Data key '$key' updated."
                Data    = [PSCustomObject]@{
                    Key   = [string]$key
                    Value = $value
                }
            }
        }
        default {
            $key = [string](Get-DialogValue -Source $Effect -Names @('Key', 'Name'))
            $value = Get-DialogValue -Source $Effect -Names @('Value')

            if (-not [string]::IsNullOrWhiteSpace($key) -and $null -ne $Session -and $null -ne $Session.Context) {
                if ($null -eq $Session.Context.Data) {
                    $Session.Context.Data = @{}
                }

                if ($Session.Context.Data -is [System.Collections.IDictionary]) {
                    $Session.Context.Data[[string]$key] = $value
                }

                return [PSCustomObject]@{
                    Success = $true
                    Type    = 'Data'
                    Detail  = "Data key '$key' updated."
                    Data    = [PSCustomObject]@{
                        Key   = [string]$key
                        Value = $value
                    }
                }
            }

            return [PSCustomObject]@{
                Success = $false
                Type    = 'Unknown'
                Detail  = 'Unsupported effect type.'
                Data    = $null
            }
        }
    }
}

function Invoke-DialogEffects {
    param(
        [object[]]$Effects,
        $Session
    )

    $results = @()
    foreach ($effect in @($Effects)) {
        $results += (Invoke-DialogEffect -Effect $effect -Session $Session)
    }

    return ,$results
}

# ============================================================================
# Public API
# ============================================================================

function Initialize-DialogSystem {
    <#
    .SYNOPSIS
        Initializes dialog system state.
    #>

    $script:DialogInitialized = $true
    $script:DialogTrees = @{}
    $script:DialogNextTreeId = [int]1
    $script:ActiveDialogSession = $null
    $script:DialogQuestFlags = @{}
    $script:DialogFallbackReputation = [int]0

    Write-Host "[Dialog] Dialog system initialized." -ForegroundColor Green
}

function New-DialogTree {
    <#
    .SYNOPSIS
        Creates and registers a new dialog tree.
    #>
    param(
        [string]$TreeId = '',
        [string]$Name = '',
        [string]$StartNodeId = ''
    )

    if ([string]::IsNullOrWhiteSpace($TreeId)) {
        $TreeId = "DialogTree_$($script:DialogNextTreeId)"
        $script:DialogNextTreeId++
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = $TreeId
    }

    $tree = [PSCustomObject]@{
        Id          = [string]$TreeId
        Name        = [string]$Name
        StartNodeId = [string]$StartNodeId
        Nodes       = @{}
        Metadata    = @{}
    }

    $script:DialogTrees[(Normalize-DialogKey -Value $TreeId)] = $tree
    return $tree
}

function Get-DialogTree {
    <#
    .SYNOPSIS
        Gets a dialog tree by id, or returns tree input directly.
    #>
    param([Parameter(Mandatory = $true)]$Tree)

    return (Resolve-DialogTree -Tree $Tree)
}

function Add-DialogNode {
    <#
    .SYNOPSIS
        Adds or updates a node in a dialog tree.
    #>
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [string]$NodeId = '',
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Speaker = 'NPC',
        [switch]$IsEnd,
        $Metadata = $null
    )

    $treeObj = Resolve-DialogTree -Tree $Tree
    if ($null -eq $treeObj) {
        Write-Warning '[Dialog] Add-DialogNode failed: tree not found.'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($NodeId)) {
        [int]$index = [int]($treeObj.Nodes.Count + 1)
        $NodeId = "Node_$index"

        while ($treeObj.Nodes.ContainsKey((Normalize-DialogKey -Value $NodeId))) {
            $index++
            $NodeId = "Node_$index"
        }
    }

    $existingNode = Resolve-DialogNode -Tree $treeObj -NodeId $NodeId
    if ($null -ne $existingNode) {
        $existingNode.Text = [string]$Text
        $existingNode.Speaker = [string]$Speaker
        $existingNode.IsEnd = [bool]$IsEnd
        if ($null -ne $Metadata) {
            $existingNode.Metadata = $Metadata
        }
        return $existingNode
    }

    $node = [PSCustomObject]@{
        Id       = [string]$NodeId
        Text     = [string]$Text
        Speaker  = [string]$Speaker
        IsEnd    = [bool]$IsEnd
        Options  = @()
        Metadata = $Metadata
    }

    $treeObj.Nodes[(Normalize-DialogKey -Value $NodeId)] = $node

    if ([string]::IsNullOrWhiteSpace([string]$treeObj.StartNodeId)) {
        $treeObj.StartNodeId = [string]$NodeId
    }

    return $node
}

function Get-DialogNode {
    <#
    .SYNOPSIS
        Gets a dialog node from a tree.
    #>
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [Parameter(Mandatory = $true)][string]$NodeId
    )

    $treeObj = Resolve-DialogTree -Tree $Tree
    if ($null -eq $treeObj) {
        return $null
    }

    return (Resolve-DialogNode -Tree $treeObj -NodeId $NodeId)
}

function Add-DialogOption {
    <#
    .SYNOPSIS
        Adds an option/response to a dialog node.
    .DESCRIPTION
        Supports conditions and effects as arrays of:
        - ScriptBlock predicates/effects, or
        - Simple objects (hashtable/PSCustomObject) with Type + fields.

        Condition examples:
            @{ Type='Stat'; Name='Charisma'; Min=5 }
            @{ Type='Item'; Name='Potion'; Count=1 }
            @{ Type='Quest'; Name='blacksmith_intro'; Expected=$true }

        Effect examples:
            @{ Type='Reputation'; Delta=2 }
            @{ Type='Item'; Name='Gold'; Count=10; Mode='Add' }
            @{ Type='Quest'; Name='blacksmith_intro'; Value=$true }
    #>
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$NextNodeId = '',
        [string]$OptionId = '',
        [object[]]$Conditions = @(),
        [object[]]$Effects = @(),
        [switch]$EndDialog,
        [switch]$ShowWhenUnavailable,
        $Metadata = $null
    )

    $treeObj = Resolve-DialogTree -Tree $Tree
    if ($null -eq $treeObj) {
        Write-Warning '[Dialog] Add-DialogOption failed: tree not found.'
        return $null
    }

    $node = Resolve-DialogNode -Tree $treeObj -NodeId $NodeId
    if ($null -eq $node) {
        Write-Warning "[Dialog] Add-DialogOption failed: node '$NodeId' not found."
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($OptionId)) {
        [int]$index = [int]($node.Options.Count + 1)
        $OptionId = "Option_$index"
    }

    $option = [PSCustomObject]@{
        Id                    = [string]$OptionId
        Text                  = [string]$Text
        NextNodeId            = [string]$NextNodeId
        EndDialog             = [bool]$EndDialog
        HiddenWhenUnavailable = [bool](-not $ShowWhenUnavailable)
        Conditions            = @($Conditions)
        Effects               = @($Effects)
        Metadata              = $Metadata
    }

    $node.Options += $option
    return $option
}

function Get-DialogOptions {
    <#
    .SYNOPSIS
        Returns dialog options for a node, respecting conditions.
    #>
    param(
        $Tree = $null,
        [string]$NodeId = '',
        $Session = $null,
        [switch]$IncludeUnavailable
    )

    $sessionObj = Get-DialogSessionInternal -Session $Session

    $treeObj = $null
    if ($null -ne $Tree) {
        $treeObj = Resolve-DialogTree -Tree $Tree
    }
    elseif ($null -ne $sessionObj) {
        $treeObj = Resolve-DialogTree -Tree $sessionObj.TreeId
    }

    if ($null -eq $treeObj) {
        return ,@()
    }

    if ([string]::IsNullOrWhiteSpace($NodeId)) {
        if ($null -ne $sessionObj -and -not [string]::IsNullOrWhiteSpace([string]$sessionObj.CurrentNodeId)) {
            $NodeId = [string]$sessionObj.CurrentNodeId
        }
        else {
            $NodeId = [string]$treeObj.StartNodeId
        }
    }

    $node = Resolve-DialogNode -Tree $treeObj -NodeId $NodeId
    if ($null -eq $node) {
        return ,@()
    }

    $result = @()
    [int]$visibleIndex = [int]1

    foreach ($option in @($node.Options)) {
        [bool]$isAvailable = Test-DialogConditions -Conditions @($option.Conditions) -Session $sessionObj

        if ($isAvailable -or $IncludeUnavailable -or (-not [bool]$option.HiddenWhenUnavailable)) {
            $result += [PSCustomObject]@{
                Index       = [int]$visibleIndex
                Id          = [string]$option.Id
                Text        = [string]$option.Text
                NextNodeId  = [string]$option.NextNodeId
                EndDialog   = [bool]$option.EndDialog
                IsAvailable = [bool]$isAvailable
                Option      = $option
            }
            $visibleIndex++
        }
    }

    return ,$result
}

function Get-DialogDisplayModel {
    <#
    .SYNOPSIS
        Builds a text-only dialog display model for the current node.
    .DESCRIPTION
        Returns speaker text and response options in a UI-agnostic shape that can
        be consumed by console, HUD, or test flows.
    #>
    param(
        $Tree = $null,
        [string]$NodeId = '',
        $Session = $null,
        [switch]$IncludeUnavailable
    )

    $sessionObj = Get-DialogSessionInternal -Session $Session

    $treeObj = $null
    if ($null -ne $Tree) {
        $treeObj = Resolve-DialogTree -Tree $Tree
    }
    elseif ($null -ne $sessionObj) {
        $treeObj = Resolve-DialogTree -Tree $sessionObj.TreeId
    }

    if ($null -eq $treeObj) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($NodeId)) {
        if ($null -ne $sessionObj -and -not [string]::IsNullOrWhiteSpace([string]$sessionObj.CurrentNodeId)) {
            $NodeId = [string]$sessionObj.CurrentNodeId
        }
        else {
            $NodeId = [string]$treeObj.StartNodeId
        }
    }

    if ([string]::IsNullOrWhiteSpace($NodeId)) {
        $firstNode = Get-DialogFirstNode -Tree $treeObj
        if ($null -ne $firstNode) {
            $NodeId = [string]$firstNode.Id
        }
    }

    $node = Resolve-DialogNode -Tree $treeObj -NodeId $NodeId
    if ($null -eq $node) {
        return $null
    }

    $optionEntries = Get-DialogOptions -Tree $treeObj -NodeId $node.Id -Session $sessionObj -IncludeUnavailable:$IncludeUnavailable
    $displayOptions = @()

    foreach ($entry in @($optionEntries)) {
        $displayOptions += [PSCustomObject]@{
            Index       = [int]$entry.Index
            Id          = [string]$entry.Id
            Text        = [string]$entry.Text
            IsAvailable = [bool]$entry.IsAvailable
            EndDialog   = [bool]$entry.EndDialog
        }
    }

    return [PSCustomObject]@{
        TreeId          = [string]$treeObj.Id
        NodeId          = [string]$node.Id
        Speaker         = [string]$node.Speaker
        Text            = [string]$node.Text
        IsEnd           = [bool]$node.IsEnd
        IsSessionActive = [bool]($null -ne $sessionObj -and $sessionObj.IsActive)
        OptionCount     = [int]$displayOptions.Count
        Options         = $displayOptions
    }
}

function Get-ActiveDialogSession {
    <#
    .SYNOPSIS
        Returns the current active dialog session (or $null).
    #>

    return $script:ActiveDialogSession
}

function Start-Dialog {
    <#
    .SYNOPSIS
        Starts a runtime dialog session for a tree.
    #>
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [string]$StartNodeId = '',
        [string]$NPCId = '',
        $Context = $null
    )

    $treeObj = Resolve-DialogTree -Tree $Tree
    if ($null -eq $treeObj) {
        Write-Warning '[Dialog] Start-Dialog failed: tree not found.'
        return $null
    }

    $nodeId = $StartNodeId
    if ([string]::IsNullOrWhiteSpace($nodeId)) {
        $nodeId = [string]$treeObj.StartNodeId
    }

    if ([string]::IsNullOrWhiteSpace($nodeId)) {
        $firstNode = Get-DialogFirstNode -Tree $treeObj
        if ($null -ne $firstNode) {
            $nodeId = [string]$firstNode.Id
        }
    }

    $startNode = Resolve-DialogNode -Tree $treeObj -NodeId $nodeId
    if ($null -eq $startNode) {
        Write-Warning '[Dialog] Start-Dialog failed: start node not found.'
        return $null
    }

    $session = [PSCustomObject]@{
        IsActive         = $true
        Completed        = $false
        CompletionReason = ''
        TreeId           = [string]$treeObj.Id
        NPCId            = [string]$NPCId
        CurrentNodeId    = [string]$startNode.Id
        LastOptionId     = ''
        History          = @()
        StartedAt        = [datetime]::UtcNow
        EndedAt          = $null
        Context          = (New-DialogContext -InputContext $Context)
    }

    $script:ActiveDialogSession = $session

    return [PSCustomObject]@{
        Session = $session
        Tree    = $treeObj
        Node    = $startNode
        Options = (Get-DialogOptions -Tree $treeObj -NodeId $startNode.Id -Session $session)
    }
}

function Stop-Dialog {
    <#
    .SYNOPSIS
        Stops the active dialog session.
    #>
    param(
        $Session = $null,
        [string]$Reason = 'Stopped'
    )

    $sessionObj = Get-DialogSessionInternal -Session $Session
    if ($null -eq $sessionObj) {
        return $false
    }

    Complete-DialogSession -Session $sessionObj -Reason $Reason
    return $true
}

function Choose-DialogOption {
    <#
    .SYNOPSIS
        Selects a player response option and advances dialog state.
    .DESCRIPTION
        Selection can be:
        - 1-based index (recommended)
        - 0-based index
        - option id string
        - exact option text string
    #>
    param(
        [Parameter(Mandatory = $true)]$Selection,
        $Session = $null
    )

    $sessionObj = Get-DialogSessionInternal -Session $Session
    if ($null -eq $sessionObj -or -not $sessionObj.IsActive) {
        return [PSCustomObject]@{
            Success = $false
            Ended   = $true
            Reason  = 'NoActiveDialog'
            Session = $sessionObj
        }
    }

    $treeObj = Resolve-DialogTree -Tree $sessionObj.TreeId
    if ($null -eq $treeObj) {
        Complete-DialogSession -Session $sessionObj -Reason 'TreeMissing'
        return [PSCustomObject]@{
            Success = $false
            Ended   = $true
            Reason  = 'TreeMissing'
            Session = $sessionObj
        }
    }

    $currentNode = Resolve-DialogNode -Tree $treeObj -NodeId $sessionObj.CurrentNodeId
    if ($null -eq $currentNode) {
        Complete-DialogSession -Session $sessionObj -Reason 'CurrentNodeMissing'
        return [PSCustomObject]@{
            Success = $false
            Ended   = $true
            Reason  = 'CurrentNodeMissing'
            Session = $sessionObj
        }
    }

    $availableOptions = Get-DialogOptions -Tree $treeObj -NodeId $currentNode.Id -Session $sessionObj
    if ($availableOptions.Count -le 0) {
        Complete-DialogSession -Session $sessionObj -Reason 'NoAvailableOptions'
        return [PSCustomObject]@{
            Success = $false
            Ended   = $true
            Reason  = 'NoAvailableOptions'
            Session = $sessionObj
        }
    }

    $selected = $null

    [int]$selectionNumber = [int]0
    $isNumericSelection = [int]::TryParse([string]$Selection, [ref]$selectionNumber)

    if ($isNumericSelection) {
        if ($selectionNumber -ge 1 -and $selectionNumber -le $availableOptions.Count) {
            $selected = $availableOptions[$selectionNumber - 1]
        }
        elseif ($selectionNumber -ge 0 -and $selectionNumber -lt $availableOptions.Count) {
            $selected = $availableOptions[$selectionNumber]
        }
    }

    if ($null -eq $selected) {
        $selectionText = [string]$Selection

        foreach ($entry in $availableOptions) {
            if ([string]::Equals([string]$entry.Id, $selectionText, [System.StringComparison]::OrdinalIgnoreCase)) {
                $selected = $entry
                break
            }
        }

        if ($null -eq $selected) {
            foreach ($entry in $availableOptions) {
                if ([string]::Equals([string]$entry.Text, $selectionText, [System.StringComparison]::Ordinal)) {
                    $selected = $entry
                    break
                }
            }
        }
    }

    if ($null -eq $selected) {
        return [PSCustomObject]@{
            Success = $false
            Ended   = $false
            Reason  = 'OptionNotFound'
            Session = $sessionObj
            Node    = $currentNode
            Options = $availableOptions
        }
    }

    if (-not $selected.IsAvailable) {
        return [PSCustomObject]@{
            Success = $false
            Ended   = $false
            Reason  = 'OptionUnavailable'
            Session = $sessionObj
            Node    = $currentNode
            Options = $availableOptions
        }
    }

    $option = $selected.Option
    $effectResults = Invoke-DialogEffects -Effects @($option.Effects) -Session $sessionObj

    $historyEntry = [PSCustomObject]@{
        Timestamp = [datetime]::UtcNow
        NodeId    = [string]$currentNode.Id
        OptionId  = [string]$option.Id
        Text      = [string]$option.Text
        Effects   = $effectResults
    }

    $sessionObj.History += $historyEntry
    $sessionObj.LastOptionId = [string]$option.Id

    [bool]$shouldEnd = [bool]$option.EndDialog
    $nextNodeId = [string]$option.NextNodeId

    if ([string]::IsNullOrWhiteSpace($nextNodeId)) {
        $shouldEnd = $true
    }

    if ($shouldEnd) {
        Complete-DialogSession -Session $sessionObj -Reason 'OptionEndedDialog'

        return [PSCustomObject]@{
            Success        = $true
            Ended          = $true
            Reason         = 'OptionEndedDialog'
            Session        = $sessionObj
            SelectedOption = $option
            Effects        = $effectResults
            Node           = $null
            Options        = @()
        }
    }

    $nextNode = Resolve-DialogNode -Tree $treeObj -NodeId $nextNodeId
    if ($null -eq $nextNode) {
        Complete-DialogSession -Session $sessionObj -Reason 'NextNodeMissing'

        return [PSCustomObject]@{
            Success        = $true
            Ended          = $true
            Reason         = 'NextNodeMissing'
            Session        = $sessionObj
            SelectedOption = $option
            Effects        = $effectResults
            Node           = $null
            Options        = @()
        }
    }

    $sessionObj.CurrentNodeId = [string]$nextNode.Id

    if ($nextNode.IsEnd) {
        Complete-DialogSession -Session $sessionObj -Reason 'ReachedEndNode'

        return [PSCustomObject]@{
            Success        = $true
            Ended          = $true
            Reason         = 'ReachedEndNode'
            Session        = $sessionObj
            SelectedOption = $option
            Effects        = $effectResults
            Node           = $nextNode
            Options        = @()
        }
    }

    $nextOptions = Get-DialogOptions -Tree $treeObj -NodeId $nextNode.Id -Session $sessionObj
    if ($nextOptions.Count -le 0) {
        Complete-DialogSession -Session $sessionObj -Reason 'NoAvailableOptions'

        return [PSCustomObject]@{
            Success        = $true
            Ended          = $true
            Reason         = 'NoAvailableOptions'
            Session        = $sessionObj
            SelectedOption = $option
            Effects        = $effectResults
            Node           = $nextNode
            Options        = @()
        }
    }

    return [PSCustomObject]@{
        Success        = $true
        Ended          = $false
        Reason         = 'Advanced'
        Session        = $sessionObj
        SelectedOption = $option
        Effects        = $effectResults
        Node           = $nextNode
        Options        = $nextOptions
    }
}
