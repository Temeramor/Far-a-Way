extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")


func _initialize() -> void:
    var generator = GeneratorScript.new(1337, 5000.0)
    var sampler: Object = generator.get_native_sampler()
    if sampler == null:
        push_error("Terrain generator did not create a native sampler.")
        quit(1)
        return

    var origin_x := -12.0
    var origin_z := 8.0
    var step := 0.5
    var grid: PackedFloat32Array = generator.get_surface_height_grid(origin_x, origin_z, 5, 5, step)
    if grid.size() != 25:
        push_error("Native batch sampler returned an invalid height-grid size.")
        quit(1)
        return

    for z in range(5):
        for x in range(5):
            var expected: float = float(grid[z * 5 + x])
            var sampled: float = generator.get_surface_height(origin_x + float(x) * step, origin_z + float(z) * step)
            if absf(expected - sampled) > 0.0001:
                push_error("Native point and batch height samplers disagree.")
                quit(1)
                return

    var point_x := origin_x + 1.25
    var point_z := origin_z + 1.75
    var surface: Vector3 = generator.get_surface_sample(point_x, point_z)
    var shared_generator = GeneratorScript.new(1337, 5000.0, sampler)
    var shared_surface: Vector3 = shared_generator.get_surface_sample(point_x, point_z)
    var shared_builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    shared_builder.call("share_terrain_sampler", sampler)
    var builder_height: float = float(shared_builder.call("get_surface_height", point_x, point_z))
    if absf(builder_height - generator.get_surface_height(point_x, point_z)) > 0.0001:
        push_error("Native chunk builders must share the world's exact NoiseSet instance.")
        quit(1)
        return
    if surface.distance_to(shared_surface) > 0.0001:
        push_error("World and decoration generators must share identical native samples.")
        quit(1)
        return

    var rock_weight := generator.get_surface_rock_weight(Vector2(surface.y, surface.z).length(), point_x, point_z)
    var native_rock_weight := float(sampler.call(
        "get_surface_rock_weight", Vector2(surface.y, surface.z).length(), point_x, point_z
    ))
    if absf(rock_weight - native_rock_weight) > 0.0001:
        push_error("Native rock-weight sampling is inconsistent.")
        quit(1)
        return

    print("Native terrain sampler point, batch, shared-instance, and rock-weight tests passed.")
    quit(0)
