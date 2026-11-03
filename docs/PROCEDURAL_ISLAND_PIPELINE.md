# Procedural island and bathymetry pipeline

This branch replaces the previous generic island/ocean noise blend with a seed-driven geological profile designed for the voxel world.

## World contract

- World footprint: **10,660 × 10,660 m**.
- Target exposed island area: **approximately 4 km²**.
- Island nominal equivalent radius: **1,128.38 m**.
- Island aspect ratio varies by seed while preserving nominal ellipse area.
- Maximum semi-axis is approximately **2,257 m**; the 10.66 km square leaves at least **3 km of ocean** between the largest island outline and the nearest map edge.
- Sea level: **Y = 0 m**.
- Base voxel pitch: **0.20 m**.
- Terrain is sampled continuously in native C++ and meshed in streamed chunks; no world-sized heightmap is allocated.

The 4 km² figure is a target/nominal area, not a surveyed polygon area. Shoreline warping and the finite shoreline transition introduce a small seed-dependent difference. The island bathymetry regression test checks a coarse area estimate within a tolerance.

## Landform generation

1. A seed-derived rotated ellipse establishes the island's nominal planform.
2. Three bands of OpenSimplex/FastNoiseLite perturb the coastline:
   - broad coves and headlands;
   - medium inlets and promontories;
   - fine shoreline breakup.
3. The land base combines broad uplift, rolling hills, low-amplitude detail, ridged multifractal peaks and saddles.
4. One to three seed-derived mountain splines define the island's geological spine. Each spline contributes broad shoulders and a broken crest train; ridge noise splits the crest into peaks and cols.
5. A coastal lowland mask creates occasional depositional beaches while leaving steep headlands exposed.

Mountain chain placement is scaled against the island's size, not against the full ocean map.

## Unified bathymetry

The ocean floor is sampled by the same continuous height function as the land. It is not a separate flat plane or a copy of the land noise.

- **Shelf:** shallow nearshore platform and sand flats.
- **Continental slope:** stronger depth gradient and broad escarpments.
- **Abyssal plain:** low-amplitude undulation at greater offshore distance.
- **Submerged roots:** mountain-chain influence continues below sea level as softened underwater ridges.
- **Submarine canyons:** three seed-oriented, noise-warped trough systems radiate offshore.
- **Seamounts:** three seed-placed conical volcanic rises break up the otherwise broad deep-ocean floor.
- **Sediment detail:** high-frequency ripples are strongest on shallow flats; abyssal detail is deliberately subdued.

The bathymetric profile is an art-directed, physically motivated procedural approximation. It is not a numerical oceanographic or plate-tectonic simulation.

## Procedural surface materials

All terrain color patterns are shader functions and palette values; no albedo/normal/roughness image textures are introduced by this pipeline.

| Material ID | Use |
|---|---|
| Grass | Gentle exposed land |
| Soil | Subsurface voxel layer |
| Rock | Mountain faces, cliffs and steep seabed |
| Sand | Beaches and shallow/deep sandy flats |
| Silt | Quiet deeper seabed flats |
| Reef | Broken shallow-water coral/carbonate patches |

The voxel shader uses world-space coordinates, per-voxel quantization and procedural noise. The new silt and reef classes are encoded in vertex color and shaded by code. The ocean surface itself uses an animated procedural wave shader with directional swell, procedural color drift and Fresnel response.

## Voxel scale, LOD and current limitation

The 20 cm base voxel pitch is preserved. Existing chunk streaming, worker scheduling, mesh cache, collision generation and eight-level LOD remain in place.

**Important:** the current VoxEn terrain mesher still emits a height-column surface. The native terrain profile is now unified across land and seabed, but the renderer does not yet extract arbitrary closed 3D isosurfaces. Therefore caves, arches, overhangs and tunnels are not rendered by this change.

## Planned volumetric migration

The next major geometry step is to replace the height-column mesher with a chunked density-field mesher:

- Define a signed density field where positive values are solid and negative values are air.
- Start with the current land/seafloor surface as the base isosurface.
- Carve cave and tunnel paths using capsule/cubic-spline distance fields and smooth unions.
- Use **Surface Nets** or **Dual Contouring** for voxel-aligned extraction; Dual Contouring is preferable when sharp rock features and material boundaries must be preserved.
- Sample a one-cell halo around every chunk to avoid cracks.
- Keep the 0.2 m base cell and derive coarser LODs from the same deterministic density function.
- Generate material IDs from density gradients, depth, curvature, sediment accumulation and biome masks.
- Add regression tests for watertight chunk borders, cave connectivity, collision parity and deterministic seeds.

A heightfield-to-SDF conversion alone does not create caves; the chunk mesher must consume the 3D density field for those features to become visible.

## Useful technical references

- [NVIDIA GPU Gems — Generating Complex Procedural Terrains](https://developer.nvidia.com/gpugems/gpugems3/part-i-geometry/chapter-1-generating-complex-procedural-terrains-using-gpu)
- [Houdini Heightfields and Erosion](https://www.sidefx.com/docs/houdini/heightfields/)
- [LibreTerrain — Draw an Island](https://libreterrain.org/tutorials/draw-an-island)
- [Gaea documentation](https://docs.gaea.app/)
- [WaterCuda](https://github.com/SamG-Coder/WaterCuda)
- [Sebastian Lague — Hydraulic Erosion](https://github.com/SebLague/Hydraulic-Erosion)
- [NVIDIA GPU Gems — Rendering Water Caustics](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-2-rendering-water-caustics)
- [Eurographics 2024 — Physically-based analytical erosion for fast terrain generation](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15033)
