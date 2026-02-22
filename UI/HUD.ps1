# ============================================================================
# UI/HUD.ps1 - 2D HUD Overlay Rendering System
# ============================================================================
# Strictly-2D HUD module that renders on top of the 3D scene.
#
# Public API:
# - Initialize-HUD
# - Register-HUDElement
# - Update-HUDLayout
# - Render-HUD
# - Get-HUDScaleFromWindow
#
# This module intentionally avoids game-feature specifics (T44+ scope).
# ============================================================================

# --- Module State ---
$script:HUDInitialized = $false
$script:HUDRenderRegistered = $false
$script:HUDRendererReady = $false

$script:HUDDesignWidth = [float]1920.0
$script:HUDDesignHeight = [float]1080.0
$script:HUDScaleMode = 'Fit' # Fit | Fill | Stretch
$script:HUDMaxScale = [float]2.0

$script:HUDLastWindowWidth = [int]0
$script:HUDLastWindowHeight = [int]0
$script:HUDProjection = $null
$script:HUDLastRenderInfo = [PSCustomObject]@{
    Mode = 'NotRendered'
    Rendered = $false
    Reason = 'NotRendered'
}

$script:HUDElements = [System.Collections.ArrayList]::new()
$script:HUDNextElementId = [int]1

$script:HUDQuadVAO = [uint32]0
$script:HUDQuadVBO = [uint32]0

$script:HUDLayoutCache = $null
$script:HUDLayoutCacheWidth = [int]0
$script:HUDLayoutCacheHeight = [int]0

$script:HUDBatchActive = $false
$script:HUDBatchProgram = [uint32]0
$script:HUDBatchAlphaLoc = [int]-1

$script:HUDCmdCache = @{}
$script:HUDRectVertexScratch = [float[]]::new(48)
$script:HUDUniformLocationCache = @{}
$script:HUDViewIdentity = $null
$script:HUDModelIdentity = $null

$script:HUDTheme = [PSCustomObject]@{
    PanelColor       = [PSCustomObject]@{ R = [float]0.08; G = [float]0.10; B = [float]0.14; A = [float]0.72 }
    PanelBorderColor = [PSCustomObject]@{ R = [float]0.57; G = [float]0.70; B = [float]0.82; A = [float]0.88 }
}

# ============================================================================
# Internal Helpers
# ============================================================================

function Clamp-HUD01 {
    param([double]$Value)

    if ($Value -lt 0.0) { return [float]0.0 }
    if ($Value -gt 1.0) { return [float]1.0 }
    return [float]$Value
}

function Clamp-HUDPositive {
    param(
        [double]$Value,
        [double]$Fallback = 1.0
    )

    if ($Value -le 0.0) {
        return [float]$Fallback
    }

    return [float]$Value
}

function Test-HUDCommand {
    param([string]$Name)
    if (-not $script:HUDCmdCache.ContainsKey($Name)) {
        $script:HUDCmdCache[$Name] = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }
    return $script:HUDCmdCache[$Name]
}

function Get-HUDWindowMetrics {
    [int]$width = 1024
    [int]$height = 768

    if (Test-HUDCommand -Name 'Get-GlControl') {
        $glCtrl = Get-GlControl
        if ($null -ne $glCtrl) {
            if ($glCtrl.Width -gt 0) { $width = [int]$glCtrl.Width }
            if ($glCtrl.Height -gt 0) { $height = [int]$glCtrl.Height }
        }
    }

    if ($width -lt 1) { $width = 1 }
    if ($height -lt 1) { $height = 1 }

    return [PSCustomObject]@{
        Width = [int]$width
        Height = [int]$height
    }
}

function New-HUDColor {
    param(
        [double]$R,
        [double]$G,
        [double]$B,
        [double]$A
    )

    return [PSCustomObject]@{
        R = Clamp-HUD01 -Value $R
        G = Clamp-HUD01 -Value $G
        B = Clamp-HUD01 -Value $B
        A = Clamp-HUD01 -Value $A
    }
}

