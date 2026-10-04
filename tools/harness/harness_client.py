#!/usr/bin/env python3
"""Drive a running Ironbound match from Python through the play harness API.

Start the game with the API on:

    ./play.sh serve            (or play.bat serve on Windows)

then, from another terminal:

    python3 tools/harness/harness_client.py state
    python3 tools/harness/harness_client.py do '{"do": "fight", "units": "own:combat", "to": "base"}'
    python3 tools/harness/harness_client.py watch          # one line per 5 game seconds

or from your own script:

    from harness_client import Game
    game = Game()
    print(game.state(units=False)["players"])
    game.do("line", units="own:tank", **{"from": [20, 30], "to": [34, 30]})
    game.wait(10)

Only the standard library is used, so it runs on any Python 3.8+.
"""

import json
import socket
import sys


class Game:
    def __init__(self, host="127.0.0.1", port=7777, timeout=600.0):
        self._socket = socket.create_connection((host, port), timeout=timeout)
        self._reader = self._socket.makefile("r", encoding="utf-8")
        self._next_id = 1

    def send(self, order):
        """sends one order (a dict with "do") and returns the game's answer"""
        order = dict(order)
        order["id"] = self._next_id
        self._next_id += 1
        self._socket.sendall((json.dumps(order) + "\n").encode("utf-8"))
        line = self._reader.readline()
        if not line:
            raise ConnectionError("the game closed the connection")
        return json.loads(line)

    def do(self, what, **fields):
        fields["do"] = what
        return self.send(fields)

    def state(self, units=True):
        return self.do("state", units=units)["state"]

    def wait(self, seconds):
        """lets the given number of game seconds pass"""
        return self.do("wait", seconds=seconds)

    def close(self):
        self._socket.close()


def _summary(state):
    parts = ["t=%5.0fs fps=%3.0f" % (state["t"], state["fps"])]
    for player in state["players"]:
        stock = " ".join("%s:%d" % (key[0], value) for key, value in player["stock"].items())
        parts.append(
            "p%d %s units=%d struct=%d %s"
            % (
                player["index"],
                player.get("personality", "you"),
                player["units"],
                player["structures"],
                stock,
            )
        )
    if state["threats"]:
        parts.append("threats=%d" % len(state["threats"]))
    return " | ".join(parts)


def main(argv):
    port = 7777
    args = [arg for arg in argv if not arg.startswith("--port=")]
    for arg in argv:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    game = Game(port=port)
    if args[0] == "state":
        print(json.dumps(game.state(units="--units" in args), indent=2))
    elif args[0] == "do":
        print(json.dumps(game.send(json.loads(args[1])), indent=2))
    elif args[0] == "watch":
        every = float(args[1]) if len(args) > 1 else 5.0
        try:
            while True:
                print(_summary(game.state(units=False)), flush=True)
                game.wait(every)
        except KeyboardInterrupt:
            pass
    else:
        print("unknown command %r; try state, do or watch" % args[0])
        return 2
    game.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
