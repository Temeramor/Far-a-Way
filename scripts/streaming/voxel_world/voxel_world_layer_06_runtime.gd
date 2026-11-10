extends "res://scripts/streaming/voxel_world/voxel_world_layer_05_lod.gd"

func _neighbor_lods_for(coord: Vector2i) -> Dictionary:
    return {
        "left": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(-1, 0))),
        "right": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(1, 0))),
        "north": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(0, -1))),
        "south": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(0, 1)))
    }

func _all_lod_children_ready(children: Array[Vector2i]) -> bool:
    for child_key in children:
        var child_request: Dictionary = _wanted.get(child_key, {})
        if float(child_request.get("nearest_distance", INF)) > render_distance_m:
            continue
        if not _lod_tile_coverage_ready(child_key):
            return false
    return true

func _lod_tile_coverage_ready(coord: Vector2i) -> bool:
    if not _wanted.has(coord):
        return false
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    var request: Dictionary = _wanted[coord]
    # A chunk can remain mesh_ready after a newer LOD request has replaced it.
    # Readiness is valid only when the uploaded generation matches this exact request.
    if chunk != null and chunk.mesh_ready:
        var requested_lod: int = int(request.get("lod", -1))
        var requested_step: int = int(request.get("step_voxels", 1 << clampi(requested_lod, 0, 7)))
        if chunk.lod == requested_lod and chunk.mesh_step_voxels == requested_step and not chunk.mesh_upload_rejected:
            return true
    if not bool(request.get("fallback", false)):
        return false
    var children: Array[Vector2i] = _get_lod_tile_children(coord)
    return not children.is_empty() and _all_lod_children_ready(children)

func is_world_coverage_ready() -> bool:
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            var root_key := _make_lod_key(7, tx, tz)
            if not _wanted.has(root_key):
                continue
            if not _lod_tile_coverage_ready(root_key):
                return false
    return true

func get_startup_progress() -> float:
    if not _startup_load_pending:
        return 1.0
    if is_terrain_preparing() or not _world_started:
        return 0.035
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    var roots_total: int = 0
    var roots_ready: int = 0
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            var root_key := _make_lod_key(7, tx, tz)
            if not _wanted.has(root_key):
                continue
            roots_total += 1
            if _lod_tile_coverage_ready(root_key):
                roots_ready += 1
    if roots_ready < roots_total:
        return clampf(0.05 + 0.60 * float(roots_ready) / float(maxi(roots_total, 1)), 0.05, 0.65)
    var near_total: int = 0
    var near_ready: int = 0
    for coord_value in _wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _wanted[coord]
        if bool(request.get("fallback", false)) or float(request.get("nearest_distance", INF)) > minf(256.0, render_distance_m):
            continue
        near_total += 1
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk != null and chunk.mesh_ready:
            near_ready += 1
    return clampf(0.65 + 0.30 * float(near_ready) / float(maxi(near_total, 1)), 0.65, 0.95)

func _update_neighbor_chunk_skirts(coord: Vector2i) -> void:
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    if chunk != null and chunk.mesh_ready and chunk._render_active:
        _update_chunk_skirt_visibility(coord, chunk)
    for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
        var virtual_key := _lod_neighbor_key(coord, offset)
        if virtual_key.x < 0:
            continue
        var neighbor_key := _find_visible_lod_key_at_point(_chunk_center(virtual_key))
        var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_key) as VoxelTerrainChunk
        if neighbor != null and neighbor.mesh_ready and neighbor._render_active:
            _update_chunk_skirt_visibility(neighbor_key, neighbor)

