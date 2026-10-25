extends Control
class_name PauseMenu

signal opened
signal closed
signal quit_to_menu_requested

const COLOR_BG: Color = Color("#172321")
const COLOR_PANEL: Color = Color("#263735")
const COLOR_WOOD: Color = Color("#35271F")
const COLOR_GOLD: Color = Color("#D9A441")
const COLOR_TEAL: Color = Color("#244C4B")
const COLOR_GREEN: Color = Color("#6D8B45")
const COLOR_TEXT: Color = Color("#E8D7B3")
const COLOR_MUTED: Color = Color("#B8A986")

var _voxel_world: Node
var _main_panel: PanelContainer
var _settings_panel: PanelContainer
var _settings_scroll: ScrollContainer

var _msaa_selector: OptionButton
var _screen_aa_selector: OptionButton
var _voxel_filter_selector: OptionButton
var _crack_filter_selector: OptionButton
var _procedural_mip_toggle: CheckButton
var _mouse_mode_before_pause: int = Input.MOUSE_MODE_VISIBLE


func configure(voxel_world: Node) -> void:
    _voxel_world = voxel_world


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    mouse_filter = Control.MOUSE_FILTER_STOP
    _build_ui()
    visible = false
    get_viewport().size_changed.connect(_fit_to_viewport)
    _fit_to_viewport()


func open_pause() -> void:
    if visible:
        return
    _show_main_page()
    _mouse_mode_before_pause = Input.mouse_mode
    visible = true
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().paused = true
    opened.emit()


func close_pause() -> void:
    if not visible:
        return
    visible = false
    get_tree().paused = false
    if OS.has_feature("android"):
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    else:
        Input.mouse_mode = _mouse_mode_before_pause
    closed.emit()


func _input(event: InputEvent) -> void:
    if not visible:
        return
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
        if _settings_panel.visible:
            _show_main_page()
        else:
            close_pause()
        get_viewport().set_input_as_handled()


