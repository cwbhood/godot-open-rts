extends SceneTree

# Writes assets/ui/theme/ironbound.tres, the game-wide UI theme (project setting
# gui/theme/custom). The palette and fonts are the website's (site/assets/site.css):
# dark crate-wood panels with a thin line, sand text, constructor-yellow accent.
#
#   godot --headless --path . -s tools/ui/BuildTheme.gd
#
# Edit this script rather than the .tres, then run it again.

const OUT = "res://assets/ui/theme/ironbound.tres"
const FONTS = "res://assets/ui/fonts/"
const ICONS = "res://assets/ui/icons/hud/"

const BG = Color("#14110d")
const SURFACE = Color("#1f1a14")
const SURFACE_2 = Color("#2a231b")
const SURFACE_3 = Color("#3a3024")
const LINE = Color("#3d3326")
const FG = Color("#efe4cf")
const MUTED = Color("#b5a68c")
const ACCENT = Color("#f2a93b")
const ACCENT_INK = Color("#1a1206")
const OASIS = Color("#4cc1b0")

var theme = Theme.new()


func _init():
	var body = load(FONTS + "barlow-600.woff2")
	var display = load(FONTS + "big-shoulders-stencil-display-900.woff2")
	var mono = load(FONTS + "ibm-plex-mono-500.woff2")
	theme.default_font = body
	theme.default_font_size = 15

	_panels()
	_buttons()
	_toggles()
	_inputs()
	_lists()
	_misc()
	_variations(display, mono, load(FONTS + "barlow-700.woff2"))

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT.get_base_dir()))
	var error = ResourceSaver.save(theme, OUT)
	print("saved ", OUT, " -> ", error_string(error))
	quit(0 if error == OK else 1)


func _box(
	color, border = Color.TRANSPARENT, border_width = 0, radius = 4, margin = Vector4(0, 0, 0, 0)
):
	var box = StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = margin.x
	box.content_margin_top = margin.y
	box.content_margin_right = margin.z
	box.content_margin_bottom = margin.w
	box.anti_aliasing = true
	return box


func _panel_box():
	var box = _box(Color(BG, 0.9), LINE, 1, 5, Vector4(2, 2, 2, 2))
	box.shadow_color = Color(0, 0, 0, 0.35)
	box.shadow_size = 6
	box.shadow_offset = Vector2(0, 2)
	return box


func _panels():
	theme.set_stylebox("panel", "PanelContainer", _panel_box())
	theme.set_stylebox("panel", "Panel", _panel_box())
	var tooltip = _box(SURFACE, Color(ACCENT, 0.55), 1, 4, Vector4(10, 7, 10, 7))
	theme.set_stylebox("panel", "TooltipPanel", tooltip)
	theme.set_color("font_color", "TooltipLabel", FG)
	theme.set_font_size("font_size", "TooltipLabel", 14)
	var popup = _box(SURFACE, LINE, 1, 4, Vector4(4, 4, 4, 4))
	theme.set_stylebox("panel", "PopupMenu", popup)
	theme.set_stylebox("panel", "PopupPanel", popup)
	theme.set_stylebox(
		"hover", "PopupMenu", _box(Color(ACCENT, 0.9), Color.TRANSPARENT, 0, 3, Vector4(6, 2, 6, 2))
	)
	theme.set_color("font_color", "PopupMenu", FG)
	theme.set_color("font_hover_color", "PopupMenu", ACCENT_INK)
	theme.set_color("font_disabled_color", "PopupMenu", Color(MUTED, 0.5))
	theme.set_color("font_separator_color", "PopupMenu", MUTED)
	theme.set_constant("v_separation", "PopupMenu", 6)
	var window = _box(SURFACE, LINE, 1, 0, Vector4(0, 0, 0, 0))
	window.expand_margin_top = 28
	window.expand_margin_left = 1
	window.expand_margin_right = 1
	window.expand_margin_bottom = 1
	theme.set_stylebox("embedded_border", "Window", window)
	theme.set_stylebox("embedded_unfocused_border", "Window", window)
	theme.set_color("title_color", "Window", ACCENT)
	theme.set_stylebox(
		"panel", "AcceptDialog", _box(SURFACE, Color.TRANSPARENT, 0, 0, Vector4(8, 8, 8, 8))
	)
	var tab_panel = _box(Color(BG, 0.6), LINE, 1, 4, Vector4(6, 6, 6, 6))
	theme.set_stylebox("panel", "TabContainer", tab_panel)


