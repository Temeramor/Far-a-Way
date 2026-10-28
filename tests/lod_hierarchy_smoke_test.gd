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

    # Screen-space transitions: the next LOD's cell reaches one pixel at each boundary.
    var screen_heights: Array[int] = [720, 900, 1080, 1440]
    var expected_first_boundary: Array[float] = [82.8, 103.5, 124.2, 165.5]
    for i in range(screen_heights.size()):
        var screen_height: int = screen_heights[i]
        var first_boundary: float = world.get_lod_boundary_m_for_height(0, float(screen_height), 1.0)
        if absf(first_boundary - expected_first_boundary[i]) > 0.3:
            errors.append("LOD0 boundary for %dp should be about %.1f m, got %.1f m" % [
                screen_height, expected_first_boundary[i], first_boundary
            ])
        for lod_index in range(7):
            var boundary: float = world.get_lod_boundary_m_for_height(lod_index, float(screen_height), 1.0)
            var expected_boundary: float = expected_first_boundary[i] * float(1 << lod_index)
            if absf(boundary - expected_boundary) > 0.6:
                errors.append("%dp LOD%d boundary expected %.1f m, got %.1f m" % [
                    screen_height, lod_index, expected_boundary, boundary
                ])

    # The active viewport's boundaries must map each side of every threshold to adjacent LODs.
    for lod_index in range(7):
        var boundary: float = world.get_lod_boundary_m(lod_index)
        var just_before: int = world._lod_for_distance(maxf(0.0, boundary - 0.01))
        var at_boundary: int = world._lod_for_distance(boundary)
        if just_before != lod_index or at_boundary != lod_index + 1:
            errors.append("Active viewport LOD%d boundary %.2f m mapped to %d/%d" % [
                lod_index, boundary, just_before, at_boundary
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

    # LOD7 remains voxel geometry: quad-expanded face vertices, not a shared smooth heightfield.
    var far_generator := VoxelTerrainGenerator.new(1337, 10000.0)
    var fallback_builder_script = load("res://scripts/voxel_chunk_mesh_builder_fallback.gd")
    var far_builder = fallback_builder_script.new()
    var far_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 7, "start_x": 70000, "start_z": 60000,
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
        errors.append("LOD7 voxel mesh should produce visible geometry")
    var far_vertices: PackedVector3Array = far_data.get("vertices", PackedVector3Array())
    if far_vertices.size() == 21 * 21 or far_vertices.size() % 4 != 0:
        errors.append("LOD7 should return indexed voxel faces rather than a smooth grid")
    var far_indices: PackedInt32Array = far_data.get("indices", PackedInt32Array())
    if far_indices.is_empty() or far_indices.size() % 3 != 0:
        errors.append("LOD7 voxel mesh triangle indices should be a non-empty multiple of three")
    var far_step_m: float = 12.8
    for vertex_index in range(0, far_vertices.size(), 37):
        var quantised_height: float = far_vertices[vertex_index].y / far_step_m
        if absf(quantised_height - roundf(quantised_height)) > 0.001:
            errors.append("LOD7 vertex heights should align to its 12.8 m voxel lattice")
            break

    # LOD2 also uses voxel faces; a small tile keeps the fallback smoke test quick.
    var compact_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 2, "start_x": 70000, "start_z": 60000,
            "size_x": 128, "size_z": 128, "step_voxels": 4,
            "collision": false, "distance": 100.0, "priority": 0.0
        },
        "neighbor_lods": {"left": 2, "right": 2, "north": 2, "south": 2},
        "seed": 1337,
        "world_min_x": -5000.0, "world_min_z": -5000.0,
        "world_size_voxels": 100000,
        "terrain_world_size_m": 10000.0,
        "mountain_profile": far_generator.get_mountain_profile(),
        "debug_lod_colors": false,
        "build_collision": false
    })
    var compact_vertices: PackedVector3Array = compact_data.get("vertices", PackedVector3Array())
    var compact_normals: PackedVector3Array = compact_data.get("normals", PackedVector3Array())
    var compact_colors: PackedColorArray = compact_data.get("colors", PackedColorArray())
    var compact_indices: PackedInt32Array = compact_data.get("indices", PackedInt32Array())
    if compact_vertices.is_empty() or compact_vertices.size() % 4 != 0:
        errors.append("LOD2 should contain quad-expanded voxel faces")
    if compact_vertices.size() != compact_normals.size() or compact_vertices.size() != compact_colors.size():
        errors.append("LOD2 compact mesh vertex attributes should have matching array lengths")
    if compact_indices.is_empty() or compact_indices.size() % 3 != 0:
        errors.append("LOD2 mesh triangle indices should be a non-empty multiple of three")
    for vertex_index in range(0, compact_vertices.size(), 19):
        var quantised_height: float = compact_vertices[vertex_index].y / 0.4
        if absf(quantised_height - roundf(quantised_height)) > 0.001:
            errors.append("LOD2 vertex heights should align to its 0.4 m voxel lattice")
            break

    # Regression: leaf visibility must safely handle a typed empty child list.
    var leaf_key: Vector2i = world._make_lod_key(0, 0, 0)
    world._wanted[leaf_key] = {"lod": 0, "fallback": false, "collision": false}
    world._update_lod_subtree_visibility(leaf_key, true)
    world._wanted.erase(leaf_key)

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Far a Way screen-space voxel LOD smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
