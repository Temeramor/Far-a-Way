extends "res://scripts/world/world_controller/world_controller_state.gd"

func set_lod_target_pixels(target_pixels: float, persist: bool = true) -> void:
    GameSettings.update_lod_target_pixels(target_pixels, persist)
    voxel_world.set_lod_target_pixels(GameSettings.lod_target_pixels)

func _apply_view_distance_environment(distance_m: float) -> void:
    var safe_distance: float = clampf(distance_m, GameSettings.MIN_VIEW_DISTANCE_M, GameSettings.MAX_VIEW_DISTANCE_M)
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
    var sun_light := sky_system.get_node_or_null("SunLight") as DirectionalLight3D
    if sun_light != null:
        sun_light.shadow_enabled = true
        sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
        sun_light.directional_shadow_blend_splits = true
        sun_light.directional_shadow_max_distance = minf(safe_distance, 640.0)
        sun_light.directional_shadow_fade_start = 0.90

    # Moon shadows duplicate a second directional shadow map and add little during night scenes.
    var moon_light := sky_system.get_node_or_null("MoonLight") as DirectionalLight3D
    if moon_light != null:
        moon_light.shadow_enabled = false

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
    sky_system.set("update_interval", 0.25)
    sky_system.set("current_time", 12.0)
    sky_dome.set("process_method", 1) # Process, cloud movement at render rate.

func _on_generation_started(seed_value: int) -> void:
    loading_screen.set_progress(0.0, "Сид мира: %d — создаём рельеф" % seed_value)
    terrain.call("set_weather", _weather_mode)

func _on_generation_progress(_seed_value: int, progress: float, message: String) -> void:
    loading_screen.set_progress(progress, message)

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
    if voxel_world != null:
        voxel_world.refresh_lod_boundaries()
    if flight_status_label == null:
        return
    flight_status_label.text = "РЕЖИМ ПОЛЁТА — скорость ×%.0f" % player.flight_speed_multiplier
    flight_status_label.visible = enabled
    if flight_status_backdrop != null:
        flight_status_backdrop.visible = enabled

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

    var surface_scatter := voxel_world.get_node_or_null("VoxelSurfaceScatter") as VoxelSurfaceScatter
    if surface_scatter != null:
        surface_scatter.set_weather_mode(mode)

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

func _update_time_button_styles() -> void:
    if time_selector != null:
        time_selector.select(_time_mode)

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
