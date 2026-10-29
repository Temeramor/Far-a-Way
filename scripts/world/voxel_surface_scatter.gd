extends Node3D
class_name VoxelSurfaceScatter

## Streams voxel stones, grass tufts and wildflowers on top of the procedural terrain.
## The rock/plant voxel algorithms and palette/grid primitives are ported from
## Plant_Generator/scripts/{chunk_gen,plant_gen,vox_grid,voxel_palette,mesh_data}.gd.
## Tree generation is intentionally not included.

const GridScript = preload("res://scripts/vegetation/vox_grid.gd")
const PaletteScript = preload("res://scripts/vegetation/voxel_palette.gd")
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")

const PROP_VOXEL_SIZE: float = 0.1
const GRASS_BLADE_COUNT: int = 120
const MAX_ROCK_DISTANCE_M: float = 240.0
const PLANT_ADD_DISTANCE_M: float = 92.0
const PLANT_REMOVE_DISTANCE_M: float = 122.0
const MIN_STONE_EDGE_MARGIN_M: float = 0.25
const ROCK_MOSS_COLOR := Color("5e7b3a")
const STONE_COLOR_A := Color("8b8984")
const STONE_COLOR_B := Color("77706a")
const STEM_COLOR := Color("4c8a30")

var _world: VoxelWorld
var _material: StandardMaterial3D
var _entries: Dictionary = {}
var _refresh_accumulator: float = 0.0
var _generation_epoch: int = 0


func _ready() -> void:
    _world = get_parent() as VoxelWorld
    if _world == null:
        push_warning("VoxelSurfaceScatter: expected to be a child of VoxelWorld.")
        set_process(false)
        return
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.vertex_color_is_srgb = true
    _material.roughness = 1.0
    _material.metallic = 0.0
    if not _world.terrain_seed_changed.is_connected(_on_terrain_seed_changed):
        _world.terrain_seed_changed.connect(_on_terrain_seed_changed)


func _process(delta: float) -> void:
    if _world == null or not _world._world_started:
        return

    _refresh_accumulator += delta
    if _refresh_accumulator >= 0.18:
        _refresh_accumulator = 0.0
        _reconcile_entries()

    _build_one_pending_tile()


func _on_terrain_seed_changed(_new_seed: int) -> void:
    _generation_epoch += 1
    for entry in _entries.values():
        var root_node: Node3D = entry.get("root") as Node3D
        if root_node != null:
            root_node.queue_free()
    _entries.clear()


func _reconcile_entries() -> void:
    var desired: Dictionary = {}
    for coord_value in _world._wanted.keys():
        var coord: Vector2i = coord_value
        var parts: Dictionary = _world._decode_lod_key(coord)
        if int(parts["lod"]) != 0:
            continue

        var request: Dictionary = _world._wanted[coord]
        if bool(request.get("fallback", false)):
            continue
        var terrain_chunk: VoxelTerrainChunk = _world._chunks.get(coord) as VoxelTerrainChunk
        if terrain_chunk == null or not terrain_chunk.mesh_ready or not terrain_chunk._render_active:
            continue

        var distance: float = float(request.get("nearest_distance", INF))
        if distance > MAX_ROCK_DISTANCE_M:
            continue
        desired[coord] = {
            "request": request,
            "distance": distance,
            "full": distance <= PLANT_ADD_DISTANCE_M
        }

    for coord_value in _entries.keys():
        var coord: Vector2i = coord_value
        if not desired.has(coord):
            var stale: Dictionary = _entries[coord]
            var stale_root: Node3D = stale.get("root") as Node3D
            if stale_root != null:
                stale_root.queue_free()
            _entries.erase(coord)
            continue

        var entry: Dictionary = _entries[coord]
        var request_info: Dictionary = desired[coord]
        if bool(entry.get("plants_ready", false)) and not bool(request_info["full"]) and float(request_info["distance"]) > PLANT_REMOVE_DISTANCE_M:
            var plant_node: Node3D = entry.get("plants") as Node3D
            if plant_node != null:
                plant_node.queue_free()
            entry["plants"] = null
            entry["plants_ready"] = false
            _entries[coord] = entry


