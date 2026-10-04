"""Writes data/maps/twin_isles.json: the island demo map. Run from the repository root.

Two players, point-symmetric around the centre: each starts on its own island with a
basic economy (iron x2, oil, copper, timber), and a contested centre island holds the
rich deposits. One shallow ford links each start island to the centre (land units can
wade it); everything else is deep water, so boats and amphibious units can go around.
Edit the numbers below, not the JSON.
"""

import json
import os

SIZE = 160


def mirror(p):
    return [round(SIZE - p[0], 2), round(SIZE - p[1], 2)]


def circle(c, r):
    return {"center": c, "radius": r}


start_islands = [circle([38, 122], 27), circle([20, 100], 15), circle([62, 142], 13)]
centre_islands = [circle([80, 80], 18), circle([67, 67], 11), circle([93, 93], 11)]
# rocky lookout islets with no ford: only boats, amphibious units and aircraft get there
islets = [circle([26, 38], 7)]
start_deposits = [
    {"kind": "iron", "center": [22, 104]},
    {"kind": "iron", "center": [36, 102]},
    {"kind": "oil", "center": [58, 136]},
    {"kind": "copper", "center": [28, 138]},
    {"kind": "timber", "center": [22, 115]},
]
centre_deposits = [  # mirrored below, so each side has an equally close share
    {"kind": "oil", "center": [73, 73], "amount": 1400},
    {"kind": "copper", "center": [66, 80], "amount": 900},
    {"kind": "iron", "center": [62, 64], "amount": 1200},
]
start_forests = [{"kind": "acacia", "circles": [circle([14, 112], 3.0), circle([16, 118], 2.5)]}]
centre_forests = [{"kind": "mixed", "circles": [circle([74, 89], 2.5)]}]
ford = {"from": [53, 107], "to": [71, 89], "radius": 3.5, "depth": "shallow"}

layout = {
    "sea": True,
    "spawns": [[38, 124], mirror([38, 124])],
    "islands": start_islands
    + [circle(mirror(c["center"]), c["radius"]) for c in start_islands]
    + centre_islands
    + islets
    + [circle(mirror(c["center"]), c["radius"]) for c in islets],
    "water": [ford, dict(ford, **{"from": mirror(ford["from"]), "to": mirror(ford["to"])})],
    "lakes": [],
    "forests": [],
    "outcrops": [circle([80, 80], 2.5), circle([26, 38], 2.0), circle(mirror([26, 38]), 2.0)],
    "deposits": [],
}
for forest in start_forests + centre_forests:
    layout["forests"].append(forest)
    layout["forests"].append(
        dict(forest, circles=[circle(mirror(c["center"]), c["radius"]) for c in forest["circles"]])
    )
for deposit in start_deposits + centre_deposits:
    layout["deposits"].append(deposit)
    layout["deposits"].append(dict(deposit, center=mirror(deposit["center"])))

definition = {
    "id": "twin_isles",
    "name": "Twin Isles",
    "scene": "res://source/match/maps/TwinIsles.tscn",
    "players": 2,
    "size": [SIZE, SIZE],
    "generator": {"seed": 11},
    "layout": layout,
}
path = os.path.join("data", "maps", "twin_isles.json")
with open(path, "w") as f:
    json.dump(definition, f, indent=2)
    f.write("\n")
print("wrote", path)
