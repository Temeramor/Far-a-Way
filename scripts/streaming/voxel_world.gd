extends Node3D
class_name VoxelWorld

signal terrain_seed_changed(new_seed: int)


const VOXEL_SIZE: float = 0.2
const LOD_KEY_STRIDE: int = 100000
const BASE_MESH_STEP_VOXELS: int = 1
const DESIGN_FOV_DEGREES: float = 82.0
const TERRAIN_SHADOW_DISTANCE_M: float = 640.0
const MAX_MESH_CACHE_BYTES: int = 48 * 1024 * 1024
const MAX_MESH_CACHE_ENTRIES: int = 32
const MAX_POOLED_CHUNK_NODES: int = 32
const GeneratorScript = preload("res://scripts/world/voxel_generator.gd")
const ChunkScript = preload("res://scripts/streaming/voxel_chunk.gd")

@export_category("Voxel world")
@export_range(256.0, 20000.0, 1.0) var world_size_m: float = 5000.0
@export_range(8.0, 32.0, 8.0) var chunk_size_m: float = 32.0
@export var seed_value: int = 1337
@export var auto_start_on_ready: bool = true

@export_category("Streaming and LOD")
@export_range(512.0, 2048.0, 256.0) var render_distance_m: float = 1536.0
const LOD_TRANSITION_PIXELS: float = 3.0
@export_range(0.02, 0.10, 0.01) var lod_hysteresis_ratio: float = 0.05
@export_range(1, 8, 1) var max_concurrent_mesh_jobs: int = 2
@export_range(1, 2, 1) var max_mesh_applies_per_frame: int = 1
@export_range(0.5, 3.0, 0.25) var max_mesh_apply_time_ms: float = 1.5
@export_range(0.05, 0.2, 0.01) var streaming_refresh_interval_s: float = 0.10
@export_range(2.0, 16.0, 2.0) var streaming_refresh_distance_m: float = 8.0
@export_range(0.5, 2.5, 0.1) var streaming_prediction_seconds: float = 1.4

@export_category("Collision")
@export_range(16.0, 128.0, 8.0) var collision_distance_m: float = 80.0

var _generator: VoxelTerrainGenerator
var _spawn_position_xz: Vector2 = Vector2.ZERO
var _mountain_profile_cache: Array[Dictionary] = []
var _voxel_material: ShaderMaterial
var _player: CharacterBody3D
var _chunks: Dictionary = {}
var _queued: Dictionary = {}
var _wanted: Dictionary = {}
var _running_tasks: Dictionary = {}
var _running_by_coord: Dictionary = {}
var _completed_jobs: Dictionary = {}
var lod_target_pixels: float = 3.0
var _mesh_cache: Dictionary = {}
var _mesh_cache_order: Array[String] = []
var _mesh_cache_bytes: int = 0
var _chunk_pool: Array[VoxelTerrainChunk] = []
var _retirement_queue: Array[VoxelTerrainChunk] = []
var _retirement_lookup: Dictionary = {}
var _refresh_timer: float = 0.0
var _debug_lod_colors: bool = false
var _last_player_position := Vector2(INF, INF)
var _last_player_height: float = INF
var _last_refresh_chunk := Vector2i(-2147483648, -2147483648)
var _last_viewport_size := Vector2i.ZERO
var _lod_boundaries_m: Array[float] = [INF, INF, INF, INF, INF, INF, INF]
var _hierarchy_visibility_dirty: bool = true
var _dirty_hierarchy_roots: Dictionary = {}
var _world_size_voxels: int
var _chunk_size_voxels: int
var _world_min_x: float
var _world_min_z: float
var _chunks_per_axis: int
var _retiring_chunks: Array[VoxelTerrainChunk] = []
var _generation_epoch: int = 0
var _startup_load_pending: bool = true
var _spawn_validation_in_progress: bool = false
var _build_usec_by_lod: Array = [[], [], [], [], [], [], [], []]
var _build_p95_cached_usec: Array[float] = [80000.0, 40000.0, 25000.0, 12000.0, 6000.0, 3000.0, 1500.0, 900.0]
var _refresh_usec_samples: Array[int] = []
var _refresh_p95_cached_usec: float = 0.0
var _queue_wait_usec_samples: Array[int] = []
var _apply_wait_usec_samples: Array[int] = []
var _queue_wait_p95_cached_usec: float = 0.0
var _apply_wait_p95_cached_usec: float = 0.0
var _build_estimate_refresh_timer: float = 0.0
var _max_queue_wait_usec: int = 0
var _stale_result_count: int = 0
var _world_started: bool = false
var _last_frame_delta_ms: float = 16.67
var _adaptive_apply_limit: int = 1

func _ready() -> void:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("VoxEn native extension is required. Build the Windows x86-64 GDExtension before running Far a Way.")
        set_process(false)
        set_physics_process(false)
        return
    var native_builder_check: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if native_builder_check == null:
        push_error("VoxEnBuilder is registered but could not be instantiated. Check the native library build.")
        set_process(false)
        set_physics_process(false)
        return
    native_builder_check = null
    _world_size_voxels = int(round(world_size_m / VOXEL_SIZE))
    _chunk_size_voxels = int(round(chunk_size_m / VOXEL_SIZE))
    _world_min_x = -world_size_m * 0.5
    _world_min_z = -world_size_m * 0.5
    _chunks_per_axis = int(ceil(float(_world_size_voxels) / float(_chunk_size_voxels)))
    render_distance_m = clampf(GameSettings.view_distance_m, 512.0, 2048.0)
    lod_target_pixels = clampf(GameSettings.lod_target_pixels, 2.0, 4.0)
    _last_viewport_size = _current_viewport_pixel_size()
    _refresh_lod_boundaries()
    _generator = GeneratorScript.new(seed_value, world_size_m)
    _mountain_profile_cache = _generator.get_mountain_profile()
    _spawn_position_xz = _generator.find_safe_spawn_position(chunk_size_m)
    if not is_finite(_spawn_position_xz.x) or not is_finite(_spawn_position_xz.y):
        push_error("Far a Way cannot start: no safe, flat, dry spawn area was found.")
        set_process(false)
        set_physics_process(false)
        return

    var surface_shader := load("res://shaders/voxel_surface.gdshader") as Shader
    _voxel_material = ShaderMaterial.new()
    _voxel_material.shader = surface_shader
    _apply_seed_to_material()

    _player = get_node_or_null(NodePath("../Player")) as CharacterBody3D
    if _player != null:
        # Do not let gravity move the player before the spawn chunk's collider exists.
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
        _player.global_position = Vector3(_spawn_position_xz.x, get_surface_height(_spawn_position_xz.x, _spawn_position_xz.y) + 8.0, _spawn_position_xz.y)
        _startup_load_pending = true

    if auto_start_on_ready:
        call_deferred("_prepare_world_for_epoch", _generation_epoch)

func _process(delta: float) -> void:
    _last_frame_delta_ms = delta * 1000.0
    if _last_frame_delta_ms >= 33.0:
        _adaptive_apply_limit = 1
    else:
        _adaptive_apply_limit = maxi(1, max_mesh_applies_per_frame)
    _build_estimate_refresh_timer += delta
    if _build_estimate_refresh_timer >= 0.5:
        _build_estimate_refresh_timer = 0.0
        _refresh_build_estimate_cache()

    var viewport_size := _current_viewport_pixel_size()
    var viewport_changed: bool = viewport_size != _last_viewport_size
    if viewport_changed:
        _last_viewport_size = viewport_size
        _refresh_lod_boundaries()
        _hierarchy_visibility_dirty = true

    _refresh_timer += delta
    if _refresh_timer >= streaming_refresh_interval_s and _world_started:
        _refresh_timer = 0.0
        if _player != null:
            var player_position := Vector2(_player.global_position.x, _player.global_position.z)
            var current_chunk := Vector2i(
                clampi(floori((player_position.x - _world_min_x) / chunk_size_m), 0, _chunks_per_axis - 1),
                clampi(floori((player_position.y - _world_min_z) / chunk_size_m), 0, _chunks_per_axis - 1)
            )
            # Altitude must refresh at the same cadence as horizontal travel so spherical LOD boundaries are responsive.
            var altitude_changed: bool = absf(_player.global_position.y - _last_player_height) >= maxf(1.0, streaming_refresh_distance_m)
            if viewport_changed or player_position.distance_to(_last_player_position) >= streaming_refresh_distance_m or altitude_changed or current_chunk != _last_refresh_chunk:
                _last_player_position = player_position
                _last_player_height = _player.global_position.y
                _last_refresh_chunk = current_chunk
                _refresh_streaming()

    _poll_worker_tasks()
    _apply_completed_jobs()
    _process_chunk_jobs()
    if _hierarchy_visibility_dirty:
        _reconcile_hierarchy_visibility()
        _hierarchy_visibility_dirty = false
        _dirty_hierarchy_roots.clear()
    elif not _dirty_hierarchy_roots.is_empty():
        var dirty_roots: Array = _dirty_hierarchy_roots.keys()
        _dirty_hierarchy_roots.clear()
        for root_key in dirty_roots:
            _update_lod_subtree_visibility(root_key, true)
    _retire_stale_resources()
    _try_finish_startup_loading()

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed and not event.echo):
        return
    # F3 is reserved for diagnostics. F4 changes only a shader uniform; chunks are not rebuilt.
    if event.keycode == KEY_F4 or event.physical_keycode == KEY_F4:
        _debug_lod_colors = not _debug_lod_colors
        if _voxel_material != null:
            _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)
        for chunk_value in _chunks.values():
            var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
            if chunk != null:
                chunk.set_mesh_shader_parameter("debug_lod_colors", _debug_lod_colors)
        get_viewport().set_input_as_handled()
    elif event.keycode == KEY_R:
        regenerate_with_random_seed()