function Resolve-HUDAnchorPosition {
    param(
        [string]$Anchor,
        [float]$WindowWidth,
        [float]$WindowHeight,
        [float]$ElementWidth,
        [float]$ElementHeight,
        [float]$OffsetX,
        [float]$OffsetY
    )

    [string]$name = 'TopLeft'
    if (-not [string]::IsNullOrWhiteSpace($Anchor)) {
        $name = [string]$Anchor
    }

    [float]$x = $OffsetX
    [float]$y = $OffsetY

    switch ($name.ToLowerInvariant()) {
        'topleft' {
            $x = $OffsetX
            $y = $OffsetY
        }
        'topcenter' {
            $x = [float](($WindowWidth * 0.5) - ($ElementWidth * 0.5) + $OffsetX)
            $y = $OffsetY
        }
        'topright' {
            $x = [float]($WindowWidth - $ElementWidth - $OffsetX)
            $y = $OffsetY
        }
        'middleleft' {
            $x = $OffsetX
            $y = [float](($WindowHeight * 0.5) - ($ElementHeight * 0.5) + $OffsetY)
        }
        'middlecenter' {
            $x = [float](($WindowWidth * 0.5) - ($ElementWidth * 0.5) + $OffsetX)
            $y = [float](($WindowHeight * 0.5) - ($ElementHeight * 0.5) + $OffsetY)
        }
        'middleright' {
            $x = [float]($WindowWidth - $ElementWidth - $OffsetX)
            $y = [float](($WindowHeight * 0.5) - ($ElementHeight * 0.5) + $OffsetY)
        }
        'bottomleft' {
            $x = $OffsetX
            $y = [float]($WindowHeight - $ElementHeight - $OffsetY)
        }
        'bottomcenter' {
            $x = [float](($WindowWidth * 0.5) - ($ElementWidth * 0.5) + $OffsetX)
            $y = [float]($WindowHeight - $ElementHeight - $OffsetY)
        }
        'bottomright' {
            $x = [float]($WindowWidth - $ElementWidth - $OffsetX)
            $y = [float]($WindowHeight - $ElementHeight - $OffsetY)
        }
        default {
            $x = $OffsetX
            $y = $OffsetY
        }
    }

    return [PSCustomObject]@{
        X = [float]$x
        Y = [float]$y
    }
}

function Normalize-HUDElement {
    param(
        [Parameter(Mandatory = $true)]
        $Element
    )

    [string]$name = [string]$Element.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = ('hud_{0}' -f $script:HUDNextElementId)
    }

    [string]$anchor = 'TopLeft'
    if ($null -ne $Element.PSObject.Properties['Anchor'] -and -not [string]::IsNullOrWhiteSpace([string]$Element.Anchor)) {
        $anchor = [string]$Element.Anchor
    }

    [float]$baseX = [float]0.0
    [float]$baseY = [float]0.0
    [float]$baseWidth = [float]220.0
    [float]$baseHeight = [float]48.0
    [float]$z = [float]0.0
    [bool]$visible = $true

    if ($null -ne $Element.PSObject.Properties['BaseX']) { $baseX = [float]$Element.BaseX }
    if ($null -ne $Element.PSObject.Properties['BaseY']) { $baseY = [float]$Element.BaseY }
    if ($null -ne $Element.PSObject.Properties['BaseWidth']) { $baseWidth = Clamp-HUDPositive -Value ([double]$Element.BaseWidth) -Fallback 1.0 }
    if ($null -ne $Element.PSObject.Properties['BaseHeight']) { $baseHeight = Clamp-HUDPositive -Value ([double]$Element.BaseHeight) -Fallback 1.0 }
    if ($null -ne $Element.PSObject.Properties['ZIndex']) { $z = [float]$Element.ZIndex }
    if ($null -ne $Element.PSObject.Properties['Visible']) { $visible = [bool]$Element.Visible }

    $color = New-HUDColor -R $script:HUDTheme.PanelColor.R -G $script:HUDTheme.PanelColor.G -B $script:HUDTheme.PanelColor.B -A $script:HUDTheme.PanelColor.A
    if ($null -ne $Element.PSObject.Properties['Color'] -and $null -ne $Element.Color) {
        $src = $Element.Color
        [double]$r = $color.R
        [double]$g = $color.G
        [double]$b = $color.B
        [double]$a = $color.A
        if ($null -ne $src.PSObject.Properties['R']) { $r = [double]$src.R }
        if ($null -ne $src.PSObject.Properties['G']) { $g = [double]$src.G }
        if ($null -ne $src.PSObject.Properties['B']) { $b = [double]$src.B }
        if ($null -ne $src.PSObject.Properties['A']) { $a = [double]$src.A }
        $color = New-HUDColor -R $r -G $g -B $b -A $a
    }

    return [PSCustomObject]@{
        Id = [int]$script:HUDNextElementId
        Name = [string]$name
        Anchor = [string]$anchor
        BaseX = [float]$baseX
        BaseY = [float]$baseY
        BaseWidth = [float]$baseWidth
        BaseHeight = [float]$baseHeight
        ZIndex = [float]$z
        Visible = [bool]$visible
        Color = $color
        Runtime = [PSCustomObject]@{
            X = [float]0.0
            Y = [float]0.0
            Width = [float]0.0
            Height = [float]0.0
            Scale = [float]1.0
            WindowWidth = [float]0.0
            WindowHeight = [float]0.0
        }
    }
}

