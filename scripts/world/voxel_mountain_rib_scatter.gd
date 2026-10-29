extends RefCounted
class_name VoxelMountainRibScatter

## Creates low-poly vertical cliff objects along steep terrain contours.
## These are short, layered rock walls embedded into the downhill face, not slope-following ribs.
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const MAX_TRACE_SIDE_M: float = 12.0
const MIN_WALL_POINTS: int = 8


func build_tile(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, terrain_lod: int, tile_distance_m: float,
        collision_output: Array, build_collisions: bool) -> void:
    if terrain_lod > 3:
        return

    var probability: float = 0.18 if terrain_lod == 0 and tile_distance_m <= 240.0 else 0.10
    if terrain_lod == 1:
        probability = 0.075
    elif terrain_lod == 2:
        probability = 0.045
    elif terrain_lod == 3:
        probability = 0.025
    var roll: float = float(host._mix(tile_seed, 811, 271) % 1000) / 1000.0
    if roll >= probability:
        return

    var probes: int = 3 if terrain_lod == 0 and tile_distance_m <= 240.0 else 2
    for _probe in range(probes):
        var local_x: float = rng.randf_range(3.0, maxf(3.1, width_m - 3.0))
        var local_z: float = rng.randf_range(3.0, maxf(3.1, depth_m - 3.0))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        var surface: Dictionary = host._surface_info(world_x, world_z)
        if float(surface["rock_weight"]) < 0.58 or float(surface["slope"]) < 0.66:
            continue

        var blocked := false
        for occupied in reservations:
            var p: Vector2 = occupied["p"]
            var required: float = 2.0 + float(occupied["r"]) + 0.16
            if Vector2(local_x, local_z).distance_squared_to(p) < required * required:
                blocked = true
                break
        if blocked:
            continue

        if _try_add_cliff(
                host, output, collision_output, reservations, palette_data,
                rng, tile_seed, world_x, world_z, origin_x, origin_z, width_m, depth_m,
                terrain_lod, Vector2(float(surface["gradient_x"]), float(surface["gradient_z"])),
                build_collisions
        ):
            return


func _try_add_cliff(
        host, output, collision_output: Array, reservations: Array[Dictionary],
        palette_data: Dictionary, _rng: RandomNumberGenerator,
        tile_seed: int, world_x: float, world_z: float, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, terrain_lod: int, gradient: Vector2,
        build_collisions: bool) -> bool:
    if gradient.length_squared() < 0.44:
        return false

    # The contour tangent is perpendicular to the height gradient. This makes the wall
    # read as a cross-section of a real escarpment instead of a strip crawling uphill.
    var tangent := Vector2(-gradient.y, gradient.x).normalized()
    var centre := Vector2(world_x, world_z)
    var trace_steps: Array[float] = [0.75, 1.05, 1.5, 2.1]
    var trace_step: float = trace_steps[clampi(terrain_lod, 0, trace_steps.size() - 1)]
    var negative_path := _trace_contour(
        host, centre, tangent, -1.0, origin_x, origin_z, width_m, depth_m, trace_step
    )
    var positive_path := _trace_contour(
        host, centre, tangent, 1.0, origin_x, origin_z, width_m, depth_m, trace_step
    )
    negative_path.reverse()
    var path: Array[Vector2] = negative_path
    for point in positive_path:
        if path.is_empty() or path[path.size() - 1].distance_to(point) > 0.01:
            path.append(point)
    if path.size() < MIN_WALL_POINTS:
        return false

    var cliff_seed: int = host._mix(tile_seed, int(world_x * 10.0), int(world_z * 10.0))
    var shape_noise: FastNoiseLite = host._make_noise(cliff_seed, 0.075)
    var rock_ramps: PackedInt32Array = palette_data["rock_ramps"]
    var palette: PackedColorArray = palette_data["grid"].palette
    var wall_data: MeshData = _build_cliff_mesh(
        host, path, shape_noise, palette, rock_ramps, origin_x, origin_z
    )
    if wall_data.verts.is_empty():
        return false

    host._append_transformed_mesh(output, wall_data, Basis.IDENTITY, Vector3.ZERO)

    # Leave a sparse exclusion line so boulders don't hide the cliff's lower edge.
    var last_reserved: Vector2 = Vector2(-100000.0, -100000.0)
    for point in path:
        var local_point := Vector2(point.x - origin_x, point.y - origin_z)
        if local_point.distance_to(last_reserved) >= 2.8:
            reservations.append({"p": local_point, "r": 1.15})
            last_reserved = local_point

    if build_collisions:
        collision_output.append({
            "kind": "cliff",
            "position": Vector3.ZERO,
            "points": wall_data.verts
        })
    return true


