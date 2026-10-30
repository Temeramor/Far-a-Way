extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var world := VoxelWorld.new()
    world.auto_start_on_ready = false
    world.world_size_m = 2000.0
    world.chunk_size_m = 32.0
    root.add_child(world)
    await process_frame
    # Keep the test's map-corner assertions meaningful on the compact 2 km world.
    world.render_distance_m = 1024.0

    var errors: Array[String] = []

    # Screen-space transitions: the next LOD's cell reaches one pixel at each boundary.
    var screen_heights: Array[int] = [720, 900, 1080, 1440]
    var expected_first_boundary: Array[float] = [165.66, 207.06, 248.48, 331.31]
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

    # The default screen-space target keeps adjacent visible LOD tiers around 1.5-3 pixels.
    if absf(world.lod_target_pixels - 3.0) > 0.001:
        errors.append("Default LOD target should be 3 screen pixels.")
    for i in range(screen_heights.size()):
        var three_pixel_boundary: float = world.get_lod_boundary_m_for_height(
            0, float(screen_heights[i]), 3.0
        )
        if absf(three_pixel_boundary - expected_first_boundary[i] / 3.0) > 0.2:
            errors.append("3 px LOD target should transition at one third of the 1 px distance.")

    # The bounded mesh cache stores worker arrays without creating RenderingServer resources.
    var cache_payload := {
        "vertices": PackedVector3Array([Vector3.ZERO]),
        "normals": PackedVector3Array([Vector3.UP]),
        "colors": PackedColorArray([Color.WHITE]),
        "indices": PackedInt32Array([0, 0, 0])
    }
    world._store_cached_mesh("screen-space-smoke", cache_payload)
    var recovered_payload: Dictionary = world._get_cached_mesh("screen-space-smoke")
    if recovered_payload.is_empty() or world._mesh_cache_bytes <= 0:
        errors.append("The LRU mesh cache should preserve and return packed mesh arrays.")

    # The active viewport's boundaries must map each side of every threshold to adjacent LODs.
    for lod_index in range(7):
        var boundary: float = world.get_lod_boundary_m(lod_index)
        var just_before: int = world._lod_for_distance(maxf(0.0, boundary - 0.01))
        var at_boundary: int = world._lod_for_distance(boundary)
        if just_before != lod_index or at_boundary != lod_index + 1:
            errors.append("Active viewport LOD%d boundary %.2f m mapped to %d/%d" % [
                lod_index, boundary, just_before, at_boundary
            ])

    var expected_tile_sizes: Array[float] = [32.0, 64.0, 128.0, 256.0, 512.0, 1024.0, 2000.0, 2000.0]
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

    # The whole 2 km world fits in one LOD7 root (25.6 m cells). The centre should refine,
    # while the outer corner should remain outside this test's 1,024 m streaming radius.
    var distance_requests: Dictionary = {}
    var root_count: int = ceili(float(world._world_size_voxels) / float(world._chunk_size_voxels * 128))
    if root_count != 1:
        errors.append("2 km map should fit in one LOD7 root per axis, got %d" % root_count)
    for root_z in range(root_count):
        for root_x in range(root_count):
            world._collect_lod_tiles(
                7, root_x, root_z, Vector2.ZERO, Vector2(0.0, -1.0),
                distance_requests
            )
    var nearby_root: Dictionary = distance_requests.get(world._make_lod_key(7, 0, 0), {})
    if nearby_root.is_empty() or not bool(nearby_root.get("fallback", false)):
        errors.append("The root containing the player should refine to child LODs")
    if distance_requests.has(world._make_lod_key(0, 62, 62)):
        errors.append("The remote corner chunk outside the render distance should not be requested")

    # LOD distance is spherical in XYZ: at the same XZ position, gaining altitude
    # should move the requested leaf from detailed LOD0 to a coarser tier.
    var ground_y: float = world.get_surface_height(0.0, 0.0)
    var low_altitude_requests: Dictionary = {}
    var high_altitude_requests: Dictionary = {}
    for root_z in range(root_count):
        for root_x in range(root_count):
            world._collect_lod_tiles(
                7, root_x, root_z, Vector2.ZERO, Vector2(0.0, -1.0),
                low_altitude_requests, ground_y + 2.0
            )
            world._collect_lod_tiles(
                7, root_x, root_z, Vector2.ZERO, Vector2(0.0, -1.0),
                high_altitude_requests, ground_y + 500.0
            )
    var player_ground_key: Vector2i = world._make_lod_key(0, 31, 31)
    if not low_altitude_requests.has(player_ground_key):
        errors.append("LOD selection should retain LOD0 near the terrain at low altitude")
    if high_altitude_requests.has(player_ground_key):
        errors.append("LOD selection should become coarser directly above the same XZ tile at high altitude")

    var last_root := world._chunk_bounds(world._make_lod_key(7, 0, 0))
    if not is_equal_approx(float(last_root["width"]), 2000.0):
        errors.append("The single LOD7 root should cover the 2,000 m world width")

    # LOD7 remains voxel geometry: quad-expanded face vertices, not a shared smooth heightfield.
    var far_generator := VoxelTerrainGenerator.new(1337, 2000.0)
    var fallback_builder_script = load("res://scripts/meshing/voxel_chunk_mesh_builder_fallback.gd")
    var far_builder = fallback_builder_script.new()
    var far_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 7, "start_x": 7000, "start_z": 6000,
            "size_x": 2560, "size_z": 2560, "step_voxels": 256,
            "collision": false, "distance": 0.0, "priority": 0.0
        },
        "neighbor_lods": {"left": -1, "right": -1, "north": -1, "south": -1},
        "seed": 1337,
        "world_min_x": -1000.0, "world_min_z": -1000.0,
        "world_size_voxels": 10000,
        "terrain_world_size_m": 2000.0,
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
    var far_step_m: float = 25.6
    for vertex_index in range(0, far_vertices.size(), 37):
        var quantised_height: float = far_vertices[vertex_index].y / far_step_m
        if absf(quantised_height - roundf(quantised_height)) > 0.001:
            errors.append("LOD7 vertex heights should align to its 25.6 m voxel lattice")
            break

    # The final LOD7 root is not a full multiple of the 25.6 m voxel step.
    # Its final partial cells must sample inside the world instead of becoming zero-height columns.
    var edge_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 7, "start_x": 8192, "start_z": 8192,
            "size_x": 1808, "size_z": 1808, "step_voxels": 256,
            "collision": false, "distance": 2000.0, "priority": 0.0
        },
        "neighbor_lods": {"left": -1, "right": -1, "north": -1, "south": -1},
        "seed": 1337,
        "world_min_x": -1000.0, "world_min_z": -1000.0,
        "world_size_voxels": 10000,
        "terrain_world_size_m": 2000.0,
        "mountain_profile": far_generator.get_mountain_profile(),
        "build_collision": false
    })
    var edge_vertices: PackedVector3Array = edge_data.get("vertices", PackedVector3Array())
    var edge_normals: PackedVector3Array = edge_data.get("normals", PackedVector3Array())
    var edge_top_height: float = 0.0
    for vertex_index in range(edge_vertices.size()):
        if absf(edge_vertices[vertex_index].x - 361.6) < 0.001 and edge_normals[vertex_index].y > 0.9:
            edge_top_height = maxf(edge_top_height, edge_vertices[vertex_index].y)
    if edge_top_height <= 0.0:
        errors.append("The partial final LOD7 tile should retain terrain height at the world edge")

    # LOD2 also uses voxel faces; a small tile keeps the fallback smoke test quick.
    var compact_data: Dictionary = far_builder.build_mesh_data({
        "coord": Vector2i.ZERO,
        "request": {
            "lod": 2, "start_x": 7000, "start_z": 6000,
            "size_x": 128, "size_z": 128, "step_voxels": 8,
            "collision": false, "distance": 100.0, "priority": 0.0
        },
        "neighbor_lods": {"left": 2, "right": 2, "north": 2, "south": 2},
        "seed": 1337,
        "world_min_x": -1000.0, "world_min_z": -1000.0,
        "world_size_voxels": 10000,
        "terrain_world_size_m": 2000.0,
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
        var quantised_height: float = compact_vertices[vertex_index].y / 1.6
        if absf(quantised_height - roundf(quantised_height)) > 0.001:
            errors.append("LOD2 vertex heights should align to its 1.6 m voxel lattice")
            break

    # Regression: leaf visibility must safely handle a typed empty child list.
    var leaf_key: Vector2i = world._make_lod_key(0, 0, 0)
    world._wanted[leaf_key] = {"lod": 0, "fallback": false, "collision": false}
    world._update_lod_subtree_visibility(leaf_key, true)
    world._wanted.erase(leaf_key)

    # A hidden parent is a reusable fallback cache, not a disposable mesh generation.
    var fallback_parent_key: Vector2i = world._make_lod_key(1, 78, 78)
    var fallback_parent := VoxelTerrainChunk.new()
    fallback_parent.name = "FallbackParentCacheTest"
    fallback_parent.mesh_ready = true
    fallback_parent._render_active = false
    world.add_child(fallback_parent)
    world._chunks[fallback_parent_key] = fallback_parent
    world._wanted[fallback_parent_key] = {"lod": 1, "fallback": true, "collision": false, "nearest_distance": 0.0}
    for child_z in range(2):
        for child_x in range(2):
            var child_key: Vector2i = world._make_lod_key(0, 156 + child_x, 156 + child_z)
            var ready_child := VoxelTerrainChunk.new()
            ready_child.name = "FallbackChildCacheTest_%d_%d" % [child_x, child_z]
            ready_child.mesh_ready = true
            world.add_child(ready_child)
            world._chunks[child_key] = ready_child
            world._wanted[child_key] = {"lod": 0, "fallback": false, "collision": false, "nearest_distance": 0.0}
    world._update_lod_subtree_visibility(fallback_parent_key, true)
    if not fallback_parent.mesh_ready:
        errors.append("Hidden fallback-parent geometry should remain cached after child coverage becomes ready")

    # A near collider must remain enabled even when its visual mesh is hidden beneath a parent.
    var hidden_collision_chunk := VoxelTerrainChunk.new()
    hidden_collision_chunk.name = "HiddenCollisionCoverageTest"
    world.add_child(hidden_collision_chunk)
    hidden_collision_chunk.collision_enabled = true
    hidden_collision_chunk.set_render_active(false, true)
    if not hidden_collision_chunk.collision_active:
        errors.append("Collision coverage should remain active for a hidden but requested terrain chunk")
    hidden_collision_chunk.set_render_active(false, false)
    if hidden_collision_chunk.collision_active:
        errors.append("Collision coverage should deactivate when the chunk no longer requests collision")

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Far a Way screen-space voxel LOD smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
