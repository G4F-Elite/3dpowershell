# ============================================================================
# Engine/Shader.ps1 — Shader Compilation & Management
# ============================================================================
# Compiles GLSL vertex and fragment shaders, links them into programs, and
# provides uniform-setting functions for the rendering pipeline.
# Includes built-in default shaders for voxel rendering with texture
# sampling and basic directional lighting.
# ============================================================================

# --- Script-scope State ---
$script:DefaultShaderProgram = $null
$script:UniformLocationCache = @{}

# ============================================================================
# Shader Source — Default Voxel Shaders (GLSL 130)
# ============================================================================

$script:DefaultVertexShaderSource = @"
#version 130

in vec3 aPosition;
in vec2 aTexCoord;
in vec3 aNormal;

uniform mat4 uModel;
uniform mat4 uView;
uniform mat4 uProjection;

out vec2 vTexCoord;
out vec3 vNormal;
out vec3 vWorldPos;

void main() {
    vec4 worldPos = uModel * vec4(aPosition, 1.0);
    vWorldPos = worldPos.xyz;
    vTexCoord = aTexCoord;
    vNormal = mat3(uModel) * aNormal;
    gl_Position = uProjection * uView * worldPos;
}
"@

$script:DefaultFragmentShaderSource = @"
#version 130

in vec2 vTexCoord;
in vec3 vNormal;
in vec3 vWorldPos;

uniform sampler2D uTexture;
uniform vec3 uLightDir;
uniform float uAmbient;

out vec4 fragColor;

void main() {
    vec4 texColor = texture2D(uTexture, vTexCoord);
    vec3 normal = normalize(vNormal);
    vec3 lightDir = normalize(uLightDir);
    float diffuse = max(dot(normal, lightDir), 0.0);
    float lighting = diffuse + uAmbient;
    fragColor = vec4(texColor.rgb * lighting, texColor.a);
}
"@

# ============================================================================
# Internal Helpers
# ============================================================================

function Compile-Shader {
    <#
    .SYNOPSIS
        Compiles a single GLSL shader from source.
    .PARAMETER ShaderType
        OpenGL.ShaderType enum value (VertexShader or FragmentShader).
    .PARAMETER Source
        GLSL source code string.
    .OUTPUTS
        UInt32 shader handle.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $ShaderType,
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $shader = [OpenGL.Gl]::CreateShader($ShaderType)
    [OpenGL.Gl]::ShaderSource($shader, [string[]]@($Source))
    [OpenGL.Gl]::CompileShader($shader)

    # Check for compilation errors via info log
    $sb = [System.Text.StringBuilder]::new(1024)
    [int]$logLen = 0
    [OpenGL.Gl]::GetShaderInfoLog($shader, 1024, [ref]$logLen, $sb)
    $infoLog = $sb.ToString().Trim()

    if ($infoLog.Length -gt 0) {
        $typeName = if ($ShaderType -eq [OpenGL.ShaderType]::VertexShader) { "Vertex" } else { "Fragment" }
        Write-Host "[Shader] $typeName shader compilation FAILED:" -ForegroundColor Red
        Write-Host "[Shader] $infoLog" -ForegroundColor Red
        throw "Failed to compile $typeName shader: $infoLog"
    }

    Write-Host "[Shader] Compiled $($ShaderType) shader (handle: $shader)." -ForegroundColor DarkGray
    return $shader
}

# ============================================================================
# Public Functions
# ============================================================================

function New-ShaderProgram {
    <#
    .SYNOPSIS
        Compiles vertex and fragment GLSL source and returns a linked program handle.
    .PARAMETER VertexSource
        GLSL vertex shader source code.
    .PARAMETER FragmentSource
        GLSL fragment shader source code.
    .OUTPUTS
        UInt32 program handle.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VertexSource,
        [Parameter(Mandatory = $true)]
        [string]$FragmentSource
    )

    Write-Host "[Shader] Compiling shader program..." -ForegroundColor Yellow

    # Compile individual shaders
    $vs = Compile-Shader -ShaderType ([OpenGL.ShaderType]::VertexShader) -Source $VertexSource
    $fs = Compile-Shader -ShaderType ([OpenGL.ShaderType]::FragmentShader) -Source $FragmentSource

    # Create and link program
    $program = [OpenGL.Gl]::CreateProgram()
    [OpenGL.Gl]::AttachShader($program, $vs)
    [OpenGL.Gl]::AttachShader($program, $fs)
    [OpenGL.Gl]::LinkProgram($program)

    # Check for link errors via info log
    $sb = [System.Text.StringBuilder]::new(1024)
    [int]$logLen = 0
    [OpenGL.Gl]::GetProgramInfoLog($program, 1024, [ref]$logLen, $sb)
    $infoLog = $sb.ToString().Trim()

    if ($infoLog.Length -gt 0) {
        Write-Host "[Shader] Program linking FAILED:" -ForegroundColor Red
        Write-Host "[Shader] $infoLog" -ForegroundColor Red
        throw "Failed to link shader program: $infoLog"
    }

    # Clean up individual shaders (attached to program, no longer needed)
    [OpenGL.Gl]::DeleteShader($vs)
    [OpenGL.Gl]::DeleteShader($fs)

    Write-Host "[Shader] Shader program linked (handle: $program)." -ForegroundColor Green
    return $program
}

