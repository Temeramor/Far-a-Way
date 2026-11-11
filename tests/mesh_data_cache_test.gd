extends Node

const CacheScript = preload("res://scripts/streaming/mesh_data_cache.gd")


func _ready() -> void:
    var errors: Array[String] = []
    var cache = CacheScript.new()
    var payload := {"vertices": PackedVector3Array([Vector3.ZERO])}
    cache.store_mesh("first", payload)
    _check(cache.get_entry_count() == 1, "A stored mesh should create one cache entry.", errors)
    _check(cache.get_mesh("first").has("vertices"), "The cached mesh payload should be retrievable.", errors)
    _check(cache.get_bytes_used() == 12, "The cache should account for the packed vertex bytes.", errors)
    cache.clear()
    cache.store_mesh("oldest", payload)
    for index in range(32):
        cache.store_mesh("mesh_%d" % index, payload)
    _check(cache.get_entry_count() == 32, "The cache should respect its 32-entry capacity.", errors)
    _check(cache.get_mesh("oldest").is_empty(), "The oldest entry should be evicted at capacity.", errors)
    cache.clear()
    _check(cache.get_entry_count() == 0, "Clearing should remove all cache entries.", errors)
    _check(cache.get_bytes_used() == 0, "Clearing should reset byte accounting.", errors)
    if not errors.is_empty():
        for error_text in errors:
            push_error(error_text)
        get_tree().quit(1)
        return
    print("PASS: mesh_data_cache_test")
    get_tree().quit(0)


func _check(condition: bool, message: String, errors: Array[String]) -> void:
    if not condition:
        errors.append(message)
