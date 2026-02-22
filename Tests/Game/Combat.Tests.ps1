Describe 'Game/Combat.ps1' {
    BeforeAll {
        function Register-UpdateCallback { param($Callback) }
        function Register-RenderCallback { param($Callback) }
        function Get-KeyDown { param($Key) return $false }
        function Get-MouseButton { param([int]$Button) return $false }
        function Get-PlayerStats { return $script:TestPlayerStats }
        function Get-WeaponDamage { param([string]$WeaponName) if ($WeaponName -eq 'iron_sword') { return 10 } return 2 }
        function Get-EquipmentStats { return [PSCustomObject]@{ TotalDefense = 2; TotalDamage = 10 } }
        function Get-EquippedItem { param([string]$Slot) return 'iron_sword' }
        function Get-ItemDefinition { param([string]$Name) return [PSCustomObject]@{ AttackSpeed = 2.0 } }
        function Invoke-DurabilityUse { param([string]$ItemName) return $true }
        function Add-PlayerHP { param([float]$Delta) $script:TestPlayerHP += $Delta }

        . "$PSScriptRoot\..\..\Engine\Math.ps1"
        . "$PSScriptRoot\..\..\Game\Combat.ps1"
    }

    BeforeEach {
        $script:TestPlayerStats = [PSCustomObject]@{
            IsAlive = $true
            Strength = 2
        }
        $script:TestPlayerHP = [float]100
        $script:PlayerPosition = New-Vector3 -X 0 -Y 0 -Z 0
        Initialize-Combat
    }

    It 'finds nearest alive target in range' {
        $far = New-CombatEntity -Name 'far' -HP 10 -Position (New-Vector3 -X 2.2 -Y 0 -Z 0)
        $near = New-CombatEntity -Name 'near' -HP 10 -Position (New-Vector3 -X 1.2 -Y 0 -Z 0)
        Add-CombatEntity -Entity $far | Out-Null
        Add-CombatEntity -Entity $near | Out-Null

        $target = Get-NearestCombatTarget -Range 2.5

        $target.Name | Should -Be 'near'
    }

    It 'applies player attack damage and enters attacking state' {
        $enemy = New-CombatEntity -Name 'slime' -HP 20 -Defense 3 -Position (New-Vector3 -X 1.0 -Y 0 -Z 0)
        Add-CombatEntity -Entity $enemy | Out-Null

        $hit = Invoke-PlayerAttack

        $hit | Should -Be $true
        $enemy.HP | Should -Be 11
        (Get-CombatState) | Should -Be 'attacking'

        (Invoke-PlayerAttack) | Should -Be $false
    }

    It 'applies block mitigation when entity attacks player' {
        $attacker = New-CombatEntity -Name 'raider' -HP 30 -Damage 10 -Position (New-Vector3 -X 1 -Y 0 -Z 0) -AttackCooldownMax 1.5
        $script:PlayerCombatState = 'blocking'
        $script:PlayerBlockDamageReduction = 0.5

        Invoke-EntityAttack -Attacker $attacker -TargetIsPlayer $true

        $script:TestPlayerHP | Should -Be 96
        $attacker.AttackCooldown | Should -Be 1.5
    }
}
