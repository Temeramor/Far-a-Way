extends SceneTree

const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const RockScatterScript = preload("res://scripts/world/decoration/voxel_rock_scatter.gd")
const VegetationScatterScript = preload("res://scripts/world/decoration/voxel_vegetation_scatter.gd")


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

    if scatter._desired_plant_lod(60.0) != 0 or scatter._desired_plant_lod(130.0) != 1 or scatter._desired_plant_lod(300.0, 1) != 1:
        errors.append("Plants should use detailed LOD0 nearby and coarsened LOD1 farther away.")
    if not scatter._plant_is_requested(0, 150.0) or not scatter._plant_is_requested(1, 300.0) or scatter._plant_is_requested(1, 400.0) or scatter._plant_is_requested(2, 60.0):
        errors.append("Plants should fade out at 320 m and stop before terrain LOD2.")
    if scatter._prop_lod_for_distance(60.0) != 0 or scatter._prop_lod_for_distance(300.0) != 2 or scatter._prop_lod_for_distance(900.0) != 3:
        errors.append("Stone props must progress through LOD0..LOD3.")

    scatter.set_weather_mode(0)
    var clear_wind: float = float(scatter._plant_material.get_shader_parameter("wind_strength"))
    scatter.set_weather_mode(1)
    var cloudy_wind: float = float(scatter._plant_material.get_shader_parameter("wind_strength"))
    scatter.set_weather_mode(2)
    var overcast_wind: float = float(scatter._plant_material.get_shader_parameter("wind_strength"))
    if not (clear_wind < cloudy_wind and cloudy_wind < overcast_wind):
        errors.append("Vegetation wind strength must increase from clear to overcast weather.")

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
    var rock_ramps: PackedInt32Array = palette["rock_ramps"]
    var flower_set: Array = palette["flower_set"]
    var grass_ramps: Array = palette["grass_ramps"]
    var grass_counts: Array = palette["grass_counts"]
    if rock_ramps.size() != 6:
        errors.append("The stone palette should contain two gray ramps and one moss ramp.")
    if flower_set.size() != 8:
        errors.append("The flower palette should include all eight flower shapes.")
    if grass_ramps.size() != 3 or grass_counts.size() != 3:
        errors.append("Grass should have fresh, bright and dry-green ramps.")

    var surface: Dictionary = scatter._surface_info(50.0, 60.0)
    if not surface.has("height") or not surface.has("rock_weight") or not surface.has("slope"):
        errors.append("Surface sampling must return height, slope and rock weight.")
    elif float(surface["rock_weight"]) < 0.0 or float(surface["rock_weight"]) > 1.0:
        errors.append("Surface rock weight must stay in the 0..1 interval.")

    var rock_scatter = RockScatterScript.new()
    var vegetation_scatter = VegetationScatterScript.new()
    var stone_grid = rock_scatter.make_rock_grid(scatter, 8.0, palette, 12345)
    var stone_mesh_data = MeshDataScript.new()
    stone_grid.emit(stone_mesh_data, Vector3.ZERO, 0.1, 12345)
    if stone_mesh_data.verts.is_empty() or stone_mesh_data.indices.is_empty():
        errors.append("The voxel rock generator must emit visible mesh geometry.")
    var coarse_stone_grid = rock_scatter.make_rock_grid(scatter, 8.0, palette, 12346, 3)
    var downsampled_stone_grid = coarse_stone_grid
    for _lod_step in range(3):
        downsampled_stone_grid = downsampled_stone_grid.downsampled()
    var coarse_stone_mesh_data = MeshDataScript.new()
    downsampled_stone_grid.emit(coarse_stone_mesh_data, Vector3.ZERO, 0.8, 12346)
    if coarse_stone_mesh_data.verts.is_empty() or coarse_stone_mesh_data.indices.is_empty():
        errors.append("The downsampled distant rock tier must retain visible 80 cm voxel geometry.")
    elif coarse_stone_mesh_data.verts.size() >= stone_mesh_data.verts.size():
        errors.append("Distant rock downsampling should reduce the number of mesh vertices.")


    var flower_grid = scatter._make_object_grid(22, 20, 22, palette)
    var flower_rng := RandomNumberGenerator.new()
    flower_rng.seed = 67890
    var first_flower: Dictionary = flower_set[2]
    vegetation_scatter._add_flower(
        flower_grid, flower_rng, first_flower,
        int(palette["stem_start"]), int(palette["stem_count"])
    )
    var flower_mesh_data = MeshDataScript.new()
    flower_grid.emit(flower_mesh_data, Vector3.ZERO, 0.1, 67890)
    if flower_mesh_data.verts.is_empty() or flower_mesh_data.indices.is_empty():
        errors.append("The voxel flower generator must emit visible mesh geometry.")
    if flower_mesh_data.uv2s.size() != flower_mesh_data.verts.size():
        errors.append("Plant vertices must carry wind-weight data in UV2.")

    var grass_grid = scatter._make_object_grid(18, 12, 18, palette)
    var ramps: Array = grass_ramps
    var counts: Array = grass_counts
    vegetation_scatter._add_blade(grass_grid, flower_rng, 0, 0, 6, int(ramps[0]), int(counts[0]))
    var grass_mesh_data = MeshDataScript.new()
    grass_grid.emit(grass_mesh_data, Vector3.ZERO, 0.1, 77889)
    if grass_mesh_data.verts.is_empty() or grass_mesh_data.indices.is_empty():
        errors.append("The voxel grass generator must emit visible mesh geometry.")
    if grass_mesh_data.uv2s.size() != grass_mesh_data.verts.size():
        errors.append("Grass vertices must carry wind-weight data in UV2.")

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Far a Way voxel surface scatter smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