func _process_chunk_jobs() -> void:
    var worker_limit: int = maxi(1, mini(max_concurrent_mesh_jobs, maxi(1, OS.get_processor_count() - 1)))
    var active_decor_jobs: int = 0
    for child in get_children():
        if child is VoxelSurfaceScatter:
            active_decor_jobs = child._running_decor_tasks.size()
            break
    # Terrain owns scheduling priority; decor may use only the remaining shared worker slots.
    var available_jobs: int = worker_limit - _running_tasks.size() - active_decor_jobs
    if available_jobs <= 0 or _queued.is_empty():
        return
    var started_jobs: int = 0
    var player_xz := _player_xz()
    var heading: Vector2 = _get_streaming_heading()
    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z) if _player != null else Vector2.ZERO
    while started_jobs < available_jobs and not _queued.is_empty():
        var best_coord := Vector2i(-1, -1)
        var best_priority: float = INF
        var best_center := Vector2.ZERO
        for queued_key in _queued.keys():
            var candidate: Vector2i = queued_key
            if _running_by_coord.has(candidate):
                continue
            var candidate_center: Vector2 = _chunk_center(candidate)
            var candidate_request: Dictionary = _queued[candidate]
            var priority: float = _deadline_priority(candidate_center, candidate_request, player_xz, heading, planar_velocity)
            if priority < best_priority:
                best_priority = priority
                best_coord = candidate
                best_center = candidate_center
        if best_coord.x < 0:
            break
        var coord: Vector2i = best_coord
        var request: Dictionary = _queued[coord]
        request["priority"] = best_priority
        if not request.has("queued_usec"):
            request["queued_usec"] = Time.get_ticks_usec()
        _queued.erase(coord)
        var neighbors: Dictionary = _neighbor_lods_for(coord)
        var job_data: Dictionary = {
            "coord": coord, "request": request.duplicate(), "neighbor_lods": neighbors.duplicate(),
            "seed": seed_value, "world_min_x": _world_min_x, "world_min_z": _world_min_z,
            "world_size_voxels": _world_size_voxels,
            "terrain_world_size_m": world_size_m, "mountain_profile": _mountain_profile_cache,
            "build_collision": bool(request["collision"]) and not _chunk_has_collision_resource(coord)
        }
        var build_collision: bool = bool(request["collision"]) and not _chunk_has_collision_resource(coord)
        var cache_key: String = _make_mesh_cache_key(coord, request, neighbors, build_collision)
        var cached_data: Dictionary = _get_cached_mesh(cache_key)
        if not cached_data.is_empty():
            _completed_jobs[coord] = {
                "coord": coord, "request": request.duplicate(), "neighbors": neighbors.duplicate(),
                "builder": null, "epoch": _generation_epoch, "seed": seed_value,
                "queued_usec": int(request["queued_usec"]), "cache_key": cache_key,
                "data": cached_data, "completed_usec": Time.get_ticks_usec()
            }
            started_jobs += 1
            continue

        var builder: Object = _create_mesh_builder()
        if builder == null:
            return
        var task_id: int = WorkerThreadPool.add_task(
            Callable(builder, "build_mesh_data").bind(job_data), false,
            "VoxEn chunk %d,%d LOD%d" % [coord.x, coord.y, int(request["lod"])]
        )
        var task_record := {
            "coord": coord, "request": request.duplicate(), "neighbors": neighbors.duplicate(),
            "builder": builder, "epoch": _generation_epoch,
            "seed": seed_value, "queued_usec": int(request["queued_usec"]),
            "cache_key": cache_key
        }
        _running_tasks[task_id] = task_record
        _running_by_coord[coord] = task_id
        started_jobs += 1

func _fallback_children_ready(coord: Vector2i) -> bool:
    if not _wanted.has(coord) or not bool(_wanted[coord].get("fallback", false)):
        return false
    var children: Array[Vector2i] = _get_lod_tile_children(coord)
    return not children.is_empty() and _all_lod_children_ready(children)

func is_terrain_shadow_ready() -> bool:
    # Legacy API used by the loading UI. Each active LOD chunk owns its invisible terrain-shadow proxy.
    return is_world_coverage_ready()

func _try_finish_startup_loading() -> void:
    if not _startup_load_pending or _spawn_validation_in_progress or _spawn_validation_retry_cooldown > 0.0 or _player == null or not is_world_coverage_ready():
        return
    var spawn_x: float = _spawn_position_xz.x
    var spawn_z: float = _spawn_position_xz.y
    var expected_height: float = get_surface_height(spawn_x, spawn_z)
    var spawn_position := Vector3(spawn_x, expected_height + 8.0, spawn_z)
    # The full player footprint must be covered by active LOD0 collision chunks.
    # Rendering visibility is irrelevant: physics coverage is the startup requirement.
    if not can_move_to_position(spawn_position, 0.8):
        return
    _place_player_on_surface()

