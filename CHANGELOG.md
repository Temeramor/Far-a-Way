# Changelog

All notable changes are recorded here. The current version is defined by `project.godot` and `VERSION`.

## 0.1.0.9 — 2026-10-25

Follow-up fixes within the same version:

- Kept the far-blur distance and strength sliders as an optional experiment, but changed depth blur to **off by default** because it does not solve the likely terrain-shadow problem.
- Disabled shadow casting for **all voxel LODs**, not only LOD2+. Voxel faces still receive normal directional and sky-ambient lighting; only their participation as shadow casters is removed.
- This reduces coarse shadow blocks and self-shadow speckles, and avoids rendering voxel chunks into directional-light shadow cascades. The likely performance gain depends on the device and how much terrain is visible.
- Retained the screen-space shader filter: 10 cm colour cells fade toward an average as they become sub-pixel, and larger Voronoi cracks are filtered separately. This treats shader-colour Moiré, while disabling terrain shadows targets shadow-map artifacts.
- The native C++ mesh builder remains unchanged because shadow-casting flags belong to each Godot MeshInstance3D, and screen-space filtering runs in the GPU fragment shader.
- Sized the menu logo to the same content width as the buttons while preserving its aspect ratio; the brown panel remains removed.

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
