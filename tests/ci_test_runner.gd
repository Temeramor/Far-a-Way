extends Node

func _ready() -> void:
    var test_script_path := OS.get_environment("VOXEN_TEST_SCRIPT")
    if not test_script_path.begins_with("res://tests/") or not test_script_path.ends_with("_test.gd"):
        push_error("VOXEN_TEST_SCRIPT must point to a test script under res://tests/.")
        get_tree().quit(2)
        return

    var test_script := load(test_script_path) as GDScript
    if test_script == null:
        push_error("Could not load test script: " + test_script_path)
        get_tree().quit(2)
        return

    var test_node := test_script.new() as Node
    if test_node == null:
        push_error("Test script must extend Node: " + test_script_path)
        get_tree().quit(2)
        return

    test_node.name = "ActiveSmokeTest"
    add_child(test_node)