func regenerate_with_random_seed() -> void:
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var next_seed: int = rng.randi_range(1, 2147483646)
    if next_seed == seed_value:
        next_seed = 1 if seed_value != 1 else 2
    regenerate_with_seed(next_seed)

func regenerate_with_seed(new_seed: int) -> void:
    # Existing worker tasks cannot be cancelled safely; their epoch makes their results stale.
    _world_started = false
    _generation_epoch += 1
    seed_value = new_seed
    _queued.clear()
    _wanted.clear()
    _completed_jobs.clear()
    _mesh_cache.clear()
    _mesh_cache_order.clear()
    _mesh_cache_bytes = 0

    # Hide the old world immediately; release mesh buffers gradually over later frames.
    # In-flight tasks finish, but their old epoch will reject their results.
    for chunk_value in _chunks.values():
        var old_chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        old_chunk.set_render_active(false)
        old_chunk._retire_current_generation()
        remove_child(old_chunk)
        _retiring_chunks.append(old_chunk)
    _chunks.clear()

    _generator = GeneratorScript.new(seed_value, world_size_m)
    _mountain_profile_cache = _generator.get_mountain_profile()
    _spawn_position_xz = _generator.find_safe_spawn_position(chunk_size_m)
    if not is_finite(_spawn_position_xz.x) or not is_finite(_spawn_position_xz.y):
        push_error("Far a Way cannot regenerate: no safe, flat, dry spawn area was found for this seed.")
        _startup_load_pending = true
        _spawn_validation_in_progress = false
        return
    _spawn_validation_in_progress = false
    _apply_seed_to_material()
    terrain_seed_changed.emit(seed_value)
    if _player != null:
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
        var spawn_x: float = _spawn_position_xz.x
        var spawn_z: float = _spawn_position_xz.y
        _player.global_position = Vector3(spawn_x, get_surface_height(spawn_x, spawn_z) + 8.0, spawn_z)
        _startup_load_pending = true
    _last_player_position = Vector2(INF, INF)
    _last_player_height = INF
    _last_refresh_chunk = Vector2i(-2147483648, -2147483648)
    call_deferred("_prepare_world_for_epoch", _generation_epoch)

func _prepare_world_for_epoch(epoch: int) -> void:
    if epoch != _generation_epoch:
        return
    _world_started = true
    _refresh_timer = 0.0
    _last_player_position = Vector2(INF, INF)
    _last_refresh_chunk = Vector2i(-2147483648, -2147483648)
    _refresh_streaming()

func set_lod_settings(_legacy_lod0_distance: float) -> void:
    # Compatibility hook; LOD boundaries are screen-space based rather than fixed in metres.
    refresh_lod_boundaries()


func set_lod_target_pixels(target_pixels: float) -> void:
    lod_target_pixels = clampf(target_pixels, 2.0, 4.0)
    refresh_lod_boundaries()


func refresh_lod_boundaries() -> void:
    _refresh_lod_boundaries()
    if _world_started:
        _last_player_position = Vector2(INF, INF)
        _refresh_streaming()


func set_render_distance_m(distance_m: float) -> void:
    var safe_distance: float = snappedf(clampf(distance_m, 512.0, 2048.0), 256.0)
    if is_equal_approx(render_distance_m, safe_distance):
        return
    render_distance_m = safe_distance
    if _world_started:
        _last_player_position = Vector2(INF, INF)
        _refresh_streaming()


func set_shadow_mode(mode: int) -> void:
    var safe_mode: int = clampi(mode, 0, 1)
    for chunk_value in _chunks.values():
        var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        if chunk != null:
            chunk.set_shadow_mode(safe_mode)


func get_lod_boundary_m(lod_index: int) -> float:
    if lod_index < 0 or lod_index > 6:
        return INF
    return _lod_boundaries_m[lod_index]


func _refresh_lod_boundaries() -> void:
    var screen_height: float = float(maxi(1, _current_viewport_pixel_size().y))
    for i in range(_lod_boundaries_m.size()):
        _lod_boundaries_m[i] = get_lod_boundary_m_for_height(i, screen_height, lod_target_pixels)


func get_lod_boundary_m_for_height(lod_index: int, screen_height: float, target_pixels: float = -1.0) -> float:
    # Switch when the next coarser cell reaches the selected screen-space pixel target.
    # This keeps the visible cell footprint near the chosen 2-4 px quality/performance band.
    if lod_index < 0 or lod_index > 6:
        return INF
    var safe_height: float = maxf(screen_height, 1.0)
    var pixel_target: float = lod_target_pixels if target_pixels <= 0.0 else clampf(target_pixels, 1.0, 4.0)
    var fov_degrees: float = DESIGN_FOV_DEGREES
    if _player != null:
        var player_camera := _player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
        if player_camera != null:
            fov_degrees = player_camera.fov
    var projection_scale: float = safe_height / (2.0 * tan(deg_to_rad(clampf(fov_degrees, 30.0, 120.0)) * 0.5))
    var next_cell_size_m: float = float(get_mesh_step_voxels(lod_index + 1)) * VOXEL_SIZE
    return next_cell_size_m * projection_scale / pixel_target


func _current_viewport_pixel_size() -> Vector2i:
    var viewport_size: Vector2i = get_viewport().size
    return Vector2i(maxi(1, viewport_size.x), maxi(1, viewport_size.y))


func get_mesh_step_voxels(lod_index: int) -> int:
    # Each LOD doubles cell size: 20 cm, 40 cm, 80 cm ... up to 25.6 m.
    # The former LOD0 -> LOD1 jump was 4x and left the map rim visibly over-coarsened.
    var tier: int = clampi(lod_index, 0, 7)
    return BASE_MESH_STEP_VOXELS << tier


func is_terrain_shadow_ready() -> bool:
    # Legacy API used by the loading UI. Each active LOD chunk owns its invisible terrain-shadow proxy.
    return is_world_coverage_ready()

func is_world_coverage_ready() -> bool:
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            var root_key := _make_lod_key(7, tx, tz)
            if not _wanted.has(root_key):
                continue
            if not _lod_tile_coverage_ready(root_key):
                return false
    return true

func _apply_seed_to_material() -> void:
    if _voxel_material == null:
        return
    var safe_seed: int = abs(seed_value % 2147483647)
    _voxel_material.set_shader_parameter("seed_low", float(safe_seed % 65536))
    _voxel_material.set_shader_parameter("seed_high", float(int(floor(float(safe_seed) / 65536.0))))
    _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)


func get_surface_height(x: float, z: float) -> float:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
        _mountain_profile_cache = _generator.get_mountain_profile()
    return _generator.get_surface_height(x, z)

func get_voxel_material(global_voxel: Vector3i) -> int:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
        _mountain_profile_cache = _generator.get_mountain_profile()
    return _generator.get_voxel_material(global_voxel, _world_min_x, _world_min_z, _world_size_voxels)

