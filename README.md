# Far a Way 0.1.0.6

Far a Way is a first-person exploration prototype focused on a large procedural voxel landscape. The project uses **Godot 4.7.2**, the **Forward+ renderer**, and a native C++ GDExtension for the CPU-intensive terrain chunk builder.

## Project status

- **Platform:** Windows x86-64.
- **Renderer:** Forward+.
- **World:** seeded landscape with a default area of 2 × 2 km.
- **Base terrain resolution:** 20 cm voxel cells on X, Y and Z.
- **Default terrain view distance:** 4,096 m.
- **Coarsest voxel cell:** 25.6 m at the farthest LOD.
- **Version:** `0.1.0.6`.

The terrain is generated as height columns: each horizontal position has one generated surface height. Meshes and collisions are streamed around the player instead of creating a node for each voxel.

Surface decoration is streamed separately from terrain. Grass and flowers use two prop detail tiers: full 10 cm source voxels nearby, downsampled 20 cm voxels in the next tier, and no plants in prop LOD2 or farther. The plant mesh uses a wind shader whose sway and gusts follow Clear, Cloudy and Overcast weather; roots stay anchored while upper vertices move. Plants and stones cast shadows. Ground stones and boulders retain 10 cm voxels at every prop tier; farther tiers reduce stone density, size range and surface noise through LOD3 instead of enlarging each voxel. Mountain ribs are built as axis-aligned voxel cells whose size matches the active terrain LOD; they follow a downhill-to-crest trace and are embedded into the slope. Stone, rib and vegetation placement use a shared exclusion map. The terrain still comes from the original seeded height algorithm; no imported object meshes are used.

## Main menu and controls

The main menu contains **New Game**, **Settings** and **Exit**. New Game lets you enter a seed as a number or any text string; arbitrary text is converted to a deterministic integer, so the same input recreates the same landscape. The loading screen reports progress while the initial spawn terrain and collision are prepared.

The main-menu Settings page contains persistent controls for flight speed (**×1–×20**) and flight field of view (**82°–120°**), with Save, Cancel and Defaults actions.

In the world:

- **WASD / arrow keys:** move.
- **Mouse:** look around. Click to capture the mouse; pressing **Esc** releases it when the pause menu is opened.
- **Double-tap Space:** enable or disable flight. Flight follows the camera direction and uses the configured speed multiplier and FOV.
- **Esc:** open or close pause. The pause menu has Continue, Settings and Return to Menu actions.
- **F3:** open or close the VoxEn diagnostics overlay, with FPS, frame time, LOD distribution, worker queue timings, chunk geometry counts and video-memory usage.
- **F4:** toggle shader-based LOD colours for visualising the active terrain tiers without rebuilding chunk meshes.
- **M:** open or close the weather and time menu.
- **Settings:** choose windowed or fullscreen mode and a resolution from 640 × 360 to 2560 × 1440. Windowed mode resizes to the selected dimensions.

## Procedural terrain

The 2 × 2 km landscape uses layered seeded noise and two seeded mountain chains (six connected ridge segments). Noise frequencies adapt to map size so macro hills, secondary ridges and small landforms remain visible at this scale. Mountain height, width, lateral irregularity and spawn-area fade scale with the world size; warped ridge flanks and a sharper, multi-crest profile add more natural rocky shoulders. Height samples remain continuous while cached/interpolated; visible geometry quantises height to the active LOD cell step, from 20 cm at LOD0 to 25.6 m at LOD7, so distant cells keep voxel-like proportions.

The surface material blends grass and rock according to slope. Every LOD keeps a discrete colour sample per current voxel cell, from 20 cm at LOD0 to 25.6 m at LOD7, rather than fading to a uniform colour with screen distance. Rock colour is generated in the shader: stochastic stone hues, warped mineral bedding, broken strata, weathered pits, fine grain and a multi-scale crack network. Coarser LODs keep broad mineral bands and colour roughness while dropping sub-pixel fissures to reduce shimmer. The shader also varies roughness procedurally, with no imported rock-image dependency. The upper voxel's vertical faces use the same grass/rock surface treatment as its top face, and material transitions are smoothed across chunk borders.

## Chunk streaming and level of detail

The world is divided into terrain chunks, generated in the background and prioritised as the player moves. Eight mesh sampling tiers progressively reduce geometry detail with distance:

| LOD | Horizontal and vertical voxel step |
|---|---:|
| LOD0 | 0.2 m |
| LOD1 | 0.4 m |
| LOD2 | 0.8 m |
| LOD3 | 1.6 m |
| LOD4 | 3.2 m |
| LOD5 | 6.4 m |
| LOD6 | 12.8 m |
| LOD7 | 25.6 m |

Every visible LOD uses voxel faces. Greedy merging of top faces and matching side runs, plus exposed risers and stitching skirts, preserve the block style; the invisible smooth heightfield is reserved for terrain-shadow proxies. Each LOD quantises both horizontal and vertical detail to its own voxel step, so the farthest levels remain voxel terrain rather than a smooth heightfield.

LOD boundaries are calculated from the active viewport height and an 82° design vertical FOV. The next tier's voxel step reaches half a screen pixel at each boundary, and a 5% hysteresis prevents rapid switching around thresholds. The boundaries scale with resolution; at 720p, 900p, 1080p and 1440p they are:

