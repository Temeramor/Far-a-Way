extends Node

func _ready() -> void:
    call_deferred("_run")


func _run() -> void:
    var world := VoxelWorld.new()
    world.auto_start_on_ready = false
    world.world_size_m = 2050.0
    world.chunk_size_m = 32.0
    world.render_distance_m = 1024.0
    get_tree().root.add_child(world)
    await get_tree().process_frame

    var errors: Array[String] = []

    # Request collection is a pure, repeatable operation for an unchanged world snapshot.
    var first_plan: Dictionary = {}
    var second_plan: Dictionary = {}
    world._collect_lod_tiles(7, 0, 0, Vector2.ZERO, Vector2(0.0, -1.0), first_plan, 27.0)
    world._collect_lod_tiles(7, 0, 0, Vector2.ZERO, Vector2(0.0, -1.0), second_plan, 27.0)
    if first_plan != second_plan:
        errors.append("Identical streaming inputs must produce identical wanted requests.")

    if first_plan.is_empty():
        errors.append("The root tile containing the player must be included in the streaming plan.")
    else:
        var root_key := world._make_lod_key(7, 0, 0)
        var root_request: Dictionary = first_plan.get(root_key, {})
        if root_request.is_empty():
            errors.append("The root tile request must be retained as the LOD fallback.")
        elif not bool(root_request.get("fallback", false)):
            errors.append("The root tile containing the player must refine into child tiles.")

    # The 2,050 m world ends with a 2 m partial LOD0 tile (10 voxels).
    var edge_key := world._make_lod_key(0, 64, 64)
    var edge_bounds: Dictionary = world._chunk_bounds(edge_key)
    if not is_equal_approx(float(edge_bounds.get("width", -1.0)), 2.0):
        errors.append("The final partial tile must preserve its exact 2 m world-edge width.")
    if not is_equal_approx(float(edge_bounds.get("depth", -1.0)), 2.0):
        errors.append("The final partial tile must preserve its exact 2 m world-edge depth.")
    var outside_bounds: Dictionary = world._chunk_bounds(world._make_lod_key(0, 65, 64))
    if int(outside_bounds.get("size_x", -1)) != 0 or int(outside_bounds.get("size_z", -1)) != 0:
        errors.append("A tile beyond the world edge must have empty bounds.")

    # A request must carry the exact geometry and runtime flags consumed by the scheduler.
    var center_request: Dictionary = first_plan.get(world._make_lod_key(0, 32, 32), {})
    if not center_request.is_empty():
        if int(center_request.get("lod", -1)) != 0:
            errors.append("The near-ground request should remain LOD0.")
        if int(center_request.get("step_voxels", -1)) != world.get_mesh_step_voxels(0):
            errors.append("The planner must attach the mesh step for the selected LOD.")
        if not bool(center_request.get("collision", false)):
            errors.append("Near-ground LOD0 requests must request collision.")
        if not bool(center_request.get("shadow_proxy", false)):
            errors.append("Near-ground requests must request a terrain shadow proxy.")
        if int(center_request.get("size_x", 0)) <= 0 or int(center_request.get("size_z", 0)) <= 0:
            errors.append("Planned requests must have positive tile dimensions.")

    # Requests outside render distance are rejected before they enter the wanted set.
    var distant_plan: Dictionary = {}
    world._collect_lod_tiles(7, 0, 0, Vector2(5000.0, 5000.0), Vector2(0.0, -1.0), distant_plan, 27.0)
    if not distant_plan.is_empty():
        errors.append("Tiles outside render distance must not enter the wanted set.")

    # Differential parity check against the pre-extraction _collect_lod_tiles implementation.
    # Keep this reference deliberately local to the test: it must not call StreamingPlanner.
    var scenarios: Array = [
        {"name": "near centre", "player_xz": Vector2.ZERO, "heading": Vector2(0.0, -1.0), "player_y": 27.0},
        {"name": "moving east with hysteresis", "player_xz": Vector2(420.0, -180.0), "heading": Vector2(1.0, 0.0), "player_y": 85.0},
        {"name": "high altitude", "player_xz": Vector2(-260.0, 310.0), "heading": Vector2(-0.4, 0.9).normalized(), "player_y": 360.0},
        {"name": "partial world edge", "player_xz": Vector2(1018.0, 1018.0), "heading": Vector2(1.0, 1.0).normalized(), "player_y": 42.0},
        {"name": "outside render distance", "player_xz": Vector2(5000.0, 5000.0), "heading": Vector2.ZERO, "player_y": 27.0}
    ]
    var previous_wanted: Dictionary = {}
    for scenario in scenarios:
        var player_xz: Vector2 = scenario["player_xz"]
        var heading: Vector2 = scenario["heading"]
        var player_y: float = float(scenario["player_y"])
        var expected: Dictionary = _collect_legacy_plan(world, player_xz, heading, player_y, previous_wanted)
        world._wanted = previous_wanted.duplicate(true)
        var actual: Dictionary = {}
        world._collect_lod_tiles(7, 0, 0, player_xz, heading, actual, player_y)
        if actual != expected:
            var mismatched_keys: int = 0
            for key in expected:
                if not actual.has(key) or actual[key] != expected[key]:
                    mismatched_keys += 1
            for key in actual:
                if not expected.has(key):
                    mismatched_keys += 1
            errors.append(
                "StreamingPlanner differs from the legacy collector in scenario '%s' (%d expected, %d actual, %d mismatched keys)." %
                [str(scenario["name"]), expected.size(), actual.size(), mismatched_keys]
            )
        previous_wanted = expected.duplicate(true)

    if not errors.is_empty():
        for error in errors:
            push_error(error)
        world.queue_free()
        get_tree().quit(1)
        return

    print("PASS: streaming_planner_characterization_test")
    world.queue_free()
    get_tree().quit(0)