func get_debug_text() -> String:
    var lod_counts: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
    var collider_count: int = 0
    var near_pending: int = 0
    var render_vertices: int = 0
    var render_indices: int = 0
    var estimated_mesh_bytes: int = 0
    var shadow_vertices: int = 0
    for coord_value in _chunks.keys():
        var chunk: VoxelTerrainChunk = _chunks[coord_value] as VoxelTerrainChunk
        if chunk.lod >= 0 and chunk.lod < lod_counts.size():
            lod_counts[chunk.lod] += 1
        if chunk.collision_active:
            collider_count += 1
        render_vertices += chunk.render_vertex_count
        render_indices += chunk.render_index_count
        estimated_mesh_bytes += chunk.estimated_mesh_bytes
        shadow_vertices += chunk.shadow_vertex_count
    for coord_value in _wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _wanted[coord]
        if float(request.get("nearest_distance", INF)) > 40.0:
            continue
        var near_chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if near_chunk == null or not near_chunk.mesh_ready or near_chunk.lod != int(request["lod"]):
            near_pending += 1
    var l0: Array = _build_usec_by_lod[0]
    var l1: Array = _build_usec_by_lod[1]
    var planar_speed: float = 0.0
    if _player != null:
        planar_speed = Vector2(_player.velocity.x, _player.velocity.z).length()
    var prediction_seconds: float = _effective_prediction_seconds()
    var estimated_work_seconds: float = _estimated_lod_pipeline_usec(0) / 1000000.0
    var lead_margin_m: float = planar_speed * (prediction_seconds - estimated_work_seconds)
    var builder_mode: String = "NATIVE C++" if ClassDB.class_exists("VoxEnNativeBuilder") else "NATIVE C++ MISSING"
    var fps: int = Engine.get_frames_per_second()
    var frame_ms: float = 1000.0 / maxf(float(fps), 1.0)
    var video_memory_mb: float = float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
    var primitives: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
    var mesh_memory_mb: float = float(estimated_mesh_bytes) / 1048576.0
    return "VoxEn diagnostics | %s | FPS %d (%.1f ms) | seed %d | chunks %d | LOD 0:%d 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d 7:%d | verts %d | indices %d | mesh est. %.1f MiB | GPU %.1f MiB | prims %d | shadow verts %d | colliders %d | jobs %d running + %d queued | near pending %d | stale %d | cache %d entries / %.1f MiB | pool %d\nBuild avg/p95 ms: L0 %.1f/%.1f L1 %.1f/%.1f | refresh p95 %.2f ms | queue p95/max %.0f/%.1f ms | apply p95 %.0f ms | L0 margin %.1f m (pred %.1fs)\nControls: F3 diagnostics | M weather/time | Esc pause" % [
        builder_mode, fps, frame_ms,
        seed_value, _chunks.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4], lod_counts[5], lod_counts[6], lod_counts[7],
        render_vertices, render_indices, mesh_memory_mb, video_memory_mb, primitives, shadow_vertices,
        collider_count, _running_tasks.size(), _queued.size(), near_pending, _stale_result_count,
        _mesh_cache.size(), float(_mesh_cache_bytes) / 1048576.0, _chunk_pool.size(),
        _avg_ms(l0), _build_p95_cached_usec[0] / 1000.0, _avg_ms(l1), _build_p95_cached_usec[1] / 1000.0,
        _refresh_p95_cached_usec / 1000.0, _queue_wait_p95_cached_usec / 1000.0,
        float(_max_queue_wait_usec) / 1000.0, _apply_wait_p95_cached_usec / 1000.0,
        lead_margin_m, prediction_seconds
    ]

func is_startup_loading() -> bool:
    return _startup_load_pending

func get_loaded_chunk_count() -> int:
    return _chunks.size()

func get_startup_progress() -> float:
    if not _startup_load_pending:
        return 1.0
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    var roots_total: int = 0
    var roots_ready: int = 0
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            var root_key := _make_lod_key(7, tx, tz)
            if not _wanted.has(root_key):
                continue
            roots_total += 1
            if _lod_tile_coverage_ready(root_key):
                roots_ready += 1
    if roots_ready < roots_total:
        return clampf(0.05 + 0.60 * float(roots_ready) / float(maxi(roots_total, 1)), 0.05, 0.65)
    var near_total: int = 0
    var near_ready: int = 0
    for coord_value in _wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _wanted[coord]
        if bool(request.get("fallback", false)) or float(request.get("nearest_distance", INF)) > minf(256.0, render_distance_m):
            continue
        near_total += 1
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk != null and chunk.mesh_ready:
            near_ready += 1
    return clampf(0.65 + 0.30 * float(near_ready) / float(maxi(near_total, 1)), 0.65, 0.95)

func surface_sample_at_world(world_x: float, world_z: float) -> Vector3:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
        _mountain_profile_cache = _generator.get_mountain_profile()
    return _generator.get_surface_sample(world_x, world_z)

func _try_finish_startup_loading() -> void:
    if not _startup_load_pending or _spawn_validation_in_progress or _player == null or not is_world_coverage_ready():
        return
    var spawn_x: float = _spawn_position_xz.x
    var spawn_z: float = _spawn_position_xz.y
    var expected_height: float = get_surface_height(spawn_x, spawn_z)
    var spawn_position := Vector3(spawn_x, expected_height + 8.0, spawn_z)
    # The full player footprint must be covered by active LOD0 collision chunks.
    # Rendering visibility is irrelevant: physics coverage is the startup requirement.
    if not can_move_to_position(spawn_position, 0.8):
        return
    _place_player_on_surface()

func _chunk_has_collision_resource(coord: Vector2i) -> bool:
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    return chunk != null and chunk.collision_enabled

func can_move_to_position(world_position: Vector3, safety_margin_m: float = 0.6) -> bool:
    for offset_z in [-safety_margin_m, safety_margin_m]:
        for offset_x in [-safety_margin_m, safety_margin_m]:
            var point := Vector2(world_position.x + offset_x, world_position.z + offset_z)
            var local_x: float = point.x - _world_min_x
            var local_z: float = point.y - _world_min_z
            if local_x < 0.0 or local_z < 0.0 or local_x >= world_size_m or local_z >= world_size_m:
                return false
            var tile := Vector2i(floori(local_x / chunk_size_m), floori(local_z / chunk_size_m))
            var key := _make_lod_key(0, tile.x, tile.y)
            var chunk: VoxelTerrainChunk = _chunks.get(key) as VoxelTerrainChunk
            if chunk == null or not chunk.mesh_ready or not chunk.collision_enabled or not chunk.collision_active:
                return false
    return true


