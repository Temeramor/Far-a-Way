extends "res://scripts/world/terrain_generator.gd"
class_name VoxelTerrainGenerator

# This first prototype keeps the existing height field and distant terrain as a
# fallback, then streams a real voxel surface around the player. It deliberately
# does not create grass or flowers.
const VOXEL_CHUNK_SIZE: float = 16.0
const VOXEL_SURFACE_OFFSET: float = 0.002
const SIDE_POSITIVE_X: int = 0
const SIDE_NEGATIVE_X: int = 1
const SIDE_POSITIVE_Z: int = 2
const SIDE_NEGATIVE_Z: int = 3

@export_group("Voxel Terrain")
@export_range(0.0625, 0.1, 0.0375, "suffix:m") var voxel_size: float = 0.1
@export_range(1, 3, 1) var voxel_chunk_radius: int = 1

var _voxel_cell_size: float = 0.1
var _voxel_cells_per_chunk: int = 160
var _voxel_chunks: Dictionary = {}
var _voxel_center_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _voxel_update_running: bool = false
var _voxel_stream_generation_id: int = 0
var _voxel_material: StandardMaterial3D


func _process(_delta: float) -> void:
    if not _terrain_ready:
        return

    var camera: Camera3D = get_viewport().get_camera_3d()
    if camera == null:
        return

    var focus := Vector2(camera.global_position.x, camera.global_position.z)
    if not _collision_update_running and _last_collision_focus.distance_to(focus) >= COLLISION_LOD_UPDATE_DISTANCE:
        _update_collision_lod(focus)

    if _voxel_update_running:
        return

    var next_center := _chunk_coordinate_at(camera.global_position)
    if next_center != _voxel_center_chunk:
        _voxel_center_chunk = next_center
        _voxel_stream_generation_id += 1
        _stream_voxel_chunks.call_deferred(next_center, _voxel_stream_generation_id)


