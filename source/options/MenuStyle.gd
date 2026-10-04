extends RefCounted

# The few brand touches the options screen and the pause menu add on top of the existing
# theme (source/resources/main_menu.theme): solid panels in the brand's colours and the
# stencil heading font. Palette and font: site/assets/site.css, site/assets/fonts/.

const HEADING_FONT_PATH = "res://assets/ui/fonts/big-shoulders-stencil-display-800.woff2"
const BACKGROUND = Color("14110d")
const SURFACE = Color("1f1a14")
const LINE = Color("3d3326")
const TEXT = Color("efe4cf")
const MUTED = Color("b5a68c")
const ACCENT = Color("f2a93b")


static func heading_font():
	if not ResourceLoader.exists(HEADING_FONT_PATH):
		return null
	var font = FontVariation.new()
	font.base_font = load(HEADING_FONT_PATH)
	font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 800}
	return font


static func style_heading(label, size, font = null):
	if font == null:
		font = heading_font()
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", ACCENT)


static func panel_style(alpha = 0.97):
	var style = StyleBoxFlat.new()
	style.bg_color = Color(SURFACE, alpha)
	style.border_color = LINE
	style.set_border_width_all(2)
	style.border_width_top = 3
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 18
	return style


static func style_panel(panel):
	panel.add_theme_stylebox_override("panel", panel_style())


static func style_dialog(dialog):
	var style = panel_style(1.0)
	style.set_content_margin_all(16)
	dialog.add_theme_stylebox_override("panel", style)
	var border = panel_style(1.0)
	border.bg_color = BACKGROUND
	border.border_color = ACCENT
	border.set_border_width_all(1)
	border.expand_margin_top = 32
	border.expand_margin_left = 2
	border.expand_margin_right = 2
	border.expand_margin_bottom = 2
	dialog.add_theme_stylebox_override("embedded_border", border)
	dialog.add_theme_stylebox_override("embedded_unfocused_border", border)
	dialog.add_theme_color_override("title_color", ACCENT)


static func accent_button(button):
	"""the main action of a menu (Back, Resume): amber with dark text"""
	for state in ["normal", "hover", "pressed", "focus"]:
		var style = StyleBoxFlat.new()
		style.bg_color = {
			"normal": ACCENT,
			"hover": ACCENT.lightened(0.15),
			"pressed": ACCENT.darkened(0.15),
			"focus": ACCENT,
		}[state]
		style.set_corner_radius_all(6)
		style.set_content_margin_all(6)
		if state == "focus":
			style.draw_center = false
		button.add_theme_stylebox_override(state, style)
	for color in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(color, Color("1a1206"))


static func style_slider(slider):
	"""a track that shows on the dark panel, filled in amber up to the grabber"""
	var track = StyleBoxFlat.new()
	track.bg_color = LINE
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	slider.add_theme_stylebox_override("slider", track)
	for item in ["grabber_area", "grabber_area_highlight"]:
		var filled = track.duplicate()
		filled.bg_color = ACCENT if item == "grabber_area" else ACCENT.lightened(0.15)
		slider.add_theme_stylebox_override(item, filled)
