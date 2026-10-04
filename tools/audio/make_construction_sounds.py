"""Synthesizes the sound track of the starter city build-up (assets/audio/construction/).

The track is one file timed to tools/blender/construction_timeline.json, the same timeline the
Blender script animates, so every hammer swing, stage landing, scaffold clatter and crane slew
is heard when it is seen. Like the other audio scripts, it is built from noise and sine waves
with numpy, so it is original work released under the project's license.

    python3 tools/audio/make_construction_sounds.py

Needs numpy and ffmpeg (with libvorbis). Rebuild it whenever the timeline changes.
"""

import json
import os

import numpy as np

import make_war_sounds as war

RATE = war.RATE
HERE = os.path.dirname(os.path.abspath(__file__))
TIMELINE = json.load(open(os.path.join(HERE, "..", "blender", "construction_timeline.json")))
war.OUT_DIR = os.path.join(HERE, "..", "..", "assets", "audio", "construction")
rng = np.random.default_rng(2026)


def place(track, sound, t, gain=1.0):
    start = int(t * RATE)
    if start >= len(track):
        return
    end = min(len(track), start + len(sound))
    track[start:end] += sound[: end - start] * gain


def hammer_hit():
    """metal-on-steel clink: a few inharmonic partials over a short knock"""
    t = war.times(0.35)
    base = rng.uniform(1500, 2100)
    ring = sum(
        np.sin(2 * np.pi * base * ratio * t) * np.exp(-t * decay) * amp
        for ratio, decay, amp in ((1.0, 22, 1.0), (2.76, 30, 0.5), (5.4, 45, 0.25))
    )
    knock = war.filtered_noise(len(t), 300, 5000) * np.exp(-t * 90)
    return 0.5 * ring + 0.6 * knock


def thud(heavy=1.0):
    """a stage settling: low boom plus gritty rubble"""
    t = war.times(1.0)
    body = war.boom(t, 110 * heavy, 45, 9.0)
    grit = war.filtered_noise(len(t), 200, 3000) * np.exp(-t * 14)
    return war.outdoor_tail(body + 0.35 * grit, 0.8, 5.0, 0.3)


def clatter(seconds=0.5):
    """scaffold poles knocking together"""
    out = np.zeros(int(seconds * RATE) + RATE // 2)
    for _ in range(9):
        t = war.times(0.12)
        f = rng.uniform(600, 1300)
        clank = np.sin(2 * np.pi * f * t) * np.exp(-t * 40) + 0.4 * war.filtered_noise(
            len(t), 800, 6000
        ) * np.exp(-t * 70)
        place(out, clank, rng.uniform(0, seconds), rng.uniform(0.3, 0.7))
    return out


def motor(seconds):
    """crane slewing motor: geared whine with a soft start and stop"""
    t = war.times(seconds)
    wobble = 1.0 + 0.03 * np.sin(2 * np.pi * 3.0 * t)
    phase = 2 * np.pi * np.cumsum(140 * wobble) / RATE
    whine = np.sin(phase) + 0.4 * np.sin(2.01 * phase) + 0.2 * np.sin(3.02 * phase)
    hum = war.filtered_noise(len(t), 60, 500) * 0.5
    env = np.minimum(1.0, np.minimum(t / 0.15, (seconds - t) / 0.2))
    return (0.6 * whine + hum) * np.clip(env, 0, 1)


def whoosh():
    t = war.times(0.6)
    return war.filtered_noise(len(t), 150, 1500) * np.sin(np.pi * t / 0.6) ** 2


def done_chime():
    """two bright notes when the city is finished"""
    out = np.zeros(int(1.4 * RATE))
    for i, f in enumerate((660.0, 990.0)):
        t = war.times(1.0)
        note = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t)) * np.exp(-t * 4)
        place(out, note, i * 0.16, 0.5)
    return out


def build_track():
    T = TIMELINE
    track = np.zeros(int((T["length_s"] + 1.0) * RATE))
    # site ambience: wind over sand and a distant generator
    t = war.times(len(track) / RATE)
    track += war.filtered_noise(len(track), 80, 900) * 0.05
    track += np.sin(2 * np.pi * 55 * t) * 0.03
    for stage in T["stages"]:
        place(track, whoosh(), stage["start_s"], 0.25)
        place(track, thud(1.0 if stage["bone"] != "Stage0" else 1.3), stage["land_s"], 0.9)
    for lift in T["scaffold"]:
        place(track, clatter(0.35), lift["up_s"], 0.55)
        place(track, clatter(0.4), lift["down_s"], 0.6)
    for crane in T["cranes"]:
        swings = crane["swing_t_s"]
        for a, b in zip(swings, swings[1:]):
            place(track, motor(b - a - 0.1), a + 0.05, 0.12)
    for w in T["workers"]:
        if w["kind"] != "hammer":
            continue
        period = w.get("period_s", 0.42)
        hit = w["in_s"] + w.get("phase_s", 0.0) + period * 0.85
        while hit < w["out_s"] - 0.3:
            place(track, hammer_hit(), hit, rng.uniform(0.18, 0.3))
            hit += period
    for puff in T["dust"]:
        if puff["bone"].startswith("DustEnd"):
            place(track, thud(0.8), puff["t_s"], 0.4)
    place(track, done_chime(), T["length_s"] - 0.45, 0.6)
    fade = int(0.6 * RATE)
    track[-fade:] *= np.linspace(1, 0, fade)
    return track


if __name__ == "__main__":
    war.write("city_build_up", build_track(), peak=0.8)
