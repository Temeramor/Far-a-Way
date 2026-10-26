# Far a Way 0.1.0.12

Far a Way is a first-person landscape exploration prototype built with **Godot 4.7.2** and the **Forward+ renderer**. It combines height-column voxel terrain, streamed hierarchical LOD, a stylized procedural surface material, animated sky, weather/day-night controls and keyboard/mouse controls.

## Project overview

- **Genre:** first-person landscape exploration / procedural voxel terrain.
- **Engine:** Godot 4.7.2, Forward+ renderer.
- **World:** seeded 10 × 10 km height-column landscape.
- **Logical height quantisation:** 10 cm.
- **Target:** Windows x86-64 only. Android and Linux are no longer maintained targets for this branch; the native extension descriptor only lists Windows builds.
- **Version:** `0.1.0.12`.

## Controls

1. Open the project in Godot 4.7.2, allow resources to import, press **F5**, and start a new game from the menu.
2. Move with WASD / arrow keys, look with the mouse, and press **Esc** to pause.
3. Double-tap **Space** to toggle flight.
4. **VOXEN DEBUG** displays streaming/LOD/collision/task diagnostics; **F3** toggles debug LOD colours; **R** regenerates the landscape with a new seed.

## Terrain detail, filtering and shadows

- Eight sampling levels use steps of 10 cm, 20 cm, 40 cm, 80 cm, 1.6 m, 3.2 m, 6.4 m and 12.8 m. The 20 cm tier occupies a short 64–80 m ring; the former distance bands for larger steps otherwise remain intact. LOD7 uses a smooth shared-vertex heightfield at the same 12.8 m sampling interval, preserving distant mountain silhouettes without the obvious cuboid risers.
- Height samples stay continuous in the mesh cache and are quantised to the 10 cm voxel grid only after cubic interpolation. This reduces the repeated contour pattern caused by quantising the 0.5 m cache before interpolation.
- The upper surface voxel uses the same grass/rock material blend on its side and top faces; lower exposed voxels retain their own soil/rock layers. Native C++ and GDScript meshing now use matching surface weights and alpha markers, including a one-cell border halo.
- The normal walking camera uses vertical FOV 82°. At 1080p, a 10 cm cell projects to about one pixel at 62 m: `pixels ≈ cell_size × 1080 / (2 × tan(FOV/2) × distance)`. This is why the default LOD0 boundary remains 64 m. Flight FOV is wider, so the same terrain has a different projected size.
- Visible voxel meshes do **not** cast shadows. Separate, smooth heightfield proxies represent the continuous landform silhouette so mountains can shadow nearby terrain without casting individual block-step shadows.
- Directional shadow distance is capped at 1,024 m independently of the default 4,096 m terrain view distance. Shadow proxy sampling becomes coarser with LOD, keeping the proxy near a bounded grid density. Top surfaces receive gradually attenuated landform shadows through LOD5; LOD6+ lies beyond the active shadow range. Vertical voxel walls never receive shadow attenuation, so the smooth proxy can shade the terrain without creating a shadow checkerboard.
- LOD3 and farther use a cheaper low-frequency material path. Fine per-cell colour variation, warped crack fields and Voronoi searches are skipped for those distant tiers. Near the player, procedural details are also skipped when their screen-space contribution becomes negligible.
- Lighting is softened on 10 cm vertical risers when those risers become sub-pixel, reducing dark contour-like Moiré bands without MSAA ×4. The original default MSAA ×2 profile is retained; screen-space AA remains off to avoid extra blur and post-processing cost.
- The project now defaults to Forward+, opening the way for desktop rendering features such as screen-space reflections, SSAO/SSIL, SDFGI, volumetric fog and TAA/FSR2. This change only selects the renderer; those effects and extended user-facing graphics options are not enabled by this commit. MSAA remains at the previous 2× baseline until Windows graphics settings are implemented.

## Native VoxEn extension

Native C++ handles height sampling, greedy top-face merging, exposed side faces, stitching skirts, smooth terrain-shadow proxy generation, collision height-map data, and conversion of generated geometry to Godot packed arrays when a compatible GDExtension is installed. Native top faces encode per-corner grass/rock blend weights; the upper voxel side face carries the corresponding surface weight and uses the same XZ material projection. The native cache stays continuous until interpolation is complete. The GDScript fallback implements the same material and height rules when the extension is absent.

The repository does not commit compiled native libraries. The extension manifest is Windows-only; build the DLL for Windows x86-64.

Requirements: a Windows C++ toolchain (Visual Studio Build Tools), Python 3.12+, SCons, and Godot 4.7.2 C++ bindings (`godot-cpp` tag `10.0.0-stable`). Forward+ requires a graphics driver supporting a RenderingDevice backend such as Vulkan or Direct3D 12.

From the project root:

```sh
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git native/godot-cpp
python -m pip install --upgrade scons
cd native
```

Windows x86-64:

```sh
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
```

The extension descriptor is `bin/voxen_native.gdextension`; the Windows outputs are expected under `bin/windows/`. Do not commit generated libraries. Rebuild the extension after changing native sources.

## Architecture and limitations

- **Native C++:** mesh generation and packed-array transfer; heavy per-chunk work runs in worker threads.
- **GDScript:** streaming priorities, LOD hierarchy visibility, worker lifecycle, attachment of render/physics resources, UI, controls, sky/weather and world orchestration.
- **Streaming:** larger parent tiles remain visible until child tiles are ready, avoiding temporary holes during refinement. The worker cap is conservative to leave CPU time available for the renderer and main-thread scene management.
- **Terrain model:** height-column terrain rather than a full 3D voxel volume. Enclosed caves, overhangs, arbitrary voxel editing and persistent terrain changes are not implemented yet.
- **Native binaries:** build separately for each target; compiled artifacts are intentionally excluded from the repository.

## Checks

With Godot 4.7.2 installed:

```sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
```

The tests cover terrain generation and LOD hierarchy/mesh sampling; verify rendering on the target Windows GPU, and rebuild the native extension when C++ sources change.

Version history is maintained in [CHANGELOG.md](CHANGELOG.md).
