extends "res://scripts/rendering/voxel_surface_scatter/voxel_surface_scatter_layer_01_lod_geometry.gd"

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

    _plant_material = ShaderMaterial.new()
    _plant_material.shader = WindShader
    set_weather_mode(_weather_mode)

    if not _world.terrain_seed_changed.is_connected(_on_terrain_seed_changed):
        _world.terrain_seed_changed.connect(_on_terrain_seed_changed)

func _should_generate_rocks(
        _coord: Vector2i, terrain_lod: int, distance: float,
        tile_x: int, tile_z: int) -> bool:
    if distance > MAX_DECOR_DISTANCE_M or terrain_lod > 3:
        return false
    if terrain_lod == 0 and distance <= DENSE_ROCK_DISTANCE_M:
        return true
    var tile_seed: int = _mix(_world.seed_value, tile_x, tile_z + terrain_lod * 104729)
    var roll: float = float(tile_seed % 1000) / 1000.0
    match terrain_lod:
        0:
            return distance <= 560.0 and roll < 0.18
        1:
            return distance <= 1120.0 and roll < 0.24
        2:
            return distance <= 1600.0 and roll < 0.38
        3:
            return distance <= MAX_DECOR_DISTANCE_M and roll < 0.50
    return false

func _prop_lod_for_distance_with_hysteresis(distance_m: float, current_lod: int) -> int:
    match current_lod:
        0:
            return 1 if distance_m > PLANT_FULL_DISTANCE_M + PLANT_REMOVE_HYSTERESIS_M else 0
        1:
            if distance_m < PLANT_FULL_DISTANCE_M - PLANT_REMOVE_HYSTERESIS_M:
                return 0
            if distance_m > DENSE_ROCK_DISTANCE_M + PLANT_REMOVE_HYSTERESIS_M:
                return 2
            return 1
        2:
            if distance_m < DENSE_ROCK_DISTANCE_M - PLANT_REMOVE_HYSTERESIS_M:
                return 1
            if distance_m > 600.0 + PLANT_REMOVE_HYSTERESIS_M:
                return 3
            return 2
        3:
            return 2 if distance_m < 600.0 - PLANT_REMOVE_HYSTERESIS_M else 3
        _:
            return _prop_lod_for_distance(distance_m)

func _schedule_rock_tile(
        coord: Vector2i, request: Dictionary, distance_m: float, prop_lod: int,
        include_rocks: bool, build_token: int) -> void:
    if build_token != _generation_epoch or _world == null:
        return

    if _entries.has(coord):
        var old_entry: Dictionary = _entries[coord]
        var old_root: Node3D = old_entry.get("root") as Node3D
        if old_root != null:
            old_root.queue_free()
        _entries.erase(coord)

    var terrain_lod: int = int(request["lod"])
    var tile_x: int = int(request["tile_x"])
    var tile_z: int = int(request["tile_z"])
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

    var tile_seed: int = _mix(_world.seed_value, tile_x, tile_z + terrain_lod * 104729)
    var palette_rng := RandomNumberGenerator.new()
    palette_rng.seed = _mix(tile_seed, 31, 47)
    var palette_data: Dictionary = _make_palette(palette_rng)

    var root_node := Node3D.new()
    root_node.name = "SurfaceScatter_L%d_%d_%d" % [terrain_lod, tile_x, tile_z]
    root_node.position = Vector3(origin_x, 0.0, origin_z)
    add_child(root_node)

    var entry := {
        "root": root_node,
        "rocks_ready": false,
        "rocks_building": include_rocks,
        "rocks_task_id": -1,
        "prop_lod": prop_lod,
        "plants_ready": false,
        "plants_building": false,
        "plants_task_id": -1,
        "plants": null,
        "plants_lod": -1,
        "palette": palette_data,
        "rock_reservations": [],
        "reservations": [],
        "tile_seed": tile_seed,
        "origin_x": origin_x,
        "origin_z": origin_z,
        "width_m": width_m,
        "depth_m": depth_m,
        "distance": distance_m
    }
    _entries[coord] = entry

    # If the deterministic rock filter rejects this tile, do not initialize a terrain
    # sampler or spend a WorkerThreadPool slot on an empty rock result.
    if not include_rocks:
        if _plant_is_requested(terrain_lod, distance_m):
            _schedule_plant_tile(
                coord, _desired_plant_lod(distance_m, terrain_lod), build_token
            )
        return

    var build_collisions: bool = distance_m <= _world.collision_distance_m + DECOR_COLLISION_HYSTERESIS_M
    var builder = DecorJobScript.new()
    builder.configure(_world.seed_value, _world.world_size_m, _world._generator.get_native_sampler())
    var job_data: Dictionary = {
        "palette": palette_data,
        "tile_seed": tile_seed,
        "origin_x": origin_x,
        "origin_z": origin_z,
        "width_m": width_m,
        "depth_m": depth_m,
        "terrain_lod": terrain_lod,
        "distance_m": distance_m,
        "prop_lod": prop_lod,
        "include_rocks": include_rocks,
        "build_collisions": build_collisions
    }
    var task_id: int = WorkerThreadPool.add_task(
        Callable(builder, "build_rock_data").bind(job_data), false,
        "Far a Way surface rocks L%d" % terrain_lod
    )
    entry["rocks_task_id"] = task_id
    _entries[coord] = entry
    _running_decor_tasks[task_id] = {
        "builder": builder,
        "kind": "rocks",
        "coord": coord,
        "epoch": build_token,
        "include_rocks": include_rocks,
        "distance": distance_m,
        "build_collisions": build_collisions
    }

