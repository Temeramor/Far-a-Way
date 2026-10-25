extends Control
class_name LoadingScreen

const COLOR_WOOD: Color = Color("#35271F")
const COLOR_GOLD: Color = Color("#D9A441")
const COLOR_PARCHMENT: Color = Color("#E8D7B3")
const COLOR_TEAL_DARK: Color = Color("#18302F")

@onready var message_label: Label = $Center/Panel/Margin/Stack/Message
@onready var progress_bar: ProgressBar = $Center/Panel/Margin/Stack/ProgressBar
@onready var percent_label: Label = $Center/Panel/Margin/Stack/Percent


func _ready() -> void:
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    var pixel_font := load("res://assets/ui/pixel_ui.fnt") as Font
    var loading_theme := Theme.new()
    if pixel_font != null:
        loading_theme.default_font = pixel_font
        loading_theme.default_font_size = 16
    else:
        loading_theme.default_font = ThemeDB.fallback_font
        loading_theme.default_font_size = 16
    theme = loading_theme

    var panel_style := StyleBoxTexture.new()
    panel_style.texture = load("res://assets/ui/panel_texture.png") as Texture2D
    panel_style.texture_margin_left = 12.0
    panel_style.texture_margin_top = 12.0
    panel_style.texture_margin_right = 12.0
    panel_style.texture_margin_bottom = 12.0
    panel_style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    panel_style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
    panel_style.content_margin_left = 24.0
    panel_style.content_margin_right = 24.0
    panel_style.content_margin_top = 20.0
    panel_style.content_margin_bottom = 20.0
    $Center/Panel.add_theme_stylebox_override("panel", panel_style)
    $Center/Panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var margin := $Center/Panel/Margin as MarginContainer
    margin.add_theme_constant_override("margin_left", 22)
    margin.add_theme_constant_override("margin_right", 22)
    margin.add_theme_constant_override("margin_top", 20)
    margin.add_theme_constant_override("margin_bottom", 20)
    var stack := $Center/Panel/Margin/Stack as VBoxContainer
    stack.add_theme_constant_override("separation", 10)

    var divider := $Center/Panel/Margin/Stack/Divider as TextureRect
    divider.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

    var title := $Center/Panel/Margin/Stack/Title as Label
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", COLOR_GOLD)
    title.add_theme_color_override("font_outline_color", COLOR_WOOD)
    title.add_theme_constant_override("outline_size", 2)
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    message_label.add_theme_font_size_override("font_size", 14)
    message_label.add_theme_color_override("font_color", COLOR_PARCHMENT)
    message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

    percent_label.add_theme_font_size_override("font_size", 15)
    percent_label.add_theme_color_override("font_color", COLOR_GOLD)
    percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    # Square, pixel-sharp edges echo the menu buttons instead of using a generic rounded bar.
    var bar_background := StyleBoxFlat.new()
    bar_background.bg_color = COLOR_TEAL_DARK
    bar_background.border_color = COLOR_GOLD
    bar_background.set_border_width_all(2)
    bar_background.set_corner_radius_all(0)
    bar_background.content_margin_left = 2.0
    bar_background.content_margin_right = 2.0
    bar_background.content_margin_top = 2.0
    bar_background.content_margin_bottom = 2.0
    progress_bar.add_theme_stylebox_override("background", bar_background)

    var fill_style := StyleBoxFlat.new()
    fill_style.bg_color = COLOR_GOLD
    fill_style.border_color = Color("#F0C56E")
    fill_style.set_border_width_all(1)
    fill_style.set_corner_radius_all(0)
    progress_bar.add_theme_stylebox_override("fill", fill_style)


func set_progress(progress: float, message: String) -> void:
    var clamped_progress := clampf(progress, 0.0, 1.0)
    progress_bar.value = clamped_progress * 100.0
    percent_label.text = "%d%%" % int(roundi(clamped_progress * 100.0))
    message_label.text = message
