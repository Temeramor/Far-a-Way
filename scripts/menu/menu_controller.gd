extends Control
class_name MenuController

const WORLD_SCENE_PATH: String = "res://scenes/world.tscn"
const COLOR_WOOD: Color = Color("#35271F")
const COLOR_GOLD: Color = Color("#D9A441")
const COLOR_TEAL: Color = Color("#244C4B")
const COLOR_PARCHMENT: Color = Color("#E8D7B3")
const COLOR_GREEN: Color = Color("#6D8B45")

@onready var panel: PanelContainer = $Center/Panel
@onready var main_view: VBoxContainer = $Center/Panel/Margin/Stack/MainView
@onready var new_game_view: VBoxContainer = $Center/Panel/Margin/Stack/NewGameView
@onready var settings_view: VBoxContainer = $Center/Panel/Margin/Stack/SettingsView
@onready var seed_edit: LineEdit = $Center/Panel/Margin/Stack/NewGameView/SeedEdit
@onready var start_button: Button = $Center/Panel/Margin/Stack/NewGameView/StartButton
@onready var status_label: Label = $Center/Panel/Margin/Stack/StatusLabel
@onready var speed_slider: HSlider = $Center/Panel/Margin/Stack/SettingsView/SpeedRow/SpeedSlider
@onready var speed_value: Label = $Center/Panel/Margin/Stack/SettingsView/SpeedRow/SpeedValue
@onready var fov_slider: HSlider = $Center/Panel/Margin/Stack/SettingsView/FovRow/FovSlider
@onready var fov_value: Label = $Center/Panel/Margin/Stack/SettingsView/FovRow/FovValue
@onready var corner_badge: PanelContainer = $CornerBadge

var _launching_world: bool = false


func _ready() -> void:
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    GameSettings.load_settings()
    _apply_visual_theme()
    _adapt_to_viewport()
    get_viewport().size_changed.connect(_adapt_to_viewport)

    $Center/Panel/Margin/Stack/MainView/NewGameButton.pressed.connect(_show_new_game)
    $Center/Panel/Margin/Stack/MainView/SettingsButton.pressed.connect(_show_settings)
    $Center/Panel/Margin/Stack/MainView/ExitButton.pressed.connect(_exit_game)
    start_button.pressed.connect(_start_game)
    seed_edit.text_submitted.connect(_on_seed_submitted)
    $Center/Panel/Margin/Stack/NewGameView/BackButton.pressed.connect(_show_main)

    speed_slider.min_value = GameSettings.MIN_FLIGHT_SPEED_MULTIPLIER
    speed_slider.max_value = GameSettings.MAX_FLIGHT_SPEED_MULTIPLIER
    speed_slider.step = 1.0
    fov_slider.min_value = GameSettings.MIN_FLIGHT_FOV
    fov_slider.max_value = GameSettings.MAX_FLIGHT_FOV
    fov_slider.step = 1.0
    speed_slider.value_changed.connect(_refresh_setting_values)
    fov_slider.value_changed.connect(_refresh_setting_values)
    $Center/Panel/Margin/Stack/SettingsView/SettingsButtons/SaveButton.pressed.connect(_save_settings)
    $Center/Panel/Margin/Stack/SettingsView/SettingsButtons/CancelButton.pressed.connect(_cancel_settings)
    $Center/Panel/Margin/Stack/SettingsView/SettingsButtons/DefaultsButton.pressed.connect(_restore_defaults_in_ui)

    seed_edit.max_length = 0
    seed_edit.text = "1337"
    _sync_settings_to_ui()
    _show_main()