func _refresh_streaming() -> void:
    if _player == null or _generator == null:
        return
    var refresh_started_usec: int = Time.get_ticks_usec()
    var player_xz := Vector2(_player.global_position.x, _player.global_position.z)
    var player_y: float = _player.global_position.y
    var heading: Vector2 = _get_streaming_heading()
    var wanted: Dictionary = {}
    # The coarsest roots cover the world; every descendant remains a voxel-based mesh.
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            _collect_lod_tiles(7, tx, tz, player_xz, heading, wanted, player_y)

    # Detect actual LOD-tree topology changes. Player movement inside the same LOD bands
    # only updates priorities/distances and must not trigger a full hierarchy traversal.
    var previous_wanted: Dictionary = _wanted
    var changed_topology: Array[Vector2i] = []
    for previous_key_value in previous_wanted.keys():
        var previous_key: Vector2i = previous_key_value
        if not wanted.has(previous_key):
            changed_topology.append(previous_key)
        elif bool(previous_wanted[previous_key].get("fallback", false)) != bool(wanted[previous_key].get("fallback", false)):
            changed_topology.append(previous_key)
    for wanted_key_value in wanted.keys():
        var wanted_key: Vector2i = wanted_key_value
        if not previous_wanted.has(wanted_key):
            changed_topology.append(wanted_key)

    _wanted = wanted
    for changed_coord in changed_topology:
        _mark_hierarchy_dirty_for(changed_coord)
    for queued_coord in _queued.keys():
        if not wanted.has(queued_coord):
            _queued.erase(queued_coord)
    for existing_value in _chunks.keys():
        var existing_coord: Vector2i = existing_value
        if wanted.has(existing_coord):
            continue
        var old_chunk: VoxelTerrainChunk = _chunks[existing_coord] as VoxelTerrainChunk
        var existing_lod: int = int(_decode_lod_key(existing_coord)["lod"])
        # Retain the handful of LOD7 world roots, but do not keep thousands of obsolete
        # fine-detail chunks cached along a high-speed flight path.
        if existing_lod == 7:
            old_chunk.set_render_active(false)
            _update_neighbor_chunk_skirts(existing_coord)
            if old_chunk.mesh_ready:
                old_chunk._retire_current_generation()
            _queue_chunk_retirement(old_chunk)
            continue
        var tile_size_m: float = chunk_size_m * float(1 << existing_lod)
        var inner_boundary: float = get_lod_boundary_m(existing_lod - 1) if existing_lod > 0 else 0.0
        var cache_radius: float = maxf(tile_size_m, inner_boundary + tile_size_m * 1.5)
        if _distance_to_tile_xz(player_xz, existing_coord) > cache_radius:
            old_chunk.set_render_active(false)
            old_chunk._retire_current_generation()
            remove_child(old_chunk)
            _chunk_resource_manager.track_retiring_chunk(old_chunk)
            _chunks.erase(existing_coord)
            _completed_jobs.erase(existing_coord)
            _queued.erase(existing_coord)
            _update_neighbor_chunk_skirts(existing_coord)
        else:
            old_chunk.set_render_active(false)
            _update_neighbor_chunk_skirts(existing_coord)
    for coord_value in wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = wanted[coord]
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk != null:
            # Collision requests can change while the visible LOD tree stays the same.
            # Sync the collider immediately instead of waiting for a topology change.
            chunk.set_render_active(chunk._render_active, bool(request["collision"]))
        var fallback_children_ready: bool = _fallback_children_ready(coord)
        var rejected_same_mesh_request: bool = chunk != null and chunk.mesh_upload_rejected and chunk.rejected_mesh_lod == int(request["lod"]) and chunk.rejected_mesh_step_voxels == int(request["step_voxels"])
        # A deterministic oversize/malformed mesh must not enter an endless rebuild loop.
        # The parent LOD remains visible until this tile can produce an acceptable mesh.
        var needs_build: bool = not rejected_same_mesh_request and not fallback_children_ready and (chunk == null or not chunk.mesh_ready)
        if chunk != null and not fallback_children_ready and not rejected_same_mesh_request:
            var has_shadow_proxy: bool = chunk.shadow_vertex_count > 0
            var wants_shadow_proxy: bool = bool(request.get("shadow_proxy", false))
            var shadow_proxy_mismatch: bool = has_shadow_proxy != wants_shadow_proxy
            needs_build = needs_build or (
                chunk.lod != int(request["lod"])
                or chunk.mesh_step_voxels != int(request["step_voxels"])
                or (bool(request["collision"]) and not chunk.collision_enabled)
                or shadow_proxy_mismatch
            )
        # Do not retire a fallback parent just because its children are ready. Keep the
        # mesh cached while hidden so the parent can be restored immediately when LOD topology changes.
        if _running_job_matches(coord, request) or _completed_job_matches(coord, request):
            _queued.erase(coord)
        elif needs_build:
            var previous: Dictionary = _queued.get(coord, {})
            if not previous.is_empty() and int(previous.get("lod", -1)) == int(request["lod"]) and int(previous.get("step_voxels", -1)) == int(request["step_voxels"]) and bool(previous.get("collision", false)) == bool(request["collision"]):
                request["queued_usec"] = int(previous.get("queued_usec", Time.get_ticks_usec()))
            else:
                request["queued_usec"] = Time.get_ticks_usec()
            _queued[coord] = request
        else:
            _queued.erase(coord)
    _record_timing(_refresh_usec_samples, Time.get_ticks_usec() - refresh_started_usec, 96)

