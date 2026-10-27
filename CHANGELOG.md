# Changelog

## 0.1.0.1 — 2026-10-26

- Added a Windows x86-64 first-person exploration project built with Godot 4.7.2 and the Forward+ renderer.
- Added a main menu with New Game, Settings and Exit, deterministic world-seed input, and a loading screen with generation progress.
- Added a first-person controller with mouse look, WASD and arrow-key movement, gravity, and camera-aligned flight activated by double-tapping Space.
- Added persistent player options for flight speed and field of view.
- Added a 10 × 10 km procedural landscape with seeded mountain chains, layered noise, world-size-scaled relief and 10 cm base height quantisation.
- Added slope-aware grass and rock distribution, varied grass and stone palettes, procedural rock cracks and shared material sampling across voxel tops and upper sides.
- Added eight hierarchical terrain LOD tiers, with shared-vertex terrain surfaces for distant levels and edge skirts for continuous coverage between neighbouring tiles.
- Added distance-scaled geometry sampling and lower-density terrain-shadow proxies for distant chunks.
- Added asynchronous native C++ mesh generation, a GDScript fallback builder, collision height maps and packed vertex/index arrays.
- Added movement-aware terrain streaming prioritised by distance, view direction, velocity prediction and measured worker timing.
- Added bounded worker scheduling, LOD-aware chunk caching, mesh-resource retirement and streaming diagnostics.
- Added VoxEn diagnostics on F3, including FPS, frame time, LOD distribution, queued and running jobs, chunk geometry counts, estimated mesh memory, video-memory usage and rendered primitive counts.
- Added display options for windowed and fullscreen modes, with selectable resolutions from 640 × 360 through 2560 × 1440 and persistent preferences.
- Added a pause menu with Continue, Settings and Return to Menu actions; Esc opens the pause menu and M opens the weather and time menu.
- Added a sky and time-of-day system with sun, moon, stars, cloud layers, atmospheric fog and environmental lighting.
- Added Clear, Cloudy and Overcast weather presets, plus Dawn, Day, Dusk and Night time presets.
- Added smooth terrain-shadow proxies that preserve broad landform silhouettes while scaling shadow sampling with distance.
- Added a Windows native-extension descriptor and SCons build configuration, with compiler intermediates placed in a dedicated native build directory.
- Added smoke tests for deterministic terrain sampling, world-size scaling, hierarchical LOD coverage, compact far meshes, mesh-array integrity and native collision-height-map output.
