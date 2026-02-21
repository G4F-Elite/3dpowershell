# ============================================================================
# Engine/Input.ps1 - Keyboard & Mouse Input System
# ============================================================================
# Tracks keyboard and mouse state using WinForms events. Other game systems
# poll for input each frame via Get-Key*/Get-Mouse* functions.
# Key states cycle: idle -> pressed -> held -> released -> idle
# ============================================================================

# --- Script-scope State ---
$script:KeyStates = @{}                          # [Keys] -> 'idle'|'pressed'|'held'|'released'
$script:MouseButtons = @(                        # Index: 0=left, 1=right, 2=middle
    'idle', 'idle', 'idle'
)
$script:MousePosition = [PSCustomObject]@{ X = 0; Y = 0 }
$script:MousePositionPrev = [PSCustomObject]@{ X = 0; Y = 0 }
$script:MouseDelta = [PSCustomObject]@{ X = 0; Y = 0 }
$script:MouseCaptured = $false
$script:MouseCenterX = 0                         # Screen-space center for re-centering
$script:MouseCenterY = 0

# ============================================================================
# Public Functions
# ============================================================================

function Initialize-Input {
    <#
    .SYNOPSIS
        Hooks keyboard and mouse events on the game window's GlControl.
    .DESCRIPTION
        Must be called AFTER Initialize-GameWindow so GlControl exists.
        Registers Update-Input as an update callback automatically.
    #>

    $form = Get-MainForm
    $control = Get-GlControl

    if (-not $form -or -not $control) {
        Write-Warning "[Input] Cannot initialize - Form or GlControl is null. Call Initialize-GameWindow first."
        return
    }

    # Enable KeyPreview so the Form captures key events before child controls
    $form.KeyPreview = $true

    # --- Keyboard Events (on Form for reliable capture) ---
    $form.Add_KeyDown({
        param($sender, $e)
        $key = $e.KeyCode
        if (-not $script:KeyStates.ContainsKey($key) -or $script:KeyStates[$key] -eq 'idle' -or $script:KeyStates[$key] -eq 'released') {
            $script:KeyStates[$key] = 'pressed'
        }
        $e.Handled = $true
    })

    $form.Add_KeyUp({
        param($sender, $e)
        $key = $e.KeyCode
        $script:KeyStates[$key] = 'released'
        $e.Handled = $true
    })

    # --- Mouse Move (on GlControl since it fills the form) ---
    $control.Add_MouseMove({
        param($sender, $e)
        $script:MousePosition = [PSCustomObject]@{ X = $e.X; Y = $e.Y }
    })

    # --- Mouse Buttons (on GlControl) ---
    $control.Add_MouseDown({
        param($sender, $e)
        switch ($e.Button) {
            ([System.Windows.Forms.MouseButtons]::Left)   { $script:MouseButtons[0] = 'pressed' }
            ([System.Windows.Forms.MouseButtons]::Right)  { $script:MouseButtons[1] = 'pressed' }
            ([System.Windows.Forms.MouseButtons]::Middle) { $script:MouseButtons[2] = 'pressed' }
        }
    })

    $control.Add_MouseUp({
        param($sender, $e)
        switch ($e.Button) {
            ([System.Windows.Forms.MouseButtons]::Left)   { $script:MouseButtons[0] = 'released' }
            ([System.Windows.Forms.MouseButtons]::Right)  { $script:MouseButtons[1] = 'released' }
            ([System.Windows.Forms.MouseButtons]::Middle) { $script:MouseButtons[2] = 'released' }
        }
    })

    # Register the per-frame update
    Register-UpdateCallback ${function:Update-Input}

    Write-Host "[Input] Input system initialized." -ForegroundColor Green
}