function Compare-HUDElementOrder {
    param($A, $B)

    if ($A.ZIndex -lt $B.ZIndex) { return -1 }
    if ($A.ZIndex -gt $B.ZIndex) { return 1 }
    if ($A.Id -lt $B.Id) { return -1 }
    if ($A.Id -gt $B.Id) { return 1 }
    return 0
}

function Add-HUDShaderAlphaSupport {
    # Best-effort patch to reuse existing voxel shader for translucent HUD quads.
    # If unavailable, HUD still functions with default opaque alpha behavior.
    if ($null -eq $script:DefaultFragmentShaderSource) {
        return
    }

    if ([string]$script:DefaultFragmentShaderSource -match 'uniform\s+float\s+uHudAlpha\s*;') {
        return
    }

    $src = [string]$script:DefaultFragmentShaderSource
    $src = $src.Replace(
        'uniform float uAmbient;',
        "uniform float uAmbient;`nuniform float uHudAlpha;"
    )
    $src = $src.Replace(
        'fragColor = vec4(texColor.rgb * lighting, texColor.a);',
        'fragColor = vec4(texColor.rgb * lighting, texColor.a * uHudAlpha);'
    )

    $script:DefaultFragmentShaderSource = $src
    $script:DefaultShaderProgram = $null
}

function Ensure-HUDQuadResources {
    if ($script:HUDRendererReady) {
        return
    }

    [uint32[]]$vaoIds = @([uint32]0)
    [OpenGL.Gl]::GenVertexArrays($vaoIds)
    $script:HUDQuadVAO = [uint32]$vaoIds[0]

    [uint32[]]$vboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($vboIds)
    $script:HUDQuadVBO = [uint32]$vboIds[0]

    [OpenGL.Gl]::BindVertexArray($script:HUDQuadVAO)
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $script:HUDQuadVBO)

    [float[]]$initialData = [float[]]::new(48)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ArrayBuffer,
        [uint32]($initialData.Length * 4),
        $initialData,
        [OpenGL.BufferUsage]::DynamicDraw
    )

    $program = Get-DefaultShaderProgram
    [int]$stride = 32

    $posLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aPosition')
    if ($posLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$posLoc)
        [OpenGL.Gl]::VertexAttribPointer([uint32]$posLoc, 3, [OpenGL.VertexAttribType]::Float, $false, $stride, [IntPtr]::new(0))
    }

    $texLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aTexCoord')
    if ($texLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$texLoc)
        [OpenGL.Gl]::VertexAttribPointer([uint32]$texLoc, 2, [OpenGL.VertexAttribType]::Float, $false, $stride, [IntPtr]::new(12))
    }

    $normLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aNormal')
    if ($normLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$normLoc)
        [OpenGL.Gl]::VertexAttribPointer([uint32]$normLoc, 3, [OpenGL.VertexAttribType]::Float, $false, $stride, [IntPtr]::new(20))
    }

    [OpenGL.Gl]::BindVertexArray([uint32]0)
    $script:HUDRendererReady = $true
}

function Build-HUDRectVertices {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Z
    )

    [float]$x0 = [float]$X
    [float]$y0 = [float]$Y
    [float]$x1 = [float]($X + $Width)
    [float]$y1 = [float]($Y + $Height)

    return [float[]]@(
        $x0, $y0, $Z, 0.0, 0.0, 0.0, 0.0, 1.0,
        $x1, $y0, $Z, 1.0, 0.0, 0.0, 0.0, 1.0,
        $x1, $y1, $Z, 1.0, 1.0, 0.0, 0.0, 1.0,

        $x0, $y0, $Z, 0.0, 0.0, 0.0, 0.0, 1.0,
        $x1, $y1, $Z, 1.0, 1.0, 0.0, 0.0, 1.0,
        $x0, $y1, $Z, 0.0, 1.0, 0.0, 0.0, 1.0
    )
}

