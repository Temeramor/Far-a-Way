extends Node3D

## Streamed ground stones and vegetation. This node owns tile lifetime, LOD selection and shared materials.
const GridScript = preload("res://scripts/vegetation/vox_grid.gd")
const PaletteScript = preload("res://scripts/vegetation/voxel_palette.gd")
const MeshDataScript = preload("res://scripts/vegetation/mesh_data.gd")
const WindShader: Shader = preload("res://shaders/vegetation_wind.gdshader")
const DecorJobScript = preload("res://scripts/meshing/voxel_surface_decor_job.gd")

const MAX_DECOR_DISTANCE_M: float = 1900.0
const DENSE_ROCK_DISTANCE_M: float = 240.0
const PLANT_FULL_DISTANCE_M: float = 92.0
const PLANT_REMOVE_HYSTERESIS_M: float = 12.0
const PLANT_RENDER_DISTANCE_M: float = 320.0
const ROCK_SHADOW_DISTANCE_M: float = 80.0
const DECOR_COLLISION_HYSTERESIS_M: float = 12.0
const MAX_CONCURRENT_DECOR_JOBS: int = 1
const MIN_STONE_EDGE_MARGIN_M: float = 0.25
const ROCK_MOSS_COLOR := Color("5e7b3a")
const STONE_COLOR_A := Color("8b8984")
const STONE_COLOR_B := Color("77706a")
const STEM_COLOR := Color("4c8a30")

var _world: VoxelWorld
var _material: StandardMaterial3D
var _plant_material: ShaderMaterial
var _entries: Dictionary = {}
var _pending_actions: Array[Dictionary] = []
var _running_decor_tasks: Dictionary = {}
var _refresh_accumulator: float = 0.0
var _generation_epoch: int = 0
var _weather_mode: int = 1
