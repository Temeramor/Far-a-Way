# Changelog

All notable changes are recorded here. The current version is defined by `project.godot` and `VERSION`.

## 0.1.0.10 — 2026-10-26

- Inserted a 20 cm LOD tier between the 10 cm LOD0 and the former 40 cm LOD1. The new tier occupies a short 64–80 m ring, preserving the previous distance ranges for the larger mesh steps and retaining 12.8 m cells at the farthest level.
- Replaced the visible LOD7 block-top mesh with a smooth shared-vertex heightfield at the same 12.8 m sampling interval. This preserves distant landform silhouettes while removing the strongest cuboid appearance; a separate smooth proxy continues to cast terrain shadows.
- Calculated the default LOD0 boundary for a 1080p view: with vertical FOV 82°, a 10 cm cell projects to approximately one pixel at about 62 m, so the 64 m boundary remains appropriate.
- Kept visible voxel surfaces out of the shadow map and retained smooth continuous-heightfield shadow proxies for landform silhouettes. Shadow proxy sampling is coarser at distant LODs, and directional shadow distance is capped at 1,024 m independently of the 4,096 m terrain view. Top surfaces receive gradually attenuated smooth landform shadows through LOD5; vertical voxel risers do not receive shadow attenuation, preventing the dark chessboard effect.
- Added screen-space softening for sub-pixel 10 cm risers so their horizontal-normal walls produce fewer dark contour/Moiré strips without enabling expensive MSAA ×4. Vertical voxel walls do not receive terrain shadow attenuation.
- Added a cheaper distant material path from LOD3 onward, skipping fine per-cell colours and Voronoi crack searches; near material functions also skip detail work when the projected contribution is negligible.
- Reduced the default number of concurrent mesh jobs from eight to four, slowed redundant stream refreshes, cached the immutable mountain profile rather than rebuilding dictionaries for each chunk, coarsened far shadow proxies, and bulk-copied native geometry into packed arrays.
- Removed unused shadow-mesh count metadata and experimental graphics controls. Legacy saved graphics/LOD override sections are cleared on upgrade; the pause menu keeps its styling but no longer exposes AA, shadow-mode or view-distance controls. Default MSAA and screen-space AA are disabled.

- Removed the brown soil band beneath gray mountain rock. Both mesh builders now make visible walls and rock-topped slopes solid gray stone; grass-topped ground retains a shallow soil layer.
- Simplified the graphics menu to one anti-aliasing selector; added strict/gradual shadow modes and a live view-distance slider from 512 to 8192 m.
- Added per-LOD shadow reception: strict mode keeps full shadow influence on LOD0–LOD3 and none on LOD4+; gradual mode uses 100%, 75%, 50%, and 25% influence on LOD0–LOD3. Visible voxel meshes never cast shadows. Separate invisible full-relief silhouettes remain shadow-map occluders at every LOD, so distant mountains always block sunlight and can cast landform shadows onto nearer terrain; the simplified LOD4+ surfaces themselves do not receive direct shadows.
- Added soft depth fog with a muted green-gray tint, and synchronized terrain streaming, camera far distance, and directional shadow distance to the view-distance slider.
- Extended the native C++ mesher to return top/full geometry ranges needed by shadow proxies and aligned its rock slope/side-wall decisions with the GDScript fallback.
- Per-chunk height sampling, caching, surface classification, greedy meshing, side faces, stitching skirts, and collision height-map data run in the native C++ builder when its GDExtension library is available. Streaming priorities, LOD hierarchy, UI, shader parameters, and scene/physics attachment remain in GDScript. Rebuild the native binary from updated C++ sources to include the matching shadow metadata.



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