function Fill-HUDRectVertexScratch {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Z
    )

    [float]$x0 = [float]$X
    [float]$y0 = [float]$Y
    [float]$x1 = [float]($X + $Width)
    [float]$y1 = [float]($Y + $Height)

    $v = $script:HUDRectVertexScratch

    # tri 1
    $v[0] = $x0; $v[1] = $y0; $v[2] = $Z; $v[3] = 0.0; $v[4] = 0.0; $v[5] = 0.0; $v[6] = 0.0; $v[7] = 1.0
    $v[8] = $x1; $v[9] = $y0; $v[10] = $Z; $v[11] = 1.0; $v[12] = 0.0; $v[13] = 0.0; $v[14] = 0.0; $v[15] = 1.0
    $v[16] = $x1; $v[17] = $y1; $v[18] = $Z; $v[19] = 1.0; $v[20] = 1.0; $v[21] = 0.0; $v[22] = 0.0; $v[23] = 1.0

    # tri 2
    $v[24] = $x0; $v[25] = $y0; $v[26] = $Z; $v[27] = 0.0; $v[28] = 0.0; $v[29] = 0.0; $v[30] = 0.0; $v[31] = 1.0
    $v[32] = $x1; $v[33] = $y1; $v[34] = $Z; $v[35] = 1.0; $v[36] = 1.0; $v[37] = 0.0; $v[38] = 0.0; $v[39] = 1.0
    $v[40] = $x0; $v[41] = $y1; $v[42] = $Z; $v[43] = 0.0; $v[44] = 1.0; $v[45] = 0.0; $v[46] = 0.0; $v[47] = 1.0

    return $v
}

function Get-HUDCachedUniformLocation {
    param(
        [uint32]$Program,
        [string]$Name
    )

    [string]$key = "${Program}_${Name}"
    if ($script:HUDUniformLocationCache.ContainsKey($key)) {
        return [int]$script:HUDUniformLocationCache[$key]
    }

    [int]$loc = [OpenGL.Gl]::GetUniformLocation($Program, $Name)
    $script:HUDUniformLocationCache[$key] = [int]$loc
    return [int]$loc
}

function Set-HUDProjectionState {
    param(
        [float]$WindowWidth,
        [float]$WindowHeight
    )

    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program

    if ($null -eq $script:HUDProjection -or $script:HUDLastWindowWidth -ne [int]$WindowWidth -or $script:HUDLastWindowHeight -ne [int]$WindowHeight) {
        $script:HUDProjection = Matrix4-Orthographic -Left 0.0 -Right $WindowWidth -Bottom $WindowHeight -Top 0.0 -Near -1.0 -Far 1.0
    }
    if ($null -eq $script:HUDViewIdentity) {
        $script:HUDViewIdentity = Matrix4-Identity
    }
    if ($null -eq $script:HUDModelIdentity) {
        $script:HUDModelIdentity = Matrix4-Identity
    }

    $proj = $script:HUDProjection
    $view = $script:HUDViewIdentity
    $model = $script:HUDModelIdentity

    Set-ShaderUniformMatrix4 -Program $program -Name 'uProjection' -Matrix $proj
    Set-ShaderUniformMatrix4 -Program $program -Name 'uView' -Matrix $view
    Set-ShaderUniformMatrix4 -Program $program -Name 'uModel' -Matrix $model
}

function Begin-HUDBatch {
    if ($script:HUDBatchActive) { return }
    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program
    $atlas = Get-BlockTextureAtlas
    Bind-Texture -Handle $atlas.Handle -Unit 0
    Set-ShaderUniform1i -Program $program -Name 'uTexture' -Value 0
    [OpenGL.Gl]::BindVertexArray($script:HUDQuadVAO)
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $script:HUDQuadVBO)
    $script:HUDBatchProgram = [uint32]$program
    $script:HUDBatchAlphaLoc = Get-HUDCachedUniformLocation -Program $program -Name 'uHudAlpha'
    $script:HUDBatchActive = $true
}

