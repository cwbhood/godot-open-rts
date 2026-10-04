extends RefCounted

# Shared look of the in-match HUD: the brand palette (see assets/ui/theme/ironbound.tres,
# built by tools/ui/BuildTheme.gd), resource icons and colours, and small builders for
# the folding panel headers and the stat cells used by several panels.

const ICONS = "res://assets/ui/icons/hud/"
const BG = Color("#14110d")
const SURFACE = Color("#1f1a14")
const LINE = Color("#3d3326")
const FG = Color("#efe4cf")
const MUTED = Color("#b5a68c")
const ACCENT = Color("#f2a93b")
const RUST = Color("#d0643a")
const OASIS = Color("#4cc1b0")
const GOOD = Color("#8fbf5a")
const WARN = Color("#f2a93b")
const BAD = Color("#e0603f")
# brand colours of the commodities; data/resources.json colours paint the 3D deposits
# (oil there is almost black, unreadable on a dark bar)
const RESOURCE_COLORS = {
	"timber": Color("#8fbf5a"),
	"iron": Color("#a9b3bf"),
	"copper": Color("#e08a4f"),
	"oil": Color("#8b7bd8"),
}


static func icon(name):
	var path = ICONS + name + ".svg"
	return load(path) if ResourceLoader.exists(path) else null


static func resource_icon(resource):
	return icon(resource)


static func resource_color(resource):
	if resource in RESOURCE_COLORS:
		return RESOURCE_COLORS[resource]
	return Constants.Match.Resources.COLORS.get(resource, FG)


static func icon_rect(texture, size = 20):
	var rect = TextureRect.new()
	rect.texture = texture
	rect.custom_minimum_size = Vector2(size, size)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


static func margin(node, horizontal = 10, vertical = 8):
	"""wraps the panel's content in even padding and returns the margin container"""
	var container = MarginContainer.new()
	container.add_theme_constant_override("margin_left", horizontal)
	container.add_theme_constant_override("margin_right", horizontal)
	container.add_theme_constant_override("margin_top", vertical)
	container.add_theme_constant_override("margin_bottom", vertical)
	node.add_child(container)
	return container


static func header(icon_name, title_label, fold_button):
	"""a panel header: icon, title (stencil face) and a chevron that folds the panel"""
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var texture = icon(icon_name)
	if texture != null:
		row.add_child(icon_rect(texture, 20))
	title_label.theme_type_variation = "HeaderLabel"
	title_label.add_theme_font_size_override("font_size", 16)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	row.add_child(title_label)
	if fold_button != null:
		style_fold_button(fold_button)
		row.add_child(fold_button)
	return row


static func style_fold_button(button):
	button.flat = false
	button.theme_type_variation = "HeaderButton"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(26, 26)
	button.expand_icon = false
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER


static func set_folded_icon(button, folded):
	button.text = ""
	button.icon = icon("chevron_right" if folded else "chevron_down")
	button.tooltip_text = TranslationServer.translate("HUD_EXPAND" if folded else "HUD_COLLAPSE")


static func stat_cell(caption, value_label, tooltip = ""):
	"""a small caption over a number, for the stat grids"""
	var cell = VBoxContainer.new()
	cell.add_theme_constant_override("separation", -2)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.tooltip_text = tooltip
	cell.mouse_filter = Control.MOUSE_FILTER_PASS
	var caption_label = Label.new()
	caption_label.text = caption
	caption_label.theme_type_variation = "MutedLabel"
	caption_label.add_theme_font_size_override("font_size", 11)
	caption_label.uppercase = true
	caption_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(caption_label)
	value_label.theme_type_variation = "NumberLabel"
	value_label.add_theme_font_size_override("font_size", 15)
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(value_label)
	return cell


static func small(label, size = 13, muted = false):
	label.add_theme_font_size_override("font_size", size)
	if muted:
		label.theme_type_variation = "MutedLabel"
	return label
