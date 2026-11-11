extends SceneTree

## Repeatable native terrain benchmark. Run with:
## godot --headless --path . --script res://tests/native_chunk_benchmark.gd
## Each LOD gets one discarded warm-up build followed by 25 measured builds.
const RUNS_PER_LOD := 25
const CHUNK_SIZE_VOXELS := 160
const WORLD_SIZE_M := 2000.0
const WORLD_SIZE_VOXELS := 10000
const SEED_VALUE := 1337

func _initialize() -> void:
    call_deferred("_run_benchmark")


func _run_benchmark() -> void:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("Benchmark requires the VoxEnNativeBuilder GDExtension.")
        quit(1)
        return

    var generator_script = load("res://scripts/world/voxel_generator.gd")
    var generator = generator_script.new(SEED_VALUE, WORLD_SIZE_M)
    var builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if builder == null:
        push_error("Could not instantiate VoxEnNativeBuilder.")
        quit(1)
        return

    # Match the runtime path: prepare the expensive world-global PG-Island sampler once,
    # then let every chunk build reuse this builder's configured sampler.
    var sampler_job := _make_job(0, generator)
    var sampler_started := Time.get_ticks_usec()
    builder.call("configure_terrain_sampler", sampler_job)
    var sampler_setup_ms := float(Time.get_ticks_usec() - sampler_started) / 1000.0
    var center_height := float(builder.call("get_surface_height", 0.0, 0.0))
    if not is_finite(center_height):
        push_error("Native terrain sampler returned a non-finite center height after configuration.")
        quit(1)
        return

    var runner_metadata := _collect_runner_metadata()
    print("terrain_sampler_setup_ms,%.3f" % sampler_setup_ms)
    print("benchmark_metadata_json," + JSON.stringify(runner_metadata))
    print("lod,runs,min_ms,median_ms,p95_ms,vertices,indices")
    print("raw_sample,sample_index,lod,elapsed_us")

    var failed := false
    var p95_by_lod: Array[float] = []
    var median_by_lod: Array[float] = []
    var raw_samples_by_lod: Array = []
    for lod in range(8):
        var timings: Array[int] = []
        var vertex_count := 0
        var index_count := 0
        # One warm-up build is deliberately excluded from all statistics.
        for run_index in range(RUNS_PER_LOD + 1):
            var job_data := _make_job(lod, generator)
            var started := Time.get_ticks_usec()
            var result: Dictionary = builder.call("build_mesh_data", job_data)
            var elapsed := Time.get_ticks_usec() - started
            var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
            var indices: PackedInt32Array = result.get("indices", PackedInt32Array())
            if not bool(result.get("has_geometry", false)) or vertices.is_empty() or indices.is_empty():
                push_error("Native benchmark returned empty geometry for LOD%d." % lod)
                failed = true
                break
            if indices.size() % 3 != 0:
                push_error("Native benchmark returned an invalid triangle index count for LOD%d." % lod)
                failed = true
                break
            if run_index > 0:
                timings.append(elapsed)
                print("raw_sample,%d,%d,%d" % [run_index - 1, lod, elapsed])
            vertex_count = vertices.size()
            index_count = indices.size()
        if failed:
            break

        var sorted_timings := timings.duplicate()
        sorted_timings.sort()
        var median_us := float(sorted_timings[int(sorted_timings.size() / 2)])
        # Nearest-rank p95: with 25 samples this is the 24th ordered value.
        var p95_index := clampi(int(ceil(float(sorted_timings.size()) * 0.95)) - 1, 0, sorted_timings.size() - 1)
        var p95_us := float(sorted_timings[p95_index])
        var min_us := float(sorted_timings[0])
        var median_ms := median_us / 1000.0
        var p95_ms := p95_us / 1000.0
        p95_by_lod.append(p95_ms)
        median_by_lod.append(median_ms)
        raw_samples_by_lod.append(timings)
        print("%d,%d,%.3f,%.3f,%.3f,%d,%d" % [
            lod, timings.size(), min_us / 1000.0, median_ms, p95_ms, vertex_count, index_count
        ])

    if failed:
        quit(1)
        return
    if not _check_regression_baseline(p95_by_lod, median_by_lod, raw_samples_by_lod, runner_metadata):
        quit(1)
        return
    print("Native chunk benchmark completed.")
    quit(0)


