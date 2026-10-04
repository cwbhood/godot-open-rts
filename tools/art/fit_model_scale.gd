extends SceneTree

# Prints, for every unit with a "classic_model" in data/units, the model_scale that makes
# its "model" as long (largest horizontal side) as the classic model is in game.
#   xvfb-run -a godot --path . -s res://tools/art/fit_model_scale.gd

const GameData = preload("res://source/data-model/GameData.gd")


func _initialize():
	for entry in GameData.units():
		if not "classic_model" in entry or not ResourceLoader.exists(entry["model"]):
			continue
		var classic = _size(entry["classic_model"]) * float(entry.get("classic_model_scale", 1.0))
		var current = _size(entry["model"])
		var classic_len = max(classic.x, classic.z)
		var fitted = classic_len / max(current.x, current.z)
		print(
			(
				"%s: classic %.2f x %.2f x %.2f, new at scale 1 %.2f x %.2f x %.2f, fitted scale %.3f"
				% [
					entry["id"],
					classic.x,
					classic.y,
					classic.z,
					current.x,
					current.y,
					current.z,
					fitted,
				]
			)
		)
	quit()


func _size(path):
	var model = load(path).instantiate()
	var box = null
	for node in [model] + model.find_children("*", "MeshInstance3D", true, false):
		if node is MeshInstance3D and node.mesh != null:
			var transform = _to_root(node, model)
			var aabb = transform * node.mesh.get_aabb()
			box = aabb if box == null else box.merge(aabb)
	model.free()
	return box.size if box != null else Vector3.ONE


func _to_root(node, root):
	var transform = Transform3D()
	while node != root:
		transform = node.transform * transform
		node = node.get_parent()
	return transform
