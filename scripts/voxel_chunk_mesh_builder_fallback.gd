extends RefCounted
class_name VoxelChunkMeshBuilderFallback

## CPU-only block-terrain mesh builder. This class touches packed arrays and noise fields only;
## the SceneTree, RenderingServer and physics resources are handled by the main-thread wrapper.

const VOXEL_SIZE: float = 0.1
const BASE_MESH_STEP_VOXELS: int = 1
const HEIGHT_CACHE_STEP_VOXELS: int = 5
const LOD_SKIRT_DEPTH_VOXELS: int = 80
const SKIRT_ALPHA_LEFT: float = 0.80
const SKIRT_ALPHA_RIGHT: float = 0.84
const SKIRT_ALPHA_NORTH: float = 0.88
const SKIRT_ALPHA_SOUTH: float = 0.92
const GeneratorScript = preload("res://scripts/voxel_generator.gd")

var coord: Vector2i = Vector2i.ZERO
var lod: int = -1
var collision_enabled: bool = false
var _active_step_voxels: int = 1
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var result: Dictionary = {}

func build_mesh_data(job_data: Dictionary) -> Dictionary:
    var build_started_usec: int = Time.get_ticks_usec()
    var worker_started_usec: int = build_started_usec
    var p_coord: Vector2i = job_data["coord"]
    var request: Dictionary = job_data["request"]
    var p_lod: int = int(request["lod"])
    var neighbor_lods: Dictionary = job_data["neighbor_lods"]
    var world_min_x: float = float(job_data["world_min_x"])
    var world_min_z: float = float(job_data["world_min_z"])
    var world_size_voxels: int = int(job_data["world_size_voxels"])
    var start_voxel_x: int = int(request["start_x"])
    var start_voxel_z: int = int(request["start_z"])
    var size_voxels_x: int = int(request["size_x"])
    var size_voxels_z: int = int(request["size_z"])
    var want_collision: bool = bool(request["collision"])
    var build_collision: bool = bool(job_data.get("build_collision", want_collision))
    var generator: VoxelTerrainGenerator = GeneratorScript.new(int(job_data["seed"]), float(job_data.get("terrain_world_size_m", float(world_size_voxels) * VOXEL_SIZE)))

    _vertices = PackedVector3Array()
    _normals = PackedVector3Array()
    _colors = PackedColorArray()
    _indices = PackedInt32Array()
    coord = p_coord
    lod = p_lod
    collision_enabled = false

    var step_voxels: int = maxi(1, int(request.get("step_voxels", BASE_MESH_STEP_VOXELS << lod)))
    var cell_size: float = float(step_voxels) * VOXEL_SIZE
    var cells_x: int = int(ceil(float(size_voxels_x) / float(step_voxels)))
    var cells_z: int = int(ceil(float(size_voxels_z) / float(step_voxels)))
    _active_step_voxels = step_voxels

    var macro_offset: int = maxi(1, int(round(1.0 / cell_size)))
    var halo: int = macro_offset + 1
    var grid_width: int = cells_x + halo * 2
    var grid_depth: int = cells_z + halo * 2
    var total_samples: int = grid_width * grid_depth
    var cache_step_voxels: int = maxi(HEIGHT_CACHE_STEP_VOXELS, step_voxels)
    var cache_origin_x: int = floori(float(start_voxel_x - halo * step_voxels - cache_step_voxels * 2) / float(cache_step_voxels)) * cache_step_voxels
    var cache_origin_z: int = floori(float(start_voxel_z - halo * step_voxels - cache_step_voxels * 2) / float(cache_step_voxels)) * cache_step_voxels
    var cache_end_x: int = start_voxel_x + size_voxels_x + halo * step_voxels + cache_step_voxels * 2
    var cache_end_z: int = start_voxel_z + size_voxels_z + halo * step_voxels + cache_step_voxels * 2
    var cache_width: int = ceili(float(cache_end_x - cache_origin_x) / float(cache_step_voxels)) + 1
    var cache_depth: int = ceili(float(cache_end_z - cache_origin_z) / float(cache_step_voxels)) + 1
    var height_cache := PackedFloat32Array()
    height_cache.resize(cache_width * cache_depth)
    for cz in range(cache_depth):
        var cache_z: float = float(cache_origin_z + cz * cache_step_voxels)
        for cx in range(cache_width):
            var cache_x: float = float(cache_origin_x + cx * cache_step_voxels)
            height_cache[cz * cache_width + cx] = _sample_height_voxel_units(cache_x, cache_z, generator, world_min_x, world_min_z, world_size_voxels)

    # Cache continuous heights in voxel units. Quantise only after cubic
    # interpolation so contours are not locked to the repeated 0.5 m cache pattern.
    var raw_heights := PackedInt32Array()
    raw_heights.resize(total_samples)
    for gz in range(grid_depth):
        var global_cell_z: float = float(start_voxel_z) + float(gz - halo) * float(step_voxels) + float(step_voxels) * 0.5
        for gx in range(grid_width):
            var global_cell_x: float = float(start_voxel_x) + float(gx - halo) * float(step_voxels) + float(step_voxels) * 0.5
            raw_heights[gz * grid_width + gx] = _cached_height_voxels(global_cell_x, global_cell_z, height_cache, cache_width, cache_depth, cache_origin_x, cache_origin_z, cache_step_voxels, world_size_voxels)
    var heights: PackedInt32Array = raw_heights.duplicate()
    # Quantise vertical heights to the same world-space step as each LOD's horizontal cell.
    if step_voxels > 1:
        for height_index in range(heights.size()):
            var raw_height: int = raw_heights[height_index]
            if raw_height > 0:
                heights[height_index] = maxi(step_voxels, roundi(float(raw_height) / float(step_voxels)) * step_voxels)

    var surface_types := PackedByteArray()
    surface_types.resize(cells_x * cells_z)
    # One-cell colour halo keeps interpolated grass/rock blends continuous across chunk seams.
    var rock_weight_width: int = cells_x + 2
    var surface_rock_weights := PackedFloat32Array()
    surface_rock_weights.resize((cells_x + 2) * (cells_z + 2))
    for z in range(-1, cells_z + 1):
        for x in range(-1, cells_x + 1):
            var gx: int = x + halo
            var gz: int = z + halo
            var left_h: int = raw_heights[gz * grid_width + gx - macro_offset]
            var right_h: int = raw_heights[gz * grid_width + gx + macro_offset]
            var north_h: int = raw_heights[(gz - macro_offset) * grid_width + gx]
            var south_h: int = raw_heights[(gz + macro_offset) * grid_width + gx]
            var dx: float = float(right_h - left_h) * VOXEL_SIZE / (2.0 * float(macro_offset) * cell_size)
            var dz: float = float(south_h - north_h) * VOXEL_SIZE / (2.0 * float(macro_offset) * cell_size)
            var slope: float = sqrt(dx * dx + dz * dz)
            var world_x: float = world_min_x + (float(start_voxel_x + x * step_voxels) + float(step_voxels) * 0.5) * VOXEL_SIZE
            var world_z: float = world_min_z + (float(start_voxel_z + z * step_voxels) + float(step_voxels) * 0.5) * VOXEL_SIZE
            var rock_weight: float = generator.get_surface_rock_weight(slope, world_x, world_z)
            surface_rock_weights[(z + 1) * rock_weight_width + x + 1] = rock_weight
            if x >= 0 and x < cells_x and z >= 0 and z < cells_z:
                surface_types[z * cells_x + x] = VoxelTerrainGenerator.ROCK if rock_weight >= 0.5 else VoxelTerrainGenerator.GRASS

    _build_greedy_top_faces(
        heights, surface_types, surface_rock_weights,
        grid_width, halo, cells_x, cells_z, cell_size, step_voxels
    )
    _build_exposed_side_faces(
        heights, surface_types, surface_rock_weights,
        grid_width, halo, cells_x, cells_z, step_voxels
    )
    _build_lod_skirts(heights, surface_types, grid_width, halo, cells_x, cells_z, step_voxels, neighbor_lods)
    var smooth_shadow_data: Dictionary = {
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "indices": PackedInt32Array()
    }
    if float(request.get("distance", 0.0)) <= 1200.0:
        smooth_shadow_data = _build_smooth_shadow_surface(
            generator, p_lod, world_min_x, world_min_z,
            start_voxel_x, start_voxel_z, size_voxels_x, size_voxels_z,
            height_cache, cache_width, cache_depth, cache_origin_x, cache_origin_z, cache_step_voxels
        )

    result = {
        "coord": coord,
        "lod": lod,
        "step_voxels": step_voxels,
        "neighbor_lods_used": neighbor_lods.duplicate(true),
        "vertices": _vertices,
        "normals": _normals,
        "colors": _colors,
        "indices": _indices,
        "smooth_shadow_vertices": smooth_shadow_data["vertices"],
        "smooth_shadow_normals": smooth_shadow_data["normals"],
        "smooth_shadow_indices": smooth_shadow_data["indices"],
        "position": Vector3(
            world_min_x + float(start_voxel_x) * VOXEL_SIZE,
            0.0,
            world_min_z + float(start_voxel_z) * VOXEL_SIZE
        ),
        "has_geometry": not _indices.is_empty(),
        "want_collision": want_collision,
        "worker_started_usec": worker_started_usec
    }

    # Use a coarse shared 20 cm height lattice for collision rather than a concave triangle mesh.
    # This matches the current surface-column model and avoids rebuilding a collision BVH.
    if want_collision and build_collision:
        var collision_step_voxels: int = 2
        var collision_width: int = int(size_voxels_x / collision_step_voxels) + 1
        var collision_depth: int = int(size_voxels_z / collision_step_voxels) + 1
        var collision_heights := PackedFloat32Array()
        collision_heights.resize(collision_width * collision_depth)
        for cz in range(collision_depth):
            var global_z: float = float(start_voxel_z + cz * collision_step_voxels)
            for cx in range(collision_width):
                var global_x: float = float(start_voxel_x + cx * collision_step_voxels)
                var height_voxels: int = _cached_height_voxels(global_x, global_z, height_cache, cache_width, cache_depth, cache_origin_x, cache_origin_z, cache_step_voxels, world_size_voxels)
                # HeightMapShape3D has a uniform 0.2 scale, so halve the 10 cm voxel count.
                collision_heights[cz * collision_width + cx] = float(height_voxels) * 0.5
        result["collision_height_map"] = {
            "width": collision_width,
            "depth": collision_depth,
            "heights": collision_heights,
            "step_m": float(collision_step_voxels) * VOXEL_SIZE
        }
    result["build_usec"] = Time.get_ticks_usec() - build_started_usec
    return result


