extends SceneTree

const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")


func _initialize() -> void:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("VoxEnNativeBuilder is required for the native PG-Island terrain test.")
        quit(1)
        return

    # The 8 km world must create one shared, deterministic macro field.
    var generator = GeneratorScript.new(424242, 8000.0)
    var sampler: Object = generator.get_native_sampler()
    if sampler == null:
        push_error("Native PG-Island sampler was not created.")
        quit(1)
        return

    var grid: PackedFloat32Array = generator.get_surface_height_grid(
        -4000.0, -4000.0, 17, 17, 500.0
    )
    if grid.size() != 289:
        push_error("Native macro height sampler returned an invalid grid.")
        quit(1)
        return

    var minimum_height := INF
    var maximum_height := -INF
    for value in grid:
        if not is_finite(value):
            push_error("PG-Island macro field contains a non-finite height.")
            quit(1)
            return
        minimum_height = minf(minimum_height, value)
        maximum_height = maxf(maximum_height, value)

    if minimum_height >= 0.0:
        push_error("The 8 km macro field has no underwater bathymetry.")
        quit(1)
        return
    if maximum_height < 150.0:
        push_error("The macro field did not generate the expected mountain relief.")
        quit(1)
        return

    var sample_a: float = generator.get_surface_height(123.4, -567.8)
    var sample_b: float = float(sampler.call("get_surface_height", 123.4, -567.8))
    if not is_finite(sample_a) or absf(sample_a - sample_b) > 0.0001:
        push_error("Shared native sampler returned inconsistent terrain samples.")
        quit(1)
        return

    var surface: Vector3 = generator.get_surface_sample(123.4, -567.8)
    if not is_finite(surface.x) or not is_finite(surface.y) or not is_finite(surface.z):
        push_error("PG-Island surface gradient contains a non-finite value.")
        quit(1)
        return

    print("Native PG-Island terrain test passed. height range=[%.2f, %.2f] m" % [
        minimum_height, maximum_height
    ])
    quit(0)
