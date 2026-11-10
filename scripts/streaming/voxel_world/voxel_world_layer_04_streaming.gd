extends "res://scripts/streaming/voxel_world/voxel_world_layer_03_resource_lifetime.gd"

func _chunk_bounds(coord: Vector2i) -> Dictionary:
    var parts: Dictionary = _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    var tile_x: int = int(parts["tile_x"])
    var tile_z: int = int(parts["tile_z"])
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return {"start_x": 0, "start_z": 0, "size_x": 0, "size_z": 0, "origin": Vector2.ZERO, "center": Vector2.ZERO, "width": 0.0, "depth": 0.0, "lod": lod_index, "tile_x": tile_x, "tile_z": tile_z}
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    var origin_x: float = _world_min_x + float(start_x) * VOXEL_SIZE
    var origin_z: float = _world_min_z + float(start_z) * VOXEL_SIZE
    var width: float = float(size_x) * VOXEL_SIZE
    var depth: float = float(size_z) * VOXEL_SIZE
    return {"start_x": start_x, "start_z": start_z, "size_x": size_x, "size_z": size_z, "origin": Vector2(origin_x, origin_z), "center": Vector2(origin_x + width * 0.5, origin_z + depth * 0.5), "width": width, "depth": depth, "lod": lod_index, "tile_x": tile_x, "tile_z": tile_z}

func _store_cached_mesh(cache_key: String, data: Dictionary) -> void:
    if cache_key.is_empty() or data.is_empty():
        return
    var bytes: int = _estimate_mesh_data_bytes(data)
    if bytes <= 0 or bytes > MAX_MESH_CACHE_BYTES:
        return
    if _mesh_cache.has(cache_key):
        var old_record: Dictionary = _mesh_cache[cache_key]
        _mesh_cache_bytes -= int(old_record.get("bytes", 0))
        _mesh_cache_order.erase(cache_key)
    _mesh_cache[cache_key] = {"data": data, "bytes": bytes}
    _mesh_cache_order.append(cache_key)
    _mesh_cache_bytes += bytes
    while _mesh_cache_bytes > MAX_MESH_CACHE_BYTES or _mesh_cache.size() > MAX_MESH_CACHE_ENTRIES:
        if _mesh_cache_order.is_empty():
            break
        var oldest_key: String = _mesh_cache_order.pop_front()
        var oldest_record: Dictionary = _mesh_cache.get(oldest_key, {})
        _mesh_cache_bytes -= int(oldest_record.get("bytes", 0))
        _mesh_cache.erase(oldest_key)
    _mesh_cache_bytes = maxi(0, _mesh_cache_bytes)

func _lod_neighbor_key(coord: Vector2i, offset: Vector2i) -> Vector2i:
    var parts := _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    var tx: int = int(parts["tile_x"]) + offset.x
    var tz: int = int(parts["tile_z"]) + offset.y
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * (1 << lod_index)))
    if tx < 0 or tz < 0 or tx >= tiles_axis or tz >= tiles_axis:
        return Vector2i(-1, -1)
    return _make_lod_key(lod_index, tx, tz)

func _find_target_lod_key_at_point(point: Vector2) -> Vector2i:
    if point.x < _world_min_x or point.y < _world_min_z or point.x >= _world_min_x + world_size_m or point.y >= _world_min_z + world_size_m:
        return Vector2i(-1, -1)
    for lod_index in range(8):
        var tile_m: float = chunk_size_m * float(1 << lod_index)
        var tx: int = floori((point.x - _world_min_x) / tile_m)
        var tz: int = floori((point.y - _world_min_z) / tile_m)
        var candidate := _make_lod_key(lod_index, tx, tz)
        if _wanted.has(candidate) and not bool(_wanted[candidate].get("fallback", false)):
            return candidate
    return Vector2i(-1, -1)

func _mark_hierarchy_dirty_for(coord: Vector2i) -> void:
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var shift: int = 7 - lod_index
    var root_key := _make_lod_key(7, tile_x >> shift, coord.y >> shift)
    _dirty_hierarchy_roots[root_key] = true

func _refresh_build_estimate_cache() -> void:
    for lod_index in range(_build_usec_by_lod.size()):
        var samples: Array = _build_usec_by_lod[lod_index]
        if not samples.is_empty():
            _build_p95_cached_usec[lod_index] = _p95_usec(samples)
    if not _refresh_usec_samples.is_empty():
        _refresh_p95_cached_usec = _p95_usec(_refresh_usec_samples)
    if not _queue_wait_usec_samples.is_empty():
        _queue_wait_p95_cached_usec = _p95_usec(_queue_wait_usec_samples)
    if not _apply_wait_usec_samples.is_empty():
        _apply_wait_p95_cached_usec = _p95_usec(_apply_wait_usec_samples)

