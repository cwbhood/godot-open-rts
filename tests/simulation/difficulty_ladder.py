#!/usr/bin/env python3
"""Plays AI difficulties against each other with the same play style and reports who wins.

    python3 tests/simulation/difficulty_ladder.py --style=balanced --seconds=1500 \
        --pairs=very_easy:normal,easy:normal,normal:normal,hard:normal,brutal:normal \
        --jobs=3 --out=/tmp/ladder

Every pair is played twice with the sides swapped, so neither difficulty keeps the better
start. Each match runs tests/simulation/Simulate.tscn under a virtual display (it needs a
renderer for the navigation meshes) and writes its JSON summary to --out. The script then
prints a Markdown table and writes ladder.md and ladder.csv to --out.

Who won: a player with no units left is eliminated. When both are still standing at the
end, the one with the higher score is ahead on points, where
score = goods delivered + 15 x military units alive + 10 x enemy units destroyed.
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


def play(args, a, b, run):
    name = "%s_%s_vs_%s_%s_%d" % (args.style, a, args.style, b, run)
    out = os.path.join(args.out, name + ".json")
    log = os.path.join(args.out, name + ".log")
    if not os.path.exists(out) or args.force:
        command = [
            "xvfb-run", "-a", "-s", "-screen 0 640x360x24",
            args.godot, "--rendering-driver", "opengl3", "--resolution", "640x360",
            "--path", ROOT, "res://tests/simulation/Simulate.tscn", "--",
            "--map=" + args.map, "--ai=%s,%s" % (args.style, args.style),
            "--difficulty=%s,%s" % (a, b), "--seconds=%d" % args.seconds,
            "--time-scale=%s" % args.time_scale, "--log-every=120", "--out=" + out,
        ]
        with open(log, "w") as log_file:
            subprocess.run(command, stdout=log_file, stderr=subprocess.STDOUT,
                           timeout=args.seconds * 3 + 600)
    if not os.path.exists(out):
        return {"name": name, "error": "no summary, see " + log}
    with open(out) as summary_file:
        summary = json.load(summary_file)
    players = summary["samples"][-1]["players"]
    result = {"name": name, "a": a, "b": b, "players": players}
    alive = [p for p in players if p["units"] > 0]
    if len(alive) == 1:
        result["winner_side"] = alive[0]["player"]
        result["how"] = "eliminated the other"
    else:
        best = max(players, key=score)
        result["winner_side"] = best["player"]
        result["how"] = "ahead on points"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--style", default="balanced")
    parser.add_argument("--pairs",
                        default="very_easy:normal,easy:normal,normal:normal,hard:normal,"
                                "brutal:normal")
    parser.add_argument("--seconds", type=int, default=1500)
    parser.add_argument("--time-scale", default="4")
    parser.add_argument("--map", default="res://source/match/maps/PlainAndSimple.tscn")
    parser.add_argument("--runs", type=int, default=2, help="runs per pair, sides alternate")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--out", default="/tmp/difficulty-ladder")
    parser.add_argument("--force", action="store_true", help="replay matches already done")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    matches = []
    for pair in args.pairs.split(","):
        first, second = pair.split(":")
        for run in range(args.runs):
            a, b = (first, second) if run % 2 == 0 else (second, first)
            matches.append((a, b, run))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda m: play(args, *m), matches))
    rows = []
    for result in results:
        if "error" in result:
            print("ERROR", result["name"], result["error"], file=sys.stderr)
            continue
        for player in result["players"]:
            rows.append({
                "match": result["name"],
                "difficulty": player["difficulty"],
                "side": player["player"] + 1,
                "won": player["player"] == result["winner_side"],
                "how": result["how"],
                "delivered": sum(player["delivered"].values()),
                "army": player["army"],
                "kills": player["kills"],
                "losses": player["losses"],
                "structures": player["structures"],
                "tier": player["tier"],
                "units": player["units"],
                "score": score(player),
            })
    with open(os.path.join(args.out, "ladder.csv"), "w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    lines = [
        "| Match | Side | Difficulty | Result | Goods delivered | Army | Destroyed | Lost "
        "| Buildings | Tier |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        result = ("won, " + row["how"]) if row["won"] else "lost"
        lines.append("| %s | %d | %s | %s | %d | %d | %d | %d | %d | %d |" % (
            row["match"], row["side"], row["difficulty"], result, row["delivered"], row["army"],
            row["kills"], row["losses"], row["structures"], row["tier"]))
    table = "\n".join(lines)
    with open(os.path.join(args.out, "ladder.md"), "w") as md_file:
        md_file.write(table + "\n")
    print(table)


if __name__ == "__main__":
    main()