func _build_one_pending_tile() -> void:
    if _world == null:
        return

    var best_coord := Vector2i(-1, -1)
    var best_action: String = ""
    var best_request: Dictionary = {}
    var best_distance: float = INF

    # Existing entries missing near-field flora are upgraded one tile at a time.
    for coord_value in _world._wanted.keys():
        var coord: Vector2i = coord_value
        var parts: Dictionary = _world._decode_lod_key(coord)
        if int(parts["lod"]) != 0:
            continue
        var request: Dictionary = _world._wanted[coord]
        if bool(request.get("fallback", false)):
            continue
        var terrain_chunk: VoxelTerrainChunk = _world._chunks.get(coord) as VoxelTerrainChunk
        if terrain_chunk == null or not terrain_chunk.mesh_ready or not terrain_chunk._render_active:
            continue
        var distance: float = float(request.get("nearest_distance", INF))
        if distance > MAX_ROCK_DISTANCE_M:
            continue

        var entry: Dictionary = _entries.get(coord, {})
        var full_requested: bool = distance <= PLANT_ADD_DISTANCE_M
        var action: String = ""
        if entry.is_empty():
            action = "rocks"
        elif full_requested and not bool(entry.get("plants_ready", false)):
            action = "plants"
        if action.is_empty():
            continue
        if distance < best_distance:
            best_distance = distance
            best_coord = coord
            best_action = action
            best_request = request

    if best_coord.x < 0:
        return

    var build_token: int = _generation_epoch
    if best_action == "rocks":
        _build_rock_tile(best_coord, best_request, build_token)
    elif best_action == "plants":
        _build_plant_tile(best_coord, build_token)


func _build_rock_tile(coord: Vector2i, request: Dictionary, build_token: int) -> void:
    if build_token != _generation_epoch or _world == null:
        return

    var tile_x: int = int(_world._decode_lod_key(coord)["tile_x"])
    var tile_z: int = int(coord.y)
    var start_x: int = int(request["start_x"])
    var start_z: int = int(request["start_z"])
    var size_x: int = int(request["size_x"])
    var size_z: int = int(request["size_z"])
    var origin_x: float = _world._world_min_x + float(start_x) * VoxelWorld.VOXEL_SIZE
    var origin_z: float = _world._world_min_z + float(start_z) * VoxelWorld.VOXEL_SIZE
    var width_m: float = float(size_x) * VoxelWorld.VOXEL_SIZE
    var depth_m: float = float(size_z) * VoxelWorld.VOXEL_SIZE
    if width_m <= 0.0 or depth_m <= 0.0:
        return

    var tile_seed: int = _mix(_world.seed_value, tile_x, tile_z)
    var palette_rng := RandomNumberGenerator.new()
    palette_rng.seed = _mix(tile_seed, 31, 47)
    var palette_data: Dictionary = _make_palette(palette_rng)
    var rng := RandomNumberGenerator.new()
    rng.seed = _mix(tile_seed, 101, 307)

    var root_node := Node3D.new()
    root_node.name = "SurfaceScatter_%d_%d" % [tile_x, tile_z]
    root_node.position = Vector3(origin_x, 0.0, origin_z)
    add_child(root_node)

    var reservations: Array[Dictionary] = []
    var collision_body := StaticBody3D.new()
    collision_body.name = "StoneCollisions"
    root_node.add_child(collision_body)
    var combined_mesh_data = MeshDataScript.new()
    _scatter_stones(
        combined_mesh_data, collision_body, reservations, palette_data, rng, tile_seed,
        origin_x, origin_z, width_m, depth_m
    )
    if collision_body.get_child_count() == 0:
        collision_body.queue_free()
    if build_token != _generation_epoch:
        root_node.queue_free()
        return

    var rock_mesh: ArrayMesh = combined_mesh_data.build()
    if rock_mesh != null:
        var rock_instance := MeshInstance3D.new()
        rock_instance.name = "VoxelStones"
        rock_instance.mesh = rock_mesh
        rock_instance.material_override = _material
        root_node.add_child(rock_instance)

    _entries[coord] = {
        "root": root_node,
        "rocks_ready": true,
        "plants_ready": false,
        "plants": null,
        "palette": palette_data,
        "reservations": reservations,
        "tile_seed": tile_seed,
        "origin_x": origin_x,
        "origin_z": origin_z,
        "width_m": width_m,
        "depth_m": depth_m
    }


