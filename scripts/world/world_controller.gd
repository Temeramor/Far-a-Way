extends Node3D
class_name WorldController

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
var _voxen_debug_button: Button
var _voxen_debug_panel: PanelContainer
var _voxen_debug_label: Label
var _voxen_debug_visible: bool = false
var _voxen_debug_timer: float = 0.0
var _pause_menu: PauseMenu


func _ready() -> void:
    player.flight_mode_changed.connect(_on_flight_mode_changed)
    terrain.generation_started.connect(_on_generation_started)
    terrain.generation_progress.connect(_on_generation_progress)
    terrain.generation_finished.connect(_on_generation_finished)
    if time_of_day.has_signal("time_changed"):
        time_of_day.time_changed.connect(_on_time_changed)

    player.process_mode = Node.PROCESS_MODE_DISABLED
    loading_screen.visible = false
    voxel_world.set_lod_settings(GameSettings.lod0_distance_m)
    voxel_world.set_shadow_mode(GameSettings.shadow_mode)
    voxel_world.set_render_distance_m(GameSettings.view_distance_m)
    _configure_sky_system()
    _apply_view_distance_environment(GameSettings.view_distance_m)
    _build_flight_status()
    _setup_weather_controls()
    _build_voxen_debug_ui()
    _build_pause_menu_ui()
    _apply_weather(WEATHER_CLOUDY, false)
    call_deferred("_begin_pending_game_if_requested")


func set_view_distance_m(distance_m: float, persist: bool = true) -> void:
    var safe_distance: float = snappedf(clampf(distance_m, 512.0, 8192.0), 256.0)
    GameSettings.update_view_distance_m(safe_distance, persist)
    voxel_world.set_render_distance_m(GameSettings.view_distance_m)
    _apply_view_distance_environment(GameSettings.view_distance_m)


func _apply_view_distance_environment(distance_m: float) -> void:
    var safe_distance: float = clampf(distance_m, 512.0, 8192.0)
    var gameplay_camera: Camera3D = $Player/CameraPivot/Camera3D
    gameplay_camera.far = safe_distance * 1.06
    var environment: Environment = sky_system.environment
    if environment != null:
        environment.fog_enabled = true
        environment.fog_mode = Environment.FOG_MODE_DEPTH
        environment.fog_depth_begin = safe_distance * 0.70
        environment.fog_depth_end = safe_distance * 0.98
        environment.fog_depth_curve = 1.20
        environment.fog_light_color = Color(0.25, 0.31, 0.26, 1.0)
        environment.fog_light_energy = 0.72
        environment.fog_sun_scatter = 0.0
        environment.fog_aerial_perspective = 0.0
        environment.fog_sky_affect = 0.0
    for light_name in ["SunLight", "MoonLight"]:
        var directional_light := sky_system.get_node_or_null(light_name) as DirectionalLight3D
        if directional_light != null:
            directional_light.shadow_enabled = true
            directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
            directional_light.directional_shadow_blend_splits = true
            directional_light.directional_shadow_max_distance = minf(safe_distance, 1024.0)
            directional_light.directional_shadow_fade_start = 0.92


func _configure_sky_system() -> void:
    # The Sky controller owns the sun, moon, atmosphere, clouds and the clock. Use an equatorial
    # location so the four time presets remain intuitive throughout the year.
    # With the add-on's realistic celestial calculation, the sun travels east to west.
    time_of_day.set("system_sync", false)
    time_of_day.set("celestials_calculations", 1) # TimeOfDay.CelestialMode.REALISTIC
    time_of_day.set("latitude", 0.0)
    time_of_day.set("longitude", 0.0)
    time_of_day.set("utc", 0.0)
    time_of_day.set("year", 2025)
    time_of_day.set("month", 3)
    time_of_day.set("day", 20)
    sky_system.set("game_time_enabled", true)
    sky_system.set("editor_time_enabled", false)
    sky_system.set("minutes_per_day", 24.0)
    sky_system.set("update_interval", 0.033)
    sky_system.set("current_time", 12.0)
    sky_dome.set("process_method", 1) # Process, cloud movement at render rate.


func _begin_pending_game_if_requested() -> void:
    if GameSettings.has_requested_seed:
        var pending_seed: int = GameSettings.requested_seed
        GameSettings.has_requested_seed = false
        begin_generation(pending_seed)


