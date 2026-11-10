extends "res://scripts/streaming/voxel_world/voxel_world_layer_04_streaming.gd"

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed and not event.echo):
        return
    # F3 is reserved for diagnostics. F4 changes only a shader uniform; chunks are not rebuilt.
    if event.keycode == KEY_F4 or event.physical_keycode == KEY_F4:
        _debug_lod_colors = not _debug_lod_colors
        if _voxel_material != null:
            _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)
        for chunk_value in _chunks.values():
            var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
            if chunk != null:
                chunk.set_mesh_shader_parameter("debug_lod_colors", _debug_lod_colors)
        get_viewport().set_input_as_handled()
    elif event.keycode == KEY_R:
        regenerate_with_random_seed()

func _refresh_lod_boundaries() -> void:
    var screen_height: float = float(maxi(1, _current_viewport_pixel_size().y))
    for i in range(_lod_boundaries_m.size()):
        _lod_boundaries_m[i] = get_lod_boundary_m_for_height(i, screen_height, lod_target_pixels)

func _find_visible_lod_key_at_point(point: Vector2) -> Vector2i:
    if point.x < _world_min_x or point.y < _world_min_z or point.x >= _world_min_x + world_size_m or point.y >= _world_min_z + world_size_m:
        return Vector2i(-1, -1)
    for lod_index in range(8):
        var tile_m: float = chunk_size_m * float(1 << lod_index)
        var tx: int = floori((point.x - _world_min_x) / tile_m)
        var tz: int = floori((point.y - _world_min_z) / tile_m)
        var candidate := _make_lod_key(lod_index, tx, tz)
        var chunk: VoxelTerrainChunk = _chunks.get(candidate) as VoxelTerrainChunk
        if chunk != null and chunk.mesh_ready and chunk._render_active:
            return candidate
    return _find_target_lod_key_at_point(point)

func _collect_lod_tiles(lod_index: int, tile_x: int, tile_z: int, player_xz: Vector2, heading: Vector2, wanted: Dictionary, player_y: float = 0.0) -> void:
    # Hot streaming path: calculate tile bounds arithmetically instead of allocating the
    # eleven-key Dictionary returned by _chunk_bounds() for every visited node.
    var key := _make_lod_key(lod_index, tile_x, tile_z)
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    if size_x <= 0 or size_z <= 0:
        return
    var origin_x: float = _world_min_x + float(start_x) * VOXEL_SIZE
    var origin_z: float = _world_min_z + float(start_z) * VOXEL_SIZE
    var width: float = float(size_x) * VOXEL_SIZE
    var depth: float = float(size_z) * VOXEL_SIZE
    var center := Vector2(origin_x + width * 0.5, origin_z + depth * 0.5)
    var nearest_x: float = clampf(player_xz.x, origin_x, origin_x + width)
    var nearest_z: float = clampf(player_xz.y, origin_z, origin_z + depth)
    var dx: float = player_xz.x - nearest_x
    var dz: float = player_xz.y - nearest_z
    # Euclidean distance from the player to the local terrain surface (X, Y, Z), not an XZ-only radius.
    var terrain_y: float = _generator.get_surface_height(nearest_x, nearest_z)
    var vertical_delta: float = player_y - terrain_y
    var nearest: float = sqrt(dx * dx + dz * dz + vertical_delta * vertical_delta)
    if nearest > render_distance_m:
        return
    var boundary: float = _lod_boundary_for(lod_index - 1) if lod_index > 0 else -1.0
    if lod_index == 7:
        boundary = get_lod_boundary_m(6)
    var previous: Dictionary = _wanted.get(key, {})
    var was_split: bool = bool(previous.get("fallback", false))
    var split: bool = false
    if lod_index > 0:
        var scaled_hysteresis: float = boundary * lod_hysteresis_ratio
        var threshold: float = boundary + scaled_hysteresis if was_split else maxf(0.0, boundary - scaled_hysteresis)
        split = nearest < threshold
    var horizontal_center_distance: float = center.distance_to(player_xz)
    var req := {
        "lod": lod_index, "fallback": split, "distance": nearest,
        "nearest_distance": nearest, "priority": horizontal_center_distance - maxf(0.0, (center - player_xz).dot(heading) * 0.30),
        "collision": lod_index == 0 and nearest <= collision_distance_m,
        "start_x": start_x, "start_z": start_z,
        "size_x": size_x, "size_z": size_z,
        "tile_x": tile_x, "tile_z": tile_z, "tile_size_m": chunk_size_m * float(1 << lod_index),
        "step_voxels": get_mesh_step_voxels(lod_index),
        "shadow_proxy": nearest <= TERRAIN_SHADOW_DISTANCE_M
    }
    wanted[key] = req
    if split:
        for dz_offset in range(2):
            for dx_offset in range(2):
                _collect_lod_tiles(lod_index - 1, tile_x * 2 + dx_offset, tile_z * 2 + dz_offset, player_xz, heading, wanted, player_y)

