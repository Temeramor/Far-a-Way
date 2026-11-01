extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")


func _initialize() -> void:
    var first = GeneratorScript.new(123456, 5000.0)
    var second = GeneratorScript.new(123456, 5000.0)
    var half_size_world = GeneratorScript.new(123456, 2500.0)
    var center_height: float = first.get_surface_height(0.0, 0.0)
    var repeated_height: float = second.get_surface_height(0.0, 0.0)

    assert(is_equal_approx(center_height, repeated_height),
        "Same seed should generate identical island terrain.")
    assert(center_height > 0.0, "The central island must rise above sea level.")
    assert(first.get_surface_height(2400.0, 2400.0) < 0.0,
        "The map perimeter must contain seabed below sea level.")
    assert(first.get_surface_height_voxels(0.0, 0.0) > 0,
        "Signed terrain heights must remain correctly represented in voxel units.")

    var profile: Array = first.get_mountain_profile()
    assert(profile.size() >= 0 and profile.size() <= 9,
        "A seed may generate zero to three mountain chains (three segments each).")
    if not profile.is_empty():
        var half_profile: Array = half_size_world.get_mountain_profile()
        assert(profile.size() == half_profile.size(),
            "The same seed should preserve mountain-chain count across map scales.")
        assert(is_equal_approx(float(profile[0]["width"]) * 0.5,
            float(half_profile[0]["width"])),
            "Half-size worlds should get half-width mountain ranges.")
        assert(is_equal_approx(float(profile[0]["height"]) * 0.5,
            float(half_profile[0]["height"])),
            "Half-size worlds should get half-height mountain ranges.")

    var sampled_min: float = INF
    var sampled_max: float = -INF
    for x in range(-2400, 2401, 400):
        for z in range(-2400, 2401, 400):
            var sampled_height: float = first.get_surface_height(float(x), float(z))
            sampled_min = minf(sampled_min, sampled_height)
            sampled_max = maxf(sampled_max, sampled_height)
    assert(sampled_min < 0.0 and sampled_max > 0.0,
        "The island map must contain both underwater and above-water terrain.")
    assert(sampled_max - sampled_min >= 12.0,
        "The island must retain meaningful terrain variation.")

    var spawn_position: Vector2 = first.find_highest_land_position()
    assert(first.get_surface_height(spawn_position.x, spawn_position.y) > 0.0,
        "The selected spawn position must be on dry land.")
    assert(absf(spawn_position.x) <= 2500.0 and absf(spawn_position.y) <= 2500.0,
        "The selected spawn position must stay within map bounds.")

    var surface_height: float = first.get_surface_height(0.0, 0.0)
    assert(first.get_terrain_density(0.0, surface_height - 1.0, 0.0) > 0.0,
        "Below the surface must be solid.")
    assert(first.get_terrain_density(0.0, surface_height + 1.0, 0.0) < 0.0,
        "Above the surface must be air.")

    var seabed_sample: Vector3 = first.get_surface_sample(2400.0, 2400.0)
    var seabed_slope: float = Vector2(seabed_sample.y, seabed_sample.z).length()
    assert(first.get_surface_material(seabed_sample.x, seabed_slope, 2400.0, 2400.0)
        == GeneratorScript.SAND,
        "Gentle underwater terrain must use sand rather than grass.")

    var underwater_min: float = INF
    var underwater_max: float = -INF
    var underwater_samples: int = 0
    for x in range(-2400, 2401, 200):
        for z in range(-2400, 2401, 200):
            var depth: float = first.get_surface_height(float(x), float(z))
            if depth < -2.0:
                underwater_min = minf(underwater_min, depth)
                underwater_max = maxf(underwater_max, depth)
                underwater_samples += 1
    assert(underwater_samples > 10 and underwater_max - underwater_min > 8.0,
        "The seabed must contain noticeable hills, basins and depth variation.")

    print("Island terrain smoke test passed. center_height=%.2f spawn=%s" % [
        center_height, str(spawn_position)
    ])
    quit()