func begin_generation(seed_value: int) -> void:
    if _generation_started:
        return
    _generation_started = true
    _world_ready = false
    if weather_panel != null:
        weather_panel.visible = false
    if weather_menu_button != null:
        weather_menu_button.visible = false
        weather_menu_button.disabled = true
    _weather_menu_open = false
    player.mouse_capture_paused = false

    player.flight_speed_multiplier = GameSettings.flight_speed_multiplier
    player.flight_fov = GameSettings.flight_fov
    voxel_world.set_render_distance_m(GameSettings.view_distance_m)
    _apply_view_distance_environment(GameSettings.view_distance_m)

    loading_screen.visible = true
    loading_screen.set_progress(0.0, "Подготавливаем генератор ландшафта...")
    terrain.generate(seed_value)


func _on_generation_started(seed_value: int) -> void:
    loading_screen.set_progress(0.0, "Сид мира: %d — создаём рельеф" % seed_value)
    terrain.call("set_weather", _weather_mode)


func _on_generation_progress(_seed_value: int, progress: float, message: String) -> void:
    loading_screen.set_progress(progress, message)


func _on_generation_finished(_seed_value: int) -> void:
    # The CharacterBody origin is at the capsule feet; camera is at eye level.
    var ground_height: float = terrain.height_at_world(0.0, 0.0)
    player.global_position = Vector3(0.0, ground_height + 0.12, 0.0)
    player.velocity = Vector3.ZERO
    player.reset_camera()

    player.process_mode = Node.PROCESS_MODE_INHERIT
    loading_screen.set_progress(1.0, "Мир готов. Приятного исследования!")
    loading_screen.visible = false
    _world_ready = true
    if weather_menu_button != null:
        weather_menu_button.visible = false
        weather_menu_button.disabled = false
    if weather_panel != null:
        weather_panel.visible = false
    _weather_menu_open = false
    player.mouse_capture_paused = false
    _update_weather_button_styles()
    _update_time_button_styles()
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _build_flight_status() -> void:
    flight_status_label = Label.new()
    flight_status_label.name = "FlightStatus"
    flight_status_label.text = "РЕЖИМ ПОЛЁТА — скорость ×%.0f" % GameSettings.flight_speed_multiplier
    flight_status_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
    flight_status_label.position = Vector2(20.0, 18.0)
    flight_status_label.size = Vector2(340.0, 34.0)
    flight_status_label.visible = false
    flight_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flight_status_label.add_theme_font_size_override("font_size", 16)
    flight_status_label.add_theme_color_override("font_color", Color(0.93, 0.97, 0.88, 0.96))

    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.045, 0.07, 0.055, 0.70)
    style.set_corner_radius_all(7)
    style.content_margin_left = 10.0
    style.content_margin_right = 10.0
    style.content_margin_top = 5.0
    style.content_margin_bottom = 5.0
    flight_status_backdrop = Panel.new()
    flight_status_backdrop.name = "FlightStatusBackdrop"
    flight_status_backdrop.position = flight_status_label.position
    flight_status_backdrop.size = flight_status_label.size
    flight_status_backdrop.add_theme_stylebox_override("panel", style)
    flight_status_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    $CanvasLayer.add_child(flight_status_backdrop)
    $CanvasLayer.add_child(flight_status_label)
    $CanvasLayer.move_child(flight_status_backdrop, $CanvasLayer.get_child_count() - 2)
    $CanvasLayer.move_child(flight_status_label, $CanvasLayer.get_child_count() - 1)
    flight_status_backdrop.visible = false


func _on_flight_mode_changed(enabled: bool) -> void:
    if flight_status_label == null:
        return
    flight_status_label.text = "РЕЖИМ ПОЛЁТА — скорость ×%.0f" % player.flight_speed_multiplier
    flight_status_label.visible = enabled
    if flight_status_backdrop != null:
        flight_status_backdrop.visible = enabled


