. "$PSScriptRoot\..\Engine\Math.ps1"

# Test 1: Vector3-Cross
$v1 = New-Vector3 1 0 0
$v2 = New-Vector3 0 1 0
$cross = Vector3-Cross $v1 $v2
Write-Host "Test 1 - Cross: ($($cross.X), $($cross.Y), $($cross.Z))"
if ($cross.Z -ne 1) { Write-Host "FAIL: Cross Z should be 1" -ForegroundColor Red; exit 1 }
Write-Host "PASS" -ForegroundColor Green

# Test 2: Identity diagonal
$id = Matrix4-Identity
Write-Host "Test 2 - Identity: $($id.M[0]), $($id.M[5]), $($id.M[10]), $($id.M[15])"
if ($id.M[0] -ne 1 -or $id.M[5] -ne 1 -or $id.M[10] -ne 1 -or $id.M[15] -ne 1) { Write-Host "FAIL" -ForegroundColor Red; exit 1 }
Write-Host "PASS" -ForegroundColor Green

# Test 3: Perspective
$p = Matrix4-Perspective ([Math]::PI/3) (4.0/3.0) 0.1 100.0
Write-Host "Test 3 - Perspective M[0]=$($p.M[0]), M[5]=$($p.M[5]), M[11]=$($p.M[11])"
if ($p.M[0] -eq 0 -or $p.M[5] -eq 0 -or $p.M[11] -ne -1) { Write-Host "FAIL" -ForegroundColor Red; exit 1 }
Write-Host "PASS" -ForegroundColor Green

# Test 4: Normalize
$n = Vector3-Normalize (New-Vector3 3 0 0)
Write-Host "Test 4 - Normalize (3,0,0): ($($n.X), $($n.Y), $($n.Z))"
if ([Math]::Abs($n.X - 1.0) -gt 0.001) { Write-Host "FAIL" -ForegroundColor Red; exit 1 }
Write-Host "PASS" -ForegroundColor Green

# Test 5: Matrix4-ToFloatArray type
$fa = Matrix4-ToFloatArray $id
Write-Host "Test 5 - FloatArray type: $($fa.GetType().FullName), length: $($fa.Length)"
if ($fa.GetType().FullName -ne 'System.Single[]') { Write-Host "FAIL: wrong type" -ForegroundColor Red; exit 1 }
Write-Host "PASS" -ForegroundColor Green

Write-Host "`nAll Math.ps1 tests passed!" -ForegroundColor Cyan
