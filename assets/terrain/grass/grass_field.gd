extends Node3D
class_name ProceduralGrassField

const PATCH_SIZE: float = 144.0
const GRID_CELLS: int = 288
# Low-detail clusters cover an area about 6.7x wider than the close-up patch.
const FAR_PATCH_SIZE: float = 960.0
const FAR_GRID_CELLS: int = 192
const FAR_CENTER_SNAP: float = 128.0
const BUILD_BATCH_CELLS: int = 4096
const INSTANCE_UPLOAD_BATCH: int = 8192
const MOVE_THRESHOLD: float = 24.0
const MAX_SURFACE_SLOPE: float = 0.55
const MAX_GRASS_HEIGHT: float = 1080.0

var terrain_generator: TerrainGenerator
var world_seed: int = 1337
var _grass_mesh: ArrayMesh
var _grass_material: ShaderMaterial
var _grass_instance: MultiMeshInstance3D
var _distant_grass_mesh: ArrayMesh
var _distant_grass_instance: MultiMeshInstance3D
var _distant_flower_instance: MultiMeshInstance3D
var _flower_mesh: ArrayMesh
var _flower_material: ShaderMaterial
var _flower_instance: MultiMeshInstance3D
var _weather_mode: int = 1
var _wind_strength: float = 0.68
var _target_wind_strength: float = 0.68
var _wind_speed: float = 1.03
var _target_wind_speed: float = 1.03
var _last_center: Vector2 = Vector2(INF, INF)
var _last_far_center: Vector2 = Vector2(INF, INF)
var _refresh_requested: bool = false
var _build_in_progress: bool = false
var _refresh_pending: bool = false


func configure(generator: TerrainGenerator, seed_value: int) -> void:
    terrain_generator = generator
    world_seed = seed_value
    _refresh_requested = true


func _ready() -> void:
    _create_blade_mesh()
    _distant_grass_mesh = _create_distant_grass_mesh()
    _create_blade_material()
    _create_flower_mesh()
    _create_flower_material()

    _grass_instance = MultiMeshInstance3D.new()
    _grass_instance.name = "ProceduralGrassInstances"
    _grass_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _grass_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    add_child(_grass_instance)

    _distant_grass_instance = MultiMeshInstance3D.new()
    _distant_grass_instance.name = "DistantGrassClusters"
    _distant_grass_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _distant_grass_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    add_child(_distant_grass_instance)

    _flower_instance = MultiMeshInstance3D.new()
    _flower_instance.name = "ProceduralFlowerInstances"
    _flower_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _flower_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    add_child(_flower_instance)

    _distant_flower_instance = MultiMeshInstance3D.new()
    _distant_flower_instance.name = "DistantFlowerClusters"
    _distant_flower_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _distant_flower_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    add_child(_distant_flower_instance)
    # configure() is called before this scene is added to the tree. The process
    # loop consumes _refresh_requested, avoiding a duplicate initial patch build.
    if not _refresh_requested:
        call_deferred("_refresh_patch", true)


func set_weather(mode: int) -> void:
    _weather_mode = clampi(mode, 0, 2)
    match _weather_mode:
        0: # Clear: calmer breeze.
            _target_wind_strength = 0.34
            _target_wind_speed = 0.66
        1: # Cloudy: stronger, rolling wind.
            _target_wind_strength = 0.68
            _target_wind_speed = 1.03
        2: # Overcast: pronounced gusts.
            _target_wind_strength = 0.98
            _target_wind_speed = 1.48


func _process(delta: float) -> void:
    var wind_blend: float = 1.0 - exp(-delta * 1.15)
    _wind_strength = lerpf(_wind_strength, _target_wind_strength, wind_blend)
    _wind_speed = lerpf(_wind_speed, _target_wind_speed, wind_blend)
    if _grass_material != null:
        _grass_material.set_shader_parameter("wind_strength", _wind_strength)
        _grass_material.set_shader_parameter("wind_speed", _wind_speed)
    if _flower_material != null:
        _flower_material.set_shader_parameter("wind_strength", _wind_strength)
        _flower_material.set_shader_parameter("wind_speed", _wind_speed)

    if terrain_generator == null or not is_instance_valid(terrain_generator):
        return
    var camera: Camera3D = get_viewport().get_camera_3d()
    if camera == null:
        return
    var camera_xz := Vector2(camera.global_position.x, camera.global_position.z)
    if _refresh_requested or _last_center.distance_to(camera_xz) >= MOVE_THRESHOLD:
        _refresh_requested = false
        if _build_in_progress:
            _refresh_pending = true
        else:
            _refresh_patch(false)


