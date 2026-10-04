extends Node

# Lets a program outside Godot play the match: a TCP server on 127.0.0.1 that takes one JSON
# order per line and answers with one JSON line. Orders are the HarnessApi commands, e.g.
#
#   {"do": "state", "units": false}
#   {"do": "line", "units": "own:tank", "from": [20, 30], "to": [30, 30]}
#   {"do": "wait", "seconds": 10}
#
# An order may carry an "id"; the answer repeats it. tools/harness/harness_client.py is a
# small Python client. Only local programs can connect.

var api = null
var port = 7777

var _server = TCPServer.new()
var _clients = []  # [{peer, buffer, busy}]


func _ready():
	name = "ApiServer"
	process_mode = Node.PROCESS_MODE_ALWAYS
	var error = _server.listen(port, "127.0.0.1")
	if error != OK:
		push_error("harness: cannot listen on port %d (%s)" % [port, error_string(error)])
	else:
		print("HARNESS API listening on 127.0.0.1:%d" % port)


func _exit_tree():
	_server.stop()


func _process(_delta):
	while _server.is_connection_available():
		var peer = _server.take_connection()
		peer.set_no_delay(true)
		_clients.append({"peer": peer, "buffer": PackedByteArray(), "busy": false})
	for client in _clients.duplicate():
		var peer = client["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(client)
			continue
		var available = peer.get_available_bytes()
		if available > 0:
			var chunk = peer.get_data(available)
			if chunk[0] == OK:
				client["buffer"].append_array(chunk[1])
		if not client["busy"]:
			_handle_next_line(client)


func _handle_next_line(client):
	var newline = client["buffer"].find(10)
	if newline == -1:
		return
	var line = client["buffer"].slice(0, newline).get_string_from_utf8().strip_edges()
	client["buffer"] = client["buffer"].slice(newline + 1)
	if line == "":
		return
	client["busy"] = true
	var order = JSON.parse_string(line)
	var answer = null
	if not order is Dictionary:
		answer = {"ok": false, "error": "send one JSON object per line"}
	else:
		answer = await api.command(order)
		if order.has("id"):
			answer["id"] = order["id"]
	var peer = client["peer"]
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(answer) + "\n").to_utf8_buffer())
	client["busy"] = false
