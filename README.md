# PowerShell Voxel RPG

A full-featured 3D voxel role-playing game engine built entirely in PowerShell using OpenGL.Net for GPU rendering. Explore a procedurally generated world, fight enemies, complete quests, craft items, and level up your character — all from a PowerShell script.

---

## Overview

**Genre:** First-Person Voxel RPG
**Platform:** Windows (WinForms + OpenGL)
**Target:** 1024×768 @ 60 FPS
**Language:** PowerShell 5.1+
**Rendering:** OpenGL.Net (hardware-accelerated 3D)

The game features a complete game loop: spawn into a procedurally generated world, gather resources, craft tools and weapons, fight AI enemies, level up, unlock skills from a skill tree, talk to NPCs, complete quests, and manage your character progression across save slots.

---

## Requirements

- **Windows 10/11**
- **PowerShell 5.1** or later
- **.NET Framework 4.7+** (pre-installed on Windows 10/11)
- A GPU with **OpenGL 3.0+** support (any modern integrated or discrete GPU)
- The `libs/` folder must contain:
  - `OpenGL.Net.dll`
  - `OpenGL.Net.WinForms.dll`

---

## Running the Game

```powershell
cd 3dpowershell
.\Start.ps1
```

If you encounter an execution policy error:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Start.ps1
```

---

## Controls

| Key | Action |
|-----|--------|
| `W A S D` | Move forward / left / backward / right |
| `Space` | Jump |
| `Shift` | Sprint (1.3× speed) |
| `Mouse` | Look around (first-person) |
| `F` | Attack / melee swing |
| `G` | Toggle block placement/destruction |
| `E` | Open / close inventory |
| `Escape` | Pause menu |
| `F3` | Toggle fly mode (debug) |

All key bindings can be customized via the in-game Settings menu.

---

## Project Structure

```
3dpowershell/
├── Start.ps1               # Main entry point
├── Start_full.ps1          # Alternative startup
│
├── libs/                   # OpenGL.Net DLLs
│   ├── OpenGL.Net.dll
│   └── OpenGL.Net.WinForms.dll
│
├── Engine/                 # Core engine modules
│   ├── Math.ps1            # Vector/Matrix/Quaternion math
│   ├── GL.ps1              # Low-level OpenGL bindings
│   ├── OpenGL.ps1          # Window management & game loop
│   ├── Shader.ps1          # GLSL shader compilation & uniforms
│   ├── Mesh.ps1            # VAO/VBO/EBO mesh pipeline
│   ├── Texture.ps1         # Texture atlas & block UV mapping
│   ├── Camera.ps1          # First-person camera (pitch/yaw)
│   ├── Input.ps1           # Keyboard/mouse input & key bindings
│   ├── Physics.ps1         # AABB collision detection & response
│   ├── Raycast.ps1         # Ray casting for block/entity targeting
│   ├── Animation.ps1       # Entity animation state machine
│   └── Performance.ps1     # Frame profiler & metrics
│
├── World/                  # World generation & management
│   ├── World.ps1           # Chunk manager, loading/unloading, culling
│   ├── Chunk.ps1           # 16×256×16 voxel chunk with mesh gen
│   ├── TerrainGen.ps1      # Perlin noise terrain height maps
│   ├── Biomes.ps1          # Biome rules & climate system
│   └── Blocks.ps1          # Block type definitions & properties
│
├── Game/                   # Gameplay systems
│   ├── Player.ps1          # Player controller, movement, gravity
│   ├── Combat.ps1          # Melee combat, cooldowns, swing logic
│   ├── Enemy.ps1           # Enemy AI base behavior
│   ├── Enemies.ps1         # Zombie, Skeleton, Spider, Slime archetypes
│   ├── Inventory.ps1       # Inventory management & stacking
│   ├── Equipment.ps1       # Armor/weapon equip slots
│   ├── Tools.ps1           # Tool damage & durability
│   ├── Gathering.ps1       # Resource gathering mechanics
│   ├── Crafting.ps1        # Crafting recipes & system
│   ├── Stats.ps1           # Player stat sheet (HP, damage, defense)
│   ├── Interaction.ps1     # Block breaking & world interaction
│   ├── Experience.ps1      # XP gain & level thresholds
│   ├── LevelUp.ps1         # Level progression & stat increases
│   ├── Skills.ps1          # Skill tree (Combat/Crafting/Survival)
│   ├── SkillEffects.ps1    # Skill execution & passive effects
│   ├── StatProgression.ps1 # Long-term stat growth tracking
│   ├── Damage.ps1          # Damage calculation pipeline
│   ├── Quest.ps1           # Quest state machine & objectives
│   ├── NPC.ps1             # NPC entity management
│   ├── Dialog.ps1          # NPC dialogue system
│   ├── Death.ps1           # Death & respawn logic
│   ├── Reputation.ps1      # Faction reputation system
│   └── Rewards.ps1         # Reward distribution
│
├── Data/                   # Game content & persistence
│   ├── Items.ps1           # Item registry (30+ items)
│   ├── Quests.ps1          # Quest catalog
│   ├── Recipes.ps1         # Crafting recipes
│   ├── SaveLoad.ps1        # JSON save/load (3 slots)
│   └── Settings.ps1        # Settings persistence
│
├── UI/                     # User interface
│   ├── Menu.ps1            # Main/pause/settings menus
│   ├── HUD.ps1             # In-game heads-up display
│   ├── InventoryUI.ps1     # Inventory grid screen
│   ├── StatusBar.ps1       # HP/mana/stamina bars
│   ├── CombatUI.ps1        # Combat feedback & targeting
│   ├── QuestTracker.ps1    # Active quest objectives overlay
│   └── Minimap.ps1         # Minimap rendering
│
├── Tests/                  # Unit & integration tests
│   ├── Engine/
│   ├── Game/
│   ├── World/
│   └── Data/
│
└── .saves/                 # Save data (JSON)
    ├── settings.json
    ├── slot-01.json
    └── slot-02.json
