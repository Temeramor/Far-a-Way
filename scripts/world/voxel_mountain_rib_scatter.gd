extends RefCounted
class_name VoxelMountainRibScatter

## Builds long mountain ribs from world-axis-aligned voxel cells, following the sampled slope.
## Cell size matches the active terrain LOD. The lower rows are embedded into the hillside.
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const MAX_SIDE_LENGTH_M: float = 64.0
const TRACE_STEP_M: float = 0.75
const DIRS: Array[Vector3i] = [
    Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0), Vector3i(0, -1, 0),
    Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]
const NORMALS: Array[Vector3] = [
    Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD
]
const CORNERS: Array = [
    [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
    [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)],
    [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
    [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
    [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)],
    [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]
]

func build_tile(
        host, output, collision_body: StaticBody3D,
        reservations: Array[Dictionary], palette_data: Dictionary, rng: RandomNumberGenerator,
        tile_seed: int, origin_x: float, origin_z: float, width_m: float, depth_m: float,
        terrain_lod: int, tile_distance_m: float) -> void:
    # These ribs can span several tiles along a whole slope, so only a controlled
    # subset of eligible tiles may start one. The tile hash keeps placement deterministic.
    var rib_probability: float = 0.24 if terrain_lod == 0 and tile_distance_m <= 240.0 else 0.10
    var rib_roll: float = float(host._mix(tile_seed, 811, 271) % 1000) / 1000.0
    if rib_roll >= rib_probability:
        return

    var probes: int = 3 if terrain_lod == 0 and tile_distance_m <= 240.0 else 2
    for _probe in range(probes):
        var local_x: float = rng.randf_range(2.5, maxf(2.6, width_m - 2.5))
        var local_z: float = rng.randf_range(2.5, maxf(2.6, depth_m - 2.5))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        var surface: Dictionary = host._surface_info(world_x, world_z)
        if float(surface["rock_weight"]) < 0.58 or float(surface["slope"]) < 0.66:
            continue
        var blocked: bool = false
        for occupied in reservations:
            var p: Vector2 = occupied["p"]
            var required: float = 2.2 + float(occupied["r"]) + 0.16
            if Vector2(local_x, local_z).distance_squared_to(p) < required * required:
                blocked = true
                break
        if blocked:
            continue
        if _try_add_rib(
                host, output, collision_body, reservations, palette_data, rng, tile_seed,
                world_x, world_z, origin_x, origin_z, terrain_lod,
                Vector2(float(surface["gradient_x"]), float(surface["gradient_z"]))
        ):
            break

func _try_add_rib(
        host, output, collision_body: StaticBody3D, reservations: Array[Dictionary],
        palette_data: Dictionary, rng: RandomNumberGenerator, tile_seed: int,
        world_x: float, world_z: float, origin_x: float, origin_z: float,
        terrain_lod: int, gradient: Vector2) -> bool:
    var terrain_voxel: float = VoxelWorld.VOXEL_SIZE * float(1 << clampi(terrain_lod, 0, 3))
    if gradient.length_squared() < 0.01:
        return false
    var initial_direction: Vector2 = gradient.normalized()
    var centre := Vector2(world_x, world_z)
    var downhill: Array[Vector2] = _trace_side(host, centre, initial_direction, -1.0)
    var uphill: Array[Vector2] = _trace_side(host, centre, initial_direction, 1.0)
    downhill.reverse()
    var path: Array[Vector2] = downhill
    for point in uphill:
        if path.is_empty() or path[path.size() - 1].distance_to(point) > 0.01:
            path.append(point)
    if path.size() < 8:
        return false

    var noise := host._make_noise(host._mix(tile_seed, int(world_x * 10.0), int(world_z * 10.0)), 0.09)
    var rock_ramps: PackedInt32Array = palette_data["rock_ramps"]
    var palette: PackedColorArray = palette_data["grid"].palette
    var cells: Dictionary = {}
    var reserve_distance: float = 0.0
    for segment_index in range(path.size() - 1):
        var a: Vector2 = path[segment_index]
        var b: Vector2 = path[segment_index + 1]
        var delta: Vector2 = b - a
        var segment_length: float = delta.length()
        if segment_length <= 0.001:
            continue
        var tangent: Vector2 = delta / segment_length
        var across := Vector2(-tangent.y, tangent.x)
        var sample_count: int = maxi(1, ceili(segment_length / terrain_voxel))
        for sample_index in range(sample_count):
            var point: Vector2 = a.lerp(b, float(sample_index) / float(sample_count))
            var width_noise: float = noise.get_noise_2d(point.x * 0.45, point.y * 0.45)
            var half_width_cells: int = clampi(2 + int((width_noise + 1.0) * 1.7), 2, 5)
            if reserve_distance >= 3.0:
                reservations.append({"p": Vector2(point.x - origin_x, point.y - origin_z), "r": 0.85})
                reserve_distance = 0.0
            reserve_distance += terrain_voxel
            for across_index in range(-half_width_cells, half_width_cells + 1):
                var offset_point: Vector2 = point + across * float(across_index) * terrain_voxel
                var surface_y: float = host._world.get_surface_height(offset_point.x, offset_point.y)
                var surface_cell_y: int = floori(surface_y / terrain_voxel)
                var top_noise: float = noise.get_noise_2d(offset_point.x * 0.8 + 100.0, offset_point.y * 0.8 - 80.0)
                var protrusion_cells: int = clampi(2 + int((top_noise + 1.0) * 1.7), 2, 5)
                var base_cell_y: int = surface_cell_y - 2
                var cell_x: int = floori(offset_point.x / terrain_voxel)
                var cell_z: int = floori(offset_point.y / terrain_voxel)
                var tone: float = 0.5 + noise.get_noise_2d(offset_point.x * 0.22, offset_point.y * 0.22) * 0.32
                var use_moss: bool = top_noise > 0.54 and rng.randf() < 0.35
                var use_first_ramp: bool = rng.randf() < 0.5
                var ramp_start: int = int(rock_ramps[0] if use_first_ramp else rock_ramps[2])
                var ramp_count: int = int(rock_ramps[1] if use_first_ramp else rock_ramps[3])
                var color_index: int = ramp_start + clampi(int(tone * float(ramp_count)), 0, ramp_count - 1)
                if use_moss:
                    color_index = int(rock_ramps[4]) + rng.randi_range(0, int(rock_ramps[5]) - 1)
                for height_step in range(protrusion_cells + 2):
                    cells[Vector3i(cell_x, base_cell_y + height_step, cell_z)] = color_index

    if cells.is_empty():
        return false
    var rib_data = build_aligned_rib_mesh(cells, palette, terrain_voxel, origin_x, origin_z)
    if rib_data.verts.is_empty():
        return false
    host._append_transformed_mesh(output, rib_data, Basis.IDENTITY, Vector3.ZERO)
    if collision_body != null:
        var collision_faces := PackedVector3Array()
        for index_value in rib_data.indices:
            collision_faces.append(rib_data.verts[int(index_value)])
        if not collision_faces.is_empty():
            var concave := ConcavePolygonShape3D.new()
            concave.set_faces(collision_faces)
            var collision := CollisionShape3D.new()
            collision.name = "MountainRibCollision"
            collision.shape = concave
            collision_body.add_child(collision)
    return true

func build_aligned_rib_mesh(
        cells: Dictionary, palette: PackedColorArray, terrain_voxel: float,
        origin_x: float, origin_z: float) -> MeshData:
    var rib_data = MeshDataScript.new()
    for cell_value in cells.keys():
        var cell: Vector3i = cell_value
        var color_index: int = int(cells[cell])
        if color_index < 0 or color_index >= palette.size():
            continue
        var base := Vector3(
            float(cell.x) * terrain_voxel - origin_x,
            float(cell.y) * terrain_voxel,
            float(cell.z) * terrain_voxel - origin_z
        )
        for face in range(6):
            if cells.has(cell + DIRS[face]):
                continue
            var corners: Array = CORNERS[face]
            rib_data.quad(
                base + corners[0] * terrain_voxel, base + corners[1] * terrain_voxel,
                base + corners[2] * terrain_voxel, base + corners[3] * terrain_voxel,
                NORMALS[face], palette[color_index]
            )
    return rib_data

func _trace_side(host, start: Vector2, initial_direction: Vector2, sign_value: float) -> Array[Vector2]:
    var result: Array[Vector2] = [start]
    var current: Vector2 = start
    var direction: Vector2 = initial_direction * sign_value
    var travelled: float = 0.0
    var step: float = maxf(TRACE_STEP_M, 0.5)
    while travelled < MAX_SIDE_LENGTH_M:
        var next_point: Vector2 = current + direction * step
        var half_world: float = host._world.world_size_m * 0.5
        if absf(next_point.x) > half_world or absf(next_point.y) > half_world:
            break
        var surface: Dictionary = host._surface_info(next_point.x, next_point.y)
        var local_gradient := Vector2(float(surface["gradient_x"]), float(surface["gradient_z"]))
        if local_gradient.length_squared() > 0.04:
            var target_direction: Vector2 = local_gradient.normalized() * sign_value
            direction = (direction * 0.45 + target_direction * 0.55).normalized()
        current = next_point
        result.append(current)
        travelled += step
        if result.size() > 5:
            var rock_weight: float = float(surface["rock_weight"])
            var slope: float = float(surface["slope"])
            if rock_weight < 0.18 and slope < 0.42:
                break
            if sign_value > 0.0 and slope < 0.28:
                break
    return result