| Resolution | LOD0→1 | 1→2 | 2→3 | 3→4 | 4→5 | 5→6 | 6→7 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 720p | 331 m | 663 m | 1,325 m | 2,650 m | 5,301 m | 10,602 m | 21,204 m |
| 900p | 414 m | 828 m | 1,657 m | 3,313 m | 6,626 m | 13,252 m | 26,504 m |
| 1080p | 497 m | 994 m | 1,988 m | 3,976 m | 7,951 m | 15,903 m | 31,805 m |
| 1440p (2K-class) | 663 m | 1,325 m | 2,650 m | 5,301 m | 10,602 m | 21,204 m | 42,407 m |

Parent tiles remain visible until the required child coverage is ready. Their hidden meshes stay cached while nearby child LODs are active, so crossing a tile boundary can restore a parent immediately instead of rebuilding the full tile. Near terrain colliders remain active even while their visual chunks are hidden beneath a fallback parent, and collision jobs are prioritised ahead of non-critical visual detail. A border halo, stitching skirts and neighbour-aware visibility keep adjacent chunks connected. The stream manager uses Euclidean 3D distance to the generated terrain surface, including altitude during flight, and prioritises jobs using view direction, velocity prediction and measured build/queue/apply timings. Full hierarchy scans are coalesced to one refresh, while mesh uploads update only the affected LOD root and adjacent skirts.

## Lighting, weather and time of day

The sky system animates the sun, moon, stars and cloud layers, controls atmospheric fog and environmental lighting, and advances the in-game clock. The world HUD provides three weather presets — **Clear**, **Cloudy** and **Overcast** — plus time selection and the **Dawn**, **Day**, **Dusk** and **Night** presets.

Visible voxel meshes do not cast individual block shadows. The native C++ chunk builder generates a separate continuous, non-voxel heightfield proxy that preserves broad mountain and hill silhouettes; proxy vertices follow the generated terrain height without an artificial vertical offset. Directional shadow-map attenuation on upper faces fades continuously with camera distance from 20% at 40 m to 0% at 500 m, avoiding fixed per-LOD brightness steps and visible seams. Vertical voxel sides are handled separately from shadow strength: wrap lighting and a soft directional fill reduce the dark appearance of faces turned away from the sun. Side fill is not shadow-map attenuation, and broad landform shadows remain available through the smooth proxy.

The Forward+ renderer is selected with a baseline **MSAA ×2** profile and screen-space AA disabled. The pause-menu Settings page currently reports that baseline rather than exposing advanced graphics sliders.

## Native terrain builder

The Windows extension registers `VoxEnNativeBuilder` and is the production path for per-chunk CPU work. The C++ implementation includes:

- procedural terrain height and slope sampling from the world seed and mountain profile;
- continuous height caching, cubic interpolation and final voxel-height quantisation;
- greedy merging of top faces and creation of exposed side geometry;
- per-surface material weights, neighbour data, border halo handling and LOD stitching skirts;
- voxel surface meshes at all LODs and separate smooth terrain-shadow proxy meshes;
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
- `scripts/world/`: world lifecycle, startup loading, weather/time controls, world HUD, plus separate streamed rock, mountain-rib and vegetation generators.
- `scripts/vegetation/`: voxel grid, colour palette and mesh accumulator used by rocks, grass and flowers.
- `scripts/voxel_world.gd`: streamed chunk coverage, hierarchical LOD, job scheduling and diagnostics.
- `scripts/voxel_chunk.gd`: render/collision resource application and retirement for each chunk.
- `scripts/voxel_generator.gd`: deterministic terrain profile and surface-height queries.
- `scripts/voxel_chunk_mesh_builder_fallback.gd`: CPU mesh-builder fallback.
- `native/src/`: native C++ terrain builder and GDExtension registration.
- `scripts/sky/` and `shaders/sky/`: sky, clock, cloud and atmospheric-fog systems.
- `scripts/player/` and `scripts/ui/`: player control, loading screen and pause menu.
- `shaders/voxel_surface.gdshader`: procedural terrain material.
- `shaders/vegetation_wind.gdshader`: weather-responsive plant motion.

## Current limits and verification

The 2 × 2 km terrain is a height-column model rather than a full 3D voxel volume. It does not currently support arbitrary voxel editing, persistent terrain modification, enclosed caves or overhangs. Chunk collision uses height-map data consistent with this terrain model. The native C++ builder already handles the main terrain mesh, collision-height data and smooth shadow proxy. Decoration placement and voxel generation remain in GDScript and are scheduled one tile at a time. Distant boulders use fewer placements and less surface noise, but retain the required 10 cm voxel size. The remaining candidates to measure on the Windows build are near-field rock-grid filling, mountain-rib cell/face generation and plant placement. Port only the parts that profiling identifies as bottlenecks; native code must be built and compared on the target machine before it can replace the existing GDScript fallback.

With Godot 4.7.2 installed, check resource import and script parsing:

```powershell
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/terrain_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
godot --headless --path . --script res://tests/shadow_lod_smoke_test.gd
godot --headless --path . --script res://tests/voxel_surface_scatter_smoke_test.gd
```

After building the Windows DLL, also run the native smoke test:

```powershell
godot --headless --path . --script res://tests/native_builder_smoke_test.gd
```

The native smoke test checks generated geometry arrays and collision height-map output. It reports a skip when the extension is not loaded, so a passing verification requires the DLL to be present. Then run the project and check rendering and streaming on the target GPU.
