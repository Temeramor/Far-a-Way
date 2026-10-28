extends SceneTree

func _initialize() -> void:
    call_deferred("_run_native_builder_test")


func _run_native_builder_test() -> void:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        print("SKIP: VoxEnNativeBuilder is not loaded. Build the Windows GDExtension to test native mesh generation.")
        quit()
        return

    var generator_script = load("res://scripts/voxel_generator.gd")
    var generator = generator_script.new(123456, 10000.0)
    var builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if builder == null:
        push_error("VoxEnNativeBuilder exists in ClassDB but could not be instantiated.")
        quit(1)
        return

    # A small near-spawn tile exercises the native sampler, mesh builder and collision map.
    var job_data: Dictionary = {
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 0,
            "start_x": 50000,
            "start_z": 50000,
            "size_x": 64,
            "size_z": 64,
            "step_voxels": 1,
            "collision": true,
            "distance": 0.0,
            "priority": 0.0
        },
        "neighbor_lods": {
            "left": -1,
            "right": -1,
            "north": -1,
            "south": -1
        },
        "seed": 123456,
        "world_min_x": -5000.0,
        "world_min_z": -5000.0,
        "world_size_voxels": 100000,
        "terrain_world_size_m": 10000.0,
        "mountain_profile": generator.get_mountain_profile(),
        "debug_lod_colors": false,
        "build_collision": true
    }

    var result: Dictionary = builder.call("build_mesh_data", job_data)
    var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = result.get("normals", PackedVector3Array())
    var colors: PackedColorArray = result.get("colors", PackedColorArray())
    var indices: PackedInt32Array = result.get("indices", PackedInt32Array())
    var shadow_vertices: PackedVector3Array = result.get("smooth_shadow_vertices", PackedVector3Array())
    var shadow_normals: PackedVector3Array = result.get("smooth_shadow_normals", PackedVector3Array())
    var shadow_indices: PackedInt32Array = result.get("smooth_shadow_indices", PackedInt32Array())

    if not bool(result.get("has_geometry", false)) or vertices.is_empty() or indices.is_empty():
        push_error("Native builder did not return terrain geometry.")
        quit(1)
        return
    if normals.size() != vertices.size() or colors.size() != vertices.size():
        push_error("Native builder returned mismatched vertex, normal or colour arrays.")
        quit(1)
        return

    if indices.size() % 3 != 0:
        push_error("Native builder returned an index count that is not divisible by three.")
        quit(1)
        return

    if shadow_vertices.is_empty() or shadow_indices.is_empty():
        push_error("Native builder did not return the smooth near-terrain shadow proxy.")
        quit(1)
        return
    if shadow_normals.size() != shadow_vertices.size() or shadow_indices.size() % 3 != 0:
        push_error("Native builder returned invalid smooth shadow-proxy arrays.")
        quit(1)
        return

    var collision_data: Dictionary = result.get("collision_height_map", {})
    if collision_data.is_empty():
        push_error("Native builder did not return collision height-map data.")
        quit(1)
        return
    var collision_heights: PackedFloat32Array = collision_data.get("heights", PackedFloat32Array())
    var expected_height_count: int = int(collision_data.get("width", 0)) * int(collision_data.get("depth", 0))
    if expected_height_count < 4 or collision_heights.size() != expected_height_count:
        push_error("Native builder returned an invalid collision height map.")
        quit(1)
        return

    print("Native terrain builder smoke test passed. vertices=%d indices=%d shadow_vertices=%d shadow_indices=%d collision_samples=%d" % [
        vertices.size(), indices.size(), shadow_vertices.size(), shadow_indices.size(), collision_heights.size()
    ])
    quit()
