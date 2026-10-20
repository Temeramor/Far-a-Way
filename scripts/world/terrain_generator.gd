extends Node3D
class_name TerrainGenerator

signal generation_started(seed_value: int)
signal generation_progress(seed_value: int, progress: float, status: String)
signal generation_finished(seed_value: int)

const CHUNK_CELLS: int = 128
const COLLISION_NEAR_STEP: int = 1
const COLLISION_MID_STEP: int = 2
const COLLISION_FAR_STEP: int = 4
const COLLISION_LOD_UPDATE_DISTANCE: float = 256.0
const MIN_TERRAIN_HEIGHT: float = -80.0
const MAX_TERRAIN_HEIGHT: float = 1600.0

@export_group("World")
@export var world_size: float = 10000.0
@export_range(1024, 2048, 1024) var resolution: int = 2048
@export var world_seed: int = 1337

var heights: PackedFloat32Array = PackedFloat32Array()
var _generation_id: int = 0
var _sample_spacing: float = 1.0
var _terrain_root: Node3D
var _grass_field: Node3D
var _weather_mode: int = 1
var _collision_chunks: Array[Dictionary] = []
var _terrain_ready: bool = false
var _collision_update_running: bool = false
var _initial_collision_focus: Vector2 = Vector2.ZERO
var _last_collision_focus: Vector2 = Vector2(INF, INF)
# Cached mountain-segment data avoids allocating Vectors and performing Dictionary lookups
# for every sampled point in the 2049 x 2049 height field.
var _mountain_starts: Array[Vector2] = []
var _mountain_deltas: Array[Vector2] = []
var _mountain_lengths_squared: Array[float] = []
var _mountain_widths: Array[float] = []
var _mountain_heights: Array[float] = []
var _mountain_phases: Array[float] = []
var _macro_noise: FastNoiseLite
var _hill_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _micro_ridge_noise: FastNoiseLite


func _process(_delta: float) -> void:
    if not _terrain_ready or _collision_update_running:
        return
    var camera: Camera3D = get_viewport().get_camera_3d()
    if camera == null:
        return
    var focus := Vector2(camera.global_position.x, camera.global_position.z)
    if _last_collision_focus.distance_to(focus) >= COLLISION_LOD_UPDATE_DISTANCE:
        _update_collision_lod(focus)