func _build_smooth_shadow_surface(
    generator: VoxelTerrainGenerator,
    p_lod: int,
    world_min_x: float,
    world_min_z: float,
    start_voxel_x: int,
    start_voxel_z: int,
    size_voxels_x: int,
    size_voxels_z: int,
    height_cache: PackedFloat32Array,
    cache_width: int,
    cache_depth: int,
    cache_origin_x: int,
    cache_origin_z: int,
    cache_step_voxels: int
) -> Dictionary:
    # The shadow-only surface stays continuous. Its sample spacing is aligned with the
    # cache lattice whenever possible, allowing the same continuous noise samples to be reused.
    var shadow_step_voxels: int
    if p_lod <= 1:
        shadow_step_voxels = 5
    elif p_lod == 2:
        shadow_step_voxels = 10
    elif p_lod <= 4:
        shadow_step_voxels = 24 << (p_lod - 3)
    else:
        shadow_step_voxels = 160 << (p_lod - 5)
    var shadow_cells_x: int = ceili(float(size_voxels_x) / float(shadow_step_voxels))
    var shadow_cells_z: int = ceili(float(size_voxels_z) / float(shadow_step_voxels))
    var shadow_width: int = shadow_cells_x + 1
    var shadow_depth: int = shadow_cells_z + 1

    var shadow_vertices := PackedVector3Array()
    var shadow_normals := PackedVector3Array()
    var shadow_indices := PackedInt32Array()
    shadow_vertices.resize(shadow_width * shadow_depth)
    shadow_normals.resize(shadow_width * shadow_depth)
    shadow_indices.resize(shadow_cells_x * shadow_cells_z * 6)

    for z in range(shadow_depth):
        var local_voxel_z: int = mini(z * shadow_step_voxels, size_voxels_z)
        var world_z: float = world_min_z + float(start_voxel_z + local_voxel_z) * VOXEL_SIZE
        for x in range(shadow_width):
            var local_voxel_x: int = mini(x * shadow_step_voxels, size_voxels_x)
            var world_x: float = world_min_x + float(start_voxel_x + local_voxel_x) * VOXEL_SIZE
            var vertex_index: int = z * shadow_width + x
            # Reuse the continuous height cache for samples that lie exactly on its grid.
            var global_voxel_x: int = start_voxel_x + local_voxel_x
            var global_voxel_z: int = start_voxel_z + local_voxel_z
            var cache_dx: int = global_voxel_x - cache_origin_x
            var cache_dz: int = global_voxel_z - cache_origin_z
            var height_m: float
            if cache_step_voxels > 0 and cache_dx >= 0 and cache_dz >= 0 and cache_dx % cache_step_voxels == 0 and cache_dz % cache_step_voxels == 0:
                var cache_x: int = int(cache_dx / cache_step_voxels)
                var cache_z: int = int(cache_dz / cache_step_voxels)
                if cache_x >= 0 and cache_x < cache_width and cache_z >= 0 and cache_z < cache_depth:
                    height_m = height_cache[cache_z * cache_width + cache_x] * VOXEL_SIZE
                else:
                    height_m = generator.get_surface_height(world_x, world_z)
            else:
                height_m = generator.get_surface_height(world_x, world_z)
            shadow_vertices[vertex_index] = Vector3(
                float(local_voxel_x) * VOXEL_SIZE,
                height_m,
                float(local_voxel_z) * VOXEL_SIZE
            )
            shadow_normals[vertex_index] = Vector3.UP

    var index_cursor: int = 0
    for z in range(shadow_cells_z):
        for x in range(shadow_cells_x):
            var top_left: int = z * shadow_width + x
            var top_right: int = top_left + 1
            var bottom_left: int = top_left + shadow_width
            var bottom_right: int = bottom_left + 1
            # Winding is upward-facing so the shadow map treats the heightfield as solid terrain.
            shadow_indices[index_cursor] = top_left
            shadow_indices[index_cursor + 1] = bottom_left
            shadow_indices[index_cursor + 2] = top_right
            shadow_indices[index_cursor + 3] = top_right
            shadow_indices[index_cursor + 4] = bottom_left
            shadow_indices[index_cursor + 5] = bottom_right
            index_cursor += 6

    return {
        "vertices": shadow_vertices,
        "normals": shadow_normals,
        "indices": shadow_indices
    }

