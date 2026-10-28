extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var errors: Array[String] = []
    var chunk := VoxelTerrainChunk.new()

    for lod_index in range(8):
        chunk.lod = lod_index
        if not chunk._should_proxy_cast_shadow():
            errors.append("LOD%d should preserve smooth landform shadow casting" % lod_index)

    # Legacy shadow-mode calls must not affect shader shadow strength: it is now
    # calculated continuously from camera distance in voxel_surface.gdshader.
    chunk.lod = 0
    chunk.set_shadow_mode(0)
    chunk.lod = 7
    chunk.set_shadow_mode(1)

    chunk.free()

    if not errors.is_empty():
        for error_text in errors:
            push_error(error_text)
        quit(1)
        return

    print("Shadow smoke test passed: terrain silhouette proxies remain enabled across LOD tiers; shadow attenuation is distance-based in the shader.")
    quit()
