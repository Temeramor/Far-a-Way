extends Node

const CacheScript = preload("res://scripts/streaming/mesh_data_cache.gd")


func _ready() -> void:
    var cache = CacheScript.new()
    var payload := {"vertices": PackedVector3Array([Vector3.ZERO])}
    cache.store_mesh("first", payload)
    assert(cache.get_entry_count() == 1)
    assert(cache.get_mesh("first").has("vertices"))
    assert(cache.get_bytes_used() == 12)
    cache.clear()
    cache.store_mesh("oldest", payload)
    for index in range(32):
        cache.store_mesh("mesh_%d" % index, payload)
    assert(cache.get_entry_count() == 32)
    assert(cache.get_mesh("oldest").is_empty())
    cache.clear()
    assert(cache.get_entry_count() == 0)
    assert(cache.get_bytes_used() == 0)
    print("PASS: mesh_data_cache_test")
    get_tree().quit(0)
