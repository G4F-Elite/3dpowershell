# ============================================================================
# Engine/OpenGL.ps1 — OpenGL Initialization & Window Management
# ============================================================================
# Creates a WinForms Form with an OpenGL.GlControl render surface.
# Provides game loop via GlControl's Animation property and a callback
# system for other modules to hook into the render cycle.
# ============================================================================

# --- Script-scope State ---
$script:MainForm = $null
$script:GlControl = $null
$script:RenderCallbacks = [System.Collections.ArrayList]::new()
$script:UpdateCallbacks = [System.Collections.ArrayList]::new()
$script:LastFrameTime = [System.Diagnostics.Stopwatch]::new()
$script:DeltaTime = 0.016  # Default ~60fps
$script:GLInitialized = $false  # Track if GL has been initialized

# ============================================================================
# Public Functions
# ============================================================================

function Initialize-GameWindow {
    <#
    .SYNOPSIS
        Creates the main game window with an OpenGL render surface.
    .DESCRIPTION
        Sets up a WinForms Form (1024x768) containing an OpenGL.GlControl
        with depth buffering, double buffering, and 60fps animation.
    #>

    Write-Host "[Engine] Initializing game window..." -ForegroundColor Yellow

    # --- Create the main form ---
    $script:MainForm = New-Object System.Windows.Forms.Form
    $script:MainForm.Text = "PowerShell Voxel RPG"
    $script:MainForm.Width = 1024
    $script:MainForm.Height = 768
    $script:MainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $script:MainForm.BackColor = [System.Drawing.Color]::Black

    # --- Create the GlControl ---
    $script:GlControl = New-Object OpenGL.GlControl
    $script:GlControl.DepthBits = [uint32]24
    $script:GlControl.ColorBits = [uint32]32
    $script:GlControl.DoubleBuffer = $true
    $script:GlControl.Animation = $true
    $script:GlControl.AnimationTime = 16  # ~60 FPS
    $script:GlControl.Dock = [System.Windows.Forms.DockStyle]::Fill

    # --- Hook GlControl Events ---

    # ContextCreated: Initialize OpenGL state
    $script:GlControl.Add_ContextCreated({
        param($sender, $e)
        Write-Host "[Engine] OpenGL context created event fired." -ForegroundColor Green
        Write-Host "[Engine] GL Version: $([OpenGL.Gl]::CurrentVersion)" -ForegroundColor Cyan
        Write-Host "[Engine] GL Vendor: $([OpenGL.Gl]::CurrentVendor)" -ForegroundColor Cyan
        Write-Host "[Engine] GL Renderer: $([OpenGL.Gl]::CurrentRenderer)" -ForegroundColor Cyan

        # Set clear color to cornflower blue using wrapper
        GL-ClearColor -R 0.39 -G 0.58 -B 0.93 -A 1.0

        # Enable depth testing using wrapper
        GL-Enable -Cap ([OpenGL.EnableCap]::DepthTest)
        
        # Start the frame timer
        $script:LastFrameTime.Start()
        
        # Mark GL as initialized
        $script:GLInitialized = $true

        Write-Host "[Engine] OpenGL initialized - Cornflower blue clear color, depth test enabled." -ForegroundColor Green
    })

    # Render: Called each frame by GlControl's animation system
    $script:GlControl.Add_Render({
        param($sender, $e)

        # FALLBACK: Initialize GL if ContextCreated didn't fire
        if (-not $script:GLInitialized) {
            # Check if GL context is ready
            if ([OpenGL.Gl]::CurrentVersion -eq $null) {
                Write-Warning "[Engine] GL context not ready yet, skipping frame."
                return
            }
            Write-Host "[Engine] GL fallback initialization in Render event." -ForegroundColor Yellow
            try {
                # Set clear color to cornflower blue using wrapper
                GL-ClearColor -R 0.39 -G 0.58 -B 0.93 -A 1.0
                # Enable depth testing using wrapper
                GL-Enable -Cap ([OpenGL.EnableCap]::DepthTest)
                # Start the frame timer
                $script:LastFrameTime.Start()
                $script:GLInitialized = $true
                Write-Host "[Engine] OpenGL initialized (fallback) - Cornflower blue clear color, depth test enabled." -ForegroundColor Green
            } catch {
                Write-Warning "[Engine] GL fallback init failed: $_"
            }
        }

        # Calculate delta time
        $elapsed = $script:LastFrameTime.Elapsed.TotalSeconds
        if ($elapsed -gt 0) {
            $script:DeltaTime = $elapsed
        }
        $script:LastFrameTime.Restart()

        # Set viewport to match control size using wrapper
        $glCtrl = $sender
        GL-Viewport -X 0 -Y 0 -Width $glCtrl.ClientSize.Width -Height $glCtrl.ClientSize.Height

        # Clear color and depth buffers using wrapper
        $clearMask = [OpenGL.ClearBufferMask]::ColorBufferBit -bor [OpenGL.ClearBufferMask]::DepthBufferBit
        GL-Clear -Mask $clearMask

        $perfWatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Invoke all registered update callbacks
        foreach ($cb in $script:UpdateCallbacks) {
            $perfWatch.Restart()
            try {
                & $cb $script:DeltaTime
            } catch {
                Write-Warning "[Engine] Update callback error: $_"
            }
            $ms = $perfWatch.ElapsedMilliseconds
            if ($ms -gt 100) {
                Write-Host "[PERF] Update callback $($cb.ToString().Substring(0, [math]::Min($cb.ToString().Length, 50))) took $ms ms" -ForegroundColor Red
            }
        }

        # Invoke all registered render callbacks
        foreach ($cb in $script:RenderCallbacks) {
            $perfWatch.Restart()
            try {
                & $cb $script:DeltaTime
            } catch {
                Write-Warning "[Engine] Render callback error: $_"
                Write-Host $_.ScriptStackTrace -ForegroundColor Red
            }
            $ms = $perfWatch.ElapsedMilliseconds
            if ($ms -gt 100) {
                Write-Host "[PERF] Render callback $($cb.ToString().Substring(0, [math]::Min($cb.ToString().Length, 50))) took $ms ms" -ForegroundColor Red
            }
        }
    })

    # ContextDestroying: Cleanup
    $script:GlControl.Add_ContextDestroying({
        param($sender, $e)
        Write-Host "[Engine] OpenGL context destroying - cleaning up." -ForegroundColor Yellow
        $script:LastFrameTime.Stop()
    })

    # --- Add GlControl to Form ---
    $script:MainForm.Controls.Add($script:GlControl)

    Write-Host "[Engine] Game window initialized (1024x768, 60fps target)." -ForegroundColor Green
}

