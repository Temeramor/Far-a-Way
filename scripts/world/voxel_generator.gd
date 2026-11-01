extends RefCounted
class_name VoxelTerrainGenerator

## Seeded terrain profile sampled as 20 cm voxel columns.
## Chunk meshing is streamed; no world-sized height array or per-voxel Node allocation is used.

const VOXEL_SIZE: float = 0.2
const VERTICAL_OFFSET_VOXELS: int = 1536
const AIR: int = 0
const GRASS: int = 1
const SOIL: int = 2
const ROCK: int = 3
const SAND: int = 4
const MIN_TERRAIN_HEIGHT: float = -220.0
const MAX_TERRAIN_HEIGHT: float = 1600.0
const HEIGHT_SAMPLE_STEP_M: float = 0.5
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
    # Mountain presence is seed-driven: some islands are low and hilly, others carry one to three ranges.
    var range_count: int = rng.randi_range(0, 3)
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
    if _native_sampler == null:
        return VOXEL_SIZE
    return float(_native_sampler.call("get_surface_height", x, z))


func get_surface_sample(x: float, z: float) -> Vector3:
    if _native_sampler == null:
        return Vector3(VOXEL_SIZE, 0.0, 0.0)
    return _native_sampler.call("get_surface_sample", x, z, HEIGHT_SAMPLE_STEP_M)


func get_surface_height_grid(
        origin_x: float, origin_z: float, columns: int, rows: int,
        step_m: float = HEIGHT_SAMPLE_STEP_M) -> PackedFloat32Array:
    if _native_sampler == null:
        return PackedFloat32Array()
    return _native_sampler.call(
        "sample_height_grid", origin_x, origin_z, columns, rows, step_m
    )


func get_surface_height_voxels(x: float, z: float) -> int:
    # Signed world-space height; the native mesher applies its internal vertical origin.
    return int(round(get_surface_height(x, z) / VOXEL_SIZE))


func find_safe_spawn_position(_chunk_size_m: float = 32.0) -> Vector2:
    # Search the whole island for a naturally flat, dry clearing. Height alone is
    # deliberately not a selection criterion: mountain peaks and steep ridges fail.
    var half: float = world_size_m * 0.5
    var coarse_step: float = 25.0
    var columns: int = int(floor(world_size_m / coarse_step)) + 1
    var samples: PackedFloat32Array = get_surface_height_grid(
        -half, -half, columns, columns, coarse_step
    )
    var best_score: float = -INF
    var best_position := Vector2(INF, INF)

    for z in range(columns):
        for x in range(columns):
            var index: int = z * columns + x
            if index >= samples.size():
                continue
            var coarse_height: float = samples[index]
            if coarse_height < 3.0 or coarse_height > 100.0:
                continue
            var px: float = -half + float(x) * coarse_step
            var pz: float = -half + float(z) * coarse_step
            if absf(px) > half - 8.0 or absf(pz) > half - 8.0:
                continue
            var chunk_local_x: float = fposmod(px + half, maxf(_chunk_size_m, 1.0))
            var chunk_local_z: float = fposmod(pz + half, maxf(_chunk_size_m, 1.0))
            if minf(chunk_local_x, _chunk_size_m - chunk_local_x) < 2.0 or minf(chunk_local_z, _chunk_size_m - chunk_local_z) < 2.0:
                continue
            var score: float = _safe_spawn_candidate_score(px, pz)
            if score > best_score:
                best_score = score
                best_position = Vector2(px, pz)

    if not is_finite(best_score):
        return Vector2(INF, INF)

    # Refine around the best broad-area candidate so the final point is not tied
    # to the coarse scan lattice.
    var coarse_best: Vector2 = best_position
    for z in range(-6, 7):
        for x in range(-6, 7):
            var px: float = coarse_best.x + float(x) * 2.0
            var pz: float = coarse_best.y + float(z) * 2.0
            if absf(px) > half - 8.0 or absf(pz) > half - 8.0:
                continue
            var chunk_local_x: float = fposmod(px + half, maxf(_chunk_size_m, 1.0))
            var chunk_local_z: float = fposmod(pz + half, maxf(_chunk_size_m, 1.0))
            if minf(chunk_local_x, _chunk_size_m - chunk_local_x) < 2.0 or minf(chunk_local_z, _chunk_size_m - chunk_local_z) < 2.0:
                continue
            var score: float = _safe_spawn_candidate_score(px, pz)
            if score > best_score:
                best_score = score
                best_position = Vector2(px, pz)
    return best_position


