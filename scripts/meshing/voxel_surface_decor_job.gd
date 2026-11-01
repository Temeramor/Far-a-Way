extends RefCounted
class_name VoxelSurfaceDecorJob

## CPU-only decoration worker. It owns a private terrain sampler/cache and returns mesh data;
## SceneTree, ArrayMesh, and physics resources are created by VoxelSurfaceScatter on the main thread.

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const RockScatterScript = preload("res://scripts/world/decoration/voxel_rock_scatter.gd")
const VegetationScatterScript = preload("res://scripts/world/decoration/voxel_vegetation_scatter.gd")
const GridScript = preload("res://scripts/vegetation/vox_grid.gd")
const RESERVATION_CELL_SIZE: float = 2.0
const MAX_RESERVATION_RADIUS: float = 3.3

var result: Dictionary = {}
var world_size_m: float = 2000.0
var _generator: VoxelTerrainGenerator
var _rock_scatter = RockScatterScript.new()
var _vegetation_scatter = VegetationScatterScript.new()
var _reservation_cells: Dictionary = {}
var _cancellation_token: Object


func configure(seed_value: int, size_m: float, native_sampler: Object = null) -> void:
    world_size_m = size_m
    _generator = GeneratorScript.new(seed_value, size_m, native_sampler)
    _cancellation_token = ClassDB.instantiate("VoxEnNativeBuilder")
    # This task owns its terrain sampler and cache; it does not read mutable VoxelWorld state.


func cancel() -> void:
    if _cancellation_token != null:
        _cancellation_token.call("cancel")


func _is_cancelled() -> bool:
    return _cancellation_token != null and bool(_cancellation_token.call("is_cancelled"))


func build_rock_data(job_data: Dictionary) -> void:
    if _is_cancelled():
        return
    _reservation_cells.clear()
    var mesh_data = MeshDataScript.new()
    var reservations: Array[Dictionary] = []
    var collision_data: Array[Dictionary] = []
    var include_rocks: bool = bool(job_data.get("include_rocks", false))
    var palette_data: Dictionary = job_data["palette"]
    var tile_seed: int = int(job_data["tile_seed"])
    var distance_m: float = float(job_data["distance_m"])
    var build_collisions: bool = bool(job_data.get("build_collisions", false))

    if include_rocks:
        var rng := RandomNumberGenerator.new()
        rng.seed = _mix(tile_seed, 101, 307)
        _rock_scatter.build_tile(
            self, mesh_data, reservations, palette_data, rng, tile_seed,
            float(job_data["origin_x"]), float(job_data["origin_z"]),
            float(job_data["width_m"]), float(job_data["depth_m"]),
            int(job_data["prop_lod"]), distance_m, collision_data, build_collisions
        )
    if _is_cancelled():
        return

    result = {
        "kind": "rocks",
        "mesh_data": mesh_data,
        "palette": palette_data,
        "reservations": reservations,
        "collision_data": collision_data
    }


func build_plant_data(job_data: Dictionary) -> void:
    if _is_cancelled():
        return
    _reservation_cells.clear()
    var mesh_data = MeshDataScript.new()
    var reservations: Array[Dictionary] = []
    for occupied in job_data.get("reservations", []):
        reservations.append(occupied.duplicate(true))
    _rebuild_reservation_index(reservations)

    var rng := RandomNumberGenerator.new()
    var tile_seed: int = int(job_data["tile_seed"])
    rng.seed = _mix(tile_seed, 503, 709)
    _vegetation_scatter.build_tile(
        self, mesh_data, reservations, job_data["palette"], rng, tile_seed,
        float(job_data["origin_x"]), float(job_data["origin_z"]),
        float(job_data["width_m"]), float(job_data["depth_m"]),
        int(job_data["voxel_lod"])
    )
    if _is_cancelled():
        return
    result = {
        "kind": "plants",
        "mesh_data": mesh_data,
        "reservations": reservations
    }


func _is_sand(world_x: float, world_z: float) -> bool:
    return _generator != null and _generator.is_sand_surface(world_x, world_z)


func _surface_info(world_x: float, world_z: float) -> Vector4:
    # Packed as (height, gradient_x, gradient_z, rock_weight) to avoid a Dictionary
    # allocation for every vegetation/rock placement probe.
    var sample: Vector3 = _generator.get_surface_sample(world_x, world_z)
    var gradient := Vector2(sample.y, sample.z)
    var slope: float = gradient.length()
    var rock_weight: float = _generator.get_surface_rock_weight(slope, world_x, world_z)
    return Vector4(sample.x, gradient.x, gradient.y, rock_weight)