func _refresh_streaming() -> void:
    if _player == null or _generator == null:
        return
    var refresh_started_usec: int = Time.get_ticks_usec()
    var player_xz := Vector2(_player.global_position.x, _player.global_position.z)
    var player_y: float = _player.global_position.y
    var heading: Vector2 = _get_streaming_heading()
    var wanted: Dictionary = {}
    # The coarsest roots cover the world; every descendant remains a voxel-based mesh.
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            _collect_lod_tiles(7, tx, tz, player_xz, heading, wanted, player_y)

    # Detect actual LOD-tree topology changes. Player movement inside the same LOD bands
    # only updates priorities/distances and must not trigger a full hierarchy traversal.
    var previous_wanted: Dictionary = _wanted
    var changed_topology: Array[Vector2i] = []
    for previous_key_value in previous_wanted.keys():
        var previous_key: Vector2i = previous_key_value
        if not wanted.has(previous_key):
            changed_topology.append(previous_key)
        elif bool(previous_wanted[previous_key].get("fallback", false)) != bool(wanted[previous_key].get("fallback", false)):
            changed_topology.append(previous_key)
    for wanted_key_value in wanted.keys():
        var wanted_key: Vector2i = wanted_key_value
        if not previous_wanted.has(wanted_key):
            changed_topology.append(wanted_key)

    _wanted = wanted
    for changed_coord in changed_topology:
        _mark_hierarchy_dirty_for(changed_coord)
    for queued_coord in _queued.keys():
        if not wanted.has(queued_coord):
            _queued.erase(queued_coord)
    for existing_value in _chunks.keys():
        var existing_coord: Vector2i = existing_value
        if wanted.has(existing_coord):
            continue
        var old_chunk: VoxelTerrainChunk = _chunks[existing_coord] as VoxelTerrainChunk
        var existing_lod: int = int(_decode_lod_key(existing_coord)["lod"])
        # Retain the handful of LOD7 world roots, but do not keep thousands of obsolete
        # fine-detail chunks cached along a high-speed flight path.
        if existing_lod == 7:
            old_chunk.set_render_active(false)
            _update_neighbor_chunk_skirts(existing_coord)
            if old_chunk.mesh_ready:
                old_chunk._retire_current_generation()
            _queue_chunk_retirement(old_chunk)
            continue
        var tile_size_m: float = chunk_size_m * float(1 << existing_lod)
        var inner_boundary: float = get_lod_boundary_m(existing_lod - 1) if existing_lod > 0 else 0.0
        var cache_radius: float = maxf(tile_size_m, inner_boundary + tile_size_m * 1.5)
        if _distance_to_tile_xz(player_xz, existing_coord) > cache_radius:
            old_chunk.set_render_active(false)
            old_chunk._retire_current_generation()
            remove_child(old_chunk)
            _retiring_chunks.append(old_chunk)
            _chunks.erase(existing_coord)
            _completed_jobs.erase(existing_coord)
            _queued.erase(existing_coord)
            _update_neighbor_chunk_skirts(existing_coord)
        else:
            old_chunk.set_render_active(false)
            _update_neighbor_chunk_skirts(existing_coord)
    for coord_value in wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = wanted[coord]
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk != null:
            # Collision requests can change while the visible LOD tree stays the same.
            # Sync the collider immediately instead of waiting for a topology change.
            chunk.set_render_active(chunk._render_active, bool(request["collision"]))
        var fallback_children_ready: bool = _fallback_children_ready(coord)
        var rejected_same_mesh_request: bool = chunk != null and chunk.mesh_upload_rejected and chunk.rejected_mesh_lod == int(request["lod"]) and chunk.rejected_mesh_step_voxels == int(request["step_voxels"])
        # A deterministic oversize/malformed mesh must not enter an endless rebuild loop.
        # The parent LOD remains visible until this tile can produce an acceptable mesh.
        var needs_build: bool = not rejected_same_mesh_request and not fallback_children_ready and (chunk == null or not chunk.mesh_ready)
        if chunk != null and not fallback_children_ready and not rejected_same_mesh_request:
            var has_shadow_proxy: bool = chunk.shadow_vertex_count > 0
            var wants_shadow_proxy: bool = bool(request.get("shadow_proxy", false))
            var shadow_proxy_mismatch: bool = has_shadow_proxy != wants_shadow_proxy
            needs_build = needs_build or (
                chunk.lod != int(request["lod"])
                or chunk.mesh_step_voxels != int(request["step_voxels"])
                or (bool(request["collision"]) and not chunk.collision_enabled)
                or shadow_proxy_mismatch
            )
        # Do not retire a fallback parent just because its children are ready. Keep the
        # mesh cached while hidden so the parent can be restored immediately when LOD topology changes.
        if _running_job_matches(coord, request) or _completed_job_matches(coord, request):
            _queued.erase(coord)
        elif needs_build:
            var previous: Dictionary = _queued.get(coord, {})
            if not previous.is_empty() and int(previous.get("lod", -1)) == int(request["lod"]) and int(previous.get("step_voxels", -1)) == int(request["step_voxels"]) and bool(previous.get("collision", false)) == bool(request["collision"]):
                request["queued_usec"] = int(previous.get("queued_usec", Time.get_ticks_usec()))
            else:
                request["queued_usec"] = Time.get_ticks_usec()
            _queued[coord] = request
        else:
            _queued.erase(coord)
    _record_timing(_refresh_usec_samples, Time.get_ticks_usec() - refresh_started_usec, 96)

