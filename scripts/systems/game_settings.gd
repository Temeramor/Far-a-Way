extends Node

## Centralized saved settings shared between the menu and gameplay scenes.
const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_FLIGHT_SPEED_MULTIPLIER: float = 10.0
const DEFAULT_FLIGHT_FOV: float = 100.0
const MIN_FLIGHT_SPEED_MULTIPLIER: float = 1.0
const MAX_FLIGHT_SPEED_MULTIPLIER: float = 20.0
const MIN_FLIGHT_FOV: float = 82.0
const MAX_FLIGHT_FOV: float = 120.0

var flight_speed_multiplier: float = DEFAULT_FLIGHT_SPEED_MULTIPLIER
var flight_fov: float = DEFAULT_FLIGHT_FOV
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


func save_settings(speed_multiplier: float, fov: float) -> bool:
    flight_speed_multiplier = clampf(
        speed_multiplier, MIN_FLIGHT_SPEED_MULTIPLIER, MAX_FLIGHT_SPEED_MULTIPLIER
    )
    flight_fov = clampf(fov, MIN_FLIGHT_FOV, MAX_FLIGHT_FOV)

    var config := ConfigFile.new()
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    var error = config.save(SETTINGS_PATH)
    if error != OK:
        push_warning("Не удалось сохранить настройки: %s" % error_string(error))
        return false
    return true


func reset_to_defaults() -> void:
    _set_defaults()
    var config := ConfigFile.new()
    config.set_value("flight", "speed_multiplier", flight_speed_multiplier)
    config.set_value("flight", "fov", flight_fov)
    var error = config.save(SETTINGS_PATH)
    if error != OK:
        push_warning("Не удалось сохранить настройки по умолчанию: %s" % error_string(error))


func _set_defaults() -> void:
    flight_speed_multiplier = DEFAULT_FLIGHT_SPEED_MULTIPLIER
    flight_fov = DEFAULT_FLIGHT_FOV