func _adapt_to_viewport() -> void:
    var view_size: Vector2 = get_viewport().get_visible_rect().size
    if view_size.x <= 0.0 or view_size.y <= 0.0:
        return

    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    var panel_width: float
    var panel_height: float
    if view_size.x < 720.0:
        panel_width = maxf(280.0, view_size.x - 24.0)
        panel_height = minf(view_size.y - 24.0, 900.0)
    else:
        panel_width = clampf(view_size.x * 0.36, 420.0, 520.0)
        panel_height = clampf(view_size.y * 0.78, 500.0, 820.0)
        if view_size.y < 620.0:
            panel_height = view_size.y - 24.0
    panel.custom_minimum_size = Vector2(panel_width, panel_height)
    panel.position = Vector2(maxf(12.0, view_size.x * 0.03), maxf(12.0, (view_size.y - panel_height) * 0.5))
    panel.size = Vector2(panel_width, panel_height)

    var logo := $Center/Panel/Margin/Stack/Logo as TextureRect
    if logo.texture != null and logo.texture.get_width() > 0:
        var column_width: float = maxf(1.0, panel_width - 46.0)
        var logo_height: float = column_width * float(logo.texture.get_height()) / float(logo.texture.get_width())
        logo.custom_minimum_size = Vector2(0.0, logo_height)

    corner_badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
    if view_size.x >= 900.0 and view_size.y >= 500.0:
        corner_badge.visible = true
        var badge_width: float = minf(260.0, view_size.x * 0.30)
        var badge_height: float = 64.0
        var badge_margin_x: float = maxf(22.0, view_size.x * 0.03)
        var badge_margin_y: float = maxf(18.0, view_size.y * 0.035)
        corner_badge.position = Vector2(view_size.x - badge_width - badge_margin_x, view_size.y - badge_height - badge_margin_y)
        corner_badge.size = Vector2(badge_width, badge_height)
    else:
        corner_badge.visible = false


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
    # The button texture has 16 px carved corners and a moss-covered top rim.
    # Preserve the ornaments as nine-patch corners while the center tiles cleanly.
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