func generate(new_seed: int = 1337) -> void:
    _terrain_ready = false
    _generation_id += 1
    var request_id: int = _generation_id
    world_seed = new_seed
    generation_started.emit(world_seed)
    generation_progress.emit(world_seed, 0.01, "Подготавливаем процедурный рельеф...")

    await _remove_previous_terrain()
    if request_id != _generation_id:
        return

    _create_noise_fields(world_seed)
    _create_mountain_ranges(world_seed)
    _sample_spacing = world_size / float(resolution)

    # A sampled height field is the single source for mesh vertices, collision and grass placement.
    # It gives every terrain chunk identical border heights and keeps the generation deterministic.
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
            generation_progress.emit(world_seed, progress, "Формируем горные хребты, гребни и склоны...")
            await get_tree().process_frame

    if request_id != _generation_id:
        return

    _terrain_root = Node3D.new()
    _terrain_root.name = "ProceduralTerrain"
    add_child(_terrain_root)

    var terrain_shader := load("res://shaders/procedural_terrain.gdshader") as Shader
    var terrain_material := ShaderMaterial.new()
    terrain_material.shader = terrain_shader
    # Keep both parts of the seed within exact float-integer ranges. The shader mixes
    # them before hashing, avoiding large float offsets that can create visible bands.
    var shader_seed: int = abs(world_seed % 2147483647)
    terrain_material.set_shader_parameter("seed_offset", float(shader_seed % 65536))
    terrain_material.set_shader_parameter("seed_offset_high", float(int(floor(float(shader_seed) / 65536.0))))
    terrain_material.set_shader_parameter("pixel_size", 0.2875)
    terrain_material.set_shader_parameter("rock_transition_start", 0.30)
    terrain_material.set_shader_parameter("rock_transition_end", 0.48)

    var camera: Camera3D = get_viewport().get_camera_3d()
    _initial_collision_focus = Vector2.ZERO
    if camera != null:
        _initial_collision_focus = Vector2(camera.global_position.x, camera.global_position.z)
    _last_collision_focus = _initial_collision_focus
    _collision_chunks.clear()

    var chunks_per_axis: int = int(float(resolution) / float(CHUNK_CELLS))
    var total_chunks: int = chunks_per_axis * chunks_per_axis
    # ArrayMesh LOD uses the same vertex buffer but progressively fewer triangles.
    # Boundary strips retain every edge sample at each level to avoid cracks between
    # adjacent chunks when their automatically-selected LODs differ.
    var render_lods: Dictionary = {
        900.0: _build_render_lod_indices(2),
        1800.0: _build_render_lod_indices(4),
        3000.0: _build_render_lod_indices(8)
    }
    var finished_chunks: int = 0
    generation_progress.emit(world_seed, 0.49, "Строим геометрию ландшафта и физику...")

    for chunk_z in range(chunks_per_axis):
        for chunk_x in range(chunks_per_axis):
            if request_id != _generation_id:
                return
            _create_chunk(chunk_x, chunk_z, terrain_material, render_lods)
            finished_chunks += 1
            if finished_chunks % 2 == 0:
                var mesh_progress: float = 0.49 + 0.39 * float(finished_chunks) / float(total_chunks)
                generation_progress.emit(world_seed, mesh_progress, "Собираем детализированные склоны и коллизии...")
                await get_tree().process_frame

    if request_id != _generation_id:
        return

    generation_progress.emit(world_seed, 0.91, "Размещаем процедурную траву...")
    var grass_scene := load("res://assets/terrain/grass/GrassField.tscn") as PackedScene
    if grass_scene != null:
        _grass_field = grass_scene.instantiate() as Node3D
        _grass_field.name = "ProceduralGrassField"
        _grass_field.call("configure", self, world_seed)
        add_child(_grass_field)
        _grass_field.call("set_weather", _weather_mode)

    await get_tree().process_frame
    if request_id != _generation_id:
        return
    _terrain_ready = true
    generation_progress.emit(world_seed, 1.0, "Мир готов.")
    generation_finished.emit(world_seed)


func set_weather(mode: int) -> void:
    _weather_mode = clampi(mode, 0, 2)
    if is_instance_valid(_grass_field):
        _grass_field.call("set_weather", _weather_mode)


func height_at_world(world_x: float, world_z: float) -> float:
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
    return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func surface_sample_at_world(world_x: float, world_z: float) -> Vector3:
    # Returns (height, dHeight/dX, dHeight/dZ) from the already-generated height map.
    # This avoids evaluating every procedural noise field five times for each grass blade.
    if heights.is_empty():
        return Vector3(24.0, 0.0, 0.0)

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
    var h_top: float = lerpf(h00, h10, tx)
    var h_bottom: float = lerpf(h01, h11, tx)
    var height: float = lerpf(h_top, h_bottom, tz)
    var slope_x: float = lerpf(h10 - h00, h11 - h01, tz) / _sample_spacing
    var slope_z: float = lerpf(h01 - h00, h11 - h10, tx) / _sample_spacing
    return Vector3(height, slope_x, slope_z)


func _create_noise_fields(seed_value: int) -> void:
    _macro_noise = _make_noise(seed_value + 101, 0.00028, 4, FastNoiseLite.FRACTAL_FBM)
    _hill_noise = _make_noise(seed_value + 307, 0.00115, 4, FastNoiseLite.FRACTAL_FBM)
    _detail_noise = _make_noise(seed_value + 503, 0.0048, 3, FastNoiseLite.FRACTAL_FBM)
    _ridge_noise = _make_noise(seed_value + 709, 0.00082, 5, FastNoiseLite.FRACTAL_RIDGED)
    _micro_ridge_noise = _make_noise(seed_value + 907, 0.0034, 3, FastNoiseLite.FRACTAL_RIDGED)


func _make_noise(seed_value: int, frequency_value: float, octave_count: int, fractal_mode: FastNoiseLite.FractalType) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = seed_value
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = frequency_value
    noise.fractal_type = fractal_mode
    noise.fractal_octaves = octave_count
    noise.fractal_lacunarity = 2.05
    noise.fractal_gain = 0.52
    return noise


