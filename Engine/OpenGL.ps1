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
$script:RenderCallbackNames = [System.Collections.ArrayList]::new()
$script:UpdateCallbackNames = [System.Collections.ArrayList]::new()
$script:LastFrameTime = [System.Diagnostics.Stopwatch]::new()
$script:DeltaTime = 0.016  # Default ~60fps
$script:GLInitialized = $false  # Track if GL has been initialized
$script:PerfCallbackLoggingEnabled = $true
$script:PerfCallbackThresholdMs = [int]100
$script:LastViewportWidth = [int]-1
$script:LastViewportHeight = [int]-1
$script:FrameProfilerEnabled = $true
$script:FrameProfilerPrintEveryN = [int]1
$script:FrameProfilerFrameCounter = [int]0

function Get-FrameProfilerCallbackLabel {
    param(
        [string]$CallbackName,
        [string]$Phase,
        [int]$Index
    )

    [string]$line = [string]$CallbackName
    if ([string]::IsNullOrWhiteSpace($line)) {
        $line = 'unnamed'
    }
    if ($line.Length -gt 72) {
        $line = $line.Substring(0, 72)
    }

    return ('{0}[{1}] {2}' -f $Phase, $Index, $line)
}

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

        $frameWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $stageWatch = [System.Diagnostics.Stopwatch]::StartNew()

        [bool]$profileEnabled = [bool]$script:FrameProfilerEnabled
        [bool]$slowCallbackLogging = [bool]$script:PerfCallbackLoggingEnabled
        [bool]$measureCallbacks = ($profileEnabled -or $slowCallbackLogging)

        $cbWatch = $null
        if ($measureCallbacks) {
            $cbWatch = [System.Diagnostics.Stopwatch]::StartNew()
        }

        [double]$deltaCalcMs = 0.0
        [double]$viewportMs = 0.0
        [double]$clearMs = 0.0
        [double]$updateTotalMs = 0.0
        [double]$renderTotalMs = 0.0

        $profileLines = $null
        if ($profileEnabled) {
            $profileLines = [System.Collections.Generic.List[string]]::new()
        }

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
        $stageWatch.Restart()
        $elapsed = $script:LastFrameTime.Elapsed.TotalSeconds
        if ($elapsed -gt 0) {
            $script:DeltaTime = $elapsed
        }
        $script:LastFrameTime.Restart()
        $deltaCalcMs = $stageWatch.Elapsed.TotalMilliseconds

        # Set viewport only when size changes
        $stageWatch.Restart()
        $glCtrl = $sender
        [int]$vpW = [int]$glCtrl.ClientSize.Width
        [int]$vpH = [int]$glCtrl.ClientSize.Height
        if ($vpW -ne $script:LastViewportWidth -or $vpH -ne $script:LastViewportHeight) {
            GL-Viewport -X 0 -Y 0 -Width $vpW -Height $vpH
            $script:LastViewportWidth = $vpW
            $script:LastViewportHeight = $vpH
        }
        $viewportMs = $stageWatch.Elapsed.TotalMilliseconds

        # Clear color and depth buffers using wrapper
        $stageWatch.Restart()
        $clearMask = [OpenGL.ClearBufferMask]::ColorBufferBit -bor [OpenGL.ClearBufferMask]::DepthBufferBit
        GL-Clear -Mask $clearMask
        $clearMs = $stageWatch.Elapsed.TotalMilliseconds

        # Invoke all registered update/render callbacks
        $stageWatch.Restart()
        $updateIndex = 0
        if ($measureCallbacks) {
            [int]$updateCallbackCount = [int]$script:UpdateCallbacks.Count
            for ($updateIndex = 0; $updateIndex -lt $updateCallbackCount; $updateIndex++) {
                $cb = $script:UpdateCallbacks[$updateIndex]
                $cbWatch.Restart()
                try {
                    & $cb $script:DeltaTime
                } catch {
                    Write-Warning "[Engine] Update callback error: $_"
                }
                [double]$cbMs = $cbWatch.Elapsed.TotalMilliseconds
                $updateTotalMs += $cbMs

                if ($profileEnabled) {
                    [string]$cbName = 'unnamed'
                    if ($updateIndex -lt $script:UpdateCallbackNames.Count) {
                        $cbName = [string]$script:UpdateCallbackNames[$updateIndex]
                    }
                    $label = Get-FrameProfilerCallbackLabel -CallbackName $cbName -Phase 'U' -Index $updateIndex
                    [void]$profileLines.Add(('{0,8:N2} ms  {1}' -f $cbMs, $label))
                }

                if ($slowCallbackLogging -and $cbMs -gt [double]$script:PerfCallbackThresholdMs) {
                    Write-Host "[PERF] Update callback $updateIndex took $([Math]::Round($cbMs, 2)) ms" -ForegroundColor Red
                }
            }
        }
        else {
            [int]$updateCallbackCount = [int]$script:UpdateCallbacks.Count
            for ($updateIndex = 0; $updateIndex -lt $updateCallbackCount; $updateIndex++) {
                $cb = $script:UpdateCallbacks[$updateIndex]
                try {
                    & $cb $script:DeltaTime
                }
                catch {
                    Write-Warning "[Engine] Update callback error: $_"
                }
            }
        }
        $updateTotalMs = $stageWatch.Elapsed.TotalMilliseconds

        $stageWatch.Restart()
        $renderIndex = 0
        if ($measureCallbacks) {
            [int]$renderCallbackCount = [int]$script:RenderCallbacks.Count
            for ($renderIndex = 0; $renderIndex -lt $renderCallbackCount; $renderIndex++) {
                $cb = $script:RenderCallbacks[$renderIndex]
                $cbWatch.Restart()
                try {
                    & $cb $script:DeltaTime
                } catch {
                    Write-Warning "[Engine] Render callback error: $_"
                    Write-Host $_.ScriptStackTrace -ForegroundColor Red
                }
                [double]$cbMs = $cbWatch.Elapsed.TotalMilliseconds
                $renderTotalMs += $cbMs

                if ($profileEnabled) {
                    [string]$cbName = 'unnamed'
                    if ($renderIndex -lt $script:RenderCallbackNames.Count) {
                        $cbName = [string]$script:RenderCallbackNames[$renderIndex]
                    }
                    $label = Get-FrameProfilerCallbackLabel -CallbackName $cbName -Phase 'R' -Index $renderIndex
                    [void]$profileLines.Add(('{0,8:N2} ms  {1}' -f $cbMs, $label))
                }

                if ($slowCallbackLogging -and $cbMs -gt [double]$script:PerfCallbackThresholdMs) {
                    Write-Host "[PERF] Render callback $renderIndex took $([Math]::Round($cbMs, 2)) ms" -ForegroundColor Red
                }
            }
        }
        else {
            [int]$renderCallbackCount = [int]$script:RenderCallbacks.Count
            for ($renderIndex = 0; $renderIndex -lt $renderCallbackCount; $renderIndex++) {
                $cb = $script:RenderCallbacks[$renderIndex]
                try {
                    & $cb $script:DeltaTime
                }
                catch {
                    Write-Warning "[Engine] Render callback error: $_"
                    Write-Host $_.ScriptStackTrace -ForegroundColor Red
                }
            }
        }
        $renderTotalMs = $stageWatch.Elapsed.TotalMilliseconds

        if ($profileEnabled) {
            $script:FrameProfilerFrameCounter++
            [int]$printEvery = [Math]::Max(1, [int]$script:FrameProfilerPrintEveryN)
            if (($script:FrameProfilerFrameCounter % $printEvery) -eq 0) {
                [double]$frameMs = $frameWatch.Elapsed.TotalMilliseconds
                Write-Host ('[FRAME] total={0,8:N2} ms | dt={1,6:N2} ms | deltaCalc={2,6:N2} | viewport={3,6:N2} | clear={4,6:N2} | update={5,7:N2} | render={6,7:N2}' -f $frameMs, ($script:DeltaTime * 1000.0), $deltaCalcMs, $viewportMs, $clearMs, $updateTotalMs, $renderTotalMs) -ForegroundColor Yellow
                foreach ($line in @($profileLines)) {
                    Write-Host ('         ' + $line) -ForegroundColor DarkYellow
                }
            }
        }
    })

    # ContextDestroying: Cleanup
    $script:GlControl.Add_ContextDestroying({
        param($sender, $e)
        Write-Host "[Engine] OpenGL context destroying - cleaning up." -ForegroundColor Yellow
        if (Get-Command -Name Set-MouseCapture -ErrorAction SilentlyContinue) {
            try { Set-MouseCapture -Captured $false } catch {}
        }
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

    param(
        [int]$AutoCloseSeconds = 0
    )

    Write-Host "[Engine] Starting game loop..." -ForegroundColor Cyan
    Write-Host "[Engine] Close the window to exit." -ForegroundColor Gray

    $timer = $null
    if ($AutoCloseSeconds -gt 0) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [Math]::Max(1, $AutoCloseSeconds * 1000)
        $timer.Add_Tick({
            Write-Host "Auto-closing game window for test"
            $script:MainForm.Close()
        })
        $timer.Start()
    }

    [System.Windows.Forms.Application]::Run($script:MainForm)

    if ($null -ne $timer) {
        $timer.Stop()
        $timer.Dispose()
    }

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
        [scriptblock]$Callback,
        [string]$Name = ''
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = [string]$Callback.Ast.Extent.Text
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'unnamed'
    }
    [string]$Name = (($Name -split "`r?`n")[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'unnamed'
    }
    if ($Name.Length -gt 72) {
        $Name = $Name.Substring(0, 72)
    }

    $script:RenderCallbacks.Add($Callback) | Out-Null
    $script:RenderCallbackNames.Add($Name) | Out-Null
    Write-Host "[Engine] Render callback registered: '$Name' (total: $($script:RenderCallbacks.Count))." -ForegroundColor DarkGray
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
        [scriptblock]$Callback,
        [string]$Name = ''
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = [string]$Callback.Ast.Extent.Text
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'unnamed'
    }
    [string]$Name = (($Name -split "`r?`n")[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'unnamed'
    }
    if ($Name.Length -gt 72) {
        $Name = $Name.Substring(0, 72)
    }

    $script:UpdateCallbacks.Add($Callback) | Out-Null
    $script:UpdateCallbackNames.Add($Name) | Out-Null
    Write-Host "[Engine] Update callback registered: '$Name' (total: $($script:UpdateCallbacks.Count))." -ForegroundColor DarkGray
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

function Get-FrameProfilerSummary {
    <#
    .SYNOPSIS
        Returns a lightweight frame performance summary.
    .DESCRIPTION
        Uses current delta-time plus world-render stats (if available) so
        benchmark scripts can capture FPS and frame timings without parsing
        console logs.
    #>

    [double]$frameMs = [double]($script:DeltaTime * 1000.0)
    [double]$fps = 0.0
    if ($frameMs -gt 0.0) {
        $fps = 1000.0 / $frameMs
    }

    $summary = [PSCustomObject]@{
        DeltaTimeSeconds = [double]$script:DeltaTime
        FrameMs = [double]$frameMs
        FPS = [double]$fps
        WorldFrameCount = [int]0
        WorldAverageFrameMs = [double]0.0
        WorldAverageFps = [double]0.0
        WorldMinFrameMs = [double]0.0
        WorldMaxFrameMs = [double]0.0
    }

    if (Get-Command -Name Get-WorldPerformanceSummary -ErrorAction SilentlyContinue) {
        try {
            $worldPerf = Get-WorldPerformanceSummary
            if ($null -ne $worldPerf) {
                $summary.WorldFrameCount = [int]$worldPerf.FrameCount
                $summary.WorldAverageFrameMs = [double]$worldPerf.AverageFrameMs
                $summary.WorldAverageFps = [double]$worldPerf.AverageFps
                $summary.WorldMinFrameMs = [double]$worldPerf.MinFrameMs
                $summary.WorldMaxFrameMs = [double]$worldPerf.MaxFrameMs
            }
        }
        catch {
        }
    }

    return $summary
}

function Set-FrameProfilerState {
    param(
        [bool]$Enabled,
        [int]$PrintEveryN = 120,
        [bool]$LogSlowCallbacks = $false,
        [int]$SlowCallbackThresholdMs = 100
    )

    $script:FrameProfilerEnabled = [bool]$Enabled
    $script:FrameProfilerPrintEveryN = [int][Math]::Max(1, $PrintEveryN)
    $script:PerfCallbackLoggingEnabled = [bool]$LogSlowCallbacks
    $script:PerfCallbackThresholdMs = [int][Math]::Max(1, $SlowCallbackThresholdMs)
    $script:FrameProfilerFrameCounter = [int]0
}

function Get-MainForm {
    <#
    .SYNOPSIS
        Returns the main Form instance for direct access by other modules.
    #>
    return $script:MainForm
}