func _collect_runner_metadata() -> Dictionary:
    var version_info: Dictionary = Engine.get_version_info()
    return {
        "godot_version": version_info.get("string", "unknown"),
        "godot_build": version_info.get("build", "unknown"),
        "os": OS.get_name(),
        "os_version": OS.get_version(),
        "processor": OS.get_processor_name(),
        "processor_count": OS.get_processor_count(),
        "runner_os": OS.get_environment("RUNNER_OS"),
        "runner_arch": OS.get_environment("RUNNER_ARCH"),
        "runner_name": OS.get_environment("RUNNER_NAME"),
        "image_os": OS.get_environment("ImageOS"),
        "image_version": OS.get_environment("ImageVersion"),
        "github_run_id": OS.get_environment("GITHUB_RUN_ID"),
        "github_run_number": OS.get_environment("GITHUB_RUN_NUMBER"),
        "github_sha": OS.get_environment("GITHUB_SHA"),
        "github_ref_name": OS.get_environment("GITHUB_REF_NAME")
    }


func _check_regression_baseline(
    p95_values: Array[float],
    median_values: Array[float],
    raw_samples: Array,
    runner_metadata: Dictionary
) -> bool:
    var baseline_path: String = OS.get_environment("VOXEN_BENCHMARK_BASELINE_PATH")
    if baseline_path.is_empty():
        push_warning("No VOXEN_BENCHMARK_BASELINE_PATH set; benchmark ran without a regression baseline.")
        return true

    var baseline_values: Array = []
    var baseline_is_compatible := false
    if FileAccess.file_exists(baseline_path):
        var input := FileAccess.open(baseline_path, FileAccess.READ)
        if input != null:
            var parsed = JSON.parse_string(input.get_as_text())
            if parsed is Dictionary:
                var baseline_schema := int(parsed.get("schema_version", 1))
                var baseline_runs := int(parsed.get("runs_per_lod", 0))
                var baseline_p95_method := str(parsed.get("p95_method", "legacy"))
                if baseline_schema == 2 and baseline_runs == RUNS_PER_LOD and baseline_p95_method == "nearest_rank":
                    baseline_values = parsed.get("p95_ms", [])
                    baseline_is_compatible = baseline_values.size() == p95_values.size()
                else:
                    print("Existing benchmark baseline is incompatible (schema=%d, runs_per_lod=%d, p95_method=%s); skipping comparison and establishing a v2 baseline." % [
                        baseline_schema, baseline_runs, baseline_p95_method
                    ])
            else:
                push_warning("Existing benchmark baseline is not a JSON object; skipping comparison and replacing it with a validated v2 baseline.")
        else:
            push_warning("Could not open existing benchmark baseline; skipping comparison and establishing a v2 baseline.")
    else:
        print("No existing benchmark baseline found; this run establishes the v2 baseline.")

    if baseline_is_compatible:
        for lod in range(p95_values.size()):
            var baseline_ms: float = float(baseline_values[lod])
            var allowed_ms: float = baseline_ms * 1.25
            if baseline_ms > 0.0 and p95_values[lod] > allowed_ms:
                push_error("LOD%d p95 regression: %.3f ms exceeds the 25%% threshold over compatible v2 baseline %.3f ms." % [
                    lod, p95_values[lod], baseline_ms
                ])
                return false
    elif FileAccess.file_exists(baseline_path):
        print("No compatible v2 LOD baseline found; this run establishes the v2 baseline.")

    var output := FileAccess.open(baseline_path, FileAccess.WRITE)
    if output == null:
        push_error("Could not write benchmark baseline: " + baseline_path)
        return false
    output.store_string(JSON.stringify({
        "schema_version": 2,
        "runs_per_lod": RUNS_PER_LOD,
        "p95_method": "nearest_rank",
        "p95_ms": p95_values,
        "median_ms": median_values,
        "raw_samples_us": raw_samples,
        "runner_metadata": runner_metadata
    }, "\t"))
    print("Saved compatible benchmark baseline schema v2 with %d samples per LOD." % RUNS_PER_LOD)
    return true

func _make_job(lod: int, generator) -> Dictionary:
    return {
        "coord": Vector2i.ZERO,
        "request": {
            "lod": lod,
            "start_x": 4920,
            "start_z": 4920,
            "size_x": CHUNK_SIZE_VOXELS,
            "size_z": CHUNK_SIZE_VOXELS,
            "step_voxels": 1 << lod,
            "collision": false,
            "distance": 10000.0,
            "shadow_proxy": false,
            "priority": 0.0
        },
        "neighbor_lods": {
            "left": -1,
            "right": -1,
            "north": -1,
            "south": -1
        },
        "seed": SEED_VALUE,
        "world_min_x": -WORLD_SIZE_M * 0.5,
        "world_min_z": -WORLD_SIZE_M * 0.5,
        "world_size_voxels": WORLD_SIZE_VOXELS,
        "terrain_world_size_m": WORLD_SIZE_M,
        "mountain_profile": generator.get_mountain_profile(),
        "debug_lod_colors": false,
        "build_collision": false
    }
