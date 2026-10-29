extends RefCounted
class_name VoxelVegetationScatter

## Voxel flowers and grass. Source grids are downsampled before meshing for coarse prop LODs.
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const PaletteScript = preload("res://scripts/vegetation/voxel_palette.gd")
const PROP_VOXEL_SIZE: float = 0.1
const GRASS_BLADE_COUNT: int = 120

func build_tile(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, voxel_lod: int) -> void:
    scatter_flowers(host, output, reservations, palette_data, rng, tile_seed,
        origin_x, origin_z, width_m, depth_m, voxel_lod)
    scatter_grass(host, output, reservations, palette_data, rng, tile_seed,
        origin_x, origin_z, width_m, depth_m, voxel_lod)

func _coarsen_grid(source_grid, voxel_lod: int):
    var grid = source_grid
    for _step in range(clampi(voxel_lod, 0, 1)):
        grid = grid.downsampled()
    return grid

func scatter_flowers(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, voxel_lod: int) -> void:
    var meadow := host._make_noise(host._mix(tile_seed, 37, 0), 0.035)
    var meadow_pick: float = meadow.get_noise_2d(origin_x + width_m * 0.5, origin_z + depth_m * 0.5) * 0.5 + 0.5
    var patch_count: int = rng.randi_range(3, 6) if voxel_lod == 0 else rng.randi_range(1, 2)
    if meadow_pick > 0.55:
        patch_count += 2 if voxel_lod == 0 else 1
    var flower_set: Array = palette_data["flower_set"]
    var flower_index: int = 0

    for patch_index in range(patch_count):
        var center_x: float = rng.randf_range(3.0, maxf(3.1, width_m - 3.0))
        var center_z: float = rng.randf_range(3.0, maxf(3.1, depth_m - 3.0))
        var flower_a: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        var flower_b: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        var count: int = rng.randi_range(8, 24) if voxel_lod == 0 else rng.randi_range(3, 7)
        var sigma: float = rng.randf_range(1.3, 2.8)
        for j in range(count):
            var local_x: float = center_x + rng.randfn(0.0, sigma)
            var local_z: float = center_z + rng.randfn(0.0, sigma)
            var flower: Dictionary = flower_a if rng.randf() < 0.75 else flower_b
            _try_add_flower(host, output, reservations, palette_data, rng, flower, local_x, local_z,
                origin_x, origin_z, width_m, depth_m, flower_index, voxel_lod)
            flower_index += 1

    for single_index in range(10 if voxel_lod == 0 else 2):
        var local_x: float = rng.randf_range(1.0, maxf(1.1, width_m - 1.0))
        var local_z: float = rng.randf_range(1.0, maxf(1.1, depth_m - 1.0))
        var flower: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        _try_add_flower(host, output, reservations, palette_data, rng, flower, local_x, local_z,
            origin_x, origin_z, width_m, depth_m, flower_index, voxel_lod)
        flower_index += 1

func _try_add_flower(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, flower: Dictionary,
        local_x: float, local_z: float, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, index: int, voxel_lod: int) -> void:
    var exclusion_radius: float = 0.32
    if not host._can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
        return
    var world_x: float = origin_x + local_x
    var world_z: float = origin_z + local_z
    var surface: Dictionary = host._surface_info(world_x, world_z)
    if float(surface["rock_weight"]) > 0.17 or float(surface["slope"]) > 0.82:
        return

    var grid = host._make_object_grid(22, 20, 22, palette_data)
    _add_flower(
        grid, rng, flower,
        int(palette_data["stem_start"]), int(palette_data["stem_count"])
    )
    var piece = MeshDataScript.new()
    var flower_seed: int = host._mix(index + int(origin_x * 10.0), int(local_x * 100.0), int(local_z * 100.0))
    var mesh_grid = _coarsen_grid(grid, voxel_lod)
    mesh_grid.emit(piece, Vector3.ZERO, PROP_VOXEL_SIZE * float(1 << voxel_lod), flower_seed)
    host._append_transformed_mesh(
        output, piece, Basis.IDENTITY,
        Vector3(local_x, float(surface["height"]), local_z)
    )
    reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})

func scatter_grass(
        host, output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, voxel_lod: int) -> void:
    var meadow := host._make_noise(host._mix(tile_seed, 37, 0), 0.035)
    var ramps: Array = palette_data["grass_ramps"]
    var counts: Array = palette_data["grass_counts"]
    var target_clumps: int = GRASS_BLADE_COUNT if voxel_lod == 0 else 30
    for clump_index in range(target_clumps):
        var local_x: float = rng.randf_range(0.8, maxf(0.9, width_m - 0.8))
        var local_z: float = rng.randf_range(0.8, maxf(0.9, depth_m - 0.8))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        var surface: Dictionary = host._surface_info(world_x, world_z)
        if float(surface["rock_weight"]) > 0.24 or float(surface["slope"]) > 0.94:
            continue
        var meadow_detail: float = meadow.get_noise_2d(world_x, world_z)
        if meadow_detail < -0.35:
            continue

        var exclusion_radius: float = 0.42
        if not host._can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
            continue

        var selection: float = rng.randf()
        var ramp_index: int = 0
        if selection > 0.85:
            ramp_index = 2
        elif selection > 0.45:
            ramp_index = 1
        var ramp_start: int = int(ramps[ramp_index])
        var ramp_count: int = int(counts[ramp_index])
        var grid = host._make_object_grid(18, 12, 18, palette_data)
        var blades: int = rng.randi_range(3, 9)
        var height_max: int = rng.randi_range(3, 7)
        for blade_index in range(blades):
            var blade_x: int = roundi(rng.randfn(0.0, 2.2))
            var blade_z: int = roundi(rng.randfn(0.0, 2.2))
            var blade_height: int = rng.randi_range(2, height_max)
            _add_blade(grid, rng, blade_x, blade_z, blade_height, ramp_start, ramp_count)

        var piece = MeshDataScript.new()
        var grass_seed: int = host._mix(clump_index + int(origin_x * 10.0), int(local_x * 100.0), int(local_z * 100.0))
        var mesh_grid = _coarsen_grid(grid, voxel_lod)
        mesh_grid.emit(piece, Vector3.ZERO, PROP_VOXEL_SIZE * float(1 << voxel_lod), grass_seed)
        host._append_transformed_mesh(
            output, piece, Basis.IDENTITY,
            Vector3(local_x, float(surface["height"]), local_z)
        )
        reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})