func _trace_contour(
        host, start: Vector2, initial_tangent: Vector2, sign_value: float,
        origin_x: float, origin_z: float, width_m: float, depth_m: float,
        trace_step: float) -> Array[Vector2]:
    var result: Array[Vector2] = [start]
    var current: Vector2 = start
    var direction: Vector2 = initial_tangent * sign_value
    var travelled: float = 0.0

    while travelled < MAX_TRACE_SIDE_M:
        var next_point: Vector2 = current + direction * trace_step
        # Keep each object inside its owning tile to avoid duplicated cliff strips at seams.
        if next_point.x < origin_x + 1.2 or next_point.x > origin_x + width_m - 1.2:
            break
        if next_point.y < origin_z + 1.2 or next_point.y > origin_z + depth_m - 1.2:
            break

        var surface: Dictionary = host._surface_info(next_point.x, next_point.y)
        var local_gradient := Vector2(float(surface["gradient_x"]), float(surface["gradient_z"]))
        if local_gradient.length_squared() < 0.025:
            break
        if result.size() >= 4 and (
                float(surface["rock_weight"]) < 0.35 or float(surface["slope"]) < 0.43):
            break

        var target_tangent := Vector2(-local_gradient.y, local_gradient.x).normalized()
        if target_tangent.dot(direction) < 0.0:
            target_tangent = -target_tangent
        direction = (direction * 0.42 + target_tangent * 0.58).normalized()
        current = next_point
        result.append(current)
        travelled += trace_step
    return result


