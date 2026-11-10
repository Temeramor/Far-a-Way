extends "res://scripts/streaming/voxel_world/voxel_world_layer_02_mesh_data.gd"

func _decode_lod_key(coord: Vector2i) -> Dictionary:
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    return {"lod": lod_index, "tile_x": coord.x - lod_index * LOD_KEY_STRIDE, "tile_z": coord.y}

func _get_streaming_heading() -> Vector2:
    if _player == null:
        return Vector2(0.0, -1.0)

    var forward_3d: Vector3 = -_player.global_transform.basis.z
    var view_heading := Vector2(forward_3d.x, forward_3d.z)
    if view_heading.length_squared() > 0.0001:
        view_heading = view_heading.normalized()
    else:
        view_heading = Vector2(0.0, -1.0)

    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z)
    if planar_velocity.length_squared() > 1.0:
        # Bias towards the current view so a rapid turn reprioritises visible chunks,
        # while retaining some look-ahead in the direction of travel.
        return (view_heading * 0.65 + planar_velocity.normalized() * 0.35).normalized()
    return view_heading

func _estimated_build_usec(lod_index: int) -> float:
    return _build_p95_cached_usec[clampi(lod_index, 0, 7)]

func _record_timing(samples: Array, value_usec: int, limit: int) -> void:
    samples.append(maxi(0, value_usec))
    while samples.size() > limit:
        samples.pop_front()

func _avg_ms(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var sum_usec: float = 0.0
    for value in samples:
        sum_usec += float(value)
    return sum_usec / float(samples.size()) / 1000.0

func _p95_usec(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var ordered: Array = samples.duplicate()
    ordered.sort()
    var index: int = clampi(int(ceil(float(ordered.size() - 1) * 0.95)), 0, ordered.size() - 1)
    return float(ordered[index])

func _queue_chunk_retirement(chunk: VoxelTerrainChunk) -> void:
    _chunk_resource_manager.queue_retirement(chunk)


func _exit_tree() -> void:
    _chunk_resource_manager.shutdown(_chunks)
    _mesh_data_cache.clear()

func regenerate_with_random_seed() -> void:
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var next_seed: int = rng.randi_range(1, 2147483646)
    if next_seed == seed_value:
        next_seed = 1 if seed_value != 1 else 2
    regenerate_with_seed(next_seed)

func get_lod_boundary_m_for_height(lod_index: int, screen_height: float, target_pixels: float = -1.0) -> float:
    # Switch when the next coarser cell reaches the selected screen-space pixel target.
    # This keeps the visible cell footprint near the chosen 2-4 px quality/performance band.
    if lod_index < 0 or lod_index > 6:
        return INF
    var safe_height: float = maxf(screen_height, 1.0)
    var pixel_target: float = lod_target_pixels if target_pixels <= 0.0 else clampf(target_pixels, 1.0, 4.0)
    var fov_degrees: float = DESIGN_FOV_DEGREES
    if _player != null:
        var player_camera := _player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
        if player_camera != null:
            fov_degrees = player_camera.fov
    var projection_scale: float = safe_height / (2.0 * tan(deg_to_rad(clampf(fov_degrees, 30.0, 120.0)) * 0.5))
    var next_cell_size_m: float = float(get_mesh_step_voxels(lod_index + 1)) * VOXEL_SIZE
    return next_cell_size_m * projection_scale / pixel_target

func can_move_to_position(world_position: Vector3, safety_margin_m: float = 0.6) -> bool:
    for offset_z in [-safety_margin_m, safety_margin_m]:
        for offset_x in [-safety_margin_m, safety_margin_m]:
            var point := Vector2(world_position.x + offset_x, world_position.z + offset_z)
            var local_x: float = point.x - _world_min_x
            var local_z: float = point.y - _world_min_z
            if local_x < 0.0 or local_z < 0.0 or local_x >= world_size_m or local_z >= world_size_m:
                return false
            var tile := Vector2i(floori(local_x / chunk_size_m), floori(local_z / chunk_size_m))
            var key := _make_lod_key(0, tile.x, tile.y)
            var chunk: VoxelTerrainChunk = _chunks.get(key) as VoxelTerrainChunk
            if chunk == null or not chunk.mesh_ready or not chunk.collision_enabled or not chunk.collision_active:
                return false
    return true