func generate(new_seed: int = 1337) -> void:
    _terrain_ready = false
    _generation_id += 1
    _voxel_stream_generation_id += 1
    _voxel_update_running = false
    _voxel_chunks.clear()
    _voxel_center_chunk = Vector2i(2147483647, 2147483647)
    var request_id: int = _generation_id

    world_seed = new_seed
    generation_started.emit(world_seed)
    generation_progress.emit(world_seed, 0.01, "Подготавливаем воксельный рельеф...")

    await _remove_previous_terrain()
    if request_id != _generation_id:
        return

    _voxel_cells_per_chunk = maxi(1, roundi(VOXEL_CHUNK_SIZE / maxf(voxel_size, 0.01)))
    # Make the effective size divide a chunk exactly, so adjacent chunks share
    # identical grid coordinates even when a custom voxel_size was entered.
    _voxel_cell_size = VOXEL_CHUNK_SIZE / float(_voxel_cells_per_chunk)

    _create_noise_fields(world_seed)
    _create_mountain_ranges(world_seed)
    _sample_spacing = world_size / float(resolution)

    # Reuse the same deterministic height field as the original generator.
    var row_width: int = resolution + 1
    heights.resize(row_width * row_width)
    var half_size: float = world_size * 0.5
    for z in range(row_width):
        if request_id != _generation_id:
            return
        var world_z: float = float(z) * _sample_spacing - half_size
        var row_offset: int = z * row_width
        for x in range(row_width):
            var world_x: float = float(x) * _sample_spacing - half_size
            heights[row_offset + x] = _height_at(world_x, world_z)
        if z % 4 == 0:
            var progress: float = 0.03 + 0.43 * float(z + 1) / float(row_width)
            generation_progress.emit(world_seed, progress, "Формируем высотную карту по сиду...")
            await get_tree().process_frame

    if request_id != _generation_id:
        return

    _terrain_root = Node3D.new()
    _terrain_root.name = "ProceduralTerrain"
    add_child(_terrain_root)

    # Keep the original terrain shader for the far-field fallback. The near-field
    # voxel surface is an additional, independently streamed layer.
    var terrain_shader := load("res://shaders/procedural_terrain.gdshader") as Shader
    var terrain_material := ShaderMaterial.new()
    terrain_material.shader = terrain_shader
    var shader_seed: int = abs(world_seed % 2147483647)
    terrain_material.set_shader_parameter("seed_offset", float(shader_seed % 65536))
    terrain_material.set_shader_parameter("seed_offset_high", float(int(floor(float(shader_seed) / 65536.0))))
    terrain_material.set_shader_parameter("pixel_size", 1.15)
    terrain_material.set_shader_parameter("rock_transition_start", 0.30)
    terrain_material.set_shader_parameter("rock_transition_end", 0.48)

    _voxel_material = StandardMaterial3D.new()
    _voxel_material.vertex_color_use_as_albedo = true
    _voxel_material.roughness = 1.0
    _voxel_material.metallic = 0.0
    _voxel_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
    _voxel_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

    var camera: Camera3D = get_viewport().get_camera_3d()
    _initial_collision_focus = Vector2.ZERO
    if camera != null:
        _initial_collision_focus = Vector2(camera.global_position.x, camera.global_position.z)
    _last_collision_focus = _initial_collision_focus
    _collision_chunks.clear()

    # Retain the existing chunked terrain and its robust distant collision/LOD.
    var chunks_per_axis: int = int(float(resolution) / float(CHUNK_CELLS))
    var total_chunks: int = chunks_per_axis * chunks_per_axis
    var render_lods: Dictionary = {
        900.0: _build_render_lod_indices(2),
        1800.0: _build_render_lod_indices(4),
        3000.0: _build_render_lod_indices(8)
    }
    var finished_chunks: int = 0
    generation_progress.emit(world_seed, 0.49, "Строим дальний рельеф и физику...")

    for chunk_z in range(chunks_per_axis):
        for chunk_x in range(chunks_per_axis):
            if request_id != _generation_id:
                return
            _create_chunk(chunk_x, chunk_z, terrain_material, render_lods)
            finished_chunks += 1
            if finished_chunks % 2 == 0:
                var mesh_progress: float = 0.49 + 0.39 * float(finished_chunks) / float(total_chunks)
                generation_progress.emit(world_seed, mesh_progress, "Собираем дальний рельеф...")
                await get_tree().process_frame

    if request_id != _generation_id:
        return

    generation_progress.emit(world_seed, 0.90, "Создаём цветные воксели вокруг игрока...")
    var center := Vector2i.ZERO
    if camera != null:
        center = _chunk_coordinate_at(camera.global_position)
    _voxel_center_chunk = center
    _voxel_stream_generation_id += 1
    var stream_id: int = _voxel_stream_generation_id
    await _stream_voxel_chunks(center, stream_id)

    if request_id != _generation_id:
        return

    await get_tree().process_frame
    if request_id != _generation_id:
        return
    _terrain_ready = true
    generation_progress.emit(world_seed, 1.0, "Воксельный прототип готов.")
    generation_finished.emit(world_seed)


func _chunk_coordinate_at(position: Vector3) -> Vector2i:
    var half_size: float = world_size * 0.5
    var chunks_per_axis: int = maxi(1, ceili(world_size / VOXEL_CHUNK_SIZE))
    var chunk_x: int = clampi(int(floor((position.x + half_size) / VOXEL_CHUNK_SIZE)), 0, chunks_per_axis - 1)
    var chunk_z: int = clampi(int(floor((position.z + half_size) / VOXEL_CHUNK_SIZE)), 0, chunks_per_axis - 1)
    return Vector2i(chunk_x, chunk_z)


func _stream_voxel_chunks(center: Vector2i, stream_id: int) -> void:
    if _voxel_update_running or stream_id != _voxel_stream_generation_id:
        return
    _voxel_update_running = true

    var wanted: Dictionary = {}
    var chunks_per_axis: int = maxi(1, ceili(world_size / VOXEL_CHUNK_SIZE))
    for chunk_z in range(center.y - voxel_chunk_radius, center.y + voxel_chunk_radius + 1):
        for chunk_x in range(center.x - voxel_chunk_radius, center.x + voxel_chunk_radius + 1):
            if chunk_x < 0 or chunk_z < 0 or chunk_x >= chunks_per_axis or chunk_z >= chunks_per_axis:
                continue
            var key := Vector2i(chunk_x, chunk_z)
            wanted[key] = true
            if _voxel_chunks.has(key):
                continue

            var chunk_root: Node3D = await _build_voxel_chunk(chunk_x, chunk_z, stream_id)
            if stream_id != _voxel_stream_generation_id:
                if is_instance_valid(chunk_root):
                    chunk_root.queue_free()
                return
            if chunk_root == null:
                continue
            _terrain_root.add_child(chunk_root)
            _voxel_chunks[key] = chunk_root
            await get_tree().process_frame

    if stream_id != _voxel_stream_generation_id:
        return

    var obsolete: Array[Vector2i] = []
    for key_variant in _voxel_chunks.keys():
        var key: Vector2i = key_variant
        if not wanted.has(key):
            var old_chunk := _voxel_chunks[key] as Node3D
            if is_instance_valid(old_chunk):
                old_chunk.queue_free()
            obsolete.append(key)
    for key in obsolete:
        _voxel_chunks.erase(key)

    _voxel_update_running = false


