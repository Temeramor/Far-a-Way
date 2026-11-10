extends SceneTree

const ENTRYPOINTS: Array[Script] = [
    preload("res://scripts/streaming/voxel_world.gd"),
    preload("res://scripts/rendering/voxel_surface_scatter.gd"),
    preload("res://scripts/world/world_controller.gd"),
]


func _initialize() -> void:
    for script_resource: Script in ENTRYPOINTS:
        var instance: Object = script_resource.new()
        if not instance is Node3D:
            push_error("Refactored entry point must remain a Node3D: %s" % script_resource.resource_path)
            quit(1)
            return
        instance.free()
    quit(0)
