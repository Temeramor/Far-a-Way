extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")
const WORLD_SIZE_M := 2000.0
const REFERENCE_WORLD_SIZE_M := 10000.0


func _initialize() -> void:
    var seed_value := 1337
    var generator = GeneratorScript.new(seed_value, WORLD_SIZE_M)
    var reference_noises := _make_reference_noises(seed_value, WORLD_SIZE_M)
    var profile: Array[Dictionary] = generator.get_mountain_profile()
    var points: Array[Vector2] = [
        Vector2(0.0, 0.0),
        Vector2(-12.5, 8.0),
        Vector2(125.0, -230.5),
        Vector2(-420.0, 315.0),
        Vector2(620.0, 540.0),
        Vector2(-780.0, -660.0),
        Vector2(999.5, -840.0),
        Vector2(-1000.0, 1000.0)
    ]

    for point in points:
        var expected_height := _reference_height(reference_noises, profile, point.x, point.y)
        var actual_height: float = generator.get_surface_height(point.x, point.y)
        if absf(actual_height - expected_height) > 0.02:
            push_error("Vendored FastNoiseLite height mismatch at %s: native=%f reference=%f" % [
                point, actual_height, expected_height
            ])
            quit(1)
            return

        var surface: Vector3 = generator.get_surface_sample(point.x, point.y)
        var slope := Vector2(surface.y, surface.z).length()
        var normal_slope := 1.0 - 1.0 / sqrt(1.0 + slope * slope)
        var transition_noise: float = reference_noises["transition"].get_noise_2d(point.x, point.y) * 0.12
        var expected_rock := _smoothstep(0.30, 0.48, normal_slope + transition_noise)
        var actual_rock: float = generator.get_surface_rock_weight(slope, point.x, point.y)
        if absf(actual_rock - expected_rock) > 0.0001:
            push_error("Vendored FastNoiseLite rock-weight mismatch at %s." % point)
            quit(1)
            return

    print("Vendored FastNoiseLite matches Godot FastNoiseLite reference samples.")
    quit(0)


func _make_reference_noises(seed_value: int, world_size_m: float) -> Dictionary:
    var frequency_scale: float = clampf(REFERENCE_WORLD_SIZE_M / world_size_m, 0.35, 6.0)
    return {
        "macro": _make_noise(seed_value + 101, 0.00028 * frequency_scale, 4, FastNoiseLite.FRACTAL_FBM),
        "hills": _make_noise(seed_value + 307, 0.00115 * frequency_scale, 4, FastNoiseLite.FRACTAL_FBM),
        "detail": _make_noise(seed_value + 503, 0.0048 * frequency_scale, 3, FastNoiseLite.FRACTAL_FBM),
        "ridges": _make_noise(seed_value + 709, 0.00082 * frequency_scale, 5, FastNoiseLite.FRACTAL_RIDGED),
        "micro": _make_noise(seed_value + 907, 0.0034 * frequency_scale, 3, FastNoiseLite.FRACTAL_RIDGED),
        "transition": _make_noise(seed_value + 1301, 0.008 * frequency_scale, 2, FastNoiseLite.FRACTAL_FBM)
    }


func _make_noise(seed_value: int, frequency: float, octaves: int, fractal: FastNoiseLite.FractalType) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = seed_value
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = frequency
    noise.fractal_type = fractal
    noise.fractal_octaves = octaves
    noise.fractal_lacunarity = 2.05
    noise.fractal_gain = 0.52
    return noise


func _reference_height(noises: Dictionary, profile: Array[Dictionary], x: float, z: float) -> float:
    var macro: float = noises["macro"].get_noise_2d(x, z)
    var hills: float = noises["hills"].get_noise_2d(x, z)
    var detail: float = noises["detail"].get_noise_2d(x, z)
    var ridge_detail: float = (noises["ridges"].get_noise_2d(x, z) + 1.0) * 0.5
    var micro_ridge: float = noises["micro"].get_noise_2d(x, z)
    var world_scale: float = WORLD_SIZE_M / REFERENCE_WORLD_SIZE_M
    var height: float = 26.0 + macro * 17.0 + hills * 10.0
    height += maxf(hills - 0.12, 0.0) * 18.0
    height += detail * 3.8
    height += pow(maxf(ridge_detail - 0.58, 0.0), 1.7) * (12.0 + 38.0 * world_scale)

    var mountain_height := 0.0
    var point := Vector2(x, z)
    for segment in profile:
        var a: Vector2 = segment["start"]
        var ab: Vector2 = segment["delta"]
        var along: float = clampf((point - a).dot(ab) / float(segment["length_squared"]), 0.0, 1.0)
        var closest: Vector2 = a + ab * along
        var offset: Vector2 = point - closest
        var distance_squared: float = offset.length_squared()
        var width: float = float(segment["width"])
        var broad_radius: float = width * 1.72
        if distance_squared >= broad_radius * broad_radius:
            continue
        var distance: float = sqrt(distance_squared)
        var peak_height: float = float(segment["height"])
        var phase: float = float(segment["phase"])
        var flank_warp: float = (detail * 0.60 + micro_ridge * 0.40) * width * 0.11
        var shaped_distance: float = maxf(0.0, distance + flank_warp)
        var broad_mask: float = clampf(1.0 - shaped_distance / broad_radius, 0.0, 1.0)
        var cliff_mask: float = clampf(1.0 - shaped_distance / width, 0.0, 1.0)
        var crest_profile: float = 0.72 + 0.28 * absf(sin(along * PI * 2.1 + phase))
        var rough_profile: float = 0.72 + 0.28 * ridge_detail
        var foothills: float = pow(broad_mask, 1.36) * (peak_height * 0.36 + 75.0 * world_scale)
        var crest: float = pow(cliff_mask, 0.82) * peak_height * crest_profile * rough_profile
        mountain_height = maxf(mountain_height, maxf(foothills, crest))
    height += mountain_height
    if mountain_height > 1.0:
        var mountain_mask: float = clampf(mountain_height / 900.0, 0.0, 1.0)
        height += mountain_mask * (micro_ridge * 42.0 + detail * 28.0)

    var spawn_fade: float = 1.0 - _smoothstep(420.0 * world_scale, 1420.0 * world_scale, point.length())
    var spawn_height: float = 25.0 + macro * 3.0 + detail * 0.8
    height = lerpf(height, spawn_height, spawn_fade)
    return maxf(0.2, clampf(height, -80.0, 1600.0))


func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
    var t: float = clampf((value - edge_a) / (edge_b - edge_a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