func _poll_decor_tasks() -> void:
    var applied_count: int = 0
    for task_key in _running_decor_tasks.keys():
        var task_id: int = int(task_key)
        var active_record: Dictionary = _running_decor_tasks[task_id]
        var active_coord: Vector2i = active_record["coord"]
        var stale_task: bool = (
            int(active_record["epoch"]) != _generation_epoch
            or not _entries.has(active_coord)
            or not _world._wanted.has(active_coord)
        )
        if stale_task and not bool(active_record.get("cancel_requested", false)):
            var active_builder = active_record.get("builder")
            if active_builder != null and active_builder.has_method("cancel"):
                active_builder.call("cancel")
            active_record["cancel_requested"] = true
            _running_decor_tasks[task_id] = active_record
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var record: Dictionary = _running_decor_tasks[task_id]
        _running_decor_tasks.erase(task_id)
        var coord: Vector2i = record["coord"]
        if int(record["epoch"]) != _generation_epoch or not _entries.has(coord) or not _world._wanted.has(coord):
            continue

        var entry: Dictionary = _entries[coord]
        var builder = record["builder"]
        var data: Dictionary = builder.result
        var kind: String = str(record["kind"])
        if kind == "rocks":
            if int(entry.get("rocks_task_id", -1)) != task_id:
                continue
            entry["rocks_building"] = false
            entry["rocks_task_id"] = -1
            if data.is_empty():
                _entries[coord] = entry
                continue

            var root_node: Node3D = entry.get("root") as Node3D
            if root_node == null or not is_instance_valid(root_node):
                _entries.erase(coord)
                continue
            var mesh_data = data.get("mesh_data")
            var rock_mesh: ArrayMesh = mesh_data.build() if mesh_data != null else null
            if rock_mesh != null:
                var rock_instance := MeshInstance3D.new()
                rock_instance.name = "VoxelStonesAndRibs"
                rock_instance.mesh = rock_mesh
                rock_instance.material_override = _material
                rock_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if float(record["distance"]) <= ROCK_SHADOW_DISTANCE_M else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                root_node.add_child(rock_instance)

            var current_request: Dictionary = _world._wanted.get(coord, {})
            var current_distance: float = float(current_request.get("nearest_distance", INF))
            var collision_is_still_near: bool = current_distance <= _world.collision_distance_m + DECOR_COLLISION_HYSTERESIS_M
            if bool(record.get("build_collisions", false)) and collision_is_still_near:
                _create_decor_collision_shapes(root_node, data.get("collision_data", []))

            var reservations: Array[Dictionary] = []
            for occupied in data.get("reservations", []):
                reservations.append(occupied.duplicate(true))
            var rock_reservations: Array[Dictionary] = []
            for occupied in reservations:
                rock_reservations.append(occupied.duplicate(true))
            entry["palette"] = data["palette"]
            entry["rocks_ready"] = bool(record["include_rocks"])
            entry["rock_reservations"] = rock_reservations
            entry["reservations"] = reservations
            _entries[coord] = entry
        elif kind == "plants":
            if int(entry.get("plants_task_id", -1)) != task_id:
                continue
            entry["plants_building"] = false
            entry["plants_task_id"] = -1
            if data.is_empty():
                _entries[coord] = entry
                continue

            var current_request: Dictionary = _world._wanted.get(coord, {})
            var current_distance: float = float(current_request.get("nearest_distance", INF))
            var current_lod: int = int(current_request.get("lod", -1))
            if current_lod < 0 or not _plant_is_requested(current_lod, current_distance):
                _entries[coord] = entry
                continue
            if _desired_plant_lod(current_distance, current_lod) != int(record["voxel_lod"]):
                _entries[coord] = entry
                continue

            var plant_mesh_data = data.get("mesh_data")
            var plant_mesh: ArrayMesh = plant_mesh_data.build() if plant_mesh_data != null else null
            var plant_node: Node3D = null
            if plant_mesh != null:
                plant_node = Node3D.new()
                plant_node.name = "VoxelPlants_LOD%d" % int(record["voxel_lod"])
                var plant_instance := MeshInstance3D.new()
                plant_instance.name = "Mesh"
                plant_instance.mesh = plant_mesh
                plant_instance.material_override = _plant_material
                # Hundreds of tiny plant shadows are expensive; let the terrain carry the lighting.
                plant_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                plant_instance.visibility_range_end = PLANT_RENDER_DISTANCE_M
                plant_instance.visibility_range_end_margin = 48.0
                plant_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
                plant_node.add_child(plant_instance)
                var root_node: Node3D = entry.get("root") as Node3D
                if root_node != null:
                    root_node.add_child(plant_node)

            entry["plants"] = plant_node
            entry["plants_ready"] = true
            entry["plants_lod"] = int(record["voxel_lod"])
            var plant_reservations: Array[Dictionary] = []
            for occupied in data.get("reservations", []):
                plant_reservations.append(occupied.duplicate(true))
            entry["reservations"] = plant_reservations
            _entries[coord] = entry

        applied_count += 1
        if applied_count >= 1:
            break

