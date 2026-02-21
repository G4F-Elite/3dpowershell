# ============================================================================
# Engine/Math.ps1 — 3D Math Utilities
# ============================================================================
# Vector2/3/4, Matrix4x4, Quaternion operations for the rendering engine.
# All matrices are column-major (OpenGL convention).
# All functions are pure — no script-scope mutation.
# ============================================================================

# ============================================================================
# Vector2
# ============================================================================

function New-Vector2 {
    param([float]$X = 0, [float]$Y = 0)
    [PSCustomObject]@{ X = $X; Y = $Y }
}

function Vector2-Add {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X + $B.X; Y = $A.Y + $B.Y }
}

function Vector2-Subtract {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X - $B.X; Y = $A.Y - $B.Y }
}

function Vector2-Multiply {
    param($V, [float]$S)
    [PSCustomObject]@{ X = $V.X * $S; Y = $V.Y * $S }
}

function Vector2-Length {
    param($V)
    [Math]::Sqrt($V.X * $V.X + $V.Y * $V.Y)
}

function Vector2-Normalize {
    param($V)
    $len = Vector2-Length $V
    if ($len -eq 0) { return New-Vector2 }
    [PSCustomObject]@{ X = $V.X / $len; Y = $V.Y / $len }
}

# ============================================================================
# Vector3
# ============================================================================

function New-Vector3 {
    param([float]$X = 0, [float]$Y = 0, [float]$Z = 0)
    [PSCustomObject]@{ X = $X; Y = $Y; Z = $Z }
}

function Vector3-Add {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X + $B.X; Y = $A.Y + $B.Y; Z = $A.Z + $B.Z }
}

function Vector3-Subtract {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X - $B.X; Y = $A.Y - $B.Y; Z = $A.Z - $B.Z }
}

function Vector3-Multiply {
    param($V, [float]$S)
    [PSCustomObject]@{ X = $V.X * $S; Y = $V.Y * $S; Z = $V.Z * $S }
}

function Vector3-Dot {
    param($A, $B)
    $A.X * $B.X + $A.Y * $B.Y + $A.Z * $B.Z
}

function Vector3-Cross {
    param($A, $B)
    [PSCustomObject]@{
        X = $A.Y * $B.Z - $A.Z * $B.Y
        Y = $A.Z * $B.X - $A.X * $B.Z
        Z = $A.X * $B.Y - $A.Y * $B.X
    }
}

function Vector3-Length {
    param($V)
    [Math]::Sqrt($V.X * $V.X + $V.Y * $V.Y + $V.Z * $V.Z)
}

function Vector3-Normalize {
    param($V)
    $len = Vector3-Length $V
    if ($len -eq 0) { return New-Vector3 }
    [PSCustomObject]@{ X = $V.X / $len; Y = $V.Y / $len; Z = $V.Z / $len }
}

function Vector3-Negate {
    param($V)
    [PSCustomObject]@{ X = -$V.X; Y = -$V.Y; Z = -$V.Z }
}

# ============================================================================
# Vector4
# ============================================================================

function New-Vector4 {
    param([float]$X = 0, [float]$Y = 0, [float]$Z = 0, [float]$W = 0)
    [PSCustomObject]@{ X = $X; Y = $Y; Z = $Z; W = $W }
}

function Vector4-Add {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X + $B.X; Y = $A.Y + $B.Y; Z = $A.Z + $B.Z; W = $A.W + $B.W }
}

function Vector4-Subtract {
    param($A, $B)
    [PSCustomObject]@{ X = $A.X - $B.X; Y = $A.Y - $B.Y; Z = $A.Z - $B.Z; W = $A.W - $B.W }
}

function Vector4-Multiply {
    param($V, [float]$S)
    [PSCustomObject]@{ X = $V.X * $S; Y = $V.Y * $S; Z = $V.Z * $S; W = $V.W * $S }
}

