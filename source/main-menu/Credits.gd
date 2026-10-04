extends Control

const CREDITS = [
	["CREDITS_IRONBOUND", ["Destin (cwbhood) and contributors"]],
	["CREDITS_BASED_ON", ["Open RTS by Pawel Lampe (Scony) | Lampe Games, MIT licence"]],
	["CREDITS_ENGINE", ["Godot Engine, MIT licence, godotengine.org"]],
	[
		"ASSETS",
		[
			"3D Space Kit by Kenney.nl (CC0)",
			"Ironbound models, textures and sounds: made by the scripts in tools/",
			"Voices: Kokoro-82M (Apache 2.0) via kokoro-onnx (MIT). Full list: ASSET_CREDITS.md",
		]
	],
	["CREDITS_FONTS", ["Barlow, Big Shoulders Stencil Display, IBM Plex Mono (SIL OFL 1.1)"]],
]

@onready var _rich_text_label = find_child("RichTextLabel")


func _ready():
	var lines = []
	for section in CREDITS:
		lines.append("[color=#f2a93b][b]%s[/b][/color]" % tr(section[0]).to_upper())
		lines.append("\n".join(section[1]))
		lines.append("")
	_rich_text_label.text = "[center]%s[/center]" % "\n".join(lines).strip_edges()


func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