func _build_greedy_top_faces(
    heights: PackedInt32Array,
    surface_types: PackedByteArray,
    surface_rock_weights: PackedFloat32Array,
    grid_width: int,
    halo: int,
    cells_x: int,
    cells_z: int,
    cell_size: float,
    step_voxels: int
) -> void:
    var visited := PackedByteArray()
    visited.resize(cells_x * cells_z)
    visited.fill(0)

    for z in range(cells_z):
        for x in range(cells_x):
            var cell_index: int = z * cells_x + x
            if visited[cell_index] != 0:
                continue
            var grid_index: int = _grid_index(x, z, grid_width, halo)
            var height_voxels: int = heights[grid_index]
            var material_type: int = surface_types[cell_index]
            var base_rock_weight: float = _surface_rock_weight(surface_rock_weights, cells_x, x, z)
            var run_x: int = 1
            while x + run_x < cells_x:
                var next_cell: int = z * cells_x + x + run_x
                if visited[next_cell] != 0:
                    break
                var next_grid: int = _grid_index(x + run_x, z, grid_width, halo)
                if heights[next_grid] != height_voxels or surface_types[next_cell] != material_type:
                    break
                if absf(_surface_rock_weight(surface_rock_weights, cells_x, x + run_x, z) - base_rock_weight) > 0.10:
                    break
                run_x += 1

            var run_z: int = 1
            while z + run_z < cells_z:
                var can_extend: bool = true
                for dx in range(run_x):
                    var test_cell: int = (z + run_z) * cells_x + x + dx
                    var test_grid: int = _grid_index(x + dx, z + run_z, grid_width, halo)
                    if visited[test_cell] != 0 or heights[test_grid] != height_voxels or surface_types[test_cell] != material_type:
                        can_extend = false
                        break
                    if absf(_surface_rock_weight(surface_rock_weights, cells_x, x + dx, z + run_z) - base_rock_weight) > 0.10:
                        can_extend = false
                        break
                if not can_extend:
                    break
                run_z += 1

            for dz in range(run_z):
                for dx in range(run_x):
                    visited[(z + dz) * cells_x + x + dx] = 1

            var x0: float = float(x * step_voxels) * VOXEL_SIZE
            var x1: float = float((x + run_x) * step_voxels) * VOXEL_SIZE
            var z0: float = float(z * step_voxels) * VOXEL_SIZE
            var z1: float = float((z + run_z) * step_voxels) * VOXEL_SIZE
            var y: float = float(height_voxels) * VOXEL_SIZE
            var weight_0: float = _average_surface_rock_weight(surface_rock_weights, cells_x, x, z)
            var weight_1: float = _average_surface_rock_weight(surface_rock_weights, cells_x, x, z + run_z)
            var weight_2: float = _average_surface_rock_weight(surface_rock_weights, cells_x, x + run_x, z + run_z)
            var weight_3: float = _average_surface_rock_weight(surface_rock_weights, cells_x, x + run_x, z)
            _add_quad_vertex_colors(
                Vector3(x0, y, z0), Vector3(x0, y, z1),
                Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3.UP,
                _top_face_color(material_type, weight_0),
                _top_face_color(material_type, weight_1),
                _top_face_color(material_type, weight_2),
                _top_face_color(material_type, weight_3)
            )