func _safe_spawn_candidate_score(world_x: float, world_z: float) -> float:
    var center: Vector3 = get_surface_sample(world_x, world_z)
    var center_slope: float = Vector2(center.y, center.z).length()
    if center.x < 3.0 or center.x > 100.0 or center_slope > 0.22:
        return -INF

    var offsets: Array[Vector2] = [
        Vector2(3.0, 0.0), Vector2(-3.0, 0.0),
        Vector2(0.0, 3.0), Vector2(0.0, -3.0),
        Vector2(2.1, 2.1), Vector2(-2.1, 2.1),
        Vector2(2.1, -2.1), Vector2(-2.1, -2.1)
    ]
    var min_height: float = center.x
    var max_height: float = center.x
    var max_slope: float = center_slope
    for offset in offsets:
        var sample: Vector3 = get_surface_sample(world_x + offset.x, world_z + offset.y)
        var sample_slope: float = Vector2(sample.y, sample.z).length()
        if sample.x < 2.0 or sample_slope > 0.28:
            return -INF
        min_height = minf(min_height, sample.x)
        max_height = maxf(max_height, sample.x)
        max_slope = maxf(max_slope, sample_slope)

    var height_spread: float = max_height - min_height
    if height_spread > 1.5:
        return -INF
    # Prefer broad, nearly level ground; elevation is only a small tie-breaker.
    return -max_slope * 20.0 - height_spread * 4.0 + minf(center.x, 60.0) * 0.015


func get_surface_rock_weight(gradient: float, x: float, z: float) -> float:
    if _native_sampler == null:
        return 0.0
    return float(_native_sampler.call("get_surface_rock_weight", gradient, x, z))


func get_surface_material(height_m: float, slope: float, x: float, z: float) -> int:
    if _native_sampler == null:
        return GRASS
    return int(_native_sampler.call("get_surface_material", height_m, slope, x, z))


func is_sand_surface(x: float, z: float) -> bool:
    var sample: Vector3 = get_surface_sample(x, z)
    var slope: float = Vector2(sample.y, sample.z).length()
    return get_surface_material(sample.x, slope, x, z) == SAND


func get_terrain_density(world_x: float, world_y: float, world_z: float) -> float:
    return get_surface_height(world_x, world_z) - world_y


func get_voxel_material(voxel: Vector3i, world_min_x: float, world_min_z: float, world_size_voxels: int) -> int:
    if voxel.x < 0 or voxel.z < 0 or voxel.x >= world_size_voxels or voxel.z >= world_size_voxels:
        return AIR
    var world_x: float = world_min_x + (float(voxel.x) + 0.5) * VOXEL_SIZE
    var world_z: float = world_min_z + (float(voxel.z) + 0.5) * VOXEL_SIZE
    var surface_y: int = get_surface_height_voxels(world_x, world_z) + VERTICAL_OFFSET_VOXELS
    var internal_y: int = voxel.y + VERTICAL_OFFSET_VOXELS
    if internal_y >= surface_y:
        return AIR
    var surface_sample: Vector3 = get_surface_sample(world_x, world_z)
    var surface_slope: float = Vector2(surface_sample.y, surface_sample.z).length()
    var top_material: int = get_surface_material(
        float(surface_y - VERTICAL_OFFSET_VOXELS) * VOXEL_SIZE, surface_slope, world_x, world_z
    )
    if internal_y == surface_y - 1:
        return top_material
    # A gray rock-topped mountain is a solid stone mass, not a brown soil rind.
    if top_material == ROCK:
        return ROCK
    if internal_y >= surface_y - 5:
        return SOIL
    return ROCK
