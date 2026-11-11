extends "res://scripts/rendering/voxel_surface_scatter/voxel_surface_scatter_state.gd"

func set_weather_mode(mode: int) -> void:
    _weather_mode = clampi(mode, 0, 2)
    if _plant_material == null:
        return
    # Weather changes sway amplitude and the strength of gusts, not a frantic oscillation rate.
    var strengths: Array[float] = [0.018, 0.055, 0.11]
    var gusts: Array[float] = [0.08, 0.16, 0.28]
    _plant_material.set_shader_parameter("wind_strength", strengths[_weather_mode])
    _plant_material.set_shader_parameter("wind_speed", 1.25)
    _plant_material.set_shader_parameter("gust_strength", gusts[_weather_mode])
    _plant_material.set_shader_parameter("wind_direction", Vector2(0.82, 0.57).normalized())

func _on_terrain_seed_changed(_new_seed: int) -> void:
    _generation_epoch += 1
    _pending_actions.clear()
    for entry in _entries.values():
        var root_node: Node3D = entry.get("root") as Node3D
        if root_node != null:
            root_node.queue_free()
    _entries.clear()

func _plant_is_requested(terrain_lod: int, distance: float) -> bool:
    # Vegetation only occupies two prop tiers and never appears on terrain LOD2+.
    return terrain_lod <= 1 and distance <= PLANT_RENDER_DISTANCE_M

func _desired_plant_lod(distance: float, terrain_lod: int = 0) -> int:
    return maxi(terrain_lod, 0 if distance <= PLANT_FULL_DISTANCE_M else 1)

func _prop_lod_for_distance(distance_m: float) -> int:
    if distance_m <= PLANT_FULL_DISTANCE_M:
        return 0
    if distance_m <= DENSE_ROCK_DISTANCE_M:
        return 1
    if distance_m <= 600.0:
        return 2
    return 3

func _schedule_plant_tile(coord: Vector2i, voxel_lod: int, build_token: int) -> void:
    if build_token != _generation_epoch or not _entries.has(coord) or _world == null:
        return
    var entry: Dictionary = _entries[coord]
    if bool(entry.get("plants_ready", false)) or bool(entry.get("plants_building", false)):
        return

    var reservations: Array[Dictionary] = []
    for occupied in entry.get("rock_reservations", []):
        reservations.append(occupied.duplicate(true))

    var builder = DecorJobScript.new()
    builder.configure(_world.seed_value, _world.world_size_m, _world._generator.get_native_sampler())
    var job_data: Dictionary = {
        "palette": entry["palette"],
        "reservations": reservations,
        "tile_seed": int(entry["tile_seed"]),
        "origin_x": float(entry["origin_x"]),
        "origin_z": float(entry["origin_z"]),
        "width_m": float(entry["width_m"]),
        "depth_m": float(entry["depth_m"]),
        "voxel_lod": voxel_lod
    }
    entry["plants_building"] = true
    _entries[coord] = entry
    var task_id: int = WorkerThreadPool.add_task(
        Callable(builder, "build_plant_data").bind(job_data), false,
        "Far a Way vegetation L%d" % voxel_lod
    )
    entry["plants_task_id"] = task_id
    _entries[coord] = entry
    _running_decor_tasks[task_id] = {
        "builder": builder,
        "kind": "plants",
        "coord": coord,
        "epoch": build_token,
        "voxel_lod": voxel_lod
    }

func _create_decor_collision_shapes(root_node: Node3D, collision_data: Array) -> void:
    if collision_data.is_empty():
        return

    var body := StaticBody3D.new()
    body.name = "BoulderCollisions"
    body.collision_layer = 1
    body.collision_mask = 1

    for item in collision_data:
        var radius_m: float = float(item.get("radius_m", 0.5))
        var height: float = maxf(0.35, radius_m * 1.20)
        var box := BoxShape3D.new()
        box.size = Vector3(radius_m * 2.5, height, radius_m * 2.5)

        var collision := CollisionShape3D.new()
        collision.name = "BoulderCollision"
        collision.shape = box
        var base_position: Vector3 = item.get("position", Vector3.ZERO)
        var orientation: Basis = item.get("basis", Basis.IDENTITY)
        collision.basis = orientation
        collision.position = base_position + orientation.y * (height * 0.5)
        body.add_child(collision)

    if body.get_child_count() > 0:
        root_node.add_child(body)
    else:
        body.free()

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

func _surface_info(world_x: float, world_z: float) -> Dictionary:
    var sample: Vector3 = _world.surface_sample_at_world(world_x, world_z)
    var gradient := Vector2(sample.y, sample.z)
    var slope: float = gradient.length()
    # Decoration helpers are also used by isolated tests and can be queried before
    # terrain startup. In that state the world exposes a safe flat sample and zero rock weight.
    var rock_weight: float = 0.0
    var generator: VoxelTerrainGenerator = _world._generator
    if generator != null and generator.is_terrain_prepared():
        rock_weight = generator.get_surface_rock_weight(slope, world_x, world_z)
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
        destination.uv2s.append(source.uv2s[i] if source.uv2s.size() == source.verts.size() else Vector2.ZERO)
    for index_value in source.indices:
        destination.indices.append(first_index + int(index_value))
