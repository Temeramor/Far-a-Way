extends "res://scripts/streaming/voxel_world/voxel_world_state.gd"

func is_terrain_preparing() -> bool:
    return _active_terrain_prepare_task_id >= 0

func regenerate_with_seed(new_seed: int) -> void:
    # Existing worker tasks cannot be cancelled safely; their epoch makes their results stale.
    _world_started = false
    _startup_load_pending = true
    _spawn_validation_in_progress = false
    _spawn_validation_retry_cooldown = 0.0
    if _player != null:
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
    _generation_epoch += 1
    seed_value = new_seed
    _queued.clear()
    _wanted.clear()
    _completed_jobs.clear()
    _mesh_cache.clear()
    _mesh_cache_order.clear()
    _mesh_cache_bytes = 0

    # Hide the old world immediately; release mesh buffers gradually over later frames.
    # In-flight tasks finish, but their old epoch will reject their results.
    for chunk_value in _chunks.values():
        var old_chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        old_chunk.set_render_active(false)
        old_chunk._retire_current_generation()
        remove_child(old_chunk)
        _retiring_chunks.append(old_chunk)
    _chunks.clear()

    _generator = GeneratorScript.new(seed_value, world_size_m)
    _mountain_profile_cache.clear()
    _spawn_position_xz = Vector2.ZERO
    _spawn_validation_in_progress = false
    _startup_load_pending = true
    _world_started = false
    if _player != null:
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
        _player.global_position = Vector3(0.0, 1200.0, 0.0)
    _last_player_position = Vector2(INF, INF)
    _last_player_height = INF
    _last_refresh_chunk = Vector2i(-2147483648, -2147483648)

    # The native 2048² heightfield, hydraulic erosion and spawn search are CPU-heavy.
    # Run them away from the main thread so the loading screen can keep rendering.
    var task_id: int = WorkerThreadPool.add_task(
        Callable(_generator, "prepare_native_terrain").bind(chunk_size_m),
        false, "VoxEn terrain preparation seed %d" % seed_value
    )
    if task_id < 0:
        push_error("Far a Way could not schedule background terrain preparation.")
        return
    _active_terrain_prepare_task_id = task_id
    _terrain_prepare_jobs[task_id] = {
        "generator": _generator,
        "epoch": _generation_epoch
    }

func set_shadow_mode(mode: int) -> void:
    var safe_mode: int = clampi(mode, 0, 1)
    for chunk_value in _chunks.values():
        var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        if chunk != null:
            chunk.set_shadow_mode(safe_mode)

func get_lod_boundary_m(lod_index: int) -> float:
    if lod_index < 0 or lod_index > 6:
        return INF
    return _lod_boundaries_m[lod_index]

func _current_viewport_pixel_size() -> Vector2i:
    var viewport_size: Vector2i = get_viewport().size
    return Vector2i(maxi(1, viewport_size.x), maxi(1, viewport_size.y))

func get_mesh_step_voxels(lod_index: int) -> int:
    # Each LOD doubles cell size: 20 cm, 40 cm, 80 cm ... up to 25.6 m.
    # The former LOD0 -> LOD1 jump was 4x and left the map rim visibly over-coarsened.
    var tier: int = clampi(lod_index, 0, 7)
    return BASE_MESH_STEP_VOXELS << tier

func _apply_seed_to_material() -> void:
    if _voxel_material == null:
        return
    var safe_seed: int = abs(seed_value % 2147483647)
    _voxel_material.set_shader_parameter("seed_low", float(safe_seed % 65536))
    _voxel_material.set_shader_parameter("seed_high", float(int(floor(float(safe_seed) / 65536.0))))
    _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)

func get_surface_height(x: float, z: float) -> float:
    if _generator == null or not _generator.is_terrain_prepared():
        return 25.0
    return _generator.get_surface_height(x, z)

func get_voxel_material(global_voxel: Vector3i) -> int:
    if _generator == null or not _generator.is_terrain_prepared():
        return 1
    return _generator.get_voxel_material(global_voxel, _world_min_x, _world_min_z, _world_size_voxels)

func is_startup_loading() -> bool:
    return _startup_load_pending

func get_loaded_chunk_count() -> int:
    return _chunks.size()

func surface_sample_at_world(world_x: float, world_z: float) -> Vector3:
    if _generator == null or not _generator.is_terrain_prepared():
        return Vector3(25.0, 0.0, 0.0)
    return _generator.get_surface_sample(world_x, world_z)
