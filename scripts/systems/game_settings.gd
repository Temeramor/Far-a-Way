extends Node

const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_FLIGHT_SPEED_MULTIPLIER: float = 10.0
const DEFAULT_FLIGHT_FOV: float = 100.0
const MIN_FLIGHT_SPEED_MULTIPLIER: float = 1.0
const MAX_FLIGHT_SPEED_MULTIPLIER: float = 20.0
const MIN_FLIGHT_FOV: float = 82.0
const MAX_FLIGHT_FOV: float = 120.0
const DEFAULT_LOD0_DISTANCE_M: float = 64.0
const DEFAULT_SHADOW_MODE: int = 1
const DEFAULT_VIEW_DISTANCE_M: float = 4096.0

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
# Fixed mobile graphics profile; intentionally no experimental user-facing toggles.
var lod0_distance_m: float = DEFAULT_LOD0_DISTANCE_M
var shadow_mode: int = DEFAULT_SHADOW_MODE
var view_distance_m: float = DEFAULT_VIEW_DISTANCE_M
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
        return

    flight_speed_multiplier = clampf(
        float(config.get_value("flight", "speed_multiplier", DEFAULT_FLIGHT_SPEED_MULTIPLIER)),
        MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER
    )
    flight_fov = clampf(
        float(config.get_value("flight", "fov", DEFAULT_FLIGHT_FOV)),
        MIN_FLIGHT_FOV, MAX_FLIGHT_FOV
    )
    _set_fixed_graphics_defaults()

    # Discard persisted AA, shadow, LOD and distance experiments after upgrading.
    var changed := false
    for legacy_section in ["graphics", "lod"]:
        if config.has_section(legacy_section):
            config.erase_section(legacy_section)
            changed = true
    if changed:
        var save_error: Error = config.save(SETTINGS_PATH)
        if save_error != OK:
            push_warning("Не удалось очистить старые графические настройки: " + error_string(save_error))


func save_settings(speed_multiplier: float, fov: float) -> bool:
    flight_speed_multiplier = clampf(speed_multiplier, MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER)
    flight_fov = clampf(fov, MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)
    return _save_all_settings()


# Internal compatibility hooks. Render distance and shadow range use fixed defaults.
func update_shadow_mode(mode: int, _persist: bool = false) -> bool:
    shadow_mode = clampi(mode, 0, 1)
    return true


func update_view_distance_m(distance_m: float, _persist: bool = false) -> bool:
    view_distance_m = snappedf(clampf(distance_m, 512.0, 8192.0), 256.0)
    return true


func _save_all_settings() -> bool:
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    if config.has_section("graphics"):
        config.erase_section("graphics")
    if config.has_section("lod"):
        config.erase_section("lod")
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
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
    _set_fixed_graphics_defaults()


func _set_fixed_graphics_defaults() -> void:
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    shadow_mode = DEFAULT_SHADOW_MODE
    view_distance_m = DEFAULT_VIEW_DISTANCE_M
