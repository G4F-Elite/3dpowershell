# ============================================================================
# PowerShell Voxel RPG - Entry Point
# ============================================================================
# Launch script for the 3D Voxel RPG game engine built in PowerShell.
# Uses OpenGL.Net for rendering via WinForms GlControl.
# ============================================================================

param(
    [int]$AutoCloseSeconds = 0
)

$ErrorActionPreference = 'Stop'

# Determine script root (works in PS 5.1 and PS 7+)
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  PowerShell Voxel RPG - Engine Loading..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Load Dependencies ---
$libsPath = Join-Path $PSScriptRoot "libs"

Write-Host "[1/3] Loading OpenGL.Net assembly..." -ForegroundColor Yellow
$openglDll = Join-Path $libsPath "OpenGL.Net.dll"
if (-not (Test-Path $openglDll)) {
    throw "OpenGL.Net.dll not found at: $openglDll"
}
[Reflection.Assembly]::LoadFrom($openglDll) | Out-Null

Write-Host "[2/3] Loading OpenGL.Net.WinForms assembly..." -ForegroundColor Yellow
$winformsDll = Join-Path $libsPath "OpenGL.Net.WinForms.dll"
if (-not (Test-Path $winformsDll)) {
    throw "OpenGL.Net.WinForms.dll not found at: $winformsDll"
}
[Reflection.Assembly]::LoadFrom($winformsDll) | Out-Null

Write-Host "[3/3] Loading System.Windows.Forms..." -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Dot-source Engine Modules ---
. "$PSScriptRoot\Engine\Math.ps1"
. "$PSScriptRoot\Engine\GL.ps1"
. "$PSScriptRoot\Engine\OpenGL.ps1"
. "$PSScriptRoot\Engine\Shader.ps1"
. "$PSScriptRoot\Engine\Input.ps1"
. "$PSScriptRoot\Engine\Texture.ps1"
. "$PSScriptRoot\Engine\Mesh.ps1"
. "$PSScriptRoot\Engine\Camera.ps1"
. "$PSScriptRoot\Engine\Physics.ps1"
. "$PSScriptRoot\Engine\Raycast.ps1"
. "$PSScriptRoot\Engine\Performance.ps1"

# --- Dot-source World Modules ---
. "$PSScriptRoot\World\Chunk.ps1"
. "$PSScriptRoot\World\TerrainGen.ps1"
. "$PSScriptRoot\World\Biomes.ps1"
. "$PSScriptRoot\World\Blocks.ps1"
. "$PSScriptRoot\World\World.ps1"

# --- Dot-source Data Modules ---
. "$PSScriptRoot\Data\Items.ps1"
. "$PSScriptRoot\Data\Recipes.ps1"
. "$PSScriptRoot\Data\SaveLoad.ps1"
. "$PSScriptRoot\Data\Settings.ps1"

# --- Dot-source Game Modules ---
. "$PSScriptRoot\Game\Player.ps1"
. "$PSScriptRoot\Game\Stats.ps1"
. "$PSScriptRoot\Game\Interaction.ps1"
. "$PSScriptRoot\Game\Inventory.ps1"
. "$PSScriptRoot\Game\Gathering.ps1"
. "$PSScriptRoot\Game\Equipment.ps1"
. "$PSScriptRoot\Game\Crafting.ps1"
. "$PSScriptRoot\Game\Tools.ps1"
. "$PSScriptRoot\Game\Combat.ps1"
. "$PSScriptRoot\Game\Experience.ps1"
. "$PSScriptRoot\Game\Enemy.ps1"
. "$PSScriptRoot\Game\Enemies.ps1"
. "$PSScriptRoot\Game\NPC.ps1"
. "$PSScriptRoot\Game\Dialog.ps1"
. "$PSScriptRoot\Game\Quest.ps1"
. "$PSScriptRoot\Game\Death.ps1"
. "$PSScriptRoot\Game\Reputation.ps1"
. "$PSScriptRoot\Game\Damage.ps1"
. "$PSScriptRoot\Game\LevelUp.ps1"
. "$PSScriptRoot\Game\Rewards.ps1"
. "$PSScriptRoot\Game\Skills.ps1"
. "$PSScriptRoot\Game\SkillEffects.ps1"
. "$PSScriptRoot\Game\StatProgression.ps1"
. "$PSScriptRoot\Data\Quests.ps1"

# --- Dot-source UI Modules (only Menu + HUD dependency) ---
. "$PSScriptRoot\UI\HUD.ps1"
. "$PSScriptRoot\UI\Menu.ps1"

# --- Engine Ready ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Engine loaded successfully!" -ForegroundColor Green
Write-Host "  OpenGL.Net v$([OpenGL.Gl].Assembly.GetName().Version)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# --- Initialize and Start ---
Initialize-Performance
Initialize-GameWindow
Register-AutoSaveOnExit -Slot 1 | Out-Null
Initialize-Settings -ApplyRuntime | Out-Null
Initialize-Input
Initialize-Camera
Initialize-World -Seed 12345
Initialize-Player
Initialize-Physics
Initialize-PlayerStats
Initialize-Interaction
Initialize-Inventory
Initialize-Gathering
Initialize-Equipment
Initialize-Crafting
Initialize-Tools
Initialize-Combat
Initialize-ExperienceSystem
Initialize-QuestSystem
Initialize-ReputationSystem
Initialize-Menu

# --- Start Game Loop (blocks until window closes) ---
Start-GameLoop -AutoCloseSeconds $AutoCloseSeconds