function End-HUDBatch {
    if (-not $script:HUDBatchActive) { return }
    [OpenGL.Gl]::BindVertexArray([uint32]0)
    $script:HUDBatchProgram = [uint32]0
    $script:HUDBatchAlphaLoc = [int]-1
    $script:HUDBatchActive = $false
}

function Draw-HUDRect {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Z,
        [float]$R,
        [float]$G,
        [float]$B,
        [float]$A
    )

    if ($Width -le 0.0 -or $Height -le 0.0) { return }
    if ($A -le 0.0) { return }

    if ($script:HUDBatchActive) {
        [uint32]$program = [uint32]$script:HUDBatchProgram
        [int]$alphaLoc = [int]$script:HUDBatchAlphaLoc
    }
    else {
        [uint32]$program = [uint32](Get-DefaultShaderProgram)
        Use-ShaderProgram -Program $program
        $atlas = Get-BlockTextureAtlas
        Bind-Texture -Handle $atlas.Handle -Unit 0
        Set-ShaderUniform1i -Program $program -Name 'uTexture' -Value 0
        [OpenGL.Gl]::BindVertexArray($script:HUDQuadVAO)
        [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $script:HUDQuadVBO)
        [int]$alphaLoc = Get-HUDCachedUniformLocation -Program $program -Name 'uHudAlpha'
    }

    Set-ShaderUniform3f -Program $program -Name 'uLightDir' -X $R -Y $G -Z $B
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value ([float]0.0)

    if ($alphaLoc -ge 0) {
        [OpenGL.Gl]::Uniform1($alphaLoc, [float]$A)
    }

    [float[]]$verts = Fill-HUDRectVertexScratch -X $X -Y $Y -Width $Width -Height $Height -Z $Z

    [OpenGL.Gl]::BufferSubData(
        [OpenGL.BufferTarget]::ArrayBuffer,
        [IntPtr]::Zero,
        [uint32]($verts.Length * 4),
        $verts
    )

    [OpenGL.Gl]::DrawArrays([OpenGL.PrimitiveType]::Triangles, 0, 6)

    if (-not $script:HUDBatchActive) {
        [OpenGL.Gl]::BindVertexArray([uint32]0)
    }
}

# ============================================================================
# Public API
# ============================================================================

function Get-HUDScaleFromWindow {
    <#
    .SYNOPSIS
        Calculates HUD scaling from current window dimensions.
    .OUTPUTS
        PSCustomObject containing Scale, ScaleX, ScaleY, and config metadata.
    #>
    param(
        [Parameter(Mandatory = $true)][float]$WindowWidth,
        [Parameter(Mandatory = $true)][float]$WindowHeight
    )

    [float]$w = Clamp-HUDPositive -Value $WindowWidth -Fallback 1.0
    [float]$h = Clamp-HUDPositive -Value $WindowHeight -Fallback 1.0
    [float]$dw = Clamp-HUDPositive -Value $script:HUDDesignWidth -Fallback 1920.0
    [float]$dh = Clamp-HUDPositive -Value $script:HUDDesignHeight -Fallback 1080.0

    [float]$sx = [float]($w / $dw)
    [float]$sy = [float]($h / $dh)
    [float]$s = [float]1.0

    switch ($script:HUDScaleMode.ToLowerInvariant()) {
        'fill' {
            $s = [float][Math]::Max($sx, $sy)
        }
        'stretch' {
            $s = [float]1.0
        }
        default {
            $s = [float][Math]::Min($sx, $sy)
        }
    }

    if ($script:HUDScaleMode.ToLowerInvariant() -ne 'stretch') {
        if ($script:HUDMaxScale -gt 0.0 -and $s -gt $script:HUDMaxScale) {
            $s = [float]$script:HUDMaxScale
        }
        if ($s -le 0.0) {
            $s = [float]1.0
        }
    }

    return [PSCustomObject]@{
        Scale = [float]$s
        ScaleX = [float]$sx
        ScaleY = [float]$sy
        Mode = [string]$script:HUDScaleMode
        DesignWidth = [float]$dw
        DesignHeight = [float]$dh
        WindowWidth = [float]$w
        WindowHeight = [float]$h
    }
}