```

---

## Architecture

### Game Loop

The engine uses a **callback-based game loop** registered through `Engine/OpenGL.ps1`. Each frame:

1. **Update phase** — all registered update callbacks run in order (input, physics, AI, game logic)
2. **Render phase** — all render callbacks run (world chunks, entities, HUD, UI overlays)

Delta-time is clamped per frame to prevent physics explosions on lag spikes.

### Rendering Pipeline

- **OpenGL 3.0+** core profile via OpenGL.Net
- **GLSL 1.30** shaders with directional lighting (diffuse + ambient)
- **Texture atlas** for all block faces — single draw call efficiency
- **VAO/VBO/EBO** per chunk mesh, rebuilt on chunk modification
- **Face culling** — only visible block faces are emitted to GPU
- **View frustum culling** — chunks outside the camera frustum skipped entirely
- **Transparent pass** — water blocks rendered last with blending

### World Generation

- **Chunk size:** 16×256×16 blocks
- **Algorithm:** 2D Perlin noise with 4-octave fractal Brownian motion
- **Height range:** 20–64 blocks above bedrock (base 38 + amplitude 24)
- **Seed:** Configurable (default 12345)
- **Chunk streaming:** Loads/unloads chunks within render distance around the player

### Block Types

| ID | Name     | Notes              |
|----|----------|--------------------|
| 0  | Air      | Transparent        |
| 1  | Stone    | Mineable           |
| 2  | Dirt     | Mineable           |
| 3  | Grass    | Top layer          |
| 4  | Sand     | Beaches            |
| 5  | Wood     | Tree trunks        |
| 6  | Leaves   | Tree foliage       |
| 7  | Water    | Semi-transparent   |

### Player Physics

- **Move speed:** 4.3 blocks/sec (5.6 sprinting)
- **Jump velocity:** 8.0 units/sec
- **Gravity:** 20.0 units/sec²
- **Terminal velocity:** −50.0 units/sec
- **Collision:** Per-axis AABB against block grid with wall sliding

### Combat

- **Attack rate:** 1.6 swings/sec (0.625s cooldown)
- **Melee reach:** 2.5 blocks
- **Blocking:** 50% damage reduction
- **Enemies:** Zombie (tank), Skeleton (ranged), Spider (fast), Slime (splits on death)

### Progression

- **XP system** with configurable level thresholds
- **Skill tree** across three categories: Combat, Crafting, Survival (30 skill cap)
- **Stat growth** per level-up (HP, damage, defense)
- **Equipment slots** for weapon + armor
- **Faction reputation** system affecting NPC behavior

### Save System

- 3 save slots stored as JSON in `.saves/`
- Saves: player position, inventory, stats, skills, quests, world state
- Settings saved separately in `.saves/settings.json`
- Auto-save on game exit

---

## Enemy Reference

| Enemy    | HP | Damage | Defense | Speed | Special            |
|----------|----|--------|---------|-------|--------------------|
| Zombie   | 45 | 7      | 2       | 1.25  | Slow tank          |
| Skeleton | 28 | 6      | 1       | 2.6   | Ranged (7.0 range) |
| Spider   | —  | —      | —       | Fast  | Leap attack        |
| Slime    | —  | —      | —       | —     | Splits on death    |

---

## Item Categories

| Category    | Examples                              |
|-------------|---------------------------------------|
| Resource    | Stone, Dirt, Wood, Cobblestone, Sand  |
| Tool        | Pickaxe (Wood/Stone/Iron)             |
| Weapon      | Sword (Wood/Stone/Iron)               |
| Armor       | Leather, Chain, Iron sets             |
| Consumable  | Food items, potions                   |

Resources stack up to 64. Equipment stacks to 1.

---

## Settings

All settings persist to `.saves/settings.json`. Configurable options:

**Video**
- Resolution: 1024×768 / 1280×720 / 1920×1080
- VSync: On / Off
- Render Distance: 1–8 chunks

**Audio**
- Master / Music / Effects volume (0–100)

**Controls**
- Full key rebinding for all 13 actions

---

## Technical Notes

- **No external game engine** — the entire 3D pipeline is hand-rolled in PowerShell
- **Interop layer** — OpenGL.Net provides C#→OpenGL bindings consumed via .NET reflection
- **Performance** — PowerShell overhead is real; complex scenes may drop below 60 FPS on weaker hardware
- **Shader compilation** — happens at startup; GLSL errors are printed to console
- **Thread model** — single-threaded; chunk generation is synchronous (a known bottleneck)

---

## License

MIT
