# Changelog

## 0.1.0.1 — 2026-10-28

- Added a Windows x86-64 first-person exploration project built with Godot 4.7.2 and the Forward+ renderer.
- Added a main menu with New Game, Settings and Exit, deterministic world-seed input, and a loading screen with generation progress.
- Added a first-person controller with mouse look, WASD and arrow-key movement, gravity, and camera-aligned flight activated by double-tapping Space.
- Added persistent player options for flight speed and field of view.
- Added a 10 × 10 km procedural landscape with seeded mountain chains, layered noise, world-size-scaled relief and 10 cm base height quantisation.
- Added slope-aware grass and rock distribution, varied grass and stone palettes, procedural rock cracks and shared material sampling across voxel tops and upper sides.
- Added eight hierarchical voxel LOD tiers with matching horizontal and vertical cell sizes from 10 cm to 12.8 m, greedy merging of top faces and matching side runs, exposed risers and edge skirts for continuous coverage.
- Added resolution-aware LOD boundaries based on viewport height and an 82° design FOV, with 5% hysteresis and a one-pixel target footprint for the next tier.
- Added terrain-height quantisation to each active LOD cell step and 3D terrain-relative distance calculations for altitude-aware flight streaming.
- Added per-voxel colour sampling at every LOD, with cell scale matching the 10 cm–12.8 m mesh step; far tiers simplify palette and crack calculations without fading to a uniform distance colour.
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
- Added a Windows native-extension descriptor and SCons build configuration, with compiler intermediates placed in a dedicated native build directory.
- Added smoke tests for deterministic terrain sampling, world-size scaling, hierarchical coverage, resolution-dependent LOD boundaries, voxel-face geometry at distant tiers, mesh-array integrity and native collision-height-map output.
