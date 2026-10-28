extends Node3D
class_name DemoRockFormations

## Procedurally recreates the demo's rocky tunnel, entrance boulders and crystal groups.
## No Terrain3D height data or imported demo meshes are used; every anchor follows Far a Way's
## current procedural height field, so a new seed moves the formations onto the new terrain.

const TUNNEL_CENTER_X: float = 546.733
const TUNNEL_CENTER_Z: float = 468.686
const TUNNEL_LENGTH: float = 530.482
const TUNNEL_HALF_WIDTH: float = 117.8
const TUNNEL_INNER_HALF_WIDTH: float = 83.0
const TUNNEL_OUTER_HEIGHT: float = 64.0
const TUNNEL_INNER_HEIGHT: float = 28.0
const TUNNEL_CELL_SIZE: float = 4.0
const ROCK_CELL_SIZE: float = 2.0
const CRYSTAL_CELL_SIZE: float = 0.4

const FACE_DIRECTIONS = [
    Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0), Vector3i(0, -1, 0),
    Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]
const FACE_NORMALS = [
    Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN,
    Vector3.BACK, Vector3.FORWARD
]
const FACE_CORNERS = [
    [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
    [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
    [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
    [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)],
    [Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
    [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]
]

var _world: VoxelWorld
var _build_generation: int = 0


func _ready() -> void:
    _world = get_parent().get_node_or_null("VoxelWorld") as VoxelWorld
    if _world == null:
        push_warning("DemoRockFormations: VoxelWorld was not found; demo formations were skipped.")
        return
    _world.terrain_seed_changed.connect(_on_terrain_seed_changed)
    call_deferred("_rebuild_for_seed", _world.seed_value)


func _on_terrain_seed_changed(new_seed: int) -> void:
    call_deferred("_rebuild_for_seed", new_seed)


func _rebuild_for_seed(new_seed: int) -> void:
    if _world == null:
        return
    _build_generation += 1
    var generation_token: int = _build_generation
    for child in get_children():
        remove_child(child)
        child.queue_free()
    await get_tree().process_frame
    if generation_token != _build_generation:
        return

    await _build_tunnel_arch(generation_token, new_seed)
    if generation_token != _build_generation:
        return

    _build_rock_cluster("TunnelEntranceEast", _east_entrance_rocks(), new_seed + 101)
    await get_tree().process_frame
    if generation_token != _build_generation:
        return

    _build_rock_cluster("TunnelEntranceWest", _west_entrance_rocks(), new_seed + 307)
    await get_tree().process_frame
    if generation_token != _build_generation:
        return

    await _build_crystal_group(generation_token,
        "BlueCrystalGroup", Vector2(415.722, 611.385),
        Color(0.24, 0.43, 1.0), new_seed + 503,
        [
            {"dx": 0.05, "dz": 4.55, "radius": 0.90, "height": 6.0},
            {"dx": 4.01, "dz": -0.62, "radius": 0.67, "height": 7.6},
            {"dx": -1.70, "dz": -0.57, "radius": 0.82, "height": 5.2}
        ]
    )
    await get_tree().process_frame
    if generation_token != _build_generation:
        return

    await _build_crystal_group(generation_token,
        "PurpleCrystalGroup", Vector2(553.318, 647.425),
        Color(0.49, 0.30, 1.0), new_seed + 709,
        [
            {"dx": 0.82, "dz": 2.54, "radius": 0.83, "height": 5.7},
            {"dx": 4.01, "dz": -0.62, "radius": 0.70, "height": 7.4},
            {"dx": 7.29, "dz": 4.53, "radius": 0.92, "height": 6.2}
        ]
    )
    await get_tree().process_frame
    if generation_token != _build_generation:
        return

    await _build_crystal_group(generation_token,
        "RedCrystalGroup", Vector2(711.291, 579.252),
        Color(0.82, 0.10, 0.31), new_seed + 907,
        [
            {"dx": 0.59, "dz": 3.05, "radius": 0.82, "height": 6.4},
            {"dx": 4.01, "dz": -0.62, "radius": 0.70, "height": 7.2},
            {"dx": 7.29, "dz": 4.53, "radius": 0.95, "height": 5.6}
        ]
    )


func _east_entrance_rocks() -> Array[Dictionary]:
    return [
        {"x": 299.644, "z": 424.309, "rx": 12.0, "ry": 9.0, "rz": 11.0, "id": 1},
        {"x": 318.179, "z": 421.731, "rx": 12.0, "ry": 8.0, "rz": 10.0, "id": 2},
        {"x": 321.814, "z": 436.931, "rx": 10.0, "ry": 8.0, "rz": 9.0, "id": 3},
        {"x": 338.177, "z": 430.367, "rx": 11.0, "ry": 9.0, "rz": 10.0, "id": 4},
        {"x": 320.977, "z": 441.012, "rx": 12.0, "ry": 10.0, "rz": 10.0, "id": 5},
        {"x": 295.848, "z": 419.450, "rx": 11.0, "ry": 9.0, "rz": 10.0, "id": 6},
        {"x": 306.288, "z": 434.042, "rx": 10.0, "ry": 8.0, "rz": 9.0, "id": 7},
        {"x": 328.686, "z": 427.630, "rx": 11.0, "ry": 9.0, "rz": 10.0, "id": 8},
        {"x": 303.461, "z": 428.826, "rx": 10.0, "ry": 8.0, "rz": 8.0, "id": 9},
        {"x": 335.270, "z": 418.362, "rx": 9.0, "ry": 8.0, "rz": 8.0, "id": 10},
        {"x": 345.465, "z": 480.747, "rx": 15.0, "ry": 10.0, "rz": 12.0, "id": 11}
    ]


func _west_entrance_rocks() -> Array[Dictionary]:
    return [
        {"x": 807.937, "z": 467.411, "rx": 17.0, "ry": 12.0, "rz": 16.0, "id": 21},
        {"x": 766.019, "z": 452.605, "rx": 15.0, "ry": 10.0, "rz": 14.0, "id": 22},
        {"x": 793.166, "z": 454.834, "rx": 17.0, "ry": 13.0, "rz": 15.0, "id": 23},
        {"x": 824.574, "z": 446.946, "rx": 12.0, "ry": 9.0, "rz": 12.0, "id": 24},
        {"x": 773.937, "z": 469.972, "rx": 14.0, "ry": 10.0, "rz": 13.0, "id": 25},
        {"x": 786.081, "z": 453.531, "rx": 12.0, "ry": 9.0, "rz": 11.0, "id": 26},
        {"x": 791.859, "z": 508.107, "rx": 15.0, "ry": 11.0, "rz": 14.0, "id": 27}
    ]


func _build_rock_cluster(cluster_name: String, specs: Array, cluster_seed: int) -> void:
    var step: float = ROCK_CELL_SIZE
    var min_x: float = INF
    var min_y: float = INF
    var min_z: float = INF
    for spec in specs:
        var center_x: float = float(spec["x"])
        var center_z: float = float(spec["z"])
        var radius_x: float = float(spec["rx"])
        var radius_y: float = float(spec["ry"])
        var radius_z: float = float(spec["rz"])
        var ground_y: float = _world.get_surface_height(center_x, center_z)
        var center_y: float = ground_y + radius_y * 0.25
        min_x = minf(min_x, center_x - radius_x)
        min_y = minf(min_y, center_y - radius_y)
        min_z = minf(min_z, center_z - radius_z)

    var origin := Vector3(min_x, floor(min_y / step) * step, min_z)
    var cells: Dictionary = {}
    for spec in specs:
        var center_x: float = float(spec["x"])
        var center_z: float = float(spec["z"])
        var radius_x: float = float(spec["rx"])
        var radius_y: float = float(spec["ry"])
        var radius_z: float = float(spec["rz"])
        var ground_y: float = _world.get_surface_height(center_x, center_z)
        var center_y: float = ground_y + radius_y * 0.25
        var seed_offset: float = float(cluster_seed + int(spec["id"]) * 31) * 0.013
        var x_start: int = floori((center_x - radius_x - origin.x) / step)
        var x_end: int = ceili((center_x + radius_x - origin.x) / step)
        var y_start: int = floori((center_y - radius_y - origin.y) / step)
        var y_end: int = ceili((center_y + radius_y - origin.y) / step)
        var z_start: int = floori((center_z - radius_z - origin.z) / step)
        var z_end: int = ceili((center_z + radius_z - origin.z) / step)
        for iy in range(y_start, y_end):
            var world_y: float = origin.y + (float(iy) + 0.5) * step
            var ny: float = (world_y - center_y) / radius_y
            for iz in range(z_start, z_end):
                var world_z: float = origin.z + (float(iz) + 0.5) * step
                var nz: float = (world_z - center_z) / radius_z
                for ix in range(x_start, x_end):
                    var world_x: float = origin.x + (float(ix) + 0.5) * step
                    var nx: float = (world_x - center_x) / radius_x
                    var roughness: float = sin(world_x * 0.17 + world_z * 0.11 + seed_offset) * 0.055
                    roughness += sin(world_y * 0.13 - world_x * 0.07 + seed_offset * 1.9) * 0.035
                    if nx * nx + ny * ny + nz * nz <= 1.0 + roughness:
                        cells[Vector3i(ix, iy, iz)] = true

    var mesh := _create_voxel_mesh(cells, step)
    if mesh != null:
        _add_mesh_node(cluster_name, mesh, origin, _world.get_voxel_prop_material(step), true)


func _build_tunnel_arch(generation_token: int, terrain_seed: int) -> void:
    var step: float = TUNNEL_CELL_SIZE
    var half_length: float = TUNNEL_LENGTH * 0.5
    var origin_x: float = TUNNEL_CENTER_X - half_length
    var origin_z: float = TUNNEL_CENTER_Z - TUNNEL_HALF_WIDTH
    var x_cells: int = ceili(TUNNEL_LENGTH / step)
    var z_cells: int = ceili((TUNNEL_HALF_WIDTH * 2.0) / step)
    var terrain_heights := PackedFloat32Array()
    terrain_heights.resize(x_cells * z_cells)
    var min_ground: float = INF

    for ix in range(x_cells):
        var world_x: float = origin_x + (float(ix) + 0.5) * step
        for iz in range(z_cells):
            var world_z: float = origin_z + (float(iz) + 0.5) * step
            var ground_y: float = _world.get_surface_height(world_x, world_z)
            terrain_heights[ix * z_cells + iz] = ground_y
            min_ground = minf(min_ground, ground_y)
        if ix % 8 == 0:
            await get_tree().process_frame
            if generation_token != _build_generation:
                return

    var origin_y: float = floor(min_ground / step) * step - step
    var origin := Vector3(origin_x, origin_y, origin_z)
    var cells: Dictionary = {}
    var arch_seed: float = float(terrain_seed) * 0.00073

    for ix in range(x_cells):
        var world_x: float = origin_x + (float(ix) + 0.5) * step
        var x_norm: float = (world_x - TUNNEL_CENTER_X) / half_length
        var end_scale: float = 0.84 + 0.16 * sqrt(maxf(0.0, 1.0 - x_norm * x_norm))
        for iz in range(z_cells):
            var world_z: float = origin_z + (float(iz) + 0.5) * step
            var lateral: float = world_z - TUNNEL_CENTER_Z
            var outer_ratio: float = lateral / TUNNEL_HALF_WIDTH
            if absf(outer_ratio) >= 1.0:
                continue
            var outer_height: float = TUNNEL_OUTER_HEIGHT * sqrt(maxf(0.0, 1.0 - outer_ratio * outer_ratio)) * end_scale
            var inner_ratio: float = lateral / TUNNEL_INNER_HALF_WIDTH
            var inner_height: float = 0.0
            if absf(inner_ratio) < 1.0:
                inner_height = TUNNEL_INNER_HEIGHT * sqrt(maxf(0.0, 1.0 - inner_ratio * inner_ratio)) * end_scale
            var ground_y: float = terrain_heights[ix * z_cells + iz]
            var column_base_y: float = floor(ground_y / step) * step
            var base_index: int = roundi((column_base_y - origin_y) / step)
            var layer_count: int = ceili(outer_height / step)
            for layer in range(layer_count):
                var relative_height: float = column_base_y - ground_y + (float(layer) + 0.5) * step
                if relative_height < inner_height or relative_height > outer_height:
                    continue
                var cell_y: int = base_index + layer
                var bed_noise: float = sin(world_x * 0.022 + world_z * 0.031 + arch_seed) * 0.7
                if relative_height < inner_height + step * 1.4 and bed_noise < -0.55:
                    continue
                cells[Vector3i(ix, cell_y, iz)] = true
        if ix % 8 == 0:
            await get_tree().process_frame
            if generation_token != _build_generation:
                return

    var mesh := _create_voxel_mesh(cells, step)
    if mesh != null and generation_token == _build_generation:
        _add_mesh_node("ProceduralRockTunnel", mesh, origin, _world.get_voxel_prop_material(step), true)


func _build_crystal_group(generation_token: int, group_name: String, group_center: Vector2, crystal_color: Color, crystal_seed: int, specs: Array) -> void:
    if generation_token != _build_generation:
        return
    var step: float = CRYSTAL_CELL_SIZE
    var origin_x: float = group_center.x - 5.0
    var origin_z: float = group_center.y - 5.0
    var min_ground: float = INF
    for spec in specs:
        var gx: float = group_center.x + float(spec["dx"])
        var gz: float = group_center.y + float(spec["dz"])
        min_ground = minf(min_ground, _world.get_surface_height(gx, gz))
    var origin_y: float = floor(min_ground / step) * step
    var origin := Vector3(origin_x, origin_y, origin_z)
    var cells: Dictionary = {}

    for spec in specs:
        var center_x: float = group_center.x + float(spec["dx"])
        var center_z: float = group_center.y + float(spec["dz"])
        var ground_y: float = _world.get_surface_height(center_x, center_z)
        var base_y: float = floor(ground_y / step) * step
        var base_index: int = roundi((base_y - origin_y) / step)
        var radius: float = float(spec["radius"])
        var height: float = float(spec["height"])
        var x_start: int = floori((center_x - radius - origin_x) / step)
        var x_end: int = ceili((center_x + radius - origin_x) / step)
        var z_start: int = floori((center_z - radius - origin_z) / step)
        var z_end: int = ceili((center_z + radius - origin_z) / step)
        var layers: int = ceili(height / step)
        for layer in range(layers):
            var progress: float = (float(layer) + 0.5) / float(maxi(layers, 1))
            var layer_radius: float = maxf(step * 0.75, radius * (1.0 - 0.70 * progress))
            var center_y: float = origin_y + (float(base_index + layer) + 0.5) * step
            for iz in range(z_start, z_end):
                var world_z: float = origin_z + (float(iz) + 0.5) * step
                for ix in range(x_start, x_end):
                    var world_x: float = origin_x + (float(ix) + 0.5) * step
                    var dx: float = absf(world_x - center_x) / layer_radius
                    var dz: float = absf(world_z - center_z) / layer_radius
                    var facet: float = sin((world_x + world_z + float(crystal_seed)) * 0.7) * 0.06
                    if dx + dz <= 1.35 + facet and maxf(dx, dz) <= 1.0 + facet:
                        cells[Vector3i(ix, base_index + layer, iz)] = true
            if layer % 6 == 0:
                await get_tree().process_frame
                if generation_token != _build_generation:
                    return

    var mesh := _create_voxel_mesh(cells, step)
    if mesh != null:
        var material := StandardMaterial3D.new()
        material.albedo_color = crystal_color
        material.metallic = 0.12
        material.roughness = 0.22
        material.emission_enabled = true
        material.emission = crystal_color * 0.7
        material.emission_energy_multiplier = 1.25
        _add_mesh_node(group_name, mesh, origin, material, false)


func _create_voxel_mesh(cells: Dictionary, step: float) -> ArrayMesh:
    if cells.is_empty():
        return null
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var stone_color := Color(0.24, 0.245, 0.24, 1.0)

    for cell_value in cells.keys():
        var cell: Vector3i = cell_value
        for face_index in range(FACE_DIRECTIONS.size()):
            if cells.has(cell + FACE_DIRECTIONS[face_index]):
                continue
            var base_index: int = vertices.size()
            var corners: Array = FACE_CORNERS[face_index]
            for corner_value in corners:
                var corner: Vector3 = corner_value
                vertices.append((Vector3(cell) + corner) * step)
                normals.append(FACE_NORMALS[face_index])
                colors.append(stone_color)
            indices.append(base_index)
            indices.append(base_index + 1)
            indices.append(base_index + 2)
            indices.append(base_index)
            indices.append(base_index + 2)
            indices.append(base_index + 3)

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    if not indices.is_empty():
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh


func _add_mesh_node(node_name: String, mesh: ArrayMesh, mesh_origin: Vector3, material: Material, add_collision: bool) -> void:
    var root_node := Node3D.new()
    root_node.name = node_name
    root_node.position = mesh_origin
    add_child(root_node)

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "Mesh"
    mesh_instance.mesh = mesh
    mesh_instance.material_override = material
    root_node.add_child(mesh_instance)

    if add_collision:
        var body := StaticBody3D.new()
        body.name = "StaticBody"
        root_node.add_child(body)
        var collision := CollisionShape3D.new()
        collision.name = "CollisionShape"
        collision.shape = mesh.create_trimesh_shape()
        body.add_child(collision)