func _create_mountain_ranges(seed_value: int) -> void:
    _mountain_starts.clear()
    _mountain_deltas.clear()
    _mountain_lengths_squared.clear()
    _mountain_widths.clear()
    _mountain_heights.clear()
    _mountain_phases.clear()
    var rng := RandomNumberGenerator.new()
    rng.seed = int(seed_value) + 17011

    for _range_index in range(3):
        var angle: float = rng.randf_range(0.0, PI)
        var direction := Vector2(cos(angle), sin(angle))
        var side := Vector2(-direction.y, direction.x)
        var center := Vector2(
            rng.randf_range(-world_size * 0.20, world_size * 0.20),
            rng.randf_range(-world_size * 0.20, world_size * 0.20)
        )
        var half_length: float = world_size * rng.randf_range(0.23, 0.34)
        var points: Array[Vector2] = [
            center - direction * half_length + side * rng.randf_range(-600.0, 600.0),
            center - direction * half_length * 0.34 + side * rng.randf_range(-1050.0, 1050.0),
            center + direction * half_length * 0.30 + side * rng.randf_range(-1050.0, 1050.0),
            center + direction * half_length + side * rng.randf_range(-600.0, 600.0)
        ]
        var range_height: float = rng.randf_range(850.0, 1320.0)
        var range_width: float = rng.randf_range(540.0, 930.0)
        var phase: float = rng.randf_range(0.0, TAU)
        for segment_index in range(points.size() - 1):
            var a: Vector2 = points[segment_index]
            var b: Vector2 = points[segment_index + 1]
            var delta: Vector2 = b - a
            _mountain_starts.append(a)
            _mountain_deltas.append(delta)
            _mountain_lengths_squared.append(maxf(delta.length_squared(), 0.001))
            _mountain_widths.append(range_width * rng.randf_range(0.88, 1.12))
            _mountain_heights.append(range_height * rng.randf_range(0.94, 1.06))
            _mountain_phases.append(phase + float(segment_index) * 1.7)

