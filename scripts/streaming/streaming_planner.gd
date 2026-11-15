extends RefCounted
class_name StreamingPlanner

const LOD_KEY_STRIDE: int = 100000
const TERRAIN_SHADOW_DISTANCE_M: float = 640.0
const VOXEL_SIZE: float = 0.2


func collect_tile(
    lod_index: int,
    tile_x: int,
    tile_z: int,
    player_xz: Vector2,
    heading: Vector2,
    player_y: float,
    previous_wanted: Dictionary,
    wanted: Dictionary,
    config: Dictionary,
    surface_height: Callable
) -> void:
    # Keep the hot path allocation-light: bounds are calculated arithmetically.
    var key := Vector2i(lod_index * LOD_KEY_STRIDE + tile_x, tile_z)
    var world_size_voxels: int = int(config["world_size_voxels"])
    var chunk_size_voxels: int = int(config["chunk_size_voxels"])
    var tile_voxels: int = chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return

    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, world_size_voxels - start_z))
    if size_x <= 0 or size_z <= 0:
        return

    var world_min_x: float = float(config["world_min_x"])
    var world_min_z: float = float(config["world_min_z"])
    var origin_x: float = world_min_x + float(start_x) * VOXEL_SIZE
    var origin_z: float = world_min_z + float(start_z) * VOXEL_SIZE
    var width: float = float(size_x) * VOXEL_SIZE
    var depth: float = float(size_z) * VOXEL_SIZE
    var center := Vector2(origin_x + width * 0.5, origin_z + depth * 0.5)
    var nearest_x: float = clampf(player_xz.x, origin_x, origin_x + width)
    var nearest_z: float = clampf(player_xz.y, origin_z, origin_z + depth)
    var dx: float = player_xz.x - nearest_x
    var dz: float = player_xz.y - nearest_z
    var terrain_y: float = float(surface_height.call(nearest_x, nearest_z))
    var vertical_delta: float = player_y - terrain_y
    var nearest: float = sqrt(dx * dx + dz * dz + vertical_delta * vertical_delta)
    if nearest > float(config["render_distance_m"]):
        return

    var lod_boundaries: Array = config["lod_boundaries"]
    var boundary: float = float(lod_boundaries[clampi(lod_index - 1, 0, 6)]) if lod_index > 0 else -1.0
    if lod_index == 7:
        boundary = float(lod_boundaries[6])
    var previous: Dictionary = previous_wanted.get(key, {})
    var was_split: bool = bool(previous.get("fallback", false))
    var split: bool = false
    if lod_index > 0:
        var scaled_hysteresis: float = boundary * float(config["lod_hysteresis_ratio"])
        var threshold: float = boundary + scaled_hysteresis if was_split else maxf(0.0, boundary - scaled_hysteresis)
        split = nearest < threshold

    var horizontal_center_distance: float = center.distance_to(player_xz)
    var req := {
        "lod": lod_index, "fallback": split, "distance": nearest,
        "nearest_distance": nearest, "priority": horizontal_center_distance - maxf(0.0, (center - player_xz).dot(heading) * 0.30),
        "collision": lod_index == 0 and nearest <= float(config["collision_distance_m"]),
        "start_x": start_x, "start_z": start_z,
        "size_x": size_x, "size_z": size_z,
        "tile_x": tile_x, "tile_z": tile_z, "tile_size_m": float(config["chunk_size_m"]) * float(1 << lod_index),
        "step_voxels": 1 << clampi(lod_index, 0, 7),
        "shadow_proxy": nearest <= TERRAIN_SHADOW_DISTANCE_M
    }
    wanted[key] = req

    if split:
        for dz_offset in range(2):
            for dx_offset in range(2):
                collect_tile(
                    lod_index - 1, tile_x * 2 + dx_offset, tile_z * 2 + dz_offset,
                    player_xz, heading, player_y, previous_wanted, wanted, config, surface_height
                )
