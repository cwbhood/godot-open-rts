extends RefCounted

# The "Match rules" box of the Play menu: how much help the player gets this match.
#
# - a preset dropdown: Guided (tutorial, AI assist and auto-build all allowed), Raw (none
#   of them: play it with no help and no automation) or Custom once a box is changed,
# - one check box per rule (see source/data-model/MatchRules.gd).
#
# New players start on Guided; after that the last choice is remembered in
# user://match_rules.cfg. Play.gd copies the choice into MatchSettings with apply_to().

const MatchRules = preload("res://source/data-model/MatchRules.gd")

const PRESET_ORDER = [MatchRules.PRESET_GUIDED, MatchRules.PRESET_RAW, MatchRules.PRESET_CUSTOM]
const RULE_KEYS = {
	"tutorial": "MATCH_RULE_TUTORIAL",
	"ai_assist": "MATCH_RULE_AI_ASSIST",
	"auto_build": "MATCH_RULE_AUTO_BUILD",
}

var box = VBoxContainer.new()
var preset_button = OptionButton.new()
var check_boxes = {}  # rule -> CheckBox
var _summary = Label.new()


func setup(parent):
	box.name = "MatchRules"
	parent.add_child(box)
	var header = HBoxContainer.new()
	box.add_child(header)
	var title = Label.new()
	title.text = tr("MATCH_RULES")
	title.tooltip_text = tr("MATCH_RULES_TOOLTIP")
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	preset_button.name = "MatchRulesPreset"
	for preset in PRESET_ORDER:
		preset_button.add_item(tr("MATCH_RULES_PRESET_" + preset.to_upper()))
		preset_button.set_item_tooltip(
			preset_button.item_count - 1, tr("MATCH_RULES_PRESET_%s_TOOLTIP" % preset.to_upper())
		)
	preset_button.set_item_disabled(PRESET_ORDER.find(MatchRules.PRESET_CUSTOM), true)
	preset_button.item_selected.connect(func(index): select_preset(PRESET_ORDER[index]))
	header.add_child(preset_button)
	var last = MatchRules.load_last()
	for rule in MatchRules.RULES:
		var check_box = CheckBox.new()
		check_box.name = "MatchRule_" + rule
		check_box.text = tr(RULE_KEYS[rule])
		check_box.tooltip_text = tr(RULE_KEYS[rule] + "_TOOLTIP")
		check_box.button_pressed = last[rule]
		check_box.toggled.connect(func(_pressed): _on_changed())
		box.add_child(check_box)
		check_boxes[rule] = check_box
	_summary.add_theme_font_size_override("font_size", 13)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size.x = 240
	_summary.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_summary)
	_refresh()


func select_preset(preset):
	"""sets the boxes from "guided" or "raw" (also what the QA bots call)"""
	if not preset in MatchRules.PRESETS:
		return
	for rule in MatchRules.RULES:
		check_boxes[rule].set_pressed_no_signal(MatchRules.PRESETS[preset][rule])
	_on_changed()


func rules():
	var chosen = {}
	for rule in MatchRules.RULES:
		chosen[rule] = check_boxes[rule].button_pressed
	return chosen


func apply_to(match_settings):
	var chosen = rules()
	for rule in MatchRules.RULES:
		match_settings.set(rule, chosen[rule])
	MatchRules.save_last(chosen)


func _on_changed():
	_refresh()


func _refresh():
	var preset = MatchRules.preset_of(rules())
	preset_button.select(PRESET_ORDER.find(preset))
	_summary.text = tr("MATCH_RULES_PRESET_%s_TOOLTIP" % preset.to_upper())
