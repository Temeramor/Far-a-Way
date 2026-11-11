extends Node

const ENTRYPOINTS: Array[Script] = [
    preload("res://scripts/streaming/voxel_world.gd"),
    preload("res://scripts/rendering/voxel_surface_scatter.gd"),
    preload("res://scripts/world/world_controller.gd"),
]


func _ready() -> void:
    for script_resource: Script in ENTRYPOINTS:
        var instance: Object = script_resource.new()
        if not instance is Node3D:
            push_error("Refactored entry point must remain a Node3D: %s" % script_resource.resource_path)
            get_tree().quit(1)
            return
        instance.free()
    print("PASS: refactor_entrypoints_smoke_test")
    get_tree().quit(0)