func _build_ui() -> void:
    var pixel_font := load("res://assets/ui/pixel_ui.fnt") as Font
    var pause_theme := Theme.new()
    pause_theme.default_font = pixel_font if pixel_font != null else ThemeDB.fallback_font
    pause_theme.default_font_size = 16
    theme = pause_theme

    var shade := ColorRect.new()
    shade.name = "PauseShade"
    shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    shade.color = Color(0.012, 0.022, 0.020, 0.84)
    shade.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(shade)

    var center := CenterContainer.new()
    center.name = "PanelCenter"
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(center)

    _main_panel = _make_panel("PausePanel")
    center.add_child(_main_panel)
    var main_stack := VBoxContainer.new()
    main_stack.add_theme_constant_override("separation", 12)
    _main_panel.add_child(main_stack)

    var title := Label.new()
    title.text = "ПАУЗА"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 34)
    title.add_theme_color_override("font_color", COLOR_GOLD)
    title.add_theme_color_override("font_outline_color", Color("#211812"))
    title.add_theme_constant_override("outline_size", 2)
    main_stack.add_child(title)
    main_stack.add_child(_make_divider())

    var resume_button := _make_button("Продолжить", true)
    resume_button.pressed.connect(close_pause)
    main_stack.add_child(resume_button)

    var settings_button := _make_button("Настройки")
    settings_button.pressed.connect(_show_settings_page)
    main_stack.add_child(settings_button)

    var quit_button := _make_button("Выйти в меню")
    quit_button.pressed.connect(_quit_to_menu)
    main_stack.add_child(quit_button)

    _settings_panel = _make_panel("GraphicsSettingsPanel")
    center.add_child(_settings_panel)

    var settings_stack := VBoxContainer.new()
    settings_stack.add_theme_constant_override("separation", 8)
    _settings_panel.add_child(settings_stack)

    var settings_title := Label.new()
    settings_title.text = "НАСТРОЙКИ ГРАФИКИ"
    settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    settings_title.add_theme_font_size_override("font_size", 22)
    settings_title.add_theme_color_override("font_color", COLOR_GOLD)
    settings_title.add_theme_color_override("font_outline_color", Color("#211812"))
    settings_title.add_theme_constant_override("outline_size", 1)
    settings_stack.add_child(settings_title)
    settings_stack.add_child(_make_divider())

    _settings_scroll = ScrollContainer.new()
    _settings_scroll.name = "SettingsScroll"
    _settings_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    settings_stack.add_child(_settings_scroll)

    var settings_content := VBoxContainer.new()
    settings_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    settings_content.add_theme_constant_override("separation", 8)
    _settings_scroll.add_child(settings_content)

    var filter_heading := _make_label("ФИЛЬТРАЦИЯ ДАЛЬНЕЙ ПОВЕРХНОСТИ", true)
    settings_content.add_child(filter_heading)
    var filter_description := _make_label(
        "Сравни способы устранения ряби. MSAA сглаживает геометрию, экранное AA обрабатывает кадр, а фильтры ниже усредняют процедурные цвета и трещины вдали.",
        false
    )
    filter_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_content.add_child(filter_description)

    _msaa_selector = _make_option_row(settings_content, "Сглаживание 3D (MSAA)",
        ["Выкл.", "2×", "4×", "8×"], GameSettings.msaa_mode)
    _msaa_selector.item_selected.connect(_on_msaa_selected)

    _screen_aa_selector = _make_option_row(settings_content, "Экранное AA",
        ["Выкл.", "FXAA", "SMAA"], GameSettings.screen_space_aa_mode)
    _screen_aa_selector.item_selected.connect(_on_screen_aa_selected)

    _voxel_filter_selector = _make_option_row(settings_content, "Фильтр цветов",
        ["Без фильтра", "0,5×", "1×", "1,5×", "2×"], GameSettings.voxel_detail_filter_mode)
    _voxel_filter_selector.item_selected.connect(_on_voxel_filter_selected)

    _crack_filter_selector = _make_option_row(settings_content, "Фильтр трещин",
        ["Без фильтра", "0,5×", "1×", "2×"], GameSettings.rock_crack_filter_mode)
    _crack_filter_selector.item_selected.connect(_on_crack_filter_selected)

    _procedural_mip_toggle = _make_check_button(
        "Мип-подобная фильтрация шума", GameSettings.procedural_mip_filter_enabled
    )
    _procedural_mip_toggle.toggled.connect(_on_procedural_mip_toggled)
    settings_content.add_child(_procedural_mip_toggle)

    var hint := _make_label(
        "Процедурные цвета создаются шейдером, а не mipmap-текстурой. Переключатель включает/выключает усреднение субпиксельных деталей — аналог mip-фильтра для сравнения. Настройки применяются сразу и сохраняются.",
        false
    )
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_content.add_child(hint)

    var settings_buttons := HBoxContainer.new()
    settings_buttons.add_theme_constant_override("separation", 8)
    settings_stack.add_child(settings_buttons)

    var back_button := _make_button("Назад")
    back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    back_button.pressed.connect(_show_main_page)
    settings_buttons.add_child(back_button)

    var done_button := _make_button("Готово", true)
    done_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    done_button.pressed.connect(_show_main_page)
    settings_buttons.add_child(done_button)

    _sync_graphics_controls()
    _show_main_page()


func _style_texture(path: String, border: float, content_left: float, content_top: float, content_right: float, content_bottom: float) -> StyleBoxTexture:
    var style := StyleBoxTexture.new()
    style.texture = load(path) as Texture2D
    style.texture_margin_left = border
    style.texture_margin_top = border
    style.texture_margin_right = border
    style.texture_margin_bottom = border
    style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    style.content_margin_left = content_left
    style.content_margin_top = content_top
    style.content_margin_right = content_right
    style.content_margin_bottom = content_bottom
    return style


