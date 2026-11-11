# Performance and generation baseline

**Status:** benchmark harness v2 migration is verified by run 43107089833. The legacy schema-v1 baseline was skipped, 200 samples (25 per LOD) and runner metadata were recorded, and a schema-v2 baseline was cached. A second v2 run is still required to verify the 25% regression guard against a compatible baseline. Numerical baseline remains provisional; visual baseline is not approved.
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

The Windows workflow builds the GDExtension in debug and release configurations, imports the project headlessly, and runs the core smoke tests and native-field invariant checks. The native chunk benchmark exercises LOD0–LOD7 with 25 measured runs after one warm-up run. It emits summary CSV columns:

lod,runs,min_ms,median_ms,p95_ms,vertices,indices

It also emits one raw_sample CSV row per measured build (sample_index,lod,elapsed_us) and a benchmark_metadata_json record containing Godot/OS/CPU details and GitHub runner/image/run/commit metadata. The cached JSON baseline keeps the p95_ms field and adds schema_version, runs_per_lod, p95_method, median_ms, raw_samples_us, and runner_metadata. The guard compares only schema v2 baselines with matching run count and p95 method; legacy/incompatible baselines are explicitly skipped and replaced by a new v2 baseline.

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

## Corrected benchmark — first valid measurement (run 43074187166)

The corrected harness was confirmed on Windows x86-64, Godot 4.7.2, commit `21d479734ff2265ca20132b63be101c1f19c0c4e`. It configures the native terrain sampler once before the LOD loop and reuses it for every measured chunk build.

- One-time terrain sampler setup: **16,499.580 ms** (reported separately; not included in chunk timings).
- Five measured builds per LOD after warm-up.
- p95 chunk-build timings, milliseconds:

| LOD | p95 (ms) | Vertices | Indices |
|---:|---:|---:|---:|
| 0 | 27.304 | 68,160 | 102,240 |
| 1 | 16.667 | 16,168 | 24,252 |
| 2 | 4.670 | 3,724 | 5,586 |
| 3 | 1.771 | 824 | 1,236 |
| 4 | 0.818 | 272 | 408 |
| 5 | 0.470 | 72 | 108 |
| 6 | 0.402 | 8 | 12 |
| 7 | 0.289 | 16 | 24 |

These are the first valid chunk-build measurements, not yet an approved performance baseline. Repeat the same workflow on the same commit at least once (preferably twice) and review per-LOD variance before setting a regression threshold. The 16.5-second sampler setup is a separate world-generation cost and should be tracked separately from chunk meshing.