function Start-GameLoop {
    <#
    .SYNOPSIS
        Starts the game loop by running the WinForms message pump.
    .DESCRIPTION
        Calls Application.Run() which blocks until the window is closed.
        The GlControl's Animation property drives the render loop.
    #>

    Write-Host "[Engine] Starting game loop..." -ForegroundColor Cyan
    Write-Host "[Engine] Close the window to exit." -ForegroundColor Gray

    # Test hack: auto close after 10 seconds
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 10000
    $timer.Add_Tick({
        Write-Host "Auto-closing game window for test"
        $script:MainForm.Close()
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($script:MainForm)

    Write-Host ""
    Write-Host "[Engine] Game loop ended. Window closed." -ForegroundColor Yellow
}

function Register-RenderCallback {
    <#
    .SYNOPSIS
        Registers a scriptblock to be called each frame during rendering.
    .PARAMETER Callback
        A scriptblock that receives delta time (seconds) as its parameter.
    .EXAMPLE
        Register-RenderCallback { param($dt) Write-Host "Frame: $dt seconds" }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )

    $script:RenderCallbacks.Add($Callback) | Out-Null
    Write-Host "[Engine] Render callback registered (total: $($script:RenderCallbacks.Count))." -ForegroundColor DarkGray
}

function Register-UpdateCallback {
    <#
    .SYNOPSIS
        Registers a scriptblock to be called each frame during the update phase.
    .PARAMETER Callback
        A scriptblock that receives delta time (seconds) as its parameter.
    .EXAMPLE
        Register-UpdateCallback { param($dt) $script:PlayerPos += $speed * $dt }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )

    $script:UpdateCallbacks.Add($Callback) | Out-Null
    Write-Host "[Engine] Update callback registered (total: $($script:UpdateCallbacks.Count))." -ForegroundColor DarkGray
}

function Get-DeltaTime {
    <#
    .SYNOPSIS
        Returns the time elapsed since the last frame in seconds.
    #>
    return $script:DeltaTime
}

function Get-GlControl {
    <#
    .SYNOPSIS
        Returns the GlControl instance for direct access by other modules.
    #>
    return $script:GlControl
}

function Get-MainForm {
    <#
    .SYNOPSIS
        Returns the main Form instance for direct access by other modules.
    #>
    return $script:MainForm
}
