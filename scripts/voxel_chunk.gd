extends Node3D
class_name VoxelTerrainChunk

## Holds render/collision resources for one chunk; the native builder performs expensive CPU mesh work.
## Mesh/physics nodes are attached on the main thread and replaced GPU resources are retired gradually.

const VOXEL_SIZE: float = 0.1
const LOD_SHADOW_STRENGTHS: Array[float] = [0.20, 0.15, 0.10, 0.05, 0.0, 0.0, 0.0, 0.0]
const FallbackBuilderScript = preload("res://scripts/voxel_chunk_mesh_builder_fallback.gd")

var coord: Vector2i = Vector2i.ZERO
var lod: int = -1
var mesh_step_voxels: int = 1
var collision_enabled: bool = false # A collision shape is allocated for this chunk.
var collision_active: bool = false # Its collision layer is currently enabled.
var mesh_ready: bool = false
var render_vertex_count: int = 0
var render_index_count: int = 0
var shadow_vertex_count: int = 0
var estimated_mesh_bytes: int = 0
var mesh_upload_rejected: bool = false
var rejected_mesh_lod: int = -1
var rejected_mesh_step_voxels: int = -1
var neighbor_lods_used: Dictionary = {}

var _render_active: bool = true
var _skirt_visibility_cache := Vector4(-1.0, -1.0, -1.0, -1.0)
# Use a unique regular ShaderMaterial per chunk instead of instance uniforms.
# Compatibility renderer hardware can impose a very low per-instance-uniform limit.
var _mesh_shader_material: ShaderMaterial
var _retired_nodes: Array[Node] = []

# Convenient synchronous entry point for small tests. Runtime streaming uses WorkerThreadPool.
func build(
    p_coord: Vector2i,
    start_voxel_x: int,
    start_voxel_z: int,
    size_voxels_x: int,
    size_voxels_z: int,
    p_lod: int,
    neighbor_lods: Dictionary,
    generator: VoxelTerrainGenerator,
    material: Material,
    world_min_x: float,
    world_min_z: float,
    world_size_voxels: int,
    want_collision: bool,
    _p_debug_lod_colors: bool
) -> void:
    var job_data := {
        "coord": p_coord,
        "request": {
            "lod": p_lod,
            "start_x": start_voxel_x,
            "start_z": start_voxel_z,
            "size_x": size_voxels_x,
            "size_z": size_voxels_z,
            "collision": want_collision,
            "distance": 0.0,
            "priority": 0.0
        },
        "neighbor_lods": neighbor_lods.duplicate(true),
        "seed": generator.seed_value,
        "world_min_x": world_min_x,
        "world_min_z": world_min_z,
        "world_size_voxels": world_size_voxels,
    }
    var builder: Object = null
    if ClassDB.class_exists("VoxEnNativeBuilder"):
        builder = ClassDB.instantiate("VoxEnNativeBuilder")
    if builder == null:
        builder = FallbackBuilderScript.new()
    apply_mesh_data(builder.build_mesh_data(job_data), material)