func _surface_rock_weight(weights: PackedFloat32Array, cells_x: int, cell_x: int, cell_z: int) -> float:
    return weights[(cell_z + 1) * (cells_x + 2) + cell_x + 1]


func _average_surface_rock_weight(weights: PackedFloat32Array, cells_x: int, corner_x: int, corner_z: int) -> float:
    var total: float = 0.0
    for dz in range(corner_z - 1, corner_z + 1):
        for dx in range(corner_x - 1, corner_x + 1):
            total += _surface_rock_weight(weights, cells_x, dx, dz)
    return total * 0.25


func _top_face_color(material_type: int, rock_weight: float) -> Color:
    var color: Color = _material_color(material_type)
    # Stable byte codes 246..252 encode the grass/rock blend independently of skirt tags.
    color.a = float(246 + roundi(clampf(rock_weight, 0.0, 1.0) * 6.0)) / 255.0
    return color


func _build_exposed_side_faces(
    heights: PackedInt32Array,
    surface_types: PackedByteArray,
    surface_rock_weights: PackedFloat32Array,
    grid_width: int,
    halo: int,
    cells_x: int,
    cells_z: int,
    step_voxels: int
) -> void:
    # Merge consecutive side faces that share both height levels and material weights.
    for x in range(cells_x):
        _emit_side_runs_x(heights, surface_types, surface_rock_weights, grid_width, halo, cells_x, cells_z, step_voxels, x, false)
        _emit_side_runs_x(heights, surface_types, surface_rock_weights, grid_width, halo, cells_x, cells_z, step_voxels, x, true)
    for z in range(cells_z):
        _emit_side_runs_z(heights, surface_types, surface_rock_weights, grid_width, halo, cells_x, cells_z, step_voxels, z, false)
        _emit_side_runs_z(heights, surface_types, surface_rock_weights, grid_width, halo, cells_x, cells_z, step_voxels, z, true)