func _build_plant_tile(coord: Vector2i, build_token: int) -> void:
    if build_token != _generation_epoch or not _entries.has(coord) or _world == null:
        return
    var entry: Dictionary = _entries[coord]
    if bool(entry.get("plants_ready", false)):
        return

    var palette_data: Dictionary = entry["palette"]
    var reservations: Array[Dictionary] = entry["reservations"]
    var origin_x: float = float(entry["origin_x"])
    var origin_z: float = float(entry["origin_z"])
    var width_m: float = float(entry["width_m"])
    var depth_m: float = float(entry["depth_m"])
    var tile_seed: int = int(entry["tile_seed"])
    var rng := RandomNumberGenerator.new()
    rng.seed = _mix(tile_seed, 503, 709)

    var plant_mesh_data = MeshDataScript.new()
    _scatter_flowers(
        plant_mesh_data, reservations, palette_data, rng, tile_seed,
        origin_x, origin_z, width_m, depth_m
    )
    if build_token != _generation_epoch or not _entries.has(coord):
        return
    _scatter_grass(
        plant_mesh_data, reservations, palette_data, rng, tile_seed,
        origin_x, origin_z, width_m, depth_m
    )
    if build_token != _generation_epoch or not _entries.has(coord):
        return

    var plant_mesh: ArrayMesh = plant_mesh_data.build()
    var plant_node: Node3D = null
    if plant_mesh != null:
        plant_node = Node3D.new()
        plant_node.name = "VoxelGrassAndFlowers"
        var plant_instance := MeshInstance3D.new()
        plant_instance.name = "Mesh"
        plant_instance.mesh = plant_mesh
        plant_instance.material_override = _material
        plant_node.add_child(plant_instance)
        var root_node: Node3D = entry.get("root") as Node3D
        if root_node != null:
            root_node.add_child(plant_node)

    entry["plants"] = plant_node
    entry["plants_ready"] = true
    entry["reservations"] = reservations
    _entries[coord] = entry