function Initialize-HUD {
    <#
    .SYNOPSIS
        Initializes HUD state and registers overlay render callback.
    .DESCRIPTION
        Intended to be called after world/combat initialization so callback
        ordering naturally renders HUD on top of 3D passes.
    #>
    param(
        [float]$DesignWidth = [float]1920.0,
        [float]$DesignHeight = [float]1080.0,
        [ValidateSet('Fit', 'Fill', 'Stretch')][string]$ScaleMode = 'Fit',
        [float]$MaxScale = [float]2.0,
        [switch]$RegisterDefaultElements
    )

    Add-HUDShaderAlphaSupport

    $script:HUDDesignWidth = Clamp-HUDPositive -Value $DesignWidth -Fallback 1920.0
    $script:HUDDesignHeight = Clamp-HUDPositive -Value $DesignHeight -Fallback 1080.0
    $script:HUDScaleMode = [string]$ScaleMode
    $script:HUDMaxScale = Clamp-HUDPositive -Value $MaxScale -Fallback 2.0

    if (-not $script:HUDInitialized) {
        $script:HUDElements = [System.Collections.ArrayList]::new()
        $script:HUDNextElementId = [int]1
        $script:HUDInitialized = $true
    }

    $script:HUDLastRenderInfo = [PSCustomObject]@{
        Mode = 'Initialized'
        Rendered = $false
        Reason = 'Initialized'
    }

    if (-not $script:HUDRenderRegistered) {
        if (Test-HUDCommand -Name 'Register-RenderCallback') {
            Register-RenderCallback ${function:Render-HUD}
            $script:HUDRenderRegistered = $true
            Write-Host '[HUD] Render callback registered.' -ForegroundColor DarkGray
        }
    }

    if ($RegisterDefaultElements.IsPresent -and $script:HUDElements.Count -eq 0) {
        Register-HUDElement -Element ([PSCustomObject]@{
            Name = 'OverlayRoot'
            Anchor = 'TopLeft'
            BaseX = 20
            BaseY = 20
            BaseWidth = 380
            BaseHeight = 86
            ZIndex = 10
            Visible = $true
            Color = $script:HUDTheme.PanelColor
        }) | Out-Null

        Register-HUDElement -Element ([PSCustomObject]@{
            Name = 'LogDock'
            Anchor = 'BottomLeft'
            BaseX = 20
            BaseY = 20
            BaseWidth = 520
            BaseHeight = 140
            ZIndex = 8
            Visible = $true
            Color = (New-HUDColor -R 0.07 -G 0.09 -B 0.13 -A 0.66)
        }) | Out-Null

        Register-HUDElement -Element ([PSCustomObject]@{
            Name = 'StatusDock'
            Anchor = 'TopRight'
            BaseX = 20
            BaseY = 20
            BaseWidth = 320
            BaseHeight = 60
            ZIndex = 9
            Visible = $true
            Color = (New-HUDColor -R 0.10 -G 0.12 -B 0.17 -A 0.70)
        }) | Out-Null
    }

    Update-HUDLayout | Out-Null

    Write-Host ("[HUD] Initialized ({0}x{1}, mode={2})." -f [int]$script:HUDDesignWidth, [int]$script:HUDDesignHeight, $script:HUDScaleMode) -ForegroundColor Green
}

function Register-HUDElement {
    <#
    .SYNOPSIS
        Registers a HUD element with deterministic anchor-based layout.
    .OUTPUTS
        Normalized HUD element object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Element
    )

    if (-not $script:HUDInitialized) {
        Initialize-HUD
    }

    $normalized = Normalize-HUDElement -Element $Element
    $script:HUDElements.Add($normalized) | Out-Null
    $script:HUDNextElementId = [int]$script:HUDNextElementId + 1
    $script:HUDLayoutCache = $null

    Update-HUDLayout | Out-Null

    return $normalized
}

