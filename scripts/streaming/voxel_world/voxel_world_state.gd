extends Node3D

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
@export_range(256.0, 20000.0, 1.0) var world_size_m: float = 8000.0
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
var _spawn_validation_retry_cooldown: float = 0.0
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
var _terrain_prepare_jobs: Dictionary = {}
var _active_terrain_prepare_task_id: int = -1
