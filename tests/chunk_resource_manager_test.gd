extends SceneTree

const ManagerScript = preload("res://scripts/streaming/chunk_resource_manager.gd")
const ChunkScript = preload("res://scripts/streaming/voxel_chunk.gd")


func _initialize() -> void:
    var manager = ManagerScript.new()
    var chunk = ChunkScript.new()
    manager.recycle_retired_chunk(chunk)
    assert(manager.get_pool_size() == 1)
    var reused = manager.take_pooled_chunk()
    assert(reused == chunk)
    assert(manager.get_pool_size() == 0)
    reused.free()
    quit(0)
