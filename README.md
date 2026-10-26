# Far a Way 0.1.0.1

Far a Way is a first-person exploration prototype focused on a large procedural voxel landscape. The project uses **Godot 4.7.2**, the **Forward+ renderer**, and a native C++ GDExtension for the CPU-intensive terrain chunk builder.

## Project status

- **Platform:** Windows x86-64.
- **Renderer:** Forward+.
- **World:** seeded landscape with a default area of 10 × 10 km.
- **Base terrain resolution:** 10 cm voxel height steps.
- **Default terrain view distance:** 4,096 m.
- **Version:** `0.1.0.1`.

The terrain is generated as height columns: each horizontal position has one generated surface height. Meshes and collisions are streamed around the player instead of creating a node for each voxel.

## Main menu and controls

The main menu contains **New Game**, **Settings** and **Exit**. New Game lets you enter a seed as a number or any text string; arbitrary text is converted to a deterministic integer, so the same input recreates the same landscape. The loading screen reports progress while the initial spawn terrain and collision are prepared.

The main-menu Settings page contains persistent controls for flight speed (**×1–×20**) and flight field of view (**82°–120°**), with Save, Cancel and Defaults actions.

In the world:

- **WASD / arrow keys:** move.
- **Mouse:** look around. Click to capture the mouse; pressing **Esc** releases it when the pause menu is opened.
- **Double-tap Space:** enable or disable flight. Flight follows the camera direction and uses the configured speed multiplier and FOV.
- **Esc:** open or close pause. The pause menu has Continue, Settings and Return to Menu actions. Its current Settings page shows the Forward+ / MSAA baseline notice.
- **M:** open or close the weather selector.
- **VOXEN DEBUG:** the on-screen debug control opens streaming, LOD, collision and worker-task diagnostics.

## Procedural terrain

The landscape uses a seed-controlled set of layered noise fields and seeded mountain chains. Mountain height and width scale with world size. Height samples remain continuous while cached/interpolated and are quantised to the 10 cm voxel grid at the final mesh-sampling stage.

The surface material blends grass and rock according to slope. The stylised palette uses pixel-scale colour variation and varied Voronoi-style cracks on nearer terrain; fine per-cell variation and crack calculations are reduced at distance. The upper voxel's vertical faces use the same grass/rock surface treatment as its top face, and material transitions are smoothed across chunk borders.

## Chunk streaming and level of detail

The world is divided into terrain chunks, generated in the background and prioritised as the player moves. Eight mesh sampling tiers progressively reduce geometry detail with distance:

| LOD | Sampling step |
|---|---:|
| LOD0 | 0.1 m |
| LOD1 | 0.2 m |
| LOD2 | 0.4 m |
| LOD3 | 0.8 m |
| LOD4 | 1.6 m |
| LOD5 | 3.2 m |
| LOD6 | 6.4 m |
| LOD7 | 12.8 m |

The default LOD0 boundary is 64 m, followed by a short 20 cm ring from 64 to 80 m; the later boundaries expand by powers of two to cover the distant landscape. The farthest tier uses a smooth shared-vertex heightfield surface, preserving broad mountain silhouettes without distant block-shaped risers.

Parent tiles remain visible until the required child tiles are ready, helping prevent temporary holes during refinement. A border halo, stitching skirts and neighbour-aware visibility keep adjacent chunks connected. The stream manager prioritises jobs using distance, view direction, velocity prediction and measured build/queue/apply timings. The worker-task limit adjusts to available CPU cores so scene management and rendering retain processing time.

## Lighting, weather and time of day

The sky system animates the sun, moon, stars and cloud layers, controls atmospheric fog and environmental lighting, and advances the in-game clock. The world HUD provides three weather presets — **Clear**, **Cloudy** and **Overcast** — plus time selection and the **Dawn**, **Day**, **Dusk** and **Night** presets.

Visible voxel meshes do not cast individual block shadows. Separate smooth terrain-shadow proxies cast the broader landform silhouettes, reducing the block-step shadow checkerboard. Proxy sampling is coarsened with distance; the directional shadow range is limited independently of terrain view distance, and visible surface shadowing fades at distant LODs.

The Forward+ renderer is selected with a baseline **MSAA ×2** profile and screen-space AA disabled. The pause-menu Settings page currently reports that baseline rather than exposing advanced graphics sliders.

## Native terrain builder

The Windows extension registers `VoxEnNativeBuilder` and is the production path for per-chunk CPU work. The C++ implementation includes:

- procedural terrain height and slope sampling from the world seed and mountain profile;
- continuous height caching, cubic interpolation and final voxel-height quantisation;
- greedy merging of top faces and creation of exposed side geometry;
- per-surface material weights, neighbour data, border halo handling and LOD stitching skirts;
- the smooth far-distance surface and separate terrain-shadow proxy meshes;
- collision height-map data;
- bulk vertex, normal, colour and index-array preparation for Godot.

Chunk build jobs are dispatched through Godot's `WorkerThreadPool`. GDScript manages world lifecycle, LOD coverage/visibility, job scheduling and priorities, attachment/retirement of render and physics nodes, player controls, menus, weather and time-of-day UI. A similarly structured GDScript mesh builder remains as a fallback for a project run without the native DLL; it is slower and should not be used to assess normal terrain-generation performance.

Compiled native binaries are not included in the repository. Build the extension for Windows after cloning and whenever its C++ sources change.

### Native build requirements

- Windows x86-64 and Visual Studio C++ Build Tools.
- Python 3.12+ and SCons.
- Godot 4.7.2 C++ bindings (`godot-cpp` tag `10.0.0-stable`).
- Godot 4.7.2 using Forward+ and a compatible graphics driver.

Run from the project root:

```powershell
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git native/godot-cpp
python -m pip install --upgrade scons
cd native
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
```

The extension descriptor is `bin/voxen_native.gdextension`; output DLLs belong under `bin/windows/`.

## Project layout

- `scripts/menu/`: main menu, seed input and persistent flight settings.
- `scripts/world/`: world lifecycle, startup loading, weather/time controls and world HUD.
- `scripts/voxel_world.gd`: streamed chunk coverage, hierarchical LOD, job scheduling and diagnostics.
- `scripts/voxel_chunk.gd`: render/collision resource application and retirement for each chunk.
- `scripts/voxel_generator.gd`: deterministic terrain profile and surface-height queries.
- `scripts/voxel_chunk_mesh_builder_fallback.gd`: CPU mesh-builder fallback.
- `native/src/`: native C++ terrain builder and GDExtension registration.
- `scripts/sky/` and `shaders/sky/`: sky, clock, cloud and atmospheric-fog systems.
- `scripts/player/` and `scripts/ui/`: player control, loading screen and pause menu.
- `shaders/voxel_surface.gdshader`: procedural terrain material.

## Current limits and verification

The terrain is a height-column model rather than a full 3D voxel volume. It does not currently support arbitrary voxel editing, persistent terrain modification, enclosed caves or overhangs. Chunk collision uses height-map data consistent with this terrain model.

With Godot 4.7.2 installed, check resource import and script parsing:

```powershell
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/terrain_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
```

After building the Windows DLL, also run the native smoke test:

```powershell
godot --headless --path . --script res://tests/native_builder_smoke_test.gd
```

The native smoke test checks generated geometry arrays and collision height-map output. It reports a skip when the extension is not loaded, so a passing verification requires the DLL to be present. Then run the project and check rendering and streaming on the target GPU.
