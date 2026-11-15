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

    if not errors.is_empty():
        for error in errors:
            push_error(error)
        world.queue_free()
        get_tree().quit(1)
        return

    print("PASS: streaming_planner_characterization_test")
    world.queue_free()
    get_tree().quit(0)