func _poll_worker_tasks() -> void:
    for task_key in _running_tasks.keys():
        var task_id: int = int(task_key)
        var active_record: Dictionary = _running_tasks[task_id]
        var active_coord: Vector2i = active_record["coord"]
        if not bool(active_record.get("cancel_requested", false)) and not _job_record_matches_current(active_record, active_coord):
            var active_builder = active_record.get("builder")
            if active_builder != null and active_builder.has_method("cancel"):
                active_builder.call("cancel")
            active_record["cancel_requested"] = true
            _running_tasks[task_id] = active_record
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var record: Dictionary = _running_tasks[task_id]
        _running_tasks.erase(task_id)
        var coord: Vector2i = record["coord"]
        if int(_running_by_coord.get(coord, -1)) == task_id:
            _running_by_coord.erase(coord)
        var builder = record["builder"]
        var data: Dictionary = builder.result
        if data.is_empty():
            if _wanted.has(coord) and not _fallback_children_ready(coord):
                var retry_empty: Dictionary = _wanted[coord].duplicate(true)
                retry_empty["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry_empty
            continue
        # Treat the request as authoritative even if an older compiled native extension
        # does not return this metadata field yet. Both mesh builders receive the same stride.
        data["step_voxels"] = int(record["request"].get("step_voxels", get_mesh_step_voxels(int(record["request"]["lod"]))))
        var lod_index: int = clampi(int(data.get("lod", record["request"]["lod"])), 0, 7)
        _record_timing(_build_usec_by_lod[lod_index], int(data.get("build_usec", 0)), 128)
        var queue_wait_usec: int = maxi(0, int(data.get("worker_started_usec", Time.get_ticks_usec())) - int(record.get("queued_usec", Time.get_ticks_usec())))
        _max_queue_wait_usec = maxi(_max_queue_wait_usec, queue_wait_usec)
        _record_timing(_queue_wait_usec_samples, queue_wait_usec, 128)
        if _job_record_matches_current(record, coord) and not _fallback_children_ready(coord):
            record["data"] = data
            record["completed_usec"] = Time.get_ticks_usec()
            _completed_jobs[coord] = record
            _store_cached_mesh(str(record.get("cache_key", "")), data)
        else:
            _stale_result_count += 1
            if _wanted.has(coord) and not _running_by_coord.has(coord) and not _fallback_children_ready(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry
