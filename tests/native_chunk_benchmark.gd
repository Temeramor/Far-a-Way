extends SceneTree

## Repeatable native terrain benchmark. Run with:
## godot --headless --path . --script res://tests/native_chunk_benchmark.gd
const RUNS_PER_LOD := 5
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

    print("lod,runs,min_ms,median_ms,p95_ms,vertices,indices")
    var failed := false
    var p95_by_lod: Array[float] = []
    for lod in range(8):
        var timings: Array[int] = []
        var vertex_count := 0
        var index_count := 0
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
            vertex_count = vertices.size()
            index_count = indices.size()
        if failed:
            break
        timings.sort()
        var median_ms := float(timings[int(timings.size() / 2)]) / 1000.0
        var min_ms := float(timings[0]) / 1000.0
        var p95_index := clampi(int(ceil(float(timings.size()) * 0.95)) - 1, 0, timings.size() - 1)
        var p95_ms := float(timings[p95_index]) / 1000.0
        p95_by_lod.append(p95_ms)
        print("%d,%d,%.3f,%.3f,%.3f,%d,%d" % [
            lod, RUNS_PER_LOD, min_ms, median_ms, p95_ms, vertex_count, index_count
        ])

    if failed:
        quit(1)
        return
    if not _check_regression_baseline(p95_by_lod):
        quit(1)
        return
    print("Native chunk benchmark completed.")
    quit(0)


func _check_regression_baseline(p95_values: Array[float]) -> bool:
    var baseline_path: String = OS.get_environment("VOXEN_BENCHMARK_BASELINE_PATH")
    if baseline_path.is_empty():
        push_warning("No VOXEN_BENCHMARK_BASELINE_PATH set; benchmark ran without a regression baseline.")
        return true

    var baseline_values: Array = []
    if FileAccess.file_exists(baseline_path):
        var input := FileAccess.open(baseline_path, FileAccess.READ)
        if input != null:
            var parsed = JSON.parse_string(input.get_as_text())
            if parsed is Dictionary:
                baseline_values = parsed.get("p95_ms", [])

    if baseline_values.size() == p95_values.size():
        for lod in range(p95_values.size()):
            var baseline_ms: float = float(baseline_values[lod])
            var allowed_ms: float = baseline_ms * 1.25
            if baseline_ms > 0.0 and p95_values[lod] > allowed_ms:
                push_error("LOD%d p95 regression: %.3f ms exceeds the 25%% threshold over %.3f ms baseline." % [
                    lod, p95_values[lod], baseline_ms
                ])
                return false
    else:
        print("No complete LOD benchmark baseline found; this run establishes the baseline.")

    var output := FileAccess.open(baseline_path, FileAccess.WRITE)
    if output == null:
        push_error("Could not write benchmark baseline: " + baseline_path)
        return false
    output.store_string(JSON.stringify({"p95_ms": p95_values}, "\\t"))
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
