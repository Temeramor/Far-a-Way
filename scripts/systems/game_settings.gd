extends Node

const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_FLIGHT_SPEED_MULTIPLIER: float = 10.0
const DEFAULT_FLIGHT_FOV: float = 100.0
const MIN_FLIGHT_SPEED_MULTIPLIER: float = 1.0
const MAX_FLIGHT_SPEED_MULTIPLIER: float = 20.0
const MIN_FLIGHT_FOV: float = 82.0
const MAX_FLIGHT_FOV: float = 120.0
const DEFAULT_LOD_DETAIL_BIAS: int = 1
const DEFAULT_LOD0_DISTANCE_M: float = 64.0
const DEFAULT_ANTI_ALIASING_MODE: int = 3
const DEFAULT_SHADOW_MODE: int = 1
const DEFAULT_VIEW_DISTANCE_M: float = 4096.0
const DEFAULT_VOXEL_DETAIL_FILTER_MODE: int = 2
const DEFAULT_ROCK_CRACK_FILTER_MODE: int = 2
const DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED: bool = true

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
var lod_detail_bias: int = DEFAULT_LOD_DETAIL_BIAS
var lod0_distance_m: float = DEFAULT_LOD0_DISTANCE_M
var anti_aliasing_mode: int = DEFAULT_ANTI_ALIASING_MODE
var shadow_mode: int = DEFAULT_SHADOW_MODE
var view_distance_m: float = DEFAULT_VIEW_DISTANCE_M

# These remain internal shader defaults, not user-facing graphics settings.
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
    var error: Error = config.load(SETTINGS_PATH)
    if error != OK:
        _set_defaults()
        _apply_viewport_graphics_settings()
        return
    flight_speed_multiplier = clampf(float(config.get_value("flight", "speed_multiplier", DEFAULT_FLIGHT_SPEED_MULTIPLIER)), MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER)
    flight_fov = clampf(float(config.get_value("flight", "fov", DEFAULT_FLIGHT_FOV)), MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)
    if config.has_section_key("graphics", "anti_aliasing_mode"):
        anti_aliasing_mode = clampi(int(config.get_value("graphics", "anti_aliasing_mode", DEFAULT_ANTI_ALIASING_MODE)), 0, 5)
    else:
        var old_screen_aa: int = int(config.get_value("graphics", "screen_space_aa_mode", 0))
        var old_msaa: int = int(config.get_value("graphics", "msaa_mode", 1))
        if old_screen_aa > 0:
            anti_aliasing_mode = clampi(old_screen_aa, 1, 2)
        else:
            match old_msaa:
                0: anti_aliasing_mode = 0
                2: anti_aliasing_mode = 4
                3: anti_aliasing_mode = 5
                _: anti_aliasing_mode = 3
    shadow_mode = clampi(int(config.get_value("graphics", "shadow_mode", DEFAULT_SHADOW_MODE)), 0, 1)
    view_distance_m = snappedf(clampf(float(config.get_value("graphics", "view_distance_m", DEFAULT_VIEW_DISTANCE_M)), 512.0, 8192.0), 256.0)
    lod_detail_bias = DEFAULT_LOD_DETAIL_BIAS
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    _apply_viewport_graphics_settings()


func save_settings(speed_multiplier: float, fov: float) -> bool:
    flight_speed_multiplier = clampf(speed_multiplier, MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER)
    flight_fov = clampf(fov, MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)
    return _save_all_settings()


func update_lod_settings(detail_bias: int, lod0_distance: float, persist: bool = true) -> bool:
    lod_detail_bias = clampi(detail_bias, 0, 3)
    lod0_distance_m = snappedf(clampf(lod0_distance, 32.0, 256.0), 16.0)
    return _save_all_settings() if persist else true


func update_anti_aliasing_mode(mode: int, persist: bool = true) -> bool:
    anti_aliasing_mode = clampi(mode, 0, 5)
    _apply_viewport_graphics_settings()
    return _save_all_settings() if persist else true


func update_shadow_mode(mode: int, persist: bool = true) -> bool:
    shadow_mode = clampi(mode, 0, 1)
    return _save_all_settings() if persist else true


func update_view_distance_m(distance_m: float, persist: bool = true) -> bool:
    view_distance_m = snappedf(clampf(distance_m, 512.0, 8192.0), 256.0)
    return _save_all_settings() if persist else true


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
    viewport.msaa_3d = Viewport.MSAA_DISABLED
    viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
    match anti_aliasing_mode:
        1: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
        2: viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
        3: viewport.msaa_3d = Viewport.MSAA_2X
        4: viewport.msaa_3d = Viewport.MSAA_4X
        5: viewport.msaa_3d = Viewport.MSAA_8X
        _: pass


func _save_all_settings() -> bool:
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    if config.has_section("lod"):
        config.erase_section("lod")
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    config.set_value("graphics", "anti_aliasing_mode", anti_aliasing_mode)
    config.set_value("graphics", "shadow_mode", shadow_mode)
    config.set_value("graphics", "view_distance_m", view_distance_m)
    for obsolete_key in [
        "msaa_mode", "screen_space_aa_mode", "voxel_detail_filter_mode",
        "rock_crack_filter_mode", "procedural_mip_filter_enabled",
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
    anti_aliasing_mode = DEFAULT_ANTI_ALIASING_MODE
    shadow_mode = DEFAULT_SHADOW_MODE
    view_distance_m = DEFAULT_VIEW_DISTANCE_M
    voxel_detail_filter_mode = DEFAULT_VOXEL_DETAIL_FILTER_MODE
    rock_crack_filter_mode = DEFAULT_ROCK_CRACK_FILTER_MODE
    procedural_mip_filter_enabled = DEFAULT_PROCEDURAL_MIP_FILTER_ENABLED
