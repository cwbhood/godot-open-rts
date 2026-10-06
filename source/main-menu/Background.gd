extends TextureRect

# The menus' backdrop: a shot of a real match in the current art direction
# (assets/ui/backdrops/<look>.jpg, see source/match/environment/Look.gd), drifting slowly so
# the menus feel alive. Falls back to the scene's painted background for looks without a shot.

const BACKDROPS = "res://assets/ui/backdrops/"
const Look = preload("res://source/match/environment/Look.gd")
const DRIFT_S = 45.0
const DRIFT_ZOOM = 1.08


func _ready():
	var path = BACKDROPS + Look.picked_look() + ".jpg"
	if not ResourceLoader.exists(path):
		path = BACKDROPS + Look.DEFAULT_LOOK + ".jpg"
	if ResourceLoader.exists(path):
		texture = load(path)
	resized.connect(func(): pivot_offset = size / 2.0)
	pivot_offset = size / 2.0
	var drift = create_tween().set_loops()
	drift.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	drift.tween_property(self, "scale", Vector2.ONE * DRIFT_ZOOM, DRIFT_S)
	drift.tween_property(self, "scale", Vector2.ONE, DRIFT_S)
