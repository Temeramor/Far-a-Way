extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")
const WORLD_SIZE_M := 10660.0
const REFERENCE_WORLD_SIZE_M := 10000.0


func _initialize() -> void:
    var seed_value := 1337
    var generator = GeneratorScript.new(seed_value, WORLD_SIZE_M)
    var reference_transition := _make_transition_noise(seed_value, WORLD_SIZE_M)
    var points: Array[Vector2] = [
        Vector2(0.0, 0.0),
        Vector2(-12.5, 8.0),
        Vector2(125.0, -230.5),
        Vector2(-420.0, 315.0),
        Vector2(620.0, 540.0),
        Vector2(-780.0, -660.0),
        Vector2(999.5, -840.0),
        Vector2(-1000.0, 1000.0),
        Vector2(5300.0, 0.0)
    ]

    for point in points:
        var surface: Vector3 = generator.get_surface_sample(point.x, point.y)
        var slope := Vector2(surface.y, surface.z).length()
        var normal_slope := 1.0 - 1.0 / sqrt(1.0 + slope * slope)
        var transition_noise: float = reference_transition.get_noise_2d(point.x, point.y) * 0.12
        var expected_rock := _smoothstep(0.30, 0.48, normal_slope + transition_noise)
        var actual_rock: float = generator.get_surface_rock_weight(slope, point.x, point.y)
        if absf(actual_rock - expected_rock) > 0.0001:
            push_error("Vendored FastNoiseLite rock-weight mismatch at %s." % point)
            quit(1)
            return

    var grid: PackedFloat32Array = generator.get_surface_height_grid(-100.0, -100.0, 5, 5, 50.0)
    if grid.size() != 25:
        push_error("Native geology sampler returned an invalid sample grid.")
        quit(1)
        return
    for z in range(5):
        for x in range(5):
            var expected: float = generator.get_surface_height(-100.0 + float(x) * 50.0,
                -100.0 + float(z) * 50.0)
            var actual: float = grid[z * 5 + x]
            if absf(actual - expected) > 0.0001:
                push_error("Native point and batch geology samplers disagree.")
                quit(1)
                return

    print("FastNoiseLite transition parity and unified island sampler checks passed.")
    quit(0)


func _make_transition_noise(seed_value: int, world_size_m: float) -> FastNoiseLite:
    var frequency_scale: float = clampf(REFERENCE_WORLD_SIZE_M / world_size_m, 0.35, 6.0)
    var noise := FastNoiseLite.new()
    noise.seed = seed_value + 1301
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = 0.008 * frequency_scale
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = 2
    noise.fractal_lacunarity = 2.05
    noise.fractal_gain = 0.52
    return noise


func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
    var t: float = clampf((value - edge_a) / (edge_b - edge_a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
