extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var builder_script = load("res://scripts/voxel_chunk_builder.gd")
    var chunk_script = load("res://scripts/voxel_chunk.gd")
    var builder = builder_script.new()
    var material := StandardMaterial3D.new()

    for lod in [2, 4]:
        var step_by_lod: Array[int] = [2, 8, 16, 32, 64, 128, 256]
        var size_voxels: int = 1280 if lod == 2 else 5120
        var result: Dictionary = builder.build_mesh_data({
            "coord": Vector2i(1, 1),
            "request": {
                "lod": lod,
                "start_x": 50000,
                "start_z": 70000,
                "size_x": size_voxels,
                "size_z": size_voxels,
                "step_voxels": step_by_lod[lod],
                "collision": false,
                "distance": 0.0,
                "priority": 0.0
            },
            "neighbor_lods": {"left": 0, "right": 0, "north": 0, "south": 0},
            "seed": 1337,
            "world_min_x": -5000.0,
            "world_min_z": -5000.0,
            "world_size_voxels": 100000,
            "terrain_world_size_m": 10000.0,
            "debug_lod_colors": false,
            "build_collision": false
        })
        assert(bool(result.get("has_geometry", false)), "Expected generated mesh for LOD%d" % lod)
        var top_count: int = int(result["shadow_top_vertex_count"])
        var full_count: int = int(result["shadow_full_vertex_count"])
        assert(top_count >= 4, "Expected a top surface for LOD%d" % lod)
        assert(full_count >= top_count, "Full shadow mesh cannot be smaller than top-only mesh")

        var chunk = chunk_script.new()
        root.add_child(chunk)
        chunk.apply_mesh_data(result, material)
        var visible_mesh := chunk.get_node("VoxelMesh") as MeshInstance3D
        var shadow_proxy := chunk.get_node("TerrainShadowProxy") as MeshInstance3D
        assert(visible_mesh != null and visible_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
            "Visible colour mesh should not cast shadows at LOD%d" % lod)
        assert(shadow_proxy != null and shadow_proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
            "Expected invisible shadow-only proxy at LOD%d" % lod)
        var proxy_vertices: PackedVector3Array = shadow_proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
        var expected_count: int = full_count if lod <= 3 else top_count
        assert(proxy_vertices.size() == expected_count,
            "LOD%d shadow proxy must use expected terrain geometry: wanted %d vertices, got %d" % [lod, expected_count, proxy_vertices.size()])
        chunk.free()

    print("Terrain blend and LOD shadow proxy smoke test passed.")
    quit(0)
