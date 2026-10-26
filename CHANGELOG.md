# Changelog

## 0.1.0.1 — 2026-10-26

- Added a Windows x86-64 first-person landscape exploration prototype running on Godot 4.7.2 with the Forward+ renderer.
- Added seeded procedural generation for a 10 × 10 km default world, using layered noise, multiple mountain chains, world-size-scaled mountain profiles and deterministic surface-height sampling.
- Added height-column voxel terrain with a 10 cm base sampling step and eight distance-based mesh-detail tiers from 10 cm through 12.8 m.
- Added continuous height caching, cubic height interpolation and final height quantisation to the voxel grid.
- Added streamed chunk creation, hierarchical LOD coverage, parent-tile visual fallback until children are ready, neighbour-aware LOD decisions, border halos and stitching skirts.
- Added movement-aware chunk prioritisation using distance, view direction, velocity prediction, estimated mesh-build duration and worker queue timings.
- Added threaded chunk mesh jobs, bounded task concurrency, build-time profiling and on-screen streaming/LOD/collision/task diagnostics.
- Added a native C++ mesh builder for terrain sampling, top-face merging, exposed side geometry, surface weights, stitching skirts, smooth far terrain, shadow proxies, collision height maps and packed mesh-array output.
- Added a GDScript mesh-generation fallback for runs where the native extension is not available.
- Added a stylised terrain material with slope-based grass/rock blending, pixel colour variation, varied Voronoi-style rock cracks, consistent top/side surface treatment and reduced-cost distant shading.
- Added separate smooth terrain-shadow proxy meshes so landform silhouettes can cast shadows without visible voxel surfaces casting individual block shadows.
- Added screen-space-aware distant shading simplification, softer lighting on sub-pixel voxel risers and a default MSAA ×2 profile.
- Added a first-person player controller with mouse look, keyboard movement, a double-tap Space flight-mode toggle, flight speed/FOV settings and spawn placement on generated terrain.
- Added the main menu, world loading screen, pause menu, settings page and return-to-menu flow.
- Added an animated sky system with time-of-day progression, sun, moon, stars, cloud layers, atmospheric fog and environmental lighting controls.
- Added Clear, Cloudy and Overcast weather presets, plus in-game time controls and presets.
- Added a Windows GDExtension descriptor and SCons build configuration for debug and release DLLs.
- Added deterministic terrain and hierarchical LOD smoke tests for regression checking.