func _setup_weather_controls() -> void:
    weather_panel = PanelContainer.new()
    weather_panel.name = "WeatherAndTimeMenu"
    weather_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
    weather_panel.offset_left = -205.0
    weather_panel.offset_top = 62.0
    weather_panel.offset_right = 205.0
    weather_panel.offset_bottom = 250.0
    weather_panel.mouse_filter = Control.MOUSE_FILTER_STOP

    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.035, 0.055, 0.045, 0.96)
    panel_style.border_color = Color(0.32, 0.39, 0.27, 0.95)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(9)
    panel_style.content_margin_left = 12.0
    panel_style.content_margin_right = 12.0
    panel_style.content_margin_top = 10.0
    panel_style.content_margin_bottom = 10.0
    weather_panel.add_theme_stylebox_override("panel", panel_style)

    var rows := VBoxContainer.new()
    rows.name = "MenuRows"
    rows.add_theme_constant_override("separation", 10)
    weather_panel.add_child(rows)

    var header := HBoxContainer.new()
    header.name = "Header"
    rows.add_child(header)

    var title := Label.new()
    title.text = "ПОГОДА И ВРЕМЯ"
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.add_theme_font_size_override("font_size", 15)
    title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.87, 1.0))
    header.add_child(title)

    var close_button := _make_control_button("CloseWeatherMenu", "×", "Закрыть меню")
    close_button.custom_minimum_size = Vector2(34.0, 30.0)
    close_button.add_theme_font_size_override("font_size", 20)
    close_button.pressed.connect(_set_weather_menu_open.bind(false))
    header.add_child(close_button)

    var weather_row := HBoxContainer.new()
    weather_row.name = "WeatherSelection"
    weather_row.add_theme_constant_override("separation", 10)
    rows.add_child(weather_row)

    var weather_label := Label.new()
    weather_label.text = "Погода"
    weather_label.custom_minimum_size = Vector2(100.0, 0.0)
    weather_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    weather_label.add_theme_color_override("font_color", Color(0.88, 0.91, 0.82, 1.0))
    weather_row.add_child(weather_label)

    weather_selector = OptionButton.new()
    weather_selector.name = "WeatherSelector"
    weather_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    weather_selector.add_item("Ясно", WEATHER_CLEAR)
    weather_selector.add_item("Облачно", WEATHER_CLOUDY)
    weather_selector.add_item("Пасмурно", WEATHER_OVERCAST)
    weather_selector.item_selected.connect(_on_weather_selection_changed)
    _style_button(weather_selector, false)
    weather_row.add_child(weather_selector)

    var time_row := HBoxContainer.new()
    time_row.name = "TimeSelection"
    time_row.add_theme_constant_override("separation", 10)
    rows.add_child(time_row)

    var time_label := Label.new()
    time_label.text = "Время суток"
    time_label.custom_minimum_size = Vector2(100.0, 0.0)
    time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    time_label.add_theme_color_override("font_color", Color(0.88, 0.91, 0.82, 1.0))
    time_row.add_child(time_label)

    time_selector = OptionButton.new()
    time_selector.name = "TimeSelector"
    time_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    for preset in range(TIME_LABELS.size()):
        time_selector.add_item(TIME_LABELS[preset], preset)
    time_selector.item_selected.connect(_on_time_selection_changed)
    _style_button(time_selector, false)
    time_row.add_child(time_selector)

    var hint := Label.new()
    hint.text = "M — открыть/закрыть · Esc — закрыть"
    hint.visible = true
    hint.add_theme_font_size_override("font_size", 11)
    hint.add_theme_color_override("font_color", Color(0.66, 0.72, 0.63, 1.0))
    rows.add_child(hint)

    $CanvasLayer.add_child(weather_panel)
    weather_panel.visible = false

    weather_menu_button = _make_control_button("WeatherMenuToggle", "ПОГОДА / ВРЕМЯ", "Открыть настройки погоды и времени")
    weather_menu_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
    weather_menu_button.offset_left = -210.0
    weather_menu_button.offset_top = 14.0
    weather_menu_button.offset_right = -14.0
    weather_menu_button.offset_bottom = 54.0
    weather_menu_button.custom_minimum_size = Vector2(196.0, 40.0)
    weather_menu_button.visible = false
    weather_menu_button.disabled = true
    weather_menu_button.pressed.connect(_toggle_weather_menu)
    $CanvasLayer.add_child(weather_menu_button)

    _update_weather_button_styles()
    _update_time_button_styles()