func _emit_side_runs_x(
    heights: PackedInt32Array, surface_types: PackedByteArray, surface_rock_weights: PackedFloat32Array,
    grid_width: int, halo: int, cells_x: int, cells_z: int, step_voxels: int,
    x: int, right_side: bool
) -> void:
    var x_voxels: int = (x + (1 if right_side else 0)) * step_voxels
    var x_pos: float = float(x_voxels) * VOXEL_SIZE
    var neighbour_x: int = x + (1 if right_side else -1)
    var z: int = 0
    while z < cells_z:
        var h: int = heights[_grid_index(x, z, grid_width, halo)]
        var other_h: int = heights[_grid_index(neighbour_x, z, grid_width, halo)]
        if h <= other_h:
            z += 1
            continue
        var cell_index: int = z * cells_x + x
        var material: int = int(surface_types[cell_index])
        var base_weight: float = _surface_rock_weight(surface_rock_weights, cells_x, x, z)
        var weight_sum: float = base_weight
        var run: int = 1
        while z + run < cells_z:
            var next_h: int = heights[_grid_index(x, z + run, grid_width, halo)]
            var next_other_h: int = heights[_grid_index(neighbour_x, z + run, grid_width, halo)]
            var next_material: int = int(surface_types[(z + run) * cells_x + x])
            var next_weight: float = _surface_rock_weight(surface_rock_weights, cells_x, x, z + run)
            if next_h != h or next_other_h != other_h or next_material != material or absf(next_weight - base_weight) > 0.10:
                break
            weight_sum += next_weight
            run += 1
        var z0: float = float(z * step_voxels) * VOXEL_SIZE
        var z1: float = float(mini((z + run) * step_voxels, cells_z * step_voxels)) * VOXEL_SIZE
        var low_m: float = float(other_h) * VOXEL_SIZE
        var high_m: float = float(h) * VOXEL_SIZE
        if right_side:
            _add_segmented_side_face(
                Vector3(x_pos, low_m, z0), Vector3(x_pos, low_m, z0),
                Vector3(x_pos, high_m, z1), Vector3(x_pos, low_m, z1),
                Vector3.RIGHT, other_h, h, material, true, 1.0, weight_sum / float(run)
            )
        else:
            _add_segmented_side_face(
                Vector3(x_pos, low_m, z1), Vector3(x_pos, high_m, z1),
                Vector3(x_pos, high_m, z0), Vector3(x_pos, low_m, z0),
                Vector3.LEFT, other_h, h, material, true, 1.0, weight_sum / float(run)
            )
        z += run