function Update-HUDLayout {
    <#
    .SYNOPSIS
        Recalculates HUD element runtime placement and ordering.
    .OUTPUTS
        Array of HUD elements sorted by z-order then registration id.
    #>

    if (-not $script:HUDInitialized) {
        return @()
    }

    $metrics = Get-HUDWindowMetrics
    $scaleInfo = Get-HUDScaleFromWindow -WindowWidth $metrics.Width -WindowHeight $metrics.Height
    [float]$scale = [float]$scaleInfo.Scale

    [float]$windowWidth = [float]$metrics.Width
    [float]$windowHeight = [float]$metrics.Height

    foreach ($element in $script:HUDElements) {
        [float]$width = [float]($element.BaseWidth * $scale)
        [float]$height = [float]($element.BaseHeight * $scale)
        [float]$offsetX = [float]($element.BaseX * $scale)
        [float]$offsetY = [float]($element.BaseY * $scale)

        $origin = Resolve-HUDAnchorPosition `
            -Anchor $element.Anchor `
            -WindowWidth $windowWidth `
            -WindowHeight $windowHeight `
            -ElementWidth $width `
            -ElementHeight $height `
            -OffsetX $offsetX `
            -OffsetY $offsetY

        $element.Runtime.X = [float]$origin.X
        $element.Runtime.Y = [float]$origin.Y
        $element.Runtime.Width = [float]$width
        $element.Runtime.Height = [float]$height
        $element.Runtime.Scale = [float]$scale
        $element.Runtime.WindowWidth = [float]$windowWidth
        $element.Runtime.WindowHeight = [float]$windowHeight
    }

    $script:HUDLastWindowWidth = [int]$metrics.Width
    $script:HUDLastWindowHeight = [int]$metrics.Height

    $ordered = @($script:HUDElements)
    [Array]::Sort($ordered, [System.Collections.Generic.Comparer[object]]::Create([System.Comparison[object]]{
        param($a, $b)
        Compare-HUDElementOrder -A $a -B $b
    }))

    return @($ordered)
}

function Get-HUDElements {
    <#
    .SYNOPSIS
        Returns HUD elements in render order.
    #>

    $metrics = Get-HUDWindowMetrics
    if ($null -ne $script:HUDLayoutCache -and $metrics.Width -eq $script:HUDLayoutCacheWidth -and $metrics.Height -eq $script:HUDLayoutCacheHeight) {
        return @($script:HUDLayoutCache)
    }
    $result = @(Update-HUDLayout)
    $script:HUDLayoutCache = $result
    $script:HUDLayoutCacheWidth = [int]$metrics.Width
    $script:HUDLayoutCacheHeight = [int]$metrics.Height
    return @($result)
}

function Get-HUDLayoutState {
    <#
    .SYNOPSIS
        Returns deterministic HUD state for smoke verification and downstream UI.
    #>

    $ordered = Get-HUDElements
    $metrics = Get-HUDWindowMetrics
    $scaleInfo = Get-HUDScaleFromWindow -WindowWidth $metrics.Width -WindowHeight $metrics.Height

    return [PSCustomObject]@{
        Initialized = [bool]$script:HUDInitialized
        RenderRegistered = [bool]$script:HUDRenderRegistered
        RendererReady = [bool]$script:HUDRendererReady
        LastRender = $script:HUDLastRenderInfo
        WindowWidth = [int]$metrics.Width
        WindowHeight = [int]$metrics.Height
        Scale = [float]$scaleInfo.Scale
        ScaleMode = [string]$script:HUDScaleMode
        ElementCount = [int]$ordered.Count
        Elements = @($ordered)
    }
}

function Get-HUDState {
    <#
    .SYNOPSIS
        Returns deterministic HUD state snapshot.
    #>

    return (Get-HUDLayoutState)
}

function Render-HUD {
    <#
    .SYNOPSIS
        2D overlay render callback drawn after world/combat passes.
    .DESCRIPTION
        Uses orthographic projection, disables depth test, and draws HUD quads
        with deterministic z-order in screen space.
    #>
    param($dt)

    if (-not $script:HUDInitialized) {
        $script:HUDLastRenderInfo = [PSCustomObject]@{
            Mode = 'Skipped'
            Rendered = $false
            Reason = 'NotInitialized'
        }
        return
    }

    if ($null -eq ('OpenGL.Gl' -as [type])) {
        $script:HUDLastRenderInfo = [PSCustomObject]@{
            Mode = 'HeadlessNoGL'
            Rendered = $false
            Reason = 'OpenGLTypeUnavailable'
        }
        return
    }

    if (-not (Test-HUDCommand -Name 'Get-DefaultShaderProgram')) {
        $script:HUDLastRenderInfo = [PSCustomObject]@{
            Mode = 'HeadlessNoShader'
            Rendered = $false
            Reason = 'GetDefaultShaderProgramMissing'
        }
        return
    }
    if (-not (Test-HUDCommand -Name 'Matrix4-Orthographic')) {
        $script:HUDLastRenderInfo = [PSCustomObject]@{
            Mode = 'HeadlessNoMath'
            Rendered = $false
            Reason = 'Matrix4OrthographicMissing'
        }
        return
    }
    if (-not (Test-HUDCommand -Name 'Bind-Texture')) {
        $script:HUDLastRenderInfo = [PSCustomObject]@{
            Mode = 'HeadlessNoTexture'
            Rendered = $false
            Reason = 'BindTextureMissing'
        }
        return
    }

    $metrics = Get-HUDWindowMetrics
    if ($metrics.Width -ne $script:HUDLastWindowWidth -or $metrics.Height -ne $script:HUDLastWindowHeight) {
        Update-HUDLayout | Out-Null
    }

    Ensure-HUDQuadResources
    Set-HUDProjectionState -WindowWidth ([float]$metrics.Width) -WindowHeight ([float]$metrics.Height)

    [OpenGL.Gl]::Disable([OpenGL.EnableCap]::DepthTest)
    [OpenGL.Gl]::Enable([OpenGL.EnableCap]::Blend)
    [OpenGL.Gl]::BlendFunc([OpenGL.BlendingFactor]::SrcAlpha, [OpenGL.BlendingFactor]::OneMinusSrcAlpha)

    $ordered = Get-HUDElements

    Begin-HUDBatch

    foreach ($element in $ordered) {
        if (-not $element.Visible) { continue }

        # Near-zero depth layering in orthographic space; still strictly 2D.
        [float]$z = [float]([Math]::Max(-0.95, [Math]::Min(0.95, -0.001 * $element.ZIndex)))

        Draw-HUDRect `
            -X ([float]$element.Runtime.X) `
            -Y ([float]$element.Runtime.Y) `
            -Width ([float]$element.Runtime.Width) `
            -Height ([float]$element.Runtime.Height) `
            -Z $z `
            -R ([float]$element.Color.R) `
            -G ([float]$element.Color.G) `
            -B ([float]$element.Color.B) `
            -A ([float]$element.Color.A)

        # Deterministic border treatment for visual separation.
        [float]$border = [float][Math]::Max(1.0, [Math]::Round($element.Runtime.Scale))
        [float]$br = [float]$script:HUDTheme.PanelBorderColor.R
        [float]$bg = [float]$script:HUDTheme.PanelBorderColor.G
        [float]$bb = [float]$script:HUDTheme.PanelBorderColor.B
        [float]$ba = [float]$script:HUDTheme.PanelBorderColor.A

        Draw-HUDRect -X $element.Runtime.X -Y $element.Runtime.Y -Width $element.Runtime.Width -Height $border -Z ($z - 0.0001) -R $br -G $bg -B $bb -A $ba
        Draw-HUDRect -X $element.Runtime.X -Y ($element.Runtime.Y + $element.Runtime.Height - $border) -Width $element.Runtime.Width -Height $border -Z ($z - 0.0001) -R $br -G $bg -B $bb -A $ba
        Draw-HUDRect -X $element.Runtime.X -Y $element.Runtime.Y -Width $border -Height $element.Runtime.Height -Z ($z - 0.0001) -R $br -G $bg -B $bb -A $ba
        Draw-HUDRect -X ($element.Runtime.X + $element.Runtime.Width - $border) -Y $element.Runtime.Y -Width $border -Height $element.Runtime.Height -Z ($z - 0.0001) -R $br -G $bg -B $bb -A $ba
    }

    End-HUDBatch

    [OpenGL.Gl]::Disable([OpenGL.EnableCap]::Blend)
    [OpenGL.Gl]::Enable([OpenGL.EnableCap]::DepthTest)

    # Restore default ambient and alpha for non-HUD renderers.
    $program = Get-DefaultShaderProgram
    Set-ShaderUniform1f -Program $program -Name 'uAmbient' -Value ([float]0.3)

    $alphaLoc = Get-HUDCachedUniformLocation -Program $program -Name 'uHudAlpha'
    if ($alphaLoc -ge 0) {
        [OpenGL.Gl]::Uniform1($alphaLoc, [float]1.0)
    }

    $script:HUDLastRenderInfo = [PSCustomObject]@{
        Mode = 'GLOverlay'
        Rendered = $true
        Reason = 'Rendered'
    }
}
