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
const DEFAULT_FAR_TERRAIN_BLUR_ENABLED: bool = false
const DEFAULT_FAR_TERRAIN_BLUR_DISTANCE_M: float = 256.0
const MIN_FAR_TERRAIN_BLUR_DISTANCE_M: float = 128.0
const MAX_FAR_TERRAIN_BLUR_DISTANCE_M: float = 2048.0
const FAR_TERRAIN_BLUR_DISTANCE_STEP_M: float = 128.0
const DEFAULT_FAR_TERRAIN_BLUR_AMOUNT: float = 0.035
const MIN_FAR_TERRAIN_BLUR_AMOUNT: float = 0.0
const MAX_FAR_TERRAIN_BLUR_AMOUNT: float = 0.12
const FAR_TERRAIN_BLUR_AMOUNT_STEP: float = 0.005

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
var lod_detail_bias: int = DEFAULT_LOD_DETAIL_BIAS
var lod0_distance_m: float = DEFAULT_LOD0_DISTANCE_M
var far_terrain_blur_enabled: bool = DEFAULT_FAR_TERRAIN_BLUR_ENABLED
var far_terrain_blur_distance_m: float = DEFAULT_FAR_TERRAIN_BLUR_DISTANCE_M
var far_terrain_blur_amount: float = DEFAULT_FAR_TERRAIN_BLUR_AMOUNT
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
    # LOD is fixed for this build; ignore old LOD values stored by previous versions.
    lod_detail_bias = DEFAULT_LOD_DETAIL_BIAS
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    # Migrate to a real camera depth-of-field filter. The previous shadow-only toggle
    # and global AA options are intentionally not reused.
    far_terrain_blur_enabled = bool(config.get_value(
        "graphics", "experimental_far_terrain_blur_enabled", DEFAULT_FAR_TERRAIN_BLUR_ENABLED
    ))
    far_terrain_blur_distance_m = snappedf(clampf(
        float(config.get_value(
            "graphics", "far_terrain_blur_distance_m", DEFAULT_FAR_TERRAIN_BLUR_DISTANCE_M
        )),
        MIN_FAR_TERRAIN_BLUR_DISTANCE_M,
        MAX_FAR_TERRAIN_BLUR_DISTANCE_M
    ), FAR_TERRAIN_BLUR_DISTANCE_STEP_M)
    far_terrain_blur_amount = snappedf(clampf(
        float(config.get_value(
            "graphics", "far_terrain_blur_amount", DEFAULT_FAR_TERRAIN_BLUR_AMOUNT
        )),
        MIN_FAR_TERRAIN_BLUR_AMOUNT,
        MAX_FAR_TERRAIN_BLUR_AMOUNT
    ), FAR_TERRAIN_BLUR_AMOUNT_STEP)


func save_settings(speed_multiplier: float, fov: float) -> bool:
    flight_speed_multiplier = clampf(
        speed_multiplier, MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER
    )
    flight_fov = clampf(fov, MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)
    return _save_all_settings()


func update_lod_settings(detail_bias: int, lod0_distance: float, persist: bool = true) -> bool:
    lod_detail_bias = clampi(detail_bias, 0, 3)
    lod0_distance_m = snappedf(clampf(lod0_distance, 32.0, 256.0), 16.0)
    if persist:
        return _save_all_settings()
    return true


func update_graphics_settings(
    far_blur_enabled: bool,
    blur_distance_m: float,
    blur_amount: float,
    persist: bool = true
) -> bool:
    far_terrain_blur_enabled = far_blur_enabled
    far_terrain_blur_distance_m = snappedf(clampf(
        blur_distance_m,
        MIN_FAR_TERRAIN_BLUR_DISTANCE_M,
        MAX_FAR_TERRAIN_BLUR_DISTANCE_M
    ), FAR_TERRAIN_BLUR_DISTANCE_STEP_M)
    far_terrain_blur_amount = snappedf(clampf(
        blur_amount,
        MIN_FAR_TERRAIN_BLUR_AMOUNT,
        MAX_FAR_TERRAIN_BLUR_AMOUNT
    ), FAR_TERRAIN_BLUR_AMOUNT_STEP)
    if persist:
        return _save_all_settings()
    return true


func _save_all_settings() -> bool:
    # Keep flight and graphics settings; discard obsolete experimental LOD values.
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    if config.has_section("lod"):
        config.erase_section("lod")
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    config.set_value("graphics", "experimental_far_terrain_blur_enabled", far_terrain_blur_enabled)
    config.set_value("graphics", "far_terrain_blur_distance_m", far_terrain_blur_distance_m)
    config.set_value("graphics", "far_terrain_blur_amount", far_terrain_blur_amount)
    for obsolete_key in [
        "far_terrain_blur_enabled",
        "antialiasing_mode",
        "distant_lod_shadow_filter_enabled",
        "mipmap_bias_mode",
        "distant_detail_filter_mode",
        "screen_space_detail_filter_enabled"
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
    _save_all_settings()


func _set_defaults() -> void:
    flight_speed_multiplier = DEFAULT_FLIGHT_SPEED_MULTIPLIER
    flight_fov = DEFAULT_FLIGHT_FOV
    lod_detail_bias = DEFAULT_LOD_DETAIL_BIAS
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    far_terrain_blur_enabled = DEFAULT_FAR_TERRAIN_BLUR_ENABLED
    far_terrain_blur_distance_m = DEFAULT_FAR_TERRAIN_BLUR_DISTANCE_M
    far_terrain_blur_amount = DEFAULT_FAR_TERRAIN_BLUR_AMOUNT
