extends PanelContainer

# The in-game manual (F1): a list of topics on the left, the explanation on the right.
# Texts are translation keys HELP_<TOPIC>_TITLE / HELP_<TOPIC>_BODY in guide.csv.

const TOPICS = [
	"BASICS",
	"CONSTRUCTORS",
	"AUTO_EXPAND",
	"HELPER",
	"RESOURCES",
	"SUPPLY_LINES",
	"DELIVERY_JOBS",
	"STORAGE",
	"TRAINS",
	"ROADS",
	"POWER",
	"CITY_TIERS",
	"TRADE",
	"COMBAT",
	"COMMANDS",
	"AIRCRAFT",
	"LIMITS",
]

var _topics = ItemList.new()
var _body = RichTextLabel.new()


func _ready():
	name = "HelpWindow"
	custom_minimum_size = Vector2(820, 520)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var box = VBoxContainer.new()
	margin.add_child(box)
	var header = HBoxContainer.new()
	box.add_child(header)
	var title = Label.new()
	title.text = tr("HELP_TITLE")
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close = Button.new()
	close.text = tr("HELP_CLOSE")
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(hide)
	header.add_child(close)
	var split = HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 12)
	box.add_child(split)
	_topics.custom_minimum_size = Vector2(250, 0)
	_topics.focus_mode = Control.FOCUS_NONE
	for topic in TOPICS:
		_topics.add_item(tr("HELP_{0}_TITLE".format([topic])))
	_topics.item_selected.connect(show_topic_at)
	split.add_child(_topics)
	_body.bbcode_enabled = true
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("normal_font_size", 16)
	_body.add_theme_font_size_override("bold_font_size", 16)
	split.add_child(_body)
	show_topic("BASICS")
	hide()


func _unhandled_key_input(event):
	if visible and event.pressed and event.keycode == KEY_ESCAPE:
		hide()
		get_viewport().set_input_as_handled()


func _process(_delta):
	if visible:
		position = ((get_viewport_rect().size - size) / 2.0).round()


func show_topic(topic):
	show_topic_at(max(0, TOPICS.find(topic)))


func show_topic_at(index):
	_topics.select(index)
	var topic = TOPICS[index]
	_body.text = "[b]{0}[/b]\n\n{1}".format(
		[tr("HELP_{0}_TITLE".format([topic])), tr("HELP_{0}_BODY".format([topic]))]
	)
	_body.scroll_to_line(0)