func _emit_side_runs_z(
    heights: PackedInt32Array, surface_types: PackedByteArray, surface_rock_weights: PackedFloat32Array,
    grid_width: int, halo: int, cells_x: int, cells_z: int, step_voxels: int,
    z: int, south_side: bool
) -> void:
    var z_voxels: int = (z + (1 if south_side else 0)) * step_voxels
    var z_pos: float = float(z_voxels) * VOXEL_SIZE
    var neighbour_z: int = z + (1 if south_side else -1)
    var x: int = 0
    while x < cells_x:
        var h: int = heights[_grid_index(x, z, grid_width, halo)]
        var other_h: int = heights[_grid_index(x, neighbour_z, grid_width, halo)]
        if h <= other_h:
            x += 1
            continue
        var cell_index: int = z * cells_x + x
        var material: int = int(surface_types[cell_index])
        var base_weight: float = _surface_rock_weight(surface_rock_weights, cells_x, x, z)
        var weight_sum: float = base_weight
        var run: int = 1
        while x + run < cells_x:
            var next_h: int = heights[_grid_index(x + run, z, grid_width, halo)]
            var next_other_h: int = heights[_grid_index(x + run, neighbour_z, grid_width, halo)]
            var next_material: int = int(surface_types[z * cells_x + x + run])
            var next_weight: float = _surface_rock_weight(surface_rock_weights, cells_x, x + run, z)
            if next_h != h or next_other_h != other_h or next_material != material or absf(next_weight - base_weight) > 0.10:
                break
            weight_sum += next_weight
            run += 1
        var x0: float = float(x * step_voxels) * VOXEL_SIZE
        var x1: float = float(mini((x + run) * step_voxels, cells_x * step_voxels)) * VOXEL_SIZE
        var low_m: float = float(other_h) * VOXEL_SIZE
        var high_m: float = float(h) * VOXEL_SIZE
        if south_side:
            _add_segmented_side_face(
                Vector3(x0, low_m, z_pos), Vector3(x1, low_m, z_pos),
                Vector3(x1, high_m, z_pos), Vector3(x0, high_m, z_pos),
                Vector3(0.0, 0.0, 1.0), other_h, h, material, false, 1.0, weight_sum / float(run)
            )
        else:
            _add_segmented_side_face(
                Vector3(x1, low_m, z_pos), Vector3(x0, low_m, z_pos),
                Vector3(x0, high_m, z_pos), Vector3(x1, high_m, z_pos),
                Vector3(0.0, 0.0, -1.0), other_h, h, material, false, 1.0, weight_sum / float(run)
            )
        x += run


func _build_lod_skirts(heights: PackedInt32Array, surface_types: PackedByteArray, grid_width: int, halo: int, cells_x: int, cells_z: int, step_voxels: int, neighbor_lods: Dictionary) -> void:
    # Skirts are baked on all internal borders. Runtime masks also keep them visible while a
    # neighbouring mesh is absent or stale, then hide them once equal-LOD geometry is ready.
    # Their top aligns to the lower of the two local halo samples to avoid overlapping ordinary walls.
    var x0: float = 0.0
    var x1: float = float(cells_x * step_voxels) * VOXEL_SIZE
    var z0: float = 0.0
    var z1: float = float(cells_z * step_voxels) * VOXEL_SIZE
    var skirt_depth_voxels: int = maxi(LOD_SKIRT_DEPTH_VOXELS, step_voxels * 8)
    if int(neighbor_lods.get("left", -1)) >= 0:
        for z in range(cells_z):
            var h: int = heights[_grid_index(0, z, grid_width, halo)]
            var outer_h: int = heights[_grid_index(-1, z, grid_width, halo)]
            var top: int = mini(h, outer_h)
            var low: int = maxi(0, top - skirt_depth_voxels)
            _add_segmented_side_face(Vector3(x0, float(low) * VOXEL_SIZE, float(z + 1) * step_voxels * VOXEL_SIZE), Vector3(x0, float(top) * VOXEL_SIZE, float(z + 1) * step_voxels * VOXEL_SIZE), Vector3(x0, float(top) * VOXEL_SIZE, float(z) * step_voxels * VOXEL_SIZE), Vector3(x0, float(low) * VOXEL_SIZE, float(z) * step_voxels * VOXEL_SIZE), Vector3.LEFT, low, top, int(surface_types[z * cells_x]), true, SKIRT_ALPHA_LEFT)
    if int(neighbor_lods.get("right", -1)) >= 0:
        for z in range(cells_z):
            var h: int = heights[_grid_index(cells_x - 1, z, grid_width, halo)]
            var outer_h: int = heights[_grid_index(cells_x, z, grid_width, halo)]
            var top: int = mini(h, outer_h)
            var low: int = maxi(0, top - skirt_depth_voxels)
            _add_segmented_side_face(Vector3(x1, float(low) * VOXEL_SIZE, float(z) * step_voxels * VOXEL_SIZE), Vector3(x1, float(top) * VOXEL_SIZE, float(z) * step_voxels * VOXEL_SIZE), Vector3(x1, float(top) * VOXEL_SIZE, float(z + 1) * step_voxels * VOXEL_SIZE), Vector3(x1, float(low) * VOXEL_SIZE, float(z + 1) * step_voxels * VOXEL_SIZE), Vector3.RIGHT, low, top, int(surface_types[z * cells_x + cells_x - 1]), true, SKIRT_ALPHA_RIGHT)
    if int(neighbor_lods.get("north", -1)) >= 0:
        for x in range(cells_x):
            var h: int = heights[_grid_index(x, 0, grid_width, halo)]
            var outer_h: int = heights[_grid_index(x, -1, grid_width, halo)]
            var top: int = mini(h, outer_h)
            var low: int = maxi(0, top - skirt_depth_voxels)
            _add_segmented_side_face(Vector3(float(x + 1) * step_voxels * VOXEL_SIZE, float(low) * VOXEL_SIZE, z0), Vector3(float(x) * step_voxels * VOXEL_SIZE, float(low) * VOXEL_SIZE, z0), Vector3(float(x) * step_voxels * VOXEL_SIZE, float(top) * VOXEL_SIZE, z0), Vector3(float(x + 1) * step_voxels * VOXEL_SIZE, float(top) * VOXEL_SIZE, z0), Vector3(0.0, 0.0, -1.0), low, top, int(surface_types[x]), false, SKIRT_ALPHA_NORTH)
    if int(neighbor_lods.get("south", -1)) >= 0:
        for x in range(cells_x):
            var h: int = heights[_grid_index(x, cells_z - 1, grid_width, halo)]
            var outer_h: int = heights[_grid_index(x, cells_z, grid_width, halo)]
            var top: int = mini(h, outer_h)
            var low: int = maxi(0, top - skirt_depth_voxels)
            _add_segmented_side_face(Vector3(float(x) * step_voxels * VOXEL_SIZE, float(low) * VOXEL_SIZE, z1), Vector3(float(x + 1) * step_voxels * VOXEL_SIZE, float(low) * VOXEL_SIZE, z1), Vector3(float(x + 1) * step_voxels * VOXEL_SIZE, float(top) * VOXEL_SIZE, z1), Vector3(float(x) * step_voxels * VOXEL_SIZE, float(top) * VOXEL_SIZE, z1), Vector3(0.0, 0.0, 1.0), low, top, int(surface_types[(cells_z - 1) * cells_x + x]), false, SKIRT_ALPHA_SOUTH)