func _make_palette(rng: RandomNumberGenerator) -> Dictionary:
    var palette_grid = GridScript.new(1, 1, 1)

    var gray_a: PackedColorArray = PaletteScript.shades(STONE_COLOR_A, 5, rng, 0.01, 0.05, 0.14)
    var gray_b: PackedColorArray = PaletteScript.shades(STONE_COLOR_B, 5, rng, 0.01, 0.05, 0.14)
    var moss: PackedColorArray = PaletteScript.shades(ROCK_MOSS_COLOR, 3, rng, 0.02, 0.08, 0.10)
    var rock_ramps := PackedInt32Array()
    rock_ramps.append(palette_grid.add_ramp(gray_a))
    rock_ramps.append(gray_a.size())
    rock_ramps.append(palette_grid.add_ramp(gray_b))
    rock_ramps.append(gray_b.size())
    rock_ramps.append(palette_grid.add_ramp(moss))
    rock_ramps.append(moss.size())

    var flower_set: Array = []
    var flower_definitions: Array = [
        [Color("d8322b"), Color("2b1a1a"), 0],
        [Color("4a6fd6"), Color("e8e0a0"), 0],
        [Color("f2f0ea"), Color("f0c020"), 1],
        [Color("f2c418"), Color("d89a10"), 2],
        [Color("e870a0"), Color("f5c0d0"), 3],
        [Color("8a5fc8"), Color("6a3fa8"), 4],
        [Color("f7e04a"), Color("e0b020"), 0],
        [Color("5a7fe0"), Color("3a5fc0"), 3]
    ]
    for definition in flower_definitions:
        var petals: PackedColorArray = PaletteScript.shades(definition[0], 3, rng, 0.01, 0.06, 0.08)
        var center: PackedColorArray = PaletteScript.shades(definition[1], 2, rng, 0.01, 0.05, 0.06)
        flower_set.append({
            "ps": palette_grid.add_ramp(petals),
            "pn": petals.size(),
            "cs": palette_grid.add_ramp(center),
            "cn": center.size(),
            "shape": int(definition[2])
        })

    var stems: PackedColorArray = PaletteScript.shades(STEM_COLOR, 4, rng, 0.02, 0.10, 0.15)
    var stem_start: int = palette_grid.add_ramp(stems)
    var hue: float = rng.randf_range(-0.02, 0.02)
    var grass_a: PackedColorArray = PaletteScript.shades(Color.from_hsv(0.27 + hue, 0.62, 0.55), 5, rng, 0.015, 0.08, 0.12)
    var grass_b: PackedColorArray = PaletteScript.shades(Color.from_hsv(0.24 + hue, 0.58, 0.68), 5, rng, 0.015, 0.08, 0.12)
    var grass_dry: PackedColorArray = PaletteScript.shades(Color.from_hsv(0.15, 0.45, 0.66), 5, rng, 0.02, 0.08, 0.12)

    return {
        "grid": palette_grid,
        "rock_ramps": rock_ramps,
        "flower_set": flower_set,
        "stem_start": stem_start,
        "stem_count": stems.size(),
        "grass_ramps": [
            palette_grid.add_ramp(grass_a), palette_grid.add_ramp(grass_b),
            palette_grid.add_ramp(grass_dry)
        ],
        "grass_counts": [grass_a.size(), grass_b.size(), grass_dry.size()]
    }


func _make_object_grid(width: int, height: int, depth: int, palette_data: Dictionary):
    var grid = GridScript.new(maxi(4, width), maxi(4, height), maxi(4, depth))
    var shared_palette = palette_data["grid"]
    grid.palette = shared_palette.palette
    grid.ramp_lo = shared_palette.ramp_lo
    grid.ramp_hi = shared_palette.ramp_hi
    return grid


func _scatter_stones(
        output, collision_body: StaticBody3D, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int,
        origin_x: float, origin_z: float, width_m: float, depth_m: float) -> void:
    var stone_noise := _make_noise(_mix(tile_seed, 19, 53), 0.022)
    var noise_pick: float = stone_noise.get_noise_2d(origin_x + width_m * 0.5, origin_z + depth_m * 0.5) * 0.5 + 0.5
    var stone_count: int = rng.randi_range(3, 6)
    if noise_pick > 0.5:
        stone_count += int((noise_pick - 0.5) * 12.0)

    for i in range(stone_count):
        var local_x: float = rng.randf_range(1.6, maxf(1.7, width_m - 1.6))
        var local_z: float = rng.randf_range(1.6, maxf(1.7, depth_m - 1.6))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        if _near_spawn(world_x, world_z):
            continue

        var surface: Dictionary = _surface_info(world_x, world_z)
        var rock_weight: float = float(surface["rock_weight"])
        var slope: float = float(surface["slope"])
        if rock_weight < 0.18 and rng.randf() > 0.28:
            continue

        if rock_weight >= 0.58 and slope >= 0.70 and rng.randf() < 0.62:
            _try_add_outcrop(
                output, collision_body, reservations, palette_data, rng, world_x, world_z,
                local_x, local_z, float(surface["height"]), Vector2(surface["gradient_x"], surface["gradient_z"]),
                width_m, depth_m
            )
            continue

        var radius_units: float = lerpf(2.5, 14.0, pow(rng.randf(), 2.5))
        var voxel_size: float = PROP_VOXEL_SIZE
        var radius_m: float = radius_units * voxel_size
        var exclusion_radius: float = maxf(0.45, radius_m * 1.55)
        if not _can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
            continue
        var rock_seed: int = rng.randi()
        var grid = _make_rock_grid(radius_units, 1.0, voxel_size, palette_data, rock_seed)
        var rock_piece = MeshDataScript.new()
        grid.emit(rock_piece, Vector3.ZERO, voxel_size, rock_seed)
        var surface_y: float = float(surface["height"])
        _append_transformed_mesh(
            output, rock_piece, Basis.IDENTITY,
            Vector3(local_x, surface_y - 0.06, local_z)
        )
        if radius_units >= 5.0:
            _add_boulder_collision(collision_body, local_x, local_z, surface_y, radius_m)
        reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})

    # A second set of samples finds long rock ribs specifically on bare mountain faces.
    for probe in range(7):
        var local_x: float = rng.randf_range(2.0, maxf(2.1, width_m - 2.0))
        var local_z: float = rng.randf_range(2.0, maxf(2.1, depth_m - 2.0))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        var surface: Dictionary = _surface_info(world_x, world_z)
        if float(surface["rock_weight"]) < 0.60 or float(surface["slope"]) < 0.68:
            continue
        if rng.randf() > 0.72:
            continue
        _try_add_outcrop(
            output, collision_body, reservations, palette_data, rng, world_x, world_z,
            local_x, local_z, float(surface["height"]), Vector2(surface["gradient_x"], surface["gradient_z"]),
            width_m, depth_m
        )