func _make_control_button(button_name: String, caption: String, hint: String) -> Button:
    var control_button := Button.new()
    control_button.name = button_name
    control_button.text = caption
    control_button.tooltip_text = hint
    control_button.focus_mode = Control.FOCUS_NONE
    control_button.add_theme_font_size_override("font_size", 13)
    control_button.add_theme_color_override("font_color", Color(0.94, 0.96, 0.87, 1.0))
    control_button.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.94, 1.0))
    control_button.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 0.94, 1.0))
    return control_button


func _on_weather_button_pressed(mode: int) -> void:
    var next_mode: int = clampi(mode, WEATHER_CLEAR, WEATHER_OVERCAST)
    if next_mode != _weather_mode:
        _weather_mode = next_mode
        terrain.call("set_weather", _weather_mode)
        _apply_weather(_weather_mode, true)
    _update_weather_button_styles()


func _apply_weather(mode: int, animate: bool) -> void:
    if not is_instance_valid(sky_dome) or not is_instance_valid(sky_system):
        return
    if _sky_tween and _sky_tween.is_running():
        _sky_tween.kill()

    var cumulus_coverage: float
    var cirrus_coverage: float
    var cumulus_intensity: float
    var cumulus_thickness: float
    var cumulus_absorption: float
    var cumulus_frequency: float
    var cirrus_intensity: float
    var cirrus_thickness: float
    var sun_energy: float
    var ambient_energy: float
    var sky_exposure: float
    var sun_disk_intensity: float
    var wind_speed: float
    var day_tint: Color
    var horizon_tint: Color

    match mode:
        WEATHER_CLEAR:
            cumulus_coverage = 0.24
            cirrus_coverage = 0.27
            cumulus_intensity = 0.72
            cumulus_thickness = 0.022
            cumulus_absorption = 2.0
            cumulus_frequency = 1.45
            cirrus_intensity = 1.25
            cirrus_thickness = 1.45
            sun_energy = 1.22
            ambient_energy = 0.88
            sky_exposure = 1.05
            sun_disk_intensity = 30.0
            wind_speed = 2.0
            day_tint = Color(0.8078, 0.9098, 1.0, 1.0)
            horizon_tint = Color(0.98, 0.635, 0.463, 1.0)
        WEATHER_CLOUDY:
            cumulus_coverage = 0.55
            cirrus_coverage = 0.50
            cumulus_intensity = 0.60
            cumulus_thickness = 0.0243
            cumulus_absorption = 2.0
            cumulus_frequency = 2.7
            cirrus_intensity = 2.0
            cirrus_thickness = 1.7
            sun_energy = 0.95
            ambient_energy = 0.72
            sky_exposure = 1.0
            sun_disk_intensity = 30.0
            wind_speed = 5.0
            day_tint = Color(0.74, 0.84, 0.94, 1.0)
            horizon_tint = Color(0.90, 0.67, 0.55, 1.0)
        _:
            cumulus_coverage = 0.82
            cirrus_coverage = 0.68
            cumulus_intensity = 0.48
            cumulus_thickness = 0.030
            cumulus_absorption = 2.4
            cumulus_frequency = 2.2
            cirrus_intensity = 1.65
            cirrus_thickness = 2.0
            sun_energy = 0.34
            ambient_energy = 0.53
            sky_exposure = 0.82
            sun_disk_intensity = 11.0
            wind_speed = 10.0
            day_tint = Color(0.53, 0.60, 0.68, 1.0)
            horizon_tint = Color(0.48, 0.54, 0.61, 1.0)

    # The bundled cloud noise is retained for normal and overcast weather. Clear weather
    # uses a code-generated, lower-frequency seamless texture to create wider cloud gaps.
    sky_dome.set("cumulus_texture", SKY_NOISE_CLEAR if mode == WEATHER_CLEAR else SKY_NOISE_CLOUDY)

    var targets: Dictionary = {
        "cumulus_coverage": cumulus_coverage,
        "cirrus_coverage": cirrus_coverage,
        "cumulus_intensity": cumulus_intensity,
        "cumulus_thickness": cumulus_thickness,
        "cumulus_absorption": cumulus_absorption,
        "cumulus_noise_freq": cumulus_frequency,
        "cirrus_intensity": cirrus_intensity,
        "cirrus_thickness": cirrus_thickness,
        "sun_light_energy": sun_energy,
        "exposure": sky_exposure,
        "sun_disk_intensity": sun_disk_intensity,
        "atm_day_tint": day_tint,
        "atm_horizon_light_tint": horizon_tint,
        "wind_speed": wind_speed,
    }

    if not animate:
        for property_name in targets:
            sky_dome.set(property_name, targets[property_name])
        sky_system.environment.ambient_light_energy = ambient_energy
        return

    _sky_tween = create_tween()
    _sky_tween.set_parallel(true)
    _sky_tween.set_trans(Tween.TRANS_SINE)
    _sky_tween.set_ease(Tween.EASE_IN_OUT)
    for property_name in targets:
        _sky_tween.tween_property(sky_dome, property_name, targets[property_name], 2.5)
    # Tween the Environment directly: the Sky controller's ambient-energy alias starts its own
    # sky-contribution tween from its setter, so animating that alias would fight itself.
    _sky_tween.tween_property(sky_system.environment, "ambient_light_energy", ambient_energy, 2.5)


