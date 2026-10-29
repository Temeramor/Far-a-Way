extends Node3D
class_name VoxelSurfaceScatter

## Streamed surface decoration. Per-object algorithms are separated into rock, mountain-rib
## and vegetation scripts; this node owns tile lifetime, LOD selection and shared materials.
const GridScript = preload("res://scripts/vegetation/vox_grid.gd")
const PaletteScript = preload("res://scripts/vegetation/voxel_palette.gd")
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const WindShader: Shader = preload("res://shaders/vegetation_wind.gdshader")
const DecorJobScript = preload("res://scripts/world/voxel_surface_decor_job.gd")

const MAX_DECOR_DISTANCE_M: float = 1900.0
const DENSE_ROCK_DISTANCE_M: float = 240.0
const PLANT_FULL_DISTANCE_M: float = 92.0
const PLANT_REMOVE_HYSTERESIS_M: float = 12.0
const PLANT_RENDER_DISTANCE_M: float = 320.0
const ROCK_SHADOW_DISTANCE_M: float = 80.0
const DECOR_COLLISION_HYSTERESIS_M: float = 12.0
const MAX_CONCURRENT_DECOR_JOBS: int = 1
const MIN_STONE_EDGE_MARGIN_M: float = 0.25
const ROCK_MOSS_COLOR := Color("5e7b3a")
const STONE_COLOR_A := Color("8b8984")
const STONE_COLOR_B := Color("77706a")
const STEM_COLOR := Color("4c8a30")

var _world: VoxelWorld
var _material: StandardMaterial3D
var _plant_material: ShaderMaterial
var _entries: Dictionary = {}
var _pending_actions: Array[Dictionary] = []
var _running_decor_tasks: Dictionary = {}
var _refresh_accumulator: float = 0.0
var _generation_epoch: int = 0
var _weather_mode: int = 1


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


func _process(delta: float) -> void:
    if _world == null or not _world._world_started:
        return
    _poll_decor_tasks()
    _refresh_accumulator += delta
    if _refresh_accumulator >= 0.18:
        _refresh_accumulator = 0.0
        _reconcile_entries()
    _build_one_pending_tile()

func _on_terrain_seed_changed(_new_seed: int) -> void:
    _generation_epoch += 1
    _pending_actions.clear()
    for entry in _entries.values():
        var root_node: Node3D = entry.get("root") as Node3D
        if root_node != null:
            root_node.queue_free()
    _entries.clear()

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


func _build_one_pending_tile() -> void:
    if _running_decor_tasks.size() >= MAX_CONCURRENT_DECOR_JOBS or _pending_actions.is_empty():
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
        "terrain_lod": terrain_lod,
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
    builder.configure(_world.seed_value, _world.world_size_m)
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
    builder.configure(_world.seed_value, _world.world_size_m)
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

func _poll_decor_tasks() -> void:
    var applied_count: int = 0
    for task_key in _running_decor_tasks.keys():
        var task_id: int = int(task_key)
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var record: Dictionary = _running_decor_tasks[task_id]
        _running_decor_tasks.erase(task_id)
        var coord: Vector2i = record["coord"]
        if int(record["epoch"]) != _generation_epoch or not _entries.has(coord):
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


func _create_decor_collision_shapes(root_node: Node3D, collision_data: Array) -> void:
    if collision_data.is_empty():
        return
    var body := StaticBody3D.new()
    body.name = "DecorationCollisions"
    body.collision_layer = 1
    body.collision_mask = 1
    for item in collision_data:
        var points: PackedVector3Array = item.get("points", PackedVector3Array())
        if points.size() < 4:
            continue
        # Bound convex-hull work on large cliff meshes while preserving the silhouette.
        var stride: int = maxi(1, ceili(float(points.size()) / 192.0))
        var hull_points := PackedVector3Array()
        for i in range(0, points.size(), stride):
            hull_points.append(points[i])
        if hull_points.size() < 4:
            continue
        var convex := ConvexPolygonShape3D.new()
        convex.set_points(hull_points)
        convex.margin = 0.03
        var collision := CollisionShape3D.new()
        collision.name = "DecorConvexCollision"
        collision.shape = convex
        collision.position = item.get("position", Vector3.ZERO)
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
        destination.uv2s.append(source.uv2s[i] if source.uv2s.size() == source.verts.size() else Vector2.ZERO)
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