func _reconcile_entries() -> void:
    var desired: Dictionary = {}
    for coord_value in _world._wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _world._wanted[coord]
        var terrain_lod: int = int(request.get("lod", 0))
        if terrain_lod > 3 or bool(request.get("fallback", false)):
            continue

        var terrain_chunk: VoxelTerrainChunk = _world._chunks.get(coord) as VoxelTerrainChunk
        if terrain_chunk == null or not terrain_chunk.mesh_ready or not terrain_chunk._render_active:
            continue
        var distance: float = float(request.get("nearest_distance", INF))
        if distance > MAX_DECOR_DISTANCE_M:
            continue

        var tile_x: int = int(request.get("tile_x", 0))
        var tile_z: int = int(request.get("tile_z", 0))
        var wants_rocks: bool = _should_generate_rocks(coord, terrain_lod, distance, tile_x, tile_z)
        var wants_plants: bool = _plant_is_requested(terrain_lod, distance)
        if not wants_rocks and not wants_plants:
            continue

        var existing: Dictionary = _entries.get(coord, {})
        var requested_prop_lod: int = maxi(terrain_lod, _prop_lod_for_distance(distance))
        if not existing.is_empty():
            requested_prop_lod = maxi(
                terrain_lod,
                _prop_lod_for_distance_with_hysteresis(distance, int(existing.get("prop_lod", -1)))
            )
            if requested_prop_lod != int(existing.get("prop_lod", -1)):
                var old_root: Node3D = existing.get("root") as Node3D
                if old_root != null:
                    old_root.queue_free()
                _entries.erase(coord)
                existing = {}
            else:
                existing["distance"] = distance
                existing["terrain_lod"] = terrain_lod
                var root_node: Node3D = existing.get("root") as Node3D
                if root_node != null:
                    var rock_instance: MeshInstance3D = root_node.get_node_or_null("VoxelStonesAndRibs") as MeshInstance3D
                    if rock_instance != null:
                        rock_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if distance <= ROCK_SHADOW_DISTANCE_M else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                _entries[coord] = existing

        desired[coord] = {
            "request": request,
            "distance": distance,
            "lod": terrain_lod,
            "prop_lod": requested_prop_lod,
            "rocks": wants_rocks,
            "plants": wants_plants
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
        if bool(entry.get("plants_ready", false)):
            var plant_distance: float = float(request_info["distance"])
            var current_plant_lod: int = int(entry.get("plants_lod", 0))
            var wants_plants: bool = bool(request_info["plants"])
            var remove_plants: bool = not wants_plants or plant_distance > PLANT_RENDER_DISTANCE_M + PLANT_REMOVE_HYSTERESIS_M
            if current_plant_lod == 0 and plant_distance > PLANT_FULL_DISTANCE_M + PLANT_REMOVE_HYSTERESIS_M:
                remove_plants = true
            elif current_plant_lod == 1 and plant_distance < PLANT_FULL_DISTANCE_M - PLANT_REMOVE_HYSTERESIS_M:
                remove_plants = true

            if remove_plants:
                var plant_node: Node3D = entry.get("plants") as Node3D
                if plant_node != null:
                    plant_node.queue_free()
                entry["plants"] = null
                entry["plants_ready"] = false
                entry["plants_lod"] = -1
                var clean_reservations: Array[Dictionary] = []
                for occupied in entry.get("rock_reservations", []):
                    clean_reservations.append(occupied.duplicate(true))
                entry["reservations"] = clean_reservations
                _entries[coord] = entry

    # Cache a distance-sorted work queue here, not by walking every wanted tile every frame.
    var next_actions: Array[Dictionary] = []
    for coord_value in desired.keys():
        var coord: Vector2i = coord_value
        var info: Dictionary = desired[coord]
        var entry: Dictionary = _entries.get(coord, {})
        var action: String = ""
        var include_rocks: bool = false
        if entry.is_empty():
            action = "rocks"
            include_rocks = bool(info["rocks"])
        elif bool(entry.get("rocks_building", false)):
            continue
        elif bool(info["rocks"]) and not bool(entry.get("rocks_ready", false)):
            action = "rocks"
            include_rocks = true
        elif bool(info["plants"]) and not bool(entry.get("plants_ready", false)) and not bool(entry.get("plants_building", false)):
            action = "plants"
        if action.is_empty():
            continue
        next_actions.append({
            "coord": coord,
            "action": action,
            "include_rocks": include_rocks,
            "distance": float(info["distance"]),
            "lod": int(info["lod"]),
            "prop_lod": int(info["prop_lod"])
        })
    next_actions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a["distance"]) < float(b["distance"])
    )
    _pending_actions = next_actions