func _sample_height_voxel_units(
    global_voxel_x: float,
    global_voxel_z: float,
    generator: VoxelTerrainGenerator,
    world_min_x: float,
    world_min_z: float,
    world_size_voxels: int
) -> float:
    if global_voxel_x < 0.0 or global_voxel_z < 0.0 or global_voxel_x >= float(world_size_voxels) or global_voxel_z >= float(world_size_voxels):
        return 0.0
    var world_x: float = world_min_x + global_voxel_x * VOXEL_SIZE
    var world_z: float = world_min_z + global_voxel_z * VOXEL_SIZE
    return maxf(1.0, generator.get_surface_height(world_x, world_z) / VOXEL_SIZE)

func _grid_index(x: int, z: int, grid_width: int, halo: int) -> int:
    return (z + halo) * grid_width + x + halo

func _add_segmented_side_face(
    p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
    normal: Vector3, low_height_voxels: int, high_height_voxels: int,
    top_material: int, vertical_first: bool, edge_alpha: float = 1.0,
    surface_rock_weight: float = -1.0
) -> void:
    if high_height_voxels <= low_height_voxels:
        return
    var point_a := Vector3(p0.x, 0.0, p0.z)
    var point_b: Vector3 = Vector3(p3.x, 0.0, p3.z) if vertical_first else Vector3(p1.x, 0.0, p1.z)

    if edge_alpha >= 0.95:
        # The upper exposed voxel carries the same blend as its top face.
        var top_start: int = maxi(low_height_voxels, high_height_voxels - _active_step_voxels)
        var encoded_alpha: float = -1.0
        if surface_rock_weight >= 0.0:
            # Stable 8-bit codes 240..245 keep grassy sides outside the skirt discard range.
            encoded_alpha = float(240 + roundi(clampf(surface_rock_weight, 0.0, 1.0) * 5.0)) / 255.0
        if lod >= 3:
            # Distant layer detail is sub-pixel; keep a voxel riser with only one lower band.
            var lower_material: int = VoxelTerrainGenerator.ROCK if top_material == VoxelTerrainGenerator.ROCK else VoxelTerrainGenerator.SOIL
            _emit_side_segment(point_a, point_b, normal, low_height_voxels, top_start, lower_material, vertical_first, edge_alpha)
        elif top_material == VoxelTerrainGenerator.ROCK:
            _emit_side_segment(point_a, point_b, normal, low_height_voxels, top_start, VoxelTerrainGenerator.ROCK, vertical_first, edge_alpha)
        else:
            var soil_start: int = maxi(low_height_voxels, high_height_voxels - _active_step_voxels * 5)
            _emit_side_segment(point_a, point_b, normal, low_height_voxels, soil_start, VoxelTerrainGenerator.ROCK, vertical_first, edge_alpha)
            _emit_side_segment(point_a, point_b, normal, soil_start, top_start, VoxelTerrainGenerator.SOIL, vertical_first, edge_alpha)
        _emit_side_segment(point_a, point_b, normal, top_start, high_height_voxels, top_material, vertical_first, edge_alpha, encoded_alpha)
        return

    # Stitching skirts are geometric seams; distant LODs only need one continuous band.
    if lod >= 3:
        var lower_material: int = VoxelTerrainGenerator.ROCK if top_material == VoxelTerrainGenerator.ROCK else VoxelTerrainGenerator.SOIL
        _emit_side_segment(point_a, point_b, normal, low_height_voxels, high_height_voxels, lower_material, vertical_first, edge_alpha)
        return
    if top_material == VoxelTerrainGenerator.ROCK:
        _emit_side_segment(point_a, point_b, normal, low_height_voxels, high_height_voxels, VoxelTerrainGenerator.ROCK, vertical_first, edge_alpha)
        return
    var skirt_top_start: int = maxi(low_height_voxels, high_height_voxels - _active_step_voxels)
    var skirt_soil_start: int = maxi(low_height_voxels, high_height_voxels - _active_step_voxels * 5)
    _emit_side_segment(point_a, point_b, normal, low_height_voxels, skirt_soil_start, VoxelTerrainGenerator.ROCK, vertical_first, edge_alpha)
    _emit_side_segment(point_a, point_b, normal, skirt_soil_start, skirt_top_start, VoxelTerrainGenerator.SOIL, vertical_first, edge_alpha)
    _emit_side_segment(point_a, point_b, normal, skirt_top_start, high_height_voxels, top_material, vertical_first, edge_alpha)