func _can_reserve(
        local_x: float, local_z: float, radius: float,
        width_m: float, depth_m: float, reservations: Array[Dictionary]) -> bool:
    const EDGE_MARGIN_M: float = 0.25
    if local_x - radius < EDGE_MARGIN_M or local_z - radius < EDGE_MARGIN_M:
        return false
    if local_x + radius > width_m - EDGE_MARGIN_M or local_z + radius > depth_m - EDGE_MARGIN_M:
        return false

    var candidate := Vector2(local_x, local_z)
    var cell_x: int = floori(local_x / RESERVATION_CELL_SIZE)
    var cell_z: int = floori(local_z / RESERVATION_CELL_SIZE)
    var search_cells: int = ceili((radius + MAX_RESERVATION_RADIUS + 0.16) / RESERVATION_CELL_SIZE)
    for dz in range(-search_cells, search_cells + 1):
        for dx in range(-search_cells, search_cells + 1):
            var bucket: Array = _reservation_cells.get(Vector2i(cell_x + dx, cell_z + dz), [])
            for reservation_index in bucket:
                var occupied: Dictionary = reservations[int(reservation_index)]
                var existing_position: Vector2 = occupied["p"]
                var min_distance: float = radius + float(occupied["r"]) + 0.16
                if candidate.distance_squared_to(existing_position) < min_distance * min_distance:
                    return false
    return true


func _rebuild_reservation_index(reservations: Array[Dictionary]) -> void:
    for index in range(reservations.size()):
        var occupied: Dictionary = reservations[index]
        var position: Vector2 = occupied["p"]
        var cell := Vector2i(
            floori(position.x / RESERVATION_CELL_SIZE),
            floori(position.y / RESERVATION_CELL_SIZE)
        )
        var bucket: Array = _reservation_cells.get(cell, [])
        bucket.append(index)
        _reservation_cells[cell] = bucket


func _reserve(local_x: float, local_z: float, radius: float, reservations: Array[Dictionary]) -> void:
    var index: int = reservations.size()
    reservations.append({"p": Vector2(local_x, local_z), "r": radius})
    var cell := Vector2i(
        floori(local_x / RESERVATION_CELL_SIZE),
        floori(local_z / RESERVATION_CELL_SIZE)
    )
    var bucket: Array = _reservation_cells.get(cell, [])
    bucket.append(index)
    _reservation_cells[cell] = bucket


func _make_object_grid(width: int, height: int, depth: int, palette_data: Dictionary):
    var grid = GridScript.new(maxi(4, width), maxi(4, height), maxi(4, depth))
    var shared_palette = palette_data["grid"]
    grid.palette = shared_palette.palette
    grid.ramp_lo = shared_palette.ramp_lo
    grid.ramp_hi = shared_palette.ramp_hi
    return grid


func _append_transformed_mesh(destination, source, basis: Basis, origin: Vector3) -> void:
    if _is_cancelled() or source.verts.is_empty():
        return
    var first_index: int = destination.verts.size()
    for i in range(source.verts.size()):
        if (i & 255) == 0 and _is_cancelled():
            return
        destination.verts.append(origin + basis * source.verts[i])
        destination.normals.append((basis * source.normals[i]).normalized())
        destination.colors.append(source.colors[i])
        destination.uv2s.append(
            source.uv2s[i] if source.uv2s.size() == source.verts.size() else Vector2.ZERO
        )
    for index_index in range(source.indices.size()):
        if (index_index & 1023) == 0 and _is_cancelled():
            return
        var index_value: int = source.indices[index_index]
        destination.indices.append(first_index + int(index_value))


func _make_noise(noise_seed: int, frequency: float) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = noise_seed
    noise.frequency = frequency
    return noise


func _near_spawn(world_x: float, world_z: float) -> bool:
    return world_x * world_x + world_z * world_z < 16.0


static func _mix(a: int, b: int, c: int) -> int:
    var hash_value: int = a * 374761393 + b * 668265263 + c * 1442695041 + 1013904223
    hash_value = (hash_value ^ (hash_value >> 13)) * 1274126177
    hash_value = hash_value ^ (hash_value >> 16)
    return hash_value & 0x7fffffff