func _build_voxel_chunk(chunk_x: int, chunk_z: int, stream_id: int) -> Node3D:
    var cells: int = _voxel_cells_per_chunk
    var cell_count: int = cells * cells
    var heights_in_chunk := PackedFloat32Array()
    var colors_in_chunk := PackedColorArray()
    heights_in_chunk.resize(cell_count)
    colors_in_chunk.resize(cell_count)

    var half_size: float = world_size * 0.5
    var origin_x: float = float(chunk_x) * VOXEL_CHUNK_SIZE - half_size
    var origin_z: float = float(chunk_z) * VOXEL_CHUNK_SIZE - half_size

    # Sample once per voxel cell. Heights are quantized upward so the voxel faces
    # sit just above the original triangle surface rather than z-fighting with it.
    for z in range(cells):
        var world_z: float = origin_z + (float(z) + 0.5) * _voxel_cell_size
        for x in range(cells):
            var world_x: float = origin_x + (float(x) + 0.5) * _voxel_cell_size
            var index: int = z * cells + x
            var source_height: float = _source_mesh_height_at_world(world_x, world_z)
            heights_in_chunk[index] = ceil(source_height / _voxel_cell_size) * _voxel_cell_size + VOXEL_SURFACE_OFFSET
            colors_in_chunk[index] = _voxel_color_at_world(world_x, world_z, source_height)
        if z % 32 == 0:
            await get_tree().process_frame
            if stream_id != _voxel_stream_generation_id:
                return null

    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    # Reserve space for the flat top quads before adding cliff faces.
    vertices.resize(0)
    normals.resize(0)
    colors.resize(0)
    indices.resize(0)

    for z in range(cells):
        var z0: float = float(z) * _voxel_cell_size
        var z1: float = z0 + _voxel_cell_size
        var world_z0: float = origin_z + z0
        for x in range(cells):
            var index: int = z * cells + x
            var x0: float = float(x) * _voxel_cell_size
            var x1: float = x0 + _voxel_cell_size
            var world_x0: float = origin_x + x0
            var top_height: float = heights_in_chunk[index]
            _append_voxel_face(
                vertices, normals, colors, indices,
                Vector3(x0, top_height, z0),
                Vector3(x1, top_height, z0),
                Vector3(x0, top_height, z1),
                Vector3(x1, top_height, z1),
                colors_in_chunk[index],
                Vector3.UP
            )

            # Each horizontal neighbor pair is processed once. Vertical walls are
            # split into voxel-sized bands, preserving the block pattern on cliffs.
            var neighbor_world_x: float = world_x0 + 1.5 * _voxel_cell_size
            var neighbor_world_z: float = world_z0 + 0.5 * _voxel_cell_size
            var neighbor_height_x: float
            var neighbor_color_x: Color
            if x + 1 < cells:
                neighbor_height_x = heights_in_chunk[index + 1]
                neighbor_color_x = colors_in_chunk[index + 1]
            elif world_x0 + _voxel_cell_size < half_size - 0.0001:
                neighbor_height_x = _quantized_height_at_world(neighbor_world_x, neighbor_world_z)
                neighbor_color_x = _voxel_color_at_world(
                    neighbor_world_x, neighbor_world_z, _source_mesh_height_at_world(neighbor_world_x, neighbor_world_z)
                )
            else:
                neighbor_height_x = top_height
                neighbor_color_x = colors_in_chunk[index]

            if absf(top_height - neighbor_height_x) > _voxel_cell_size * 0.5:
                if top_height > neighbor_height_x:
                    _append_vertical_wall(
                        vertices, normals, colors, indices, x0, x1, z0, z1,
                        neighbor_height_x, top_height, SIDE_POSITIVE_X, colors_in_chunk[index].darkened(0.12)
                    )
                else:
                    _append_vertical_wall(
                        vertices, normals, colors, indices, x0, x1, z0, z1,
                        top_height, neighbor_height_x, SIDE_NEGATIVE_X, neighbor_color_x.darkened(0.12)
                    )

            var neighbor_world_x_z: float = world_x0 + 0.5 * _voxel_cell_size
            var neighbor_world_z_z: float = world_z0 + 1.5 * _voxel_cell_size
            var neighbor_height_z: float
            var neighbor_color_z: Color
            if z + 1 < cells:
                neighbor_height_z = heights_in_chunk[index + cells]
                neighbor_color_z = colors_in_chunk[index + cells]
            elif world_z0 + _voxel_cell_size < half_size - 0.0001:
                neighbor_height_z = _quantized_height_at_world(neighbor_world_x_z, neighbor_world_z_z)
                neighbor_color_z = _voxel_color_at_world(
                    neighbor_world_x_z, neighbor_world_z_z, _source_mesh_height_at_world(neighbor_world_x_z, neighbor_world_z_z)
                )
            else:
                neighbor_height_z = top_height
                neighbor_color_z = colors_in_chunk[index]

            if absf(top_height - neighbor_height_z) > _voxel_cell_size * 0.5:
                if top_height > neighbor_height_z:
                    _append_vertical_wall(
                        vertices, normals, colors, indices, x0, x1, z0, z1,
                        neighbor_height_z, top_height, SIDE_POSITIVE_Z, colors_in_chunk[index].darkened(0.12)
                    )
                else:
                    _append_vertical_wall(
                        vertices, normals, colors, indices, x0, x1, z0, z1,
                        top_height, neighbor_height_z, SIDE_NEGATIVE_Z, neighbor_color_z.darkened(0.12)
                    )
        if z % 32 == 0:
            await get_tree().process_frame
            if stream_id != _voxel_stream_generation_id:
                return null

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var voxel_mesh := ArrayMesh.new()
    voxel_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    var root := Node3D.new()
    root.name = "VoxelChunk_%03d_%03d" % [chunk_x, chunk_z]
    root.position = Vector3(origin_x, 0.0, origin_z)

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "VoxelSurface"
    mesh_instance.mesh = voxel_mesh
    mesh_instance.material_override = _voxel_material
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    root.add_child(mesh_instance)

    var collision_body := StaticBody3D.new()
    collision_body.name = "VoxelCollision"
    collision_body.collision_layer = 1
    collision_body.collision_mask = 1
    var collision_shape := CollisionShape3D.new()
    collision_shape.shape = voxel_mesh.create_trimesh_shape()
    collision_body.add_child(collision_shape)
    root.add_child(collision_body)

    return root