func _estimated_lod_pipeline_usec(lod_index: int) -> float:
    return (
        _estimated_build_usec(lod_index)
        + _refresh_p95_cached_usec
        + _queue_wait_p95_cached_usec
        + _apply_wait_p95_cached_usec
        + streaming_refresh_interval_s * 1000000.0
    )

func _p95_ms(samples: Array) -> float:
    return _p95_usec(samples) / 1000.0

func _retire_stale_resources() -> void:
    # Visit only chunks that actually have detached resources awaiting disposal.
    var started_usec: int = Time.get_ticks_usec()
    var retired_count: int = 0
    while not _retirement_queue.is_empty():
        var resident_chunk: VoxelTerrainChunk = _retirement_queue[0]
        while retired_count < 8 and resident_chunk.retire_one_old_node():
            retired_count += 1
            if retired_count >= 2 and Time.get_ticks_usec() - started_usec >= 2500:
                return
        if resident_chunk._retired_nodes.is_empty():
            _retirement_queue.pop_front()
            _retirement_lookup.erase(resident_chunk.get_instance_id())
        if retired_count >= 8 or Time.get_ticks_usec() - started_usec >= 2500:
            return

    for i in range(_retiring_chunks.size() - 1, -1, -1):
        var stale_chunk: VoxelTerrainChunk = _retiring_chunks[i]
        while retired_count < 8 and stale_chunk.retire_one_old_node():
            retired_count += 1
            if retired_count >= 2 and Time.get_ticks_usec() - started_usec >= 2500:
                return
        if stale_chunk._retired_nodes.is_empty():
            _retiring_chunks.remove_at(i)
            _recycle_retired_chunk(stale_chunk)
        if retired_count >= 8 or Time.get_ticks_usec() - started_usec >= 2500:
            return

func _place_player_on_surface() -> void:
    if _player == null or _spawn_validation_in_progress:
        return
    _spawn_validation_in_progress = true
    var spawn_epoch: int = _generation_epoch
    var spawn_x: float = _spawn_position_xz.x
    var spawn_z: float = _spawn_position_xz.y
    var expected_height: float = get_surface_height(spawn_x, spawn_z)
    _player.set_physics_process(false)
    _player.velocity = Vector3.ZERO
    _player.global_position = Vector3(spawn_x, expected_height + 12.0, spawn_z)

    # Wait for PhysicsServer to register all HeightMapShape3D resources before probing.
    await get_tree().physics_frame
    await get_tree().physics_frame
    if not is_instance_valid(_player) or spawn_epoch != _generation_epoch:
        _spawn_validation_in_progress = false
        return

    # Probe the centre and the complete capsule footprint. A single centre hit
    # can hide a missing edge/corner in a newly-created HeightMapShape3D.
    var probe_offsets: Array[Vector2] = [
        Vector2.ZERO,
        Vector2(0.28, 0.0), Vector2(-0.28, 0.0),
        Vector2(0.0, 0.28), Vector2(0.0, -0.28),
        Vector2(0.20, 0.20), Vector2(-0.20, 0.20),
        Vector2(0.20, -0.20), Vector2(-0.20, -0.20)
    ]
    var center_hit: Dictionary = {}
    var probes_valid: bool = true
    var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    for offset in probe_offsets:
        var probe_x: float = spawn_x + offset.x
        var probe_z: float = spawn_z + offset.y
        var probe_height: float = get_surface_height(probe_x, probe_z)
        var ray_query := PhysicsRayQueryParameters3D.create(
            Vector3(probe_x, probe_height + 12.0, probe_z),
            Vector3(probe_x, probe_height - 12.0, probe_z),
            1
        )
        ray_query.exclude = [_player.get_rid()]
        var hit: Dictionary = space_state.intersect_ray(ray_query)
        if hit.is_empty() or absf(float(hit["position"].y) - probe_height) > 0.65:
            probes_valid = false
            break
        if offset == Vector2.ZERO:
            center_hit = hit

    if not probes_valid or center_hit.is_empty():
        push_warning("Startup blocked: terrain collision does not match the complete player footprint. Player physics remains disabled.")
        _spawn_validation_retry_cooldown = 0.5
        _spawn_validation_in_progress = false
        return

    # Start clearly above the voxel surface; gravity brings the capsule down
    # onto the already-confirmed collider instead of placing it flush with the mesh.
    _player.global_position = center_hit["position"] + Vector3(0.0, 0.0, 0.0)
    _player.velocity = Vector3.ZERO
    await get_tree().physics_frame
    if is_instance_valid(_player) and spawn_epoch == _generation_epoch:
        _startup_load_pending = false
        _player.set_physics_process(true)
    _spawn_validation_in_progress = false

func _lod_for_distance(distance: float) -> int:
    for lod_index in range(7):
        if distance < get_lod_boundary_m(lod_index):
            return lod_index
    return 7

func _lod_boundary_for(lod_index: int) -> float:
    return get_lod_boundary_m(lod_index)
