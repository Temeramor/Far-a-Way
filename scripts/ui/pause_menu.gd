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

var _main_panel: PanelContainer
var _settings_panel: PanelContainer
var _mouse_mode_before_pause: int = Input.MOUSE_MODE_VISIBLE


func configure(_voxel_world: Node, _world_controller: Node = null) -> void:
    # Keep the scene setup API. Graphics now use the fixed automatic profile.
    pass


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
    settings_stack.add_theme_constant_override("separation", 10)
    _settings_panel.add_child(settings_stack)

    var settings_title := Label.new()
    settings_title.text = "НАСТРОЙКИ"
    settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    settings_title.add_theme_font_size_override("font_size", 22)
    settings_title.add_theme_color_override("font_color", COLOR_GOLD)
    settings_title.add_theme_color_override("font_outline_color", Color("#211812"))
    settings_title.add_theme_constant_override("outline_size", 1)
    settings_stack.add_child(settings_title)
    settings_stack.add_child(_make_divider())

    var settings_notice := _make_label(
        "Графика настраивается автоматически для стабильной работы. "
        + "Детализация и тени рельефа упрощаются с расстоянием; тяжёлое MSAA отключено.",
        false
    )
    settings_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    settings_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    settings_notice.custom_minimum_size = Vector2(0.0, 110.0)
    settings_stack.add_child(settings_notice)
    settings_stack.add_child(_make_divider())

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


func _fit_to_viewport() -> void:
    if _main_panel == null or _settings_panel == null:
        return
    var view_size: Vector2 = get_viewport().get_visible_rect().size
    var panel_width: float = minf(560.0, maxf(250.0, view_size.x - 24.0))
    var panel_height: float = minf(680.0, maxf(300.0, view_size.y - 24.0))
    _main_panel.custom_minimum_size = Vector2(minf(panel_width, 430.0), 0.0)
    _settings_panel.custom_minimum_size = Vector2(panel_width, panel_height)


func _show_main_page() -> void:
    _main_panel.visible = true
    _settings_panel.visible = false


func _show_settings_page() -> void:
    _main_panel.visible = false
    _settings_panel.visible = true


func _quit_to_menu() -> void:
    visible = false
    get_tree().paused = false
    quit_to_menu_requested.emit()