func apply_mesh_data(data: Dictionary, material: Material) -> void:
    var incoming_lod: int = int(data.get("lod", -1))
    var incoming_step_voxels: int = int(data.get("step_voxels", 1 << clampi(incoming_lod, 0, 7)))
    var incoming_vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
    var incoming_normals: PackedVector3Array = data.get("normals", PackedVector3Array())
    var incoming_colors: PackedColorArray = data.get("colors", PackedColorArray())
    var incoming_indices: PackedInt32Array = data.get("indices", PackedInt32Array())

    # Validate before retiring a working mesh. If a terrain tile exceeds safe GPU limits,
    # keep the current generation visible and remember the rejected request.
    var has_geometry: bool = bool(data.get("has_geometry", false))
    var invalid_mesh: bool = incoming_vertices.size() > 1200000 or incoming_vertices.is_empty() or incoming_indices.is_empty() or incoming_indices.size() % 3 != 0 or incoming_normals.size() != incoming_vertices.size() or incoming_colors.size() != incoming_vertices.size()
    if has_geometry and invalid_mesh:
        mesh_upload_rejected = true
        rejected_mesh_lod = incoming_lod
        rejected_mesh_step_voxels = incoming_step_voxels
        push_warning("Voxel chunk %s LOD%d mesh rejected before GPU upload (vertices=%d, indices=%d). Existing terrain remains active." % [
            str(data.get("coord", coord)), incoming_lod, incoming_vertices.size(), incoming_indices.size()
        ])
        return

    mesh_upload_rejected = false
    rejected_mesh_lod = -1
    rejected_mesh_step_voxels = -1

    # Collision is based on world height, not visual LOD. Preserve an existing heightmap body
    # when only the render mesh changes so visual streaming does not churn physics resources.
    var wants_collision: bool = bool(data.get("want_collision", false))
    var collision_body := get_node_or_null("VoxelCollision") as StaticBody3D
    var preserve_collision: bool = wants_collision and collision_enabled and collision_body != null
    _retire_current_generation(preserve_collision)
    # Release the replaced generation before uploading its successor. Keeping both generations
    # alive during ArrayMesh creation can temporarily double GPU memory and trigger Vulkan OOM.
    while retire_one_old_node():
        pass
    _mesh_shader_material = null
    coord = data.get("coord", Vector2i.ZERO)
    lod = int(data.get("lod", -1))
    mesh_step_voxels = int(data.get("step_voxels", 1 << clampi(lod, 0, 7)))
    neighbor_lods_used = data.get("neighbor_lods_used", {}).duplicate(true)
    collision_enabled = false
    collision_active = false
    position = data.get("position", Vector3.ZERO)
    mesh_ready = false
    render_vertex_count = 0
    render_index_count = 0
    shadow_vertex_count = 0
    estimated_mesh_bytes = 0
    if preserve_collision:
        collision_enabled = true
        set_collision_active(wants_collision)
    else:
        collision_enabled = false
        collision_active = false

    if not bool(data.get("has_geometry", false)):
        return

    # Instance uniforms reserve a fixed per-node buffer on the Compatibility renderer.
    # A regular uniform on a per-chunk material avoids exhausting that hardware-limited buffer.
    var mesh_material: Material = material
    if material is ShaderMaterial:
        _mesh_shader_material = (material as ShaderMaterial).duplicate() as ShaderMaterial
        _mesh_shader_material.set_shader_parameter("skirt_visibility", Vector4(1.0, 1.0, 1.0, 1.0))
        _mesh_shader_material.set_shader_parameter("lod_shadow_strength", _shadow_receive_strength())
        _mesh_shader_material.set_shader_parameter("lod_index", lod)
        mesh_material = _mesh_shader_material

    var render_vertices_data: PackedVector3Array = incoming_vertices
    var render_normals_data: PackedVector3Array = incoming_normals
    var render_colors_data: PackedColorArray = incoming_colors
    var render_indices_data: PackedInt32Array = incoming_indices
    var shadow_vertices: PackedVector3Array = data.get("smooth_shadow_vertices", PackedVector3Array())
    var shadow_indices: PackedInt32Array = data.get("smooth_shadow_indices", PackedInt32Array())
    render_vertex_count = render_vertices_data.size()
    render_index_count = render_indices_data.size()
    shadow_vertex_count = shadow_vertices.size()
    # Conservative estimate for GPU position/normal/colour buffers and triangle indices.
    estimated_mesh_bytes = render_vertex_count * 28 + render_index_count * 4 + shadow_vertex_count * 24 + shadow_indices.size() * 4

    var mesh := _make_array_mesh(data, mesh_material)
    mesh.resource_name = "VoxelChunk_%d_%d_LOD%d" % [coord.x, coord.y, lod]
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "VoxelMesh"
    mesh_instance.mesh = mesh
    # Rebuilt chunks can remain logically inactive while hidden in the hierarchy.
    # New VisualInstances are visible by default, so inherit the chunk state immediately.
    mesh_instance.visible = _render_active
    # The visible colour mesh never enters the shadow map; each active LOD has a separate
    # invisible caster, so shadow complexity can change without changing material lighting.
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _skirt_visibility_cache = Vector4(-1.0, -1.0, -1.0, -1.0)
    add_child(mesh_instance)

    var shadow_normals: PackedVector3Array = data.get("smooth_shadow_normals", PackedVector3Array())
    if shadow_vertices.size() >= 3 and shadow_indices.size() >= 3:
        var shadow_data: Dictionary = {
            "vertices": shadow_vertices,
            "normals": shadow_normals,
            "indices": shadow_indices
        }
        var shadow_mesh := _make_array_mesh(shadow_data, null)
        shadow_mesh.resource_name = "TerrainShadowProxy_%d_%d_LOD%d" % [coord.x, coord.y, lod]
        var shadow_proxy := MeshInstance3D.new()
        shadow_proxy.name = "TerrainShadowProxy"
        shadow_proxy.mesh = shadow_mesh
        shadow_proxy.visible = _render_active and _should_proxy_cast_shadow()
        shadow_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
        add_child(shadow_proxy)

    mesh_ready = true

    if wants_collision and not preserve_collision:
        var collision_data: Dictionary = data.get("collision_height_map", {})
        if not collision_data.is_empty():
            var height_shape := HeightMapShape3D.new()
            height_shape.map_width = int(collision_data["width"])
            height_shape.map_depth = int(collision_data["depth"])
            height_shape.map_data = collision_data["heights"]

            var collision_shape := CollisionShape3D.new()
            collision_shape.name = "VoxelCollisionShape"
            collision_shape.shape = height_shape
            var step_m: float = float(collision_data.get("step_m", 0.2))
            collision_shape.scale = Vector3(step_m, step_m, step_m)
            collision_shape.position = Vector3(
                float(int(collision_data["width"]) - 1) * step_m * 0.5,
                0.0,
                float(int(collision_data["depth"]) - 1) * step_m * 0.5
            )

            var body := StaticBody3D.new()
            body.name = "VoxelCollision"
            # Collision data is world-space terrain coverage and remains valid even if this LOD mesh is hidden under a parent fallback.
            var should_collide: bool = bool(data.get("want_collision", false))
            body.collision_layer = 1 if should_collide else 0
            body.collision_mask = 1 if should_collide else 0
            body.add_child(collision_shape)
            add_child(body)
            collision_enabled = true
            collision_active = should_collide

