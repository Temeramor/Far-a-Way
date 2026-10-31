extends RefCounted
class_name VoxelTerrainGenerator

## Seeded terrain profile sampled as 20 cm voxel columns.
## Chunk meshing is streamed; no world-sized height array or per-voxel Node allocation is used.

const VOXEL_SIZE: float = 0.2
const AIR: int = 0
const GRASS: int = 1
const SOIL: int = 2
const ROCK: int = 3
const MIN_TERRAIN_HEIGHT: float = -80.0
const MAX_TERRAIN_HEIGHT: float = 1600.0
const HEIGHT_SAMPLE_STEP_M: float = 0.5
const MAX_SURFACE_CACHE_ENTRIES: int = 131072
const REFERENCE_WORLD_SIZE_M: float = 10000.0

var seed_value: int = 1337
var world_size_m: float = 2000.0
var _native_sampler: Object
var _mountain_starts: Array[Vector2] = []
var _mountain_deltas: Array[Vector2] = []
var _mountain_lengths_squared: Array[float] = []
var _mountain_widths: Array[float] = []
var _mountain_heights: Array[float] = []
var _mountain_phases: Array[float] = []
var _surface_height_cache: Dictionary = {}
var _surface_height_cache_order: Array[Vector2i] = []
var _surface_height_cache_cursor: int = 0


func _init(
        p_seed: int = 1337, p_world_size_m: float = 2000.0,
        p_native_sampler: Object = null) -> void:
    seed_value = p_seed
    world_size_m = maxf(256.0, p_world_size_m)
    if p_native_sampler != null:
        _native_sampler = p_native_sampler
        return
    _create_mountain_ranges()
    _native_sampler = ClassDB.instantiate("VoxEnNativeBuilder")
    if _native_sampler == null:
        push_error("VoxelTerrainGenerator requires VoxEnNativeBuilder as its native terrain sampler.")
        return
    _native_sampler.call("configure_terrain_sampler", {
        "seed": seed_value,
        "terrain_world_size_m": world_size_m,
        "mountain_profile": get_mountain_profile()
    })


func get_native_sampler() -> Object:
    return _native_sampler


func _create_mountain_ranges() -> void:
    _mountain_starts.clear()
    _mountain_deltas.clear()
    _mountain_lengths_squared.clear()
    _mountain_widths.clear()
    _mountain_heights.clear()
    _mountain_phases.clear()
    var mountain_scale: float = world_size_m / REFERENCE_WORLD_SIZE_M
    var rng := RandomNumberGenerator.new()
    rng.seed = int(seed_value) + 17011
    # Reduce chain density on smaller maps without changing the seeded chain-based algorithm.
    var range_count: int = clampi(roundi(3.0 * sqrt(mountain_scale)), 2, 5)
    var narrow_offset: float = 600.0 * mountain_scale
    var wide_offset: float = 1050.0 * mountain_scale
    for _range_index in range(range_count):
        var angle: float = rng.randf_range(0.0, PI)
        var direction := Vector2(cos(angle), sin(angle))
        var side := Vector2(-direction.y, direction.x)
        var center := Vector2(
            rng.randf_range(-world_size_m * 0.20, world_size_m * 0.20),
            rng.randf_range(-world_size_m * 0.20, world_size_m * 0.20)
        )
        var half_length: float = world_size_m * rng.randf_range(0.23, 0.34)
        var points: Array[Vector2] = [
            center - direction * half_length + side * rng.randf_range(-narrow_offset, narrow_offset),
            center - direction * half_length * 0.34 + side * rng.randf_range(-wide_offset, wide_offset),
            center + direction * half_length * 0.30 + side * rng.randf_range(-wide_offset, wide_offset),
            center + direction * half_length + side * rng.randf_range(-narrow_offset, narrow_offset)
        ]
        # Scale mountain height, width and lateral irregularity together with map size.
        # This keeps the range profile coherent on the smaller 2 km landscape.
        var range_height: float = rng.randf_range(850.0, 1320.0) * mountain_scale
        var range_width: float = rng.randf_range(540.0, 930.0) * mountain_scale
        var phase: float = rng.randf_range(0.0, TAU)
        for segment_index in range(points.size() - 1):
            var a: Vector2 = points[segment_index]
            var b: Vector2 = points[segment_index + 1]
            var delta: Vector2 = b - a
            _mountain_starts.append(a)
            _mountain_deltas.append(delta)
            _mountain_lengths_squared.append(maxf(delta.length_squared(), 0.001))
            _mountain_widths.append(range_width * rng.randf_range(0.88, 1.12))
            _mountain_heights.append(range_height * rng.randf_range(0.94, 1.06))
            _mountain_phases.append(phase + float(segment_index) * 1.7)


func get_mountain_profile() -> Array[Dictionary]:
    var profile: Array[Dictionary] = []
    for i in range(_mountain_starts.size()):
        profile.append({
            "start": _mountain_starts[i], "delta": _mountain_deltas[i],
            "length_squared": _mountain_lengths_squared[i], "width": _mountain_widths[i],
            "height": _mountain_heights[i], "phase": _mountain_phases[i]
        })
    return profile


