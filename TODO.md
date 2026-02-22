# TODO — PowerShell Voxel RPG

Tracked issues, planned features, and improvements. Items are grouped by module/area.

Legend: `[ ]` — not started · `[~]` — in progress · `[x]` — done

---

## HUD (`UI/HUD.ps1`)

- [ ] **Fix health bar not updating in real time** — the HP bar visually lags behind the actual player HP after taking damage; it only refreshes on the next full render cycle instead of immediately
- [ ] **Fix stamina bar depletion display** — stamina drains during sprinting but the bar stays full until the player stops moving
- [ ] **Fix mana bar visibility** — mana bar renders behind other HUD elements due to incorrect draw order
- [ ] **Add status effect icons** — display active buffs/debuffs (poison, burning, regeneration, slowness) as small icons with a countdown timer below the status bars
- [ ] **Add dynamic crosshair** — crosshair should expand when moving, contract when standing still, and turn red when an enemy is in melee range
- [ ] **Add hotbar for quick-access items** — a row of 9 slots at the bottom of the screen showing a subset of the inventory; cycle with scroll wheel or number keys 1–9
- [ ] **Add damage numbers** — floating damage values should pop up above an enemy on hit and fade out over ~0.8 seconds
- [ ] **Add XP progress bar** — thin bar at the bottom of the screen showing current XP toward next level, with a flash animation on level-up
- [ ] **Fix level indicator position** — the current level number overlaps with the minimap on low resolutions (< 1280 wide)
- [ ] **Add compass / direction indicator** — a compass strip or arrow at the top edge showing cardinal directions and quest marker bearing
- [ ] **Add interaction prompt** — when the player looks at an NPC or interactable block, show a contextual prompt (e.g. "Press E to talk" / "Press G to mine")

---

## Controls & Input (`Engine/Input.ps1`, `Game/Player.ps1`)

- [ ] **Fix diagonal movement speed** — moving diagonally (W+A or W+D) is ~41% faster than axis-aligned movement due to non-normalized direction vector; clamp resultant velocity to the configured move speed
- [ ] **Fix mouse sensitivity not applying from settings** — mouse sensitivity changed in the settings menu does not take effect until the game is restarted; apply it live inside `Update-Camera`
- [ ] **Fix jump buffering** — if the player presses Space a frame before landing, the jump should still fire; currently the input is swallowed
- [ ] **Fix sprint toggle behavior** — holding Shift while already jumping causes the sprint flag to persist after landing; reset sprint state on jump start
- [ ] **Add raw input support for mouse** — current mouse read uses `Form.MousePosition` polling which can lose delta on fast movements; switch to WM_INPUT or track accumulated `MouseMove` events
- [ ] **Add gamepad/controller support** — map left stick to movement, right stick to camera look, triggers to attack/block, bumpers to inventory navigation; use `XInput` via .NET PInvoke
- [ ] **Add key repeat suppression** — held keys currently fire every frame for single-action events (inventory open, attack toggle); add a `IsKeyJustPressed` helper distinct from `IsKeyHeld`
- [ ] **Add customizable dead zone for analog inputs** — when controller support lands, expose dead zone threshold in settings
- [ ] **Fix block placement ray offset** — placed blocks sometimes snap to the wrong face when the player is very close to a surface; recalculate hit normal from the fractional raycast position
- [ ] **Add crouch / sneak mechanic** — Left Ctrl to crouch, reducing player AABB height to ~1.4, halving movement speed, and preventing fall damage from edge-drops

---

## Graphics & Rendering (`Engine/OpenGL.ps1`, `Engine/Mesh.ps1`, `Engine/Shader.ps1`)

