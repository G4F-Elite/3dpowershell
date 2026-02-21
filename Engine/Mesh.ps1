# ============================================================================
# Engine/Mesh.ps1 — Mesh Creation & Rendering Pipeline
# ============================================================================
# Creates VBO/VAO/EBO GPU resources for rendering textured cubes.
# Provides New-CubeMesh (creates a textured cube), Draw-Mesh (renders it),
# Remove-Mesh (cleans up GPU resources), and Initialize-Renderer (sets up
# face culling and registers the render callback).
# ============================================================================

# --- Script-scope State ---
$script:TestCubeMesh = $null
$script:RendererInitialized = $false

# ============================================================================
# Public Functions
# ============================================================================

function New-CubeMesh {
    <#
    .SYNOPSIS
        Creates a textured cube mesh with GPU buffers ready for rendering.
    .DESCRIPTION
        Generates a unit cube (1x1x1) centered at origin with 6 faces,
        24 vertices (4 per face), and 36 indices (2 triangles per face).
        Each vertex has: position (vec3), texcoord (vec2), normal (vec3).
        Vertex format matches the default shader: aPosition, aTexCoord, aNormal.
    .PARAMETER BlockType
        Block type for texture lookup (default 'grass').
    .OUTPUTS
        PSCustomObject with VAO, VBO, EBO handles and IndexCount.
    #>
    param(
        [string]$BlockType = 'grass'
    )

    Write-Host "[Mesh] Creating cube mesh (block: $BlockType)..." -ForegroundColor Yellow

    # Get texture atlas for UV coords
    $atlas = Get-BlockTextureAtlas

    # --- Build vertex data ---
    # Each vertex: X, Y, Z, U, V, NX, NY, NZ (8 floats)
    # Cube from (-0.5, -0.5, -0.5) to (0.5, 0.5, 0.5)
    # 6 faces x 4 vertices = 24 vertices x 8 floats = 192 floats

    $verts = [System.Collections.ArrayList]::new()

    # Helper to add a face's 4 vertices
    # $positions = array of 4 position arrays [x,y,z]
    # $uv = PSCustomObject with U0, V0, U1, V1
    # $normal = [nx, ny, nz]
    function Add-FaceVertices {
        param($vertList, $positions, $uv, $normal)
        # Vertex 0: bottom-left UV
        $vertList.Add($positions[0][0]) | Out-Null; $vertList.Add($positions[0][1]) | Out-Null; $vertList.Add($positions[0][2]) | Out-Null
        $vertList.Add($uv.U0) | Out-Null; $vertList.Add($uv.V1) | Out-Null
        $vertList.Add($normal[0]) | Out-Null; $vertList.Add($normal[1]) | Out-Null; $vertList.Add($normal[2]) | Out-Null

        # Vertex 1: bottom-right UV
        $vertList.Add($positions[1][0]) | Out-Null; $vertList.Add($positions[1][1]) | Out-Null; $vertList.Add($positions[1][2]) | Out-Null
        $vertList.Add($uv.U1) | Out-Null; $vertList.Add($uv.V1) | Out-Null
        $vertList.Add($normal[0]) | Out-Null; $vertList.Add($normal[1]) | Out-Null; $vertList.Add($normal[2]) | Out-Null

        # Vertex 2: top-right UV
        $vertList.Add($positions[2][0]) | Out-Null; $vertList.Add($positions[2][1]) | Out-Null; $vertList.Add($positions[2][2]) | Out-Null
        $vertList.Add($uv.U1) | Out-Null; $vertList.Add($uv.V0) | Out-Null
        $vertList.Add($normal[0]) | Out-Null; $vertList.Add($normal[1]) | Out-Null; $vertList.Add($normal[2]) | Out-Null

        # Vertex 3: top-left UV
        $vertList.Add($positions[3][0]) | Out-Null; $vertList.Add($positions[3][1]) | Out-Null; $vertList.Add($positions[3][2]) | Out-Null
        $vertList.Add($uv.U0) | Out-Null; $vertList.Add($uv.V0) | Out-Null
        $vertList.Add($normal[0]) | Out-Null; $vertList.Add($normal[1]) | Out-Null; $vertList.Add($normal[2]) | Out-Null
    }

    # --- Front face (south, +Z) — normal (0, 0, 1) ---
    $uvSouth = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'south'
    Add-FaceVertices $verts @(
        @([float]-0.5, [float]-0.5, [float] 0.5),
        @([float] 0.5, [float]-0.5, [float] 0.5),
        @([float] 0.5, [float] 0.5, [float] 0.5),
        @([float]-0.5, [float] 0.5, [float] 0.5)
    ) $uvSouth @([float]0, [float]0, [float]1)

    # --- Back face (north, -Z) — normal (0, 0, -1) ---
    $uvNorth = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'north'
    Add-FaceVertices $verts @(
        @([float] 0.5, [float]-0.5, [float]-0.5),
        @([float]-0.5, [float]-0.5, [float]-0.5),
        @([float]-0.5, [float] 0.5, [float]-0.5),
        @([float] 0.5, [float] 0.5, [float]-0.5)
    ) $uvNorth @([float]0, [float]0, [float]-1)

    # --- Right face (east, +X) — normal (1, 0, 0) ---
    $uvEast = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'east'
    Add-FaceVertices $verts @(
        @([float] 0.5, [float]-0.5, [float] 0.5),
        @([float] 0.5, [float]-0.5, [float]-0.5),
        @([float] 0.5, [float] 0.5, [float]-0.5),
        @([float] 0.5, [float] 0.5, [float] 0.5)
    ) $uvEast @([float]1, [float]0, [float]0)

    # --- Left face (west, -X) — normal (-1, 0, 0) ---
    $uvWest = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'west'
    Add-FaceVertices $verts @(
        @([float]-0.5, [float]-0.5, [float]-0.5),
        @([float]-0.5, [float]-0.5, [float] 0.5),
        @([float]-0.5, [float] 0.5, [float] 0.5),
        @([float]-0.5, [float] 0.5, [float]-0.5)
    ) $uvWest @([float]-1, [float]0, [float]0)

    # --- Top face (top, +Y) — normal (0, 1, 0) ---
    $uvTop = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'top'
    Add-FaceVertices $verts @(
        @([float]-0.5, [float] 0.5, [float] 0.5),
        @([float] 0.5, [float] 0.5, [float] 0.5),
        @([float] 0.5, [float] 0.5, [float]-0.5),
        @([float]-0.5, [float] 0.5, [float]-0.5)
    ) $uvTop @([float]0, [float]1, [float]0)

    # --- Bottom face (bottom, -Y) — normal (0, -1, 0) ---
    $uvBottom = Get-BlockFaceUV -Atlas $atlas -BlockType $BlockType -Face 'bottom'
    Add-FaceVertices $verts @(
        @([float]-0.5, [float]-0.5, [float]-0.5),
        @([float] 0.5, [float]-0.5, [float]-0.5),
        @([float] 0.5, [float]-0.5, [float] 0.5),
        @([float]-0.5, [float]-0.5, [float] 0.5)
    ) $uvBottom @([float]0, [float]-1, [float]0)

    # Convert ArrayList to float[]
    [float[]]$vertexData = [float[]]::new($verts.Count)
    for ($i = 0; $i -lt $verts.Count; $i++) {
        $vertexData[$i] = [float]$verts[$i]
    }

    # --- Build index data ---
    # 6 faces x 2 triangles x 3 indices = 36 indices
    # Each face has 4 vertices (baseIndex + 0,1,2,3)
    # Triangle 1: 0, 1, 2   Triangle 2: 0, 2, 3
    [uint32[]]$indexData = [uint32[]]::new(36)
    for ($face = 0; $face -lt 6; $face++) {
        $base = [uint32]($face * 4)
        $idx  = $face * 6
        $indexData[$idx + 0] = $base + 0
        $indexData[$idx + 1] = $base + 1
        $indexData[$idx + 2] = $base + 2
        $indexData[$idx + 3] = $base + 0
        $indexData[$idx + 4] = $base + 2
        $indexData[$idx + 5] = $base + 3
    }

    # --- Create VAO ---
    [uint32[]]$vaoIds = @([uint32]0)
    [OpenGL.Gl]::GenVertexArrays($vaoIds)
    $vao = $vaoIds[0]
    [OpenGL.Gl]::BindVertexArray($vao)

    # --- Create VBO ---
    [uint32[]]$vboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($vboIds)
    $vbo = $vboIds[0]
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ArrayBuffer, $vbo)

    # Upload vertex data: 24 vertices x 8 floats x 4 bytes = 768 bytes
    [uint32]$vertexByteSize = [uint32]($vertexData.Length * 4)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ArrayBuffer,
        $vertexByteSize,
        $vertexData,
        [OpenGL.BufferUsage]::StaticDraw
    )

    # --- Create EBO ---
    [uint32[]]$eboIds = @([uint32]0)
    [OpenGL.Gl]::GenBuffers($eboIds)
    $ebo = $eboIds[0]
    [OpenGL.Gl]::BindBuffer([OpenGL.BufferTarget]::ElementArrayBuffer, $ebo)

    # Upload index data: 36 indices x 4 bytes = 144 bytes
    [uint32]$indexByteSize = [uint32]($indexData.Length * 4)
    [OpenGL.Gl]::BufferData(
        [OpenGL.BufferTarget]::ElementArrayBuffer,
        $indexByteSize,
        $indexData,
        [OpenGL.BufferUsage]::StaticDraw
    )

    # --- Set up vertex attribute pointers ---
    # Get the default shader to query attribute locations
    $program = Get-DefaultShaderProgram

    # Stride = 8 floats * 4 bytes = 32 bytes
    [int]$stride = 32

    # aPosition (vec3) — offset 0
    $posLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aPosition')
    if ($posLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$posLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$posLoc,
            3,
            [OpenGL.VertexAttribType]::Float,
            $false,
            $stride,
            [IntPtr]::new(0)
        )
    }

    # aTexCoord (vec2) — offset 12 bytes (3 floats * 4)
    $texLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aTexCoord')
    if ($texLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$texLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$texLoc,
            2,
            [OpenGL.VertexAttribType]::Float,
            $false,
            $stride,
            [IntPtr]::new(12)
        )
    }

    # aNormal (vec3) — offset 20 bytes (5 floats * 4)
    $normLoc = [OpenGL.Gl]::GetAttribLocation($program, 'aNormal')
    if ($normLoc -ge 0) {
        [OpenGL.Gl]::EnableVertexAttribArray([uint32]$normLoc)
        [OpenGL.Gl]::VertexAttribPointer(
            [uint32]$normLoc,
            3,
            [OpenGL.VertexAttribType]::Float,
            $false,
            $stride,
            [IntPtr]::new(20)
        )
    }

    # Unbind VAO (leave EBO bound inside VAO state)
    [OpenGL.Gl]::BindVertexArray([uint32]0)

    $mesh = [PSCustomObject]@{
        VAO        = $vao
        VBO        = $vbo
        EBO        = $ebo
        IndexCount = 36
        BlockType  = $BlockType
    }

    Write-Host "[Mesh] Cube mesh created (VAO: $vao, VBO: $vbo, EBO: $ebo, 36 indices)." -ForegroundColor Green
    return $mesh
}

