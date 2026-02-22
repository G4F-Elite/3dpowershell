# ============================================================================
# Engine/Camera.ps1 — First-Person Camera Controller
# ============================================================================
# Provides mouse-look (pitch/yaw) for the FPS camera. Player.ps1 handles
# all WASD movement and syncs position via Set-CameraPosition.
# Produces a view matrix via Matrix4-LookAt each frame.
# Dependencies: Math.ps1, Input.ps1, OpenGL.ps1 (must be loaded first)
# ============================================================================

# --- Script-scope State ---
$script:CameraPosition   = New-Vector3 -X 0 -Y 70 -Z 0
$script:CameraYaw        = [float]0.0       # Rotation around Y axis (radians)
$script:CameraPitch      = [float]0.0       # Rotation around X axis (radians)
$script:CameraSensitivity = [float]0.15     # Mouse sensitivity (degrees per pixel)

# ============================================================================
# Public Functions
# ============================================================================

function Initialize-Camera {
    <#
    .SYNOPSIS
        Initializes the camera system and registers Update-Camera as an update callback.
    .DESCRIPTION
        Must be called AFTER Initialize-Input and Initialize-GameWindow.
        Camera starts at position (0, 70, 0) looking forward (-Z).
        Mouse is NOT captured initially — user presses Escape or clicks to toggle.
    #>

    $script:CameraPosition    = New-Vector3 -X 0 -Y 70 -Z 0
    $script:CameraYaw         = [float]0.0
    $script:CameraPitch       = [float]0.0
    $script:CameraSensitivity = [float]0.15

    # Register per-frame update
    Register-UpdateCallback ${function:Update-Camera}

    Write-Host "[Camera] Camera initialized at (0, 70, 0)." -ForegroundColor Green
}

function Update-Camera {
    <#
    .SYNOPSIS
        Per-frame camera update. Called automatically via update callback.
    .DESCRIPTION
        Handles mouse look (when captured). WASD movement is handled by Player.ps1.
    #>
    param($dt)

    # --- Mouse Look (only when system-level mouse is captured) ---
    # Menu system is the sole authority for capture/release (Escape, Start, Resume).
    # Camera reads the actual capture state via Get-MouseCaptured.
    if (Get-MouseCaptured) {
        $mouseDelta = Get-MouseDelta

        # Convert pixel delta to degrees, then to radians
        $script:CameraYaw   -= $mouseDelta.X * $script:CameraSensitivity * [Math]::PI / 180.0
        $script:CameraPitch -= $mouseDelta.Y * $script:CameraSensitivity * [Math]::PI / 180.0

        # Clamp pitch to ±89 degrees (in radians)
        $maxPitch = [float](89.0 * [Math]::PI / 180.0)
        if ($script:CameraPitch -gt $maxPitch)  { $script:CameraPitch = $maxPitch }
        if ($script:CameraPitch -lt -$maxPitch) { $script:CameraPitch = -$maxPitch }
    }
}

function Get-ViewMatrix {
    <#
    .SYNOPSIS
        Computes and returns the current view matrix using Matrix4-LookAt.
    .DESCRIPTION
        Uses the camera's position, yaw, and pitch to compute the forward
        direction, then builds a LookAt matrix targeting position + forward.
    #>

    $yaw   = $script:CameraYaw
    $pitch = $script:CameraPitch

    # Full forward vector (including pitch) — OpenGL convention
    $forward = New-Vector3 `
        -X (-[Math]::Sin($yaw) * [Math]::Cos($pitch)) `
        -Y ([Math]::Sin($pitch)) `
        -Z (-[Math]::Cos($yaw) * [Math]::Cos($pitch))

    $eye    = $script:CameraPosition
    $target = Vector3-Add $eye $forward
    $up     = New-Vector3 -X 0 -Y 1 -Z 0

    return (Matrix4-LookAt $eye $target $up)
}

function Get-CameraPosition {
    <#
    .SYNOPSIS
        Returns the current camera position as a Vector3.
    #>
    return $script:CameraPosition
}

function Get-CameraForward {
    <#
    .SYNOPSIS
        Returns the camera's forward direction as a normalized Vector3.
    .DESCRIPTION
        Includes both yaw and pitch in the forward direction.
    #>
    $yaw   = $script:CameraYaw
    $pitch = $script:CameraPitch

    return (New-Vector3 `
        -X (-[Math]::Sin($yaw) * [Math]::Cos($pitch)) `
        -Y ([Math]::Sin($pitch)) `
        -Z (-[Math]::Cos($yaw) * [Math]::Cos($pitch)))
}

function Set-CameraPosition {
    <#
    .SYNOPSIS
        Sets the camera position to the given Vector3.
    #>
    param($Position)
    $script:CameraPosition = $Position
}
