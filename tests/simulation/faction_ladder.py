#!/usr/bin/env python3
"""Plays the two factions against each other, AI against AI, and reports who wins.

    python3 tests/simulation/faction_ladder.py --factions=foundry,syndicate \
        --maps=PlainAndSimple,OilAndIron,TwinBasins --runs=4 --difficulty=normal \
        --style=balanced --seconds=1800 --jobs=3 --out=/tmp/faction-ladder

Every map is played --runs times with the sides swapped every other run, both AIs with
the same play style and difficulty, so only the faction differs. Each match runs
tests/simulation/Simulate.tscn under a virtual display and ends early once one side has no
units left (--stop-on-win=1). Writes ladder.md, ladder.csv and results.json to --out and
prints win rates per faction and map plus match lengths.

Who won: a player with no units left is eliminated. When both are still standing at the
end, the one with the higher score is ahead on points, where
score = goods delivered + 15 x military units alive + 10 x enemy units destroyed
(the same rule as difficulty_ladder.py).
"""

import argparse
import concurrent.futures
import csv
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def score(player):
    return sum(player["delivered"].values()) + 15 * player["army"] + 10 * player["kills"]


def play(args, map_name, factions, run):
    name = "%s_%s_vs_%s_%d" % (map_name, factions[0], factions[1], run)
    out = os.path.join(args.out, name + ".json")
    log = os.path.join(args.out, name + ".log")
    if not os.path.exists(out) or args.force:
        command = [
            "xvfb-run", "-a", "-s", "-screen 0 640x360x24",
            args.godot, "--rendering-driver", "opengl3", "--resolution", "640x360",
            "--path", ROOT, "res://tests/simulation/Simulate.tscn", "--",
            "--map=res://source/match/maps/%s.tscn" % map_name,
            "--ai=%s,%s" % (args.style, args.style),
            "--difficulty=%s,%s" % (args.difficulty, args.difficulty),
            "--factions=%s,%s" % factions, "--seconds=%d" % args.seconds,
            "--time-scale=%s" % args.time_scale, "--log-every=120", "--stop-on-win=1",
            "--summary=" + out,
        ]
        env = dict(os.environ)
        with open(log, "w") as log_file:
            try:
                subprocess.run(command, stdout=log_file, stderr=subprocess.STDOUT, env=env,
                               timeout=args.seconds * 4 + 900)
            except subprocess.TimeoutExpired:
                pass
    if not os.path.exists(out):
        return {"name": name, "error": "no summary, see " + log}
    with open(out) as summary_file:
        summary = json.load(summary_file)
    with open(log) as log_file:
        script_errors = sum(1 for line in log_file if "SCRIPT ERROR" in line)
    players = summary["samples"][-1]["players"]
    result = {"name": name, "map": map_name, "players": players,
              "length_s": summary.get("ended_at_s", summary["samples"][-1]["t"]),
              "script_errors": script_errors}
    alive = [p for p in players if p["units"] > 0]
    if len(alive) == 1:
        result["winner"] = alive[0]["faction"]
        result["how"] = "eliminated"
    else:
        best = max(players, key=score)
        result["winner"] = best["faction"]
        result["how"] = "points"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--factions", default="foundry,syndicate")
    parser.add_argument("--maps", default="PlainAndSimple,OilAndIron,TwinBasins")
    parser.add_argument("--runs", type=int, default=4, help="runs per map, sides alternate")
    parser.add_argument("--difficulty", default="normal")
    parser.add_argument("--style", default="balanced")
    parser.add_argument("--seconds", type=int, default=1800)
    parser.add_argument("--time-scale", default="4")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--out", default="/tmp/faction-ladder")
    parser.add_argument("--force", action="store_true", help="replay matches already done")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    first, second = args.factions.split(",")
    matches = []
    for map_name in args.maps.split(","):
        for run in range(args.runs):
            factions = (first, second) if run % 2 == 0 else (second, first)
            matches.append((map_name, factions, run))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda m: play(args, *m), matches))
    with open(os.path.join(args.out, "results.json"), "w") as json_file:
        json.dump(results, json_file, indent=2)
    rows = []
    for result in results:
        if "error" in result:
            print("ERROR", result["name"], result["error"], file=sys.stderr)
            continue
        for player in result["players"]:
            rows.append({
                "match": result["name"],
                "map": result["map"],
                "faction": player["faction"],
                "side": player["player"] + 1,
                "won": player["faction"] == result["winner"],
                "how": result["how"],
                "length_min": round(result["length_s"] / 60.0, 1),
                "delivered": sum(player["delivered"].values()),
                "army": player["army"],
                "kills": player["kills"],
                "losses": player["losses"],
                "structures": player["structures"],
                "tier": player["tier"],
                "score": score(player),
                "script_errors": result["script_errors"],
            })
    if not rows:
        print("no results", file=sys.stderr)
        sys.exit(1)
    with open(os.path.join(args.out, "ladder.csv"), "w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    lines = [
        "| Match | Side | Faction | Result | Length (min) | Goods | Army | Destroyed | Lost "
        "| Buildings | Tier |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        verdict = ("won, " + row["how"]) if row["won"] else "lost"
        lines.append("| %s | %d | %s | %s | %.1f | %d | %d | %d | %d | %d | %d |" % (
            row["match"], row["side"], row["faction"], verdict, row["length_min"],
            row["delivered"], row["army"], row["kills"], row["losses"], row["structures"],
            row["tier"]))
    lines.append("")
    lines.append("| Map | %s wins | %s wins | Eliminations | Mean length (min) |" % (first, second))
    lines.append("|---|---|---|---|---|")
    done = [r for r in results if "error" not in r]
    for map_name in args.maps.split(",") + ["all"]:
        subset = [r for r in done if map_name == "all" or r["map"] == map_name]
        if not subset:
            continue
        wins_a = sum(1 for r in subset if r["winner"] == first)
        wins_b = sum(1 for r in subset if r["winner"] == second)
        eliminations = sum(1 for r in subset if r["how"] == "eliminated")
        mean = sum(r["length_s"] for r in subset) / len(subset) / 60.0
        lines.append("| %s | %d/%d | %d/%d | %d | %.1f |" % (
            map_name, wins_a, len(subset), wins_b, len(subset), eliminations, mean))
    table = "\n".join(lines)
    with open(os.path.join(args.out, "ladder.md"), "w") as md_file:
        md_file.write(table + "\n")
    print(table)


if __name__ == "__main__":
    main()