func _update_chunk_skirt_visibility(coord: Vector2i, chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not chunk.mesh_ready:
        return
    var left_key := _lod_neighbor_key(coord, Vector2i(-1, 0))
    var right_key := _lod_neighbor_key(coord, Vector2i(1, 0))
    var north_key := _lod_neighbor_key(coord, Vector2i(0, -1))
    var south_key := _lod_neighbor_key(coord, Vector2i(0, 1))
    chunk.set_skirt_visibility(Vector4(
        1.0 if _should_show_chunk_skirt(left_key, chunk, _target_lod_for_neighbor(left_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(right_key, chunk, _target_lod_for_neighbor(right_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(north_key, chunk, _target_lod_for_neighbor(north_key)) else 0.0,
        1.0 if _should_show_chunk_skirt(south_key, chunk, _target_lod_for_neighbor(south_key)) else 0.0
    ))

func _should_show_chunk_skirt(neighbor_coord: Vector2i, chunk: VoxelTerrainChunk, target_lod: int) -> bool:
    if target_lod < 0:
        return false
    if target_lod != chunk.lod:
        return true
    var neighbor_key := _find_visible_lod_key_at_point(_chunk_center(neighbor_coord))
    var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_key) as VoxelTerrainChunk
    return neighbor == null or not neighbor.mesh_ready or not neighbor._render_active or neighbor.lod != chunk.lod

func _update_neighbor_chunk_skirts(coord: Vector2i) -> void:
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    if chunk != null and chunk.mesh_ready and chunk._render_active:
        _update_chunk_skirt_visibility(coord, chunk)
    for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
        var virtual_key := _lod_neighbor_key(coord, offset)
        if virtual_key.x < 0:
            continue
        var neighbor_key := _find_visible_lod_key_at_point(_chunk_center(virtual_key))
        var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_key) as VoxelTerrainChunk
        if neighbor != null and neighbor.mesh_ready and neighbor._render_active:
            _update_chunk_skirt_visibility(neighbor_key, neighbor)

func _chunk_bounds(coord: Vector2i) -> Dictionary:
    var parts: Dictionary = _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    var tile_x: int = int(parts["tile_x"])
    var tile_z: int = int(parts["tile_z"])
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return {"start_x": 0, "start_z": 0, "size_x": 0, "size_z": 0, "origin": Vector2.ZERO, "center": Vector2.ZERO, "width": 0.0, "depth": 0.0, "lod": lod_index, "tile_x": tile_x, "tile_z": tile_z}
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    var origin_x: float = _world_min_x + float(start_x) * VOXEL_SIZE
    var origin_z: float = _world_min_z + float(start_z) * VOXEL_SIZE
    var width: float = float(size_x) * VOXEL_SIZE
    var depth: float = float(size_z) * VOXEL_SIZE
    return {"start_x": start_x, "start_z": start_z, "size_x": size_x, "size_z": size_z, "origin": Vector2(origin_x, origin_z), "center": Vector2(origin_x + width * 0.5, origin_z + depth * 0.5), "width": width, "depth": depth, "lod": lod_index, "tile_x": tile_x, "tile_z": tile_z}

func _distance_to_tile_xz(point: Vector2, coord: Vector2i) -> float:
    # Fast cache eviction distance without constructing a chunk-bounds Dictionary.
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var tile_z: int = coord.y
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    var center_x: float = _world_min_x + (float(start_x) + float(size_x) * 0.5) * VOXEL_SIZE
    var center_z: float = _world_min_z + (float(start_z) + float(size_z) * 0.5) * VOXEL_SIZE
    var half_width: float = float(size_x) * VOXEL_SIZE * 0.5
    var half_depth: float = float(size_z) * VOXEL_SIZE * 0.5
    var nearest_x: float = maxf(0.0, absf(point.x - center_x) - half_width)
    var nearest_z: float = maxf(0.0, absf(point.y - center_z) - half_depth)
    return sqrt(nearest_x * nearest_x + nearest_z * nearest_z)


func _process_chunk_jobs() -> void:
    var worker_limit: int = maxi(1, mini(max_concurrent_mesh_jobs, maxi(1, OS.get_processor_count() - 1)))
    var active_decor_jobs: int = 0
    for child in get_children():
        if child is VoxelSurfaceScatter:
            active_decor_jobs = child._running_decor_tasks.size()
            break
    # Terrain owns scheduling priority; decor may use only the remaining shared worker slots.
    var available_jobs: int = worker_limit - _running_tasks.size() - active_decor_jobs
    if available_jobs <= 0 or _queued.is_empty():
        return
    var started_jobs: int = 0
    var player_xz := _player_xz()
    var heading: Vector2 = _get_streaming_heading()
    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z) if _player != null else Vector2.ZERO
    while started_jobs < available_jobs and not _queued.is_empty():
        var best_coord := Vector2i(-1, -1)
        var best_priority: float = INF
        var best_center := Vector2.ZERO
        for queued_key in _queued.keys():
            var candidate: Vector2i = queued_key
            if _running_by_coord.has(candidate):
                continue
            var candidate_center: Vector2 = _chunk_center(candidate)
            var candidate_request: Dictionary = _queued[candidate]
            var priority: float = _deadline_priority(candidate_center, candidate_request, player_xz, heading, planar_velocity)
            if priority < best_priority:
                best_priority = priority
                best_coord = candidate
                best_center = candidate_center
        if best_coord.x < 0:
            break
        var coord: Vector2i = best_coord
        var request: Dictionary = _queued[coord]
        request["priority"] = best_priority
        if not request.has("queued_usec"):
            request["queued_usec"] = Time.get_ticks_usec()
        _queued.erase(coord)
        var neighbors: Dictionary = _neighbor_lods_for(coord)
        var job_data: Dictionary = {
            "coord": coord, "request": request.duplicate(), "neighbor_lods": neighbors.duplicate(),
            "seed": seed_value, "world_min_x": _world_min_x, "world_min_z": _world_min_z,
            "world_size_voxels": _world_size_voxels,
            "terrain_world_size_m": world_size_m, "mountain_profile": _mountain_profile_cache,
            "build_collision": bool(request["collision"]) and not _chunk_has_collision_resource(coord)
        }
        var build_collision: bool = bool(request["collision"]) and not _chunk_has_collision_resource(coord)
        var cache_key: String = _make_mesh_cache_key(coord, request, neighbors, build_collision)
        var cached_data: Dictionary = _get_cached_mesh(cache_key)
        if not cached_data.is_empty():
            _completed_jobs[coord] = {
                "coord": coord, "request": request.duplicate(), "neighbors": neighbors.duplicate(),
                "builder": null, "epoch": _generation_epoch, "seed": seed_value,
                "queued_usec": int(request["queued_usec"]), "cache_key": cache_key,
                "data": cached_data, "completed_usec": Time.get_ticks_usec()
            }
            started_jobs += 1
            continue

        var builder: Object = _create_mesh_builder()
        if builder == null:
            return
        var task_id: int = WorkerThreadPool.add_task(
            Callable(builder, "build_mesh_data").bind(job_data), false,
            "VoxEn chunk %d,%d LOD%d" % [coord.x, coord.y, int(request["lod"])]
        )
        var task_record := {
            "coord": coord, "request": request.duplicate(), "neighbors": neighbors.duplicate(),
            "builder": builder, "epoch": _generation_epoch,
            "seed": seed_value, "queued_usec": int(request["queued_usec"]),
            "cache_key": cache_key
        }
        _running_tasks[task_id] = task_record
        _running_by_coord[coord] = task_id
        started_jobs += 1

func _make_mesh_cache_key(coord: Vector2i, request: Dictionary, neighbors: Dictionary, build_collision: bool) -> String:
    return "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
        seed_value, coord.x, coord.y, int(request["lod"]),
        int(request.get("step_voxels", 1)), int(bool(request["collision"])),
        int(build_collision), int(bool(request.get("shadow_proxy", false))),
        int(neighbors.get("left", -1)), int(neighbors.get("right", -1)),
        int(neighbors.get("north", -1)), int(neighbors.get("south", -1))
    ]


func _estimate_mesh_data_bytes(data: Dictionary) -> int:
    var bytes: int = 0
    var vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = data.get("normals", PackedVector3Array())
    var colors: PackedColorArray = data.get("colors", PackedColorArray())
    var indices: PackedInt32Array = data.get("indices", PackedInt32Array())
    var shadow_vertices: PackedVector3Array = data.get("smooth_shadow_vertices", PackedVector3Array())
    var shadow_normals: PackedVector3Array = data.get("smooth_shadow_normals", PackedVector3Array())
    var shadow_indices: PackedInt32Array = data.get("smooth_shadow_indices", PackedInt32Array())
    bytes += vertices.size() * 12 + normals.size() * 12 + colors.size() * 16 + indices.size() * 4
    bytes += shadow_vertices.size() * 12 + shadow_normals.size() * 12 + shadow_indices.size() * 4
    var collision_data: Dictionary = data.get("collision_height_map", {})
    var collision_heights: PackedFloat32Array = collision_data.get("heights", PackedFloat32Array())
    bytes += collision_heights.size() * 4
    return bytes


func _get_cached_mesh(cache_key: String) -> Dictionary:
    if cache_key.is_empty() or not _mesh_cache.has(cache_key):
        return {}
    var record: Dictionary = _mesh_cache[cache_key]
    _mesh_cache_order.erase(cache_key)
    _mesh_cache_order.append(cache_key)
    return record.get("data", {})


func _store_cached_mesh(cache_key: String, data: Dictionary) -> void:
    if cache_key.is_empty() or data.is_empty():
        return
    var bytes: int = _estimate_mesh_data_bytes(data)
    if bytes <= 0 or bytes > MAX_MESH_CACHE_BYTES:
        return
    if _mesh_cache.has(cache_key):
        var old_record: Dictionary = _mesh_cache[cache_key]
        _mesh_cache_bytes -= int(old_record.get("bytes", 0))
        _mesh_cache_order.erase(cache_key)
    _mesh_cache[cache_key] = {"data": data, "bytes": bytes}
    _mesh_cache_order.append(cache_key)
    _mesh_cache_bytes += bytes
    while _mesh_cache_bytes > MAX_MESH_CACHE_BYTES or _mesh_cache.size() > MAX_MESH_CACHE_ENTRIES:
        if _mesh_cache_order.is_empty():
            break
        var oldest_key: String = _mesh_cache_order.pop_front()
        var oldest_record: Dictionary = _mesh_cache.get(oldest_key, {})
        _mesh_cache_bytes -= int(oldest_record.get("bytes", 0))
        _mesh_cache.erase(oldest_key)
    _mesh_cache_bytes = maxi(0, _mesh_cache_bytes)


func _create_mesh_builder() -> Object:
    if not ClassDB.class_exists("VoxEnNativeBuilder"):
        push_error("Cannot build a voxel chunk: VoxEnNativeBuilder is unavailable.")
        return null
    var native_builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
    if native_builder == null:
        push_error("Cannot instantiate VoxEnNativeBuilder. Check the native library build.")
        return null
    if _generator != null:
        native_builder.call("share_terrain_sampler", _generator.get_native_sampler())
    return native_builder

func _poll_worker_tasks() -> void:
    for task_key in _running_tasks.keys():
        var task_id: int = int(task_key)
        var active_record: Dictionary = _running_tasks[task_id]
        var active_coord: Vector2i = active_record["coord"]
        if not bool(active_record.get("cancel_requested", false)) and not _job_record_matches_current(active_record, active_coord):
            var active_builder = active_record.get("builder")
            if active_builder != null and active_builder.has_method("cancel"):
                active_builder.call("cancel")
            active_record["cancel_requested"] = true
            _running_tasks[task_id] = active_record
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var record: Dictionary = _running_tasks[task_id]
        _running_tasks.erase(task_id)
        var coord: Vector2i = record["coord"]
        if int(_running_by_coord.get(coord, -1)) == task_id:
            _running_by_coord.erase(coord)
        var builder = record["builder"]
        var data: Dictionary = builder.result
        if data.is_empty():
            if _wanted.has(coord) and not _fallback_children_ready(coord):
                var retry_empty: Dictionary = _wanted[coord].duplicate(true)
                retry_empty["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry_empty
            continue
        # Treat the request as authoritative even if an older compiled native extension
        # does not return this metadata field yet. Both mesh builders receive the same stride.
        data["step_voxels"] = int(record["request"].get("step_voxels", get_mesh_step_voxels(int(record["request"]["lod"]))))
        var lod_index: int = clampi(int(data.get("lod", record["request"]["lod"])), 0, 7)
        _record_timing(_build_usec_by_lod[lod_index], int(data.get("build_usec", 0)), 128)
        var queue_wait_usec: int = maxi(0, int(data.get("worker_started_usec", Time.get_ticks_usec())) - int(record.get("queued_usec", Time.get_ticks_usec())))
        _max_queue_wait_usec = maxi(_max_queue_wait_usec, queue_wait_usec)
        _record_timing(_queue_wait_usec_samples, queue_wait_usec, 128)
        if _job_record_matches_current(record, coord) and not _fallback_children_ready(coord):
            record["data"] = data
            record["completed_usec"] = Time.get_ticks_usec()
            _completed_jobs[coord] = record
            _store_cached_mesh(str(record.get("cache_key", "")), data)
        else:
            _stale_result_count += 1
            if _wanted.has(coord) and not _running_by_coord.has(coord) and not _fallback_children_ready(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry

func _apply_completed_jobs() -> void:
    if _completed_jobs.is_empty():
        return

    var coords: Array = _completed_jobs.keys()
    var world_coverage_ready: bool = is_world_coverage_ready()
    coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        # Decode the packed LOD key arithmetically; this comparator runs O(n log n) times.
        var lod_a: int = clampi(floori(float(a.x) / float(LOD_KEY_STRIDE)), 0, 7)
        var lod_b: int = clampi(floori(float(b.x) / float(LOD_KEY_STRIDE)), 0, 7)
        if not world_coverage_ready and lod_a != lod_b:
            return lod_a > lod_b
        var distance_a: float = float(_wanted.get(a, {"distance": INF})["distance"])
        var distance_b: float = float(_wanted.get(b, {"distance": INF})["distance"])
        return distance_a < distance_b
    )

    var applied: int = 0
    var apply_started_usec: int = Time.get_ticks_usec()
    for coord in coords:
        if applied >= _adaptive_apply_limit:
            break
        # Always allow one upload; later uploads obey a soft main-thread budget.
        if applied > 0 and Time.get_ticks_usec() - apply_started_usec >= int(max_mesh_apply_time_ms * 1000.0):
            break
        if not _completed_jobs.has(coord):
            continue
        var record: Dictionary = _completed_jobs[coord]
        if _fallback_children_ready(coord):
            _completed_jobs.erase(coord)
            continue
        if not _job_record_matches_current(record, coord):
            _completed_jobs.erase(coord)
            _stale_result_count += 1
            if _wanted.has(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry
            continue

        _completed_jobs.erase(coord)
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk == null:
            if not _chunk_pool.is_empty():
                chunk = _chunk_pool.pop_back()
                chunk.set_render_active(true)
            else:
                chunk = ChunkScript.new()
            chunk.name = "VoxelChunk_%d_%d" % [coord.x, coord.y]
            add_child(chunk)
            _chunks[coord] = chunk
        _record_timing(
            _apply_wait_usec_samples,
            Time.get_ticks_usec() - int(record.get("completed_usec", Time.get_ticks_usec())),
            128
        )
        chunk.apply_mesh_data(record["data"], _voxel_material)
        _update_chunk_skirt_visibility(coord, chunk)
        _update_neighbor_chunk_skirts(coord)
        _mark_hierarchy_dirty_for(coord)
        applied += 1




func _job_record_matches_current(record: Dictionary, coord: Vector2i) -> bool:
    # The skirts make neighbour target LOD irrelevant to this mesh's validity.
    if int(record["epoch"]) != _generation_epoch or int(record["seed"]) != seed_value:
        return false
    if not _wanted.has(coord):
        return false
    var current: Dictionary = _wanted[coord]
    var previous: Dictionary = record["request"]
    return int(current["lod"]) == int(previous["lod"]) and int(current.get("step_voxels", -1)) == int(previous.get("step_voxels", -1)) and bool(current["collision"]) == bool(previous["collision"]) and bool(current.get("shadow_proxy", false)) == bool(previous.get("shadow_proxy", false))

func _running_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _running_by_coord.has(coord):
        return false
    var record: Dictionary = _running_tasks.get(int(_running_by_coord[coord]), {})
    return not record.is_empty() and int(record["epoch"]) == _generation_epoch and int(record["seed"]) == seed_value and int(record["request"]["lod"]) == int(request["lod"]) and int(record["request"].get("step_voxels", -1)) == int(request.get("step_voxels", -1)) and bool(record["request"]["collision"]) == bool(request["collision"]) and bool(record["request"].get("shadow_proxy", false)) == bool(request.get("shadow_proxy", false))

func _completed_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _completed_jobs.has(coord):
        return false
    var record: Dictionary = _completed_jobs[coord]
    return int(record["epoch"]) == _generation_epoch and int(record["seed"]) == seed_value and int(record["request"]["lod"]) == int(request["lod"]) and int(record["request"].get("step_voxels", -1)) == int(request.get("step_voxels", -1)) and bool(record["request"]["collision"]) == bool(request["collision"]) and bool(record["request"].get("shadow_proxy", false)) == bool(request.get("shadow_proxy", false))

func _neighbor_lods_for(coord: Vector2i) -> Dictionary:
    return {
        "left": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(-1, 0))),
        "right": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(1, 0))),
        "north": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(0, -1))),
        "south": _target_lod_for_neighbor(_lod_neighbor_key(coord, Vector2i(0, 1)))
    }