func _emit_side_segment(
    point_a: Vector3, point_b: Vector3, normal: Vector3,
    low_y: int, high_y: int, material_type: int, vertical_first: bool,
    edge_alpha: float = 1.0, encoded_alpha: float = -1.0
) -> void:
    if high_y <= low_y:
        return
    var low_m: float = float(low_y) * VOXEL_SIZE
    var high_m: float = float(high_y) * VOXEL_SIZE
    var a_low := Vector3(point_a.x, low_m, point_a.z)
    var a_high := Vector3(point_a.x, high_m, point_a.z)
    var b_low := Vector3(point_b.x, low_m, point_b.z)
    var b_high := Vector3(point_b.x, high_m, point_b.z)
    var side_color: Color = _material_color(material_type)
    if encoded_alpha >= 0.0:
        side_color.a = encoded_alpha
    elif edge_alpha < 0.95:
        side_color.a = edge_alpha
    if vertical_first:
        _add_quad(a_low, a_high, b_high, b_low, normal, side_color)
    else:
        _add_quad(a_low, b_low, b_high, a_high, normal, side_color)


func _side_material_at_height(y: int, high_height_voxels: int, top_material: int) -> int:
    if top_material == VoxelTerrainGenerator.ROCK:
        return VoxelTerrainGenerator.ROCK
    if y >= high_height_voxels - 1:
        return top_material
    if y >= high_height_voxels - 5:
        return VoxelTerrainGenerator.SOIL
    return VoxelTerrainGenerator.ROCK

func _material_color(material_type: int) -> Color:
    # LOD diagnostic colours are selected by a shader uniform instead of baked vertices.
    match material_type:
        VoxelTerrainGenerator.GRASS:
            return Color("#36a42a")
        VoxelTerrainGenerator.SOIL:
            return Color("#806044")
        VoxelTerrainGenerator.ROCK:
            return Color("#777973")
        _:
            return Color.WHITE

func _add_quad_vertex_colors(
    p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, normal: Vector3,
    color0: Color, color1: Color, color2: Color, color3: Color
) -> void:
    var base_index: int = _vertices.size()
    _vertices.append(p0)
    _vertices.append(p1)
    _vertices.append(p2)
    _vertices.append(p3)
    for _i in range(4):
        _normals.append(normal)
    _colors.append(color0)
    _colors.append(color1)
    _colors.append(color2)
    _colors.append(color3)
    _indices.append(base_index)
    _indices.append(base_index + 2)
    _indices.append(base_index + 1)
    _indices.append(base_index)
    _indices.append(base_index + 3)
    _indices.append(base_index + 2)


func _add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, normal: Vector3, color: Color) -> void:
    var base_index: int = _vertices.size()
    _vertices.append(p0)
    _vertices.append(p1)
    _vertices.append(p2)
    _vertices.append(p3)
    for _i in range(4):
        _normals.append(normal)
        _colors.append(color)
    # Godot treats clockwise triangles as front-facing. The quad vertices are
    # authored in outward-normal order (right-handed cross product points out),
    # so reverse the index winding to make the visible front face point outward.
    _indices.append(base_index)
    _indices.append(base_index + 2)
    _indices.append(base_index + 1)
    _indices.append(base_index)
    _indices.append(base_index + 3)
    _indices.append(base_index + 2)