func _update_weather_button_styles() -> void:
    if weather_selector != null:
        weather_selector.select(_weather_mode)


func _on_weather_selection_changed(index: int) -> void:
    if weather_selector == null:
        return
    _on_weather_button_pressed(weather_selector.get_item_id(index))


func _on_time_selection_changed(index: int) -> void:
    if time_selector == null:
        return
    _on_time_preset_pressed(time_selector.get_item_id(index))


func _on_time_preset_pressed(preset: int) -> void:
    var safe_preset: int = clampi(preset, TIME_DAWN, TIME_NIGHT)
    sky_system.set("current_time", TIME_PRESETS[safe_preset])
    _time_mode = safe_preset
    _update_time_button_styles()


func _on_time_changed(value: float) -> void:
    # Keep the active time preset in sync while the Sky controller advances its clock automatically.
    if value >= 4.0 and value < 9.0:
        _time_mode = TIME_DAWN
    elif value >= 9.0 and value < 16.0:
        _time_mode = TIME_DAY
    elif value >= 16.0 and value < 21.0:
        _time_mode = TIME_DUSK
    else:
        _time_mode = TIME_NIGHT
    if _time_mode != _last_styled_time_mode:
        _last_styled_time_mode = _time_mode
        _update_time_button_styles()


func _update_time_button_styles() -> void:
    if time_selector != null:
        time_selector.select(_time_mode)


func _toggle_weather_menu() -> void:
    _set_weather_menu_open(not _weather_menu_open)


func _set_weather_menu_open(open: bool) -> void:
    if open and (not _world_ready or weather_panel == null):
        return
    if open == _weather_menu_open:
        return

    if open:
        _mouse_mode_before_weather_menu = Input.mouse_mode
        _weather_menu_open = true
        weather_panel.visible = true
        player.mouse_capture_paused = true
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    else:
        _weather_menu_open = false
        weather_panel.visible = false
        player.mouse_capture_paused = false
        Input.mouse_mode = _mouse_mode_before_weather_menu


func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey) or not event.pressed or event.echo:
        return

    if event.keycode == KEY_ESCAPE:
        if _weather_menu_open:
            _set_weather_menu_open(false)
        elif _world_ready and _pause_menu != null:
            _pause_menu.open_pause()
        get_viewport().set_input_as_handled()
    elif event.keycode == KEY_F3 or event.physical_keycode == KEY_F3:
        _toggle_voxen_debug()
        get_viewport().set_input_as_handled()
    elif event.keycode == KEY_M or event.physical_keycode == KEY_M:
        _set_weather_menu_open(not _weather_menu_open)
        get_viewport().set_input_as_handled()


