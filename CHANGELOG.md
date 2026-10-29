# Changelog

## 0.1.0.6 — 2026-10-29

- Split ground boulders, mountain ribs, and grass/flower generation into separate scripts to keep their placement rules and detail tiers independently editable.
- Added two prop detail tiers for grass and flowers: 10 cm voxels in LOD0, downsampled 20 cm cells in LOD1, and no vegetation beyond that; the plant grid is downsampled before emitting faces.
- Added a vertex wind shader with rooted sway and gust modulation tied to the Clear, Cloudy and Overcast weather presets.
- Explicitly enabled shadow casting for vegetation and stone meshes.
- Rebuilt mountain ribs as unrotated world-axis-aligned cells. Their voxel size matches the active terrain LOD and the rib trace attempts to span the rocky slope from the lower grass boundary toward the crest, embedding the lowest rows into the hillside.
- Added progressive stone prop LODs: 10 cm, 20 cm, 40 cm and 80 cm cells through LOD3, with fewer and larger boulders at distance.
- Extended smoke-test coverage for separated object generators, wind vertex data and axis-aligned rib geometry.
- Reviewed native-boundary placement: terrain chunk meshing remains the existing C++ GDExtension hot path; object placement and cell filling stay budgeted in GDScript for now, with native porting gated on profiling and a tested Windows build.

## 0.1.0.5 — 2026-10-29

- Removed the placeholder tunnel, entrance boulders and coloured crystal groups from the world scene.
- Ported only the voxel stone, grass and flower algorithms from Plant_Generator, with their voxel-grid, palette and mesh-accumulator helpers; no tree generators or tree assets were imported.
- Added deterministic streaming placement per visible near-field terrain chunk. Grass and flowers use gentle grassy surfaces, boulders favour rocky terrain, and stretched voxel rock ribs follow steep gray mountain slopes while being embedded slightly into the hillside.
- Added a shared spacing/reservation check so stones, mountain ribs, grass and flowers do not occupy the same locations. The decorations follow the current world seed and are removed/rebuilt as terrain chunks stream or the seed changes.
- Corrected the documented LOD ladder to 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8 and 25.6 m.

## 0.1.0.4 — 2026-10-29

- Reduced the mesh-step progression to 1, 2, 4, 8 ... 128 base voxels and switched runtime LOD transitions to a half-pixel target. This removes the former 4x jump from LOD0 to LOD1 and keeps distant map edges substantially more detailed without forcing the entire map to LOD0.
- Matched the step fallback in the GDScript mesher, chunk metadata and native C++ builder. Shadow-proxy sampling scales down with those LOD steps, and the LOD5 coverage expectation and LOD7 edge-test scale are corrected.
- Recreated the Terrain demo's two entrance rock clusters, long hollow stone arch and three coloured crystal groups as procedural voxel meshes. Their positions come from Demo.tscn, while heights are sampled from Far a Way's current procedural terrain; Terrain3D height data and imported demo models are not copied.

## 0.1.0.3 — 2026-10-29

- Adapted terrain-noise frequencies to world size so the 2 × 2 km map retains large hills, secondary ridges and fine-scale relief instead of a near-uniform macro field.
- Improved seeded mountain chains with noise-warped flanks, sharper multi-crest profiles and scaled secondary spurs, keeping the same procedural map and six ridge segments.
- Expanded the voxel rock shader with generated mineral bedding, broken strata, weathered pitting, grain flecks, varied roughness and multi-scale fractures. Broad stone detail remains available on distant LODs while sub-pixel cracks are simplified.
- Kept rock textures procedural in the shader; no external image textures or non-reference rock placements were added.

## 0.1.0.2 — 2026-10-29

- Reduced the default procedural map from 10 × 10 km to 2 × 2 km.
- Adapted mountain generation to the compact map: two seeded chains instead of three, with mountain heights, widths, lateral offsets and spawn-area fade scaled consistently to world size.
- Added slightly stronger ridge-detail noise to give rock formations more surface roughness while preserving the existing seeded chain algorithm.
- Doubled base voxel dimensions on X, Y and Z from 0.1 m to 0.2 m. Updated all LOD geometry, distant voxel cell sizes, native and fallback mesh builders, collision sampling, tests and documentation to match (LOD7 now uses 51.2 m cells).

