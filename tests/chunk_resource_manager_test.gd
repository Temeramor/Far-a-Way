extends Node

const ManagerScript = preload("res://scripts/streaming/chunk_resource_manager.gd")
const ChunkScript = preload("res://scripts/streaming/voxel_chunk.gd")


func _ready() -> void:
    var errors: Array[String] = []
    var manager = ManagerScript.new()
    var chunk = ChunkScript.new()
    manager.recycle_retired_chunk(chunk)
    _check(manager.get_pool_size() == 1, "Recycling a retired chunk should populate the pool.", errors)
    var reused = manager.take_pooled_chunk()
    _check(reused == chunk, "The pool should return the recycled chunk instance.", errors)
    _check(manager.get_pool_size() == 0, "Taking a pooled chunk should empty the pool.", errors)
    if reused != null and is_instance_valid(reused):
        reused.free()
    if not errors.is_empty():
        for error_text in errors:
            push_error(error_text)
        get_tree().quit(1)
        return
    print("PASS: chunk_resource_manager_test")
    get_tree().quit(0)


func _check(condition: bool, message: String, errors: Array[String]) -> void:
    if not condition:
        errors.append(message)