func _style_button(control_button: Button, selected: bool) -> void:
    var normal_style := StyleBoxFlat.new()
    normal_style.bg_color = Color(0.25, 0.34, 0.20, 0.97) if selected else Color(0.065, 0.09, 0.075, 0.94)
    normal_style.border_color = Color(0.75, 0.78, 0.53, 0.98) if selected else Color(0.28, 0.35, 0.26, 0.9)
    normal_style.set_border_width_all(1)
    normal_style.set_corner_radius_all(5)
    normal_style.content_margin_left = 7.0
    normal_style.content_margin_right = 7.0
    normal_style.content_margin_top = 4.0
    normal_style.content_margin_bottom = 4.0

    var hover_style := normal_style.duplicate() as StyleBoxFlat
    hover_style.bg_color = Color(0.33, 0.43, 0.26, 1.0) if selected else Color(0.12, 0.17, 0.12, 0.98)
    var pressed_style := normal_style.duplicate() as StyleBoxFlat
    pressed_style.bg_color = Color(0.18, 0.25, 0.15, 1.0)
    control_button.add_theme_stylebox_override("normal", normal_style)
    control_button.add_theme_stylebox_override("hover", hover_style)
    control_button.add_theme_stylebox_override("pressed", pressed_style)


func _process(delta: float) -> void:
    if not _voxen_debug_visible or _voxen_debug_label == null:
        return
    _voxen_debug_timer += delta
    if _voxen_debug_timer >= 0.2:
        _voxen_debug_timer = 0.0
        _voxen_debug_label.text = terrain.get_debug_text()


func _build_voxen_debug_ui() -> void:
    _voxen_debug_panel = PanelContainer.new()
    _voxen_debug_panel.name = "VoxEnDebugPanel"
    _voxen_debug_panel.position = Vector2(14.0, 14.0)
    var view_width: float = get_viewport().get_visible_rect().size.x
    var debug_width: float = maxf(240.0, minf(790.0, view_width - 28.0))
    _voxen_debug_panel.size = Vector2(debug_width, 360.0)
    _voxen_debug_panel.custom_minimum_size = Vector2(minf(480.0, debug_width), 360.0)
    _voxen_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.025, 0.04, 0.035, 0.88)
    panel_style.border_color = Color(0.42, 0.51, 0.36, 0.9)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(4)
    panel_style.content_margin_left = 10.0
    panel_style.content_margin_right = 10.0
    panel_style.content_margin_top = 7.0
    panel_style.content_margin_bottom = 7.0
    _voxen_debug_panel.add_theme_stylebox_override("panel", panel_style)
    _voxen_debug_label = Label.new()
    _voxen_debug_label.name = "VoxEnDebugText"
    _voxen_debug_label.text = "VoxEn diagnostics — ожидание первой генерации...\nF3 — закрыть панель"
    _voxen_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _voxen_debug_label.add_theme_font_size_override("font_size", 12)
    _voxen_debug_label.add_theme_color_override("font_color", Color(0.91, 0.95, 0.85, 1.0))
    _voxen_debug_panel.add_child(_voxen_debug_label)
    $CanvasLayer.add_child(_voxen_debug_panel)
    _voxen_debug_panel.visible = false


func _toggle_voxen_debug() -> void:
    _voxen_debug_visible = not _voxen_debug_visible
    if _voxen_debug_panel != null:
        _voxen_debug_panel.visible = _voxen_debug_visible
    if _voxen_debug_visible and _voxen_debug_label != null:
        _voxen_debug_label.text = terrain.get_debug_text()



func _build_pause_menu_ui() -> void:

    _pause_menu = PauseMenuScript.new() as PauseMenu
    _pause_menu.opened.connect(_on_pause_menu_opened)
    _pause_menu.closed.connect(_on_pause_menu_closed)
    _pause_menu.quit_to_menu_requested.connect(_return_to_menu)
    $CanvasLayer.add_child(_pause_menu)


func _open_pause_menu() -> void:
    if not _world_ready or _pause_menu == null:
        return
    if _weather_menu_open:
        _set_weather_menu_open(false)
    _pause_menu.open_pause()


func _on_pause_menu_opened() -> void:
    player.mouse_capture_paused = true
    if weather_panel != null:
        weather_panel.visible = false
    if weather_menu_button != null:
        weather_menu_button.visible = false


func _on_pause_menu_closed() -> void:
    if not _world_ready:
        return
    player.mouse_capture_paused = false
    if weather_menu_button != null:
        weather_menu_button.visible = false


func _return_to_menu() -> void:
    get_tree().paused = false
    GameSettings.has_requested_seed = false
    var change_error: Error = get_tree().change_scene_to_file("res://scenes/menu.tscn")
    if change_error != OK:
        push_error("Не удалось вернуться в главное меню: " + error_string(change_error))
