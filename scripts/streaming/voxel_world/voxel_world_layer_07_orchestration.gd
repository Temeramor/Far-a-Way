extends "res://scripts/streaming/voxel_world/voxel_world_layer_06_runtime.gd"

func _apply_completed_jobs() -> void:
    if _completed_jobs.is_empty():
        return

    var coords: Array = _completed_jobs.keys()
    var world_coverage_ready: bool = is_world_coverage_ready()
    coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        # Decode the packed LOD key arithmetically; this comparator runs O(n log n) times.
        var lod_a: int = clampi(floori(float(a.x) / float(LOD_KEY_STRIDE)), 0, 7)
        var lod_b: int = clampi(floori(float(b.x) / float(LOD_KEY_STRIDE)), 0, 7)
        if not world_coverage_ready and lod_a != lod_b:
            return lod_a > lod_b
        var distance_a: float = float(_wanted.get(a, {"distance": INF})["distance"])
        var distance_b: float = float(_wanted.get(b, {"distance": INF})["distance"])
        return distance_a < distance_b
    )

    var applied: int = 0
    var apply_started_usec: int = Time.get_ticks_usec()
    for coord in coords:
        if applied >= _adaptive_apply_limit:
            break
        # Always allow one upload; later uploads obey a soft main-thread budget.
        if applied > 0 and Time.get_ticks_usec() - apply_started_usec >= int(max_mesh_apply_time_ms * 1000.0):
            break
        if not _completed_jobs.has(coord):
            continue
        var record: Dictionary = _completed_jobs[coord]
        if _fallback_children_ready(coord):
            _completed_jobs.erase(coord)
            continue
        if not _job_record_matches_current(record, coord):
            _completed_jobs.erase(coord)
            _stale_result_count += 1
            if _wanted.has(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry
            continue

        _completed_jobs.erase(coord)
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk == null:
            chunk = _chunk_resource_manager.take_pooled_chunk()
            if chunk == null:
                chunk = ChunkScript.new()
            chunk.name = "VoxelChunk_%d_%d" % [coord.x, coord.y]
            add_child(chunk)
            _chunks[coord] = chunk
        _record_timing(
            _apply_wait_usec_samples,
            Time.get_ticks_usec() - int(record.get("completed_usec", Time.get_ticks_usec())),
            128
        )
        chunk.apply_mesh_data(record["data"], _voxel_material)
        _update_chunk_skirt_visibility(coord, chunk)
        _update_neighbor_chunk_skirts(coord)
        _mark_hierarchy_dirty_for(coord)
        applied += 1

func _update_lod_subtree_visibility(coord: Vector2i, ancestors_visible: bool) -> void:
    if not _wanted.has(coord):
        return
    var request: Dictionary = _wanted[coord]
    var parent: bool = bool(request.get("fallback", false))
    # Avoid assigning an untyped [] from a ternary to Array[Vector2i] on Godot 4.7.
    # Leaf tiles have no children; parent tiles fill the typed array explicitly.
    var children: Array[Vector2i] = []
    if parent:
        children = _get_lod_tile_children(coord)
    var children_ready: bool = parent and not children.is_empty() and _all_lod_children_ready(children)
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    var node_active: bool = ancestors_visible and (not parent or not children_ready) and chunk != null and chunk.mesh_ready
    if chunk != null:
        var was_active: bool = chunk._render_active
        chunk.set_render_active(node_active, bool(request.get("collision", false)))
        if was_active != node_active:
            _update_neighbor_chunk_skirts(coord)
        # Hidden fallback-parent meshes stay cached until normal distance-based eviction.
        # This avoids rebuilding an entire parent tile when its subtree changes near a boundary.
    var children_visible: bool = ancestors_visible and parent and children_ready
    for child_key in children:
        _update_lod_subtree_visibility(child_key, children_visible)

func _prepare_world_for_epoch(epoch: int) -> void:
    if epoch != _generation_epoch:
        return
    _world_started = true
    _refresh_timer = 0.0
    _last_player_position = Vector2(INF, INF)
    _last_refresh_chunk = Vector2i(-2147483648, -2147483648)
    _refresh_streaming()

func refresh_lod_boundaries() -> void:
    _refresh_lod_boundaries()
    if _world_started:
        _last_player_position = Vector2(INF, INF)
        _refresh_streaming()

func set_render_distance_m(distance_m: float) -> void:
    var safe_distance: float = snappedf(clampf(distance_m, 512.0, 2048.0), 256.0)
    if is_equal_approx(render_distance_m, safe_distance):
        return
    render_distance_m = safe_distance
    if _world_started:
        _last_player_position = Vector2(INF, INF)
        _refresh_streaming()

func _reconcile_hierarchy_visibility() -> void:
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            _update_lod_subtree_visibility(_make_lod_key(7, tx, tz), true)

func _poll_terrain_prepare_jobs() -> void:
    if _terrain_prepare_jobs.is_empty():
        return
    for task_value in _terrain_prepare_jobs.keys():
        var task_id: int = int(task_value)
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var job: Dictionary = _terrain_prepare_jobs[task_id]
        _terrain_prepare_jobs.erase(task_id)
        if task_id != _active_terrain_prepare_task_id:
            continue
        _active_terrain_prepare_task_id = -1
        if int(job.get("epoch", -1)) != _generation_epoch:
            continue
        var prepared_generator: VoxelTerrainGenerator = job.get("generator") as VoxelTerrainGenerator
        if prepared_generator == null or not prepared_generator.is_terrain_prepared():
            push_error("Far a Way terrain preparation failed for seed %d." % seed_value)
            continue
        var spawn: Vector2 = prepared_generator.get_prepared_spawn_position()
        if not is_finite(spawn.x) or not is_finite(spawn.y):
            push_error("Far a Way cannot start: no safe, flat, dry spawn area was found for seed %d." % seed_value)
            continue
        _mountain_profile_cache = prepared_generator.get_mountain_profile()
        _spawn_position_xz = spawn
        _apply_seed_to_material()
        terrain_seed_changed.emit(seed_value)
        if _player != null:
            var spawn_height: float = prepared_generator.get_surface_height(spawn.x, spawn.y)
            _player.global_position = Vector3(spawn.x, spawn_height + 8.0, spawn.y)
            _player.velocity = Vector3.ZERO
        call_deferred("_prepare_world_for_epoch", _generation_epoch)

func set_lod_settings(_legacy_lod0_distance: float) -> void:
    # Compatibility hook; LOD boundaries are screen-space based rather than fixed in metres.
    refresh_lod_boundaries()

func set_lod_target_pixels(target_pixels: float) -> void:
    lod_target_pixels = clampf(target_pixels, 2.0, 4.0)
    refresh_lod_boundaries()

func _process(delta: float) -> void:
    _poll_terrain_prepare_jobs()
    _spawn_validation_retry_cooldown = maxf(0.0, _spawn_validation_retry_cooldown - delta)
    _last_frame_delta_ms = delta * 1000.0
    if _last_frame_delta_ms >= 33.0:
        _adaptive_apply_limit = 1
    else:
        _adaptive_apply_limit = maxi(1, max_mesh_applies_per_frame)
    _build_estimate_refresh_timer += delta
    if _build_estimate_refresh_timer >= 0.5:
        _build_estimate_refresh_timer = 0.0
        _refresh_build_estimate_cache()

    var viewport_size := _current_viewport_pixel_size()
    var viewport_changed: bool = viewport_size != _last_viewport_size
    if viewport_changed:
        _last_viewport_size = viewport_size
        _refresh_lod_boundaries()
        _hierarchy_visibility_dirty = true

    _refresh_timer += delta
    if _refresh_timer >= streaming_refresh_interval_s and _world_started:
        _refresh_timer = 0.0
        if _player != null:
            var player_position := Vector2(_player.global_position.x, _player.global_position.z)
            var current_chunk := Vector2i(
                clampi(floori((player_position.x - _world_min_x) / chunk_size_m), 0, _chunks_per_axis - 1),
                clampi(floori((player_position.y - _world_min_z) / chunk_size_m), 0, _chunks_per_axis - 1)
            )
            # Altitude must refresh at the same cadence as horizontal travel so spherical LOD boundaries are responsive.
            var altitude_changed: bool = absf(_player.global_position.y - _last_player_height) >= maxf(1.0, streaming_refresh_distance_m)
            if viewport_changed or player_position.distance_to(_last_player_position) >= streaming_refresh_distance_m or altitude_changed or current_chunk != _last_refresh_chunk:
                _last_player_position = player_position
                _last_player_height = _player.global_position.y
                _last_refresh_chunk = current_chunk
                _refresh_streaming()

    _poll_worker_tasks()
    _apply_completed_jobs()
    _process_chunk_jobs()
    if _hierarchy_visibility_dirty:
        _reconcile_hierarchy_visibility()
        _hierarchy_visibility_dirty = false
        _dirty_hierarchy_roots.clear()
    elif not _dirty_hierarchy_roots.is_empty():
        var dirty_roots: Array = _dirty_hierarchy_roots.keys()
        _dirty_hierarchy_roots.clear()
        for root_key in dirty_roots:
            _update_lod_subtree_visibility(root_key, true)
    _retire_stale_resources()
    _try_finish_startup_loading()
