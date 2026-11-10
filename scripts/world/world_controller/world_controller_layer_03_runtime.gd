extends "res://scripts/world/world_controller/world_controller_layer_02_ui_generation.gd"

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

func _toggle_weather_menu() -> void:
    _set_weather_menu_open(not _weather_menu_open)

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

func _begin_pending_game_if_requested() -> void:
    if GameSettings.has_requested_seed:
        var pending_seed: int = GameSettings.requested_seed
        GameSettings.has_requested_seed = false
        begin_generation(pending_seed)

func _on_weather_selection_changed(index: int) -> void:
    if weather_selector == null:
        return
    _on_weather_button_pressed(weather_selector.get_item_id(index))

func _on_time_selection_changed(index: int) -> void:
    if time_selector == null:
        return
    _on_time_preset_pressed(time_selector.get_item_id(index))

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