func _apply_visual_theme() -> void:
    # The bundled BMFont is a small custom bitmap rendering with Cyrillic glyphs.
    var pixel_font := load("res://assets/ui/pixel_ui.fnt") as Font
    var menu_theme := Theme.new()
    if pixel_font != null:
        menu_theme.default_font = pixel_font
        menu_theme.default_font_size = 16
    else:
        push_warning("Не удалось загрузить пиксельный шрифт меню; используется резервный системный шрифт.")
        menu_theme.default_font = ThemeDB.fallback_font
        menu_theme.default_font_size = 16
    theme = menu_theme

    var transparent_panel := StyleBoxFlat.new()
    transparent_panel.bg_color = Color(0.0, 0.0, 0.0, 0.0)
    transparent_panel.border_color = Color(0.0, 0.0, 0.0, 0.0)
    transparent_panel.content_margin_left = 23.0
    transparent_panel.content_margin_top = 19.0
    transparent_panel.content_margin_right = 23.0
    transparent_panel.content_margin_bottom = 19.0
    panel.add_theme_stylebox_override("panel", transparent_panel)
    panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var badge := _style_texture("res://assets/ui/badge_texture.png", 7.0, 15.0, 8.0, 15.0, 8.0)
    corner_badge.add_theme_stylebox_override("panel", badge)
    corner_badge.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var primary := _button_style_texture("res://assets/ui/button_primary.png")
    var secondary := _button_style_texture("res://assets/ui/button_secondary.png")
    var hovered := _button_style_texture("res://assets/ui/button_hover.png")
    var pressed := _button_style_texture("res://assets/ui/button_pressed.png")
    var primary_paths: Array[NodePath] = [
        ^"Center/Panel/Margin/Stack/MainView/NewGameButton",
        ^"Center/Panel/Margin/Stack/NewGameView/StartButton",
        ^"Center/Panel/Margin/Stack/SettingsView/SettingsButtons/SaveButton"
    ]
    var button_paths: Array[NodePath] = [
        ^"Center/Panel/Margin/Stack/MainView/NewGameButton",
        ^"Center/Panel/Margin/Stack/MainView/SettingsButton",
        ^"Center/Panel/Margin/Stack/MainView/ExitButton",
        ^"Center/Panel/Margin/Stack/NewGameView/StartButton",
        ^"Center/Panel/Margin/Stack/NewGameView/BackButton",
        ^"Center/Panel/Margin/Stack/SettingsView/SettingsButtons/SaveButton",
        ^"Center/Panel/Margin/Stack/SettingsView/SettingsButtons/CancelButton",
        ^"Center/Panel/Margin/Stack/SettingsView/SettingsButtons/DefaultsButton"
    ]
    for button_path in button_paths:
        var button := get_node(button_path) as Button
        var is_primary: bool = primary_paths.has(button_path)
        button.add_theme_stylebox_override("normal", primary if is_primary else secondary)
        button.add_theme_stylebox_override("hover", hovered)
        button.add_theme_stylebox_override("pressed", pressed)
        button.add_theme_stylebox_override("focus", hovered)
        button.add_theme_color_override("font_color", COLOR_WOOD if is_primary else COLOR_PARCHMENT)
        button.add_theme_color_override("font_hover_color", COLOR_WOOD)
        button.add_theme_color_override("font_pressed_color", COLOR_PARCHMENT)
        button.add_theme_color_override("font_focus_color", COLOR_WOOD)
        button.add_theme_font_size_override("font_size", 20 if button_path in primary_paths else 17)
        button.custom_minimum_size = Vector2(0.0, 52.0 if button_path in primary_paths else 48.0)
        button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var stack := $Center/Panel/Margin/Stack as VBoxContainer
    stack.add_theme_constant_override("separation", 8)
    stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
    for view_name in ["MainView", "NewGameView", "SettingsView"]:
        var view_path: NodePath = NodePath("Center/Panel/Margin/Stack/" + view_name)
        var view := get_node_or_null(view_path) as BoxContainer
        if view != null:
            view.add_theme_constant_override("separation", 9)
    ($Center/Panel/Margin/Stack/SettingsView/SettingsButtons as VBoxContainer).add_theme_constant_override("separation", 7)

    var logo := $Center/Panel/Margin/Stack/Logo as TextureRect
    logo.custom_minimum_size = Vector2.ZERO
    logo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    # Height will be set from the available button-column width, preserving the logo ratio.
    logo.stretch_mode = TextureRect.STRETCH_SCALE
    logo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    var divider := $Center/Panel/Margin/Stack/Divider as TextureRect
    divider.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var badge_stack := $CornerBadge/Margin/Stack as VBoxContainer
    badge_stack.add_theme_constant_override("separation", 0)
    badge_stack.alignment = BoxContainer.ALIGNMENT_CENTER
    var badge_text := $CornerBadge/Margin/Stack/BadgeText as Label
    badge_text.add_theme_font_size_override("font_size", 16)
    badge_text.add_theme_color_override("font_color", COLOR_PARCHMENT)
    badge_text.add_theme_color_override("font_outline_color", Color("#182120"))
    badge_text.add_theme_constant_override("outline_size", 1)
    badge_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    badge_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    var version_text := $CornerBadge/Margin/Stack/VersionText as Label
    version_text.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
    version_text.add_theme_font_size_override("font_size", 12)
    version_text.add_theme_color_override("font_color", COLOR_GOLD)
    version_text.add_theme_color_override("font_outline_color", Color("#182120"))
    version_text.add_theme_constant_override("outline_size", 1)
    version_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    version_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    for label_path in [
        "Center/Panel/Margin/Stack/NewGameView/SeedCaption",
        "Center/Panel/Margin/Stack/SettingsView/SpeedCaption",
        "Center/Panel/Margin/Stack/SettingsView/FovCaption"
    ]:
        var caption := get_node(label_path) as Label
        caption.add_theme_font_size_override("font_size", 16)
        caption.add_theme_color_override("font_color", COLOR_PARCHMENT)

    seed_edit.custom_minimum_size = Vector2(0.0, 44.0)
    seed_edit.add_theme_font_size_override("font_size", 14)
    seed_edit.add_theme_stylebox_override("normal", _style_texture("res://assets/ui/input_frame.png", 5.0, 12.0, 6.0, 12.0, 6.0))
    seed_edit.add_theme_stylebox_override("focus", _style_texture("res://assets/ui/input_focus.png", 5.0, 12.0, 6.0, 12.0, 6.0))
    seed_edit.add_theme_color_override("font_color", COLOR_PARCHMENT)
    seed_edit.add_theme_color_override("font_placeholder_color", Color("#B8A986"))
    seed_edit.add_theme_color_override("caret_color", COLOR_GOLD)
    seed_edit.add_theme_color_override("selection_color", Color(0.36, 0.29, 0.12, 0.85))
    seed_edit.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    # Sliders match the gold-and-teal controls without using a large, smooth gradient.
    var slider_track := StyleBoxFlat.new()
    slider_track.bg_color = Color("#1B3432")
    slider_track.set_corner_radius_all(0)
    slider_track.content_margin_top = 3.0
    slider_track.content_margin_bottom = 3.0
    var slider_fill := StyleBoxFlat.new()
    slider_fill.bg_color = COLOR_GREEN
    slider_fill.set_corner_radius_all(0)
    var grabber := load("res://assets/ui/slider_grabber.png") as Texture2D
    for slider in [speed_slider, fov_slider]:
        slider.add_theme_stylebox_override("slider", slider_track)
        slider.add_theme_stylebox_override("grabber_area", slider_track)
        slider.add_theme_stylebox_override("grabber_area_highlight", slider_fill)
        slider.add_theme_icon_override("grabber", grabber)
        slider.add_theme_icon_override("grabber_highlight", grabber)
        slider.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    for value_label in [speed_value, fov_value]:
        value_label.add_theme_font_size_override("font_size", 16)
        value_label.add_theme_color_override("font_color", COLOR_GOLD)
        value_label.custom_minimum_size = Vector2(52.0, 0.0)

    status_label.add_theme_color_override("font_color", COLOR_GOLD)
    status_label.add_theme_font_size_override("font_size", 12)
    status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _show_main() -> void:
    main_view.visible = true
    new_game_view.visible = false
    settings_view.visible = false
    status_label.visible = false
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _show_new_game() -> void:
    main_view.visible = false
    new_game_view.visible = true
    settings_view.visible = false
    status_label.visible = false
    start_button.disabled = false
    seed_edit.editable = true
    seed_edit.grab_focus()
    seed_edit.select_all()


