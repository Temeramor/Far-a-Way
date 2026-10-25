extends Node

## Centralized saved settings shared between the menu and gameplay scenes.
const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_FLIGHT_SPEED_MULTIPLIER: float = 10.0
const DEFAULT_FLIGHT_FOV: float = 100.0
const MIN_FLIGHT_SPEED_MULTIPLIER: float = 1.0
const MAX_FLIGHT_SPEED_MULTIPLIER: float = 20.0
const MIN_FLIGHT_FOV: float = 82.0
const MAX_FLIGHT_FOV: float = 120.0
const DEFAULT_LOD_DETAIL_BIAS: int = 1
const DEFAULT_LOD0_DISTANCE_M: float = 64.0
const DEFAULT_MSAA_MODE: int = 1
const DEFAULT_SCREEN_SPACE_AA_MODE: int = 0
const DEFAULT_VOXEL_DETAIL_FILTER_MODE: int = 2
const DEFAULT_ROCK_CRACK_FILTER_MODE: int = 2
const DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED: bool = true

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
var lod_detail_bias: int = DEFAULT_LOD_DETAIL_BIAS
var lod0_distance_m: float = DEFAULT_LOD0_DISTANCE_M
var msaa_mode: int = DEFAULT_MSAA_MODE
var screen_space_aa_mode: int = DEFAULT_SCREEN_SPACE_AA_MODE
var voxel_detail_filter_mode: int = DEFAULT_VOXEL_DETAIL_FILTER_MODE
var rock_crack_filter_mode: int = DEFAULT_ROCK_CRACK_FILTER_MODE
var procedural_mip_filter_enabled: bool = DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED
var requested_seed: int = 1337
var has_requested_seed: bool = false


func request_new_game(seed_value: int) -> void:
    requested_seed = seed_value
    has_requested_seed = true


func _ready() -> void:
    load_settings()


func load_settings() -> void:
    var config := ConfigFile.new()
    var error = config.load(SETTINGS_PATH)
    if error != OK:
        _set_defaults()
        _apply_viewport_graphics_settings()
        return

    flight_speed_multiplier = clampf(
        float(config.get_value("flight", "speed_multiplier", DEFAULT_FLIGHT_SPEED_MULTIPLIER)),
        MIN_FLIGHT_SPEED_MULTIPLIER,
        MAX_FLIGHT_SPEED_MULTIPLIER
    )
    flight_fov = clampf(
        float(config.get_value("flight", "fov", DEFAULT_FLIGHT_FOV)),
        MIN_FLIGHT_FOV,
        MAX_FLIGHT_FOV
    )
    lod_detail_bias = DEFAULT_LOD_DETAIL_BIAS
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M

    msaa_mode = clampi(int(config.get_value("graphics", "msaa_mode", DEFAULT_MSAA_MODE)), 0, 3)
    screen_space_aa_mode = clampi(
        int(config.get_value("graphics", "screen_space_aa_mode", DEFAULT_SCREEN_SPACE_AA_MODE)), 0, 2
    )
    voxel_detail_filter_mode = clampi(
        int(config.get_value("graphics", "voxel_detail_filter_mode", DEFAULT_VOXEL_DETAIL_FILTER_MODE)), 0, 4
    )
    rock_crack_filter_mode = clampi(
        int(config.get_value("graphics", "rock_crack_filter_mode", DEFAULT_ROCK_CRACK_FILTER_MODE)), 0, 3
    )
    procedural_mip_filter_enabled = bool(config.get_value(
        "graphics", "procedural_mip_filter_enabled", DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED
    ))
    _apply_viewport_graphics_settings()


func save_settings(speed_multiplier: float, fov: float) -> bool:
    flight_speed_multiplier = clampf(speed_multiplier, MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER)
    flight_fov = clampf(fov, MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)
    return _save_all_settings()


func update_lod_settings(detail_bias: int, lod0_distance: float, persist: bool = true) -> bool:
    lod_detail_bias = clampi(detail_bias, 0, 3)
    lod0_distance_m = snappedf(clampf(lod0_distance, 32.0, 256.0), 16.0)
    if persist:
        return _save_all_settings()
    return true


