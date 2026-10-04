extends RefCounted

# Per-match rules for how much help a player gets, picked in the Play menu (see
# source/main-menu/MatchRulesOptions.gd) and carried in MatchSettings:
#
# - tutorial: the tutorial panel and the one-off hints (the F1 manual always stays),
# - ai_assist: the player's helper AI (Helper.gd, its panel and the H key),
# - auto_build: constructor auto-expand (AutoExpand.gd, its panel, bar and the G key).
#
# "Guided" turns all three on, "Raw" turns all three off. When a rule is off the feature
# is gone for the whole match: no HUD, no hotkey, and its code refuses to run even when a
# script asks for it. Matches without these settings (older saves, test scenes) allow all.

const PRESET_GUIDED = "guided"
const PRESET_RAW = "raw"
const PRESET_CUSTOM = "custom"
const RULES = ["tutorial", "ai_assist", "auto_build"]
const PRESETS = {
	PRESET_GUIDED: {"tutorial": true, "ai_assist": true, "auto_build": true},
	PRESET_RAW: {"tutorial": false, "ai_assist": false, "auto_build": false},
}
const SETTINGS_PATH = "user://match_rules.cfg"


static func apply_preset(match_settings, preset):
	"""sets the three rules of a MatchSettings from "guided" or "raw"; false if unknown"""
	if not preset in PRESETS:
		return false
	for rule in RULES:
		match_settings.set(rule, PRESETS[preset][rule])
	return true


static func preset_of(rules):
	"""rules: anything with the three fields (MatchSettings or a dictionary)"""
	for preset in PRESETS:
		if RULES.all(func(rule): return _value(rules, rule) == PRESETS[preset][rule]):
			return preset
	return PRESET_CUSTOM


static func allowed(node, rule):
	"""whether the match node is in allows a rule; true outside a match"""
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return true
	var a_match = node.get_tree().get_first_node_in_group("match")
	if a_match == null:
		return true
	return _value(a_match.get("settings"), rule)


static func tutorial_on(node):
	return allowed(node, "tutorial")


static func ai_assist_on(node):
	return allowed(node, "ai_assist")


static func auto_build_on(node):
	return allowed(node, "auto_build")


static func describe(rules):
	"""one line for screens everyone sees, e.g. "Rules: Raw. Tutorial and tips off, ..." """
	var t = func(key): return TranslationServer.translate(key)
	var on_off = func(rule):
		return t.call("MATCH_RULES_ON" if _value(rules, rule) else "MATCH_RULES_OFF")
	return (
		t
		. call("MATCH_RULES_LINE")
		. format(
			[
				t.call("MATCH_RULES_PRESET_" + preset_of(rules).to_upper()),
				on_off.call("tutorial"),
				on_off.call("ai_assist"),
				on_off.call("auto_build"),
			]
		)
	)


static func load_last():
	"""the rules picked last time in the Play menu; new players get Guided"""
	var rules = PRESETS[PRESET_GUIDED].duplicate()
	var config = ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		for rule in RULES:
			rules[rule] = bool(config.get_value("rules", rule, rules[rule]))
	return rules


static func save_last(rules):
	var config = ConfigFile.new()
	for rule in RULES:
		config.set_value("rules", rule, bool(_value(rules, rule)))
	config.save(SETTINGS_PATH)


static func _value(rules, rule):
	if rules == null:
		return true
	var value = rules.get(rule)
	return true if value == null else bool(value)
