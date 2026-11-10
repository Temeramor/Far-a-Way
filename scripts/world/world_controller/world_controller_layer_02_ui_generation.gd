extends "res://scripts/world/world_controller/world_controller_layer_01_environment.gd"

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

func set_view_distance_m(distance_m: float, persist: bool = true) -> void:
    var safe_distance: float = snappedf(clampf(distance_m, GameSettings.MIN_VIEW_DISTANCE_M, GameSettings.MAX_VIEW_DISTANCE_M), 256.0)
    GameSettings.update_view_distance_m(safe_distance, persist)
    voxel_world.set_render_distance_m(GameSettings.view_distance_m)
    _apply_view_distance_environment(GameSettings.view_distance_m)

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
    loading_screen.set_progress(0.015, "Сцена мира загружена. Инициализируем окружение, генератор острова и систему чанков…")
    # A deferred call alone does not guarantee that the visible loading screen
    # has been drawn. Yield one frame before any potentially expensive startup work.
    await get_tree().process_frame
    loading_screen.set_progress(0.025, "Подключаем генератор рельефа и запускаем подготовку мира…")
    terrain.generate(seed_value)

func _on_generation_finished(_seed_value: int) -> void:
    # VoxelWorld has already selected a safe non-central spawn, verified the
    # LOD0 collision across the capsule footprint, and placed the player above it.
    # Never overwrite that position with the legacy (0, 0) terrain origin.
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

func _on_weather_button_pressed(mode: int) -> void:
    var next_mode: int = clampi(mode, WEATHER_CLEAR, WEATHER_OVERCAST)
    if next_mode != _weather_mode:
        _weather_mode = next_mode
        terrain.call("set_weather", _weather_mode)
        _apply_weather(_weather_mode, true)
    _update_weather_button_styles()

func _on_time_preset_pressed(preset: int) -> void:
    var safe_preset: int = clampi(preset, TIME_DAWN, TIME_NIGHT)
    sky_system.set("current_time", TIME_PRESETS[safe_preset])
    _time_mode = safe_preset
    _update_time_button_styles()