function Vector4-Dot {
    param($A, $B)
    $A.X * $B.X + $A.Y * $B.Y + $A.Z * $B.Z + $A.W * $B.W
}

function Vector4-Length {
    param($V)
    [Math]::Sqrt($V.X * $V.X + $V.Y * $V.Y + $V.Z * $V.Z + $V.W * $V.W)
}

function Vector4-Normalize {
    param($V)
    $len = Vector4-Length $V
    if ($len -eq 0) { return New-Vector4 }
    [PSCustomObject]@{ X = $V.X / $len; Y = $V.Y / $len; Z = $V.Z / $len; W = $V.W / $len }
}

# ============================================================================
# Matrix4x4 — Column-major [float[16]]
# ============================================================================
# Layout:
#   M[0]  M[4]  M[8]   M[12]     col0  col1  col2  col3
#   M[1]  M[5]  M[9]   M[13]
#   M[2]  M[6]  M[10]  M[14]
#   M[3]  M[7]  M[11]  M[15]
# ============================================================================

function New-Matrix4x4 {
    param([float[]]$M)
    if (-not $M) { $M = [float[]]::new(16) }
    [PSCustomObject]@{ M = $M }
}

function Matrix4-Identity {
    $m = [float[]]::new(16)
    $m[0] = 1; $m[5] = 1; $m[10] = 1; $m[15] = 1
    [PSCustomObject]@{ M = $m }
}

function Matrix4-ToFloatArray {
    param($Mat)
    $arr = [float[]]::new(16)
    [Array]::Copy($Mat.M, $arr, 16)
    ,$arr
}

function Matrix4-Multiply {
    param($A, $B)
    $r = [float[]]::new(16)
    $am = $A.M; $bm = $B.M
    for ($col = 0; $col -lt 4; $col++) {
        $c4 = $col * 4
        for ($row = 0; $row -lt 4; $row++) {
            $sum = [float]0
            for ($k = 0; $k -lt 4; $k++) {
                $sum += $am[$k * 4 + $row] * $bm[$c4 + $k]
            }
            $r[$c4 + $row] = $sum
        }
    }
    [PSCustomObject]@{ M = $r }
}

function Matrix4-MultiplyVector {
    param($Mat, $V)
    $m = $Mat.M
    [PSCustomObject]@{
        X = $m[0] * $V.X + $m[4] * $V.Y + $m[8]  * $V.Z + $m[12] * $V.W
        Y = $m[1] * $V.X + $m[5] * $V.Y + $m[9]  * $V.Z + $m[13] * $V.W
        Z = $m[2] * $V.X + $m[6] * $V.Y + $m[10] * $V.Z + $m[14] * $V.W
        W = $m[3] * $V.X + $m[7] * $V.Y + $m[11] * $V.Z + $m[15] * $V.W
    }
}

function Matrix4-Transpose {
    param($Mat)
    $m = $Mat.M
    $r = [float[]]::new(16)
    for ($col = 0; $col -lt 4; $col++) {
        for ($row = 0; $row -lt 4; $row++) {
            $r[$col * 4 + $row] = $m[$row * 4 + $col]
        }
    }
    [PSCustomObject]@{ M = $r }
}

# ============================================================================
# Matrix4 Creation Functions
# ============================================================================

function Matrix4-Translation {
    param([float]$X, [float]$Y, [float]$Z)
    $m = [float[]]::new(16)
    $m[0] = 1; $m[5] = 1; $m[10] = 1; $m[15] = 1
    $m[12] = $X; $m[13] = $Y; $m[14] = $Z
    [PSCustomObject]@{ M = $m }
}

function Matrix4-Scale {
    param([float]$X, [float]$Y, [float]$Z)
    $m = [float[]]::new(16)
    $m[0] = $X; $m[5] = $Y; $m[10] = $Z; $m[15] = 1
    [PSCustomObject]@{ M = $m }
}

