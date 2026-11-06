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
const DEFAULT_VIEW_DISTANCE_M: float = 1536.0
const MIN_VIEW_DISTANCE_M: float = 512.0
const MAX_VIEW_DISTANCE_M: float = 2048.0
const DEFAULT_LOD_TARGET_PIXELS: float = 3.0
const DEFAULT_WINDOW_WIDTH: int = 1280
const DEFAULT_WINDOW_HEIGHT: int = 720

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
# Runtime graphics controls that are persisted between sessions.
var lod0_distance_m: float = DEFAULT_LOD0_DISTANCE_M
var shadow_mode: int = DEFAULT_SHADOW_MODE
var view_distance_m: float = DEFAULT_VIEW_DISTANCE_M
var lod_target_pixels: float = DEFAULT_LOD_TARGET_PIXELS
var window_mode: int = 0 # 0 = windowed, 1 = fullscreen
var window_width: int = DEFAULT_WINDOW_WIDTH
var window_height: int = DEFAULT_WINDOW_HEIGHT
var requested_seed: int = 1337
var has_requested_seed: bool = false


func request_new_game(seed_value: int) -> void:
    requested_seed = seed_value
    has_requested_seed = true


func _ready() -> void:
    load_settings()
    apply_display_settings()


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
    view_distance_m = snappedf(clampf(float(config.get_value("graphics", "view_distance_m", DEFAULT_VIEW_DISTANCE_M)), MIN_VIEW_DISTANCE_M, MAX_VIEW_DISTANCE_M), 256.0)
    lod_target_pixels = clampf(float(config.get_value("graphics", "lod_target_pixels", DEFAULT_LOD_TARGET_PIXELS)), 2.0, 4.0)
    window_mode = clampi(int(config.get_value("display", "mode", 0)), 0, 1)
    window_width = int(config.get_value("display", "width", DEFAULT_WINDOW_WIDTH))
    window_height = int(config.get_value("display", "height", DEFAULT_WINDOW_HEIGHT))
    _normalise_resolution()

    # Keep the supported render-distance and screen-space LOD settings; discard only legacy LOD keys.
    var changed := false
    for legacy_section in ["lod"]:
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
    view_distance_m = snappedf(clampf(distance_m, MIN_VIEW_DISTANCE_M, MAX_VIEW_DISTANCE_M), 256.0)
    return _save_all_settings() if _persist else true


func update_lod_target_pixels(target_pixels: float, persist: bool = false) -> bool:
    lod_target_pixels = clampf(target_pixels, 2.0, 4.0)
    return _save_all_settings() if persist else true


func _save_all_settings() -> bool:
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    if config.has_section("lod"):
        config.erase_section("lod")
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    config.set_value("graphics", "view_distance_m", view_distance_m)
    config.set_value("graphics", "lod_target_pixels", lod_target_pixels)
    config.set_value("display", "mode", window_mode)
    config.set_value("display", "width", window_width)
    config.set_value("display", "height", window_height)
    var error: Error = config.save(SETTINGS_PATH)
    if error != OK:
        push_warning("Не удалось сохранить настройки: " + error_string(error))
        return false
    return true


func set_display_settings(mode: int, width: int, height: int) -> void:
    window_mode = clampi(mode, 0, 1)
    window_width = width
    window_height = height
    _normalise_resolution()
    apply_display_settings()
    _save_all_settings()


func apply_display_settings() -> void:
    if not is_inside_tree():
        return
    var target_mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN if window_mode == 1 else DisplayServer.WINDOW_MODE_WINDOWED
    if window_mode == 0:
        DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
        DisplayServer.window_set_size(Vector2i(window_width, window_height))
        var screen_size: Vector2i = DisplayServer.screen_get_size()
        DisplayServer.window_set_position(Vector2i(maxi(0, floori(float(screen_size.x - window_width) * 0.5)), maxi(0, floori(float(screen_size.y - window_height) * 0.5))))
    else:
        DisplayServer.window_set_size(Vector2i(window_width, window_height))
        DisplayServer.window_set_mode(target_mode)


func _normalise_resolution() -> void:
    var allowed: Array[Vector2i] = [Vector2i(640, 360), Vector2i(800, 450), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]
    var chosen := Vector2i(window_width, window_height)
    var best: Vector2i = allowed[0]
    var best_distance: int = 2147483647
    for size in allowed:
        var distance: int = absi(size.x - chosen.x) + absi(size.y - chosen.y)
        if distance < best_distance:
            best = size
            best_distance = distance
    window_width = best.x
    window_height = best.y


func reset_to_defaults() -> void:
    _set_defaults()
    apply_display_settings()
    _save_all_settings()


func _set_defaults() -> void:
    flight_speed_multiplier = DEFAULT_FLIGHT_SPEED_MULTIPLIER
    flight_fov = DEFAULT_FLIGHT_FOV
    _set_fixed_graphics_defaults()


func _set_fixed_graphics_defaults() -> void:
    lod0_distance_m = DEFAULT_LOD0_DISTANCE_M
    shadow_mode = DEFAULT_SHADOW_MODE
    view_distance_m = DEFAULT_VIEW_DISTANCE_M
    lod_target_pixels = DEFAULT_LOD_TARGET_PIXELS
    window_mode = 0
    window_width = DEFAULT_WINDOW_WIDTH
    window_height = DEFAULT_WINDOW_HEIGHT
