# Changelog

## 0.1.0.1 — 2026-10-26

- Added the Windows x86-64 first-person exploration project using Godot 4.7.2 and the Forward+ renderer.
- Added a main menu with New Game, Settings and Exit flows, plus deterministic world-seed input from numbers or arbitrary text strings.
- Added persistent player settings for flight speed and flight field of view, including Save, Cancel and Defaults actions.
- Added a first-person character controller with mouse look, keyboard movement, gravity, camera-aligned flight mode and double-tap Space activation.
- Added the world loading screen, initial spawn preparation, progress reporting, pause menu, Continue action and return-to-menu flow.
- Added deterministic procedural height-column terrain with layered noise, three seeded mountain chains, world-size-scaled mountain profiles, slope-aware grass/rock material weighting and 10 cm final height quantisation.
- Added a stylised surface material with pixel-scale colour variation, variable Voronoi-style rock cracks, smooth grass/rock transitions and consistent top/side material treatment.
- Added eight distance-based terrain LOD tiers from 10 cm to 12.8 m, including a short 20 cm intermediate ring and a smooth shared-vertex far-distance surface.
- Added hierarchical terrain streaming with parent-tile fallback, neighbour-aware refinement, border halo sampling and stitching skirts to maintain continuous coverage.
- Added movement-aware chunk scheduling using distance, view direction, velocity prediction and measured build, queue-wait and apply-wait timings.
- Added background chunk jobs, bounded worker concurrency, collision-height-map creation, resource retirement and streaming/LOD/collision/worker diagnostics.
- Added the native C++ terrain builder for noise/height sampling, interpolation, greedy top-face merging, exposed side geometry, material weights, LOD skirts, far terrain, smooth shadow proxies, collision data and packed mesh arrays.
- Added a GDScript mesh-generation fallback for runs without the native DLL, with the native builder as the intended Windows performance path.
- Added smooth terrain-shadow proxy geometry so landform silhouettes cast shadows without visible voxel meshes casting individual block shadows, alongside distance-based material/shadow simplification and the baseline MSAA ×2 profile.
- Added a sky and time-of-day system for the sun, moon, stars, cloud layers, atmospheric fog, environmental lighting and an advancing game clock.
- Added Clear, Cloudy and Overcast weather presets, a weather selector, time selection and Dawn, Day, Dusk and Night time presets.
- Added the Forward+ Windows native extension descriptor and SCons build configuration for debug and release DLLs.
- Added smoke tests for deterministic terrain generation, world-size scaling and hierarchical LOD/mesh sampling, plus an optional native-builder check for geometry arrays and collision height-map output.
