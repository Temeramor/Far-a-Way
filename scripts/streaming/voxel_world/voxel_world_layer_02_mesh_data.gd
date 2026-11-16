extends "res://scripts/streaming/voxel_world/voxel_world_layer_01_core.gd"

func _chunk_has_collision_resource(coord: Vector2i) -> bool:
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    return chunk != null and chunk.collision_enabled

func _distance_to_tile_xz(point: Vector2, coord: Vector2i) -> float:
    # Fast cache eviction distance without constructing a chunk-bounds Dictionary.
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var tile_z: int = coord.y
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    var center_x: float = _world_min_x + (float(start_x) + float(size_x) * 0.5) * VOXEL_SIZE
    var center_z: float = _world_min_z + (float(start_z) + float(size_z) * 0.5) * VOXEL_SIZE
    var half_width: float = float(size_x) * VOXEL_SIZE * 0.5
    var half_depth: float = float(size_z) * VOXEL_SIZE * 0.5
    var nearest_x: float = maxf(0.0, absf(point.x - center_x) - half_width)
    var nearest_z: float = maxf(0.0, absf(point.y - center_z) - half_depth)
    return sqrt(nearest_x * nearest_x + nearest_z * nearest_z)

func _make_mesh_cache_key(coord: Vector2i, request: Dictionary, neighbors: Dictionary, build_collision: bool) -> String:
    return _mesh_data_cache.make_key(seed_value, coord, request, neighbors, build_collision)

func _estimate_mesh_data_bytes(data: Dictionary) -> int:
    return _mesh_data_cache.estimate_data_bytes(data)

func _get_cached_mesh(cache_key: String) -> Dictionary:
    return _mesh_data_cache.get_mesh(cache_key)

func _create_mesh_builder() -> Object:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("Cannot build a voxel chunk: VoxEnNativeBuilder is unavailable.")
        return null
    var native_builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if native_builder == null:
        push_error("Cannot instantiate VoxEnNativeBuilder. Check the native library build.")
        return null
    if _generator != null:
        native_builder.call("share_terrain_sampler", _generator.get_native_sampler())
    return native_builder

func _job_record_matches_current(record: Dictionary, coord: Vector2i) -> bool:
    if not _wanted.has(coord):
        return false
    return _mesh_job_scheduler.is_record_current(record, _wanted[coord], _generation_epoch, seed_value)

func _running_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _running_by_coord.has(coord):
        return false
    var record: Dictionary = _running_tasks.get(int(_running_by_coord[coord]), {})
    return _mesh_job_scheduler.is_record_current(record, request, _generation_epoch, seed_value)

func _completed_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _completed_jobs.has(coord):
        return false
    return _mesh_job_scheduler.is_record_current(_completed_jobs[coord], request, _generation_epoch, seed_value)

func _chunk_center(coord: Vector2i) -> Vector2:
    # Hot path for queue prioritisation: calculate the centre without allocating a Dictionary.
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var tile_z: int = coord.y
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    return Vector2(
        _world_min_x + (float(start_x) + float(size_x) * 0.5) * VOXEL_SIZE,
        _world_min_z + (float(start_z) + float(size_z) * 0.5) * VOXEL_SIZE
    )

func _player_xz() -> Vector2:
    return Vector2(_player.global_position.x, _player.global_position.z) if _player != null else Vector2.ZERO

func _make_lod_key(lod_index: int, tile_x: int, tile_z: int) -> Vector2i:
    return Vector2i(lod_index * LOD_KEY_STRIDE + tile_x, tile_z)