func update_graphics_settings(
    new_msaa_mode: int,
    new_screen_space_aa_mode: int,
    new_voxel_detail_filter_mode: int,
    new_rock_crack_filter_mode: int,
    new_procedural_mip_filter_enabled: bool,
    persist: bool = true
) -> bool:
    msaa_mode = clampi(new_msaa_mode, 0, 3)
    screen_space_aa_mode = clampi(new_screen_space_aa_mode, 0, 2)
    voxel_detail_filter_mode = clampi(new_voxel_detail_filter_mode, 0, 4)
    rock_crack_filter_mode = clampi(new_rock_crack_filter_mode, 0, 3)
    procedural_mip_filter_enabled = new_procedural_mip_filter_enabled
    _apply_viewport_graphics_settings()
    if persist:
        return _save_all_settings()
    return true


func get_voxel_detail_filter_multiplier() -> float:
    match voxel_detail_filter_mode:
        0: return 0.0
        1: return 0.5
        2: return 1.0
        3: return 1.5
        _: return 2.0


func get_rock_crack_filter_multiplier() -> float:
    match rock_crack_filter_mode:
        0: return 0.0
        1: return 0.5
        2: return 1.0
        _: return 2.0


func _apply_viewport_graphics_settings() -> void:
    if not is_inside_tree():
        return
    var viewport: Viewport = get_tree().root
    match msaa_mode:
        1: viewport.msaa_3d = Viewport.MSAA_2X
        2: viewport.msaa_3d = Viewport.MSAA_4X
        3: viewport.msaa_3d = Viewport.MSAA_8X
        _: viewport.msaa_3d = Viewport.MSAA_DISABLED
    match screen_space_aa_mode:
        1: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
        2: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
        _: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED


func _save_all_settings() -> bool:
    # Preserve unrelated settings while removing old depth-of-field settings.
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    if config.has_section("lod"):
        config.erase_section("lod")
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    config.set_value("graphics", "msaa_mode", msaa_mode)
    config.set_value("graphics", "screen_space_aa_mode", screen_space_aa_mode)
    config.set_value("graphics", "voxel_detail_filter_mode", voxel_detail_filter_mode)
    config.set_value("graphics", "rock_crack_filter_mode", rock_crack_filter_mode)
    config.set_value("graphics", "procedural_mip_filter_enabled", procedural_mip_filter_enabled)
    for obsolete_key in [
        "experimental_far_terrain_blur_enabled", "far_terrain_blur_enabled",
        "far_terrain_blur_distance_m", "far_terrain_blur_amount", "fxaa_enabled",
        "antialiasing_mode", "distant_lod_shadow_filter_enabled", "mipmap_bias_mode",
        "distant_detail_filter_mode", "screen_space_detail_filter_enabled"
    ]:
        if config.has_section_key("graphics", obsolete_key):
            config.erase_section_key("graphics", obsolete_key)
    var error: Error = config.save(SETTINGS_PATH)
    if error != OK:
        push_warning("Не удалось сохранить настройки: " + error_string(error))
        return false
    return true


func reset_to_defaults() -> void:
    _set_defaults()
    _apply_viewport_graphics_settings()
    _save_all_settings()


func _set_defaults() -> void:
    flight_speed_multiplier = DEFAULT_FLIGHT_SPEED_MULTIPLIER
    flight_fov = DEFAULT_FLIGHT_FOV
    lod_detail_bias = DEFAULT_LOD_DETAIL_BIAS
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    msaa_mode = DEFAULT_MSAA_MODE
    screen_space_aa_mode = DEFAULT_SCREEN_SPACE_AA_MODE
    voxel_detail_filter_mode = DEFAULT_VOXEL_DETAIL_FILTER_MODE
    rock_crack_filter_mode = DEFAULT_ROCK_CRACK_FILTER_MODE
    procedural_mip_filter_enabled = DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED
