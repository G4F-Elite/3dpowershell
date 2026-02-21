# ============================================================================
# Engine/GL.ps1 - OpenGL Function Wrappers for PowerShell
# ============================================================================
# PowerShell cannot resolve overloaded static methods properly.
# This module provides wrapper functions that use reflection to call OpenGL.
# ============================================================================

# Cache for method info (performance optimization)
$script:GLMethods = @{}

function Invoke-GLMethod {
    <#
    .SYNOPSIS
        Calls a static OpenGL.Gl method using reflection.
        Caches MethodInfo + parameter types after first call per signature.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MethodName,
        
        [Parameter(Mandatory = $false)]
        [object[]]$Arguments = @()
    )
    
    # Build cache key from method name + argument types
    $cacheKey = $MethodName + '_' + $Arguments.Count
    
    if ($script:GLMethods.ContainsKey($cacheKey)) {
        $cached = $script:GLMethods[$cacheKey]
        $method = $cached.Method
        $paramTypes = $cached.ParamTypes
    } else {
        $glType = [OpenGL.Gl]
        
        # Get argument types for method resolution
        $argTypes = if ($Arguments.Count -gt 0) {
            $Arguments | ForEach-Object { $_.GetType() }
        } else {
            @()
        }
        
        # Try to get method with exact types first
        $method = $glType.GetMethod($MethodName, [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public, $null, $argTypes, $null)
        
        # If not found, try to find any method with matching name and argument count
        if ($null -eq $method) {
            $methods = $glType.GetMethods([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public) | Where-Object { $_.Name -eq $MethodName }
            $method = $methods | Where-Object { $_.GetParameters().Count -eq $Arguments.Count } | Select-Object -First 1
        }
        
        if ($null -eq $method) {
            throw "OpenGL method '$MethodName' not found with $($Arguments.Count) arguments"
        }
        
        # Cache method info and parameter types
        $paramTypes = @($method.GetParameters() | ForEach-Object { $_.ParameterType })
        $script:GLMethods[$cacheKey] = @{ Method = $method; ParamTypes = $paramTypes }
    }
    
    # Convert arguments to correct types using cached parameter types
    $convertedArgs = [object[]]::new($paramTypes.Count)
    for ($i = 0; $i -lt $paramTypes.Count; $i++) {
        $convertedArgs[$i] = [System.Convert]::ChangeType($Arguments[$i], $paramTypes[$i])
    }
    
    $method.Invoke($null, $convertedArgs)
}

# ============================================================================
# Viewport
# ============================================================================
function GL-Viewport {
    param(
        [Parameter(Mandatory = $true)]
        [int]$X,
        [Parameter(Mandatory = $true)]
        [int]$Y,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [Parameter(Mandatory = $true)]
        [int]$Height
    )
    
    Invoke-GLMethod -MethodName 'Viewport' -Arguments @($X, $Y, $Width, $Height)
}

# ============================================================================
# ClearColor
# ============================================================================
function GL-ClearColor {
    param(
        [Parameter(Mandatory = $true)]
        [float]$R,
        [Parameter(Mandatory = $true)]
        [float]$G,
        [Parameter(Mandatory = $true)]
        [float]$B,
        [Parameter(Mandatory = $true)]
        [float]$A
    )
    
    Invoke-GLMethod -MethodName 'ClearColor' -Arguments @($R, $G, $B, $A)
}

# ============================================================================
# Clear
# ============================================================================
function GL-Clear {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.ClearBufferMask]$Mask
    )
    
    Invoke-GLMethod -MethodName 'Clear' -Arguments @($Mask)
}

# ============================================================================
# Enable
# ============================================================================
function GL-Enable {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.EnableCap]$Cap
    )
    
    [OpenGL.Gl]::Enable($Cap)
}

# ============================================================================
# Disable
# ============================================================================
function GL-Disable {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.EnableCap]$Cap
    )
    
    [OpenGL.Gl]::Disable($Cap)
}

# ============================================================================
# GenVertexArrays
# ============================================================================
function GL-GenVertexArrays {
    param(
        [Parameter(Mandatory = $false)]
        [int]$Count = 1
    )
    
    $arrays = [uint32[]]::new($Count)
    [OpenGL.Gl]::GenVertexArrays($arrays)
    if ($Count -eq 1) { return $arrays[0] }
    return $arrays
}

# ============================================================================
# BindVertexArray
# ============================================================================
function GL-BindVertexArray {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$VAO
    )
    
    [OpenGL.Gl]::BindVertexArray($VAO)
}

# ============================================================================
# GenBuffers
# ============================================================================
function GL-GenBuffers {
    param(
        [Parameter(Mandatory = $false)]
        [int]$Count = 1
    )
    
    $buffers = [uint32[]]::new($Count)
    [OpenGL.Gl]::GenBuffers($buffers)
    if ($Count -eq 1) { return $buffers[0] }
    return $buffers
}

# ============================================================================
# BindBuffer
# ============================================================================
function GL-BindBuffer {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.BufferTarget]$Target,
        [Parameter(Mandatory = $true)]
        [uint32]$Buffer
    )
    
    [OpenGL.Gl]::BindBuffer($Target, $Buffer)
}

# ============================================================================
# BufferData
# ============================================================================
function GL-BufferData {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.BufferTarget]$Target,
        [Parameter(Mandatory = $true)]
        [uint32]$Size,
        [Parameter(Mandatory = $true)]
        [object]$Data,
        [Parameter(Mandatory = $true)]
        [OpenGL.BufferUsage]$Usage
    )
    
    [OpenGL.Gl]::BufferData($Target, $Size, $Data, $Usage)
}

# ============================================================================
# DrawElements
# ============================================================================
function GL-DrawElements {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.PrimitiveType]$Mode,
        [Parameter(Mandatory = $true)]
        [int]$Count,
        [Parameter(Mandatory = $true)]
        [OpenGL.DrawElementsType]$Type,
        [Parameter(Mandatory = $false)]
        [IntPtr]$Offset = [IntPtr]::Zero
    )
    
    [OpenGL.Gl]::DrawElements($Mode, $Count, $Type, $Offset)
}

# ============================================================================
# UseProgram
# ============================================================================
function GL-UseProgram {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program
    )
    
    [OpenGL.Gl]::UseProgram($Program)
}

# ============================================================================
# CreateShader
# ============================================================================
function GL-CreateShader {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.ShaderType]$Type
    )
    
    return [OpenGL.Gl]::CreateShader($Type)
}

# ============================================================================
# ShaderSource
# ============================================================================
function GL-ShaderSource {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Shader,
        [Parameter(Mandatory = $true)]
        [string]$Source
    )
    
    [OpenGL.Gl]::ShaderSource($Shader, $Source)
}

# ============================================================================
# CompileShader
# ============================================================================
function GL-CompileShader {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Shader
    )
    
    [OpenGL.Gl]::CompileShader($Shader)
}

# ============================================================================
# CreateProgram
# ============================================================================
function GL-CreateProgram {
    return [OpenGL.Gl]::CreateProgram()
}

# ============================================================================
# AttachShader
# ============================================================================
function GL-AttachShader {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [uint32]$Shader
    )
    
    [OpenGL.Gl]::AttachShader($Program, $Shader)
}

# ============================================================================
# LinkProgram
# ============================================================================
function GL-LinkProgram {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program
    )
    
    [OpenGL.Gl]::LinkProgram($Program)
}

# ============================================================================
# DeleteShader
# ============================================================================
function GL-DeleteShader {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Shader
    )
    
    [OpenGL.Gl]::DeleteShader($Shader)
}

# ============================================================================
# GetShaderParameter
# ============================================================================
function GL-GetShaderParameter {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Shader,
        [Parameter(Mandatory = $true)]
        [OpenGL.ShaderParameterName]$PName
    )
    
    $value = [int]0
    [OpenGL.Gl]::GetShader($Shader, $PName, [ref]$value)
    return $value
}

# ============================================================================
# GetProgramParameter
# ============================================================================
function GL-GetProgramParameter {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [OpenGL.ProgramParameterName]$PName
    )
    
    $value = [int]0
    [OpenGL.Gl]::GetProgram($Program, $PName, [ref]$value)
    return $value
}

# ============================================================================
# GetShaderInfoLog
# ============================================================================
function GL-GetShaderInfoLog {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Shader
    )
    
    $length = GL-GetShaderParameter -Shader $Shader -PName 'InfoLogLength'
    if ($length -gt 0) {
        $log = [System.Text.StringBuilder]::new($length)
        [OpenGL.Gl]::GetShaderInfoLog($Shader, $length, [ref]$length, $log)
        return $log.ToString()
    }
    return ""
}

# ============================================================================
# GetProgramInfoLog
# ============================================================================
function GL-GetProgramInfoLog {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program
    )
    
    $length = GL-GetProgramParameter -Program $Program -PName 'InfoLogLength'
    if ($length -gt 0) {
        $log = [System.Text.StringBuilder]::new($length)
        [OpenGL.Gl]::GetProgramInfoLog($Program, $length, [ref]$length, $log)
        return $log.ToString()
    }
    return ""
}

# ============================================================================
# GetAttribLocation
# ============================================================================
function GL-GetAttribLocation {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    
    return [OpenGL.Gl]::GetAttribLocation($Program, $Name)
}

# ============================================================================
# GetUniformLocation
# ============================================================================
function GL-GetUniformLocation {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Program,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    
    return [OpenGL.Gl]::GetUniformLocation($Program, $Name)
}

# ============================================================================
# EnableVertexAttribArray
# ============================================================================
function GL-EnableVertexAttribArray {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index
    )
    
    [OpenGL.Gl]::EnableVertexAttribArray($Index)
}

# ============================================================================
# VertexAttribPointer
# ============================================================================
function GL-VertexAttribPointer {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [int]$Size,
        [Parameter(Mandatory = $true)]
        [OpenGL.VertexAttribType]$Type,
        [Parameter(Mandatory = $false)]
        [bool]$Normalized = $false,
        [Parameter(Mandatory = $true)]
        [int]$Stride,
        [Parameter(Mandatory = $true)]
        [IntPtr]$Offset
    )
    
    [OpenGL.Gl]::VertexAttribPointer($Index, $Size, $Type, $Normalized, $Stride, $Offset)
}

# ============================================================================
# GenTextures
# ============================================================================
function GL-GenTextures {
    param(
        [Parameter(Mandatory = $false)]
        [int]$Count = 1
    )
    
    $textures = [uint32[]]::new($Count)
    [OpenGL.Gl]::GenTextures($textures)
    if ($Count -eq 1) { return $textures[0] }
    return $textures
}

# ============================================================================
# BindTexture
# ============================================================================
function GL-BindTexture {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.TextureTarget]$Target,
        [Parameter(Mandatory = $true)]
        [uint32]$Texture
    )
    
    [OpenGL.Gl]::BindTexture($Target, $Texture)
}

# ============================================================================
# ActiveTexture
# ============================================================================
function GL-ActiveTexture {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.TextureUnit]$Texture
    )
    
    [OpenGL.Gl]::ActiveTexture($Texture)
}

# ============================================================================
# TexParameter
# ============================================================================
function GL-TexParameter {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.TextureTarget]$Target,
        [Parameter(Mandatory = $true)]
        [OpenGL.TextureParameterName]$PName,
        [Parameter(Mandatory = $true)]
        [object]$Param
    )
    
    if ($Param -is [int]) {
        [OpenGL.Gl]::TexParameteri($Target, $PName, $Param)
    } elseif ($Param -is [float]) {
        [OpenGL.Gl]::TexParameterf($Target, $PName, $Param)
    }
}

# ============================================================================
# TexImage2D
# ============================================================================
function GL-TexImage2D {
    param(
        [Parameter(Mandatory = $true)]
        [OpenGL.TextureTarget]$Target,
        [Parameter(Mandatory = $false)]
        [int]$Level = 0,
        [Parameter(Mandatory = $true)]
        [OpenGL.InternalFormat]$InternalFormat,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [Parameter(Mandatory = $true)]
        [int]$Height,
        [Parameter(Mandatory = $false)]
        [int]$Border = 0,
        [Parameter(Mandatory = $true)]
        [OpenGL.PixelFormat]$Format,
        [Parameter(Mandatory = $true)]
        [OpenGL.PixelType]$Type,
        [Parameter(Mandatory = $false)]
        [object]$Pixels = $null
    )
    
    [OpenGL.Gl]::TexImage2D($Target, $Level, $InternalFormat, $Width, $Height, $Border, $Format, $Type, $Pixels)
}

# ============================================================================
# Uniform functions
# ============================================================================
function GL-Uniform1i {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Location,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )
    
    [OpenGL.Gl]::Uniform1($Location, $Value)
}

function GL-Uniform1f {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Location,
        [Parameter(Mandatory = $true)]
        [float]$Value
    )
    
    [OpenGL.Gl]::Uniform1($Location, $Value)
}

function GL-Uniform3f {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Location,
        [Parameter(Mandatory = $true)]
        [float]$X,
        [Parameter(Mandatory = $true)]
        [float]$Y,
        [Parameter(Mandatory = $true)]
        [float]$Z
    )
    
    [OpenGL.Gl]::Uniform3($Location, $X, $Y, $Z)
}

function GL-UniformMatrix4f {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Location,
        [Parameter(Mandatory = $false)]
        [int]$Count = 1,
        [Parameter(Mandatory = $false)]
        [bool]$Transpose = $false,
        [Parameter(Mandatory = $true)]
        [float[]]$Matrix
    )
    
    [OpenGL.Gl]::UniformMatrix4($Location, $Transpose, $Matrix)
}

# ============================================================================
# Delete functions
# ============================================================================
function GL-DeleteVertexArrays {
    param(
        [Parameter(Mandatory = $true)]
        [uint32[]]$Arrays
    )
    
    [OpenGL.Gl]::DeleteVertexArrays($Arrays)
}

function GL-DeleteBuffers {
    param(
        [Parameter(Mandatory = $true)]
        [uint32[]]$Buffers
    )
    
    [OpenGL.Gl]::DeleteBuffers($Buffers)
}

function GL-DeleteTextures {
    param(
        [Parameter(Mandatory = $true)]
        [uint32[]]$Textures
    )
    
    [OpenGL.Gl]::DeleteTextures($Textures)
}