func _build_cliff_mesh(
        host, path: Array[Vector2], noise: FastNoiseLite, palette: PackedColorArray,
        rock_ramps: PackedInt32Array, origin_x: float, origin_z: float) -> MeshData:
    var data: MeshData = MeshDataScript.new()
    if path.size() < 2:
        return data

    var station_count: int = path.size()
    var front_levels: Array = []
    var back_levels: Array = []
    for _layer in range(4):
        front_levels.append([])
        back_levels.append([])

    var layer_fractions: Array[float] = [0.0, 0.38, 0.74, 1.0]
    var upslope_vectors: Array[Vector2] = []

    for i in range(station_count):
        var prev: Vector2 = path[maxi(0, i - 1)]
        var next: Vector2 = path[mini(station_count - 1, i + 1)]
        var tangent: Vector2 = (next - prev).normalized()
        var sample: Dictionary = host._surface_info(path[i].x, path[i].y)
        var gradient := Vector2(float(sample["gradient_x"]), float(sample["gradient_z"]))
        var upslope: Vector2 = gradient.normalized() if gradient.length_squared() > 0.001 else Vector2(-tangent.y, tangent.x)
        upslope_vectors.append(upslope)

        var front_xz: Vector2 = path[i] - upslope * 0.55
        var front_surface: Dictionary = host._surface_info(front_xz.x, front_xz.y)
        var base_y: float = float(front_surface["height"]) - 0.18
        var height_noise: float = noise.get_noise_2d(path[i].x * 0.36, path[i].y * 0.36)
        var edge_noise: float = noise.get_noise_2d(path[i].x * 0.83 + 37.0, path[i].y * 0.83 - 19.0)
        var wall_height: float = clampf(8.2 + height_noise * 3.6 + edge_noise * 1.8, 4.0, 14.0)
        var thickness: float = clampf(1.3 + noise.get_noise_2d(path[i].x * 0.54 - 12.0, path[i].y * 0.54 + 8.0) * 0.65, 0.65, 2.0)

        for layer in range(4):
            var fraction: float = layer_fractions[layer]
            var rough_y: float = noise.get_noise_2d(path[i].x * 0.65 + float(layer) * 7.1, path[i].y * 0.65) * 0.30
            var ledge_shift: float = noise.get_noise_2d(path[i].x * 0.42, path[i].y * 0.42 + float(layer) * 11.0) * 0.16
            var level_position := Vector2(
                front_xz.x + upslope.x * ledge_shift - origin_x,
                front_xz.y + upslope.y * ledge_shift - origin_z
            )
            var y: float = base_y + wall_height * fraction + rough_y
            var front_vertex := Vector3(level_position.x, y, level_position.y)
            var back_vertex := front_vertex + Vector3(upslope.x * thickness, 0.0, upslope.y * thickness)
            front_levels[layer].append(front_vertex)
            back_levels[layer].append(back_vertex)

    for i in range(station_count):
        var up: Vector2 = upslope_vectors[i]
        var outward := Vector2(-up.x, -up.y)
        var front_normal := Vector3(outward.x, 0.0, outward.y).normalized()

        if i < station_count - 1:
            var next_tangent: Vector2 = (path[i + 1] - path[i]).normalized()
            var face_normal := Vector3(-next_tangent.y, 0.0, next_tangent.x).normalized()
            if face_normal.dot(front_normal) < 0.0:
                face_normal = -face_normal
            for layer in range(3):
                var use_ramp: int = int(rock_ramps[0] if layer != 1 else rock_ramps[2])
                var ramp_count: int = int(rock_ramps[1] if layer != 1 else rock_ramps[3])
                var tone: float = clampf(0.50 + noise.get_noise_2d(float(i) * 0.63, float(layer) * 2.1) * 0.24, 0.0, 0.999)
                var color_index: int = use_ramp + clampi(int(tone * float(ramp_count)), 0, ramp_count - 1)
                var rock_color: Color = palette[color_index] * Color(0.72, 0.76, 0.80, 1.0)
                data.quad(
                    front_levels[layer][i], front_levels[layer][i + 1],
                    front_levels[layer + 1][i + 1], front_levels[layer + 1][i],
                    face_normal, rock_color
                )
                data.quad(
                    back_levels[layer][i + 1], back_levels[layer][i],
                    back_levels[layer + 1][i], back_levels[layer + 1][i + 1],
                    -face_normal, rock_color * Color(0.82, 0.84, 0.86, 1.0)
                )

            var top_color: Color = palette[int(rock_ramps[2]) + int(rock_ramps[3]) - 1] * Color(0.72, 0.76, 0.80, 1.0)
            data.quad(
                front_levels[3][i], front_levels[3][i + 1],
                back_levels[3][i + 1], back_levels[3][i],
                Vector3.UP, top_color
            )

    # Close both ends so each formation is a solid rock object, not an open ribbon.
    for end_index in [0, station_count - 1]:
        var base_front: Vector3 = front_levels[0][end_index]
        var top_front: Vector3 = front_levels[3][end_index]
        var base_back: Vector3 = back_levels[0][end_index]
        var top_back: Vector3 = back_levels[3][end_index]
        var end_normal: Vector3
        if end_index == 0:
            end_normal = (Vector3(path[1].y - path[0].y, 0.0, path[0].x - path[1].x)).normalized()
        else:
            end_normal = (Vector3(path[station_count - 1].y - path[station_count - 2].y, 0.0, path[station_count - 2].x - path[station_count - 1].x)).normalized()
        var end_color: Color = palette[int(rock_ramps[0]) + floori(float(int(rock_ramps[1])) * 0.5)] * Color(0.70, 0.74, 0.78, 1.0)
        data.quad(base_front, base_back, top_back, top_front, end_normal, end_color)

    return data