func _button_states(type, margin = Vector4(10, 5, 10, 5)):
	theme.set_stylebox("normal", type, _box(SURFACE_2, LINE, 1, 4, margin))
	theme.set_stylebox("hover", type, _box(SURFACE_3, Color(ACCENT, 0.7), 1, 4, margin))
	theme.set_stylebox("pressed", type, _box(ACCENT, ACCENT, 1, 4, margin))
	theme.set_stylebox("hover_pressed", type, _box(ACCENT.lightened(0.12), ACCENT, 1, 4, margin))
	theme.set_stylebox("disabled", type, _box(Color(SURFACE, 0.8), Color(LINE, 0.6), 1, 4, margin))
	theme.set_stylebox("focus", type, StyleBoxEmpty.new())
	theme.set_color("font_color", type, FG)
	theme.set_color("font_hover_color", type, Color.WHITE)
	theme.set_color("font_pressed_color", type, ACCENT_INK)
	theme.set_color("font_hover_pressed_color", type, ACCENT_INK)
	theme.set_color("font_focus_color", type, FG)
	theme.set_color("font_disabled_color", type, Color(MUTED, 0.5))
	theme.set_color("icon_normal_color", type, Color.WHITE)
	theme.set_color("icon_pressed_color", type, Color.WHITE)
	theme.set_color("icon_disabled_color", type, Color(1, 1, 1, 0.4))
	theme.set_color("font_outline_color", type, Color(0, 0, 0, 0.6))


func _buttons():
	_button_states("Button")
	_button_states("OptionButton", Vector4(10, 5, 8, 5))
	theme.set_icon("arrow", "OptionButton", load(ICONS + "chevron_down.svg"))
	theme.set_constant("arrow_margin", "OptionButton", 6)
	_button_states("MenuButton")


func _toggles():
	for type in ["CheckBox", "CheckButton"]:
		var flat = Vector4(4, 3, 4, 3)
		theme.set_stylebox("normal", type, _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 4, flat))
		theme.set_stylebox("pressed", type, _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 4, flat))
		theme.set_stylebox("hover", type, _box(Color(1, 1, 1, 0.05), Color.TRANSPARENT, 0, 4, flat))
		theme.set_stylebox(
			"hover_pressed", type, _box(Color(1, 1, 1, 0.05), Color.TRANSPARENT, 0, 4, flat)
		)
		theme.set_stylebox("disabled", type, _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 4, flat))
		theme.set_stylebox("focus", type, StyleBoxEmpty.new())
		theme.set_color("font_color", type, FG)
		theme.set_color("font_hover_color", type, Color.WHITE)
		theme.set_color("font_pressed_color", type, FG)
		theme.set_color("font_hover_pressed_color", type, Color.WHITE)
		theme.set_color("font_disabled_color", type, Color(MUTED, 0.5))
		theme.set_constant("h_separation", type, 8)
	theme.set_icon("checked", "CheckBox", load(ICONS + "check_on.svg"))
	theme.set_icon("unchecked", "CheckBox", load(ICONS + "check_off.svg"))
	theme.set_icon("checked_disabled", "CheckBox", load(ICONS + "check_on_disabled.svg"))
	theme.set_icon("unchecked_disabled", "CheckBox", load(ICONS + "check_off_disabled.svg"))
	theme.set_icon("radio_checked", "CheckBox", load(ICONS + "radio_on.svg"))
	theme.set_icon("radio_unchecked", "CheckBox", load(ICONS + "radio_off.svg"))
	theme.set_icon("radio_checked_disabled", "CheckBox", load(ICONS + "check_on_disabled.svg"))
	theme.set_icon("radio_unchecked_disabled", "CheckBox", load(ICONS + "check_off_disabled.svg"))
	theme.set_icon("checked", "CheckButton", load(ICONS + "toggle_on.svg"))
	theme.set_icon("unchecked", "CheckButton", load(ICONS + "toggle_off.svg"))
	theme.set_icon("checked_disabled", "CheckButton", load(ICONS + "toggle_on_disabled.svg"))
	theme.set_icon("unchecked_disabled", "CheckButton", load(ICONS + "toggle_off_disabled.svg"))
	theme.set_icon("checked_mirrored", "CheckButton", load(ICONS + "toggle_on.svg"))
	theme.set_icon("unchecked_mirrored", "CheckButton", load(ICONS + "toggle_off.svg"))