func _build_one_pending_tile() -> void:
    if _running_decor_tasks.size() >= MAX_CONCURRENT_DECOR_JOBS or _pending_actions.is_empty():
        return
    var shared_worker_limit: int = maxi(
        1, mini(_world.max_concurrent_mesh_jobs, maxi(1, OS.get_processor_count() - 1))
    )
    if _world._running_tasks.size() + _running_decor_tasks.size() >= shared_worker_limit:
        return

    while not _pending_actions.is_empty():
        var action_info: Dictionary = _pending_actions.pop_front()
        var coord: Vector2i = action_info["coord"]
        if not _world._wanted.has(coord):
            continue
        var request: Dictionary = _world._wanted[coord]
        var terrain_lod: int = int(request.get("lod", -1))
        var distance: float = float(request.get("nearest_distance", INF))
        if terrain_lod < 0 or terrain_lod > 3 or distance > MAX_DECOR_DISTANCE_M:
            continue
        if bool(request.get("fallback", false)):
            continue
        var terrain_chunk: VoxelTerrainChunk = _world._chunks.get(coord) as VoxelTerrainChunk
        if terrain_chunk == null or not terrain_chunk.mesh_ready or not terrain_chunk._render_active:
            continue

        var wants_rocks: bool = _should_generate_rocks(
            coord, terrain_lod, distance, int(request.get("tile_x", 0)), int(request.get("tile_z", 0))
        )
        var wants_plants: bool = _plant_is_requested(terrain_lod, distance)
        var entry: Dictionary = _entries.get(coord, {})
        var action: String = str(action_info["action"])
        if action == "rocks":
            if entry.is_empty():
                _schedule_rock_tile(
                    coord, request, distance, maxi(terrain_lod, _prop_lod_for_distance(distance)),
                    wants_rocks, _generation_epoch
                )
                return
            if wants_rocks and not bool(entry.get("rocks_ready", false)) and not bool(entry.get("rocks_building", false)):
                _schedule_rock_tile(
                    coord, request, distance, maxi(terrain_lod, _prop_lod_for_distance(distance)),
                    true, _generation_epoch
                )
                return
        elif action == "plants" and not entry.is_empty() and wants_plants:
            if not bool(entry.get("plants_ready", false)) and not bool(entry.get("plants_building", false)) and not bool(entry.get("rocks_building", false)):
                _schedule_plant_tile(
                    coord, _desired_plant_lod(distance, terrain_lod), _generation_epoch
                )
                return

func _process(delta: float) -> void:
    if _world == null or not _world._world_started:
        return
    _poll_decor_tasks()
    _refresh_accumulator += delta
    if _refresh_accumulator >= 0.18:
        _refresh_accumulator = 0.0
        _reconcile_entries()
    _build_one_pending_tile()
