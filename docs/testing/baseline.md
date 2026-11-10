# Performance and generation baseline

**Status:** initial inventory; numerical and visual baseline is not yet approved.
**Engine:** Godot 4.7.2, Windows x86-64, Forward+.
**World scale:** current project configuration and README describe an 8 × 8 km map.
**Benchmark implementation:** tests/native_chunk_benchmark.gd.

## Deterministic seeds already exercised by tests

These are existing regression-test inputs, not a claim that a visual reference set has already been captured.

| Seed | World size | Current coverage |
|---:|---:|---|
| 123456 | 5,000 m | Heightfield determinism, spawn constraints, sea level, material and terrain-density checks (terrain_smoke_test.gd) |
| 1337 | 5,000 m | Native sampler point/batch parity and shared sampler consistency (native_terrain_sampler_test.gd); native chunk benchmark |
| 424242 | 8,000 m | Native macro field range, bathymetry and sample consistency (pg_island_native_terrain_test.gd) |

## Automated checks

The Windows workflow builds the GDExtension in debug and release configurations, imports the project headlessly, and runs the smoke/parity tests. The native chunk benchmark exercises LOD0–LOD7 with five measured runs after one warm-up run and emits CSV columns:

lod,runs,min_ms,median_ms,p95_ms,vertices,indices

CI preserves import logs, test logs, benchmark output and the generated benchmark JSON as a workflow artifact. The JSON produced by a CI run is a captured measurement, not yet a trusted cross-run regression threshold: GitHub-hosted runner performance can vary and a stable reference must be reviewed before enforcing hard limits.

## Still required for an approved baseline

- Select 8–12 representative world seeds spanning island and mountain configurations.
- Run each seed in the actual game scene and verify spawn, coast, mountain silhouettes and streaming visually.
- Capture reference screenshots at fixed camera positions, resolution and graphics settings.
- Export height, slope, shoreline and other diagnostic maps from a repeatable tool.
- Record hardware/runner image, Godot version, build mode, warm-up policy and benchmark repetitions.
- Review repeated CI measurements before committing a performance threshold.

Do not treat an unreviewed CI artifact as the canonical performance baseline.
