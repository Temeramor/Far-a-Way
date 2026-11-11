extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")
const WORLD_SIZE_M := 2000.0
const MIN_EXPECTED_HEIGHT_M := -250.0
const MAX_EXPECTED_HEIGHT_M := 1700.0


func _initialize() -> void:
    # The current terrain is a PG-Island-inspired native macro field. It is not
    # expected to match the former GDScript/Godot FastNoiseLite height formula:
    # the native port intentionally uses a different RNG and noise configuration.
    # Test native-field invariants here; do not compare two different algorithms.
    var generator = GeneratorScript.new(1337, WORLD_SIZE_M)
    var sampler: Object = generator.get_native_sampler()
    if sampler == null:
        push_error("Native terrain sampler is unavailable.")
        quit(1)
        return

    generator.configure_native_terrain_sampler()

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
        var first_height: float = generator.get_surface_height(point.x, point.y)
        var second_height: float = generator.get_surface_height(point.x, point.y)
        if not is_finite(first_height):
            push_error("Native terrain returned a non-finite height at %s." % point)
            quit(1)
            return
        if first_height < MIN_EXPECTED_HEIGHT_M or first_height > MAX_EXPECTED_HEIGHT_M:
            push_error("Native terrain height is outside the supported range at %s: %f" % [
                point, first_height
            ])
            quit(1)
            return
        if absf(first_height - second_height) > 0.0001:
            push_error("Repeated native height samples are not deterministic at %s." % point)
            quit(1)
            return

        var surface: Vector3 = generator.get_surface_sample(point.x, point.y)
        if not is_finite(surface.x) or not is_finite(surface.y) or not is_finite(surface.z):
            push_error("Native terrain returned a non-finite surface sample at %s." % point)
            quit(1)
            return
        if absf(surface.x - first_height) > 0.001:
            push_error("Native height and surface sample disagree at %s." % point)
            quit(1)
            return

        var slope := Vector2(surface.y, surface.z).length()
        var rock_weight: float = generator.get_surface_rock_weight(slope, point.x, point.y)
        if not is_finite(rock_weight) or rock_weight < 0.0 or rock_weight > 1.0:
            push_error("Native rock weight is outside [0, 1] at %s: %f" % [point, rock_weight])
            quit(1)
            return

    print("PASS: native_terrain_field_invariants_test")
    quit(0)