function Update-Input {
    <#
    .SYNOPSIS
        Per-frame state transitions. Called automatically via update callback.
    #>
    param($dt)

    # --- Keyboard: pressed->held, released->idle ---
    $keysToUpdate = @($script:KeyStates.Keys)
    foreach ($key in $keysToUpdate) {
        switch ($script:KeyStates[$key]) {
            'pressed'  { $script:KeyStates[$key] = 'held' }
            'released' { $script:KeyStates[$key] = 'idle' }
        }
    }

    # --- Mouse buttons: pressed->held, released->idle ---
    for ($i = 0; $i -lt 3; $i++) {
        switch ($script:MouseButtons[$i]) {
            'pressed'  { $script:MouseButtons[$i] = 'held' }
            'released' { $script:MouseButtons[$i] = 'idle' }
        }
    }

    # --- Mouse delta ---
    if ($script:MouseCaptured) {
        # In captured mode, delta is distance from center of control
        $control = Get-GlControl
        if ($control) {
            $screenPt = $control.PointToScreen([System.Drawing.Point]::new(
                [int]($control.Width / 2),
                [int]($control.Height / 2)
            ))
            $script:MouseCenterX = $screenPt.X
            $script:MouseCenterY = $screenPt.Y

            $curPos = [System.Windows.Forms.Cursor]::Position
            $script:MouseDelta = [PSCustomObject]@{
                X = $curPos.X - $script:MouseCenterX
                Y = $curPos.Y - $script:MouseCenterY
            }

            # Re-center cursor
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(
                $script:MouseCenterX,
                $script:MouseCenterY
            )
        }
    } else {
        # Normal mode: delta from previous position
        $script:MouseDelta = [PSCustomObject]@{
            X = $script:MousePosition.X - $script:MousePositionPrev.X
            Y = $script:MousePosition.Y - $script:MousePositionPrev.Y
        }
    }

    $script:MousePositionPrev = [PSCustomObject]@{
        X = $script:MousePosition.X
        Y = $script:MousePosition.Y
    }
}

# ============================================================================
# Keyboard Query Functions
# ============================================================================

function Get-KeyDown {
    <#
    .SYNOPSIS
        Returns $true on the FIRST frame a key is pressed.
    #>
    param([System.Windows.Forms.Keys]$Key)
    return ($script:KeyStates.ContainsKey($Key) -and $script:KeyStates[$Key] -eq 'pressed')
}

function Get-Key {
    <#
    .SYNOPSIS
        Returns $true while a key is held (pressed or held state).
    #>
    param([System.Windows.Forms.Keys]$Key)
    if (-not $script:KeyStates.ContainsKey($Key)) { return $false }
    $state = $script:KeyStates[$Key]
    return ($state -eq 'pressed' -or $state -eq 'held')
}

function Get-KeyUp {
    <#
    .SYNOPSIS
        Returns $true on the FIRST frame a key is released.
    #>
    param([System.Windows.Forms.Keys]$Key)
    return ($script:KeyStates.ContainsKey($Key) -and $script:KeyStates[$Key] -eq 'released')
}

# ============================================================================
# Mouse Query Functions
# ============================================================================

function Get-MousePosition {
    <#
    .SYNOPSIS
        Returns mouse position relative to the GlControl as PSCustomObject {X, Y}.
    #>
    return $script:MousePosition
}

function Get-MouseDelta {
    <#
    .SYNOPSIS
        Returns mouse movement since last frame as PSCustomObject {X, Y}.
    #>
    return $script:MouseDelta
}

function Get-MouseButton {
    <#
    .SYNOPSIS
        Returns $true while a mouse button is held. 0=left, 1=right, 2=middle.
    #>
    param([int]$Button = 0)
    if ($Button -lt 0 -or $Button -gt 2) { return $false }
    $state = $script:MouseButtons[$Button]
    return ($state -eq 'pressed' -or $state -eq 'held')
}

function Get-MouseButtonDown {
    <#
    .SYNOPSIS
        Returns $true on the first frame a mouse button is pressed. 0=left, 1=right, 2=middle.
    #>
    param([int]$Button = 0)
    if ($Button -lt 0 -or $Button -gt 2) { return $false }
    return ($script:MouseButtons[$Button] -eq 'pressed')
}

function Set-MouseCapture {
    <#
    .SYNOPSIS
        Toggles mouse capture/lock for FPS camera control.
    .DESCRIPTION
        When captured, the cursor is hidden and re-centered each frame.
        Mouse delta reflects movement from center rather than absolute position.
    #>
    param([bool]$Captured)

    $script:MouseCaptured = $Captured

    if ($Captured) {
        [System.Windows.Forms.Cursor]::Hide()

        # Center cursor on the GlControl
        $control = Get-GlControl
        if ($control) {
            $screenPt = $control.PointToScreen([System.Drawing.Point]::new(
                [int]($control.Width / 2),
                [int]($control.Height / 2)
            ))
            $script:MouseCenterX = $screenPt.X
            $script:MouseCenterY = $screenPt.Y
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(
                $script:MouseCenterX,
                $script:MouseCenterY
            )
        }

        # Reset delta so there's no jump on capture
        $script:MouseDelta = [PSCustomObject]@{ X = 0; Y = 0 }
        Write-Host "[Input] Mouse captured." -ForegroundColor DarkGray
    } else {
        [System.Windows.Forms.Cursor]::Show()
        $script:MouseDelta = [PSCustomObject]@{ X = 0; Y = 0 }
        Write-Host "[Input] Mouse released." -ForegroundColor DarkGray
    }
}
