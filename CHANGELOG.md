# Changelog

All notable changes are recorded here. The current version is defined by `project.godot` and `VERSION`.

## 0.1.0.9 — 2026-10-25

- Removed the distant-terrain blur setting and its depth-blur mechanics. Legacy blur values are removed when settings are saved.
- Continued addressing distant terrain ripple/Moiré with screen-space filtering: fine voxel colour cells and small Voronoi crack details fade as they become sub-pixel, while broad terrain colour variation is retained.
- Preserved normal lighting on visible voxel surfaces but moved shadow casting to separate invisible `SHADOWS_ONLY` terrain proxies for active LOD chunks. LOD0–LOD3 proxies include top and side faces (without stitching skirts); LOD4–LOD6 use top faces only to retain broad landform shadows while reducing distant side-wall shadow noise.
- Smoothed grass-to-rock transitions using the Neverland-style palette and continuous slope weighting. Kept the varied Voronoi cracks and omitted extra directional mineral bands/fissure overlays.
- Corrected the rock-slope calculation to use GDScript-compatible `1.0 / sqrt(...)`; cleaned a stray literal newline in a mesh-builder comment and updated outdated shadow-proxy documentation.
- A Godot 4.7.2 automated smoke test passed for surface rock-weight calculations, mesh generation at LOD2/LOD4, and shadow-proxy settings/geometry selection. The temporary test and workflow were removed after validation. The runner logged that the prebuilt Linux native GDExtension library was missing, so this run did not verify loading that native binary or replace visual testing on the target device.

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
