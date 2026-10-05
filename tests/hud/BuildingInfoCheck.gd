extends "res://tests/logistics/LogisticsChecks.gd"

# Checks the building card, the hover tip and the truck routes (BuildingInfo.gd) in a
# running match and saves screenshots of them: every building in data/units has a role
# and an explanation, a selected mine names the trucks coming for its ore and draws their
# routes, a selected truck says where it is going, hovering shows a building's name,
# rival buildings show who owns them and clicking a truck on the card selects it.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/hud/BuildingInfoCheck.tscn -- --out=/tmp/building-info
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const GameData = preload("res://source/data-model/GameData.gd")
const HaulerLinks = preload("res://source/match/economy/HaulerLinks.gd")
const Text = preload("res://source/match/hud/BuildingInfoText.gd")

var _info = null


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_logistics = _human.logistics
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.random_weather = false
		atmosphere.set_weather_immediately("clear")
	_match.fog_of_war.visible = false
	var guide = _match.find_child("Guide", true, false)
	if guide != null:
		guide.hide()  # the tutorial would cover the shots
	_info = _match.find_child("BuildingInfo", true, false)
	_depot = _own(func(unit): return unit is CommandCenter)
	_human.add_resources({"timber": 300, "iron": 300, "copper": 100, "oil": 200})
	_stop_the_rival()
	_expect(_info != null, "the HUD has the building info")
	_check_every_building_explained()
	await _check_mine_card_and_routes()
	await _check_truck_card()
	await _check_site_card()
	await _check_hover_tip()
	await _check_depot_and_rival()
	Engine.time_scale = 1.0
	print("building info checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_every_building_explained():
	var missing = []
	for entry in GameData.units():
		if entry.get("category") != "structure":
			continue
		var role_key = "ROLE_" + str(entry.get("role", "")).to_upper()
		if not "info" in entry or tr(entry["info"]) == entry["info"] or tr(role_key) == role_key:
			missing.append(entry["id"])
		if Text.needs_for(entry) == "" or Text.makes_for(entry, "") == "":
			missing.append(entry["id"] + " (needs/makes)")
	_expect(missing.is_empty(), "every building has a role and an explanation " + str(missing))


func _card_text():
	var parts = []
	for label in [
		_info.get("_card_title"),
		_info.get("_card_role"),
		_info.get("_card_details"),
		_info.get("_card_body")
	]:
		parts.append(label.get_parsed_text() if label is RichTextLabel else label.text)
	return "\n".join(parts)


func _select(unit):
	MatchSignals.deselect_all_units.emit()
	unit.find_child("Selection").select()
	await _frames(3)
	_info.call("_refresh")
	await _frames(2)


func _check_mine_card_and_routes():
	var deposits = _iron_deposits_by_distance().filter(
		func(deposit): return deposit.global_position.distance_to(_depot.global_position) > 22.0
	)
	var deposit = deposits[0]
	var towards = (_depot.global_position_yless - deposit.global_position_yless).normalized()
	var mine = _spawn(MineScene, deposit.global_position_yless + towards * (deposit.radius + 1.3))
	_mines.append(mine)
	await _frames(5)
	Engine.time_scale = 4.0
	var linked = await _wait_for(
		func():
			return HaulerLinks.links_for(mine).any(
				func(link): return link["kind"] in ["COLLECT", "WAITING", "LEAVING"]
			),
		4000
	)
	_expect(linked, "haulers are linked to the new mine: " + str(_kinds(mine)))
	for i in range(2):
		_spawn(HaulerScene, _depot.global_position_yless + Vector3(4 + i * 2, 0, 4))
	var busy = await _wait_for(_mine_is_busy.bind(mine), 6000)
	Engine.time_scale = 1.0
	_expect(busy, "more haulers come for the mine's ore: " + str(_kinds(mine)))
	await _select(mine)
	var text = _card_text()
	_expect(_info.get("_card").visible, "selecting the mine opens its card")
	_expect(text.contains(tr("MINE")), "the card names the mine: " + text.get_slice("\n", 0))
	_expect(text.contains(tr("ROLE_RESOURCE")), "the card says it is a resource building")
	_expect(text.contains(tr("MINE_INFO").left(30)), "the card explains what a mine does")
	_expect(text.contains(tr("TRUCK_NAME").format([""]).strip_edges()), "the card lists haulers")
	var routes = _match.find_child("HaulerRouteLines", true, false)
	await _frames(10)
	_expect(routes != null and routes.get_drawn_count() > 0, "the trucks' routes are drawn")
	camera_on(mine.global_position.lerp(_depot.global_position, 0.5), 24)
	await _wait_seconds(1.0)
	await _shot("1-mine-card-and-truck-routes")
	MatchSignals.deselect_all_units.emit()
	await _frames(2)
	_info.call("_on_mouse_entered", mine)
	Input.warp_mouse(get_viewport().get_camera_3d().unproject_position(mine.global_position))
	await _frames(3)
	var tip = _info.get("_tip_body").text
	_expect(
		tip.contains(tr("HOVER_TRUCKS").get_slice(":", 0)), "hovering the mine counts its haulers"
	)
	await _shot("1b-mine-hover")
	_info.call("_on_mouse_exited", mine)
	print(text)


func _check_truck_card():
	var truck = null
	for link in HaulerLinks.links_for(_mines[0]):
		if link["unit"] is Hauler and (truck == null or link["kind"] != "WAITING"):
			truck = link["unit"]
	if truck == null:
		truck = _haulers()[0]
	await _select(truck)
	var text = _card_text()
	var job = Text.job_line(truck)
	_expect(text.contains(job.left(12)), "a selected truck shows its job: " + job)
	_expect(job != tr("JOB_IDLE"), "the truck has a job")
	camera_on(truck.global_position, 30)
	await _wait_seconds(0.5)
	await _shot("2-truck-card-and-route")
	# clicking a truck on the mine's card selects it
	await _select(_mines[0])
	_info.call("_on_link_clicked", str(truck.get_instance_id()))
	await _frames(3)
	_expect(truck.is_in_group("selected_units"), "clicking a truck on the card selects it")


func _check_hover_tip():
	MatchSignals.deselect_all_units.emit()
	await _frames(2)
	var factory = _spawn(
		load("res://source/match/units/VehicleFactory.tscn"),
		_depot.global_position_yless + Vector3(-7, 0, 5)
	)
	await _frames(5)
	camera_on(factory.global_position, 26)
	await _frames(5)
	var camera = get_viewport().get_camera_3d()
	Input.warp_mouse(camera.unproject_position(factory.global_position))
	_info.call("_on_mouse_entered", factory)
	await _frames(3)
	var tip = _info.get("_tip")
	var title = _info.get("_tip_title").text
	_expect(
		tip.visible and title.contains(tr("VEHICLE_FACTORY")), "hovering shows the name: " + title
	)
	await _shot("4-hover-tip")
	_info.call("_on_mouse_exited", factory)
	await _select(factory)
	var text = _card_text()
	_expect(text.contains(tr("ROLE_FACTORY")), "a factory card says it is a factory")
	_expect(text.contains(tr("TANK")), "the factory card lists what it builds")
	await _shot("5-factory-card")


func _check_depot_and_rival():
	await _select(_depot)
	var text = _card_text()
	_expect(text.contains(tr("ROLE_HEADQUARTERS")), "the city centre card says what it is")
	await _shot("6-city-centre-card")
	var rival_depot = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player != _human:
			rival_depot = unit
			break
	if rival_depot == null:
		_expect(false, "the rival has a city centre")
		return
	await _select(rival_depot)
	text = _card_text()
	_expect(_info.get("_card").visible, "a rival building opens a card too")
	_expect(text.contains(tr("INFO_ENEMY").format([""]).strip_edges()), "it says who owns it")
	var body = _info.get("_card_body").get_parsed_text()
	_expect(not body.contains(tr("INFO_HAULERS")), "it does not list the rival's haulers")
	camera_on(rival_depot.global_position, 30)
	await _wait_seconds(0.5)
	await _shot("7-rival-building-card")


func _kinds(building):
	return HaulerLinks.links_for(building).map(func(link): return link["kind"])


func _mine_is_busy(mine):
	var kinds = _kinds(mine)
	return kinds.size() >= 2 and (kinds.has("COLLECT") or kinds.has("BRINGING_GOODS"))


func _check_site_card():
	var away = (_mines[0].global_position_yless - _depot.global_position_yless).normalized()
	var spot = _depot.global_position_yless + away.rotated(Vector3.UP, 0.9) * 20.0
	var site = _spawn(PylonScene, spot, false)
	await _frames(5)
	Engine.time_scale = 4.0
	var served = await _wait_for(_site_is_served.bind(site), 4000)
	Engine.time_scale = 1.0
	_expect(served, "a hauler is linked to a construction site: " + str(_kinds(site)))
	await _select(site)
	var text = _card_text()
	_expect(text.contains(tr("INFO_BUILDING").get_slice(":", 0)), "the site card shows progress")
	camera_on(site.global_position.lerp(_depot.global_position, 0.5), 24)
	await _wait_seconds(0.5)
	await _shot("3-site-card")
	print(text)


func _site_is_served(site):
	var kinds = _kinds(site)
	return kinds.has("BRINGING_MATERIALS") or kinds.has("COMING_FOR_MATERIALS")
