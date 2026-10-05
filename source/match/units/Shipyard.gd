extends "res://source/match/units/Structure.gd"

# Builds boats (data/units/*.json with "produced_by": ["shipyard"]). It has to stand on
# the shore ("placement": "shore" in data/units/shipyard.json, see WaterRules.gd); boats
# come out on the nearest free water.
