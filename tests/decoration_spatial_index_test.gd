extends SceneTree

const DecorJobScript = preload("res://scripts/meshing/voxel_surface_decor_job.gd")


func _initialize() -> void:
    var job = DecorJobScript.new()
    job.configure(123456, 2000.0)

    var reservations: Array[Dictionary] = []
    if not job._can_reserve(16.0, 16.0, 1.0, 32.0, 32.0, reservations):
        push_error("The first reservation should be available.")
        quit(1)
        return

    job._reserve(16.0, 16.0, 1.0, reservations)
    if job._can_reserve(17.0, 16.0, 1.0, 32.0, 32.0, reservations):
        push_error("The spatial reservation grid must reject overlapping props.")
        quit(1)
        return
    if not job._can_reserve(25.0, 25.0, 1.0, 32.0, 32.0, reservations):
        push_error("The spatial reservation grid must allow distant props.")
        quit(1)
        return

    var copied: Array[Dictionary] = []
    for occupied in reservations:
        copied.append(occupied.duplicate(true))
    job._reservation_cells.clear()
    job._rebuild_reservation_index(copied)
    if job._can_reserve(17.0, 16.0, 1.0, 32.0, 32.0, copied):
        push_error("Rebuilt reservation indices must preserve existing exclusions.")
        quit(1)
        return

    var sample: Vector4 = job._surface_info(50.0, 60.0)
    if not is_finite(sample.x) or not is_finite(sample.y) or not is_finite(sample.z) or sample.w < 0.0 or sample.w > 1.0:
        push_error("Packed terrain surface samples must contain finite values and a 0..1 rock weight.")
        quit(1)
        return

    print("Decoration spatial-index and packed-sample tests passed.")
    quit(0)