function Use-ShaderProgram {
    <#
    .SYNOPSIS
        Activates a shader program for subsequent draw calls.
    .PARAMETER Program
        UInt32 program handle from New-ShaderProgram.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program
    )

    [OpenGL.Gl]::UseProgram($Program)
}

function Get-CachedUniformLocation {
    <#
    .SYNOPSIS
        Returns a cached uniform location, querying OpenGL only on first access.
    #>
    param(
        [uint32]$Program,
        [string]$Name
    )

    [string]$cacheKey = "${Program}_${Name}"
    if ($script:UniformLocationCache.ContainsKey($cacheKey)) {
        return $script:UniformLocationCache[$cacheKey]
    }

    $location = [OpenGL.Gl]::GetUniformLocation($Program, $Name)
    $script:UniformLocationCache[$cacheKey] = $location
    return $location
}

function Set-ShaderUniformMatrix4 {
    <#
    .SYNOPSIS
        Sets a 4x4 matrix uniform on the specified shader program.
    .PARAMETER Program
        UInt32 program handle.
    .PARAMETER Name
        Uniform name in the GLSL shader.
    .PARAMETER Matrix
        Matrix4 PSCustomObject (from Math.ps1) with .M property.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Matrix
    )

    $location = Get-CachedUniformLocation -Program $Program -Name $Name
    if ($location -lt 0) { return }

    $floatArr = Matrix4-ToFloatArray $Matrix
    [OpenGL.Gl]::UniformMatrix4($location, $false, $floatArr)
}

function Set-ShaderUniform1i {
    <#
    .SYNOPSIS
        Sets an integer uniform (e.g. texture sampler binding).
    .PARAMETER Program
        UInt32 program handle.
    .PARAMETER Name
        Uniform name in the GLSL shader.
    .PARAMETER Value
        Integer value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    $location = Get-CachedUniformLocation -Program $Program -Name $Name
    if ($location -lt 0) { return }

    [OpenGL.Gl]::Uniform1($location, $Value)
}

function Set-ShaderUniform1f {
    <#
    .SYNOPSIS
        Sets a float uniform.
    .PARAMETER Program
        UInt32 program handle.
    .PARAMETER Name
        Uniform name in the GLSL shader.
    .PARAMETER Value
        Float value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [float]$Value
    )

    $location = Get-CachedUniformLocation -Program $Program -Name $Name
    if ($location -lt 0) { return }

    [OpenGL.Gl]::Uniform1($location, $Value)
}

function Set-ShaderUniform3f {
    <#
    .SYNOPSIS
        Sets a vec3 uniform (for lighting direction, colors, etc.).
    .PARAMETER Program
        UInt32 program handle.
    .PARAMETER Name
        Uniform name in the GLSL shader.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [float]$X,
        [Parameter(Mandatory = $true)]
        [float]$Y,
        [Parameter(Mandatory = $true)]
        [float]$Z
    )

    $location = Get-CachedUniformLocation -Program $Program -Name $Name
    if ($location -lt 0) { return }

    [OpenGL.Gl]::Uniform3($location, $X, $Y, $Z)
}

function Set-ShaderUniform4f {
    <#
    .SYNOPSIS
        Sets a vec4 uniform.
    .PARAMETER Program
        UInt32 program handle.
    .PARAMETER Name
        Uniform name in the GLSL shader.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [float]$X,
        [Parameter(Mandatory = $true)]
        [float]$Y,
        [Parameter(Mandatory = $true)]
        [float]$Z,
        [Parameter(Mandatory = $true)]
        [float]$W
    )

    $location = Get-CachedUniformLocation -Program $Program -Name $Name
    if ($location -lt 0) { return }

    [OpenGL.Gl]::Uniform4($location, $X, $Y, $Z, $W)
}

function Get-DefaultShaderProgram {
    <#
    .SYNOPSIS
        Returns the default voxel shader program, creating it on first call.
    .DESCRIPTION
        Lazy-creates and caches a shader program using the built-in vertex
        and fragment shaders for voxel rendering with texture + lighting.
    .OUTPUTS
        UInt32 program handle.
    #>

    if ($null -eq $script:DefaultShaderProgram) {
        Write-Host "[Shader] Creating default voxel shader program..." -ForegroundColor Yellow
        $script:DefaultShaderProgram = New-ShaderProgram `
            -VertexSource $script:DefaultVertexShaderSource `
            -FragmentSource $script:DefaultFragmentShaderSource
        Write-Host "[Shader] Default shader program ready." -ForegroundColor Green
    }

    return $script:DefaultShaderProgram
}