func _make_flower_set(grid, rng: RandomNumberGenerator) -> Array:
    var definitions: Array = [
        [Color("d8322b"), Color("2b1a1a"), 0],
        [Color("4a6fd6"), Color("e8e0a0"), 0],
        [Color("f2f0ea"), Color("f0c020"), 1],
        [Color("f2c418"), Color("d89a10"), 2],
        [Color("e870a0"), Color("f5c0d0"), 3],
        [Color("8a5fc8"), Color("6a3fa8"), 4],
        [Color("f7e04a"), Color("e0b020"), 0],
        [Color("5a7fe0"), Color("3a5fc0"), 3]
    ]
    var result: Array = []
    for definition in definitions:
        var petals: PackedColorArray = PaletteScript.shades(definition[0], 3, rng, 0.01, 0.06, 0.08)
        var center: PackedColorArray = PaletteScript.shades(definition[1], 2, rng, 0.01, 0.05, 0.06)
        result.append({
            "ps": grid.add_ramp(petals),
            "pn": petals.size(),
            "cs": grid.add_ramp(center),
            "cn": center.size(),
            "shape": int(definition[2])
        })
    return result

func _add_flower(grid, rng: RandomNumberGenerator, flower: Dictionary, stem_start: int, stem_count: int) -> void:
    var shape: int = int(flower["shape"])
    var height: int = rng.randi_range(5, 10)
    if shape == 4:
        height = rng.randi_range(8, 13)
    for y in range(height):
        grid.put_empty(0, y, 0, stem_start + clampi(int(float(y) / float(height) * stem_count), 0, stem_count - 1))
    grid.put_empty(1 if rng.randf() < 0.5 else -1, 2, 0, stem_start + stem_count - 1)
    grid.put_empty(0, 3, 1 if rng.randf() < 0.5 else -1, stem_start + stem_count - 1)

    match shape:
        0:
            _put_flower_center(grid, rng, 0, height, 0, flower)
            _put_flower_petals(grid, rng, [[1, 0], [-1, 0], [0, 1], [0, -1]], height, flower)
        1:
            for dx in range(-1, 2):
                for dz in range(-1, 2):
                    if dx == 0 and dz == 0:
                        _put_flower_center(grid, rng, dx, height, dz, flower)
                    else:
                        _put_flower_petals(grid, rng, [[dx, dz]], height, flower)
        2:
            for dx in range(-1, 2):
                for dz in range(-1, 2):
                    _put_flower_petals(grid, rng, [[dx, dz]], height, flower)
            _put_flower_center(grid, rng, 0, height + 1, 0, flower)
            _put_flower_petals(grid, rng, [[1, 0], [-1, 0], [0, 1], [0, -1]], height + 1, flower)
        3:
            _put_flower_center(grid, rng, 0, height, 0, flower)
            var ring: Array = []
            for dx in range(-1, 2):
                for dz in range(-1, 2):
                    if dx != 0 or dz != 0:
                        ring.append([dx, dz])
            _put_flower_petals(grid, rng, ring, height + 1, flower)
            _put_flower_petals(grid, rng, [[1, 0], [-1, 0], [0, 1], [0, -1]], height + 2, flower)
        _:
            for y in range(height - 5, height + 1):
                _put_flower_petals(grid, rng, [[0, 0]], y, flower)
                if (y & 1) == 0:
                    _put_flower_petals(grid, rng, [[1, 0], [-1, 0]], y, flower)
                else:
                    _put_flower_petals(grid, rng, [[0, 1], [0, -1]], y, flower)
            _put_flower_center(grid, rng, 0, height + 1, 0, flower)

func _put_flower_petals(grid, rng: RandomNumberGenerator, coords: Array, y: int, flower: Dictionary) -> void:
    for offset in coords:
        grid.put_empty(int(offset[0]), y, int(offset[1]),
            int(flower["ps"]) + rng.randi_range(0, int(flower["pn"]) - 1))

func _put_flower_center(grid, rng: RandomNumberGenerator, x: int, y: int, z: int, flower: Dictionary) -> void:
    grid.put_empty(x, y, z,
        int(flower["cs"]) + rng.randi_range(0, int(flower["cn"]) - 1))

func _add_blade(grid, rng: RandomNumberGenerator, x: int, z: int, height: int, ramp_start: int, ramp_count: int) -> void:
    var lean: int = rng.randi_range(0, 3)
    for y in range(height):
        var t: float = float(y) / float(maxi(height - 1, 1))
        var index: int = ramp_start + clampi(int(t * ramp_count + rng.randf_range(-0.6, 0.6)), 0, ramp_count - 1)
        var blade_x: int = x
        var blade_z: int = z
        if height >= 4 and y >= height - 2:
            if lean == 2:
                blade_x += 1
            elif lean == 3:
                blade_z -= 1
        grid.put_empty(blade_x, y, blade_z, index)