- [ ] **Add ambient occlusion** — calculate per-vertex AO from neighboring solid blocks during mesh generation to give corners a soft shadow that breaks up the flat-lit voxel look
- [ ] **Add fog / view distance fade** — blend distant chunks to a sky color based on depth to avoid a hard pop-in edge at the render distance boundary
- [ ] **Implement greedy meshing optimization** — current mesh generation emits one quad per visible block face; greedy meshing merges coplanar same-type faces into larger quads, reducing vertex count by 60–80% on flat terrain
- [ ] **Add skybox / sky dome** — replace the solid background clear color with a gradient sky (horizon to zenith), a sun billboard, and a moon phase billboard for the day-night cycle
- [ ] **Implement day-night cycle** — rotate a directional light over ~20-minute real-time cycle; adjust sky color temperature and light intensity from warm daylight → orange sunset → dark night → blue predawn
- [ ] **Add dynamic shadows** — implement a basic shadow map from the sun direction so terrain and entities cast shadows onto the ground (cascaded shadow map optional)
- [ ] **Add water shader effects** — animated UV scroll on water surface normals, Fresnel-based transparency (more opaque at shallow angles), and subtle refraction distortion of blocks seen through water
- [ ] **Improve entity rendering** — enemies are currently axis-aligned colored cubes; add segmented body parts (head, torso, arms, legs) with rotation offsets so limbs animate when moving and attacking
- [ ] **Add block breaking animation** — show progressive crack texture overlay (8 stages) on a block currently being mined, timed to the tool's harvest speed
- [ ] **Add particle system** — emit block debris particles on break, hit sparks on melee contact, XP orb particles on kill, and smoke particles from torches/fire
- [ ] **Improve chunk LOD** — at long render distances (> 5 chunks), render chunks at reduced detail (merged top surface only) to maintain frame rate on mid-range hardware
- [ ] **Add anti-aliasing** — enable MSAA 4× via the WinForms GlControl pixel format descriptor; expose the toggle in video settings
- [ ] **Fix z-fighting on flat terrain** — stone and dirt layers at the same Y plane flicker when the camera is far away; add a small polygon offset to subsurface layers during mesh gen
- [ ] **Add torch / point light sources** — place-able torch blocks that contribute a small radius warm point light via a simple forward-rendered point light accumulation pass

---

## Quest System (`Game/Quest.ps1`, `Data/Quests.ps1`, `UI/QuestTracker.ps1`)

- [ ] **Complete quest objective tracking** — Kill and Gather objective counters increment correctly but Explore and Talk objectives never advance; wire them up to the world travel event and dialog completion handlers respectively
- [ ] **Implement quest branching / conditional steps** — the data model for branched quests (using `QuestFlags`) is defined but no logic evaluates the flags at runtime; implement flag checks between steps
- [ ] **Fix quest completion detection** — completed objectives do not always trigger the quest's `Complete` transition; audit every `Update-QuestObjective` call site and ensure the state machine advances
- [ ] **Add quest hand-in dialogue** — when all objectives are complete the player must return to the quest giver NPC; currently hand-in auto-fires on objective completion with no final conversation
- [ ] **Add quest log screen** — a dedicated full-screen journal accessible from the pause menu listing all active and completed quests with full objective text, descriptions, and rewards preview
- [ ] **Implement quest chains** — multi-part quest sequences where completing one quest unlocks the next; requires a prerequisite check in `Start-Quest`
- [ ] **Add quest markers on minimap and compass** — show the bearing and distance to the quest target or quest-giver on the HUD compass and as a small icon on the minimap
- [ ] **Add timed quests** — certain quests should have a time limit countdown; failing to complete before expiry moves them to the Failed state and may have reputation consequences
- [ ] **Persist quest state across saves** — the active quest list is saved to slot JSON but the per-objective counters are lost on reload; include the full objective state in the serialized quest objects
- [ ] **Add world events / dynamic quests** — randomly trigger world events (bandit raid, resource shortage, monster surge) that generate temporary quests with scaled rewards based on player level

---

## Leveling & Skill Progression (`Game/Experience.ps1`, `Game/Skills.ps1`, `Game/LevelUp.ps1`)