func _button_style_texture(path: String) -> StyleBoxTexture:
    var style := StyleBoxTexture.new()
    style.texture = load(path) as Texture2D
    style.texture_margin_left = 16.0
    style.texture_margin_right = 16.0
    style.texture_margin_top = 16.0
    style.texture_margin_bottom = 12.0
    style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    style.content_margin_left = 22.0
    style.content_margin_right = 22.0
    style.content_margin_top = 13.0
    style.content_margin_bottom = 10.0
    return style


func _make_divider() -> TextureRect:
    var divider := TextureRect.new()
    divider.custom_minimum_size = Vector2(0.0, 16.0)
    divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
    divider.texture = load("res://assets/ui/divider.png") as Texture2D
    divider.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    divider.stretch_mode = TextureRect.STRETCH_SCALE
    divider.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    return divider


func _make_panel(panel_name: String) -> PanelContainer:
    var panel := PanelContainer.new()
    panel.name = panel_name
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    panel.add_theme_stylebox_override(
        "panel",
        _style_texture("res://assets/ui/panel_texture.png", 12.0, 23.0, 19.0, 23.0, 19.0)
    )
    panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    return panel


func _make_label(text_value: String, highlighted: bool) -> Label:
    var label := Label.new()
    label.text = text_value
    label.add_theme_font_size_override("font_size", 15 if highlighted else 13)
    label.add_theme_color_override("font_color", COLOR_GOLD if highlighted else COLOR_TEXT)
    return label


func _make_button(caption: String, primary: bool = false) -> Button:
    var button := Button.new()
    button.text = caption
    button.custom_minimum_size = Vector2(0.0, 52.0 if primary else 48.0)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.focus_mode = Control.FOCUS_NONE
    var normal := _button_style_texture(
        "res://assets/ui/button_primary.png" if primary else "res://assets/ui/button_secondary.png"
    )
    var hover := _button_style_texture("res://assets/ui/button_hover.png")
    var pressed := _button_style_texture("res://assets/ui/button_pressed.png")
    button.add_theme_stylebox_override("normal", normal)
    button.add_theme_stylebox_override("hover", hover)
    button.add_theme_stylebox_override("pressed", pressed)
    button.add_theme_stylebox_override("focus", hover)
    button.add_theme_color_override("font_color", COLOR_WOOD if primary else COLOR_TEXT)
    button.add_theme_color_override("font_hover_color", COLOR_WOOD)
    button.add_theme_color_override("font_pressed_color", COLOR_TEXT)
    button.add_theme_color_override("font_focus_color", COLOR_WOOD)
    button.add_theme_font_size_override("font_size", 18 if primary else 16)
    button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    return button


func _make_option_row(parent: VBoxContainer, caption: String, options: Array, selected_index: int) -> OptionButton:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(row)
    var label := _make_label(caption, true)
    label.custom_minimum_size = Vector2(125.0, 0.0)
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    row.add_child(label)
    var selector := OptionButton.new()
    selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    for option_value in options:
        selector.add_item(str(option_value))
    selector.select(clampi(selected_index, 0, maxi(0, options.size() - 1)))
    _style_option_button(selector)
    row.add_child(selector)
    return selector


func _make_check_button(caption: String, checked: bool) -> CheckButton:
    var toggle := CheckButton.new()
    toggle.text = caption
    toggle.custom_minimum_size = Vector2(0.0, 42.0)
    toggle.button_pressed = checked
    _style_check_button(toggle)
    return toggle


