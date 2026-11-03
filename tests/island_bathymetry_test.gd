extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")

func _initialize() -> void:
    var seed_value := 842771
    var generator = GeneratorScript.new(seed_value, 10660.0)
    var repeated = GeneratorScript.new(seed_value, 10660.0)

    assert(is_equal_approx(generator.get_surface_height(0.0, 0.0),
        repeated.get_surface_height(0.0, 0.0)),
        "The complete island and bathymetry must be deterministic for a seed.")

    # A 100 m sampling lattice estimates the island's planimetric area without
    # allocating a world-sized heightmap or visiting every 20 cm voxel.
    var land_samples := 0
    var sample_step := 100.0
    var half_world := 5330.0
    var count := int(floor(10660.0 / sample_step)) + 1
    for z in range(count):
        for x in range(count):
            var wx := -half_world + float(x) * sample_step
            var wz := -half_world + float(z) * sample_step
            if generator.get_surface_height(wx, wz) > 0.0:
                land_samples += 1
    var estimated_area_m2 := float(land_samples) * sample_step * sample_step
    assert(estimated_area_m2 >= 3400000.0 and estimated_area_m2 <= 4600000.0,
        "The procedural island should remain close to the requested 4 km² area; got %.0f m²." % estimated_area_m2)

    # The square map is 10.52 km wide. With the maximum island semi-axis (~2.26 km),
    # this leaves approximately 3 km of water to the nearest map edge.
    for edge_sample in [
        Vector2(5300.0, 0.0), Vector2(-5300.0, 0.0),
        Vector2(0.0, 5300.0), Vector2(0.0, -5300.0)
    ]:
        assert(generator.get_surface_height(edge_sample.x, edge_sample.y) < -120.0,
            "The outer ocean ring should be deep water, not a shallow noisy continuation.")

    var underwater_materials := {}
    for z in range(-3000, 3001, 100):
        for x in range(-3000, 3001, 100):
            var sample := generator.get_surface_sample(float(x), float(z))
            if sample.x < -1.0:
                var slope := Vector2(sample.y, sample.z).length()
                var material_id := generator.get_surface_material(sample.x, slope, float(x), float(z))
                underwater_materials[material_id] = true
                assert(material_id == GeneratorScript.SAND
                    or material_id == GeneratorScript.ROCK
                    or material_id == GeneratorScript.SILT
                    or material_id == GeneratorScript.REEF,
                    "Only seabed materials may be assigned below sea level.")

    assert(underwater_materials.has(GeneratorScript.SAND),
        "The shallow shelf must include procedural sand.")
    assert(underwater_materials.has(GeneratorScript.ROCK),
        "Steep underwater walls must expose bedrock.")

    print("Island bathymetry test passed. estimated_land_area=%.0f m² materials=%s" % [
        estimated_area_m2, str(underwater_materials.keys())
    ])
    quit()