func _create_blade_mesh() -> void:
    # The reference addon renders one RibbonTrailMesh-like strip per particle.
    # Keep that same single-blade form instead of crossing several planes into a tuft.
    const BLADE_SEGMENTS: int = 4
    const HALF_WIDTH: float = 0.055
    const BLADE_BOW: float = 0.075
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var indices := PackedInt32Array()

    for row in range(BLADE_SEGMENTS + 1):
        var t: float = float(row) / float(BLADE_SEGMENTS)
        var center_z: float = sin(t * PI * 0.5) * BLADE_BOW
        var taper: float = lerpf(1.0, 0.025, pow(t, 1.35))
        var half_width: float = HALF_WIDTH * taper
        vertices.append(Vector3(-half_width, t, center_z))
        vertices.append(Vector3(half_width, t, center_z))
        normals.append(Vector3(0.0, -BLADE_BOW, 1.0).normalized())
        normals.append(Vector3(0.0, -BLADE_BOW, 1.0).normalized())
        uvs.append(Vector2(0.0, t))
        uvs.append(Vector2(1.0, t))

    for segment in range(BLADE_SEGMENTS):
        var row0: int = segment * 2
        var row1: int = row0 + 2
        indices.append(row0)
        indices.append(row0 + 1)
        indices.append(row1)
        indices.append(row0 + 1)
        indices.append(row1 + 1)
        indices.append(row1)

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    _grass_mesh = ArrayMesh.new()
    _grass_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _create_distant_grass_mesh() -> ArrayMesh:
    # Three crossed, slightly curved ribbons form one low-detail grass clump.
    # A single MultiMesh instance therefore replaces several individual distant blades.
    const BLADE_COUNT: int = 3
    const SEGMENTS: int = 2
    const HALF_WIDTH: float = 0.20
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()

    for blade in range(BLADE_COUNT):
        var angle: float = float(blade) * PI / 3.0
        var width_axis := Vector3(cos(angle), 0.0, sin(angle))
        var forward_axis := Vector3(-sin(angle), 0.0, cos(angle))
        var ribbon_normal := forward_axis.normalized()
        var base_vertex: int = vertices.size()
        for row in range(SEGMENTS + 1):
            var t: float = float(row) / float(SEGMENTS)
            var half_width: float = HALF_WIDTH * lerpf(1.0, 0.08, t)
            var center_offset: Vector3 = forward_axis * (sin(t * PI * 0.5) * 0.11)
            var center := Vector3(0.0, t, 0.0) + center_offset
            vertices.append(center - width_axis * half_width)
            vertices.append(center + width_axis * half_width)
            normals.append(ribbon_normal)
            normals.append(ribbon_normal)
            uvs.append(Vector2(0.0, t))
            uvs.append(Vector2(1.0, t))
            colors.append(Color.WHITE)
            colors.append(Color.WHITE)
        for segment in range(SEGMENTS):
            var row0: int = base_vertex + segment * 2
            var row1: int = row0 + 2
            indices.append(row0)
            indices.append(row0 + 1)
            indices.append(row1)
            indices.append(row0 + 1)
            indices.append(row1 + 1)
            indices.append(row1)

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh


func _create_blade_material() -> void:
    var shader := load("res://shaders/procedural_grass.gdshader") as Shader
    _grass_material = ShaderMaterial.new()
    _grass_material.shader = shader
    _grass_material.set_shader_parameter("wind_direction", Vector2(0.86, 0.51))
    _grass_material.set_shader_parameter("wind_strength", _wind_strength)
    _grass_material.set_shader_parameter("wind_speed", _wind_speed)
    _grass_material.set_shader_parameter("wind_noise_scale", 0.022)