func _show_settings() -> void:
    _sync_settings_to_ui()
    main_view.visible = false
    new_game_view.visible = false
    settings_view.visible = true
    status_label.visible = false


func _sync_settings_to_ui() -> void:
    speed_slider.set_value_no_signal(GameSettings.flight_speed_multiplier)
    fov_slider.set_value_no_signal(GameSettings.flight_fov)
    _refresh_setting_values()


func _refresh_setting_values(_changed_value: float = 0.0) -> void:
    speed_value.text = "×%d" % int(roundi(speed_slider.value))
    fov_value.text = "%d°" % int(roundi(fov_slider.value))


func _restore_defaults_in_ui() -> void:
    speed_slider.value = GameSettings.DEFAULT_FLIGHT_SPEED_MULTIPLIER
    fov_slider.value = GameSettings.DEFAULT_FLIGHT_FOV
    _refresh_setting_values()


func _save_settings() -> void:
    var saved: bool = GameSettings.save_settings(speed_slider.value, fov_slider.value)
    if not saved:
        status_label.text = "Не удалось сохранить настройки. Проверьте доступ к папке пользовательских данных."
        status_label.visible = true
        return
    _show_main()


func _cancel_settings() -> void:
    GameSettings.load_settings()
    _sync_settings_to_ui()
    _show_main()


func _exit_game() -> void:
    get_tree().quit()


func _on_seed_submitted(_submitted_text: String) -> void:
    _start_game()