func _inputs():
	var field = Vector4(8, 4, 8, 4)
	for type in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", type, _box(BG, LINE, 1, 4, field))
		theme.set_stylebox("focus", type, _box(Color.TRANSPARENT, Color(ACCENT, 0.8), 1, 4, field))
		theme.set_stylebox("read_only", type, _box(Color(BG, 0.6), Color(LINE, 0.6), 1, 4, field))
		theme.set_color("font_color", type, FG)
		theme.set_color("caret_color", type, ACCENT)
		theme.set_color("selection_color", type, Color(ACCENT, 0.35))
		theme.set_color("font_placeholder_color", type, Color(MUTED, 0.6))
	var bar_bg = _box(BG, LINE, 1, 3)
	bar_bg.content_margin_top = 1
	bar_bg.content_margin_bottom = 1
	theme.set_stylebox("background", "ProgressBar", bar_bg)
	theme.set_stylebox("fill", "ProgressBar", _box(ACCENT, Color.TRANSPARENT, 0, 3))
	theme.set_color("font_color", "ProgressBar", FG)
	for type in ["HSlider", "VSlider"]:
		theme.set_stylebox("slider", type, _box(SURFACE_2, LINE, 1, 3, Vector4(0, 3, 0, 3)))
		theme.set_stylebox(
			"grabber_area",
			type,
			_box(Color(ACCENT, 0.8), Color.TRANSPARENT, 0, 3, Vector4(0, 3, 0, 3))
		)
		theme.set_stylebox(
			"grabber_area_highlight",
			type,
			_box(ACCENT, Color.TRANSPARENT, 0, 3, Vector4(0, 3, 0, 3))
		)


func _lists():
	var item_margin = Vector4(6, 6, 6, 6)
	theme.set_stylebox("panel", "ItemList", _box(Color(BG, 0.85), LINE, 1, 4, item_margin))
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	theme.set_stylebox("selected", "ItemList", _box(Color(ACCENT, 0.9), Color.TRANSPARENT, 0, 3))
	theme.set_stylebox("selected_focus", "ItemList", _box(ACCENT, Color.TRANSPARENT, 0, 3))
	theme.set_stylebox("hovered", "ItemList", _box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, 3))
	theme.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	theme.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	theme.set_color("font_color", "ItemList", FG)
	theme.set_color("font_hovered_color", "ItemList", Color.WHITE)
	theme.set_color("font_selected_color", "ItemList", ACCENT_INK)
	theme.set_color("guide_color", "ItemList", Color(LINE, 0.5))
	theme.set_constant("v_separation", "ItemList", 6)
	theme.set_constant("h_separation", "ItemList", 8)
	var tab = Vector4(12, 5, 12, 5)
	theme.set_stylebox("tab_selected", "TabContainer", _box(SURFACE_2, ACCENT, 0, 4, tab))
	theme.set_stylebox("tab_unselected", "TabContainer", _box(Color(BG, 0.7), LINE, 0, 4, tab))
	theme.set_stylebox("tab_hovered", "TabContainer", _box(SURFACE_3, LINE, 0, 4, tab))
	for type in ["TabContainer", "TabBar"]:
		theme.set_color("font_selected_color", type, ACCENT)
		theme.set_color("font_unselected_color", type, MUTED)
		theme.set_color("font_hovered_color", type, FG)
	theme.set_stylebox("tab_selected", "TabBar", _box(SURFACE_2, ACCENT, 0, 4, tab))
	theme.set_stylebox("tab_unselected", "TabBar", _box(Color(BG, 0.7), LINE, 0, 4, tab))
	theme.set_stylebox("tab_hovered", "TabBar", _box(SURFACE_3, LINE, 0, 4, tab))


func _misc():
	theme.set_color("font_color", "Label", FG)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	var line = StyleBoxLine.new()
	line.color = LINE
	line.thickness = 1
	theme.set_stylebox("separator", "HSeparator", line)
	theme.set_constant("separation", "HSeparator", 8)
	var vline = StyleBoxLine.new()
	vline.color = LINE
	vline.vertical = true
	theme.set_stylebox("separator", "VSeparator", vline)
	for type in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox(
			"scroll", type, _box(Color(BG, 0.4), Color.TRANSPARENT, 0, 4, Vector4(3, 3, 3, 3))
		)
		theme.set_stylebox("grabber", type, _box(Color(MUTED, 0.45), Color.TRANSPARENT, 0, 4))
		theme.set_stylebox(
			"grabber_highlight", type, _box(Color(MUTED, 0.7), Color.TRANSPARENT, 0, 4)
		)
		theme.set_stylebox("grabber_pressed", type, _box(ACCENT, Color.TRANSPARENT, 0, 4))
	theme.set_color("font_color", "RichTextLabel", FG)
	theme.set_color("default_color", "RichTextLabel", FG)


