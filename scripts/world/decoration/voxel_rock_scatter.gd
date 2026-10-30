extends RefCounted
class_name VoxelRockScatter

## Ground stones and boulders. Distant props use coarser voxel grids and fewer surface details.
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const PROP_VOXEL_SIZE: float = 0.1

func build_tile(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, prop_lod: int, distance_m: float,
        collision_output: Array, build_collisions: bool) -> void:
    var count: int = rng.randi_range(3, 6) if distance_m <= 240.0 else rng.randi_range(1, 2)
    if prop_lod >= 2:
        count = rng.randi_range(1, 2)
    var stone_noise: FastNoiseLite = host._make_noise(host._mix(tile_seed, 19, 53), 0.022)
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
        var surface: Vector4 = host._surface_info(world_x, world_z)
        var rock_weight: float = surface.w
        if rock_weight < 0.18 and rng.randf() > 0.28:
            continue
        if distance_m > 240.0 and rock_weight < 0.38:
            continue

        var radius_units: float
        match prop_lod:
            0:
                radius_units = lerpf(2.5, 14.0, pow(rng.randf(), 2.5))
            1:
                radius_units = lerpf(5.0, 16.0, pow(rng.randf(), 1.8))
            2:
                radius_units = lerpf(8.0, 20.0, pow(rng.randf(), 1.2))
            _:
                radius_units = lerpf(12.0, 22.0, pow(rng.randf(), 1.2))
        var radius_m: float = radius_units * PROP_VOXEL_SIZE
        var exclusion_radius: float = maxf(0.42, radius_m * 1.45)
        if not host._can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
            continue

        var rock_seed: int = rng.randi()
        # Keep 10 cm voxels for rocks at every LOD. Distant tiers use fewer/smaller
        # shapes and lower surface noise instead of enlarging individual rock voxels.
        var grid = make_rock_grid(host, radius_units, palette_data, rock_seed, prop_lod)
        var mesh_grid = grid
        var safe_prop_lod: int = clampi(prop_lod, 0, 3)
        for _lod_step in range(safe_prop_lod):
            mesh_grid = mesh_grid.downsampled()
        var rock_piece = MeshDataScript.new()
        var rock_voxel_size: float = PROP_VOXEL_SIZE * float(1 << safe_prop_lod)
        mesh_grid.emit(rock_piece, Vector3.ZERO, rock_voxel_size, rock_seed)

        # Orient the base plane to the terrain normal so the rock rests on the slope
        # instead of intersecting it with a world-axis-aligned side.
        var surface_normal := Vector3(
            -surface.y, 1.0, -surface.z
        ).normalized()
        var yaw: float = rng.randf_range(0.0, TAU)
        var local_x_axis := Vector3(cos(yaw), 0.0, sin(yaw))
        local_x_axis = (local_x_axis - surface_normal * local_x_axis.dot(surface_normal)).normalized()
        if local_x_axis.length_squared() < 0.001:
            var fallback_axis: Vector3 = Vector3.RIGHT
            if absf(surface_normal.dot(fallback_axis)) > 0.95:
                fallback_axis = Vector3.FORWARD
            local_x_axis = (fallback_axis - surface_normal * fallback_axis.dot(surface_normal)).normalized()
        var local_z_axis: Vector3 = local_x_axis.cross(surface_normal).normalized()
        var rock_basis := Basis(local_x_axis, surface_normal, local_z_axis)
        var base_position := Vector3(local_x, surface.x - 0.06, local_z)
        host._append_transformed_mesh(output, rock_piece, rock_basis, base_position)

        if radius_m >= 0.5 and build_collisions:
            collision_output.append({
                "position": base_position,
                "basis": rock_basis,
                "radius_m": radius_m
            })
        host._reserve(local_x, local_z, exclusion_radius, reservations)

func make_rock_grid(
        host, radius: float, palette_data: Dictionary, rock_seed: int, quality_lod: int = 0):
    var width: int = ceili(radius * 3.6) + 6
    var height: int = ceili(radius * 1.75) + 6
    var grid = host._make_object_grid(width, height, width, palette_data)
    _fill_rock(host, grid, rock_seed, radius, palette_data["rock_ramps"], quality_lod)
    return grid

func _fill_rock(
        host, grid, seed_value: int, radius: float, rock_ramps: PackedInt32Array,
        quality_lod: int) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value
    var noise: FastNoiseLite = host._make_noise(seed_value, 0.2)
    var quality: int = clampi(quality_lod, 0, 3)
    var detail_scale: float = [1.0, 0.82, 0.62, 0.45][quality]
    var noise_amplitude: float = [0.28, 0.21, 0.14, 0.08][quality]
    var colour_jitter: float = [0.15, 0.10, 0.06, 0.03][quality]
    var palette_pick: bool = rng.randf() < 0.5
    var gray_start: int = int(rock_ramps[0] if palette_pick else rock_ramps[2])
    var gray_count: int = int(rock_ramps[1] if palette_pick else rock_ramps[3])
    var moss: bool = rng.randf() < [0.45, 0.35, 0.25, 0.16][quality]
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
                var noise_value: float = noise.get_noise_3d(float(xx) * detail_scale, float(y) * detail_scale, float(zz) * detail_scale)
                var distance_value: float = pow(shape_value, 1.0 / 2.4) + noise_value * noise_amplitude
                if distance_value > 1.0:
                    continue
                var tone: float = 0.5 + ny * 0.35 + noise_value * 0.35 + rng.randf_range(-colour_jitter, colour_jitter)
                var index: int = gray_start + clampi(int(tone * gray_count), 0, gray_count - 1)
                if moss and ny > 0.25 and noise_value > -0.05:
                    index = int(rock_ramps[4]) + rng.randi_range(0, int(rock_ramps[5]) - 1)
                grid.put(xx, y, zz, index)
