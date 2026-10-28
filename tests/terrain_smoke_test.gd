extends SceneTree

func _initialize() -> void:
    var generator_script := load("res://scripts/voxel_generator.gd")
    var first = generator_script.new(123456, 2000.0)
    var second = generator_script.new(123456, 2000.0)
    var half_size_world = generator_script.new(123456, 1000.0)
    var h0: float = first.get_surface_height(0.0, 0.0)
    var h1: float = second.get_surface_height(0.0, 0.0)
    assert(is_equal_approx(h0, h1), "Same seed should generate identical terrain.")
    assert(h0 >= 0.2, "Voxel surfaces must remain above the world floor.")
    assert(first.get_surface_height_voxels(0.0, 0.0) >= 1, "Surface voxel height should be positive.")
    assert(first.get_mountain_profile().size() == 6, "The 2 km map should create two seeded mountain chains (six segments).")
    var sampled_min: float = INF
    var sampled_max: float = -INF
    for x in range(-900, 901, 300):
        for z in range(-900, 901, 300):
            var sampled_height: float = first.get_surface_height(float(x), float(z))
            sampled_min = minf(sampled_min, sampled_height)
            sampled_max = maxf(sampled_max, sampled_height)
    assert(sampled_max - sampled_min >= 12.0,
        "The smaller map should retain meaningful terrain variation across its 2 km area.")
    var original_profile: Array = first.get_mountain_profile()
    var half_profile: Array = half_size_world.get_mountain_profile()
    assert(is_equal_approx(float(original_profile[0]["width"]) * 0.5, float(half_profile[0]["width"])),
        "Half-size worlds should get half-width mountain ranges.")
    assert(is_equal_approx(float(original_profile[0]["height"]) * 0.5, float(half_profile[0]["height"])),
        "Half-size worlds should get half-height mountain ranges.")
    assert(first.get_terrain_density(0.0, h0 - 1.0, 0.0) > 0.0, "Below the surface must be solid.")
    assert(first.get_terrain_density(0.0, h0 + 1.0, 0.0) < 0.0, "Above the surface must be air.")
    print("Terrain smoke test passed. spawn_height=%.2f" % h0)
    quit()
