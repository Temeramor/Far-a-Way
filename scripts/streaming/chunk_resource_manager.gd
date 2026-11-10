extends RefCounted

const MAX_POOLED_CHUNK_NODES: int = 32

var _chunk_pool: Array[VoxelTerrainChunk] = []
var _retirement_queue: Array[VoxelTerrainChunk] = []
var _retirement_lookup: Dictionary = {}
var _retiring_chunks: Array[VoxelTerrainChunk] = []


func queue_retirement(chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not is_instance_valid(chunk):
        return
    var instance_id: int = chunk.get_instance_id()
    if _retirement_lookup.has(instance_id):
        return
    _retirement_lookup[instance_id] = true
    _retirement_queue.append(chunk)


func track_retiring_chunk(chunk: VoxelTerrainChunk) -> void:
    _retiring_chunks.append(chunk)


func recycle_retired_chunk(chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not is_instance_valid(chunk):
        return
    chunk.set_render_active(false)
    if _chunk_pool.size() < MAX_POOLED_CHUNK_NODES:
        chunk.name = "PooledVoxelChunk"
        _chunk_pool.append(chunk)
    else:
        chunk.free()


func take_pooled_chunk() -> VoxelTerrainChunk:
    if _chunk_pool.is_empty():
        return null
    var chunk: VoxelTerrainChunk = _chunk_pool.pop_back()
    chunk.set_render_active(true)
    return chunk


func get_pool_size() -> int:
    return _chunk_pool.size()


func retire_stale_resources() -> void:
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
            recycle_retired_chunk(stale_chunk)
        if retired_count >= 8 or Time.get_ticks_usec() - started_usec >= 2500:
            return


func shutdown(chunks: Dictionary) -> void:
    for chunk_value in chunks.values():
        var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        if chunk != null and is_instance_valid(chunk):
            while chunk.retire_one_old_node():
                pass
    for stale_chunk in _retiring_chunks:
        while stale_chunk.retire_one_old_node():
            pass
        if is_instance_valid(stale_chunk):
            stale_chunk.free()
    _retiring_chunks.clear()
    for pooled_chunk in _chunk_pool:
        if is_instance_valid(pooled_chunk):
            pooled_chunk.free()
    _chunk_pool.clear()
    _retirement_queue.clear()
    _retirement_lookup.clear()