func _deadline_priority(center: Vector2, request: Dictionary, player_xz: Vector2, heading: Vector2, velocity: Vector2) -> float:
    var offset: Vector2 = center - player_xz
    var speed: float = velocity.length()
    var lod_index: int = clampi(int(request["lod"]), 0, 7)
    if lod_index == 7:
        return -100000.0 + center.distance_to(player_xz)
    if bool(request.get("fallback", false)):
        return -50000.0 - float(lod_index) * 1000.0 + center.distance_to(player_xz)
    var estimate_seconds: float = _estimated_lod_pipeline_usec(lod_index) / 1000000.0
    var priority: float
    if speed >= 2.0:
        var direction: Vector2 = velocity / speed
        var along_track: float = offset.dot(direction)
        var lateral: float = absf(offset.cross(direction))
        if along_track < -float(request.get("tile_size_m", chunk_size_m)) * 0.5:
            priority = 2.0 + center.distance_to(player_xz) / speed + lateral * 0.02
        else:
            var eta: float = maxf(0.0, along_track - float(request.get("tile_size_m", chunk_size_m)) * 0.5) / speed
            priority = eta - estimate_seconds + lateral / maxf(speed, 1.0) * 0.35
    else:
        priority = center.distance_to(player_xz) - maxf(0.0, offset.dot(heading)) * 0.30
    if lod_index == 0:
        priority -= 0.15
    elif lod_index == 1:
        priority -= 0.07
    if bool(request["collision"]):
        var nearest: float = float(request.get("nearest_distance", center.distance_to(player_xz)))
        # A collider must arrive before the player reaches the tile, even when visual LOD work is queued.
        priority -= 10000.0 + clampf((collision_distance_m - nearest) / maxf(collision_distance_m, 1.0), 0.0, 1.0) * 0.35
    return priority

func _effective_prediction_seconds() -> float:
    var measured_work_usec: float = _estimated_lod_pipeline_usec(0)
    # Include the refresh interval itself as well as measured refresh cost, because a
    # chunk can be queued just after the last streaming refresh.
    # The 4 s ceiling prevents one pathological queue sample from exploding the fine-LOD area.
    return maxf(streaming_prediction_seconds, minf(measured_work_usec / 1000000.0 + 0.25, 4.0))

func _ready() -> void:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("VoxEn native extension is required. Build the Windows x86-64 GDExtension before running Far a Way.")
        set_process(false)
        set_physics_process(false)
        return
    var native_builder_check: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if native_builder_check == null:
        push_error("VoxEnBuilder is registered but could not be instantiated. Check the native library build.")
        set_process(false)
        set_physics_process(false)
        return
    native_builder_check = null
    _world_size_voxels = int(round(world_size_m / VOXEL_SIZE))
    _chunk_size_voxels = int(round(chunk_size_m / VOXEL_SIZE))
    _world_min_x = -world_size_m * 0.5
    _world_min_z = -world_size_m * 0.5
    _chunks_per_axis = int(ceil(float(_world_size_voxels) / float(_chunk_size_voxels)))
    render_distance_m = clampf(GameSettings.view_distance_m, 512.0, 2048.0)
    lod_target_pixels = clampf(GameSettings.lod_target_pixels, 2.0, 4.0)
    _last_viewport_size = _current_viewport_pixel_size()
    _refresh_lod_boundaries()
    _player = get_node_or_null(NodePath("../Player")) as CharacterBody3D
    if _player != null:
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
    var surface_shader := load("res://shaders/voxel_surface.gdshader") as Shader
    _voxel_material = ShaderMaterial.new()
    _voxel_material.shader = surface_shader
    _apply_seed_to_material()

    if _player != null:
        # Keep physics disabled until the background terrain preparation finds and
        # validates a safe spawn point and the corresponding collider is streamed.
        _player.global_position = Vector3(0.0, 1200.0, 0.0)
        _player.set_physics_process(false)
        _startup_load_pending = true

    if auto_start_on_ready:
        regenerate_with_seed(seed_value)