## 0.1.0.1 — 2026-10-28

- Added a Windows x86-64 first-person exploration project built with Godot 4.7.2 and the Forward+ renderer.
- Added a main menu with New Game, Settings and Exit, deterministic world-seed input, and a loading screen with generation progress.
- Added a first-person controller with mouse look, WASD and arrow-key movement, gravity, and camera-aligned flight activated by double-tapping Space.
- Added persistent player options for flight speed and field of view.
- Added a 10 × 10 km procedural landscape with seeded mountain chains, layered noise, world-size-scaled relief and 10 cm base height quantisation.
- Added slope-aware grass and rock distribution, varied grass and stone palettes, procedural rock cracks and shared material sampling across voxel tops and upper sides.
- Added eight hierarchical voxel LOD tiers with matching horizontal and vertical cell sizes from 10 cm to 25.6 m. LOD0 remains at 10 cm; LOD1 and every coarser tier use cells twice the previous ladder's size, reducing coarse mesh density while keeping tile count and physical tile boundaries unchanged. Greedy merging of top faces and matching side runs, exposed risers and edge skirts preserve continuous coverage.
- Added resolution-aware LOD boundaries based on viewport height and an 82° design FOV, with 5% hysteresis and a one-pixel target footprint for the next tier.
- Added terrain-height quantisation to each active LOD cell step and 3D terrain-relative distance calculations for altitude-aware flight streaming.
- Added per-voxel colour sampling at every LOD, with cell scale matching the 10 cm–25.6 m mesh step; far tiers simplify palette and crack calculations without fading to a uniform distance colour.
- Added lower-density terrain-shadow proxies within the near shadow range, cache-aligned height sampling and resource-aware fallback tile coverage.
- Added asynchronous native C++ mesh generation, a GDScript fallback builder, collision height maps and packed vertex/index arrays.
- Added movement-aware terrain streaming prioritised by distance, view direction, velocity prediction and measured worker timing.
- Added bounded worker scheduling, LOD-aware chunk caching, per-root hierarchy updates and local skirt updates. Hidden parent meshes remain cached for immediate fallback during LOD topology changes, and near terrain colliders can remain active beneath hidden render meshes.
- Added VoxEn diagnostics on F3, including FPS, frame time, LOD distribution, queued and running jobs, chunk geometry counts, estimated mesh memory, video-memory usage, shadow vertex counts and rendered primitive counts.
- Added F4 shader-based LOD colour visualisation for live inspection of the active voxel tiers.
- Added display options for windowed and fullscreen modes, with selectable resolutions from 640 × 360 through 2560 × 1440 and persistent preferences.
- Added a pause menu with Continue, Settings and Return to Menu actions; Esc opens the pause menu and M opens the weather and time menu.
- Added a sky and time-of-day system with sun, moon, stars, cloud layers, atmospheric fog and environmental lighting.
- Added Clear, Cloudy and Overcast weather presets, plus Dawn, Day, Dusk and Night time presets.
- Added smooth terrain-shadow proxies that preserve broad landform silhouettes while scaling shadow sampling with distance.
- Added continuous distance-based directional shadow attenuation on upper voxel faces, fading from 20% at 40 m to 0% at 500 m. Added wrap lighting and a soft directional fill for vertical sides so they are not mistaken for shadow-map darkening. Smooth heightfield proxies retain the actual terrain height and continue to cast broad landform silhouettes.
- Added a Windows native-extension descriptor and SCons build configuration, with compiler intermediates placed in a dedicated native build directory.
- Added smoke tests for deterministic terrain sampling, world-size scaling, hierarchical coverage, resolution-dependent LOD boundaries, voxel-face geometry at distant tiers, mesh-array integrity, native collision-height-map output, smooth shadow-proxy arrays and distance-based shadow lighting and the revised LOD cell-size profile.