function Matrix4-RotationX {
    param([float]$Angle) # radians
    $c = [float][Math]::Cos($Angle)
    $s = [float][Math]::Sin($Angle)
    $m = [float[]]::new(16)
    $m[0] = 1; $m[15] = 1
    $m[5] = $c;  $m[6] = $s
    $m[9] = -$s; $m[10] = $c
    [PSCustomObject]@{ M = $m }
}

function Matrix4-RotationY {
    param([float]$Angle) # radians
    $c = [float][Math]::Cos($Angle)
    $s = [float][Math]::Sin($Angle)
    $m = [float[]]::new(16)
    $m[5] = 1; $m[15] = 1
    $m[0] = $c;  $m[2] = -$s
    $m[8] = $s;  $m[10] = $c
    [PSCustomObject]@{ M = $m }
}

function Matrix4-RotationZ {
    param([float]$Angle) # radians
    $c = [float][Math]::Cos($Angle)
    $s = [float][Math]::Sin($Angle)
    $m = [float[]]::new(16)
    $m[10] = 1; $m[15] = 1
    $m[0] = $c;  $m[1] = $s
    $m[4] = -$s; $m[5] = $c
    [PSCustomObject]@{ M = $m }
}

# ============================================================================
# View & Projection Matrices
# ============================================================================

function Matrix4-LookAt {
    param($Eye, $Target, $Up)
    # Forward = normalize(eye - target) — OpenGL looks down -Z
    $f = Vector3-Normalize (Vector3-Subtract $Eye $Target)
    $r = Vector3-Normalize (Vector3-Cross $Up $f)
    $u = Vector3-Cross $f $r

    $m = [float[]]::new(16)
    # Column 0
    $m[0] = $r.X; $m[1] = $u.X; $m[2] = $f.X; $m[3] = 0
    # Column 1
    $m[4] = $r.Y; $m[5] = $u.Y; $m[6] = $f.Y; $m[7] = 0
    # Column 2
    $m[8] = $r.Z; $m[9] = $u.Z; $m[10] = $f.Z; $m[11] = 0
    # Column 3 — translation
    $m[12] = -(Vector3-Dot $r $Eye)
    $m[13] = -(Vector3-Dot $u $Eye)
    $m[14] = -(Vector3-Dot $f $Eye)
    $m[15] = 1

    [PSCustomObject]@{ M = $m }
}

function Matrix4-Perspective {
    param([float]$FovRadians, [float]$Aspect, [float]$Near, [float]$Far)
    $tanHalf = [float][Math]::Tan($FovRadians / 2.0)
    $m = [float[]]::new(16)
    $m[0]  = 1.0 / ($Aspect * $tanHalf)
    $m[5]  = 1.0 / $tanHalf
    $m[10] = -($Far + $Near) / ($Far - $Near)
    $m[11] = -1.0
    $m[14] = -(2.0 * $Far * $Near) / ($Far - $Near)
    [PSCustomObject]@{ M = $m }
}

function Matrix4-Orthographic {
    param([float]$Left, [float]$Right, [float]$Bottom, [float]$Top, [float]$Near, [float]$Far)
    $m = [float[]]::new(16)
    $m[0]  = 2.0 / ($Right - $Left)
    $m[5]  = 2.0 / ($Top - $Bottom)
    $m[10] = -2.0 / ($Far - $Near)
    $m[12] = -($Right + $Left) / ($Right - $Left)
    $m[13] = -($Top + $Bottom) / ($Top - $Bottom)
    $m[14] = -($Far + $Near) / ($Far - $Near)
    $m[15] = 1.0
    [PSCustomObject]@{ M = $m }
}

# ============================================================================
# Quaternion — (X, Y, Z, W) where W is the scalar part
# ============================================================================

function New-Quaternion {
    param([float]$X = 0, [float]$Y = 0, [float]$Z = 0, [float]$W = 1)
    [PSCustomObject]@{ X = $X; Y = $Y; Z = $Z; W = $W }
}