- [ ] **Fix skill point assignment not persisting** — investing skill points during a session correctly modifies `$Script:Skills` and `$Script:SkillPoints`, but on save/load the skill point total is restored from the slot file while changes to individual skills are not fully rehydrated; synchronize the full skill state in `Save-GameState`
- [ ] **Implement skill tree UI** — there is no in-game screen to view or assign skill points; build a tree layout screen (accessible from inventory or its own key) showing the three branches (Combat, Crafting, Survival) with prerequisite arrows and a "Confirm" button
- [ ] **Wire up passive skill effects** — many `SkillEffects.ps1` entries define bonuses (e.g. +10% melee damage, -20% crafting cost) but the actual gameplay calculations do not read these multipliers; hook them into `Damage.ps1`, `Crafting.ps1`, and `Stats.ps1`
- [ ] **Add attribute / stat point system** — on level-up grant the player a configurable number of free stat points to distribute between Strength, Agility, Endurance, and Intelligence that feed into derived stats (bonus damage, crit, HP pool, mana pool)
- [ ] **Implement prestige / ascension system** — allow resetting to level 1 with a permanent prestige bonus (e.g. +5% XP gain per prestige level) for end-game replayability
- [ ] **Add skill unlock notifications** — after a level-up display a modal or toast telling the player how many skill points they received and which skills became available
- [ ] **Balance XP curve** — the current exponential curve reaches level 30 too quickly in the first hour of play; re-tune the XP thresholds and enemy XP values with a proper progression spreadsheet
- [ ] **Add expertise / mastery system** — repeated use of a specific action (mining, swordfighting, crafting) contributes hidden proficiency XP to a sub-skill that unlocks mastery bonuses independent of the character level

---

## Crafting & Economy (`Game/Crafting.ps1`, `Data/Recipes.ps1`, `Data/Items.ps1`)

- [ ] **Add crafting UI screen** — no in-game interface exists to browse recipes; implement a grid-based crafting table screen (3×3 input grid + output slot) accessible from the inventory
- [ ] **Add recipe discovery system** — recipes should start hidden and become visible when the player first picks up a required ingredient
- [ ] **Balance item values and drop rates** — iron-tier items are too cheap relative to the effort to obtain iron; rebalance shop prices, crafting costs, and mob drop probabilities
- [ ] **Implement a shop / merchant NPC** — allow trading items for currency with NPC merchants; prices shift based on faction reputation
- [ ] **Add item durability** — weapons and tools should degrade over use; when durability reaches 0 the item breaks and must be repaired at a crafting station or with the appropriate skill
- [ ] **Add more item types** — potions (HP/stamina restore, speed boost, night vision), food (cooked meals with saturation), ranged weapons (bow + arrow), and spell scrolls (one-use magical abilities)

---

## World & Terrain (`World/World.ps1`, `World/TerrainGen.ps1`, `World/Biomes.ps1`)

- [ ] **Fix chunk seam artifacts** — visible one-block gaps or mismatched faces appear along chunk boundaries due to the mesh generator not sampling neighbor chunks for face-cull decisions; pass adjacent chunk data into `Build-ChunkMesh`
- [ ] **Add more biomes** — current biome system defines climate rules but only a few biomes are active; add Desert, Snowy Tundra, Forest, Swamp, and Ocean with appropriate block palettes and terrain shapes
- [ ] **Implement structure generation** — procedurally place trees, caves, dungeons, villages, and abandoned towers using prefab templates stamped into the terrain at generation time
- [ ] **Add underground cave systems** — use 3D Perlin noise thresholding to carve cave networks through stone layers; include ore veins (coal, iron, gold, diamond at increasing depths)
- [ ] **Implement async chunk generation** — chunk generation currently runs synchronously on the main thread and causes visible stutter when entering new areas; move it to a background runspace with a thread-safe queue
- [ ] **Add world border / map limits** — define a maximum world size and display a warning when the player approaches; prevent chunk generation beyond the limit
- [ ] **Improve water physics** — water currently does not flow between blocks; implement a simple cellular automaton water spread (flow to air neighbors up to a max spread radius)

---

## AI & Enemies (`Game/Enemy.ps1`, `Game/Enemies.ps1`)

- [ ] **Implement pathfinding** — enemies currently walk in a straight line toward the player ignoring terrain; implement a simple A* or flow-field pathfinder over the block grid so enemies navigate around walls and over ledges
- [ ] **Add idle / patrol behavior** — when the player is out of detection range enemies should wander randomly within a home area rather than standing frozen
- [ ] **Improve skeleton ranged attack** — skeleton fires projectiles but the projectile entity is invisible (no mesh is created); implement an arrow mesh and flight arc
- [ ] **Add boss enemies** — design 2–3 boss encounters with high HP, multi-phase attack patterns, and unique loot drops
- [ ] **Add enemy respawn system** — enemies that are killed should respawn after a configurable timer in their original area; currently the world permanently depopulates
- [ ] **Fix enemy stacking / overlap** — multiple enemies can occupy the same block space; add separation forces between entities

---

## Multiplayer

