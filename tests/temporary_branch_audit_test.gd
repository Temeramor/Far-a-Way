extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var generator_script = load("res://scripts/voxel_generator.gd")
    var generator = generator_script.new(123456, 10000.0)
    var grass_weight: float = generator.get_surface_rock_weight(0.0, 0.0, 0.0)
    var rock_weight: float = generator.get_surface_rock_weight(2.0, 0.0, 0.0)
    assert(grass_weight >= 0.0 and grass_weight <= 1.0, "Grass/rock blend must be clamped")
    assert(grass_weight < 0.05, "Flat surfaces should remain grass")
    assert(rock_weight > 0.95, "Very steep surfaces should become rock")

    var builder_script = load("res://scripts/voxel_chunk_builder.gd")
    var chunk_script = load("res://scripts/voxel_chunk.gd")
    var builder = builder_script.new()
    var material := StandardMaterial3D.new()

    for sample in [{"lod": 2, "step": 16}, {"lod": 4, "step": 64}]:
        var lod: int = int(sample["lod"])
        var step: int = int(sample["step"])
        var result: Dictionary = builder.build_mesh_data({
            "coord": Vector2i(1, 1),
            "request": {
                "lod": lod,
                "start_x": 40000,
                "start_z": 40000,
                "size_x": 512,
                "size_z": 512,
                "step_voxels": step,
                "collision": false
            },
            "neighbor_lods": {},
            "seed": 1337,
            "world_min_x": -5000.0,
            "world_min_z": -5000.0,
            "world_size_voxels": 100000,
            "terrain_world_size_m": 10000.0,
            "debug_lod_colors": false,
            "build_collision": false
        })
        assert(bool(result.get("has_geometry", false)), "Expected LOD%d mesh geometry" % lod)
        var top_count: int = int(result["shadow_top_vertex_count"])
        var full_count: int = int(result["shadow_full_vertex_count"])
        assert(top_count >= 4, "Expected top terrain geometry for LOD%d" % lod)
        assert(full_count >= top_count, "Full shadow geometry must contain the top surface")

        var chunk = chunk_script.new()
        root.add_child(chunk)
        chunk.apply_mesh_data(result, material)
        var visible_mesh := chunk.get_node("VoxelMesh") as MeshInstance3D
        var shadow_proxy := chunk.get_node("TerrainShadowProxy") as MeshInstance3D
        assert(visible_mesh != null, "Visible mesh missing for LOD%d" % lod)
        assert(visible_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
            "Visible material mesh must not cast its own shadow at LOD%d" % lod)
        assert(shadow_proxy != null, "Invisible shadow proxy missing for LOD%d" % lod)
        assert(shadow_proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
            "Proxy must be shadows-only at LOD%d" % lod)
        var proxy_arrays: Array = shadow_proxy.mesh.surface_get_arrays(0)
        var proxy_vertices: PackedVector3Array = proxy_arrays[Mesh.ARRAY_VERTEX]
        var expected_count: int = full_count if lod <= 3 else top_count
        assert(proxy_vertices.size() == expected_count,
            "Wrong shadow geometry for LOD%d: expected %d, got %d" % [lod, expected_count, proxy_vertices.size()])
        chunk.free()

    print("Focused terrain blend/shadow checks passed.")
    quit(0)