function Draw-Mesh {
    <#
    .SYNOPSIS
        Renders a mesh using its VAO and index buffer.
    .PARAMETER Mesh
        PSCustomObject from New-CubeMesh with VAO, IndexCount.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Mesh
    )

    [OpenGL.Gl]::BindVertexArray($Mesh.VAO)
    [OpenGL.Gl]::DrawElements(
        [OpenGL.PrimitiveType]::Triangles,
        $Mesh.IndexCount,
        [OpenGL.DrawElementsType]::UnsignedInt,
        [IntPtr]::Zero
    )
    [OpenGL.Gl]::BindVertexArray([uint32]0)
}

function Remove-Mesh {
    <#
    .SYNOPSIS
        Deletes GPU resources (VAO, VBO, EBO) for a mesh.
    .PARAMETER Mesh
        PSCustomObject from New-CubeMesh.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Mesh
    )

    if ($Mesh.VAO -gt 0) {
        [uint32[]]$vaoArr = @($Mesh.VAO)
        [OpenGL.Gl]::DeleteVertexArrays($vaoArr)
    }
    if ($Mesh.VBO -gt 0) {
        [uint32[]]$vboArr = @($Mesh.VBO)
        [OpenGL.Gl]::DeleteBuffers($vboArr)
    }
    if ($Mesh.EBO -gt 0) {
        [uint32[]]$eboArr = @($Mesh.EBO)
        [OpenGL.Gl]::DeleteBuffers($eboArr)
    }

    Write-Host "[Mesh] Mesh removed (VAO: $($Mesh.VAO))." -ForegroundColor DarkGray
}