func _target_lod_for_neighbor(neighbor_coord: Vector2i) -> int:
    if neighbor_coord.x < 0 or neighbor_coord.y < 0:
        return -1
    var visible_key := _find_visible_lod_key_at_point(_chunk_center(neighbor_coord))
    var visible_chunk: VoxelTerrainChunk = _chunks.get(visible_key) as VoxelTerrainChunk
    if visible_chunk != null and visible_chunk.mesh_ready and visible_chunk._render_active:
        return visible_chunk.lod
    var neighbor_center: Vector2 = _chunk_center(neighbor_coord)
    var target_key := _find_target_lod_key_at_point(neighbor_center)
    var target: Dictionary = _wanted.get(target_key, {})
    return int(target.get("lod", -1))

func _chunk_center(coord: Vector2i) -> Vector2:
    # Hot path for queue prioritisation: calculate the centre without allocating a Dictionary.
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var tile_z: int = coord.y
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    return Vector2(
        _world_min_x + (float(start_x) + float(size_x) * 0.5) * VOXEL_SIZE,
        _world_min_z + (float(start_z) + float(size_z) * 0.5) * VOXEL_SIZE
    )

func _player_xz() -> Vector2:
    return Vector2(_player.global_position.x, _player.global_position.z) if _player != null else Vector2.ZERO

func _lod_neighbor_key(coord: Vector2i, offset: Vector2i) -> Vector2i:
    var parts := _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    var tx: int = int(parts["tile_x"]) + offset.x
    var tz: int = int(parts["tile_z"]) + offset.y
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * (1 << lod_index)))
    if tx < 0 or tz < 0 or tx >= tiles_axis or tz >= tiles_axis:
        return Vector2i(-1, -1)
    return _make_lod_key(lod_index, tx, tz)

func _make_lod_key(lod_index: int, tile_x: int, tile_z: int) -> Vector2i:
    return Vector2i(lod_index * LOD_KEY_STRIDE + tile_x, tile_z)

func _decode_lod_key(coord: Vector2i) -> Dictionary:
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    return {"lod": lod_index, "tile_x": coord.x - lod_index * LOD_KEY_STRIDE, "tile_z": coord.y}

func _find_target_lod_key_at_point(point: Vector2) -> Vector2i:
    if point.x < _world_min_x or point.y < _world_min_z or point.x >= _world_min_x + world_size_m or point.y >= _world_min_z + world_size_m:
        return Vector2i(-1, -1)
    for lod_index in range(8):
        var tile_m: float = chunk_size_m * float(1 << lod_index)
        var tx: int = floori((point.x - _world_min_x) / tile_m)
        var tz: int = floori((point.y - _world_min_z) / tile_m)
        var candidate := _make_lod_key(lod_index, tx, tz)
        if _wanted.has(candidate) and not bool(_wanted[candidate].get("fallback", false)):
            return candidate
    return Vector2i(-1, -1)

func _find_visible_lod_key_at_point(point: Vector2) -> Vector2i:
    if point.x < _world_min_x or point.y < _world_min_z or point.x >= _world_min_x + world_size_m or point.y >= _world_min_z + world_size_m:
        return Vector2i(-1, -1)
    for lod_index in range(8):
        var tile_m: float = chunk_size_m * float(1 << lod_index)
        var tx: int = floori((point.x - _world_min_x) / tile_m)
        var tz: int = floori((point.y - _world_min_z) / tile_m)
        var candidate := _make_lod_key(lod_index, tx, tz)
        var chunk: VoxelTerrainChunk = _chunks.get(candidate) as VoxelTerrainChunk
        if chunk != null and chunk.mesh_ready and chunk._render_active:
            return candidate
    return _find_target_lod_key_at_point(point)