func _height_at(world_x: float, world_z: float) -> float:
    var macro: float = _macro_noise.get_noise_2d(world_x, world_z)
    var hills: float = _hill_noise.get_noise_2d(world_x, world_z)
    var detail: float = _detail_noise.get_noise_2d(world_x, world_z)
    var ridge_detail: float = (_ridge_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
    var micro_ridge: float = _micro_ridge_noise.get_noise_2d(world_x, world_z)

    var height: float = 26.0 + macro * 17.0 + hills * 10.0
    height += maxf(hills - 0.12, 0.0) * 18.0
    height += detail * 3.8

    var mountain_height: float = 0.0
    var point := Vector2(world_x, world_z)
    for segment_index in range(_mountain_starts.size()):
        var a: Vector2 = _mountain_starts[segment_index]
        var ab: Vector2 = _mountain_deltas[segment_index]
        var length_squared: float = _mountain_lengths_squared[segment_index]
        var along: float = clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
        var closest: Vector2 = a + ab * along
        var offset: Vector2 = point - closest
        var distance_squared: float = offset.length_squared()
        var width: float = _mountain_widths[segment_index]
        var broad_radius: float = width * 1.72
        # Outside this radius, both the foothill and crest masks are exactly zero.
        # Skip the square root and remaining profile calculations for such points.
        if distance_squared >= broad_radius * broad_radius:
            continue
        var distance: float = sqrt(distance_squared)
        var peak_height: float = _mountain_heights[segment_index]
        var phase: float = _mountain_phases[segment_index]
        var broad_mask: float = clampf(1.0 - distance / broad_radius, 0.0, 1.0)
        var cliff_mask: float = clampf(1.0 - distance / width, 0.0, 1.0)
        var crest_profile: float = 0.77 + 0.23 * absf(sin(along * PI * 2.1 + phase))
        var rough_profile: float = 0.79 + 0.21 * ridge_detail
        var foothills: float = pow(broad_mask, 1.28) * (peak_height * 0.39 + 75.0)
        var crest: float = pow(cliff_mask, 0.94) * peak_height * crest_profile * rough_profile
        mountain_height = maxf(mountain_height, maxf(foothills, crest))

    height += mountain_height
    if mountain_height > 1.0:
        var mountain_mask: float = clampf(mountain_height / 900.0, 0.0, 1.0)
        height += mountain_mask * (micro_ridge * 34.0 + detail * 22.0)

    var spawn_fade: float = 1.0 - _smoothstep(420.0, 1420.0, point.length())
    var spawn_height: float = 25.0 + macro * 3.0 + detail * 0.8
    height = lerpf(height, spawn_height, spawn_fade)
    return clampf(height, MIN_TERRAIN_HEIGHT, MAX_TERRAIN_HEIGHT)


func _create_chunk(chunk_x: int, chunk_z: int, material: ShaderMaterial, render_lods: Dictionary) -> void:
    var first_x: int = chunk_x * CHUNK_CELLS
    var first_z: int = chunk_z * CHUNK_CELLS
    var vertex_width: int = CHUNK_CELLS + 1
    var vertex_count: int = vertex_width * vertex_width
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    var row_width: int = resolution + 1

    for local_z in range(vertex_width):
        var global_z: int = first_z + local_z
        var z_world: float = float(local_z) * _sample_spacing
        var row_offset: int = global_z * row_width
        for local_x in range(vertex_width):
            var global_x: int = first_x + local_x
            var x_world: float = float(local_x) * _sample_spacing
            var index: int = local_z * vertex_width + local_x
            var height: float = heights[row_offset + global_x]
            vertices[index] = Vector3(x_world, height, z_world)

            var left_index: int = maxi(global_x - 1, 0)
            var right_index: int = mini(global_x + 1, resolution)
            var back_index: int = maxi(global_z - 1, 0)
            var front_index: int = mini(global_z + 1, resolution)
            var h_left: float = heights[row_offset + left_index]
            var h_right: float = heights[row_offset + right_index]
            var h_back: float = heights[back_index * row_width + global_x]
            var h_front: float = heights[front_index * row_width + global_x]
            normals[index] = Vector3(h_left - h_right, 2.0 * _sample_spacing, h_back - h_front).normalized()

    var indices := PackedInt32Array()
    indices.resize(CHUNK_CELLS * CHUNK_CELLS * 6)
    var index_cursor: int = 0
    for z in range(CHUNK_CELLS):
        for x in range(CHUNK_CELLS):
            var a: int = z * vertex_width + x
            var b: int = a + 1
            var c: int = a + vertex_width
            var d: int = c + 1
            # Godot treats clockwise triangles as front faces. The former reversed
            # winding exposed the underside, which also made the surface look inverted.
            indices[index_cursor] = a
            indices[index_cursor + 1] = b
            indices[index_cursor + 2] = c
            indices[index_cursor + 3] = b
            indices[index_cursor + 4] = d
            indices[index_cursor + 5] = c
            index_cursor += 6

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    var chunk_mesh := ArrayMesh.new()
    chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], render_lods)

    var half_size: float = world_size * 0.5
    var origin := Vector3(
        float(first_x) * _sample_spacing - half_size,
        0.0,
        float(first_z) * _sample_spacing - half_size
    )
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainMesh_%02d_%02d" % [chunk_x, chunk_z]
    mesh_instance.mesh = chunk_mesh
    mesh_instance.material_override = material
    mesh_instance.position = origin
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    _terrain_root.add_child(mesh_instance)

    var collision_body := StaticBody3D.new()
    collision_body.name = "TerrainCollision_%02d_%02d" % [chunk_x, chunk_z]
    collision_body.position = origin
    collision_body.collision_layer = 1
    collision_body.collision_mask = 1
    var collision_shape := CollisionShape3D.new()
    var collision_step: int = _collision_step_for_chunk(chunk_x, chunk_z, _initial_collision_focus)
    var concave := ConcavePolygonShape3D.new()
    concave.backface_collision = true
    concave.set_faces(_build_collision_faces(first_x, first_z, collision_step))
    collision_shape.shape = concave
    collision_body.add_child(collision_shape)
    _terrain_root.add_child(collision_body)
    _collision_chunks.append({
        "chunk_x": chunk_x,
        "chunk_z": chunk_z,
        "first_x": first_x,
        "first_z": first_z,
        "step": collision_step,
        "shape_node": collision_shape
    })


