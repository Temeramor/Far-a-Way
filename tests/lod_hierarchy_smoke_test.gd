extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var world := VoxelWorld.new()
    world.auto_start_on_ready = false
    world.world_size_m = 10000.0
    world.chunk_size_m = 32.0
    root.add_child(world)
    await process_frame

    var errors: Array[String] = []

    # At 1080p and vertical FOV 82 degrees, a 10 cm cell is about one pixel at 62 m.
    var pixels_at_lod0_edge: float = 0.1 * 1080.0 / (2.0 * tan(deg_to_rad(82.0 * 0.5)) * 64.0)
    if absf(pixels_at_lod0_edge - 1.0) > 0.08:
        errors.append("10 cm LOD0 cells should project to approximately one pixel at 64 m")

    # Add a narrow 20 cm tier from 64-80 m while keeping the former LOD ranges intact after it.
    var distance_samples: Array = [
        [0.0, 0], [63.9, 0], [64.0, 1], [79.9, 1],
        [80.0, 2], [127.9, 2], [128.0, 3], [255.9, 3],
        [256.0, 4], [511.9, 4], [512.0, 5], [1023.9, 5],
        [1024.0, 6], [2047.9, 6], [2048.0, 7]
    ]
    for sample in distance_samples:
        var distance: float = float(sample[0])
        var expected_lod: int = int(sample[1])
        var actual_lod: int = world._lod_for_distance(distance)
        if actual_lod != expected_lod:
            errors.append("Distance %.1f m expected LOD%d, got LOD%d" % [
                distance, expected_lod, actual_lod
            ])

    var expected_tile_sizes: Array[float] = [32.0, 64.0, 128.0, 256.0, 512.0, 1024.0, 2048.0, 4096.0]
    var expected_steps_voxels: Array[int] = [1, 2, 4, 8, 16, 32, 64, 128]
    for lod in range(8):
        var key: Vector2i = world._make_lod_key(lod, 0, 0)
        var bounds: Dictionary = world._chunk_bounds(key)
        if not is_equal_approx(float(bounds["width"]), expected_tile_sizes[lod]):
            errors.append("LOD%d tile width expected %.1f m, got %.1f m" % [
                lod, expected_tile_sizes[lod], float(bounds["width"])
            ])
        if world.get_mesh_step_voxels(lod) != expected_steps_voxels[lod]:
            errors.append("LOD%d mesh step expected %d voxels, got %d" % [
                lod, expected_steps_voxels[lod], world.get_mesh_step_voxels(lod)
            ])

    # The root LOD7 tile is 4.096 km across. The centre root should refine and
    # the far corner should remain outside the 4 km streaming radius.
    var distance_requests: Dictionary = {}
    var root_count: int = ceili(float(world._world_size_voxels) / float(world._chunk_size_voxels * 128))
    if root_count != 3:
        errors.append("10 km map should need 3 LOD7 roots per axis, got %d" % root_count)
    for root_z in range(root_count):
        for root_x in range(root_count):
            world._collect_lod_tiles(
                7, root_x, root_z, Vector2.ZERO, Vector2(0.0, -1.0), Vector2.ZERO,
                distance_requests
            )
    var nearby_root: Dictionary = distance_requests.get(world._make_lod_key(7, 1, 1), {})
    if nearby_root.is_empty() or not bool(nearby_root.get("fallback", false)):
        errors.append("The root containing the player should refine to child LODs")
    if distance_requests.has(world._make_lod_key(7, 2, 2)):
        errors.append("A remote corner root outside the render distance should not be requested")

    var last_root := world._chunk_bounds(world._make_lod_key(7, 2, 2))
    if not is_equal_approx(float(last_root["width"]), 1808.0):
        errors.append("Last LOD7 edge tile should be clipped to 1808 m")

    # LOD7 should use shared vertices for a smooth heightfield rather than flat voxel quads.
    var far_generator := VoxelTerrainGenerator.new(1337, 10000.0)
    var fallback_builder_script = load("res://scripts/voxel_chunk_mesh_builder_fallback.gd")
    var far_builder = fallback_builder_script.new()
    var far_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 7, "start_x": 50000, "start_z": 50000,
            "size_x": 2560, "size_z": 2560, "step_voxels": 128,
            "collision": false, "distance": 0.0, "priority": 0.0
        },
        "neighbor_lods": {"left": -1, "right": -1, "north": -1, "south": -1},
        "seed": 1337,
        "world_min_x": -5000.0, "world_min_z": -5000.0,
        "world_size_voxels": 100000,
        "terrain_world_size_m": 10000.0,
        "mountain_profile": far_generator.get_mountain_profile(),
        "debug_lod_colors": false,
        "build_collision": false
    })
    if not bool(far_data.get("has_geometry", false)):
        errors.append("LOD7 smooth heightfield should produce visible geometry")
    var far_vertices: PackedVector3Array = far_data.get("vertices", PackedVector3Array())
    if far_vertices.size() != 21 * 21:
        errors.append("LOD7 smooth mesh should use shared grid vertices")

    # Regression: leaf visibility must safely handle a typed empty child list.
    var leaf_key: Vector2i = world._make_lod_key(0, 0, 0)
    world._wanted[leaf_key] = {"lod": 0, "fallback": false, "collision": false}
    world._update_lod_subtree_visibility(leaf_key, true)
    world._wanted.erase(leaf_key)

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Far a Way 8-level LOD smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