func _get_lod_tile_children(coord: Vector2i) -> Array[Vector2i]:
    var children: Array[Vector2i] = []
    if not _wanted.has(coord) or not bool(_wanted[coord].get("fallback", false)):
        return children
    var parts := _decode_lod_key(coord)
    var lod_index: int = int(parts["lod"])
    if lod_index <= 0:
        return children
    var tx: int = int(parts["tile_x"])
    var tz: int = int(parts["tile_z"])
    for dz in range(2):
        for dx in range(2):
            var child_key := _make_lod_key(lod_index - 1, tx * 2 + dx, tz * 2 + dz)
            # Wanted children were already bounds-checked by _collect_lod_tiles.
            if _wanted.has(child_key):
                children.append(child_key)
    return children

func _all_lod_children_ready(children: Array[Vector2i]) -> bool:
    for child_key in children:
        var child_request: Dictionary = _wanted.get(child_key, {})
        if float(child_request.get("nearest_distance", INF)) > render_distance_m:
            continue
        if not _lod_tile_coverage_ready(child_key):
            return false
    return true


func _lod_tile_coverage_ready(coord: Vector2i) -> bool:
    if not _wanted.has(coord):
        return false
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    if chunk != null and chunk.mesh_ready:
        return true
    var request: Dictionary = _wanted[coord]
    if not bool(request.get("fallback", false)):
        return false
    var children: Array[Vector2i] = _get_lod_tile_children(coord)
    return not children.is_empty() and _all_lod_children_ready(children)


func _fallback_children_ready(coord: Vector2i) -> bool:
    if not _wanted.has(coord) or not bool(_wanted[coord].get("fallback", false)):
        return false
    var children: Array[Vector2i] = _get_lod_tile_children(coord)
    return not children.is_empty() and _all_lod_children_ready(children)

func _reconcile_hierarchy_visibility() -> void:
    var root_tiles: int = ceili(float(_world_size_voxels) / float(_chunk_size_voxels * 128))
    for tz in range(root_tiles):
        for tx in range(root_tiles):
            _update_lod_subtree_visibility(_make_lod_key(7, tx, tz), true)

func _mark_hierarchy_dirty_for(coord: Vector2i) -> void:
    var lod_index: int = clampi(floori(float(coord.x) / float(LOD_KEY_STRIDE)), 0, 7)
    var tile_x: int = coord.x - lod_index * LOD_KEY_STRIDE
    var shift: int = 7 - lod_index
    var root_key := _make_lod_key(7, tile_x >> shift, coord.y >> shift)
    _dirty_hierarchy_roots[root_key] = true


func _update_lod_subtree_visibility(coord: Vector2i, ancestors_visible: bool) -> void:
    if not _wanted.has(coord):
        return
    var request: Dictionary = _wanted[coord]
    var parent: bool = bool(request.get("fallback", false))
    # Avoid assigning an untyped [] from a ternary to Array[Vector2i] on Godot 4.7.
    # Leaf tiles have no children; parent tiles fill the typed array explicitly.
    var children: Array[Vector2i] = []
    if parent:
        children = _get_lod_tile_children(coord)
    var children_ready: bool = parent and not children.is_empty() and _all_lod_children_ready(children)
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    var node_active: bool = ancestors_visible and (not parent or not children_ready) and chunk != null and chunk.mesh_ready
    if chunk != null:
        var was_active: bool = chunk._render_active
        chunk.set_render_active(node_active, bool(request.get("collision", false)))
        if was_active != node_active:
            _update_neighbor_chunk_skirts(coord)
        # Hidden fallback-parent meshes stay cached until normal distance-based eviction.
        # This avoids rebuilding an entire parent tile when its subtree changes near a boundary.
    var children_visible: bool = ancestors_visible and parent and children_ready
    for child_key in children:
        _update_lod_subtree_visibility(child_key, children_visible)

func _collect_lod_tiles(lod_index: int, tile_x: int, tile_z: int, player_xz: Vector2, heading: Vector2, wanted: Dictionary, player_y: float = 0.0) -> void:
    # Hot streaming path: calculate tile bounds arithmetically instead of allocating the
    # eleven-key Dictionary returned by _chunk_bounds() for every visited node.
    var key := _make_lod_key(lod_index, tile_x, tile_z)
    var tile_voxels: int = _chunk_size_voxels * (1 << lod_index)
    var tiles_axis: int = ceili(float(_world_size_voxels) / float(tile_voxels))
    if tile_x < 0 or tile_z < 0 or tile_x >= tiles_axis or tile_z >= tiles_axis:
        return
    var start_x: int = tile_x * tile_voxels
    var start_z: int = tile_z * tile_voxels
    var size_x: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_x))
    var size_z: int = maxi(0, mini(tile_voxels, _world_size_voxels - start_z))
    if size_x <= 0 or size_z <= 0:
        return
    var origin_x: float = _world_min_x + float(start_x) * VOXEL_SIZE
    var origin_z: float = _world_min_z + float(start_z) * VOXEL_SIZE
    var width: float = float(size_x) * VOXEL_SIZE
    var depth: float = float(size_z) * VOXEL_SIZE
    var center := Vector2(origin_x + width * 0.5, origin_z + depth * 0.5)
    var nearest_x: float = clampf(player_xz.x, origin_x, origin_x + width)
    var nearest_z: float = clampf(player_xz.y, origin_z, origin_z + depth)
    var dx: float = player_xz.x - nearest_x
    var dz: float = player_xz.y - nearest_z
    # Euclidean distance from the player to the local terrain surface (X, Y, Z), not an XZ-only radius.
    var terrain_y: float = _generator.get_surface_height(nearest_x, nearest_z)
    var vertical_delta: float = player_y - terrain_y
    var nearest: float = sqrt(dx * dx + dz * dz + vertical_delta * vertical_delta)
    if nearest > render_distance_m:
        return
    var boundary: float = _lod_boundary_for(lod_index - 1) if lod_index > 0 else -1.0
    if lod_index == 7:
        boundary = get_lod_boundary_m(6)
    var previous: Dictionary = _wanted.get(key, {})
    var was_split: bool = bool(previous.get("fallback", false))
    var split: bool = false
    if lod_index > 0:
        var scaled_hysteresis: float = boundary * lod_hysteresis_ratio
        var threshold: float = boundary + scaled_hysteresis if was_split else maxf(0.0, boundary - scaled_hysteresis)
        split = nearest < threshold
    var horizontal_center_distance: float = center.distance_to(player_xz)
    var req := {
        "lod": lod_index, "fallback": split, "distance": nearest,
        "nearest_distance": nearest, "priority": horizontal_center_distance - maxf(0.0, (center - player_xz).dot(heading) * 0.30),
        "collision": lod_index == 0 and nearest <= collision_distance_m,
        "start_x": start_x, "start_z": start_z,
        "size_x": size_x, "size_z": size_z,
        "tile_x": tile_x, "tile_z": tile_z, "tile_size_m": chunk_size_m * float(1 << lod_index),
        "step_voxels": get_mesh_step_voxels(lod_index),
        "shadow_proxy": nearest <= TERRAIN_SHADOW_DISTANCE_M
    }
    wanted[key] = req
    if split:
        for dz_offset in range(2):
            for dx_offset in range(2):
                _collect_lod_tiles(lod_index - 1, tile_x * 2 + dx_offset, tile_z * 2 + dz_offset, player_xz, heading, wanted, player_y)

func _get_streaming_heading() -> Vector2:
    if _player == null:
        return Vector2(0.0, -1.0)

    var forward_3d: Vector3 = -_player.global_transform.basis.z
    var view_heading := Vector2(forward_3d.x, forward_3d.z)
    if view_heading.length_squared() > 0.0001:
        view_heading = view_heading.normalized()
    else:
        view_heading = Vector2(0.0, -1.0)

    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z)
    if planar_velocity.length_squared() > 1.0:
        # Bias towards the current view so a rapid turn reprioritises visible chunks,
        # while retaining some look-ahead in the direction of travel.
        return (view_heading * 0.65 + planar_velocity.normalized() * 0.35).normalized()
    return view_heading

