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

## First extended CI benchmark reference — run 43068959543

The first successful extended run on the current branch established the initial Actions-cache reference. This is a provisional measurement, not an approved cross-machine performance target.

- Branch/commit: `0.1.0.4-new` / `e3b0155bb1823286232432ab42d44cc824c65ba9`
- Runner: Windows x86-64 GitHub Actions runner (Windows 10.0.26100 environment reported in transcript)
- Engine: Godot 4.7.2; native GDExtension Release benchmark
- Benchmark input: seed 1337, 2,000 m benchmark world, 160×160-voxel chunk, LOD0–LOD7
- Sampling: one warm-up plus five measured calls per LOD; p95 over five samples is effectively the maximum sample, so repeat runs are required before setting a stable threshold.

| LOD | Min (ms) | Median (ms) | p95 (ms) | Vertices | Indices |
|---:|---:|---:|---:|---:|---:|
| 0 | 11,105.924 | 11,143.397 | 11,307.755 | 68,160 | 102,240 |
| 1 | 10,965.434 | 11,215.494 | 11,702.338 | 16,168 | 24,252 |
| 2 | 10,995.246 | 11,263.258 | 11,642.240 | 3,724 | 5,586 |
| 3 | 11,031.538 | 11,319.080 | 11,452.673 | 824 | 1,236 |
| 4 | 10,934.418 | 11,007.601 | 11,421.504 | 272 | 408 |
| 5 | 10,982.094 | 11,133.685 | 11,225.982 | 72 | 108 |
| 6 | 10,868.243 | 11,154.661 | 11,246.119 | 8 | 12 |
| 7 | 10,926.054 | 11,156.809 | 11,478.363 | 16 | 24 |

The workflow artifact `windows-extended-diagnostics-4` contains the raw benchmark output and test/import logs. The benchmark reports successful completion and established the first cache entry; it did not compare against a prior complete baseline in this run.

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
