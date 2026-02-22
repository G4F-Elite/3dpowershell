Describe 'Engine/Math.ps1' {
    BeforeAll {
        . "$PSScriptRoot\..\..\Engine\Math.ps1"
    }

    It 'computes a right-handed Vector3 cross product' {
        $a = New-Vector3 -X 1 -Y 0 -Z 0
        $b = New-Vector3 -X 0 -Y 1 -Z 0

        $cross = Vector3-Cross -A $a -B $b

        $cross.X | Should -Be 0
        $cross.Y | Should -Be 0
        $cross.Z | Should -Be 1
    }

    It 'normalizes non-zero vectors and preserves direction' {
        $n = Vector3-Normalize -V (New-Vector3 -X 3 -Y 0 -Z 0)

        $n.X | Should -Be 1
        $n.Y | Should -Be 0
        $n.Z | Should -Be 0
    }

    It 'returns zero vector for normalize(0,0,0)' {
        $n = Vector3-Normalize -V (New-Vector3)

        $n.X | Should -Be 0
        $n.Y | Should -Be 0
        $n.Z | Should -Be 0
    }

    It 'returns Matrix4-ToFloatArray as System.Single[] with copy semantics' {
        $identity = Matrix4-Identity
        $arr = Matrix4-ToFloatArray -Mat $identity

        $arr.GetType().FullName | Should -Be 'System.Single[]'
        $arr.Length | Should -Be 16

        $arr[0] = 42
        $identity.M[0] | Should -Be 1
    }

    It 'builds perspective matrix with expected OpenGL convention terms' {
        $p = Matrix4-Perspective -FovRadians ([Math]::PI / 3.0) -Aspect (4.0 / 3.0) -Near 0.1 -Far 100.0

        $p.M[0] | Should -BeGreaterThan 0
        $p.M[5] | Should -BeGreaterThan 0
        $p.M[11] | Should -Be -1
        $p.M[15] | Should -Be 0
    }
}