func _style_option_button(selector: OptionButton) -> void:
    selector.add_theme_stylebox_override("normal", _button_style_texture("res://assets/ui/button_secondary.png"))
    selector.add_theme_stylebox_override("hover", _button_style_texture("res://assets/ui/button_hover.png"))
    selector.add_theme_stylebox_override("pressed", _button_style_texture("res://assets/ui/button_pressed.png"))
    selector.add_theme_stylebox_override("focus", _button_style_texture("res://assets/ui/button_hover.png"))
    selector.add_theme_color_override("font_color", COLOR_TEXT)
    selector.add_theme_color_override("font_hover_color", COLOR_GOLD)
    selector.add_theme_color_override("font_pressed_color", COLOR_TEXT)
    selector.add_theme_font_size_override("font_size", 14)
    selector.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    var popup := selector.get_popup()
    popup.add_theme_color_override("font_color", COLOR_TEXT)
    popup.add_theme_color_override("font_hover_color", COLOR_GOLD)
    popup.add_theme_stylebox_override("panel", _button_style_texture("res://assets/ui/button_secondary.png"))


func _style_check_button(toggle: CheckButton) -> void:
    toggle.add_theme_stylebox_override("normal", _button_style_texture("res://assets/ui/button_secondary.png"))
    toggle.add_theme_stylebox_override("hover", _button_style_texture("res://assets/ui/button_hover.png"))
    toggle.add_theme_stylebox_override("pressed", _button_style_texture("res://assets/ui/button_pressed.png"))
    toggle.add_theme_color_override("font_color", COLOR_TEXT)
    toggle.add_theme_color_override("font_hover_color", COLOR_GOLD)
    toggle.add_theme_color_override("font_pressed_color", COLOR_GOLD)
    toggle.add_theme_font_size_override("font_size", 14)
    toggle.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _fit_to_viewport() -> void:
    if _main_panel == null or _settings_panel == null:
        return
    var view_size: Vector2 = get_viewport().get_visible_rect().size
    var panel_width: float = minf(560.0, maxf(250.0, view_size.x - 24.0))
    var panel_height: float = minf(680.0, maxf(300.0, view_size.y - 24.0))
    _main_panel.custom_minimum_size = Vector2(minf(panel_width, 430.0), 0.0)
    _settings_panel.custom_minimum_size = Vector2(panel_width, panel_height)
    if _settings_scroll != null:
        _settings_scroll.custom_minimum_size = Vector2(0.0, maxf(140.0, panel_height - 180.0))


func _show_main_page() -> void:
    _main_panel.visible = true
    _settings_panel.visible = false


func _show_settings_page() -> void:
    _sync_graphics_controls()
    _main_panel.visible = false
    _settings_panel.visible = true


func _sync_graphics_controls() -> void:
    _msaa_selector.select(GameSettings.msaa_mode)
    _screen_aa_selector.select(GameSettings.screen_space_aa_mode)
    _voxel_filter_selector.select(GameSettings.voxel_detail_filter_mode)
    _crack_filter_selector.select(GameSettings.rock_crack_filter_mode)
    _procedural_mip_toggle.set_pressed_no_signal(GameSettings.procedural_mip_filter_enabled)


func _on_msaa_selected(_index: int) -> void:
    _apply_graphics_settings(true)


func _on_screen_aa_selected(_index: int) -> void:
    _apply_graphics_settings(true)


func _on_voxel_filter_selected(_index: int) -> void:
    _apply_graphics_settings(true)


func _on_crack_filter_selected(_index: int) -> void:
    _apply_graphics_settings(true)


func _on_procedural_mip_toggled(_enabled: bool) -> void:
    _apply_graphics_settings(true)


func _apply_graphics_settings(persist: bool) -> void:
    GameSettings.update_graphics_settings(
        _msaa_selector.selected,
        _screen_aa_selector.selected,
        _voxel_filter_selector.selected,
        _crack_filter_selector.selected,
        _procedural_mip_toggle.button_pressed,
        persist
    )
    if _voxel_world != null and is_instance_valid(_voxel_world):
        _voxel_world.call(
            "set_surface_filter_settings",
            GameSettings.get_voxel_detail_filter_multiplier(),
            GameSettings.get_rock_crack_filter_multiplier(),
            GameSettings.procedural_mip_filter_enabled
        )


func _quit_to_menu() -> void:
    visible = false
    get_tree().paused = false
    quit_to_menu_requested.emit()