func _collect_legacy_plan(
    world: VoxelWorld,
    player_xz: Vector2,
    heading: Vector2,
    player_y: float,
    previous_wanted: Dictionary
) -> Dictionary:
    var wanted: Dictionary = {}
    var root_tiles: int = ceili(float(world._world_size_voxels) / float(world._chunk_size_voxels * 128))
    for tile_z in range(root_tiles):
        for tile_x in range(root_tiles):
            _collect_legacy_tile(world, 7, tile_x, tile_z, player_xz, heading, player_y, previous_wanted, wanted)
    return wanted


func _collect_legacy_tile(
    world: VoxelWorld,
    lod_index: int,
    tile_x: int,
    tile_z: int,
    player_xz: Vector2,
    heading: Vector2,
    player_y: float,
    previous_wanted: Dictionary,
    wanted: Dictionary
) -> void:
    var key := Vector2i(lod_index * 100000 + tile_x, tile_z)
    var tile_voxels: int = world._chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(world._world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return

    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, world._world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, world._world_size_voxels - start_z))
    if size_x <= 0 or size_z <= 0:
        return

    var origin_x: float = world._world_min_x + float(start_x) * 0.2
    var origin_z: float = world._world_min_z + float(start_z) * 0.2
    var width: float = float(size_x) * 0.2
    var depth: float = float(size_z) * 0.2
    var center := Vector2(origin_x + width * 0.5, origin_z + depth * 0.5)
    var nearest_x: float = clampf(player_xz.x, origin_x, origin_x + width)
    var nearest_z: float = clampf(player_xz.y, origin_z, origin_z + depth)
    var dx: float = player_xz.x - nearest_x
    var dz: float = player_xz.y - nearest_z
    var terrain_y: float = world.get_surface_height(nearest_x, nearest_z)
    var vertical_delta: float = player_y - terrain_y
    var nearest: float = sqrt(dx * dx + dz * dz + vertical_delta * vertical_delta)
    if nearest > world.render_distance_m:
        return

    var boundary: float = world.get_lod_boundary_m(lod_index - 1) if lod_index > 0 else -1.0
    if lod_index == 7:
        boundary = world.get_lod_boundary_m(6)
    var previous: Dictionary = previous_wanted.get(key, {})
    var was_split: bool = bool(previous.get("fallback", false))
    var split: bool = false
    if lod_index > 0:
        var scaled_hysteresis: float = boundary * world.lod_hysteresis_ratio
        var threshold: float = boundary + scaled_hysteresis if was_split else maxf(0.0, boundary - scaled_hysteresis)
        split = nearest < threshold

    var horizontal_center_distance: float = center.distance_to(player_xz)
    var request := {
        "lod": lod_index,
        "fallback": split,
        "distance": nearest,
        "nearest_distance": nearest,
        "priority": horizontal_center_distance - maxf(0.0, (center - player_xz).dot(heading) * 0.30),
        "collision": lod_index == 0 and nearest <= world.collision_distance_m,
        "start_x": start_x,
        "start_z": start_z,
        "size_x": size_x,
        "size_z": size_z,
        "tile_x": tile_x,
        "tile_z": tile_z,
        "tile_size_m": world.chunk_size_m * float(1 << lod_index),
        "step_voxels": world.get_mesh_step_voxels(lod_index),
        "shadow_proxy": nearest <= 640.0
    }
    wanted[key] = request

    if split:
        for dz_offset in range(2):
            for dx_offset in range(2):
                _collect_legacy_tile(
                    world, lod_index - 1, tile_x * 2 + dx_offset, tile_z * 2 + dz_offset,
                    player_xz, heading, player_y, previous_wanted, wanted
                )
