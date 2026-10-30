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
            # First run is a warm-up and is excluded from the timing distribution.
            if run_index > 0:
                timings.append(elapsed)
            vertex_count = vertices.size()
            index_count = indices.size()
        if failed:
            break
        timings.sort()
        var median_ms := float(timings[timings.size() / 2]) / 1000.0
        var min_ms := float(timings[0]) / 1000.0
        var p95_index := clampi(int(ceil(float(timings.size()) * 0.95)) - 1, 0, timings.size() - 1)
        var p95_ms := float(timings[p95_index]) / 1000.0
        print("%d,%d,%.3f,%.3f,%.3f,%d,%d" % [
            lod, RUNS_PER_LOD, min_ms, median_ms, p95_ms, vertex_count, index_count
        ])

    if failed:
        quit(1)
        return
    print("Native chunk benchmark completed.")
    quit(0)


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