func _try_add_outcrop(
        output, collision_body: StaticBody3D, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, world_x: float, world_z: float,
        local_x: float, local_z: float, surface_y: float, gradient: Vector2,
        width_m: float, depth_m: float) -> void:
    var radius_units: float = rng.randf_range(8.0, 15.0)
    var stretch_y: float = rng.randf_range(3.0, 5.8)
    var radius_m: float = radius_units * PROP_VOXEL_SIZE
    # The exclusion radius includes the long axis, so vegetation and other rocks do not
    # grow through a rib. It is also used as the minimum distance from neighbouring tiles.
    var exclusion_radius: float = maxf(2.4, radius_m * (stretch_y * 0.50 + 1.55))
    if not _can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
        return

    var rock_seed: int = rng.randi()
    var grid = _make_rock_grid(radius_units, stretch_y, PROP_VOXEL_SIZE, palette_data, rock_seed)
    var rock_piece = MeshDataScript.new()
    grid.emit(rock_piece, Vector3.ZERO, PROP_VOXEL_SIZE, rock_seed)

    # Aim the long axis up the local slope. The foot sinks slightly into the terrain, so
    # the visible half reads as a natural stone rib instead of a standing pillar.
    var axis := Vector3(gradient.x, maxf(gradient.length(), 0.20), gradient.y).normalized()
    var reference := Vector3.FORWARD
    if absf(axis.dot(reference)) > 0.93:
        reference = Vector3.RIGHT
    var x_axis: Vector3 = reference.cross(axis).normalized()
    if x_axis.length_squared() < 0.0001:
        x_axis = Vector3.RIGHT
    var z_axis: Vector3 = x_axis.cross(axis).normalized()
    var basis := Basis(x_axis, axis, z_axis)
    basis = basis * Basis(Vector3.UP, rng.randf_range(-0.24, 0.24))
    var anchor := Vector3(local_x, surface_y - 0.22, local_z)
    _append_transformed_mesh(output, rock_piece, basis, anchor)
    var collision_height: float = maxf(1.8, radius_m * stretch_y * 1.35)
    var collision_shape := BoxShape3D.new()
    collision_shape.size = Vector3(radius_m * 2.5, collision_height, radius_m * 2.5)
    var collision := CollisionShape3D.new()
    collision.name = "MountainRibCollision"
    collision.shape = collision_shape
    collision.transform = Transform3D(basis, anchor + basis * Vector3(0.0, collision_height * 0.5, 0.0))
    collision_body.add_child(collision)
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