func set_render_active(active: bool, request_collision: bool = false) -> void:
    var render_state_changed: bool = _render_active != active
    _render_active = active
    if render_state_changed:
        for child in get_children():
            if child is MeshInstance3D and child.name == "TerrainShadowProxy":
                child.visible = active and _should_proxy_cast_shadow()
            elif child is VisualInstance3D:
                child.visible = active
    # Visual hierarchy and physics coverage are independent: keep a valid near collider active
    # while its render mesh is hidden beneath a fallback parent during a streaming transition.
    var wants_active_collision: bool = request_collision and collision_enabled
    if collision_active != wants_active_collision:
        set_collision_active(wants_active_collision)


func set_shadow_mode(_mode: int) -> void:
    # Backward-compatible API; shadow attenuation is fixed per LOD and cannot be overridden globally.
    if _mesh_shader_material != null:
        _mesh_shader_material.set_shader_parameter("lod_shadow_strength", _shadow_receive_strength())
    var shadow_proxy := get_node_or_null("TerrainShadowProxy") as MeshInstance3D
    if shadow_proxy != null:
        shadow_proxy.visible = _render_active and _should_proxy_cast_shadow()


func _shadow_receive_strength() -> float:
    # Shadow strength is the fraction of directional shadow attenuation applied to voxel tops.
    # Vertical risers bypass it in the shader; LOD4+ receive no directional shadow darkening.
    if lod < 0:
        return 0.0
    return LOD_SHADOW_STRENGTHS[clampi(lod, 0, LOD_SHADOW_STRENGTHS.size() - 1)]


func _should_proxy_cast_shadow() -> bool:
    # The proxy is only an opaque terrain silhouette for the directional shadow map.
    # Keep it at every active LOD so distant mountains always occlude the sun and
    # cast relief shadows onto nearer chunks. The LOD mode controls how much shadow
    # the visible surface receives; LOD4+ receives none in either mode.
    return lod >= 0 and lod <= 7

func set_mesh_shader_parameter(parameter_name: StringName, value: Variant) -> void:
    if _mesh_shader_material != null:
        _mesh_shader_material.set_shader_parameter(parameter_name, value)


func set_skirt_visibility(visibility: Vector4) -> void:
    if _skirt_visibility_cache.is_equal_approx(visibility):
        return
    _skirt_visibility_cache = visibility
    if _mesh_shader_material != null:
        _mesh_shader_material.set_shader_parameter("skirt_visibility", visibility)

func set_collision_active(active: bool) -> void:
    collision_active = active and collision_enabled
    for child in get_children():
        if child is StaticBody3D and child.name == "VoxelCollision":
            child.collision_layer = 1 if collision_active else 0
            child.collision_mask = 1 if collision_active else 0

func retire_one_old_node() -> bool:
    if _retired_nodes.is_empty():
        return false
    var old_node: Node = _retired_nodes.pop_front()
    old_node.free()
    return true

func _retire_current_generation(preserve_collision: bool = false) -> void:
    mesh_ready = false
    for child in get_children():
        if preserve_collision and child is StaticBody3D and child.name == "VoxelCollision":
            continue
        if child is StaticBody3D:
            child.collision_layer = 0
            child.collision_mask = 0
        if child is VisualInstance3D:
            child.visible = false
        remove_child(child)
        _retired_nodes.append(child)
    if not preserve_collision:
        collision_enabled = false
        collision_active = false

func _make_array_mesh(data: Dictionary, material: Material) -> ArrayMesh:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
    arrays[Mesh.ARRAY_NORMAL] = data["normals"]
    if data.has("colors") and not data["colors"].is_empty():
        arrays[Mesh.ARRAY_COLOR] = data["colors"]
    arrays[Mesh.ARRAY_INDEX] = data["indices"]
    var mesh := ArrayMesh.new()
    if not data["indices"].is_empty():
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        if material != null:
            mesh.surface_set_material(0, material)
    return mesh

