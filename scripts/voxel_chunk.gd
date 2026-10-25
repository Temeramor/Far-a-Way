extends Node3D
class_name VoxelTerrainChunk

## Holds render/collision resources for one chunk. Mesh CPU work happens in VoxelChunkMeshBuilder;
## replacements are attached on the main thread and old GPU-backed nodes are retired gradually.

const VOXEL_SIZE: float = 0.1
const BuilderScript = preload("res://scripts/voxel_chunk_builder.gd")

var coord: Vector2i = Vector2i.ZERO
var lod: int = -1
var mesh_step_voxels: int = 2
var collision_enabled: bool = false # A collision shape is allocated for this chunk.
var collision_active: bool = false # Its collision layer is currently enabled.
var mesh_ready: bool = false
var debug_lod_colors: bool = false
var neighbor_lods_used: Dictionary = {}

var _render_active: bool = true
var _shadow_mode: int = 1
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
    p_debug_lod_colors: bool
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
        "debug_lod_colors": p_debug_lod_colors
    }
    var builder = BuilderScript.new()
    apply_mesh_data(builder.build_mesh_data(job_data), material)

func apply_mesh_data(data: Dictionary, material: Material) -> void:
    # Collision is based on world height, not visual LOD. Preserve an existing heightmap body
    # when only the render mesh changes so visual streaming does not churn physics resources.
    var wants_collision: bool = bool(data.get("want_collision", false))
    var collision_body := get_node_or_null("VoxelCollision") as StaticBody3D
    var preserve_collision: bool = wants_collision and collision_enabled and collision_body != null
    _retire_current_generation(preserve_collision)
    _mesh_shader_material = null
    coord = data.get("coord", Vector2i.ZERO)
    lod = int(data.get("lod", -1))
    _shadow_mode = clampi(GameSettings.shadow_mode, 0, 1)
    mesh_step_voxels = int(data.get("step_voxels", 2 << clampi(lod, 0, 6)))
    debug_lod_colors = bool(data.get("debug_lod_colors", false))
    neighbor_lods_used = data.get("neighbor_lods_used", {}).duplicate(true)
    collision_enabled = false
    collision_active = false
    position = data.get("position", Vector3.ZERO)
    mesh_ready = false
    if preserve_collision:
        collision_enabled = true
        set_collision_active(_render_active and wants_collision)
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
        mesh_material = _mesh_shader_material

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

    var shadow_top_vertex_count: int = int(data.get("shadow_top_vertex_count", 0))
    var shadow_top_index_count: int = int(data.get("shadow_top_index_count", 0))
    var shadow_full_vertex_count: int = int(data.get("shadow_full_vertex_count", 0))
    var shadow_full_index_count: int = int(data.get("shadow_full_index_count", 0))
    # Use the full opaque relief silhouette for shadow-map occlusion.
    var shadow_vertex_count: int = shadow_full_vertex_count
    var shadow_index_count: int = shadow_full_index_count
    if shadow_vertex_count >= 3 and shadow_index_count >= 3:
        var source_vertices: PackedVector3Array = data["vertices"]
        var source_normals: PackedVector3Array = data["normals"]
        var source_colors: PackedColorArray = data["colors"]
        var source_indices: PackedInt32Array = data["indices"]
        var shadow_data: Dictionary = {
            "vertices": source_vertices.slice(0, shadow_vertex_count),
            "normals": source_normals.slice(0, shadow_vertex_count),
            "colors": source_colors.slice(0, shadow_vertex_count),
            "indices": source_indices.slice(0, shadow_index_count)
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
            var should_collide: bool = _render_active and bool(data.get("want_collision", false))
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
    var wants_active_collision: bool = active and request_collision and collision_enabled
    if collision_active != wants_active_collision:
        set_collision_active(wants_active_collision)


func set_shadow_mode(mode: int) -> void:
    _shadow_mode = clampi(mode, 0, 1)
    if _mesh_shader_material != null:
        _mesh_shader_material.set_shader_parameter("lod_shadow_strength", _shadow_receive_strength())
    var shadow_proxy := get_node_or_null("TerrainShadowProxy") as MeshInstance3D
    if shadow_proxy != null:
        shadow_proxy.visible = _render_active and _should_proxy_cast_shadow()


func _shadow_receive_strength() -> float:
    if lod < 0 or lod >= 4:
        return 0.0
    if _shadow_mode == 0:
        return 1.0
    return maxf(0.0, 1.0 - float(lod) * 0.25)


func _should_proxy_cast_shadow() -> bool:
    # The proxy is only an opaque terrain silhouette for the directional shadow map.
    # Keep it at every active LOD so distant mountains always occlude the sun and
    # cast relief shadows onto nearer chunks. The LOD mode controls how much shadow
    # the visible surface receives; LOD4+ receives none in either mode.
    return lod >= 0 and lod <= 6

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
    collision_active = active and collision_enabled and _render_active
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
    arrays[Mesh.ARRAY_COLOR] = data["colors"]
    arrays[Mesh.ARRAY_INDEX] = data["indices"]
    var mesh := ArrayMesh.new()
    if not data["indices"].is_empty():
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        if material != null:
            mesh.surface_set_material(0, material)
    return mesh

