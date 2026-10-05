extends RefCounted

# Texts of the building card and the hover tip (BuildingInfo.gd), built from the unit's
# entry in data/units (name, role, info, cost, power, extracts, what it produces) and
# from its live state. Lines are BBCode for a RichTextLabel; truck names are [url] links
# carrying the truck's instance id so the card can select and centre on them.

const GameData = preload("res://source/data-model/GameData.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const HaulerLinks = preload("res://source/match/economy/HaulerLinks.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Storage = preload("res://source/match/units/Storage.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")

const MAX_TRUCK_ROWS = 6
const KIND_COLORS = {
	"COLLECT": HudStyle.ACCENT,
	"BRINGING_GOODS": HudStyle.ACCENT,
	"BRINGING_MATERIALS": HudStyle.RUST,
	"COMING_TO_LOAD": HudStyle.RUST,
	"COMING_FOR_MATERIALS": HudStyle.RUST,
	"RETURNING": HudStyle.ACCENT,
	"WAITING": HudStyle.OASIS,
	"LEAVING": Color("#6f9be0"),
	"PARKED": Color("#8c7f6b"),
	"TRAIN": HudStyle.GOOD,
}


static func entry_of(unit):
	return GameData.unit_by_scene(unit._scene_path())


static func role_text(unit):
	var entry = entry_of(unit)
	if entry == null:
		return ""
	if entry.get("category") != "structure":
		return _tr("ROLE_UNIT")
	return _tr("ROLE_" + str(entry.get("role", "support")).to_upper())


static func info_text(unit):
	"""what it is and what it does: the long info, or the short description"""
	var entry = entry_of(unit)
	if entry == null:
		return ""
	if "info" in entry and _tr(entry["info"]) != entry["info"]:
		return _tr(entry["info"])
	var description = _tr(entry.get("description", ""))
	return description.left(1).to_upper() + description.substr(1)


static func needs_line(unit):
	var entry = entry_of(unit)
	return needs_for(entry) if entry != null else ""


static func needs_for(entry):
	"""what building it costs and what it uses while it runs"""
	var parts = []
	var cost = entry.get("cost", {})
	if not cost.is_empty():
		parts.append(_tr("INFO_COSTS") + " " + HaulerLinks.cargo_text(cost))
	var power = _power(entry)
	if power.get("demand_mw") != null and float(power.get("demand_mw", 0.0)) > 0.0:
		parts.append(_tr("INFO_POWER_USE").format([_number(power["demand_mw"])]))
	var burns = power.get("burns")
	if burns is Dictionary and not burns.is_empty():
		var kinds = []
		for kind in burns:
			kinds.append(_tr(kind.to_upper()).to_lower())
		parts.append(_tr("INFO_BURNS").format([", ".join(kinds)]))
	return " · ".join(parts)


static func makes_line(unit):
	var entry = entry_of(unit)
	if entry == null:
		return ""
	return makes_for(entry, unit.player.faction if unit.player != null else "")


static func makes_for(entry, faction):
	"""what it extracts, powers, trains or shoots at"""
	var parts = []
	var extracts = entry.get("extracts", [])
	if not extracts.is_empty():
		var kinds = []
		for kind in extracts:
			kinds.append(_tr(kind.to_upper()))
		parts.append(_tr("INFO_EXTRACTS").format([" / ".join(kinds)]))
	var power = _power(entry)
	if power.get("output_mw") != null and float(power.get("output_mw", 0.0)) > 0.0:
		parts.append(
			_tr("INFO_POWER_MAKES").format(
				[_number(power["output_mw"]), _number(power.get("grid_radius_m", 0.0))]
			)
		)
	elif power.get("grid_radius_m") != null and float(power.get("grid_radius_m", 0.0)) > 0.0:
		parts.append(_tr("INFO_GRID_ONLY").format([_number(power["grid_radius_m"])]))
	if entry.get("trade_depot") == true:
		parts.append(_tr("INFO_TRADE_DEPOT"))
	if entry.get("production_bonus") != null:
		parts.append(
			_tr("INFO_FASTER_FACTORIES").format([int(float(entry["production_bonus"]) * 100.0)])
		)
	var names = []
	for product in GameData.producible_by(entry["id"], faction):
		if product.get("category") == "unit":
			names.append(_tr(product["name"]))
	if not names.is_empty():
		parts.append(_tr("INFO_TRAINS").format([", ".join(names)]))
	var properties = entry.get("properties", {})
	if properties.get("attack_damage") != null:
		var domains = []
		for domain in properties.get("attack_domains", []):
			domains.append(_tr("INFO_ATTACK_AIR" if domain == "air" else "INFO_ATTACK_GROUND"))
		(
			parts
			. append(
				(
					"{0}: {1}"
					. format(
						[
							"/".join(domains),
							(
								_tr("INFO_ATTACK")
								. format(
									[
										_number(properties["attack_damage"]),
										_number(properties.get("attack_interval", 1.0)),
										_number(properties.get("attack_range", 0.0)),
									]
								)
							),
						]
					)
				)
			)
		)
	return " · ".join(parts) if not parts.is_empty() else _tr("INFO_NOTHING")


static func status_lines(unit, own):
	"""the live state: health, construction, power, yard or production"""
	var lines = []
	if unit.get("hp") != null and unit.get("hp_max") != null:
		lines.append(_tr("INFO_HP").format([int(ceil(unit.hp)), int(unit.hp_max)]))
	if not unit is Structure:
		if unit is Hauler and own:
			lines.append(job_line(unit))
		return lines
	if unit.is_under_construction():
		(
			lines
			. append(
				(
					_tr("INFO_BUILDING")
					. format(
						[
							int(unit.get_construction_progress() * 100.0),
							int(unit.get_materials_ratio() * 100.0),
						]
					)
				)
			)
		)
		return lines
	if not own:
		return lines
	var entry = entry_of(unit)
	if entry != null and float(_power(entry).get("demand_mw", 0.0) or 0.0) > 0.0:
		if unit.power_ratio <= 0.01:
			lines.append(_color(_tr("INFO_NO_POWER"), HudStyle.BAD))
		else:
			lines.append(
				_color(
					_tr("INFO_POWERED").format([int(unit.power_ratio * 100.0)]),
					HudStyle.GOOD if unit.power_ratio >= 0.99 else HudStyle.WARN
				)
			)
	if unit is Extractor:
		lines.append_array(_extractor_lines(unit))
	elif unit is Storage:
		lines.append(_storage_line(unit))
	var queue = unit.find_child("ProductionQueue", false, false)
	if queue != null and queue.has_method("get_elements"):
		var elements = queue.get_elements()
		if elements.is_empty():
			lines.append(_color(_tr("INFO_IDLE_FACTORY"), HudStyle.MUTED))
		else:
			var first = elements.front()
			var product = GameData.unit_by_scene(_scene_of(first.unit_prototype))
			(
				lines
				. append(
					(
						_tr("INFO_PRODUCING")
						. format(
							[
								_tr(product["name"]) if product != null else "?",
								int(first.progress() * 100.0),
								elements.size() - 1,
							]
						)
					)
				)
			)
	return lines


static func _extractor_lines(unit):
	var lines = []
	if unit.is_depleted():
		lines.append(_color(_tr("INFO_DEPOSIT_GONE"), HudStyle.BAD))
		return lines
	var kind = unit.get_goods_kind()
	if kind != null:
		(
			lines
			. append(
				(
					_tr("INFO_YARD")
					. format(
						[
							int(unit.stored),
							unit.get_buffer_capacity(),
							_tr(kind.to_upper()),
							_number(unit.get_rate_per_s() * 60.0),
						]
					)
				)
			)
		)
	if unit.is_full():
		lines.append(_color(_tr("INFO_YARD_FULL"), HudStyle.WARN))
	if unit.deposit != null and is_instance_valid(unit.deposit):
		lines.append(
			_color(_tr("INFO_DEPOSIT_LEFT").format([int(unit.deposit.amount)]), HudStyle.MUTED)
		)
	return lines


static func _storage_line(unit):
	if unit.kind == null or unit.stored <= 0:
		var keeps = unit.wanted_kind if unit.wanted_kind != null else "STORAGE_AUTO"
		return _tr("INFO_STORED_EMPTY").format([_tr(keeps.to_upper()).to_lower()])
	return _tr("INFO_STORED").format(
		[int(unit.stored), unit.get_buffer_capacity(), _tr(unit.kind.to_upper())]
	)


static func truck_lines(unit, links = null):
	"""one row per truck or train working for the building"""
	if links == null:
		links = HaulerLinks.links_for(unit)
	var lines = []
	if unit is CommandCenter and unit.is_constructed():
		var counts = {"in": 0, "load": 0, "parked": 0}
		for link in links:
			if link["kind"] in ["BRINGING_GOODS", "RETURNING"]:
				counts["in"] += 1
			elif link["kind"] == "COMING_TO_LOAD":
				counts["load"] += 1
			elif link["kind"] == "PARKED":
				counts["parked"] += 1
		lines.append(
			_tr("INFO_DEPOT_SUMMARY").format([counts["in"], counts["load"], counts["parked"]])
		)
		links = links.filter(func(link): return link["kind"] != "PARKED")
	var trucks = links.filter(func(link): return link["kind"] != "TRAIN")
	if trucks.is_empty() and not unit is CommandCenter:
		lines.append(_color(_tr("INFO_NO_TRUCKS"), HudStyle.MUTED))
	for link in links.slice(0, MAX_TRUCK_ROWS):
		lines.append(link_line(link))
	if links.size() > MAX_TRUCK_ROWS:
		lines.append(
			_color(_tr("INFO_MORE_TRUCKS").format([links.size() - MAX_TRUCK_ROWS]), HudStyle.MUTED)
		)
	return lines


static func link_line(link):
	var truck = link["unit"]
	var name = (
		_tr("INFO_TRAIN_LINE").format([_name_link(truck, _tr("TRAIN"))])
		if link["kind"] == "TRAIN"
		else _name_link(truck, HaulerLinks.display_name(truck))
	)
	if link["kind"] == "TRAIN":
		return "[color={0}]■[/color] {1}".format([KIND_COLORS["TRAIN"].to_html(false), name])
	var cargo = HaulerLinks.cargo_text(link["cargo"])
	var other = HaulerLinks.display_name(link["other"]) if link["other"] != null else "-"
	var metres = int(link["distance"])
	var what = ""
	match link["kind"]:
		"COLLECT":
			var kind = link.get("goods", "")
			what = _tr("LINK_COMING_TO_COLLECT").format([kind, metres])
		"LEAVING":
			what = _tr("LINK_LEAVING_WITH").format([cargo, other])
		"WAITING":
			what = _tr("LINK_WAITING_FOR_LOAD")
		"BRINGING_GOODS":
			what = _tr("LINK_BRINGING_GOODS").format([cargo, other, metres])
		"COMING_TO_LOAD":
			what = _tr("LINK_COMING_TO_LOAD").format([other, metres])
		"COMING_FOR_MATERIALS":
			what = _tr("LINK_COMING_FOR_MATERIALS").format([other])
		"BRINGING_MATERIALS":
			what = _tr("LINK_BRINGING_MATERIALS").format([cargo, metres])
		"RETURNING":
			what = _tr("LINK_RETURNING").format([cargo, metres])
		"PARKED":
			what = _tr("LINK_PARKED")
	if link["eta_s"] >= 0.0 and link["kind"] in HaulerLinks.INBOUND:
		what += " (" + _tr("LINK_ETA").format([int(ceil(link["eta_s"]))]) + ")"
	return "[color={0}]●[/color] {1}: {2}".format(
		[KIND_COLORS.get(link["kind"], HudStyle.FG).to_html(false), name, what]
	)


static func job_line(hauler):
	"""what a truck is doing, for its card and hover tip"""
	var job = HaulerLinks.job_of(hauler)
	var targets = job["targets"]
	var names = []
	for target in targets:
		names.append(HaulerLinks.display_name(target))
	var cargo = HaulerLinks.cargo_text(job["cargo"])
	var metres = int(job["distance"])
	var text = _tr("JOB_IDLE")
	match job["kind"]:
		"COLLECTING":
			text = _tr("JOB_COLLECTING").format([names[0], metres, names[1]])
		"DELIVERING_GOODS":
			var source = HaulerLinks.source_of(hauler)
			text = _tr("JOB_DELIVERING_GOODS").format(
				[
					cargo,
					HaulerLinks.display_name(source) if source != null else "-",
					names[0],
					metres
				]
			)
		"LOADING_FOR_SITE":
			text = _tr("JOB_LOADING_FOR_SITE").format([names[0], names[1]])
		"SUPPLYING_SITE":
			text = _tr("JOB_SUPPLYING_SITE").format([cargo, names[0], metres])
		"RETURNING":
			text = _tr("JOB_RETURNING").format([cargo, names[0], metres])
		"STANDBY":
			text = _tr("JOB_STANDBY").format([names[0]])
		"PARKED":
			text = _tr("JOB_PARKED").format([names[0]])
		"MANUAL", "RECYCLING":
			text = _tr("JOB_" + job["kind"])
	if job["eta_s"] >= 0.0:
		text += " (" + _tr("LINK_ETA").format([int(ceil(job["eta_s"]))]) + ")"
	return text


static func cargo_line(hauler):
	var cargo = HaulerLinks.cargo_text(hauler.cargo)
	return _tr("JOB_CARGO").format([cargo]) if cargo != "" else _tr("JOB_EMPTY")


static func hover_summary(unit, own):
	"""one short line under the name in the hover tip"""
	if unit is Hauler and own:
		return job_line(unit)
	if not unit is Structure:
		return _tr(entry_of(unit).get("description", "")) if entry_of(unit) != null else ""
	if unit.is_under_construction():
		return _tr("INFO_BUILDING").format(
			[int(unit.get_construction_progress() * 100.0), int(unit.get_materials_ratio() * 100.0)]
		)
	if not own or not HaulerLinks.is_served_building(unit):
		return _tr(entry_of(unit).get("description", "")) if entry_of(unit) != null else ""
	var parts = []
	if unit is Extractor:
		parts.append_array(_extractor_lines(unit).slice(0, 2))
	elif unit is Storage:
		parts.append(_storage_line(unit))
	var links = HaulerLinks.links_for(unit)
	var inbound = links.filter(func(link): return link["kind"] in HaulerLinks.INBOUND).size()
	var waiting = links.filter(func(link): return link["kind"] == "WAITING").size()
	parts.append(_tr("HOVER_TRUCKS").format([inbound, waiting]))
	return "\n".join(parts)


static func plain(bbcode):
	"""the text without BBCode tags, for plain labels"""
	var regex = RegEx.create_from_string("\\[/?[a-z]+(=[^\\]]*)?\\]")
	return regex.sub(bbcode, "", true)


static func _name_link(unit, text):
	return "[url={0}]{1}[/url]".format([unit.get_instance_id(), text])


static func _power(entry):
	var power = entry.get("power")
	return power if power is Dictionary else {}


static func _scene_of(prototype):
	if prototype is PackedScene:
		return prototype.resource_path
	return str(prototype)


static func _color(text, color):
	return "[color={0}]{1}[/color]".format([color.to_html(false), text])


static func _number(value):
	var number = float(value)
	return str(int(number)) if is_equal_approx(number, round(number)) else "%.1f" % number


static func _tr(key):
	return TranslationServer.translate(key)
