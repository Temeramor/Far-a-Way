# Visual terrain baseline procedure

**Status:** accepted by user validation (16 November 2026). The user reports that dozens of different seeds generated successful, visually pleasing islands. Screenshot capture is not required for this acceptance; the checklist below remains available for future regression investigations.  
**Runtime target:** Windows x86-64, Godot 4.7.2, Forward+.  
**World:** 8,000 × 8,000 m; central irregular island approximately 4 km².

## Purpose

Record repeatable visual references for the current terrain generator before extracting streaming services or changing terrain algorithms. This is a review of the existing game scene, not a new rendering benchmark.

## Seed selection

Start with the seeds already used by terrain tests:

- `123456` — existing terrain/spawn/material smoke-test seed (its test fixture uses 5 km).
- `1337` — default game seed and native chunk benchmark seed.
- `424242` — existing native macro-field test at the actual 8 km world size.

For visual review, run every seed in the actual `scenes/world.tscn` configuration (8 km). Add candidate seeds until the final set contains 8–12 worlds and spans:
- no mountain range;
- one mountain range;
- multiple mountain ranges, including the strongest/most extensive profile found in the candidate set.

Record the generated mountain profile segment count alongside each seed. Do not assume that a seed's 2 km benchmark result represents its 8 km world.

## Capture conditions

Keep these conditions unchanged for the whole set:

- 1280 × 720 viewport (project baseline); Windows x86-64; Forward+.
- Default project graphics settings; no temporary debug material or LOD override.
- Default FOV and LOD target; record any setting that differs from the defaults.
- Wait until the spawn area is ready and the surrounding streaming has settled before capturing.
- Keep the same camera transform for comparable shots where the terrain permits it; record camera position and orientation in world coordinates.

## Required captures per seed

1. **Spawn view:** eye-level view from the generated spawn point, showing the immediate ground and horizon.
2. **Island overview:** elevated oblique view showing the overall island footprint, coast and mountain distribution.
3. **Coastline:** at least one shallow sandy beach and one non-beach coast where grass or rock meets the sea.
4. **Mountain/lowland:** a view that includes mountain mass, foothills and an adjacent valley or lowland.
5. **Underwater terrain:** shoreline view that exposes shallow seabed and a deeper underwater slope/basin.
6. **Streaming/LOD:** a view with multiple LOD bands visible; inspect for gaps, abrupt silhouette changes, flicker and distant aliasing.

If a seed does not contain a particular landform, record it as not present rather than substituting another seed without noting the change.

## Per-seed metadata

Record in a sidecar text/CSV row:

- seed and game commit;
- world size (must be 8000 m);
- generated mountain profile segment count;
- spawn X/Z and spawn surface height/slope;
- viewport, FOV, render distance and LOD target;
- camera position/orientation for each capture;
- any visible defect, including its approximate world coordinates.

## Review checklist

- Island footprint is coherent and approximately the intended 4 km² across the seed set.
- Coastline is irregular but continuous; beaches occur only on suitable gentle coasts.
- Grass/rock coast transitions and shallow seabed look natural; no underwater vegetation or unwanted grass rim.
- Mountain ranges have believable width/area relative to height; foothills connect naturally to lowlands.
- Valleys, drainage traces and erosion read as coherent terrain rather than random noise.
- Spawn is dry, safe and not placed on a mountain or steep slope.
- No visible chunk gaps, LOD cracks, severe popping, moiré, or unstable streaming.
- The same seed reproduces the same terrain and spawn.

## Exit criteria

For the initial baseline, the user accepted the generated terrain after testing dozens of seeds; screenshot folders and metadata were explicitly waived. The capture/review procedure remains a reproducible diagnostic tool if a visual regression appears later. Headless CI alone does not constitute visual sign-off.

Do not modify terrain algorithms, LOD policy or streaming architecture during this capture pass. Fix only a defect that blocks capture or makes the current scene invalid; document any such change and restart affected captures.
