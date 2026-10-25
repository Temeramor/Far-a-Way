# Far a Way 0.1.0.9

Far a Way is a procedural first-person voxel landscape exploration game built with **Godot 4.7.2**. The experimental `feature/voxen-integration` branch integrates **VoxEn 0.3.5** for streamed block-voxel terrain while retaining the existing menu, animated sky, day/night cycle, weather controls, player controller, Windows input, Android touch controls and flight mode.

## Project overview

- **Genre:** first-person landscape exploration / procedural voxel terrain.
- **Engine:** Godot 4.7.2, Mobile renderer.
- **World:** seeded 10 × 10 km height-column voxel landscape with hierarchical LOD.
- **Voxel scale:** 10 cm logical height quantisation; mesh sampling becomes coarser with distance.
- **Targets:** Android ARM64 and Windows x86-64; native extension binaries are platform-specific.
- **Version:** `0.1.0.9`.

## Gameplay and controls

1. Open the project in Godot 4.7.2, let the editor import resources, press **F5**, and start a new game from the menu.
2. **Windows:** move with WASD / arrow keys and look with the mouse. Press **Esc** to pause.
3. **Android:** use the left-side touch joystick to move, drag on the right side to look, and use the pause button on the HUD.
4. Double-tap the right half of the screen (or double-tap Space on desktop) to toggle flight.
5. **VOXEN DEBUG** toggles streaming/LOD/collision/task diagnostics; **F3** toggles diagnostic LOD colours; **R** regenerates the landscape with a new seed.

## Graphics and lighting

- **Far depth blur** is an optional experiment with start-distance and strength sliders. It is **off by default** because it is not the primary fix for terrain shimmer.
- All voxel LOD meshes have shadow casting disabled. This stops voxel faces from producing terrain-wide shadow blocks and self-shadow speckles. Their regular directional/sky lighting remains enabled, so the terrain is still shaded rather than unlit.
- The voxel shader estimates projected 10 cm colour-cell size using fragment derivatives. When cells become sub-pixel, it blends random colour variation toward a stable material average; larger rock cracks are filtered separately. This targets shader-colour Moiré but cannot fix geometric/shadow aliasing by itself.
- These visual filters run in the renderer/GPU, not the native mesh builder. VoxEn C++ remains responsible for CPU mesh geometry and height-cache generation.

Disabling shadow casting avoids the extra shadow-map rendering of voxel chunks and should improve performance, especially with directional-light shadow cascades. It does not disable direct light or sky ambient contribution ([Godot shadow-casting settings](https://docs.godotengine.org/en/4.x/classes/class_geometryinstance3d.html), [shadow performance guidance](https://docs.godotengine.org/en/latest/tutorials/performance/gpu_optimization.html)).

## Native VoxEn extension

The repository contains native GDExtension sources but **does not commit compiled DLL/SO libraries**. If no compatible extension binary is installed, the game uses the GDScript mesh-builder fallback; a native build is recommended for performance.

Requirements: a C++ compiler/toolchain, Python 3.12+, SCons, Godot 4.7.2 C++ bindings (`godot-cpp` tag `10.0.0-stable`), and the Android NDK for Android builds.

From the project root:

```sh
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git native/godot-cpp
python -m pip install --upgrade scons
cd native
```

Linux x86-64:

```sh
scons platform=linux target=template_debug arch=x86_64
scons platform=linux target=template_release arch=x86_64
```

Windows x86-64 (from a shell where the native compiler is configured):

```sh
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
```

Android ARM64 (with the Android NDK environment configured):

```sh
scons platform=android target=template_debug arch=arm64
scons platform=android target=template_release arch=arm64
```

The extension descriptor is `bin/voxen_native.gdextension`; compiled outputs are expected under `bin/linux/`, `bin/windows/` and `bin/android/`. Do not commit generated libraries.

## Architecture and limitations

- **Native C++:** CPU mesh building, height-cache sampling, greedy top-face merging, exposed side faces, LOD skirts and collision-height data.
- **GDScript:** streaming/task priority, worker lifecycle, applying Godot rendering and physics resources on the main thread, UI, controls, sky/weather and world orchestration.
- **Startup and LOD:** coarse tiles cover the map first; parent tiles remain visible until their children are ready, preventing visible holes while detail increases.
- **Terrain model:** height-column voxels, not a full 3D volume. Enclosed caves, overhangs, arbitrary voxel editing and persistent voxel changes are not implemented yet.
- **Native binaries:** build separately for each target platform; compiled artifacts are intentionally excluded from the repository.

## Checks

With Godot 4.7.2 installed:

```sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
```

The smoke tests cover deterministic terrain generation and LOD hierarchy/mesh sampling; they do not yet verify native-vs-GDScript mesh parity.

Version history is maintained in [CHANGELOG.md](CHANGELOG.md).