func _build_render_lod_indices(step: int) -> PackedInt32Array:
    # Only steps that divide CHUNK_CELLS are valid, and all used levels do.
    var stride: int = clampi(step, 2, CHUNK_CELLS)
    var n: int = CHUNK_CELLS
    var vertices_per_row: int = n + 1
    var indices: Array[int] = []

    # Coarse interior cells.
    for z in range(stride, n - stride, stride):
        for x in range(stride, n - stride, stride):
            _append_lod_quad(indices, Vector2i(x, z), stride, vertices_per_row)

    # Middle portions of the top and bottom borders. Every outer edge sample is used;
    # a short fan joins them to a coarse inner row.
    for x in range(stride, n - stride, stride):
        for j in range(stride):
            _append_lod_triangle(indices, Vector2i(x + j, 0), Vector2i(x + j + 1, 0), Vector2i(x + stride, stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(x, 0), Vector2i(x + stride, stride), Vector2i(x, stride), vertices_per_row)

        for j in range(stride):
            _append_lod_triangle(indices, Vector2i(x + j, n), Vector2i(x + j + 1, n), Vector2i(x, n - stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(x + stride, n), Vector2i(x, n - stride), Vector2i(x + stride, n - stride), vertices_per_row)

    # Middle portions of the left and right borders.
    for z in range(stride, n - stride, stride):
        for j in range(stride):
            _append_lod_triangle(indices, Vector2i(0, z + j), Vector2i(stride, z + stride), Vector2i(0, z + j + 1), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(0, z), Vector2i(stride, z), Vector2i(stride, z + stride), vertices_per_row)

        for j in range(stride):
            _append_lod_triangle(indices, Vector2i(n, z + j), Vector2i(n, z + j + 1), Vector2i(n - stride, z), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(n, z + stride), Vector2i(n - stride, z + stride), Vector2i(n - stride, z), vertices_per_row)

    # Corner fans keep the full-resolution samples along both exposed edges.
    for j in range(stride):
        _append_lod_triangle(indices, Vector2i(j, 0), Vector2i(j + 1, 0), Vector2i(stride, stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(0, j), Vector2i(stride, stride), Vector2i(0, j + 1), vertices_per_row)

        _append_lod_triangle(indices, Vector2i(n - stride + j, 0), Vector2i(n - stride + j + 1, 0), Vector2i(n - stride, stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(n, j), Vector2i(n, j + 1), Vector2i(n - stride, stride), vertices_per_row)

        _append_lod_triangle(indices, Vector2i(j, n), Vector2i(j + 1, n), Vector2i(stride, n - stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(0, n - stride + j), Vector2i(stride, n - stride), Vector2i(0, n - stride + j + 1), vertices_per_row)

        _append_lod_triangle(indices, Vector2i(n - stride + j, n), Vector2i(n - stride + j + 1, n), Vector2i(n - stride, n - stride), vertices_per_row)
        _append_lod_triangle(indices, Vector2i(n, n - stride + j), Vector2i(n, n - stride + j + 1), Vector2i(n - stride, n - stride), vertices_per_row)

    return PackedInt32Array(indices)


func _append_lod_quad(indices: Array[int], top_left: Vector2i, step: int, vertices_per_row: int) -> void:
    var a := top_left
    var b := Vector2i(top_left.x + step, top_left.y)
    var c := Vector2i(top_left.x, top_left.y + step)
    var d := Vector2i(top_left.x + step, top_left.y + step)
    _append_lod_triangle(indices, a, b, c, vertices_per_row)
    _append_lod_triangle(indices, b, d, c, vertices_per_row)


func _append_lod_triangle(indices: Array[int], a: Vector2i, b: Vector2i, c: Vector2i, vertices_per_row: int) -> void:
    # Godot uses clockwise front faces. Normalize winding so the helper can safely
    # triangulate each of the four border orientations with the same code.
    var determinant: int = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    if determinant == 0:
        return
    if determinant < 0:
        var temp: Vector2i = b
        b = c
        c = temp
    indices.append(a.y * vertices_per_row + a.x)
    indices.append(b.y * vertices_per_row + b.x)
    indices.append(c.y * vertices_per_row + c.x)


func _collision_step_for_chunk(chunk_x: int, chunk_z: int, focus: Vector2) -> int:
    var half_size: float = world_size * 0.5
    var chunk_width: float = float(CHUNK_CELLS) * _sample_spacing
    var min_x: float = float(chunk_x) * chunk_width - half_size
    var min_z: float = float(chunk_z) * chunk_width - half_size
    var max_x: float = min_x + chunk_width
    var max_z: float = min_z + chunk_width
    var dx: float = 0.0
    var dz: float = 0.0
    if focus.x < min_x:
        dx = min_x - focus.x
    elif focus.x > max_x:
        dx = focus.x - max_x
    if focus.y < min_z:
        dz = min_z - focus.y
    elif focus.y > max_z:
        dz = focus.y - max_z
    var distance_to_chunk: float = Vector2(dx, dz).length()
    if distance_to_chunk <= 700.0:
        return COLLISION_NEAR_STEP
    if distance_to_chunk <= 1900.0:
        return COLLISION_MID_STEP
    return COLLISION_FAR_STEP


func _update_collision_lod(focus: Vector2) -> void:
    if _collision_update_running or not _terrain_ready:
        return
    _collision_update_running = true
    var changed_count: int = 0
    for i in range(_collision_chunks.size()):
        if not _terrain_ready:
            _collision_update_running = false
            return
        var record: Dictionary = _collision_chunks[i]
        var desired_step: int = _collision_step_for_chunk(int(record["chunk_x"]), int(record["chunk_z"]), focus)
        if desired_step == int(record["step"]):
            continue
        var shape := ConcavePolygonShape3D.new()
        shape.backface_collision = true
        shape.set_faces(_build_collision_faces(int(record["first_x"]), int(record["first_z"]), desired_step))
        var shape_node := record["shape_node"] as CollisionShape3D
        if is_instance_valid(shape_node):
            shape_node.shape = shape
            _collision_chunks[i]["step"] = desired_step
            changed_count += 1
        # A near collision mesh may contain tens of thousands of triangles.
        # Spread shape rebuilds over separate frames to prevent movement hitching.
        if changed_count > 0:
            await get_tree().process_frame
    _last_collision_focus = focus
    _collision_update_running = false


func _build_collision_faces(first_x: int, first_z: int, collision_step: int) -> PackedVector3Array:
    var faces := PackedVector3Array()
    var row_width: int = resolution + 1
    var sample_count: int = int(float(CHUNK_CELLS) / float(collision_step))
    faces.resize(sample_count * sample_count * 6)
    var cursor: int = 0

    for cell_z in range(sample_count):
        var local_z0: int = cell_z * collision_step
        var local_z1: int = local_z0 + collision_step
        var global_z0: int = first_z + local_z0
        var global_z1: int = first_z + local_z1
        for cell_x in range(sample_count):
            var local_x0: int = cell_x * collision_step
            var local_x1: int = local_x0 + collision_step
            var global_x0: int = first_x + local_x0
            var global_x1: int = first_x + local_x1
            var h_a: float = heights[global_z0 * row_width + global_x0]
            var h_b: float = heights[global_z0 * row_width + global_x1]
            var h_c: float = heights[global_z1 * row_width + global_x0]
            var h_d: float = heights[global_z1 * row_width + global_x1]
            var a := Vector3(float(local_x0) * _sample_spacing, h_a, float(local_z0) * _sample_spacing)
            var b := Vector3(float(local_x1) * _sample_spacing, h_b, float(local_z0) * _sample_spacing)
            var c := Vector3(float(local_x0) * _sample_spacing, h_c, float(local_z1) * _sample_spacing)
            var d := Vector3(float(local_x1) * _sample_spacing, h_d, float(local_z1) * _sample_spacing)
            # Keep collision triangle winding in sync with the visible top face.
            faces[cursor] = a
            faces[cursor + 1] = b
            faces[cursor + 2] = c
            faces[cursor + 3] = b
            faces[cursor + 4] = d
            faces[cursor + 5] = c
            cursor += 6

    return faces


func _remove_previous_terrain() -> void:
    _terrain_ready = false
    _collision_update_running = false
    _collision_chunks.clear()
    if is_instance_valid(_grass_field):
        _grass_field.queue_free()
        _grass_field = null
    if is_instance_valid(_terrain_root):
        _terrain_root.queue_free()
        _terrain_root = null
    await get_tree().process_frame


func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
    var t: float = clampf((value - edge_a) / (edge_b - edge_a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