func _create_flower_mesh() -> void:
    # A flower is a tiny 8-bit cluster of square petals plus one centre pixel.
    # It is placed at the tip of one occasional ribbon blade, not on every tuft.
    var vertices: Array[Vector3] = []
    var normals: Array[Vector3] = []
    var colors: Array[Color] = []
    var indices: Array[int] = []
    # About twice the previous pixel diameter; the shader billboards the head toward
    # the camera so the flower reads as a small round blossom instead of an edge-on line.
    # Double the base pixel geometry; instance scaling then spans 2x to 4x the
    # previous minimum/maximum flower size without producing metre-wide blossoms.
    var petal_half: float = 0.104
    var petal_offset: float = 0.136
    var petal_positions: Array[Vector2] = [
        Vector2(-petal_offset, 0.0), Vector2(petal_offset, 0.0),
        Vector2(0.0, -petal_offset), Vector2(0.0, petal_offset),
        Vector2(-petal_offset * 0.72, -petal_offset * 0.72),
        Vector2(petal_offset * 0.72, -petal_offset * 0.72),
        Vector2(-petal_offset * 0.72, petal_offset * 0.72),
        Vector2(petal_offset * 0.72, petal_offset * 0.72)
    ]
    for petal_position in petal_positions:
        _append_flower_pixel(vertices, normals, colors, indices, petal_position, petal_half, 0.0, true)
    _append_flower_pixel(vertices, normals, colors, indices, Vector2.ZERO, 0.088, 0.018, false)

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(vertices)
    arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(normals)
    arrays[Mesh.ARRAY_COLOR] = PackedColorArray(colors)
    arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)
    _flower_mesh = ArrayMesh.new()
    _flower_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _append_flower_pixel(
    vertices: Array[Vector3],
    normals: Array[Vector3],
    colors: Array[Color],
    indices: Array[int],
    center: Vector2,
    half_size: float,
    z_offset: float,
    petal: bool
) -> void:
    var first: int = vertices.size()
    vertices.append(Vector3(center.x - half_size, center.y - half_size, z_offset))
    vertices.append(Vector3(center.x + half_size, center.y - half_size, z_offset))
    vertices.append(Vector3(center.x + half_size, center.y + half_size, z_offset))
    vertices.append(Vector3(center.x - half_size, center.y + half_size, z_offset))
    for _i in range(4):
        normals.append(Vector3.BACK)
        colors.append(Color(1.0, 1.0, 1.0, 1.0) if petal else Color(1.0, 1.0, 1.0, 0.0))
    indices.append(first)
    indices.append(first + 1)
    indices.append(first + 2)
    indices.append(first)
    indices.append(first + 2)
    indices.append(first + 3)


func _create_flower_material() -> void:
    var shader := load("res://shaders/procedural_flowers.gdshader") as Shader
    _flower_material = ShaderMaterial.new()
    _flower_material.shader = shader
    _flower_material.set_shader_parameter("wind_direction", Vector2(0.86, 0.51))
    _flower_material.set_shader_parameter("wind_strength", _wind_strength)
    _flower_material.set_shader_parameter("wind_speed", _wind_speed)
    _flower_material.set_shader_parameter("wind_noise_scale", 0.022)