function Quaternion-FromAxisAngle {
    param($Axis, [float]$Angle) # Axis = Vector3, Angle in radians
    $half = $Angle / 2.0
    $s = [float][Math]::Sin($half)
    $a = Vector3-Normalize $Axis
    [PSCustomObject]@{
        X = $a.X * $s
        Y = $a.Y * $s
        Z = $a.Z * $s
        W = [float][Math]::Cos($half)
    }
}

function Quaternion-Multiply {
    param($A, $B)
    [PSCustomObject]@{
        X = $A.W * $B.X + $A.X * $B.W + $A.Y * $B.Z - $A.Z * $B.Y
        Y = $A.W * $B.Y - $A.X * $B.Z + $A.Y * $B.W + $A.Z * $B.X
        Z = $A.W * $B.Z + $A.X * $B.Y - $A.Y * $B.X + $A.Z * $B.W
        W = $A.W * $B.W - $A.X * $B.X - $A.Y * $B.Y - $A.Z * $B.Z
    }
}

function Quaternion-Normalize {
    param($Q)
    $len = [Math]::Sqrt($Q.X * $Q.X + $Q.Y * $Q.Y + $Q.Z * $Q.Z + $Q.W * $Q.W)
    if ($len -eq 0) { return New-Quaternion }
    [PSCustomObject]@{ X = $Q.X / $len; Y = $Q.Y / $len; Z = $Q.Z / $len; W = $Q.W / $len }
}

function Quaternion-ToMatrix {
    param($Q)
    $x = $Q.X; $y = $Q.Y; $z = $Q.Z; $w = $Q.W
    $x2 = $x + $x; $y2 = $y + $y; $z2 = $z + $z
    $xx = $x * $x2; $xy = $x * $y2; $xz = $x * $z2
    $yy = $y * $y2; $yz = $y * $z2; $zz = $z * $z2
    $wx = $w * $x2; $wy = $w * $y2; $wz = $w * $z2

    $m = [float[]]::new(16)
    $m[0]  = 1 - ($yy + $zz); $m[1]  = $xy + $wz;       $m[2]  = $xz - $wy;       $m[3]  = 0
    $m[4]  = $xy - $wz;       $m[5]  = 1 - ($xx + $zz);  $m[6]  = $yz + $wx;       $m[7]  = 0
    $m[8]  = $xz + $wy;       $m[9]  = $yz - $wx;        $m[10] = 1 - ($xx + $yy); $m[11] = 0
    $m[12] = 0;               $m[13] = 0;                 $m[14] = 0;               $m[15] = 1

    [PSCustomObject]@{ M = $m }
}

function Quaternion-Slerp {
    param($A, $B, [float]$T)
    $dot = $A.X * $B.X + $A.Y * $B.Y + $A.Z * $B.Z + $A.W * $B.W

    # Ensure shortest path
    $bx = $B.X; $by = $B.Y; $bz = $B.Z; $bw = $B.W
    if ($dot -lt 0) {
        $dot = -$dot
        $bx = -$bx; $by = -$by; $bz = -$bz; $bw = -$bw
    }

    if ($dot -gt 0.9995) {
        # Linear interpolation for very close quaternions
        $rx = $A.X + $T * ($bx - $A.X)
        $ry = $A.Y + $T * ($by - $A.Y)
        $rz = $A.Z + $T * ($bz - $A.Z)
        $rw = $A.W + $T * ($bw - $A.W)
    } else {
        $theta = [Math]::Acos($dot)
        $sinT = [Math]::Sin($theta)
        $s0 = [Math]::Sin((1 - $T) * $theta) / $sinT
        $s1 = [Math]::Sin($T * $theta) / $sinT
        $rx = $s0 * $A.X + $s1 * $bx
        $ry = $s0 * $A.Y + $s1 * $by
        $rz = $s0 * $A.Z + $s1 * $bz
        $rw = $s0 * $A.W + $s1 * $bw
    }

    Quaternion-Normalize ([PSCustomObject]@{ X = $rx; Y = $ry; Z = $rz; W = $rw })
}