func _source_mesh_height_at_world(world_x: float, world_z: float) -> float:
    # Match the triangle diagonal used by TerrainGenerator._create_chunk exactly.
    if heights.is_empty():
        return 24.0

    var half_size: float = world_size * 0.5
    var fx: float = clampf((world_x + half_size) / _sample_spacing, 0.0, float(resolution))
    var fz: float = clampf((world_z + half_size) / _sample_spacing, 0.0, float(resolution))
    var x0: int = mini(int(floor(fx)), resolution - 1)
    var z0: int = mini(int(floor(fz)), resolution - 1)
    var tx: float = clampf(fx - float(x0), 0.0, 1.0)
    var tz: float = clampf(fz - float(z0), 0.0, 1.0)
    var row_width: int = resolution + 1
    var h00: float = heights[z0 * row_width + x0]
    var h10: float = heights[z0 * row_width + x0 + 1]
    var h01: float = heights[(z0 + 1) * row_width + x0]
    var h11: float = heights[(z0 + 1) * row_width + x0 + 1]

    if tx + tz <= 1.0:
        return h00 + tx * (h10 - h00) + tz * (h01 - h00)
    return h10 * (1.0 - tz) + h11 * (tx + tz - 1.0) + h01 * (1.0 - tx)


func _quantized_height_at_world(world_x: float, world_z: float) -> float:
    var source_height: float = _source_mesh_height_at_world(world_x, world_z)
    return ceil(source_height / _voxel_cell_size) * _voxel_cell_size + VOXEL_SURFACE_OFFSET


