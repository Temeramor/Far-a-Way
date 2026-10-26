# Changelog

All notable changes are recorded here. The current version is defined by `project.godot` and `VERSION`.

## 0.1.0.12 — 2026-10-26

- Switched the project from the Mobile renderer to Forward+, and changed the required project feature tag to `Forward Plus`.
- Removed mobile-specific renderer overrides and Android-only display/input configuration from `project.godot`.
- Made Windows x86-64 the only declared platform target in `bin/voxen_native.gdextension`; Linux and Android native entries were removed.
- Updated README build instructions and project metadata for Windows-only development. The current pause-menu notice now names Forward+ and makes clear that extended graphics controls are a later step.
- Kept the existing 2× MSAA baseline and existing terrain/LOD/shader behaviour. Forward+-only features are not enabled by this change; the renderer switch is the foundation for later PBR materials, SSAO/SSIL, SSR, SDFGI, volumetric fog and temporal upscaling.
- Bumped the project version to `0.1.0.12`. Validate shader/material behaviour in Godot on Windows and rebuild the Windows GDExtension before relying on the result.

## 0.1.0.11 — 2026-10-26

- Fixed upper grass voxel side faces so they use the same grass/rock texture blend and XZ material projection as their top faces, instead of using a stone-like side treatment. Lower exposed voxels retain their own soil/rock layers.
- Changed both mesh builders to cache continuous height samples and quantise only after cubic interpolation to the 10 cm voxel grid, reducing the repeating contour pattern inherited from the 50 cm cache lattice.
- Brought native C++ and GDScript material handling into parity: native top faces now encode per-corner blend weights, and upper side faces carry the matching material weight across chunk borders.
- Updated the project version and documentation. Rebuild the platform-specific Android/Windows native extension before evaluating these C++ changes; compiled libraries remain intentionally excluded from the repository.

## 0.1.0.10 — 2026-10-26

- Added a 20 cm intermediate LOD step after the 10 cm near tier. The eight mesh steps are now 10 cm, 20 cm, 40 cm, 80 cm, 1.6 m, 3.2 m, 6.4 m and 12.8 m. The 20 cm tier occupies a short 64–80 m ring so the existing farther LOD rings and 4 km viewing distance remain in place.
- Calibrated LOD0 to the 1080p / 82° walking-camera projection: a 10 cm cell is approximately one pixel at 62 m, so the existing 64 m LOD0 boundary remains sensible.
- Replaced the visible farthest LOD7 voxel-top mesh with a smooth shared-vertex heightfield at the same 12.8 m sampling spacing. Large distant landforms are preserved while the cube-shaped risers are removed.
- Visible voxel meshes never cast shadows. Separate continuous-heightfield shadow proxies cast landform silhouettes; their sampling density is bounded at distant LODs, and directional shadow distance is capped at 1,024 m while terrain remains visible to 4,096 m. Top surfaces can receive gradually attenuated proxy shadows through LOD5; vertical voxel risers do not receive shadow attenuation.
- Reduced dark sub-pixel stair/Moiré bands by softening lighting normals on 10 cm risers based on their estimated screen-space size. This targets the offending geometry without using MSAA ×4.
- Added a cheaper low-frequency surface-material path from LOD3 onward, skipping per-cell colour noise and Voronoi crack calculations on distant terrain. Near detail functions also exit before expensive crack work when the crack contribution is already negligible.
- Improved CPU work around streamed chunks: the far LOD bypasses unused quantized height/material caches, the mountain profile is reused instead of re-created during repeated height queries, native vectors are bulk-copied into Godot packed arrays, unused shadow-count metadata was removed, and concurrent mesh jobs were reduced from eight to four with less frequent stream refreshes.
- Removed experimental AA/shadow/view-distance controls from the pause-menu settings page and cleared old saved graphics/LOD overrides when upgrading. The original MSAA ×2 default is retained, screen-space AA remains off, and 4×/8× options are no longer exposed.
- Updated the native C++ builder and the LOD regression test. Rebuild the Android/Windows GDExtension from the updated sources before evaluating the new native path.

## 0.1.0.8

- Added Off / FXAA / MSAA ×2 / MSAA ×4, mipmap bias and screen-space filtering controls.
- Set the default LOD0 boundary to 64 m and increased the distant mesh-sampling strides.
- Replaced the main-menu text title with `assets/ui/logo.png` and removed unused UI assets.

## 0.1.0.7

- Added the pause menu, Android pause control, Esc support on PC and return-to-menu action.
- Added live mesh-stride controls and configurable LOD distance bands.
- Ensured native and GDScript mesh builders report the same effective sampling stride.

## 0.1.0.6

- Fixed typed-array handling during LOD hierarchy visibility reconciliation.
- Added a regression check for a leaf tile with no children.

## 0.1.0.5

- Removed the stale shadow-proxy scene reference and restored shadow casting on visible voxel LODs.
- Adapted height-cache spacing to mesh stride to reduce the cost of kilometre-scale root tiles.
- Expanded hierarchy smoke tests for sampling strides.

## 0.1.0.4

- Added hierarchical voxel coverage across the whole map, with parent fallback until children are ready.
- Set geometric distance bands and mesh-sampling steps for LOD0–LOD6.
- Disabled procedural grass and flowers and simplified the rock colour palette.
- Fixed native SCons environment setup.

## 0.1.0.3

- Added a coarse shadow-only terrain mesh so visible voxel chunks no longer cast block-by-block shadows.

## 0.1.0.2

- Extended voxel streaming and added LOD0–LOD6.
- Faded fine material pixels and rock cracks at distance.

## 0.1.0.1

- Disabled procedural grass and flowers.
- Preserved the terrain scale from Neverland/main and made mountain ranges scale with world size.
- Simplified rock pixels and retained variable-width Voronoi cracks.
