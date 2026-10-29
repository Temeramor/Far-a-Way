extends SceneTree

const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")


func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var errors: Array[String] = []
    var world := VoxelWorld.new()
    world.auto_start_on_ready = false
    world.world_size_m = 2000.0
    world.chunk_size_m = 32.0
    root.add_child(world)
    await process_frame

    var scatter := VoxelSurfaceScatter.new()
    world.add_child(scatter)
    await process_frame

    var mixed_a: int = scatter._mix(1337, 12, 31)
    var mixed_b: int = scatter._mix(1337, 12, 31)
    if mixed_a != mixed_b:
        errors.append("The per-tile seed mixer must be deterministic.")

    var occupied: Array[Dictionary] = []
    if not scatter._can_reserve(16.0, 16.0, 1.0, 32.0, 32.0, occupied):
        errors.append("The first prop position should be available.")
    occupied.append({"p": Vector2(16.0, 16.0), "r": 1.0})
    if scatter._can_reserve(17.0, 16.0, 1.0, 32.0, 32.0, occupied):
        errors.append("The exclusion map must reject intersecting props.")
    if scatter._can_reserve(0.5, 0.5, 1.0, 32.0, 32.0, occupied):
        errors.append("A prop footprint must not cross a scatter-tile edge.")

    var palette_rng := RandomNumberGenerator.new()
    palette_rng.seed = 43210
    var palette: Dictionary = scatter._make_palette(palette_rng)
    if (palette["rock_ramps"] as PackedInt32Array).size() != 6:
        errors.append("The stone palette should contain two gray ramps and one moss ramp.")
    if (palette["flower_set"] as Array).size() != 8:
        errors.append("The flower palette should include all eight flower shapes.")
    if (palette["grass_ramps"] as Array).size() != 3 or (palette["grass_counts"] as Array).size() != 3:
        errors.append("Grass should have fresh, bright and dry-green ramps.")

    var surface: Dictionary = scatter._surface_info(50.0, 60.0)
    if not surface.has("height") or not surface.has("rock_weight") or not surface.has("slope"):
        errors.append("Surface sampling must return height, slope and rock weight.")
    elif float(surface["rock_weight"]) < 0.0 or float(surface["rock_weight"]) > 1.0:
        errors.append("Surface rock weight must stay in the 0..1 interval.")

    var stone_grid = scatter._make_rock_grid(8.0, 1.0, 0.1, palette, 12345)
    var stone_mesh_data = MeshDataScript.new()
    stone_grid.emit(stone_mesh_data, Vector3.ZERO, 0.1, 12345)
    if stone_mesh_data.verts.is_empty() or stone_mesh_data.indices.is_empty():
        errors.append("The voxel rock generator must emit visible mesh geometry.")

    var rib_grid = scatter._make_rock_grid(10.0, 4.0, 0.1, palette, 54321)
    var rib_mesh_data = MeshDataScript.new()
    rib_grid.emit(rib_mesh_data, Vector3.ZERO, 0.1, 54321)
    if rib_mesh_data.verts.is_empty() or rib_mesh_data.indices.is_empty():
        errors.append("The stretched mountain-rib generator must emit visible mesh geometry.")

    var flower_grid = scatter._make_object_grid(22, 20, 22, palette)
    var flower_rng := RandomNumberGenerator.new()
    flower_rng.seed = 67890
    var first_flower: Dictionary = palette["flower_set"][2]
    scatter._add_flower(
        flower_grid, flower_rng, first_flower,
        int(palette["stem_start"]), int(palette["stem_count"])
    )
    var flower_mesh_data = MeshDataScript.new()
    flower_grid.emit(flower_mesh_data, Vector3.ZERO, 0.1, 67890)
    if flower_mesh_data.verts.is_empty() or flower_mesh_data.indices.is_empty():
        errors.append("The voxel flower generator must emit visible mesh geometry.")

    var grass_grid = scatter._make_object_grid(18, 12, 18, palette)
    var ramps: Array = palette["grass_ramps"]
    var counts: Array = palette["grass_counts"]
    scatter._add_blade(grass_grid, flower_rng, 0, 0, 6, int(ramps[0]), int(counts[0]))
    var grass_mesh_data = MeshDataScript.new()
    grass_grid.emit(grass_mesh_data, Vector3.ZERO, 0.1, 77889)
    if grass_mesh_data.verts.is_empty() or grass_mesh_data.indices.is_empty():
        errors.append("The voxel grass generator must emit visible mesh geometry.")

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Far a Way voxel surface scatter smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