func _start_game() -> void:
    if _launching_world:
        return
    _launching_world = true
    start_button.disabled = true
    seed_edit.editable = false

    # Preserve arbitrary input as a deterministic integer key for noise.
    var seed_value: int = _seed_from_text(seed_edit.text)
    GameSettings.request_new_game(seed_value)
    _show_world_loading_overlay(seed_value)

    # Loading the world scene (and all its dependencies) synchronously used to
    # block the menu before the in-world loading screen could be displayed.
    # Threaded loading keeps this menu-owned overlay responsive during that phase.
    var request_error: Error = ResourceLoader.load_threaded_request(WORLD_SCENE_PATH, "PackedScene", true)
    if request_error != OK:
        _abort_world_launch("Не удалось запустить загрузку сцены: " + error_string(request_error))
        return

    await get_tree().process_frame
    var load_progress: Array[float] = []
    var load_status: ResourceLoader.ThreadLoadStatus = ResourceLoader.load_threaded_get_status(WORLD_SCENE_PATH, load_progress)
    while load_status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
        var ratio: float = load_progress[0] if not load_progress.is_empty() else 0.0
        _set_world_loading_progress(0.04 + ratio * 0.26, "Загружаем сцену мира и её ресурсы…")
        await get_tree().process_frame
        load_status = ResourceLoader.load_threaded_get_status(WORLD_SCENE_PATH, load_progress)

    if load_status != ResourceLoader.THREAD_LOAD_LOADED:
        _abort_world_launch("Не удалось загрузить сцену мира.")
        return

    _set_world_loading_progress(0.32, "Сцена загружена. Подготавливаем генерацию острова…")
    await get_tree().process_frame
    var packed_world: PackedScene = ResourceLoader.load_threaded_get(WORLD_SCENE_PATH) as PackedScene
    if packed_world == null:
        _abort_world_launch("Загруженный ресурс мира имеет неверный формат.")
        return

    var change_error: Error = get_tree().change_scene_to_packed(packed_world)
    if change_error != OK:
        _abort_world_launch("Не удалось открыть сцену мира: " + error_string(change_error))


func _show_world_loading_overlay(seed_value: int) -> void:
    var overlay := ColorRect.new()
    overlay.name = "WorldLoadingOverlay"
    overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.color = Color(0.018, 0.035, 0.031, 0.96)
    overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    overlay.z_index = 100
    add_child(overlay)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.add_child(center)

    var panel_loading := PanelContainer.new()
    panel_loading.custom_minimum_size = Vector2(460.0, 190.0)
    center.add_child(panel_loading)
    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color("#18302F")
    panel_style.border_color = COLOR_GOLD
    panel_style.set_border_width_all(2)
    panel_style.set_corner_radius_all(0)
    panel_style.content_margin_left = 24.0
    panel_style.content_margin_right = 24.0
    panel_style.content_margin_top = 22.0
    panel_style.content_margin_bottom = 22.0
    panel_loading.add_theme_stylebox_override("panel", panel_style)

    var stack := VBoxContainer.new()
    stack.add_theme_constant_override("separation", 12)
    panel_loading.add_child(stack)

    var title := Label.new()
    title.text = "ПОДГОТОВКА МИРА"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 21)
    title.add_theme_color_override("font_color", COLOR_GOLD)
    stack.add_child(title)

    var message := Label.new()
    message.name = "LoadingMessage"
    message.text = "Сид мира: %d — подготавливаем ресурсы…" % seed_value
    message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    message.add_theme_color_override("font_color", COLOR_PARCHMENT)
    message.add_theme_font_size_override("font_size", 14)
    stack.add_child(message)

    var progress := ProgressBar.new()
    progress.name = "LoadingProgress"
    progress.min_value = 0.0
    progress.max_value = 100.0
    progress.value = 4.0
    progress.custom_minimum_size = Vector2(0.0, 18.0)
    stack.add_child(progress)


func _set_world_loading_progress(value: float, message: String) -> void:
    var overlay := get_node_or_null("WorldLoadingOverlay") as ColorRect
    if overlay == null:
        return
    var label := overlay.get_node_or_null("Center/PanelContainer/VBoxContainer/LoadingMessage") as Label
    var bar := overlay.get_node_or_null("Center/PanelContainer/VBoxContainer/LoadingProgress") as ProgressBar
    if label != null:
        label.text = message
    if bar != null:
        bar.value = clampf(value, 0.0, 1.0) * 100.0


func _abort_world_launch(message: String) -> void:
    GameSettings.has_requested_seed = false
    _launching_world = false
    start_button.disabled = false
    seed_edit.editable = true
    var overlay := get_node_or_null("WorldLoadingOverlay")
    if overlay != null:
        overlay.queue_free()
    status_label.text = message
    status_label.visible = true


func _seed_from_text(value: String) -> int:
    if value.is_valid_int() and value.length() <= 18:
        return int(value)
    var bytes: PackedByteArray = value.to_utf8_buffer()
    if bytes.is_empty():
        return 0
    var hash_value: int = 2166136261
    const MODULUS: int = 2147483647
    for byte_value in bytes:
        hash_value = int((hash_value * 16777619 + int(byte_value) + 97) % MODULUS)
    return hash_value
