# Far a Way 0.1.0.10

Far a Way is a first-person landscape exploration prototype built with **Godot 4.7.2** and the Mobile renderer. It combines a height-column voxel terrain, streamed hierarchical LOD, a stylized procedural surface material, animated sky, weather/day-night controls, Android touch input and Windows keyboard/mouse controls.

## Project overview

- **Genre:** first-person landscape exploration / procedural voxel terrain.
- **Engine:** Godot 4.7.2, Mobile renderer.
- **World:** seeded 10 × 10 km height-column landscape.
- **Logical height quantisation:** 10 cm.
- **Targets:** Android ARM64 and Windows x86-64; native GDExtension binaries are platform-specific.
- **Version:** `0.1.0.10`.

## Controls

1. Open the project in Godot 4.7.2, allow resources to import, press **F5**, and start a new game from the menu.
2. **Windows:** move with WASD / arrow keys, look with the mouse, press **Esc** to pause.
3. **Android:** use the left-side touch joystick to move, drag on the right side to look, and use the pause button on the HUD.
4. Double-tap the right half of the screen (or double-tap Space on desktop) to toggle flight.
5. **VOXEN DEBUG** displays streaming/LOD/collision/task diagnostics; **F3** toggles debug LOD colours; **R** regenerates the landscape with a new seed.

## Terrain detail, filtering and shadows

- Eight sampling levels use steps of 10 cm, 20 cm, 40 cm, 80 cm, 1.6 m, 3.2 m, 6.4 m and 12.8 m. The 20 cm tier occupies a short 64–80 m ring; the former distance bands for larger steps otherwise remain intact. LOD7 uses a smooth shared-vertex heightfield at the same 12.8 m sampling interval, preserving distant mountain silhouettes without the obvious cuboid risers.
- The normal walking camera uses vertical FOV 82°. At 1080p, a 10 cm cell projects to about one pixel at 62 m: `pixels ≈ cell_size × 1080 / (2 × tan(FOV/2) × distance)`. This is why the default LOD0 boundary remains 64 m. Flight FOV is wider, so the same terrain has a different projected size.
- Visible voxel meshes do **not** cast shadows. Separate, smooth heightfield proxies represent the continuous landform silhouette so mountains can shadow nearby terrain without casting individual block-step shadows.
- Directional shadow distance is capped at 1,024 m independently of the default 4,096 m terrain view distance. Shadow proxy sampling becomes coarser with LOD, keeping the proxy near a bounded grid density. Top surfaces receive gradually attenuated landform shadows through LOD5; LOD6+ lies beyond the active shadow range. Vertical voxel walls never receive shadow attenuation, so the smooth proxy can shade the terrain without creating a shadow checkerboard.
- LOD3 and farther use a cheaper low-frequency material path. Fine per-cell colour variation, warped crack fields and Voronoi searches are skipped for those distant tiers. Near the player, procedural details are also skipped when their screen-space contribution becomes negligible.
- Lighting is softened on 10 cm vertical risers when those risers become sub-pixel, reducing dark contour-like Moiré bands without enabling MSAA ×4 for the whole frame. MSAA and screen-space AA are off in the default mobile profile.
- Graphics settings are automatic; the pause menu retains the same visual style but no longer exposes experimental AA, shadow-mode, or view-distance sliders. Old persisted graphics overrides are cleared on upgrade.

## Native VoxEn extension

Native C++ handles height sampling, greedy top-face merging, exposed side faces, stitching skirts, smooth terrain-shadow proxy generation, collision height-map data, and conversion of generated geometry to Godot packed arrays when a compatible GDExtension is installed. The GDScript fallback remains available when the extension is absent.

The repository does not commit compiled DLL/SO files. Build the native extension separately for every target platform.

Requirements: a C++ toolchain, Python 3.12+, SCons, Godot 4.7.2 C++ bindings (`godot-cpp` tag `10.0.0-stable`), and the Android NDK for Android builds.

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

Windows x86-64:

```sh
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
```

Android ARM64 (with the Android NDK environment configured):

```sh
scons platform=android target=template_debug arch=arm64
scons platform=android target=template_release arch=arm64
```

The extension descriptor is `bin/voxen_native.gdextension`; compiled outputs are expected under `bin/linux/`, `bin/windows/` and `bin/android/`. Do not commit generated libraries. Rebuild the extension after changing native sources.

## Architecture and limitations

- **Native C++:** mesh generation and packed-array transfer; heavy per-chunk work runs in worker threads.
- **GDScript:** streaming priorities, LOD hierarchy visibility, worker lifecycle, attachment of render/physics resources, UI, controls, sky/weather and world orchestration.
- **Streaming:** larger parent tiles remain visible until child tiles are ready, avoiding temporary holes during refinement. The worker cap is conservative to leave CPU time available for the mobile renderer.
- **Terrain model:** height-column terrain rather than a full 3D voxel volume. Enclosed caves, overhangs, arbitrary voxel editing and persistent terrain changes are not implemented yet.
- **Native binaries:** build separately for each target; compiled artifacts are intentionally excluded from the repository.

## Checks

With Godot 4.7.2 installed:

```sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
```

The tests cover terrain generation and LOD hierarchy/mesh sampling; the visual result still requires checking on the target Android device, and the native extension needs rebuilding to include the C++ changes.

Version history is maintained in [CHANGELOG.md](CHANGELOG.md).