func get_surface_height(x: float, z: float) -> float:
    var grid_x: int = roundi(x / HEIGHT_SAMPLE_STEP_M)
    var grid_z: int = roundi(z / HEIGHT_SAMPLE_STEP_M)
    if absf(x - float(grid_x) * HEIGHT_SAMPLE_STEP_M) < 0.0001 and absf(z - float(grid_z) * HEIGHT_SAMPLE_STEP_M) < 0.0001:
        return _get_cached_grid_height(grid_x, grid_z)
    return _calculate_surface_height(x, z)


func get_surface_sample(x: float, z: float) -> Vector3:
    # Bilinear sample the same half-metre height lattice used by voxel mesh jobs.
    # This keeps the original vegetation API inexpensive without a giant height map.
    var grid_x_float: float = x / HEIGHT_SAMPLE_STEP_M
    var grid_z_float: float = z / HEIGHT_SAMPLE_STEP_M
    var grid_x: int = floori(grid_x_float)
    var grid_z: int = floori(grid_z_float)
    var tx: float = clampf(grid_x_float - float(grid_x), 0.0, 1.0)
    var tz: float = clampf(grid_z_float - float(grid_z), 0.0, 1.0)
    var h00: float = _get_cached_grid_height(grid_x, grid_z)
    var h10: float = _get_cached_grid_height(grid_x + 1, grid_z)
    var h01: float = _get_cached_grid_height(grid_x, grid_z + 1)
    var h11: float = _get_cached_grid_height(grid_x + 1, grid_z + 1)
    var top: float = lerpf(h00, h10, tx)
    var bottom: float = lerpf(h01, h11, tx)
    var height: float = lerpf(top, bottom, tz)
    var slope_x: float = lerpf(h10 - h00, h11 - h01, tz) / HEIGHT_SAMPLE_STEP_M
    var slope_z: float = lerpf(h01 - h00, h11 - h10, tx) / HEIGHT_SAMPLE_STEP_M
    return Vector3(height, slope_x, slope_z)


func _get_cached_grid_height(grid_x: int, grid_z: int) -> float:
    var key := Vector2i(grid_x, grid_z)
    if _surface_height_cache.has(key):
        return float(_surface_height_cache[key])
    var x: float = float(grid_x) * HEIGHT_SAMPLE_STEP_M
    var z: float = float(grid_z) * HEIGHT_SAMPLE_STEP_M
    var height: float = _calculate_surface_height(x, z)
    if _surface_height_cache.size() >= MAX_SURFACE_CACHE_ENTRIES:
        var expired_key: Vector2i = _surface_height_cache_order[_surface_height_cache_cursor]
        _surface_height_cache.erase(expired_key)
        _surface_height_cache_order[_surface_height_cache_cursor] = key
        _surface_height_cache_cursor = (_surface_height_cache_cursor + 1) % MAX_SURFACE_CACHE_ENTRIES
    else:
        _surface_height_cache_order.append(key)
    _surface_height_cache[key] = height
    return height


func _calculate_surface_height(x: float, z: float) -> float:
    if _native_sampler == null:
        return VOXEL_SIZE
    return float(_native_sampler.call("get_surface_height", x, z))


func get_surface_height_voxels(x: float, z: float) -> int:
    return maxi(1, int(round(get_surface_height(x, z) / VOXEL_SIZE)))


func get_surface_rock_weight(gradient: float, x: float, z: float) -> float:
    if _native_sampler == null:
        return 0.0
    return float(_native_sampler.call("get_surface_rock_weight", gradient, x, z))


func get_surface_material(height_m: float, slope: float, x: float, z: float) -> int:
    # Categorical helper for vertical faces; top faces use the continuous weight directly.
    return ROCK if get_surface_rock_weight(slope, x, z) >= 0.5 else GRASS


func get_terrain_density(world_x: float, world_y: float, world_z: float) -> float:
    return get_surface_height(world_x, world_z) - world_y


func get_voxel_material(voxel: Vector3i, world_min_x: float, world_min_z: float, world_size_voxels: int) -> int:
    if voxel.x < 0 or voxel.z < 0 or voxel.x >= world_size_voxels or voxel.z >= world_size_voxels or voxel.y < 0:
        return AIR
    var world_x: float = world_min_x + (float(voxel.x) + 0.5) * VOXEL_SIZE
    var world_z: float = world_min_z + (float(voxel.z) + 0.5) * VOXEL_SIZE
    var surface_y: int = get_surface_height_voxels(world_x, world_z)
    if voxel.y >= surface_y:
        return AIR
    var surface_sample: Vector3 = get_surface_sample(world_x, world_z)
    var surface_slope: float = Vector2(surface_sample.y, surface_sample.z).length()
    var top_material: int = get_surface_material(
        float(surface_y) * VOXEL_SIZE, surface_slope, world_x, world_z
    )
    if voxel.y == surface_y - 1:
        return top_material
    # A gray rock-topped mountain is a solid stone mass, not a brown soil rind.
    if top_material == ROCK:
        return ROCK
    if voxel.y >= surface_y - 5:
        return SOIL
    return ROCK