func _variations(display, mono, bold):
	# headings: bold body face, accent coloured (the condensed stencil face is unreadable at
	# panel-header sizes; it is kept for big titles, TitleLabel)
	theme.add_type("HeaderLabel")
	theme.set_type_variation("HeaderLabel", "Label")
	theme.set_font("font", "HeaderLabel", bold)
	theme.set_font_size("font_size", "HeaderLabel", 20)
	theme.set_color("font_color", "HeaderLabel", ACCENT)
	theme.add_type("TitleLabel")
	theme.set_type_variation("TitleLabel", "Label")
	theme.set_font("font", "TitleLabel", display)
	theme.set_font_size("font_size", "TitleLabel", 44)
	theme.set_color("font_color", "TitleLabel", ACCENT)
	# numbers: stock, prices, clocks
	theme.add_type("NumberLabel")
	theme.set_type_variation("NumberLabel", "Label")
	theme.set_font("font", "NumberLabel", mono)
	theme.set_font_size("font_size", "NumberLabel", 15)
	theme.add_type("MutedLabel")
	theme.set_type_variation("MutedLabel", "Label")
	theme.set_color("font_color", "MutedLabel", MUTED)
	theme.set_font_size("font_size", "MutedLabel", 13)
	# the HUD's top strip: square edges, flush with the screen
	theme.add_type("TopBar")
	theme.set_type_variation("TopBar", "PanelContainer")
	var bar = _box(Color(BG, 0.92), Color.TRANSPARENT, 0, 0, Vector4(10, 3, 10, 3))
	bar.border_color = LINE
	bar.border_width_bottom = 1
	bar.shadow_color = Color(0, 0, 0, 0.35)
	bar.shadow_size = 6
	theme.set_stylebox("panel", "TopBar", bar)
	# panels with no frame (the build grid holder)
	theme.add_type("ClearPanel")
	theme.set_type_variation("ClearPanel", "PanelContainer")
	theme.set_stylebox("panel", "ClearPanel", StyleBoxEmpty.new())
	# a strong call to action: the accent filled button
	theme.add_type("AccentButton")
	theme.set_type_variation("AccentButton", "Button")
	var m = Vector4(16, 7, 16, 7)
	theme.set_stylebox("normal", "AccentButton", _box(ACCENT, ACCENT, 1, 4, m))
	theme.set_stylebox("hover", "AccentButton", _box(ACCENT.lightened(0.15), ACCENT, 1, 4, m))
	theme.set_stylebox("pressed", "AccentButton", _box(ACCENT.darkened(0.15), ACCENT, 1, 4, m))
	theme.set_stylebox(
		"disabled", "AccentButton", _box(Color(ACCENT, 0.3), Color.TRANSPARENT, 0, 4, m)
	)
	theme.set_color("font_color", "AccentButton", ACCENT_INK)
	theme.set_color("font_hover_color", "AccentButton", ACCENT_INK)
	theme.set_color("font_pressed_color", "AccentButton", ACCENT_INK)
	theme.set_color("font_disabled_color", "AccentButton", Color(ACCENT_INK, 0.6))
	# a flat header button that folds a panel
	theme.add_type("HeaderButton")
	theme.set_type_variation("HeaderButton", "Button")
	var hm = Vector4(4, 2, 4, 2)
	theme.set_stylebox("normal", "HeaderButton", StyleBoxEmpty.new())
	theme.set_stylebox("pressed", "HeaderButton", StyleBoxEmpty.new())
	theme.set_stylebox(
		"hover", "HeaderButton", _box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, 3, hm)
	)
	theme.set_stylebox(
		"hover_pressed", "HeaderButton", _box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, 3, hm)
	)
	theme.set_color("font_color", "HeaderButton", FG)
	theme.set_color("font_pressed_color", "HeaderButton", FG)
	theme.set_color("font_hover_color", "HeaderButton", ACCENT)
	theme.set_color("font_hover_pressed_color", "HeaderButton", ACCENT)
	theme.set_font("font", "HeaderButton", bold)
	theme.set_font_size("font_size", "HeaderButton", 16)
	# build / command slots in the unit menu
	theme.add_type("SlotButton")
	theme.set_type_variation("SlotButton", "Button")
	var slot = _box(Color(SURFACE, 0.92), LINE, 1, 5)
	slot.border_width_bottom = 2
	theme.set_stylebox("normal", "SlotButton", slot)
	var slot_hover = _box(SURFACE_3, ACCENT, 1, 5)
	slot_hover.border_width_bottom = 2
	theme.set_stylebox("hover", "SlotButton", slot_hover)
	theme.set_stylebox("pressed", "SlotButton", _box(Color(ACCENT, 0.35), ACCENT, 2, 5))
	theme.set_stylebox("hover_pressed", "SlotButton", _box(Color(ACCENT, 0.45), ACCENT, 2, 5))
	theme.set_stylebox("disabled", "SlotButton", _box(Color(BG, 0.85), Color(LINE, 0.7), 1, 5))
	theme.set_color("font_pressed_color", "SlotButton", FG)
	theme.set_color("font_hover_pressed_color", "SlotButton", Color.WHITE)