Artifact: [windows-extended-diagnostics-5](https://github.com/Temeramor/Far-a-Way/actions/runs/43074187166/artifacts/13879834870). It contains the raw benchmark CSV-style log, p95 JSON, import log and all seven test logs.



## Corrected benchmark — independent repeat (run 43080357758)

The second corrected run used the same commit 387f15eccc6ba6bb11d2c12d93bbd4f4f7f5c3a7, Windows x86-64 and Godot 4.7.2. It restored the benchmark JSON written by run 43074187166, so the 25% per-LOD regression guard compared against the first corrected measurement and passed.

- One-time terrain sampler setup: **13,339.506 ms**.
- Five measured builds per LOD after warm-up.
- p95 chunk-build timings, milliseconds:

| LOD | p95 (ms) | Vertices | Indices | Change vs. run 43074187166 |
|---:|---:|---:|---:|---:|
| 0 | 27.251 | 68,160 | 102,240 | -0.2% |
| 1 | 13.145 | 16,168 | 24,252 | -21.1% |
| 2 | 3.751 | 3,724 | 5,586 | -19.7% |
| 3 | 1.330 | 824 | 1,236 | -24.9% |
| 4 | 0.605 | 272 | 408 | -26.0% |
| 5 | 0.281 | 72 | 108 | -40.2% |
| 6 | 0.202 | 8 | 12 | -49.8% |
| 7 | 0.164 | 16 | 24 | -43.3% |

LOD0 is nearly unchanged, while LOD1–LOD7 are materially faster in this run. The runner image version and Godot version match the first run, but the hosted runner was allocated in a different Azure region (centralus rather than westus3). With only five measured samples per LOD, the reported p95 is effectively the maximum sample and is sensitive to outliers and runner contention. The difference must not be interpreted as a proven code-level speedup.

The cache behavior is confirmed: this run restored the previous corrected JSON from run 43074187166, compared the new values against its 25% threshold, passed, and saved a new immutable cache entry. This guard is a coarse regression tripwire, not a statistical baseline or a hardware-independent guarantee.

**Decision:** keep the numerical baseline provisional. Run at least one more independent measurement on the same commit. If the spread remains this large, increase repetitions and report robust median/percentile statistics and runner metadata before approving a threshold. Continue to keep the sampler setup cost separate from chunk meshing.

Artifact: [windows-extended-diagnostics-6](https://github.com/Temeramor/Far-a-Way/actions/runs/43080357758/artifacts/13883689322).


## Corrected benchmark — third independent repeat (run 43099687501)

The third corrected run used commit `f99817296f05c544f44f8bf600e45341a448b603`, Windows Server 2025 x86-64 and Godot 4.7.2. It restored the p95 JSON saved by run 43080357758 and passed the 25% per-LOD regression guard.

- One-time terrain sampler setup: **10,170.707 ms**.
- Five measured builds per LOD after warm-up.
- Full results, milliseconds:

| LOD | min | median | p95 | Vertices | Indices | p95 change vs. run 43080357758 |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 16.526 | 16.760 | 17.015 | 68,160 | 102,240 | -37.6% |
| 1 | 10.420 | 10.473 | 13.723 | 16,168 | 24,252 | +4.4% |
| 2 | 2.979 | 2.989 | 3.028 | 3,724 | 5,586 | -19.3% |
| 3 | 1.008 | 1.019 | 1.065 | 824 | 1,236 | -19.9% |
| 4 | 0.444 | 0.461 | 0.495 | 272 | 408 | -18.2% |
| 5 | 0.215 | 0.230 | 0.254 | 72 | 108 | -9.6% |
| 6 | 0.152 | 0.160 | 0.186 | 8 | 12 | -7.9% |
| 7 | 0.103 | 0.107 | 0.136 | 16 | 24 | -17.1% |

The third run's medians are approximately 5–21% below the second run, depending on LOD. LOD1 p95 is 13.723 ms versus a 10.473 ms median, illustrating the effect of outliers. The one-time sampler setup has also varied across the three corrected runs (16,499.580 / 13,339.506 / 10,170.707 ms).

Runner metadata: Azure `westus3`, Windows Server 2025, image `windows-2025-vs2026` version `20261103.298.1`, Godot 4.7.2. The second run used Azure `centralus`; detailed hardware configuration is not present in the artifact.

Cache behavior is confirmed: run 43099687501 restored the baseline written by run 43080357758, passed the 25% per-LOD guard, and saved a new immutable cache entry. This validates the guard's operation, not the statistical stability of timings.

**Decision:** keep the numerical baseline provisional. Three runs validate the corrected harness, but five measured samples per LOD are insufficient for a robust p95; it is effectively the maximum and varies with runner load. Increase to approximately 20–30 measured builds per LOD after warm-up, retain raw samples and runner metadata, and repeat before approving a threshold. Keep sampler setup separate from chunk-build timings.

Artifact: [windows-extended-diagnostics-8](https://github.com/Temeramor/Far-a-Way/actions/runs/43099687501/artifacts/13892581387).

## Parity scope

The former `fastnoise_parity_test.gd` compared the current PG-Island native terrain against a legacy GDScript height formula. That comparison is invalid: the native port deliberately uses a different RNG and noise configuration, as documented in README. The test has been replaced by `native_terrain_field_invariants_test.gd`, which checks finite and bounded heights, repeatable samples, agreement between height and surface APIs, and bounded rock weights. Exact cross-implementation parity is out of scope until a dedicated RNG/noise-porting milestone is approved.


## Benchmark harness v2 — first CI attempt and migration fix (12 November 2026)

Run [43102542013](https://github.com/Temeramor/Far-a-Way/actions/runs/43102542013) checked out commit `1c0e7da498ddda6c8e3ab6d70fdfde36e31cce35`. Debug/Release GDExtension builds, Godot import/script validation, and all seven smoke/parity tests passed. The benchmark then completed all eight LODs and emitted exactly 200 raw sample rows plus runner metadata:

| LOD | min (ms) | median (ms) | nearest-rank p95 (ms) |
|---:|---:|---:|---:|
| 0 | 20.913 | 21.107 | 22.540 |
| 1 | 13.037 | 13.136 | 13.295 |
| 2 | 3.757 | 3.775 | 3.828 |
| 3 | 1.251 | 1.283 | 1.344 |
| 4 | 0.536 | 0.552 | 0.618 |
| 5 | 0.302 | 0.315 | 0.359 |
| 6 | 0.199 | 0.230 | 0.253 |
| 7 | 0.163 | 0.168 | 0.235 |

One-time terrain sampler setup was 13,455.105 ms. Runner metadata reports Windows Server 2025, AMD EPYC 9V74 80-Core Processor (4 visible processors), Godot 4.7.2, image `win25-vs2026` version `20261103.298.1`, Azure region eastus.

**Failure cause:** the cache restored the previous schema-v1 baseline from run 43099687501, whose LOD0 p95 was 17.015 ms based on five measurements. The new schema-v2 p95 (22.540 ms) is based on 25 measurements and nearest-rank p95. Comparing these values under the 25% guard is statistically invalid; the guard lacked a schema/method compatibility check. This is a harness migration defect, not a meshing/build/test failure. The benchmark correctly failed rather than silently overwriting the old baseline.

**Fix committed:** `5930850187f426a64d2b559f377eefd5505420bb` updates the guard to compare only schema v2 baselines with the expected 25 runs per LOD and `nearest_rank` method. Legacy or otherwise incompatible baseline files are explicitly reported, skipped for that one migration run, and replaced with a v2 baseline after all benchmark samples validate. The per-LOD 25% guard remains active for subsequent compatible v2 runs.

**Verification still required:** rerun Windows extended workflow on the fix. Confirm it reports the legacy baseline as incompatible, completes with the marker, saves schema v2 with 200 samples and metadata, and caches it. Then run once more to verify the guard against a compatible v2 baseline. Do not approve numerical baseline until repeatability is reviewed.

Artifact: [windows-extended-diagnostics-9](https://github.com/Temeramor/Far-a-Way/actions/runs/43102542013/artifacts/13892978434).


## Benchmark harness v2 — migration run and first v2 baseline (run 43107089833)

The Windows x86-64 job checked out commit `05148e477531690b72262fb4e9a945629d4ca0ed` on `0.1.0.4-new`. Debug/Release GDExtension builds, Godot 4.7.2 project import/script validation, and all seven smoke/parity tests passed.

The cache restored the legacy baseline from run 43099687501. The harness correctly reported it as incompatible (`schema=1, runs_per_lod=0, p95_method=legacy`), skipped the invalid cross-method comparison, completed all 200 measured builds (25 per LOD), and saved a schema-v2 baseline with raw samples and runner metadata. The workflow then saved a new cache entry keyed to run 43107089833.

- One-time terrain sampler setup: **16,473.884 ms**.
- Runner: Windows Server 2025, AMD EPYC 7763 64-Core Processor (4 visible processors), Godot 4.7.2, image `windows-2025-vs2026` version `20261103.298.1`, Azure eastus2.
- Results, milliseconds:

| LOD | min | median | nearest-rank p95 | Vertices | Indices |
|---:|---:|---:|---:|---:|---:|
| 0 | 26.115 | 26.338 | 34.265 | 68,160 | 102,240 |
| 1 | 15.914 | 16.015 | 22.212 | 16,168 | 24,252 |
| 2 | 4.578 | 4.602 | 4.697 | 3,724 | 5,586 |
| 3 | 1.615 | 1.646 | 1.692 | 824 | 1,236 |
| 4 | 0.783 | 0.825 | 1.158 | 272 | 408 |
| 5 | 0.392 | 0.458 | 0.530 | 72 | 108 |
| 6 | 0.283 | 0.354 | 0.411 | 8 | 12 |
| 7 | 0.208 | 0.224 | 0.291 | 16 | 24 |

LOD0 and LOD1 contain notable high samples, so this run establishes the compatible v2 cache baseline but does not establish stable absolute performance. Crucially, because the restored baseline was legacy/incompatible, this run **did not exercise the 25% guard against a compatible v2 baseline**.

**Next verification:** run Windows extended workflow once more. It must restore the cache entry from 43107089833, compare schema v2 with 25 samples and nearest-rank p95, and pass the 25% per-LOD guard. Keep the numerical baseline provisional until repeated measurements are reviewed.

Artifact: [windows-extended-diagnostics-10](https://github.com/Temeramor/Far-a-Way/actions/runs/43107089833/artifacts/13894669724).