func _deadline_priority(center: Vector2, request: Dictionary, player_xz: Vector2, heading: Vector2, velocity: Vector2) -> float:
    var offset: Vector2 = center - player_xz
    var speed: float = velocity.length()
    var lod_index: int = clampi(int(request["lod"]), 0, 7)
    if lod_index == 7:
        return -100000.0 + center.distance_to(player_xz)
    if bool(request.get("fallback", false)):
        return -50000.0 - float(lod_index) * 1000.0 + center.distance_to(player_xz)
    var estimate_seconds: float = _estimated_lod_pipeline_usec(lod_index) / 1000000.0
    var priority: float
    if speed >= 2.0:
        var direction: Vector2 = velocity / speed
        var along_track: float = offset.dot(direction)
        var lateral: float = absf(offset.cross(direction))
        if along_track < -float(request.get("tile_size_m", chunk_size_m)) * 0.5:
            priority = 2.0 + center.distance_to(player_xz) / speed + lateral * 0.02
        else:
            var eta: float = maxf(0.0, along_track - float(request.get("tile_size_m", chunk_size_m)) * 0.5) / speed
            priority = eta - estimate_seconds + lateral / maxf(speed, 1.0) * 0.35
    else:
        priority = center.distance_to(player_xz) - maxf(0.0, offset.dot(heading)) * 0.30
    if lod_index == 0:
        priority -= 0.15
    elif lod_index == 1:
        priority -= 0.07
    if bool(request["collision"]):
        var nearest: float = float(request.get("nearest_distance", center.distance_to(player_xz)))
        # A collider must arrive before the player reaches the tile, even when visual LOD work is queued.
        priority -= 10000.0 + clampf((collision_distance_m - nearest) / maxf(collision_distance_m, 1.0), 0.0, 1.0) * 0.35
    return priority


func _refresh_build_estimate_cache() -> void:
    for lod_index in range(_build_usec_by_lod.size()):
        var samples: Array = _build_usec_by_lod[lod_index]
        if not samples.is_empty():
            _build_p95_cached_usec[lod_index] = _p95_usec(samples)
    if not _refresh_usec_samples.is_empty():
        _refresh_p95_cached_usec = _p95_usec(_refresh_usec_samples)
    if not _queue_wait_usec_samples.is_empty():
        _queue_wait_p95_cached_usec = _p95_usec(_queue_wait_usec_samples)
    if not _apply_wait_usec_samples.is_empty():
        _apply_wait_p95_cached_usec = _p95_usec(_apply_wait_usec_samples)

func _effective_prediction_seconds() -> float:
    var measured_work_usec: float = _estimated_lod_pipeline_usec(0)
    # Include the refresh interval itself as well as measured refresh cost, because a
    # chunk can be queued just after the last streaming refresh.
    # The 4 s ceiling prevents one pathological queue sample from exploding the fine-LOD area.
    return maxf(streaming_prediction_seconds, minf(measured_work_usec / 1000000.0 + 0.25, 4.0))

func _estimated_lod_pipeline_usec(lod_index: int) -> float:
    return (
        _estimated_build_usec(lod_index)
        + _refresh_p95_cached_usec
        + _queue_wait_p95_cached_usec
        + _apply_wait_p95_cached_usec
        + streaming_refresh_interval_s * 1000000.0
    )

func _estimated_build_usec(lod_index: int) -> float:
    return _build_p95_cached_usec[clampi(lod_index, 0, 7)]

func _record_timing(samples: Array, value_usec: int, limit: int) -> void:
    samples.append(maxi(0, value_usec))
    while samples.size() > limit:
        samples.pop_front()

func _avg_ms(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var sum_usec: float = 0.0
    for value in samples:
        sum_usec += float(value)
    return sum_usec / float(samples.size()) / 1000.0

func _p95_ms(samples: Array) -> float:
    return _p95_usec(samples) / 1000.0

func _p95_usec(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var ordered: Array = samples.duplicate()
    ordered.sort()
    var index: int = clampi(int(ceil(float(ordered.size() - 1) * 0.95)), 0, ordered.size() - 1)
    return float(ordered[index])

func _queue_chunk_retirement(chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not is_instance_valid(chunk):
        return
    var instance_id: int = chunk.get_instance_id()
    if _retirement_lookup.has(instance_id):
        return
    _retirement_lookup[instance_id] = true
    _retirement_queue.append(chunk)


func _recycle_retired_chunk(chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not is_instance_valid(chunk):
        return
    chunk.set_render_active(false)
    if _chunk_pool.size() < MAX_POOLED_CHUNK_NODES:
        chunk.name = "PooledVoxelChunk"
        _chunk_pool.append(chunk)
    else:
        chunk.free()


func _retire_stale_resources() -> void:
    # Visit only chunks that actually have detached resources awaiting disposal.
    var started_usec: int = Time.get_ticks_usec()
    var retired_count: int = 0
    while not _retirement_queue.is_empty():
        var resident_chunk: VoxelTerrainChunk = _retirement_queue[0]
        while retired_count < 8 and resident_chunk.retire_one_old_node():
            retired_count += 1
            if retired_count >= 2 and Time.get_ticks_usec() - started_usec >= 2500:
                return
        if resident_chunk._retired_nodes.is_empty():
            _retirement_queue.pop_front()
            _retirement_lookup.erase(resident_chunk.get_instance_id())
        if retired_count >= 8 or Time.get_ticks_usec() - started_usec >= 2500:
            return

    for i in range(_retiring_chunks.size() - 1, -1, -1):
        var stale_chunk: VoxelTerrainChunk = _retiring_chunks[i]
        while retired_count < 8 and stale_chunk.retire_one_old_node():
            retired_count += 1
            if retired_count >= 2 and Time.get_ticks_usec() - started_usec >= 2500:
                return
        if stale_chunk._retired_nodes.is_empty():
            _retiring_chunks.remove_at(i)
            _recycle_retired_chunk(stale_chunk)
        if retired_count >= 8 or Time.get_ticks_usec() - started_usec >= 2500:
            return

func _place_player_on_surface() -> void:
    if _player == null or _spawn_validation_in_progress:
        return
    _spawn_validation_in_progress = true
    var spawn_epoch: int = _generation_epoch
    var spawn_x: float = _spawn_position_xz.x
    var spawn_z: float = _spawn_position_xz.y
    var expected_height: float = get_surface_height(spawn_x, spawn_z)
    _player.set_physics_process(false)
    _player.velocity = Vector3.ZERO
    _player.global_position = Vector3(spawn_x, expected_height + 12.0, spawn_z)

    # Wait for PhysicsServer to register all HeightMapShape3D resources before probing.
    await get_tree().physics_frame
    await get_tree().physics_frame
    if not is_instance_valid(_player) or spawn_epoch != _generation_epoch:
        _spawn_validation_in_progress = false
        return

    var ray_query := PhysicsRayQueryParameters3D.create(
        Vector3(spawn_x, expected_height + 12.0, spawn_z),
        Vector3(spawn_x, expected_height - 12.0, spawn_z),
        1
    )
    ray_query.exclude = [_player.get_rid()]
    var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray_query)
    if hit.is_empty() or absf(float(hit["position"].y) - expected_height) > 1.0:
        push_warning("Startup blocked: the selected spawn point has no matching terrain collider. Player physics remains disabled.")
        _spawn_validation_in_progress = false
        return

    _player.global_position = hit["position"] + Vector3(0.0, 2.5, 0.0)
    _player.velocity = Vector3.ZERO
    await get_tree().physics_frame
    if is_instance_valid(_player) and spawn_epoch == _generation_epoch:
        _startup_load_pending = false
        _player.set_physics_process(true)
    _spawn_validation_in_progress = false

func _exit_tree() -> void:
    # Detached retired meshes and pooled chunk shells are outside the SceneTree; release them explicitly.
    for chunk_value in _chunks.values():
        var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        while chunk.retire_one_old_node():
            pass
    for stale_chunk in _retiring_chunks:
        while stale_chunk.retire_one_old_node():
            pass
        if is_instance_valid(stale_chunk):
            stale_chunk.free()
    _retiring_chunks.clear()
    for pooled_chunk in _chunk_pool:
        if is_instance_valid(pooled_chunk):
            pooled_chunk.free()
    _chunk_pool.clear()
    _retirement_queue.clear()
    _retirement_lookup.clear()
    _mesh_cache.clear()
    _mesh_cache_order.clear()
    _mesh_cache_bytes = 0

func _lod_for_distance(distance: float) -> int:
    for lod_index in range(7):
        if distance < get_lod_boundary_m(lod_index):
            return lod_index
    return 7

func _lod_boundary_for(lod_index: int) -> float:
    return get_lod_boundary_m(lod_index)