func _refresh_patch(force: bool) -> void:
    if _build_in_progress:
        _refresh_pending = true
        return
    if terrain_generator == null or not is_instance_valid(terrain_generator) or _grass_instance == null:
        return

    var camera: Camera3D = get_viewport().get_camera_3d()
    var camera_xz := Vector2.ZERO
    if camera != null:
        camera_xz = Vector2(camera.global_position.x, camera.global_position.z)
    var center := Vector2(round(camera_xz.x / 32.0) * 32.0, round(camera_xz.y / 32.0) * 32.0)
    if not force and center.distance_to(_last_center) < MOVE_THRESHOLD:
        return
    var far_center := Vector2(
        round(camera_xz.x / FAR_CENTER_SNAP) * FAR_CENTER_SNAP,
        round(camera_xz.y / FAR_CENTER_SNAP) * FAR_CENTER_SNAP
    )
    var refresh_far: bool = force or _last_far_center.x == INF or _last_far_center.distance_to(far_center) > 0.1

    _build_in_progress = true
    _refresh_pending = false
    _last_center = center

    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_custom_data = true
    multimesh.mesh = _grass_mesh

    var instance_transforms: Array[Transform3D] = []
    var colors := PackedColorArray()
    var flower_transforms: Array[Transform3D] = []
    var flower_data: Array[Color] = []
    var flower_instance_colors: Array[Color] = []
    var cell_size: float = PATCH_SIZE / float(GRID_CELLS)
    var start_cell_x: int = int(floor((center.x - PATCH_SIZE * 0.5) / cell_size))
    var start_cell_z: int = int(floor((center.y - PATCH_SIZE * 0.5) / cell_size))
    var total_cells: int = GRID_CELLS * GRID_CELLS

    # Build the instance list in small batches; a full patch contains >80k candidates.
    # Yielding keeps fast movement from causing half-second main-thread stalls.
    for cell_index in range(total_cells):
        var gz: int = int(float(cell_index) / float(GRID_CELLS))
        var gx: int = cell_index - gz * GRID_CELLS
        var world_cell_x: int = start_cell_x + gx
        var world_cell_z: int = start_cell_z + gz
        var px: float = (float(world_cell_x) + lerpf(0.08, 0.92, _random01(world_cell_x, world_cell_z, 1))) * cell_size
        var pz: float = (float(world_cell_z) + lerpf(0.08, 0.92, _random01(world_cell_x, world_cell_z, 2))) * cell_size

        var surface_sample: Vector3 = terrain_generator.surface_sample_at_world(px, pz)
        var h: float = surface_sample.x
        if h <= MAX_GRASS_HEIGHT:
            var slope_x: float = surface_sample.y
            var slope_z: float = surface_sample.z
            var slope: float = sqrt(slope_x * slope_x + slope_z * slope_z)
            if slope <= MAX_SURFACE_SLOPE and _random01(world_cell_x, world_cell_z, 3) >= clampf(slope * 0.30, 0.0, 0.16):
                var blade_height: float = lerpf(0.72, 1.55, _random01(world_cell_x, world_cell_z, 4))
                # Keep most of the established grass height range, but add a short-grass
                # population (22-50 cm) where small blossoms can naturally appear.
                if _random01(world_cell_x, world_cell_z, 15) < 0.24:
                    blade_height = lerpf(0.22, 0.50, _random01(world_cell_x, world_cell_z, 16))
                var width_scale: float = lerpf(0.76, 1.34, _random01(world_cell_x, world_cell_z, 5))
                var yaw: float = _random01(world_cell_x, world_cell_z, 6) * TAU
                var surface_normal := Vector3(-slope_x, 1.0, -slope_z).normalized()
                var align_basis := Basis(Quaternion(Vector3.UP, surface_normal))
                var yaw_basis := Basis(surface_normal, yaw)
                var blade_orientation: Basis = yaw_basis * align_basis
                var blade_basis: Basis = blade_orientation.scaled(Vector3(width_scale, blade_height, width_scale))
                var local_position := Vector3(px - center.x, h + 0.015, pz - center.y)
                instance_transforms.append(Transform3D(blade_basis, local_position))
                colors.append(Color(
                    _random01(world_cell_x, world_cell_z, 7),
                    _random01(world_cell_x, world_cell_z, 8),
                    lerpf(0.24, 0.92, _random01(world_cell_x, world_cell_z, 9)),
                    lerpf(0.42, 0.98, _random01(world_cell_x, world_cell_z, 10))
                ))

                # Flowers grow only on the short blades (maximum 50 cm), much more often
                # than before. Position and multi-colour palette remain deterministic per seed.
                if blade_height <= 0.50 and _random01(world_cell_x, world_cell_z, 11) > 0.20:
                    var tip_position: Vector3 = local_position + blade_basis * Vector3(0.0, 1.0, 0.075)
                    var flower_size_pick: float = _random01(world_cell_x, world_cell_z, 14)
                    # The base petal mesh spans roughly 0.48 world units. Scaling it
                    # from 0.21 to 0.42 keeps the actual blossom diameter between 10 and 20 cm.
                    var flower_size_distribution: float = pow(flower_size_pick, 1.15)
                    var flower_scale: float = lerpf(0.21, 0.42, flower_size_distribution)

                    # Give each flower a deterministic direction in the upper hemisphere:
                    # some heads lie nearly flat and face up, while others tilt naturally
                    # to the side. A separate roll rotates the pixel-petal pattern.
                    var flower_azimuth: float = _random01(world_cell_x, world_cell_z, 18) * TAU
                    var flower_upness: float = _random01(world_cell_x, world_cell_z, 17)
                    var flower_horizontal: float = sqrt(maxf(0.0, 1.0 - flower_upness * flower_upness))
                    var flower_normal := Vector3(
                        cos(flower_azimuth) * flower_horizontal,
                        flower_upness,
                        sin(flower_azimuth) * flower_horizontal
                    ).normalized()
                    var flower_align := Basis(Quaternion(Vector3.BACK, flower_normal))
                    var flower_roll := Basis(flower_normal, _random01(world_cell_x, world_cell_z, 19) * TAU)
                    var flower_orientation: Basis = flower_roll * flower_align
                    var flower_basis: Basis = flower_orientation.scaled(Vector3.ONE * flower_scale)
                    flower_transforms.append(Transform3D(flower_basis, tip_position))
                    # Custom channels are explicit: palette, brightness, wind response,
                    # and per-flower size variation. Do not inherit near-white grass alpha.
                    var flower_palette_pick: float = _random01(world_cell_x, world_cell_z, 12)
                    flower_instance_colors.append(_flower_palette_color(flower_palette_pick))
                    var flower_custom := Color(
                        flower_palette_pick,
                        _random01(world_cell_x, world_cell_z, 13),
                        colors[colors.size() - 1].b,
                        lerpf(0.72, 1.0, flower_size_distribution)
                    )
                    flower_data.append(flower_custom)

        if cell_index > 0 and cell_index % BUILD_BATCH_CELLS == 0:
            await get_tree().process_frame
            if not is_instance_valid(self) or not is_instance_valid(terrain_generator):
                _build_in_progress = false
                return

    multimesh.instance_count = instance_transforms.size()
    for i in range(instance_transforms.size()):
        multimesh.set_instance_transform(i, instance_transforms[i])
        multimesh.set_instance_custom_data(i, colors[i])
        if i > 0 and i % INSTANCE_UPLOAD_BATCH == 0:
            await get_tree().process_frame
            if not is_instance_valid(self):
                _build_in_progress = false
                return

    # Swap only after the new patch is ready, so the old patch stays in place while building.
    global_position = Vector3(center.x, 0.0, center.y)
    _grass_instance.multimesh = multimesh
    _grass_instance.material_override = _grass_material
    _grass_instance.custom_aabb = AABB(
        Vector3(-PATCH_SIZE * 0.5, -100.0, -PATCH_SIZE * 0.5),
        Vector3(PATCH_SIZE, 1800.0, PATCH_SIZE)
    )

    var flower_multimesh := MultiMesh.new()
    flower_multimesh.transform_format = MultiMesh.TRANSFORM_3D
    flower_multimesh.use_custom_data = true
    flower_multimesh.use_colors = true
    flower_multimesh.mesh = _flower_mesh
    flower_multimesh.instance_count = flower_transforms.size()
    for flower_index in range(flower_transforms.size()):
        flower_multimesh.set_instance_transform(flower_index, flower_transforms[flower_index])
        flower_multimesh.set_instance_custom_data(flower_index, flower_data[flower_index])
        flower_multimesh.set_instance_color(flower_index, flower_instance_colors[flower_index])
        if flower_index > 0 and flower_index % INSTANCE_UPLOAD_BATCH == 0:
            await get_tree().process_frame
            if not is_instance_valid(self):
                _build_in_progress = false
                return
    _flower_instance.multimesh = flower_multimesh
    _flower_instance.material_override = _flower_material
    _flower_instance.custom_aabb = AABB(
        Vector3(-PATCH_SIZE * 0.5, -100.0, -PATCH_SIZE * 0.5),
        Vector3(PATCH_SIZE, 1800.0, PATCH_SIZE)
    )

    # Parent origin follows the near patch. Offset the far LOD nodes so their world
    # positions remain anchored to the less frequently rebuilt, snapped far center.
    _distant_grass_instance.position = Vector3(far_center.x - center.x, 0.0, far_center.y - center.y)
    _distant_flower_instance.position = _distant_grass_instance.position
    if refresh_far:
        var far_grass_transforms: Array[Transform3D] = []
        var far_grass_data: Array[Color] = []
        var far_flower_transforms: Array[Transform3D] = []
        var far_flower_data: Array[Color] = []
        var far_flower_colors: Array[Color] = []
        var far_cell_size: float = FAR_PATCH_SIZE / float(FAR_GRID_CELLS)
        var far_start_x: int = int(floor((far_center.x - FAR_PATCH_SIZE * 0.5) / far_cell_size))
        var far_start_z: int = int(floor((far_center.y - FAR_PATCH_SIZE * 0.5) / far_cell_size))
        var far_total_cells: int = FAR_GRID_CELLS * FAR_GRID_CELLS

        # The far field is sampled at multi-metre intervals. Each accepted point is one
        # 3-ribbon tuft, not one instance per individual blade, so fill remains visible
        # over several hundred metres with far fewer geometry instances than near grass.
        for far_cell_index in range(far_total_cells):
            var far_gz: int = int(float(far_cell_index) / float(FAR_GRID_CELLS))
            var far_gx: int = far_cell_index - far_gz * FAR_GRID_CELLS
            var far_world_cell_x: int = far_start_x + far_gx
            var far_world_cell_z: int = far_start_z + far_gz
            var far_px: float = (
                float(far_world_cell_x)
                + lerpf(0.12, 0.88, _random01(far_world_cell_x, far_world_cell_z, 31))
            ) * far_cell_size
            var far_pz: float = (
                float(far_world_cell_z)
                + lerpf(0.12, 0.88, _random01(far_world_cell_x, far_world_cell_z, 32))
            ) * far_cell_size

            var far_surface: Vector3 = terrain_generator.surface_sample_at_world(far_px, far_pz)
            var far_slope: float = sqrt(far_surface.y * far_surface.y + far_surface.z * far_surface.z)
            if far_surface.x <= MAX_GRASS_HEIGHT and far_slope <= MAX_SURFACE_SLOPE \
                    and _random01(far_world_cell_x, far_world_cell_z, 33) >= clampf(far_slope * 0.30, 0.0, 0.16):
                var far_height: float = lerpf(0.62, 0.95, _random01(far_world_cell_x, far_world_cell_z, 34))
                var far_width: float = lerpf(0.86, 1.22, _random01(far_world_cell_x, far_world_cell_z, 35))
                var far_yaw: float = _random01(far_world_cell_x, far_world_cell_z, 36) * TAU
                var far_normal := Vector3(-far_surface.y, 1.0, -far_surface.z).normalized()
                var far_align := Basis(Quaternion(Vector3.UP, far_normal))
                var far_yaw_basis := Basis(far_normal, far_yaw)
                var far_basis: Basis = (far_yaw_basis * far_align).scaled(
                    Vector3(far_width, far_height, far_width)
                )
                var far_position := Vector3(far_px - far_center.x, far_surface.x + 0.01, far_pz - far_center.y)
                far_grass_transforms.append(Transform3D(far_basis, far_position))
                far_grass_data.append(Color(
                    _random01(far_world_cell_x, far_world_cell_z, 37),
                    _random01(far_world_cell_x, far_world_cell_z, 38),
                    lerpf(0.40, 0.76, _random01(far_world_cell_x, far_world_cell_z, 39)),
                    lerpf(0.72, 0.96, _random01(far_world_cell_x, far_world_cell_z, 40))
                ))

                # A smaller share of the far clumps carries enlarged flower dots so
                # the flowered meadow remains legible without full-detail blossoms.
                if _random01(far_world_cell_x, far_world_cell_z, 41) > 0.87:
                    var far_tip := far_position + far_basis * Vector3(0.0, 0.92, 0.04)
                    var far_flower_pick: float = _random01(far_world_cell_x, far_world_cell_z, 42)
                    var far_flower_size: float = lerpf(
                        0.82, 1.32, pow(_random01(far_world_cell_x, far_world_cell_z, 43), 1.1)
                    )
                    var far_azimuth: float = _random01(far_world_cell_x, far_world_cell_z, 44) * TAU
                    var far_upness: float = lerpf(0.25, 1.0, _random01(far_world_cell_x, far_world_cell_z, 45))
                    var far_horizontal: float = sqrt(maxf(0.0, 1.0 - far_upness * far_upness))
                    var far_flower_normal := Vector3(
                        cos(far_azimuth) * far_horizontal,
                        far_upness,
                        sin(far_azimuth) * far_horizontal
                    ).normalized()
                    var far_flower_align := Basis(Quaternion(Vector3.BACK, far_flower_normal))
                    var far_flower_roll := Basis(
                        far_flower_normal,
                        _random01(far_world_cell_x, far_world_cell_z, 46) * TAU
                    )
                    var far_flower_basis: Basis = (far_flower_roll * far_flower_align).scaled(
                        Vector3.ONE * far_flower_size
                    )
                    far_flower_transforms.append(Transform3D(far_flower_basis, far_tip))
                    far_flower_colors.append(_flower_palette_color(far_flower_pick))
                    far_flower_data.append(Color(
                        far_flower_pick,
                        _random01(far_world_cell_x, far_world_cell_z, 47),
                        0.55,
                        0.86
                    ))

            if far_cell_index > 0 and far_cell_index % BUILD_BATCH_CELLS == 0:
                await get_tree().process_frame
                if not is_instance_valid(self) or not is_instance_valid(terrain_generator):
                    _build_in_progress = false
                    return

        var far_grass_multimesh := MultiMesh.new()
        far_grass_multimesh.transform_format = MultiMesh.TRANSFORM_3D
        far_grass_multimesh.use_custom_data = true
        far_grass_multimesh.mesh = _distant_grass_mesh
        far_grass_multimesh.instance_count = far_grass_transforms.size()
        for i in range(far_grass_transforms.size()):
            far_grass_multimesh.set_instance_transform(i, far_grass_transforms[i])
            far_grass_multimesh.set_instance_custom_data(i, far_grass_data[i])
            if i > 0 and i % INSTANCE_UPLOAD_BATCH == 0:
                await get_tree().process_frame
                if not is_instance_valid(self):
                    _build_in_progress = false
                    return
        _distant_grass_instance.multimesh = far_grass_multimesh
        _distant_grass_instance.material_override = _grass_material
        _distant_grass_instance.custom_aabb = AABB(
            Vector3(-FAR_PATCH_SIZE * 0.5, -100.0, -FAR_PATCH_SIZE * 0.5),
            Vector3(FAR_PATCH_SIZE, 1800.0, FAR_PATCH_SIZE)
        )

        var far_flower_multimesh := MultiMesh.new()
        far_flower_multimesh.transform_format = MultiMesh.TRANSFORM_3D
        far_flower_multimesh.use_custom_data = true
        far_flower_multimesh.use_colors = true
        far_flower_multimesh.mesh = _flower_mesh
        far_flower_multimesh.instance_count = far_flower_transforms.size()
        for i in range(far_flower_transforms.size()):
            far_flower_multimesh.set_instance_transform(i, far_flower_transforms[i])
            far_flower_multimesh.set_instance_custom_data(i, far_flower_data[i])
            far_flower_multimesh.set_instance_color(i, far_flower_colors[i])
            if i > 0 and i % INSTANCE_UPLOAD_BATCH == 0:
                await get_tree().process_frame
                if not is_instance_valid(self):
                    _build_in_progress = false
                    return
        _distant_flower_instance.multimesh = far_flower_multimesh
        _distant_flower_instance.material_override = _flower_material
        _distant_flower_instance.custom_aabb = AABB(
            Vector3(-FAR_PATCH_SIZE * 0.5, -100.0, -FAR_PATCH_SIZE * 0.5),
            Vector3(FAR_PATCH_SIZE, 1800.0, FAR_PATCH_SIZE)
        )
        _last_far_center = far_center

    _build_in_progress = false

    if _refresh_pending:
        _refresh_pending = false
        call_deferred("_refresh_patch", false)


func _flower_palette_color(pick: float) -> Color:
    # Colour is supplied through MultiMesh instance colour, not only a shader branch;
    # each blossom therefore keeps its own vivid palette on all supported renderers.
    if pick < 0.22:
        return Color(1.00, 0.08, 0.34) # saturated magenta / rose
    if pick < 0.44:
        return Color(1.00, 0.58, 0.025) # bright golden yellow
    if pick < 0.66:
        return Color(0.42, 0.08, 1.00) # saturated violet
    if pick < 0.84:
        return Color(0.035, 0.48, 1.00) # vivid blue
    if pick < 0.985:
        return Color(1.00, 0.19, 0.025) # vivid orange-red
    return Color(1.00, 0.20, 0.58) # rare hot pink, never pale ivory


func _random01(cell_x: int, cell_z: int, salt: int) -> float:
    var key := Vector3i(
        cell_x * 17 + salt * 101,
        cell_z * 31 - salt * 37,
        int(world_seed % 1000003) + salt * 11
    )
    var value: int = int(abs(hash(key)) % 1000000)
    return float(value) / 1000000.0
