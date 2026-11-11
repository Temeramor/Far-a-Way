# Performance and generation baseline

**Status:** first automated benchmark reference captured (run 43068959543); numerical and visual baselines are still provisional and not approved.
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

The Windows workflow builds the GDExtension in debug and release configurations, imports the project headlessly, and runs the core smoke tests and native-field invariant checks. The native chunk benchmark exercises LOD0–LOD7 with five measured runs after one warm-up run and emits CSV columns:

lod,runs,min_ms,median_ms,p95_ms,vertices,indices

CI preserves import logs, test logs, benchmark output and the generated benchmark JSON as a workflow artifact. The extended workflow restores the last successful benchmark JSON from an Actions cache scoped by OS, Godot version and branch, then saves a new immutable cache entry after a successful run. The first successful run on a cache key establishes the baseline; later runs fail if any LOD p95 exceeds that baseline by more than 25%. This is a coarse guardrail, not a hardware-independent performance guarantee: runner image changes and noisy hosted hardware can still affect measurements.

## Benchmark harness correction — run 43068959543 is not a chunk-time baseline

Run 43068959543 proved that the extended workflow and benchmark executable completed, but a subsequent source review found that its measured timings are **not valid measurements of chunk meshing**.

The old benchmark instantiated `VoxEnNativeBuilder` and called `build_mesh_data()` without first calling `configure_terrain_sampler()`. In that state, `MeshBuild` creates a fresh `NoiseSet` and `configure_noise_from_job()` runs inside every build. That configuration calls `PgIslandTerrain.generate()`, including global macro-field generation and erosion. The benchmark therefore repeated expensive world-global terrain preparation for every warm-up and measured sample, for every LOD.

The old run reported p95 values of approximately 11.2–11.7 seconds per sample. **Do not use those values as chunk-build timings or as a performance regression baseline.** They mainly include repeated terrain-sampler setup and must be treated as a diagnostic record of the flawed harness.

The benchmark is being corrected to mirror the runtime lifecycle: call `configure_terrain_sampler()` once before the LOD loop, report that one-time setup duration separately, and reuse the configured sampler for every `build_mesh_data()` call. The first successful run after this correction must establish a new provisional chunk-build baseline; subsequent independent runs will be used to review measurement variance.

## Still required for an approved baseline

- Select 8–12 representative world seeds spanning island and mountain configurations.
- Run each seed in the actual game scene and verify spawn, coast, mountain silhouettes and streaming visually.
- Capture reference screenshots at fixed camera positions, resolution and graphics settings.
- Export height, slope, shoreline and other diagnostic maps from a repeatable tool.
- Record hardware/runner image, Godot version, build mode, warm-up policy and benchmark repetitions.
- Review repeated CI measurements before committing a performance threshold.

Do not treat an unreviewed CI artifact as the canonical performance baseline.


## Parity scope

The former `fastnoise_parity_test.gd` compared the current PG-Island native terrain against a legacy GDScript height formula. That comparison is invalid: the native port deliberately uses a different RNG and noise configuration, as documented in README. The test has been replaced by `native_terrain_field_invariants_test.gd`, which checks finite and bounded heights, repeatable samples, agreement between height and surface APIs, and bounded rock weights. Exact cross-implementation parity is out of scope until a dedicated RNG/noise-porting milestone is approved.