function Initialize-Renderer {
    <#
    .SYNOPSIS
        Initializes the mesh rendering system: enables back-face culling
        and creates a test cube mesh.
    .DESCRIPTION
        MUST be called when a GL context is active (e.g. from a render
        callback or ContextCreated event). Do NOT call before Application.Run().
        Uses lazy init — called automatically on first render frame.
    #>

    if ($script:RendererInitialized) {
        return
    }

    Write-Host "[Mesh] Initializing renderer..." -ForegroundColor Yellow

    # Enable back-face culling
    [OpenGL.Gl]::Enable([OpenGL.EnableCap]::CullFace)
    Write-Host "[Mesh] Back-face culling enabled." -ForegroundColor DarkGray

    # Create the test cube mesh (requires GL context for shader, texture, buffers)
    $script:TestCubeMesh = New-CubeMesh -BlockType 'grass'

    $script:RendererInitialized = $true
    Write-Host "[Mesh] Renderer initialized — test cube ready." -ForegroundColor Green
}

function Invoke-TestCubeRender {
    <#
    .SYNOPSIS
        Render callback that draws the test cube with proper MVP matrices,
        texture binding, and lighting uniforms.
    .PARAMETER dt
        Delta time in seconds (from game loop).
    #>
    param($dt)

    # Lazy init on first render frame (GL context guaranteed to exist here)
    if (-not $script:RendererInitialized) {
        Initialize-Renderer
    }

    if ($null -eq $script:TestCubeMesh) { return }

    $program = Get-DefaultShaderProgram
    Use-ShaderProgram -Program $program

    # --- Model matrix: translate cube slightly forward so camera can see it ---
    $model = Matrix4-Translation -X 0 -Y 0 -Z 0

    # --- View matrix: camera looking at origin from (2, 2, 3) ---
    $eye    = New-Vector3 -X 2 -Y 2 -Z 3
    $target = New-Vector3 -X 0 -Y 0 -Z 0
    $up     = New-Vector3 -X 0 -Y 1 -Z 0
    $view   = Matrix4-LookAt $eye $target $up

    # --- Projection matrix: 60 degree FOV, ~4:3 aspect ---
    $fovRad = [float]([Math]::PI / 3.0)  # 60 degrees
    $aspect = [float](1024.0 / 768.0)
    $proj   = Matrix4-Perspective -FovRadians $fovRad -Aspect $aspect -Near 0.1 -Far 100.0

    # Set MVP uniforms
    Set-ShaderUniformMatrix4 -Program $program -Name 'uModel'      -Matrix $model
    Set-ShaderUniformMatrix4 -Program $program -Name 'uView'       -Matrix $view
    Set-ShaderUniformMatrix4 -Program $program -Name 'uProjection' -Matrix $proj

    # Bind texture atlas to texture unit 0
    $atlas = Get-BlockTextureAtlas
    Bind-Texture -Handle $atlas.Handle -Unit 0
    Set-ShaderUniform1i -Program $program -Name 'uTexture' -Value 0

    # Set lighting uniforms — directional sunlight from upper-right-front
    Set-ShaderUniform3f -Program $program -Name 'uLightDir' -X 0.5 -Y 0.8 -Z 0.3
    Set-ShaderUniform1f -Program $program -Name 'uAmbient'  -Value 0.3

    # Draw the cube
    Draw-Mesh -Mesh $script:TestCubeMesh
}
