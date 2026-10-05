extends Node

# Ironbound keeps its settings, replays, maps and crash reports in its own user folder
# (%APPDATA%/Ironbound, ~/.local/share/Ironbound, ~/Library/Application Support/Ironbound).
# Builds named "Open RTS" used Godot's shared folder, .../Godot/app_userdata/Open RTS; on the
# first start, copy everything over from there once (files that already exist are kept). Runs
# as the first autoload so later autoloads already read the copied options.

const OLD_FOLDER_NAME = "Open RTS"
const MARKER = "user://.migrated_from_open_rts"


func _init():
	var new_dir = OS.get_user_data_dir()
	if FileAccess.file_exists(MARKER):
		return
	var old_dir = _old_user_dir()
	if old_dir == "" or not DirAccess.dir_exists_absolute(old_dir):
		return
	var copied = _copy_tree(old_dir, new_dir)
	var marker = FileAccess.open(MARKER, FileAccess.WRITE)
	if marker != null:
		marker.store_line(old_dir)
	print("Copied %d files from %s to %s" % [copied, old_dir, new_dir])


func _old_user_dir():
	var data_dir = OS.get_data_dir()
	if data_dir == "":
		return ""
	for godot_dir in ["Godot", "godot"]:  # Linux uses the lower-case name
		var path = data_dir.path_join(godot_dir).path_join("app_userdata").path_join(
			OLD_FOLDER_NAME
		)
		if DirAccess.dir_exists_absolute(path):
			return path
	return ""


func _copy_tree(from_dir, to_dir):
	var copied = 0
	DirAccess.make_dir_recursive_absolute(to_dir)
	var dir = DirAccess.open(from_dir)
	if dir == null:
		return 0
	for file_name in dir.get_files():
		var target = to_dir.path_join(file_name)
		if FileAccess.file_exists(target):
			continue
		if DirAccess.copy_absolute(from_dir.path_join(file_name), target) == OK:
			copied += 1
	for sub_dir in dir.get_directories():
		if sub_dir in ["logs", "shader_cache", "vulkan", "objectdb_snapshots"]:
			continue
		copied += _copy_tree(from_dir.path_join(sub_dir), to_dir.path_join(sub_dir))
	return copied
