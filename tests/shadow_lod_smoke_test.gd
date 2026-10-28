extends SceneTree

const EXPECTED_SHADOW_STRENGTHS: Array[float] = [
    0.20, 0.15, 0.10, 0.05, 0.0, 0.0, 0.0, 0.0
]


func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var errors: Array[String] = []
    var chunk := VoxelTerrainChunk.new()

    for lod_index in range(EXPECTED_SHADOW_STRENGTHS.size()):
        chunk.lod = lod_index
        var actual_strength: float = chunk._shadow_receive_strength()
        var expected_strength: float = EXPECTED_SHADOW_STRENGTHS[lod_index]
        if absf(actual_strength - expected_strength) > 0.0001:
            errors.append("LOD%d shadow strength expected %.2f, got %.3f" % [
                lod_index, expected_strength, actual_strength
            ])

        # Smooth terrain proxies must remain eligible to cast landform silhouettes,
        # even though visible voxel meshes never cast individual voxel shadows.
        if not chunk._should_proxy_cast_shadow():
            errors.append("LOD%d should preserve smooth terrain silhouette casting" % lod_index)

    # The legacy shadow-mode hook must not override the specified per-LOD profile.
    chunk.lod = 0
    chunk.set_shadow_mode(0)
    if absf(chunk._shadow_receive_strength() - EXPECTED_SHADOW_STRENGTHS[0]) > 0.0001:
        errors.append("Legacy shadow mode changed the fixed LOD0 shadow profile")
    chunk.lod = 4
    chunk.set_shadow_mode(1)
    if absf(chunk._shadow_receive_strength() - EXPECTED_SHADOW_STRENGTHS[4]) > 0.0001:
        errors.append("Legacy shadow mode changed the LOD4 no-receive-shadow profile")

    chunk.free()

    if not errors.is_empty():
        for error in errors:
            push_error(error)
        quit(1)
        return

    print("Shadow LOD smoke test passed: strengths are 20/15/10/5/0/0/0/0 and smooth terrain casters remain enabled.")
    quit()