func _scatter_flowers(
        output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float) -> void:
    var meadow := _make_noise(_mix(tile_seed, 37, 0), 0.035)
    var meadow_pick: float = meadow.get_noise_2d(origin_x + width_m * 0.5, origin_z + depth_m * 0.5) * 0.5 + 0.5
    var patch_count: int = rng.randi_range(3, 6)
    if meadow_pick > 0.55:
        patch_count += 2
    var flower_set: Array = palette_data["flower_set"]
    var flower_index: int = 0

    for patch_index in range(patch_count):
        var center_x: float = rng.randf_range(3.0, maxf(3.1, width_m - 3.0))
        var center_z: float = rng.randf_range(3.0, maxf(3.1, depth_m - 3.0))
        var flower_a: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        var flower_b: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        var count: int = rng.randi_range(8, 24)
        var sigma: float = rng.randf_range(1.3, 2.8)
        for j in range(count):
            var local_x: float = center_x + rng.randfn(0.0, sigma)
            var local_z: float = center_z + rng.randfn(0.0, sigma)
            var flower: Dictionary = flower_a if rng.randf() < 0.75 else flower_b
            _try_add_flower(output, reservations, palette_data, rng, flower, local_x, local_z,
                origin_x, origin_z, width_m, depth_m, flower_index)
            flower_index += 1

    for single_index in range(10):
        var local_x: float = rng.randf_range(1.0, maxf(1.1, width_m - 1.0))
        var local_z: float = rng.randf_range(1.0, maxf(1.1, depth_m - 1.0))
        var flower: Dictionary = flower_set[rng.randi_range(0, flower_set.size() - 1)]
        _try_add_flower(output, reservations, palette_data, rng, flower, local_x, local_z,
            origin_x, origin_z, width_m, depth_m, flower_index)
        flower_index += 1


func _try_add_flower(
        output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, flower: Dictionary,
        local_x: float, local_z: float, origin_x: float, origin_z: float,
        width_m: float, depth_m: float, index: int) -> void:
    var exclusion_radius: float = 0.32
    if not _can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
        return
    var world_x: float = origin_x + local_x
    var world_z: float = origin_z + local_z
    var surface: Dictionary = _surface_info(world_x, world_z)
    if float(surface["rock_weight"]) > 0.17 or float(surface["slope"]) > 0.82:
        return

    var grid = _make_object_grid(22, 20, 22, palette_data)
    _add_flower(
        grid, rng, flower,
        int(palette_data["stem_start"]), int(palette_data["stem_count"])
    )
    var piece = MeshDataScript.new()
    var flower_seed: int = _mix(index + int(origin_x * 10.0), int(local_x * 100.0), int(local_z * 100.0))
    grid.emit(piece, Vector3.ZERO, PROP_VOXEL_SIZE, flower_seed)
    _append_transformed_mesh(
        output, piece, Basis.IDENTITY,
        Vector3(local_x, float(surface["height"]), local_z)
    )
    reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})


func _scatter_grass(
        output, reservations: Array[Dictionary], palette_data: Dictionary,
        rng: RandomNumberGenerator, tile_seed: int, origin_x: float, origin_z: float,
        width_m: float, depth_m: float) -> void:
    var meadow := _make_noise(_mix(tile_seed, 37, 0), 0.035)
    var ramps: Array = palette_data["grass_ramps"]
    var counts: Array = palette_data["grass_counts"]
    for clump_index in range(GRASS_BLADE_COUNT):
        var local_x: float = rng.randf_range(0.8, maxf(0.9, width_m - 0.8))
        var local_z: float = rng.randf_range(0.8, maxf(0.9, depth_m - 0.8))
        var world_x: float = origin_x + local_x
        var world_z: float = origin_z + local_z
        var surface: Dictionary = _surface_info(world_x, world_z)
        if float(surface["rock_weight"]) > 0.24 or float(surface["slope"]) > 0.94:
            continue
        var meadow_detail: float = meadow.get_noise_2d(world_x, world_z)
        if meadow_detail < -0.35:
            continue

        var exclusion_radius: float = 0.42
        if not _can_reserve(local_x, local_z, exclusion_radius, width_m, depth_m, reservations):
            continue

        var selection: float = rng.randf()
        var ramp_index: int = 0
        if selection > 0.85:
            ramp_index = 2
        elif selection > 0.45:
            ramp_index = 1
        var ramp_start: int = int(ramps[ramp_index])
        var ramp_count: int = int(counts[ramp_index])
        var grid = _make_object_grid(18, 12, 18, palette_data)
        var blades: int = rng.randi_range(3, 9)
        var height_max: int = rng.randi_range(3, 7)
        for blade_index in range(blades):
            var blade_x: int = roundi(rng.randfn(0.0, 2.2))
            var blade_z: int = roundi(rng.randfn(0.0, 2.2))
            var blade_height: int = rng.randi_range(2, height_max)
            _add_blade(grid, rng, blade_x, blade_z, blade_height, ramp_start, ramp_count)

        var piece = MeshDataScript.new()
        var grass_seed: int = _mix(clump_index + int(origin_x * 10.0), int(local_x * 100.0), int(local_z * 100.0))
        grid.emit(piece, Vector3.ZERO, PROP_VOXEL_SIZE, grass_seed)
        _append_transformed_mesh(
            output, piece, Basis.IDENTITY,
            Vector3(local_x, float(surface["height"]), local_z)
        )
        reservations.append({"p": Vector2(local_x, local_z), "r": exclusion_radius})


