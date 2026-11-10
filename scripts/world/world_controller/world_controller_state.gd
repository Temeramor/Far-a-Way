extends Node3D

const PauseMenuScript = preload("res://scripts/ui/pause_menu.gd")

@onready var terrain: TerrainGenerator = $Terrain
@onready var voxel_world: VoxelWorld = $VoxelWorld
@onready var player: PlayerController = $Player
@onready var loading_screen: LoadingScreen = $CanvasLayer/LoadingScreen
@onready var sky_system: WorldEnvironment = $Sky
@onready var sky_dome: Node = $Sky/SkyDome
@onready var time_of_day: Node = $Sky/TimeOfDay

const WEATHER_CLEAR: int = 0
const WEATHER_CLOUDY: int = 1
const WEATHER_OVERCAST: int = 2
const SKY_NOISE_CLOUDY: Texture2D = preload("res://assets/sky/noiseClouds.png")
const SKY_NOISE_CLEAR: Texture2D = preload("res://assets/sky/cloud_noise_sparse.png")

const TIME_DAWN: int = 0
const TIME_DAY: int = 1
const TIME_DUSK: int = 2
const TIME_NIGHT: int = 3
const TIME_PRESETS: Array[float] = [6.0, 12.0, 18.0, 0.0]
const TIME_LABELS: Array[String] = ["Рассвет", "День", "Закат", "Ночь"]

var flight_status_label: Label
var flight_status_backdrop: Panel
var weather_panel: PanelContainer
var weather_menu_button: Button
var weather_selector: OptionButton
var time_selector: OptionButton
var _weather_menu_open: bool = false
var _mouse_mode_before_weather_menu: int = Input.MOUSE_MODE_VISIBLE
var _weather_mode: int = WEATHER_CLOUDY
var _time_mode: int = TIME_DAY
var _last_styled_time_mode: int = -1
var _world_ready: bool = false
var _generation_started: bool = false
var _sky_tween: Tween
var _voxen_debug_panel: PanelContainer
var _voxen_debug_label: Label
var _voxen_debug_visible: bool = false
var _voxen_debug_timer: float = 0.0
var _pause_menu: PauseMenu