- [ ] **Design network architecture** — decide on client-server authoritative model vs. peer-to-peer; given the PowerShell environment the most viable path is a lightweight TCP server hosted by one player with client connections via `System.Net.Sockets.TcpClient`
- [ ] **Implement server host mode** — allow one player to start a local server that listens on a configurable port; serialize world state and player positions for broadcast
- [ ] **Implement client connection** — build a client that connects to a host's IP/port, receives world chunks on demand, and sends local player input each tick
- [ ] **Add player entity rendering for remote players** — display other players as distinct colored humanoid voxel models with username labels
- [ ] **Synchronize combat and damage** — damage events must be validated server-side to prevent cheating; broadcast enemy HP changes and player death events to all clients
- [ ] **Add chat system** — simple in-game text chat with a toggle key (T), rendered as an overlay in the bottom-left of the HUD
- [ ] **Handle player join/leave gracefully** — notify all connected players when someone joins or disconnects; do not crash the host if a client drops
- [ ] **Persist shared world state** — the host's save slot should store the state for all players; guests carry their own inventory/level but share the same world map

---

## Audio

- [ ] **Implement audio engine** — currently no audio plays; integrate `System.Media.SoundPlayer` for simple WAV playback or `NAudio` for OGG/MP3 support
- [ ] **Add footstep sounds** — play material-specific step sounds (grass, stone, sand, water splash) based on the block beneath the player
- [ ] **Add ambient sounds** — looping background sounds (wind, distant bird calls, cave drip) that blend based on the current biome and depth
- [ ] **Add combat sounds** — sword swing, hit impact, block parry, and enemy death sounds
- [ ] **Add music tracks** — distinct background music for the main menu, daytime exploration, night, and combat encounters; cross-fade between tracks

---

## UI / UX Polish

- [ ] **Add tooltip system** — hovering over an item in the inventory or hotbar shows a tooltip card with the item's name, type, stats, and description
- [ ] **Improve inventory drag-and-drop** — currently items can only be moved by clicking two separate slots; add proper mouse drag to reorder inventory items
- [ ] **Add settings validation** — if the player sets a resolution their GPU does not support the game should fall back gracefully rather than crashing
- [ ] **Add a loading screen** — replace the blank window during initial world generation with a loading bar and a tip text rotation
- [ ] **Add death screen** — on player death show a "You Died" screen with options to respawn at the world spawn or load the last save
- [ ] **Add achievement system** — define 20–30 achievements (First Kill, Level 10, Build a House, etc.) with a notification toast on unlock and a viewable achievement log

---

## Performance & Stability

- [ ] **Profile and fix frame drops on chunk load** — the primary performance bottleneck is synchronous chunk mesh rebuilding; measure with `Performance.ps1` and identify the worst-case per-frame budget violation
- [ ] **Add crash recovery** — wrap the main game loop in a try/catch that writes a crash log to `logs/crash.txt` with the last 200 frames of performance data and the exception message
- [ ] **Add an automated test suite** — the `Tests/` directory structure exists but most test files are empty; write at minimum unit tests for Math, TerrainGen, Inventory, Combat damage calculations, and SaveLoad round-trips
- [ ] **Fix memory leak on chunk unload** — unloaded chunks delete their block data but do not call `glDeleteBuffers` / `glDeleteVertexArrays` on their VAO/VBO resources; add a disposal step in `Remove-Chunk`
- [ ] **Add configurable render distance cap warning** — at render distance ≥ 7, warn the player in settings that performance may degrade significantly on integrated graphics

---

## Code Quality & Architecture

- [ ] **Standardize error handling** — many functions silently swallow errors; use `$ErrorActionPreference = 'Stop'` within module scopes and propagate fatal errors to the main loop
- [ ] **Add module-level documentation headers** — each `.ps1` file should have a top-of-file comment block stating purpose, public functions, and dependencies
- [ ] **Refactor global state** — many `$Script:` and `$Global:` variables are accessed across module boundaries without a clear ownership model; introduce a central game state object passed by reference
- [ ] **Unify naming conventions** — some functions use `Verb-Noun`, others use camelCase or PascalCase directly; align everything to PowerShell approved verb conventions
- [ ] **Clean up tmp files** — multiple `tmpclaude-*` directories exist in the working tree from development sessions; add them to `.gitignore` and delete them