func _voxel_color_at_world(world_x: float, world_z: float, height: float) -> Color:
    var surface: Vector3 = surface_sample_at_world(world_x, world_z)
    var slope: float = Vector2(surface.y, surface.z).length()
    var grass := Color(0.29, 0.43, 0.20, 1.0)
    var earth := Color(0.43, 0.35, 0.23, 1.0)
    var rock := Color(0.48, 0.49, 0.47, 1.0)
    var high_rock := Color(0.64, 0.65, 0.63, 1.0)

    var dry_amount: float = clampf((0.10 - _macro_noise.get_noise_2d(world_x, world_z)) * 0.18, 0.0, 0.12)
    var land_color: Color = grass.lerp(earth, dry_amount)
    var rock_amount: float = maxf(
        clampf((slope - 0.42) / 1.05, 0.0, 1.0),
        clampf((height - 560.0) / 440.0, 0.0, 1.0)
    )
    var color: Color = land_color.lerp(rock, rock_amount).lerp(high_rock, clampf((height - 1050.0) / 400.0, 0.0, 1.0))

    # Stable, subtle per-cell variation: each voxel keeps its own color for a given seed.
    var grid_x: int = int(floor(world_x / _voxel_cell_size))
    var grid_z: int = int(floor(world_z / _voxel_cell_size))
    var hash_value: int = posmod(
        grid_x * 73856093 + grid_z * 19349663 + world_seed * 83492791,
        2147483647
    )
    var variant: float = float(posmod(hash_value, 1000)) / 999.0
    var brightness: float = lerpf(0.88, 1.10, variant)
    return Color(
        clampf(color.r * brightness, 0.0, 1.0),
        clampf(color.g * brightness, 0.0, 1.0),
        clampf(color.b * brightness, 0.0, 1.0),
        1.0
    )


func _append_voxel_face(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    d: Vector3,
    color: Color,
    normal: Vector3
) -> void:
    var first_vertex: int = vertices.size()
    vertices.append(a)
    vertices.append(b)
    vertices.append(c)
    vertices.append(d)
    normals.append(normal)
    normals.append(normal)
    normals.append(normal)
    normals.append(normal)
    colors.append(color)
    colors.append(color)
    colors.append(color)
    colors.append(color)
    # Keep the same clockwise winding as the original terrain meshes in Godot.
    indices.append(first_vertex)
    indices.append(first_vertex + 1)
    indices.append(first_vertex + 2)
    indices.append(first_vertex + 1)
    indices.append(first_vertex + 3)
    indices.append(first_vertex + 2)


func _append_vertical_wall(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    x0: float,
    x1: float,
    z0: float,
    z1: float,
    low_height: float,
    high_height: float,
    side: int,
    color: Color
) -> void:
    var y: float = low_height
    var wall_normal: Vector3
    match side:
        SIDE_POSITIVE_X:
            wall_normal = Vector3.RIGHT
        SIDE_NEGATIVE_X:
            wall_normal = Vector3.LEFT
        SIDE_POSITIVE_Z:
            wall_normal = Vector3.BACK
        _:
            wall_normal = Vector3.FORWARD

    while y < high_height - 0.0001:
        var next_y: float = minf(y + _voxel_cell_size, high_height)
        var a: Vector3
        var b: Vector3
        var c: Vector3
        var d: Vector3
        match side:
            SIDE_POSITIVE_X:
                a = Vector3(x1, y, z0)
                b = Vector3(x1, next_y, z0)
                c = Vector3(x1, y, z1)
                d = Vector3(x1, next_y, z1)
            SIDE_NEGATIVE_X:
                a = Vector3(x0, y, z1)
                b = Vector3(x0, next_y, z1)
                c = Vector3(x0, y, z0)
                d = Vector3(x0, next_y, z0)
            SIDE_POSITIVE_Z:
                a = Vector3(x1, y, z1)
                b = Vector3(x1, next_y, z1)
                c = Vector3(x0, y, z1)
                d = Vector3(x0, next_y, z1)
            _:
                a = Vector3(x0, y, z0)
                b = Vector3(x0, next_y, z0)
                c = Vector3(x1, y, z0)
                d = Vector3(x1, next_y, z0)
        _append_voxel_face(vertices, normals, colors, indices, a, b, c, d, color, wall_normal)
        y = next_y


func set_weather(mode: int) -> void:
    # Weather still controls the original sky; this prototype intentionally has no plants.
    _weather_mode = clampi(mode, 0, 2)
