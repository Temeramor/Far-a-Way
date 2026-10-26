# Far a Way 0.1.0.1

Far a Way is a first-person exploration prototype focused on a large procedural voxel landscape. The project uses **Godot 4.7.2**, the **Forward+ renderer**, and a native C++ GDExtension for the expensive per-chunk terrain mesh work.

## Project status

- **Platform:** Windows x86-64.
- **Renderer:** Forward+.
- **World:** seeded landscape with a default area of 10 × 10 km.
- **Terrain resolution:** 10 cm base voxel height steps.
- **Default view distance:** 4,096 m.
- **Project version:** `0.1.0.1`.

The terrain is a height-column landscape: each horizontal position has a generated surface height. It is not a fully editable 3D voxel volume.

## Controls

- **WASD / arrow keys:** move.
- **Mouse:** look around.
- **Esc:** pause or resume. The pause menu includes Continue, Settings and Return to Menu.
- **Double-tap Space:** toggle flight.
- **M:** open or close the weather and time-of-day menu.
- **R:** regenerate the landscape with a new seed.
- **F3:** toggle debug colours for terrain LOD levels.
- **VOXEN DEBUG:** show terrain streaming, LOD, collision and worker-task diagnostics.

The world HUD also provides weather and time-of-day controls. Available weather presets are Clear, Cloudy and Overcast; time can be adjusted with the available controls and presets. The sky system animates the sun, moon, stars and cloud layers and manages atmospheric fog and environmental lighting. The Settings page in the pause menu is currently informational; adjustable graphics options have not been added yet.

## Procedural terrain

The landscape is generated from a seed using several noise fields and seeded mountain chains. Mountain height and width scale with the chosen world size, and the terrain surface stays continuous until interpolation is complete and the final height is quantised to the voxel grid.

The surface material blends grass and rock according to terrain slope. Rock regions use a stylised pixel palette and varied Voronoi-style cracks. The blend is continuous across chunk borders, and the upper voxel's side faces use the same grass/rock surface treatment as the top face. Distant LOD levels use a cheaper material path that skips fine per-cell variation and crack calculations when they contribute little to the final image.

## Streaming and level of detail

Terrain is split into chunks and streamed around the player. Eight sampling tiers progressively reduce mesh density with distance:

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

The nearest tier extends to roughly 64 m, with a short intermediate 20 cm ring between 64 and 80 m; larger rings handle successively more distant terrain out to the default view distance. The farthest tier uses a smooth shared-vertex surface to preserve large landform silhouettes without distant block-shaped risers.

The hierarchy keeps a parent tile visible until the required child tiles are ready, avoiding holes during LOD refinement. A one-cell border halo, stitching skirts and neighbour-aware visibility help keep adjacent chunks visually connected. Streaming requests are prioritised by distance, view direction and predicted movement. Build-time estimates and queue/apply timings feed the priority model, while a bounded worker-task queue preserves time for rendering and main-thread scene work.

## Lighting and shadows

Visible voxel meshes do not cast individual block shadows. Instead, each streamed LOD can provide a separate, smoother terrain-shadow proxy, allowing broad mountain silhouettes and landform shading without the checkerboard effect of dense block-step shadows. Proxy density is reduced with distance, the directional shadow range is capped independently of the terrain view distance, and fine surface shadow attenuation fades at distant LOD levels.

The project uses a baseline MSAA ×2 profile with screen-space AA disabled. Forward+ is selected as the desktop renderer. Additional advanced rendering effects are not currently enabled by default.

## Native terrain builder

The native extension is registered as `VoxEnNativeBuilder` and is preferred whenever the Windows DLL is available. It handles the CPU-intensive per-chunk operations in C++:

- procedural height and slope sampling for mesh generation;
- continuous height caching, cubic interpolation and final voxel-height quantisation;
- greedy merging of top faces and generation of exposed side faces;
- terrain material weights, chunk-border halo handling and LOD stitching skirts;
- smooth far-surface and terrain-shadow proxy geometry;
- collision height-map data;
- bulk preparation of vertex, normal, colour and index arrays for Godot.

Chunk jobs run through `WorkerThreadPool`. GDScript remains responsible for high-level world streaming, hierarchy/visibility decisions, job scheduling, attaching mesh and physics resources, player/gameplay orchestration, UI, and the sky/weather controls. A GDScript mesh builder remains available as a compatibility fallback if the native extension is missing; normal performance should be evaluated with the native Windows build installed.

The repository does not include compiled native binaries. Rebuild the extension after changing C++ sources.

### Build requirements

- Windows x86-64 and Visual Studio C++ Build Tools.
- Python 3.12+ and SCons.
- Godot 4.7.2 C++ bindings (`godot-cpp` tag `10.0.0-stable`).
- Godot 4.7.2 using Forward+ and a compatible graphics driver.

From the project root:

```powershell
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git native/godot-cpp
python -m pip install --upgrade scons
cd native
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
```

The extension descriptor is `bin/voxen_native.gdextension`; output DLLs belong under `bin/windows/`.

## Code layout

- `scripts/world/`: world controller and terrain-generation lifecycle adapter.
- `scripts/voxel_world.gd`: chunk streaming, LOD hierarchy, task scheduling and diagnostics.
- `scripts/voxel_chunk.gd`: attaches and retires render and collision resources for a chunk.
- `scripts/voxel_generator.gd`: deterministic terrain profile and surface queries used by gameplay and fallback paths.
- `scripts/voxel_chunk_mesh_builder_fallback.gd`: CPU mesh-builder fallback for when the native extension is unavailable.
- `native/src/`: native C++ mesh builder and GDExtension registration.
- `scripts/sky/` and `shaders/sky/`: sky, time-of-day, cloud and atmospheric-fog systems.
- `scripts/player/` and `scripts/ui/`: player controller and menus/HUD.
- `shaders/voxel_surface.gdshader`: procedural terrain surface material.

## Current limits and checks

The current landscape does not provide arbitrary voxel editing, persistent terrain modification, enclosed caves or overhangs. Chunk collision uses height-map data, matching the height-column terrain model.

With Godot 4.7.2 installed, check that resources import and scripts parse:

```powershell
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/terrain_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
```

Rendering and native performance should also be verified by running the project with the rebuilt Windows extension on the target GPU.

See [CHANGELOG.md](CHANGELOG.md) for the current baseline feature set.