func _make_rock_grid(radius: float, stretch_y: float, voxel_size: float, palette_data: Dictionary, rock_seed: int):
    var width: int = ceili(radius * 2.8) + 6
    var height: int = ceili(radius * 1.75 * stretch_y) + 6
    var grid = _make_object_grid(width, height, width, palette_data)
    _fill_rock(grid, rock_seed, radius, stretch_y, palette_data["rock_ramps"])
    return grid


func _fill_rock(grid, seed_value: int, radius: float, stretch_y: float, rock_ramps: PackedInt32Array) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value
    var noise := _make_noise(seed_value, 0.2)

    var palette_pick: bool = rng.randf() < 0.5
    var gray_start: int = int(rock_ramps[0] if palette_pick else rock_ramps[2])
    var gray_count: int = int(rock_ramps[1] if palette_pick else rock_ramps[3])
    var moss: bool = rng.randf() < 0.45
    var rx: float = radius * rng.randf_range(0.9, 1.3)
    var ry: float = radius * rng.randf_range(0.5, 0.85) * stretch_y
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
                grid.put( xx, y, zz, index)


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


func _surface_info(world_x: float, world_z: float) -> Dictionary:
    var sample: Vector3 = _world.surface_sample_at_world(world_x, world_z)
    var gradient := Vector2(sample.y, sample.z)
    var slope: float = gradient.length()
    var rock_weight: float = _world._generator.get_surface_rock_weight(slope, world_x, world_z)
    return {
        "height": _world.get_surface_height(world_x, world_z),
        "slope": slope,
        "gradient_x": gradient.x,
        "gradient_z": gradient.y,
        "rock_weight": rock_weight
    }


func _can_reserve(
        local_x: float, local_z: float, radius: float,
        width_m: float, depth_m: float, reservations: Array[Dictionary]) -> bool:
    if local_x - radius < MIN_STONE_EDGE_MARGIN_M or local_z - radius < MIN_STONE_EDGE_MARGIN_M:
        return false
    if local_x + radius > width_m - MIN_STONE_EDGE_MARGIN_M or local_z + radius > depth_m - MIN_STONE_EDGE_MARGIN_M:
        return false

    var candidate := Vector2(local_x, local_z)
    for occupied in reservations:
        var existing_position: Vector2 = occupied["p"]
        var min_distance: float = radius + float(occupied["r"]) + 0.16
        if candidate.distance_squared_to(existing_position) < min_distance * min_distance:
            return false
    return true


func _append_transformed_mesh(destination, source, basis: Basis, origin: Vector3) -> void:
    if source.verts.is_empty():
        return
    var first_index: int = destination.verts.size()
    for i in range(source.verts.size()):
        destination.verts.append(origin + basis * source.verts[i])
        destination.normals.append((basis * source.normals[i]).normalized())
        destination.colors.append(source.colors[i])
    for index_value in source.indices:
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