func get_debug_text() -> String:
    var lod_counts: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
    var collider_count: int = 0
    var near_pending: int = 0
    var render_vertices: int = 0
    var render_indices: int = 0
    var estimated_mesh_bytes: int = 0
    var shadow_vertices: int = 0
    for coord_value in _chunks.keys():
        var chunk: VoxelTerrainChunk = _chunks[coord_value] as VoxelTerrainChunk
        if chunk.lod >= 0 and chunk.lod < lod_counts.size():
            lod_counts[chunk.lod] += 1
        if chunk.collision_active:
            collider_count += 1
        render_vertices += chunk.render_vertex_count
        render_indices += chunk.render_index_count
        estimated_mesh_bytes += chunk.estimated_mesh_bytes
        shadow_vertices += chunk.shadow_vertex_count
    for coord_value in _wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _wanted[coord]
        if float(request.get("nearest_distance", INF)) > 40.0:
            continue
        var near_chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if near_chunk == null or not near_chunk.mesh_ready or near_chunk.lod != int(request["lod"]):
            near_pending += 1
    var l0: Array = _build_usec_by_lod[0]
    var l1: Array = _build_usec_by_lod[1]
    var planar_speed: float = 0.0
    if _player != null:
        planar_speed = Vector2(_player.velocity.x, _player.velocity.z).length()
    var prediction_seconds: float = _effective_prediction_seconds()
    var estimated_work_seconds: float = _estimated_lod_pipeline_usec(0) / 1000000.0
    var lead_margin_m: float = planar_speed * (prediction_seconds - estimated_work_seconds)
    var builder_mode: String = "NATIVE C++" if ClassDB.class_exists("VoxEnNativeBuilder") else "NATIVE C++ MISSING"
    var fps: int = Engine.get_frames_per_second()
    var frame_ms: float = 1000.0 / maxf(float(fps), 1.0)
    var video_memory_mb: float = float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
    var primitives: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
    var mesh_memory_mb: float = float(estimated_mesh_bytes) / 1048576.0
    return "VoxEn diagnostics | %s | FPS %d (%.1f ms) | seed %d | chunks %d | LOD 0:%d 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d 7:%d | verts %d | indices %d | mesh est. %.1f MiB | GPU %.1f MiB | prims %d | shadow verts %d | colliders %d | jobs %d running + %d queued | near pending %d | stale %d | cache %d entries / %.1f MiB | pool %d\nBuild avg/p95 ms: L0 %.1f/%.1f L1 %.1f/%.1f | refresh p95 %.2f ms | queue p95/max %.0f/%.1f ms | apply p95 %.0f ms | L0 margin %.1f m (pred %.1fs)\nControls: F3 diagnostics | M weather/time | Esc pause" % [
        builder_mode, fps, frame_ms,
        seed_value, _chunks.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4], lod_counts[5], lod_counts[6], lod_counts[7],
        render_vertices, render_indices, mesh_memory_mb, video_memory_mb, primitives, shadow_vertices,
        collider_count, _running_tasks.size(), _queued.size(), near_pending, _stale_result_count,
        _mesh_cache.size(), float(_mesh_cache_bytes) / 1048576.0, _chunk_pool.size(),
        _avg_ms(l0), _build_p95_cached_usec[0] / 1000.0, _avg_ms(l1), _build_p95_cached_usec[1] / 1000.0,
        _refresh_p95_cached_usec / 1000.0, _queue_wait_p95_cached_usec / 1000.0,
        float(_max_queue_wait_usec) / 1000.0, _apply_wait_p95_cached_usec / 1000.0,
        lead_margin_m, prediction_seconds
    ]

func _should_show_chunk_skirt(neighbor_coord: Vector2i, chunk: VoxelTerrainChunk, target_lod: int) -> bool:
    if target_lod < 0:
        return false
    if target_lod != chunk.lod:
        return true
    var neighbor_key := _find_visible_lod_key_at_point(_chunk_center(neighbor_coord))
    var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_key) as VoxelTerrainChunk
    return neighbor == null or not neighbor.mesh_ready or not neighbor._render_active or neighbor.lod != chunk.lod

func _target_lod_for_neighbor(neighbor_coord: Vector2i) -> int:
    if neighbor_coord.x < 0 or neighbor_coord.y < 0:
        return -1
    var visible_key := _find_visible_lod_key_at_point(_chunk_center(neighbor_coord))
    var visible_chunk: VoxelTerrainChunk = _chunks.get(visible_key) as VoxelTerrainChunk
    if visible_chunk != null and visible_chunk.mesh_ready and visible_chunk._render_active:
        return visible_chunk.lod
    var neighbor_center: Vector2 = _chunk_center(neighbor_coord)
    var target_key := _find_target_lod_key_at_point(neighbor_center)
    var target: Dictionary = _wanted.get(target_key, {})
    return int(target.get("lod", -1))

func _get_lod_tile_children(coord: Vector2i) -> Array[Vector2i]:
    var children: Array[Vector2i] = []
    if not _wanted.has(coord) or not bool(_wanted[coord].get("fallback", false)):
        return children
    var parts := _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    if lod_index <= 0:
        return children
    var tx: int = int(parts["tile_x"])
    var tz: int = int(parts["tile_z"])
    for dz in range(2):
        for dx in range(2):
            var child_key := _make_lod_key(lod_index - 1, tx * 2 + dx, tz * 2 + dz)
            # Wanted children were already bounds-checked by _collect_lod_tiles.
            if _wanted.has(child_key):
                children.append(child_key)
    return children

func _update_chunk_skirt_visibility(coord: Vector2i, chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not chunk.mesh_ready:
        return
    var left_key := _lod_neighbor_key(coord, Vector2i(-1, 0))
    var right_key := _lod_neighbor_key(coord, Vector2i(1, 0))
    var north_key := _lod_neighbor_key(coord, Vector2i(0, -1))
    var south_key := _lod_neighbor_key(coord, Vector2i(0, 1))
    chunk.set_skirt_visibility(Vector4(
        1.0 if _should_show_chunk_skirt(left_key, chunk, _target_lod_for_neighbor(left_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(right_key, chunk, _target_lod_for_neighbor(right_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(north_key, chunk, _target_lod_for_neighbor(north_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(south_key, chunk, _target_lod_for_neighbor(south_key)) else 0.0
    ))
