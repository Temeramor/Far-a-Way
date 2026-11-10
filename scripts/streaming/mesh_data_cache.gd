extends RefCounted

const MAX_BYTES: int = 48 * 1024 * 1024
const MAX_ENTRIES: int = 32

var _entries: Dictionary = {}
var _lru_order: Array[String] = []
var _bytes_used: int = 0


func make_key(seed_value: int, coord: Vector2i, request: Dictionary, neighbors: Dictionary, build_collision: bool) -> String:
    return "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
        seed_value, coord.x, coord.y, int(request["lod"]),
        int(request.get("step_voxels", 1)), int(bool(request["collision"])),
        int(build_collision), int(bool(request.get("shadow_proxy", false))),
        int(neighbors.get("left", -1)), int(neighbors.get("right", -1)),
        int(neighbors.get("north", -1)), int(neighbors.get("south", -1))
    ]


func estimate_data_bytes(data: Dictionary) -> int:
    var bytes: int = 0
    var vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = data.get("normals", PackedVector3Array())
    var colors: PackedColorArray = data.get("colors", PackedColorArray())
    var indices: PackedInt32Array = data.get("indices", PackedInt32Array())
    var shadow_vertices: PackedVector3Array = data.get("smooth_shadow_vertices", PackedVector3Array())
    var shadow_normals: PackedVector3Array = data.get("smooth_shadow_normals", PackedVector3Array())
    var shadow_indices: PackedInt32Array = data.get("smooth_shadow_indices", PackedInt32Array())
    bytes += vertices.size() * 12 + normals.size() * 12 + colors.size() * 16 + indices.size() * 4
    bytes += shadow_vertices.size() * 12 + shadow_normals.size() * 12 + shadow_indices.size() * 4
    var collision_data: Dictionary = data.get("collision_height_map", {})
    var collision_heights: PackedFloat32Array = collision_data.get("heights", PackedFloat32Array())
    bytes += collision_heights.size() * 4
    return bytes


func get_mesh(cache_key: String) -> Dictionary:
    if cache_key.is_empty() or not _entries.has(cache_key):
        return {}
    var record: Dictionary = _entries[cache_key]
    _lru_order.erase(cache_key)
    _lru_order.append(cache_key)
    return record.get("data", {})


func store_mesh(cache_key: String, data: Dictionary) -> void:
    if cache_key.is_empty() or data.is_empty():
        return
    var bytes: int = estimate_data_bytes(data)
    if bytes <= 0 or bytes > MAX_BYTES:
        return
    if _entries.has(cache_key):
        var old_record: Dictionary = _entries[cache_key]
        _bytes_used -= int(old_record.get("bytes", 0))
        _lru_order.erase(cache_key)
    _entries[cache_key] = {"data": data, "bytes": bytes}
    _lru_order.append(cache_key)
    _bytes_used += bytes
    while _bytes_used > MAX_BYTES or _entries.size() > MAX_ENTRIES:
        if _lru_order.is_empty():
            break
        var oldest_key: String = _lru_order.pop_front()
        var oldest_record: Dictionary = _entries.get(oldest_key, {})
        _bytes_used -= int(oldest_record.get("bytes", 0))
        _entries.erase(oldest_key)
    _bytes_used = maxi(0, _bytes_used)


func clear() -> void:
    _entries.clear()
    _lru_order.clear()
    _bytes_used = 0


func get_entry_count() -> int:
    return _entries.size()


func get_bytes_used() -> int:
    return _bytes_used
