# Changelog

All notable changes are recorded here. The current version is defined by `project.godot` and `VERSION`.

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
