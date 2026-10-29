extends RefCounted
class_name VoxelRockScatter

## Ground stones and boulders. Source voxel grids are downsampled for prop LODs 1-3.
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const PROP_VOXEL_SIZE: float = 0.1

func build_tile(
        host: Node, output, collision_body: StaticBody3D,
        reservations: Array[Dictionary], palette_data: Dictionary, rng: RandomNumberGenerator,
        tile_seed: int, origin_x: float, origin_z: float, width_m: float, depth_m: float,
        prop_lod: int, distance_m: float) -> void:
    var count: int = rng.randi_range(3, 6) if distance_m <= 240.0 else rng.randi_range(1, 2)
    if prop_lod >= 2:
        count = rng.randi_range(1, 2)
    var stone_noise := host._make_noise(host._mix(tile_seed, 19, 53), 0.022)
    var noise_pick: float = stone_noise.get_noise_2d(
        origin_x + width_m * 0.5, origin_z + depth_m * 0.5
    ) * 0.5 + 0.5
    if distance_m <= 240.0 and noise_pick > 0.5:
        count += int((noise_pick - 0.5) * 6.0)

    for i in range(count):
        var local_x: float = rng.randf_range(1.6, maxf(1.7, width_m - 1.6))
        var local_z: float = rng.randf_range(1.6, maxf(1.7, depth_m - 1.6))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        if host._near_spawn(world_x, world_z):
            continue
        var surface: Dictionary = host._surface_info(world_x, world_z)
        var rock_weight: float = float(surface["rock_weight"])
        if rock_weight < 0.18 and rng.randf() > 0.28:
            continue
        if distance_m > 240.0 and rock_weight < 0.38:
            continue

        var radius_units: float
        match prop_lod:
            0:
                radius_units = lerpf(2.5, 14.0, pow(rng.randf(), 2.5))
            1:
                radius_units = lerpf(5.0, 18.0, pow(rng.randf(), 1.8))
            2:
                radius_units = lerpf(12.0, 30.0, pow(rng.randf(), 1.2))
            _:
                radius_units = lerpf(20.0, 44.0, pow(rng.randf(), 1.2))
        var radius_m: float = radius_units * PROP_VOXEL_SIZE
        var exclusion_radius: float = maxf(0.42, radius_m * 1.45)
        if not host._can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
            continue

        var rock_seed: int = rng.randi()
        var grid = make_rock_grid(host, radius_units, palette_data, rock_seed)
        for _lod_step in range(clampi(prop_lod, 0, 3)):
            grid = grid.downsampled()
        var rock_piece = MeshDataScript.new()
        grid.emit(rock_piece, Vector3.ZERO, PROP_VOXEL_SIZE * float(1 << prop_lod), rock_seed)
        host._append_transformed_mesh(
            output, rock_piece, Basis.IDENTITY,
            Vector3(local_x, float(surface["height"]) - 0.06, local_z)
        )
        if collision_body != null and radius_m >= 0.5:
            _add_boulder_collision(collision_body, local_x, local_z, float(surface["height"]), radius_m)
        reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})

func _add_boulder_collision(
        collision_body: StaticBody3D, local_x: float, local_z: float, surface_y: float, radius_m: float) -> void:
    var collision_shape := BoxShape3D.new()
    var height: float = maxf(0.35, radius_m * 1.20)
    collision_shape.size = Vector3(radius_m * 2.5, height, radius_m * 2.5)
    var collision := CollisionShape3D.new()
    collision.name = "BoulderCollision"
    collision.shape = collision_shape
    collision.position = Vector3(local_x, surface_y - 0.06 + height * 0.5, local_z)
    collision_body.add_child(collision)

func make_rock_grid(host: Node, radius: float, palette_data: Dictionary, rock_seed: int):
    var width: int = ceili(radius * 3.6) + 6
    var height: int = ceili(radius * 1.75) + 6
    var grid = host._make_object_grid(width, height, width, palette_data)
    _fill_rock(host, grid, rock_seed, radius, palette_data["rock_ramps"])
    return grid

func _fill_rock(host: Node, grid, seed_value: int, radius: float, rock_ramps: PackedInt32Array) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value
    var noise := host._make_noise(seed_value, 0.2)
    var palette_pick: bool = rng.randf() < 0.5
    var gray_start: int = int(rock_ramps[0] if palette_pick else rock_ramps[2])
    var gray_count: int = int(rock_ramps[1] if palette_pick else rock_ramps[3])
    var moss: bool = rng.randf() < 0.45
    var rx: float = radius * rng.randf_range(0.9, 1.3)
    var ry: float = radius * rng.randf_range(0.5, 0.85)
    var rz: float = radius * rng.randf_range(0.9, 1.3)
    var cy: float = ry * 0.45
    var ext: float = 1.3
    for y in range(0, mini(grid.h, ceili(cy + ry * ext) + 1)):
        var ny: float = (float(y) - cy) / ry
        for zz in range(-ceili(rz * ext), ceili(rz * ext) + 1):
            var nz: float = float(zz) / rz
            for xx in range(-ceili(rx * ext), ceili(rx * ext) + 1):
                var nx: float = float(xx) / rx
                var shape_value: float = pow(absf(nx), 2.4) + pow(absf(ny), 2.4) + pow(absf(nz), 2.4)
                if shape_value > 2.2:
                    continue
                var noise_value: float = noise.get_noise_3d(float(xx), float(y), float(zz))
                var distance_value: float = pow(shape_value, 1.0 / 2.4) + noise_value * 0.28
                if distance_value > 1.0:
                    continue
                var tone: float = 0.5 + ny * 0.35 + noise_value * 0.35 + rng.randf_range(-0.15, 0.15)
                var index: int = gray_start + clampi(int(tone * gray_count), 0, gray_count - 1)
                if moss and ny > 0.25 and noise_value > -0.05:
                    index = int(rock_ramps[4]) + rng.randi_range(0, int(rock_ramps[5]) - 1)
                grid.put(xx, y, zz, index)
