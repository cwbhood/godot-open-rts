"""Composes and renders Ironbound's music: the menu theme, two calm match tracks, a tension
loop, a battle loop and the victory and defeat stings.

Every note is written in this file. The parts are played by the GeneralUser GS SoundFont
(see SOUNDFONT below) through tinysoundfont, one synth per part, and then mixed with numpy:
panning, a convolution hall reverb, gentle compression, loudness normalisation (EBU R128
integrated loudness, about -16 LUFS) and a peak limiter. Loops are made seamless by folding
the reverb and release tail that runs past the loop point back onto the start.

    pip install numpy tinysoundfont --no-deps   # tinysoundfont's pyaudio extra is not needed
    python3 tools/audio/make_music.py           # writes assets/audio/music/*.ogg
    python3 tools/audio/make_music.py --only battle,victory
    python3 tools/audio/make_music.py --check   # durations, loudness, envelopes, spectra
    python3 tools/audio/make_music.py --check --plots DIR   # also spectrogram PNGs

Needs ffmpeg with libvorbis. The SoundFont (32 MB) is downloaded once into
~/.cache/ironbound-music/ and verified against SOUNDFONT_SHA256; pass --soundfont FILE to use
a local copy. The music is original work released under the project's MIT license; the
SoundFont's own license (free use in music, private or commercial) is quoted in
ASSET_CREDITS.md.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import wave

import numpy as np

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "music")
SOUNDFONT_URL = (
    "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"
)
SOUNDFONT_LICENSE_URL = (
    "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/documentation/LICENSE.txt"
)
SOUNDFONT_SHA256 = "9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe"  # v2.0.3
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".cache", "ironbound-music")
OGG_QUALITY = 3
TAIL_S = 7.0  # rendered past the last bar for releases and reverb
STING_TAIL_S = 4.0  # how long a piece that does not loop rings on after its last bar

# General MIDI programs (0-based) of the GeneralUser GS bank
NYLON_GUITAR = 24
ACOUSTIC_BASS = 32
VIOLIN = 40
CELLO = 42
CONTRABASS = 43
TREMOLO_STRINGS = 44
PIZZICATO = 45
HARP = 46
TIMPANI = 47
FAST_STRINGS = 48
SLOW_STRINGS = 49
CHOIR = 52
TROMBONE = 57
TUBA = 58
FRENCH_HORNS = 60
BRASS_SECTION = 61
OBOE = 68
CLARINET = 71
FLUTE = 73
SHAKUHACHI = 77  # breathy, close to a ney
WARM_PAD = 89
HALO_PAD = 94
SITAR = 104
TAIKO = 116

# drum keys (General MIDI percussion map)
KICK = 36
SIDE_STICK = 37
LOW_TOM = 41
MID_TOM = 45
HIGH_TOM = 48
CRASH = 49
RIDE_BELL = 53
TAMBOURINE = 54
SPLASH = 55
HIGH_BONGO = 60
LOW_BONGO = 61
MUTE_CONGA = 62
OPEN_CONGA = 63
LOW_CONGA = 64
SHAKER = 70  # maracas
WIND_CHIMES = 81  # open triangle in the standard kit
KIT_STANDARD = 0
KIT_ORCHESTRA = 48

NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def key(name):
    """'D4' -> 62, 'F#3' -> 54, 'Bb2' -> 46"""
    match = re.fullmatch(r"([A-G])([#b]?)(-?\d)", name)
    assert match, name
    letter, accidental, octave = match.groups()
    offset = NOTE_OFFSETS[letter] + {"#": 1, "b": -1, "": 0}[accidental]
    return 12 * (int(octave) + 1) + offset


def keys(names):
    return [key(name) for name in names.split()]


def parse_phrase(text):
    """'A4:1.5 Bb4:.5 | D4+A4:2 r:1' -> [(offset, duration, [keys])]; '|' is only visual"""
    notes = []
    at = 0.0
    for token in text.split():
        if token == "|":
            continue
        pitch, duration = token.split(":")
        duration = float(duration)
        if pitch != "r":
            notes.append((at, duration, [key(name) for name in pitch.split("+")]))
        at += duration
    return notes, at


class Part:
    """one instrument: notes in beats, expression (CC11) ramps, mix settings"""

    def __init__(self, score, name, program, **settings):
        self.score = score
        self.name = name
        self.program = program
        self.drums = settings.get("drums", False)
        self.bank = 128 if self.drums else 0
        self.gain_db = settings.get("gain_db", 0.0)
        self.pan = settings.get("pan", 0.0)
        self.reverb = settings.get("reverb", 0.25)
        self.humanize_ms = settings.get("humanize_ms", 7.0)
        self.vel_jitter = settings.get("vel_jitter", 5)
        self.low_cut = settings.get("low_cut", 0.0)  # Hz; keeps pads and strings off the bass
        self.notes = []  # (beat, duration, key, velocity)
        self.controls = []  # (beat, controller, value)

    def note(self, beat, duration, a_key, velocity):
        self.notes.append((beat, duration, a_key, int(np.clip(velocity, 1, 127))))

    def chord(self, beat, duration, chord_keys, velocity, strum=0.0):
        for index, a_key in enumerate(chord_keys):
            self.note(beat + index * strum, duration - index * strum, a_key, velocity)

    def phrase(self, beat, text, velocity=80, transpose=0, legato=0.98, tremolo=None, accent=8):
        """plays a written line; tremolo=step repeats long notes like an oud's plectrum"""
        notes, length = parse_phrase(text)
        for offset, duration, chord_keys in notes:
            # a little more weight on notes that land on the beat, a little on longer ones
            on_beat = abs((beat + offset) - round(beat + offset)) < 0.01
            vel = velocity + (accent if on_beat else 0) + min(duration, 2.0) * 3
            for a_key in chord_keys:
                if tremolo and duration >= 1.0:
                    steps = int(round(duration / tremolo))
                    for step in range(steps):
                        decay = 1.0 - 0.35 * (step / max(steps - 1, 1))
                        self.note(beat + offset + step * tremolo, tremolo, a_key + transpose,
                                  vel * (decay if step else 1.0) - (0 if step == 0 else 12))
                else:
                    self.note(beat + offset, duration * legato, a_key + transpose, vel)
        return beat + length

    def swell(self, beat_from, beat_to, value_from, value_to, steps_per_beat=8):
        """expression ramp, the way a section swells and fades"""
        steps = max(1, int((beat_to - beat_from) * steps_per_beat))
        for step in range(steps + 1):
            fraction = step / steps
            shaped = fraction * fraction * (3 - 2 * fraction)  # smooth ends
            value = value_from + (value_to - value_from) * shaped
            self.controls.append((beat_from + fraction * (beat_to - beat_from), 11, int(value)))

    def hits(self, beat, pattern, a_key, loud=100, soft=60, step=0.25, chance=1.0):
        """drum pattern: 'X' accent, 'x' normal, 'o' ghost, '.' rest"""
        rng = self.score.rng
        for index, char in enumerate(pattern.replace(" ", "")):
            if char == "." or rng.random() > chance:
                continue
            velocity = {"X": loud + 15, "x": loud, "o": soft}[char]
            self.note(beat + index * step, step, a_key, velocity)

    def roll(self, beat, duration, a_key, vel_from, vel_to, step=0.125):
        steps = int(duration / step)
        for index in range(steps):
            fraction = index / max(steps - 1, 1)
            self.note(beat + index * step, step, a_key, vel_from + (vel_to - vel_from) * fraction)


class Score:
    def __init__(self, name, bpm, bars, beats_per_bar=4, loop=True, lufs=-16.0, seed=1):
        self.name = name
        self.bpm = bpm
        self.bars = bars
        self.beats_per_bar = beats_per_bar
        self.loop = loop
        self.lufs = lufs
        self.rng = np.random.default_rng(seed)
        self.parts = []

    def part(self, name, program, **settings):
        part = Part(self, name, program, **settings)
        self.parts.append(part)
        return part

    def bar(self, index, beat=0.0):
        return index * self.beats_per_bar + beat

    @property
    def seconds(self):
        return self.bars * self.beats_per_bar * 60.0 / self.bpm

    def sample(self, beat):
        return int(round(beat * 60.0 / self.bpm * RATE))


# --- harmony helpers ------------------------------------------------------------------------

# D phrygian dominant (D Eb F# G A Bb C): the Arabic hijaz colour the whole score leans on
D_HIJAZ = [0, 1, 4, 5, 7, 8, 10]


def scale_key(root, scale, degree):
    octave, step = divmod(degree, len(scale))
    return root + 12 * octave + scale[step]


def arpeggio(part, beat, beats, chord_keys, velocity, pattern=(0, 1, 2, 3, 2, 1, 3, 2), step=0.5,
             ring=1.6):
    """broken chord in eighths over 'beats' beats; notes ring on like a plucked string"""
    for index in range(int(beats / step)):
        a_key = chord_keys[pattern[index % len(pattern)] % len(chord_keys)]
        accent = 10 if index % int(1 / step * 2) == 0 else 0
        part.note(beat + index * step, step * ring, a_key, velocity + accent)


def pad(part, beat, beats, chord_keys, velocity, swell=(70, 110, 80)):
    part.chord(beat, beats * 0.995, chord_keys, velocity)
    low, high, end = swell
    part.swell(beat, beat + beats * 0.5, low, high)
    part.swell(beat + beats * 0.5, beat + beats * 0.995, high, end)


def maqsum(part_low, part_high, beat, loud=90, soft=45, fill=False):
    """the Egyptian maqsum: dum tek . tek dum . tek . over one bar, with ghost notes"""
    part_low.hits(beat, "x... .... x... ....", LOW_CONGA, loud, soft)
    part_low.hits(beat, ".... .... .... ..o.", OPEN_CONGA, loud - 15, soft)
    if fill:
        part_high.hits(beat, "x.o. x.xo ..x. xoxx", HIGH_BONGO, loud - 5, soft)
    else:
        part_high.hits(beat, "..x. x.o. o.x. x.o.", HIGH_BONGO, loud - 10, soft)


# --- the main theme ---------------------------------------------------------------------------

THEME_A = (
    "A4:1.5 Bb4:.5 A4:1 G4:1 | F#4:1.5 G4:.5 F#4:.5 Eb4:.5 D4:1 | "
    "D4:.5 Eb4:.5 F#4:1 G4:.5 A4:.5 Bb4:1 | A4:3 r:1"
)
THEME_B = (
    "C5:1.5 Bb4:.5 A4:1 G4:1 | Bb4:1.5 A4:.5 G4:.5 F#4:.5 Eb4:1 | "
    "F#4:1 Eb4:.5 D4:.5 C4:1 Eb4:1 | D4:4"
)
THEME = THEME_A + " | " + THEME_B
# one chord per bar of the theme: Gm/D D Eb D Cm Gm Eb D
THEME_CHORDS = [
    keys("D3 G3 Bb3 D4"),
    keys("D3 A3 D4 F#4"),
    keys("Eb3 G3 Bb3 Eb4"),
    keys("D3 A3 D4 F#4"),
    keys("C3 G3 C4 Eb4"),
    keys("D3 G3 Bb3 D4"),
    keys("Eb3 G3 Bb3 Eb4"),
    keys("D3 A3 D4 F#4"),
]
THEME_BASS = keys("D2 D2 Eb2 D2 C2 G1 Eb2 D2")


def stretch(text, factor):
    """the same line with every duration multiplied"""
    return " ".join(
        token if token == "|" else "{0}:{1}".format(token.split(":")[0],
                                                    float(token.split(":")[1]) * factor)
        for token in text.split()
    )


def compose_menu():
    s = Score("menu_theme", bpm=76, bars=40, lufs=-16.0, seed=11)
    drone = s.part("drone", CONTRABASS, gain_db=-8, reverb=0.3)
    pad_part = s.part("pad", WARM_PAD, gain_db=-12, reverb=0.4, low_cut=120)
    strings = s.part("strings", SLOW_STRINGS, gain_db=-4, reverb=0.45, pan=-0.1, low_cut=90)
    cello = s.part("cello", CELLO, gain_db=-5, reverb=0.35, pan=0.25)
    oud = s.part("oud", NYLON_GUITAR, gain_db=-1, reverb=0.3, pan=-0.2)
    ney = s.part("ney", SHAKUHACHI, gain_db=-5, reverb=0.5, pan=0.15)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-4, reverb=0.45, pan=0.2)
    brass = s.part("brass", BRASS_SECTION, gain_db=-7, reverb=0.4, pan=-0.15)
    choir = s.part("choir", CHOIR, gain_db=-11, reverb=0.55)
    timpani = s.part("timpani", TIMPANI, gain_db=-5, reverb=0.4, humanize_ms=3)
    taiko = s.part("taiko", TAIKO, gain_db=-5, reverb=0.35, humanize_ms=3)
    drum_low = s.part("darbuka_dum", 0, drums=True, gain_db=-4, reverb=0.25, pan=-0.1)
    drum_high = s.part("darbuka_tek", 0, drums=True, gain_db=-8, reverb=0.25, pan=0.2)
    shaker = s.part("shaker", 0, drums=True, gain_db=-16, reverb=0.2, pan=0.35)
    cymbal = s.part("cymbal", KIT_ORCHESTRA, drums=True, gain_db=-10, reverb=0.5)

    # the D drone runs under the whole piece, breathing in four-bar swells
    for bar in range(0, 40, 4):
        drone.note(s.bar(bar), 16, key("D2"), 70)
        drone.swell(s.bar(bar), s.bar(bar + 2), 60, 105)
        drone.swell(s.bar(bar + 2), s.bar(bar + 4), 105, 60)
        pad_part.chord(s.bar(bar), 16, keys("D3 A3 D4"), 60)

    # intro: strings rise out of the drone, the ney sketches the theme
    pad(strings, s.bar(0), 8, keys("D3 A3 D4"), 60, (20, 85, 70))
    pad(strings, s.bar(2), 8, keys("Eb3 G3 Bb3"), 58, (70, 90, 60))
    ney.phrase(s.bar(1), "A4:3 Bb4:.5 A4:.5 | G4:2 F#4:1 Eb4:1 | D4:4", 72)
    for bar in range(0, 4):
        drum_low.hits(s.bar(bar), "x... .... ..o. ....", LOW_CONGA, 70, 45)

    # A: the oud plays the theme over strings and a light darbuka groove
    start = 4
    oud.phrase(s.bar(start), THEME, 92, tremolo=0.25)
    for index in range(8):
        bar = start + index
        pad(strings, s.bar(bar), 4, THEME_CHORDS[index], 55, (55, 80, 62))
        cello.note(s.bar(bar), 3.9, THEME_BASS[index] + 12, 70)
        maqsum(drum_low, drum_high, s.bar(bar), 80, 40, fill=index == 7)
        shaker.hits(s.bar(bar), "x.o. x.o. x.o. x.o.", SHAKER, 70, 40)

    # B: the horns take the theme, the oud accompanies, taiko and timpani join
    start = 12
    horns.phrase(s.bar(start), THEME, 82, transpose=-12, legato=1.0)
    for index in range(8):
        bar = start + index
        chord = THEME_CHORDS[index]
        arpeggio(oud, s.bar(bar), 4, [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[3] + 12],
                 68)
        pad(strings, s.bar(bar), 4, chord, 64, (65, 95, 75))
        cello.note(s.bar(bar), 3.9, THEME_BASS[index] + 12, 78)
        drone.note(s.bar(bar), 3.9, THEME_BASS[index], 72)
        maqsum(drum_low, drum_high, s.bar(bar), 88, 45, fill=index in (3, 7))
        shaker.hits(s.bar(bar), "x.o. x.o. x.o. x.o.", SHAKER, 75, 45)
        taiko.note(s.bar(bar), 1, key("D2"), 85 if index % 2 == 0 else 70)
    timpani.roll(s.bar(19), 4, key("D2"), 40, 100)

    # C: climax, brass and strings in octaves, choir, full percussion
    start = 20
    brass.phrase(s.bar(start), THEME, 92, transpose=0, legato=1.0)
    horns.phrase(s.bar(start), THEME, 84, transpose=-12, legato=1.0)
    strings.phrase(s.bar(start), THEME, 74, transpose=12, legato=1.0)
    for index in range(8):
        bar = start + index
        chord = THEME_CHORDS[index]
        pad(choir, s.bar(bar), 4, [k + 12 for k in chord[1:]], 70, (70, 100, 85))
        cello.phrase(s.bar(bar), "{0}:1.5 {0}:.5 {1}:2".format(
            *[name_of(THEME_BASS[index] + 12), name_of(THEME_BASS[index] + 19)]), 88)
        drone.note(s.bar(bar), 3.9, THEME_BASS[index], 85)
        maqsum(drum_low, drum_high, s.bar(bar), 98, 55, fill=True)
        shaker.hits(s.bar(bar), "xooo xooo xooo xooo", SHAKER, 80, 50)
        taiko.hits(s.bar(bar), "x.....x...x.....", key("D2"), 95, 70, step=0.25)
        timpani.note(s.bar(bar), 1, THEME_BASS[index] + 12 if index != 4 else key("C3"), 80)
        arpeggio(oud, s.bar(bar), 4, [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[3] + 12],
                 70)
    cymbal.note(s.bar(20), 4, CRASH, 90)
    cymbal.note(s.bar(24), 4, CRASH, 80)
    timpani.roll(s.bar(27, 2), 2, key("D2"), 60, 110)

    # D: breakdown, the ney varies the theme over the drone, oud plucks
    start = 28
    cymbal.note(s.bar(start), 4, CRASH, 75)
    taiko.note(s.bar(start), 2, key("D2"), 100)
    ney.phrase(
        s.bar(start + 1),
        "A4:2 Bb4:.5 A4:.5 G4:1 | F#4:3 Eb4:1 | D4:1.5 Eb4:.5 F#4:1 A4:1 | "
        "G4:2 F#4:1 Eb4:1 | D4:6 r:2",
        74,
    )
    for index in range(8):
        bar = start + index
        chord = THEME_CHORDS[index % 4]
        oud.chord(s.bar(bar), 3.5, [chord[0], chord[1], chord[2]], 60, strum=0.04)
        oud.note(s.bar(bar, 2.5), 1.5, chord[3], 52)
        pad(strings, s.bar(bar), 4, chord, 50, (50, 72, 55))
        drum_low.hits(s.bar(bar), "x... .... ..o. ....", LOW_CONGA, 72, 45)

    # outro: back to the drone so the loop restarts on the intro
    for bar in range(36, 40):
        drum_low.hits(s.bar(bar), "x... .... ..o. ....", LOW_CONGA, 66, 42)
    pad(strings, s.bar(36), 8, keys("D3 A3 D4"), 52, (55, 70, 30))
    ney.phrase(s.bar(37), "A4:2 G4:1 F#4:1 | Eb4:2 D4:2", 60)
    return s


def name_of(a_key):
    names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    return "{0}{1}".format(names[a_key % 12], a_key // 12 - 1)


# --- calm 1: dust and steel -----------------------------------------------------------------

CALM1_CHORDS = [
    keys("D3 A3 D4 F4"),
    keys("Bb2 F3 Bb3 D4"),
    keys("C3 G3 C4 E4"),
    keys("D3 A3 D4 F4"),
    keys("G2 D3 G3 Bb3"),
    keys("Bb2 F3 Bb3 D4"),
    keys("A2 E3 A3 D4"),
    keys("A2 E3 A3 C#4"),
]
CALM1_MELODY_1 = (
    "r:1 A4:1 D5:1 E5:1 | F5:3 D5:1 | E5:1.5 D5:.5 C5:1 G4:1 | A4:4 | "
    "r:1 Bb4:1 D5:1 G5:1 | F5:2 E5:.5 D5:.5 F5:1 | E5:2 D5:2 | C#5:3 r:1"
)
CALM1_MELODY_2 = (
    "D5:1.5 C5:.5 A4:2 | Bb4:1 A4:1 F4:2 | G4:1 C5:1 E5:1.5 D5:.5 | D5:3 r:1 | "
    "G4:1.5 Bb4:.5 D5:2 | C5:1 Bb4:1 A4:1 F4:1 | E4:1 F4:1 G4:1 Bb4:1 | A4:3 r:1"
)


def compose_calm_1():
    s = Score("calm_dust_and_steel", bpm=84, bars=49, loop=False, lufs=-17.0, seed=21)
    guitar = s.part("guitar", NYLON_GUITAR, gain_db=-2, reverb=0.3, pan=-0.25)
    harp = s.part("harp", HARP, gain_db=-4, reverb=0.4, pan=0.25)
    pad_part = s.part("pad", WARM_PAD, gain_db=-11, reverb=0.45, low_cut=150)
    strings = s.part("strings", SLOW_STRINGS, gain_db=-7, reverb=0.45, low_cut=90)
    bass = s.part("bass", CONTRABASS, gain_db=-7, reverb=0.25)
    pizz = s.part("pizz", PIZZICATO, gain_db=-5, reverb=0.3, pan=0.1)
    flute = s.part("flute", FLUTE, gain_db=-6, reverb=0.45, pan=0.15)
    clarinet = s.part("clarinet", CLARINET, gain_db=-5, reverb=0.4, pan=-0.1)
    ney = s.part("ney", SHAKUHACHI, gain_db=-7, reverb=0.55, pan=0.2)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-11, reverb=0.5, pan=0.2)
    shaker = s.part("shaker", 0, drums=True, gain_db=-17, reverb=0.2, pan=0.4)
    bongo = s.part("bongo", 0, drums=True, gain_db=-12, reverb=0.25, pan=-0.3)

    def section(start, layers):
        for index in range(8):
            bar = start + index
            chord = CALM1_CHORDS[index]
            high = [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[3] + 12]
            if "guitar" in layers:
                arpeggio(guitar, s.bar(bar), 4, high, 62)
            if "harp" in layers:
                arpeggio(harp, s.bar(bar), 4, high + [chord[1] + 24], 56,
                         pattern=(0, 1, 2, 3, 4, 3, 2, 1))
            if "pad" in layers:
                pad(pad_part, s.bar(bar), 4, chord[1:], 55, (60, 80, 65))
            if "strings" in layers:
                pad(strings, s.bar(bar), 4, chord, 58, (55, 85, 65))
            if "horns" in layers:
                pad(horns, s.bar(bar), 4, chord[1:3], 50, (40, 75, 50))
            if "bass" in layers:
                bass.note(s.bar(bar), 3.8, chord[0] - 12 if chord[0] >= key("C3") else chord[0],
                          66)
            if "pizz" in layers:
                root = chord[0] - 12 if chord[0] >= key("C3") else chord[0]
                pizz.phrase(s.bar(bar), "{0}:1.5 {1}:.5 {2}:1 {1}:1".format(
                    name_of(root + 12), name_of(root + 19), name_of(root + 24)), 70)
            if "perc" in layers:
                shaker.hits(s.bar(bar), "x.o. x.o. x.o. x.oo", SHAKER, 65, 38)
                bongo.hits(s.bar(bar), "x... ..o. ..x. o...", HIGH_BONGO, 70, 40)
                bongo.hits(s.bar(bar), ".... x... .... ..x.", LOW_BONGO, 66, 40)

    section(0, {"guitar", "pad", "bass"})
    section(8, {"guitar", "pad", "bass", "perc"})
    flute.phrase(s.bar(8), CALM1_MELODY_1, 74)
    section(16, {"guitar", "strings", "pizz", "perc"})
    clarinet.phrase(s.bar(16), CALM1_MELODY_2, 74, transpose=-12)
    section(24, {"harp", "pad", "bass"})
    ney.phrase(s.bar(25), "A4:4 | G4:2 F4:2 | E4:4 | D4:4 | r:4 | Bb4:2 A4:2 | G4:4 | A4:4", 66)
    section(32, {"guitar", "strings", "horns", "pizz", "perc"})
    strings.phrase(s.bar(32), CALM1_MELODY_1, 70, legato=1.0)
    section(40, {"guitar", "pad", "bass", "harp"})
    flute.phrase(s.bar(40), "r:1 A4:1 D5:1 E5:1 | F5:3 D5:1 | E5:1.5 D5:.5 C5:1 G4:1 | A4:4", 64)
    # a last D minor chord to rest on
    final = s.bar(48)
    guitar.chord(final, 4, keys("D3 A3 D4 F4 A4"), 60, strum=0.06)
    harp.chord(final, 4, keys("D4 F4 A4 D5"), 52, strum=0.08)
    pad(pad_part, final, 4, keys("D3 A3 F4"), 55, (70, 70, 0))
    bass.note(final, 4, key("D2"), 64)
    return s


# --- calm 2: caravan road -------------------------------------------------------------------

CALM2_CHORDS = [
    keys("A2 E3 A3 C#4"),
    keys("Bb2 F3 Bb3 D4"),
    keys("A2 E3 A3 C#4"),
    keys("D3 A3 D4 F4"),
    keys("G2 D3 G3 Bb3"),
    keys("F2 C3 F3 A3"),
    keys("Bb2 F3 Bb3 D4"),
    keys("A2 E3 A3 C#4"),
]
CALM2_MELODY_A = (
    "E4:1 F4:.5 E4:.5 C#4:1 D4:1 | E4:1.5 F4:.5 D4:2 | C#4:.5 D4:.5 E4:1 F4:.5 G4:.5 F4:.5 E4:.5 | "
    "D4:2 F4:1 A4:1 | G4:1.5 F4:.5 E4:1 D4:1 | F4:1.5 E4:.5 D4:1 C4:1 | D4:1 C#4:.5 D4:.5 Bb3:2 | "
    "A3:3 r:1"
)
CALM2_MELODY_B = (
    "A4:2 Bb4:1 A4:1 | G4:1 F4:1 D4:2 | E4:1.5 F4:.5 G4:1 A4:1 | F4:3 r:1 | "
    "Bb4:1.5 A4:.5 G4:1 F4:1 | A4:1 G4:1 F4:1 C4:1 | F4:1 E4:1 D4:1 C#4:1 | E4:1 C#4:1 A3:2"
)


def compose_calm_2():
    s = Score("calm_caravan_road", bpm=96, bars=57, loop=False, lufs=-17.0, seed=31)
    oud = s.part("oud", NYLON_GUITAR, gain_db=0, reverb=0.3, pan=-0.2)
    harp = s.part("harp", HARP, gain_db=-6, reverb=0.4, pan=0.3)
    sitar = s.part("sitar", SITAR, gain_db=-14, reverb=0.45, pan=0.35)
    drone = s.part("drone", WARM_PAD, gain_db=-10, reverb=0.4, low_cut=110)
    strings = s.part("strings", SLOW_STRINGS, gain_db=-7, reverb=0.45, pan=0.05, low_cut=90)
    bass = s.part("bass", ACOUSTIC_BASS, gain_db=-7, reverb=0.2)
    clarinet = s.part("clarinet", CLARINET, gain_db=-5, reverb=0.4, pan=0.15)
    ney = s.part("ney", SHAKUHACHI, gain_db=-7, reverb=0.55, pan=-0.15)
    dum = s.part("darbuka_dum", 0, drums=True, gain_db=-5, reverb=0.25, pan=-0.05)
    tek = s.part("darbuka_tek", 0, drums=True, gain_db=-9, reverb=0.25, pan=0.15)
    tambourine = s.part("tambourine", 0, drums=True, gain_db=-19, reverb=0.3, pan=-0.35)

    for bar in range(0, 56, 4):
        drone.chord(s.bar(bar), 16, keys("A2 E3 A3"), 58)
        drone.swell(s.bar(bar), s.bar(bar + 2), 55, 85)
        drone.swell(s.bar(bar + 2), s.bar(bar + 4), 85, 55)

    def groove(start, bars, loud=84, fills=True, tamb=False):
        for index in range(bars):
            bar = start + index
            maqsum(dum, tek, s.bar(bar), loud, 40, fill=fills and index % 4 == 3)
            if tamb:
                tambourine.hits(s.bar(bar), "..x. ..x. ..x. ..x.", TAMBOURINE, 70, 40)

    def bassline(start):
        for index in range(8):
            root = CALM2_CHORDS[index][0]
            root = root - 12 if root >= key("C3") else root
            bass.phrase(s.bar(start + index), "{0}:1.5 {0}:.5 {1}:1 {0}:1".format(
                name_of(root), name_of(root + 7)), 74)

    # S1: an unaccompanied oud prelude over the drone
    oud.phrase(s.bar(1), "E3:2 F3:1 E3:1 | C#3:2 D3:1 E3:1 | F3:1 G3:1 F3:1 E3:1 | D3:2 C#3:2 | "
               "Bb2:1 C#3:1 D3:1 E3:1 | F3:2 E3:1 D3:1 | E3:4", 80, tremolo=0.25)
    for bar in range(0, 8, 2):
        dum.hits(s.bar(bar), "x... .... .... ....", LOW_CONGA, 70, 40)
    sitar.note(s.bar(0), 8, key("A2"), 60)
    sitar.note(s.bar(4), 8, key("E3"), 55)

    # S2: the groove starts, the oud plays melody A
    groove(8, 8)
    bassline(8)
    oud.phrase(s.bar(8), CALM2_MELODY_A, 88, tremolo=0.25)

    # S3: clarinet sings melody B, oud and harp accompany
    groove(16, 8)
    bassline(16)
    clarinet.phrase(s.bar(16), CALM2_MELODY_B, 72)
    for index in range(8):
        chord = CALM2_CHORDS[index]
        arpeggio(harp, s.bar(16 + index), 4, [k + 12 for k in chord], 54)
        oud.chord(s.bar(16 + index), 1.5, chord[:3], 62, strum=0.03)
        oud.chord(s.bar(16 + index, 2), 1.5, chord[:3], 55, strum=0.03)

    # S4: strings arrive, clarinet takes melody A an octave up
    groove(24, 8, loud=88, tamb=True)
    bassline(24)
    clarinet.phrase(s.bar(24), CALM2_MELODY_A, 74, transpose=12)
    for index in range(8):
        chord = CALM2_CHORDS[index]
        pad(strings, s.bar(24 + index), 4, chord, 58, (55, 85, 65))
        arpeggio(oud, s.bar(24 + index), 4, chord, 60, pattern=(0, 2, 1, 3, 2, 1, 3, 2))

    # S5: breakdown, sitar and ney over the drone and a frame drum
    for bar in range(32, 40):
        dum.hits(s.bar(bar), "x... .... ..o. ....", LOW_CONGA, 72, 42)
    sitar.phrase(s.bar(32), "A3:2 Bb3:1 A3:1 | G3:2 F3:2 | E3:4 | r:4", 70)
    ney.phrase(s.bar(35), "E4:2 F4:1 E4:1 | D4:2 C#4:2 | D4:1 E4:1 F4:1 G4:1 | A4:4 | "
               "Bb4:2 A4:2 | G4:4", 70)

    # S6: oud and strings together on melody A, full groove
    groove(40, 8, loud=90, tamb=True)
    bassline(40)
    oud.phrase(s.bar(40), CALM2_MELODY_A, 90, tremolo=0.25)
    strings.phrase(s.bar(40), CALM2_MELODY_A, 64, legato=1.0)
    for index in range(8):
        arpeggio(harp, s.bar(40 + index), 4, [k + 12 for k in CALM2_CHORDS[index]], 50)

    # S7: the caravan moves off; the groove thins and the oud ends on A
    groove(48, 4, loud=80, fills=False)
    for bar in range(52, 56):
        dum.hits(s.bar(bar), "x... .... ..o. ....", LOW_CONGA, 64, 38)
    bassline(48)
    oud.phrase(s.bar(48), "E4:1 F4:.5 E4:.5 C#4:1 D4:1 | E4:1.5 F4:.5 D4:2 | "
               "C#4:.5 D4:.5 E4:1 F4:.5 E4:.5 D4:.5 C#4:.5 | D4:1 C#4:.5 D4:.5 Bb3:2 | "
               "A3:4 | r:4 | E3:2 F3:1 E3:1 | A2+E3+A3:4", 82, tremolo=0.25)
    oud.chord(s.bar(56), 4, keys("A2 E3 A3 C#4 E4"), 64, strum=0.06)
    bass.note(s.bar(56), 4, key("A1"), 70)
    return s


# --- tension: heat haze ---------------------------------------------------------------------


def compose_tension():
    s = Score("tension_heat_haze", bpm=100, bars=36, lufs=-16.0, seed=41)
    cello = s.part("cello", CELLO, gain_db=-2, reverb=0.25, pan=-0.15, humanize_ms=4)
    basses = s.part("basses", CONTRABASS, gain_db=-8, reverb=0.25, humanize_ms=4)
    tremolo = s.part("tremolo", TREMOLO_STRINGS, gain_db=-7, reverb=0.5, pan=0.2)
    pad_part = s.part("pad", HALO_PAD, gain_db=-13, reverb=0.5, low_cut=150)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-4, reverb=0.5, pan=0.25)
    low_brass = s.part("low_brass", TROMBONE, gain_db=-6, reverb=0.4, pan=-0.2)
    choir = s.part("choir", CHOIR, gain_db=-14, reverb=0.6)
    taiko = s.part("taiko", TAIKO, gain_db=-6, reverb=0.35, humanize_ms=3)
    timpani = s.part("timpani", TIMPANI, gain_db=-7, reverb=0.4, humanize_ms=3)
    shaker = s.part("shaker", 0, drums=True, gain_db=-19, reverb=0.2, pan=0.4)
    bongo = s.part("bongo", 0, drums=True, gain_db=-13, reverb=0.25, pan=-0.35)

    roots = [key("D2"), key("D2"), key("Eb2"), key("D2")]
    # 3+3+2 accents over eighths: root, root, octave, root, neighbour, root, octave, root
    ostinato = [0, 0, 12, 0, 1, 0, 12, 0]
    accents = [1, 0, 0, 1, 0, 0, 1, 0]
    for bar in range(36):
        root = roots[bar % 4]
        level = 0 if bar < 8 else (6 if bar < 24 else 12)
        if bar >= 32:
            level = 0
        for step in range(8):
            velocity = (92 if accents[step] else 66) + level
            cello.note(s.bar(bar, step * 0.5), 0.32, root + 12 + ostinato[step], velocity)
            if accents[step]:
                basses.note(s.bar(bar, step * 0.5), 0.4, root, velocity - 6)
        if bar % 4 == 0:
            pad_part.chord(s.bar(bar), 16, keys("D2 A2 D3"), 60)
    # high, close dissonances that never settle
    for bar, chord in ((0, "A4 Bb4"), (4, "D5 Eb5"), (8, "A4 Bb4"), (12, "F#4 G4"),
                       (16, "A4 Bb4"), (20, "D5 Eb5"), (24, "A4 Bb4 D5"), (28, "F#4 G4 C5"),
                       (32, "A4 Bb4")):
        pad(tremolo, s.bar(bar), 16, keys(chord), 60, (25, 95, 30))
    # horn swells from bar 8: a falling half step, again and again
    for bar in (8, 12, 16, 20, 24, 28):
        horns.note(s.bar(bar), 7.8, key("Bb3"), 70)
        horns.note(s.bar(bar + 2), 7.8, key("A3"), 70)
        horns.swell(s.bar(bar), s.bar(bar + 1.5), 20, 110)
        horns.swell(s.bar(bar, 6), s.bar(bar + 3, 3), 110, 25)
    # taiko from bar 8, building
    for bar in range(8, 32):
        loud = 70 + (bar - 8)
        taiko.hits(s.bar(bar), "x..... x..... x...", key("D2"), loud, loud - 20, step=0.25)
    for bar in range(16, 32):
        shaker.hits(s.bar(bar), "xooo xooo xooo xooo", SHAKER, 66, 36)
        bongo.hits(s.bar(bar), "..o. ..x. .o.. x.o.", HIGH_BONGO, 72, 40, chance=0.85)
    for bar in (15, 23, 31):
        timpani.roll(s.bar(bar), 4, key("A1"), 35, 105, step=0.125)
    for bar in range(16, 32, 2):
        timpani.note(s.bar(bar), 1, key("D2"), 85)
    # the theme's opening, darkened, in low brass
    low_brass.phrase(s.bar(24), "D3:1.5 Eb3:.5 F#3:2 | G3:1.5 F#3:.5 Eb3:2 | D3:4 | r:4 | "
                     "A3:1.5 Bb3:.5 A3:2 | G3:1.5 F#3:.5 Eb3:2 | D3:4 | r:4", 86, legato=1.0)
    for bar in (24, 28):
        pad(choir, s.bar(bar), 16, keys("D4 A4 Eb5"), 60, (40, 95, 50))
    # the last bars fall back to the bare ostinato so the loop restarts cleanly
    for bar in range(32, 36):
        taiko.note(s.bar(bar), 1, key("D2"), 60)
    return s


# --- battle: iron storm ---------------------------------------------------------------------


def compose_battle():
    s = Score("battle_iron_storm", bpm=132, bars=48, lufs=-15.0, seed=51)
    violins = s.part("violins", FAST_STRINGS, gain_db=-2, reverb=0.3, pan=-0.2, humanize_ms=3)
    cello = s.part("cello", CELLO, gain_db=-2, reverb=0.25, pan=0.15, humanize_ms=3)
    basses = s.part("basses", CONTRABASS, gain_db=-7, reverb=0.25, humanize_ms=3)
    brass = s.part("brass", BRASS_SECTION, gain_db=-4, reverb=0.4, pan=0.1)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-4, reverb=0.45, pan=0.25)
    low_brass = s.part("low_brass", TROMBONE, gain_db=-5, reverb=0.35, pan=-0.2)
    choir = s.part("choir", CHOIR, gain_db=-11, reverb=0.55)
    taiko = s.part("taiko", TAIKO, gain_db=-3, reverb=0.35, humanize_ms=3)
    toms = s.part("toms", 0, drums=True, gain_db=-6, reverb=0.3, humanize_ms=3)
    timpani = s.part("timpani", TIMPANI, gain_db=-6, reverb=0.4, humanize_ms=3)
    dum = s.part("darbuka_dum", 0, drums=True, gain_db=-5, reverb=0.2, pan=-0.1, humanize_ms=3)
    tek = s.part("darbuka_tek", 0, drums=True, gain_db=-8, reverb=0.2, pan=0.2, humanize_ms=3)
    shaker = s.part("shaker", 0, drums=True, gain_db=-16, reverb=0.2, pan=0.4, humanize_ms=3)
    cymbal = s.part("cymbal", KIT_ORCHESTRA, drums=True, gain_db=-9, reverb=0.45)

    # four-bar harmonic cycle as scale degrees of D hijaz: D D Eb D, then C D Eb D
    cycle_a = [0, 0, 1, 0]
    cycle_b = [-1, 0, 1, 0]
    # sixteenth ostinato in scale degrees above the bar's degree
    figure = [0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 2, 1, 1, 0, -1]
    root = key("D4")

    def ostinato(bar, degree, loud):
        for step in range(16):
            velocity = (loud if step % 4 == 0 else loud - 22) + (8 if step in (0, 6, 12) else 0)
            violins.note(s.bar(bar, step * 0.25), 0.2,
                         scale_key(root, D_HIJAZ, degree + figure[step]), velocity)
        bass_key = scale_key(key("D2"), D_HIJAZ, degree)
        for step in range(8):
            accent = step in (0, 3, 6)
            cello.note(s.bar(bar, step * 0.5), 0.3, bass_key + 12 + (12 if step == 6 else 0),
                       95 if accent else 72)
            if accent:
                basses.note(s.bar(bar, step * 0.5), 0.45, bass_key, 96)

    def drums(bar, intensity, fill=False):
        taiko.hits(s.bar(bar), "x.....x...x.x...", key("D2"), 96 + intensity, 70, step=0.25)
        dum.hits(s.bar(bar), "x... ..x. x... ....", LOW_CONGA, 92, 50)
        tek.hits(s.bar(bar), "oox. oxoo oox. oxox", HIGH_BONGO, 86, 44)
        shaker.hits(s.bar(bar), "xoxo xoxo xoxo xoxo", SHAKER, 72, 45)
        if fill:
            toms.hits(s.bar(bar, 2), "x.x. xxx. xxxx xxxx", HIGH_TOM, 100, 80, step=0.125)
            toms.hits(s.bar(bar, 3), "..x. x.x. ", MID_TOM, 104, 80, step=0.125)
            toms.hits(s.bar(bar, 3.5), "x.x.", LOW_TOM, 110, 80, step=0.125)

    for bar in range(48):
        in_cycle = bar % 4
        degree = (cycle_b if (bar // 4) % 2 else cycle_a)[in_cycle]
        loud = 82 if bar < 8 else (90 if bar < 32 else 86)
        if 32 <= bar < 40:
            # break: cellos and basses only, the strings rest
            bass_key = scale_key(key("D2"), D_HIJAZ, degree)
            for step in range(8):
                cello.note(s.bar(bar, step * 0.5), 0.3, bass_key + 12, 90 if step in (0, 3, 6) else 70)
            basses.note(s.bar(bar), 1.0, bass_key, 92)
        else:
            ostinato(bar, degree, loud)
        if not 32 <= bar < 36:
            drums(bar, 8 if bar >= 16 else 0, fill=bar % 8 == 7)
    for bar in (0, 8, 16, 24, 40):
        cymbal.note(s.bar(bar), 4, CRASH, 95)

    # bars 8-15: brass stabs on the 3+3+2 accents
    for bar in range(8, 16):
        degree = (cycle_b if (bar // 4) % 2 else cycle_a)[bar % 4]
        chord_root = scale_key(key("D3"), D_HIJAZ, degree)
        triad = [chord_root, scale_key(key("D3"), D_HIJAZ, degree + 2),
                 scale_key(key("D3"), D_HIJAZ, degree + 4)]
        brass.chord(s.bar(bar), 0.6, triad, 100)
        brass.chord(s.bar(bar, 1.5), 0.6, triad, 92)
        if bar % 2 == 1:
            brass.chord(s.bar(bar, 3), 0.9, triad, 96)
    horns.phrase(s.bar(10), "A3:4 | Bb3:2 A3:2 | r:4 | r:4 | A3:4 | Bb3:2 C4:2 | A3:4", 86)

    # bars 16-31: the theme at half speed on brass and horns, choir behind
    theme_slow = stretch(THEME, 2.0)
    brass.phrase(s.bar(16), theme_slow, 98, legato=1.0)
    horns.phrase(s.bar(16), theme_slow, 90, transpose=-12, legato=1.0)
    for index in range(8):
        chord = THEME_CHORDS[index]
        pad(choir, s.bar(16 + index * 2), 8, [k + 12 for k in chord[1:]], 72, (60, 105, 80))
        low_brass.note(s.bar(16 + index * 2), 7.5, THEME_BASS[index] + 12, 84)
        timpani.note(s.bar(16 + index * 2), 1, THEME_BASS[index] + 12, 100)

    # bars 32-39: break; taiko solo and horn calls, then a build
    for bar in range(32, 40):
        taiko.hits(s.bar(bar), "X..x..x.X..x.x.x" if bar % 2 else "X.....x...X.....",
                   key("D2"), 100, 70)
    horns.phrase(s.bar(32), "A3:2 Bb3:2 | A3:4 | r:4 | r:4 | D4:2 Eb4:2 | D4:4", 94)
    low_brass.phrase(s.bar(36), "D3:4 | Eb3:4 | D3:4 | D3:2 Eb3:1 F#3:1", 88)
    timpani.roll(s.bar(38), 8, key("A1"), 50, 115, step=0.125)

    # bars 40-47: everything, the theme's opening at full speed, twice
    for start in (40, 44):
        brass.phrase(s.bar(start), THEME_A, 100, legato=0.9)
        horns.phrase(s.bar(start), THEME_A, 90, transpose=-12, legato=0.9)
    for bar in range(40, 48):
        timpani.note(s.bar(bar), 1, key("D2"), 95)
    return s


# --- stings ---------------------------------------------------------------------------------


def compose_victory():
    s = Score("sting_victory", bpm=88, bars=3, loop=False, lufs=-15.0, seed=61)
    brass = s.part("brass", BRASS_SECTION, gain_db=-2, reverb=0.45)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-3, reverb=0.5, pan=0.2)
    strings = s.part("strings", FAST_STRINGS, gain_db=-5, reverb=0.45, pan=-0.2)
    basses = s.part("basses", CONTRABASS, gain_db=-4, reverb=0.3)
    timpani = s.part("timpani", TIMPANI, gain_db=-4, reverb=0.45)
    cymbal = s.part("cymbal", KIT_ORCHESTRA, drums=True, gain_db=-7, reverb=0.55)
    # a rising call in D major, the theme's turn, and a held D chord
    brass.phrase(0, "A3:.33 A3:.33 A3:.34 D4:1 F#4:1 A4:1 | G4:.5 A4:.5 B4:1 A4:2 | D5:4", 100,
                 legato=1.0)
    horns.phrase(0, "r:1 A3:1 D4:1 F#4:1 | E4:2 C#4:2 | F#4:4", 90, legato=1.0)
    strings.chord(0, 1.0, keys("D3 A3 D4"), 90)
    strings.chord(4, 2, keys("G3 B3 D4 G4"), 92)
    strings.chord(6, 2, keys("A3 C#4 E4 A4"), 96)
    strings.chord(8, 4, keys("D3 A3 D4 F#4 A4 D5"), 100)
    basses.phrase(0, "D2:4 | G1:2 A1:2 | D2:4", 100)
    timpani.roll(6, 2, key("A1"), 60, 115, step=0.125)
    timpani.note(8, 2, key("D2"), 120)
    cymbal.note(8, 4, CRASH, 105)
    return s


def compose_defeat():
    s = Score("sting_defeat", bpm=60, bars=3, beats_per_bar=3, loop=False, lufs=-17.0, seed=71)
    cello = s.part("cello", CELLO, gain_db=-1, reverb=0.45)
    strings = s.part("strings", SLOW_STRINGS, gain_db=-5, reverb=0.55)
    horns = s.part("horns", FRENCH_HORNS, gain_db=-6, reverb=0.55, pan=0.2)
    basses = s.part("basses", CONTRABASS, gain_db=-3, reverb=0.35)
    taiko = s.part("taiko", TAIKO, gain_db=-4, reverb=0.5)
    # the theme's descent, slow and low, settling on a bare D minor
    cello.phrase(0, "A3:1 Bb3:1 A3:1 | G3:1 F#3:1 Eb3:1 | D3:3", 86, legato=1.0)
    horns.note(0, 6, key("D3"), 70)
    horns.swell(0, 3, 40, 100)
    horns.swell(3, 9, 100, 30)
    pad(strings, 0, 6, keys("Eb3 G3 Bb3"), 60, (40, 85, 70))
    pad(strings, 6, 3, keys("D3 F3 A3"), 60, (70, 75, 20))
    basses.note(0, 9, key("D2"), 80)
    taiko.note(6, 2, key("D2"), 95)
    return s


PIECES = {
    "menu": compose_menu,
    "calm_1": compose_calm_1,
    "calm_2": compose_calm_2,
    "tension": compose_tension,
    "battle": compose_battle,
    "victory": compose_victory,
    "defeat": compose_defeat,
}


# --- rendering ------------------------------------------------------------------------------


def soundfont_bytes(path):
    if path is None:
        path = os.path.join(CACHE_DIR, "GeneralUser-GS.sf2")
        if not os.path.exists(path):
            os.makedirs(CACHE_DIR, exist_ok=True)
            print("downloading", SOUNDFONT_URL)
            urllib.request.urlretrieve(SOUNDFONT_URL, path + ".part")
            os.replace(path + ".part", path)
    with open(path, "rb") as file:
        data = file.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SOUNDFONT_SHA256:
        print("warning: {0} has sha256 {1}, expected {2}; the music will differ".format(
            path, digest, SOUNDFONT_SHA256), file=sys.stderr)
    return data


def render_part(part, score, sf_data, total):
    import tinysoundfont

    synth = tinysoundfont.Synth(samplerate=RATE, gain=-6.0)
    sfid = synth.sfload(sf_data)
    channel = 9 if part.drums else 0
    synth.program_select(channel, sfid, part.bank, part.program, part.drums)
    synth.control_change(channel, 7, 100)
    synth.control_change(channel, 11, 127)
    rng = score.rng
    events = []  # (sample, order, kind, a, b)
    for index, (beat, duration, a_key, velocity) in enumerate(part.notes):
        jitter = rng.normal(0.0, part.humanize_ms / 1000.0) * RATE
        start = max(0, score.sample(beat) + int(jitter))
        end = max(start + 64, score.sample(beat + duration) + int(jitter))
        velocity = int(np.clip(velocity + rng.integers(-part.vel_jitter, part.vel_jitter + 1),
                               1, 127))
        events.append((start, 2, "on", a_key, (velocity, index)))
        events.append((end, 0, "off", a_key, index))
    for beat, controller, value in part.controls:
        events.append((score.sample(beat), 1, "cc", controller, int(np.clip(value, 0, 127))))
    events.sort(key=lambda event: (event[0], event[1]))
    out = np.zeros((total, 2), dtype=np.float32)
    playing = {}  # key -> index of the note that holds it
    position = 0
    for sample, _order, kind, a, b in events:
        sample = min(sample, total)
        if sample > position:
            out[position:sample] = np.frombuffer(
                synth.generate(sample - position), dtype=np.float32
            ).reshape(-1, 2)
            position = sample
        if kind == "on":
            if a in playing:
                synth.noteoff(channel, a)  # re-strike: end the ringing note first
            synth.noteon(channel, a, b[0])
            playing[a] = b[1]
        elif kind == "off":
            if playing.get(a) == b:  # a later note on the same key keeps ringing
                synth.noteoff(channel, a)
                del playing[a]
        else:
            synth.control_change(channel, a, b)
    if position < total:
        out[position:] = np.frombuffer(synth.generate(total - position),
                                       dtype=np.float32).reshape(-1, 2)
    return out


def make_impulse_response(seconds=3.4, t60=2.4, predelay=0.022, seed=7):
    """a warm hall: decorrelated noise for each side, highs dying faster than lows"""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    ir = np.zeros((n, 2))
    for channel in range(2):
        spectrum = np.fft.rfft(rng.standard_normal(n))
        tail = np.zeros(n)
        for low, high, decay in ((0, 400, 1.15), (400, 2500, 1.0), (2500, 8000, 0.55),
                                 (8000, RATE, 0.25)):
            band = np.fft.irfft(spectrum * ((freqs >= low) & (freqs < high)), n)
            tail += band * np.exp(-6.91 * t / (t60 * decay))
        tail *= np.minimum(1.0, t / 0.03)  # diffuse build-up
        for delay, gain in ((0.011, 0.5), (0.019, 0.4), (0.027, 0.3), (0.041, 0.25)):
            tail[int((delay + 0.003 * channel) * RATE)] += gain * 30.0 * np.std(tail)
        shift = int(predelay * RATE)
        ir[shift:, channel] = tail[: n - shift]
        ir[:, channel] /= np.sqrt(np.sum(ir[:, channel] ** 2))
    return ir


def convolve(signal, ir):
    n = len(signal) + len(ir)
    size = 1 << (n - 1).bit_length()
    mono = signal.mean(axis=1)
    spectrum = np.fft.rfft(mono, size)
    out = np.zeros((len(signal), 2))
    for channel in range(2):
        wet = np.fft.irfft(spectrum * np.fft.rfft(ir[:, channel], size), size)
        out[:, channel] = wet[: len(signal)]
    return out


def biquad_response(b, a, freqs):
    z = np.exp(-1j * 2 * np.pi * freqs / RATE)
    return np.abs((b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z))


def k_weighting(freqs):
    """magnitude of the ITU-R BS.1770 pre-filter (high shelf, then high-pass) at RATE"""
    # high shelf, +4 dB above ~1.7 kHz
    gain_db, f0, q = 3.99984385397, 1681.97445095, 0.7071752369554193
    big_a = 10 ** (gain_db / 40.0)
    w0 = 2 * np.pi * f0 / RATE
    alpha = np.sin(w0) / (2 * q)
    cos = np.cos(w0)
    shelf_b = [big_a * ((big_a + 1) + (big_a - 1) * cos + 2 * np.sqrt(big_a) * alpha),
               -2 * big_a * ((big_a - 1) + (big_a + 1) * cos),
               big_a * ((big_a + 1) + (big_a - 1) * cos - 2 * np.sqrt(big_a) * alpha)]
    shelf_a = [(big_a + 1) - (big_a - 1) * cos + 2 * np.sqrt(big_a) * alpha,
               2 * ((big_a - 1) - (big_a + 1) * cos),
               (big_a + 1) - (big_a - 1) * cos - 2 * np.sqrt(big_a) * alpha]
    # high-pass at 38 Hz
    f0, q = 38.13547087613982, 0.5003270373253953
    w0 = 2 * np.pi * f0 / RATE
    alpha = np.sin(w0) / (2 * q)
    cos = np.cos(w0)
    hp_b = [(1 + cos) / 2, -(1 + cos), (1 + cos) / 2]
    hp_a = [1 + alpha, -2 * cos, 1 - alpha]
    return biquad_response(shelf_b, shelf_a, freqs) * biquad_response(hp_b, hp_a, freqs)


def integrated_loudness(signal):
    """EBU R128 / BS.1770 integrated loudness in LUFS (gated, 400 ms blocks)"""
    n = len(signal)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    weights = k_weighting(freqs)
    power = np.zeros(n)
    for channel in range(signal.shape[1]):
        weighted = np.fft.irfft(np.fft.rfft(signal[:, channel]) * weights, n)
        power += weighted**2
    cumulative = np.concatenate([[0.0], np.cumsum(power)])
    block, hop = int(0.4 * RATE), int(0.1 * RATE)
    starts = np.arange(0, max(1, n - block), hop)
    block_power = (cumulative[starts + block] - cumulative[starts]) / block
    loudness = -0.691 + 10 * np.log10(block_power + 1e-12)
    gated = block_power[loudness > -70]
    if len(gated) == 0:
        return -70.0
    relative = -0.691 + 10 * np.log10(gated.mean()) - 10
    gated = gated[(-0.691 + 10 * np.log10(gated + 1e-12)) > relative]
    return -0.691 + 10 * np.log10(gated.mean())


def smooth_gain(target_db, attack, release, hop_s):
    """one-pole smoothing of a gain curve: fast when reducing, slow when recovering"""
    out = np.zeros_like(target_db)
    level = 0.0
    attack_coef = np.exp(-hop_s / attack)
    release_coef = np.exp(-hop_s / release)
    for index, value in enumerate(target_db):
        coef = attack_coef if value < level else release_coef
        level = coef * level + (1 - coef) * value
        out[index] = level
    return out


def compress(signal, ratio=1.8, attack=0.03, release=0.35):
    """gentle bus compression above the level of the louder passages"""
    hop = 512
    frames = len(signal) // hop
    power = (signal[: frames * hop] ** 2).mean(axis=1).reshape(frames, hop).mean(axis=1)
    window = 8
    power = np.convolve(power, np.ones(window) / window, mode="same")
    level_db = 10 * np.log10(power + 1e-12)
    active = level_db[level_db > level_db.max() - 40]
    threshold = np.percentile(active, 75)
    reduction = np.where(level_db > threshold, (threshold - level_db) * (1 - 1 / ratio), 0.0)
    reduction = smooth_gain(reduction, attack, release, hop / RATE)
    gain = 10 ** (np.interp(np.arange(len(signal)), np.arange(frames) * hop + hop / 2,
                            reduction) / 20)
    return signal * gain[:, None]


def limit(signal, ceiling_db=-1.6, release=0.08):
    """look-ahead peak limiter so nothing reaches the ceiling"""
    ceiling = 10 ** (ceiling_db / 20)
    hop = 64
    frames = int(np.ceil(len(signal) / hop))
    padded = np.zeros((frames * hop, 2))
    padded[: len(signal)] = signal
    peaks = np.abs(padded).max(axis=1).reshape(frames, hop).max(axis=1)
    needed = np.minimum(0.0, 20 * np.log10(ceiling / (peaks + 1e-12)))
    # look ahead: start reducing one block before a peak arrives
    ahead = np.minimum(needed, np.concatenate([needed[1:], [0.0]]))
    ahead = np.minimum(ahead, np.concatenate([[0.0], needed[:-1]]))
    gain_db = smooth_gain(ahead, 0.0001, release, hop / RATE)
    gain_db = np.minimum(gain_db, ahead)
    gain = 10 ** (np.interp(np.arange(len(signal)), np.arange(frames) * hop + hop / 2,
                            gain_db) / 20)
    return np.clip(signal * gain[:, None], -ceiling, ceiling)


def filter_stem(signal, cutoff):
    """steep high-pass at 'cutoff' Hz"""
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    response = 1.0 / np.sqrt(1.0 + (cutoff / freqs) ** 6)
    return np.stack([np.fft.irfft(np.fft.rfft(signal[:, c]) * response, n) for c in range(2)],
                    axis=1)


def master_eq(signal, cutoff=28.0, air_db=3.5, air_from=3500.0, low_db=-2.5, low_below=100.0):
    """clears rumble below 'cutoff', lifts the top a little (the SoundFont is dark) and eases
    the low end so taiko and basses leave room for the explosions of the game"""
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    response = 1.0 / np.sqrt(1.0 + (cutoff / freqs) ** 8)
    shelf = 1.0 / (1.0 + (air_from / freqs) ** 2)  # 0 below, 1 above
    response *= 10 ** (air_db * shelf / 20)
    low_shelf = 1.0 / (1.0 + (freqs / low_below) ** 2)  # 1 below, 0 above
    response *= 10 ** (low_db * low_shelf / 20)
    return np.stack([np.fft.irfft(np.fft.rfft(signal[:, c]) * response, n) for c in range(2)],
                    axis=1)


PART_REFERENCE_DB = -20.0


def active_level_db(stem):
    """mean power of the 400 ms blocks within 30 dB of the loudest one"""
    block = int(0.4 * RATE)
    blocks = len(stem) // block
    power = (stem[: blocks * block] ** 2).mean(axis=1).reshape(blocks, block).mean(axis=1)
    if power.max() <= 0:
        return PART_REFERENCE_DB
    active = power[power > power.max() * 1e-3]
    return 10 * np.log10(active.mean())


def master(score, sf_data, ir, verbose=True):
    loop_samples = score.sample(score.bars * score.beats_per_bar)
    total = loop_samples + int(TAIL_S * RATE)
    dry = np.zeros((total, 2))
    send = np.zeros((total, 2))
    for part in score.parts:
        stem = render_part(part, score, sf_data, total).astype(np.float64)
        # level every part by how loud it is while it plays, so gain_db is a mix position
        # (0 = lead) rather than a correction for how hot each SoundFont preset is
        if part.low_cut:
            stem = filter_stem(stem, part.low_cut)
        active = active_level_db(stem)
        stem *= 10 ** ((PART_REFERENCE_DB + part.gain_db - active) / 20)
        stem[:, 0] *= min(1.0, 1.0 - part.pan)
        stem[:, 1] *= min(1.0, 1.0 + part.pan)
        if verbose:
            print("  {0:<14} {1:6.1f} dB while playing, mixed at {2:+.0f} dB, {3:4d} notes".format(
                part.name, active, part.gain_db, len(part.notes)))
        dry += stem
        send += stem * part.reverb
    mix = dry + convolve(send, ir) * 0.9
    if score.loop:
        # fold everything that rings past the loop point back onto the start
        tail = mix[loop_samples:]
        mix = mix[:loop_samples].copy()
        mix[: len(tail)] += tail
    else:
        # let the last chord ring out, then fade the room
        mix = mix[: loop_samples + int(STING_TAIL_S * RATE)]
        fade = int(2.5 * RATE)
        mix[-fade:] *= np.linspace(1.0, 0.0, fade)[:, None] ** 2
    mix = master_eq(mix)
    mix = compress(mix)
    mix *= 10 ** ((score.lufs - integrated_loudness(mix)) / 20)
    mix = limit(mix)
    return mix


def write_ogg(path, signal):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp:
        wav_path = temp.name
    try:
        rng = np.random.default_rng(0)
        dither = (rng.random(signal.shape) - rng.random(signal.shape)) / 32768.0
        pcm = np.clip((signal + dither) * 32767.0, -32768, 32767).astype(np.int16)
        with wave.open(wav_path, "wb") as file:
            file.setnchannels(2)
            file.setsampwidth(2)
            file.setframerate(RATE)
            file.writeframes(pcm.tobytes())
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-c:a", "libvorbis",
             "-q:a", str(OGG_QUALITY), path],
            check=True,
        )
    finally:
        os.remove(wav_path)


# --- checking -------------------------------------------------------------------------------


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(RATE),
         "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)


def check(names, plots_dir=None):
    """prints what each track looks like, as a stand-in for listening to it"""
    bars = " .:-=+*#%@"
    total_bytes = 0
    for name in names:
        path = os.path.join(OUT_DIR, name + ".ogg")
        if not os.path.exists(path):
            print("{0}: missing".format(name))
            continue
        signal = decode(path)
        total_bytes += os.path.getsize(path)
        seconds = len(signal) / RATE
        ffmpeg_report = subprocess.run(
            ["ffmpeg", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
            capture_output=True, text=True,
        ).stderr
        summary = ffmpeg_report[ffmpeg_report.rfind("Summary:"):]
        lufs = re.search(r"I:\s+(-?[\d.]+) LUFS", summary)
        lra = re.search(r"LRA:\s+(-?[\d.]+) LU", summary)
        peak = re.search(r"Peak:\s+(-?[\d.inf]+) dBFS", summary)
        print("{0}: {1:.1f} s, {2:.0f} kB, {3} LUFS (own meter {4:.1f}), LRA {5} LU, "
              "true peak {6} dBFS".format(
                  name, seconds, os.path.getsize(path) / 1024, lufs and lufs.group(1),
                  integrated_loudness(signal), lra and lra.group(1), peak and peak.group(1)))
        # loudness envelope, one character per 2 s
        step = 2 * RATE
        levels = [20 * np.log10(np.sqrt((signal[i: i + step] ** 2).mean()) + 1e-9)
                  for i in range(0, len(signal) - step // 2, step)]
        line = "".join(bars[int(np.clip((level + 40) / 34 * 9, 0, 9))] for level in levels)
        print("  rms/2s  |{0}|  ({1:.0f}..{2:.0f} dB)".format(line, min(levels), max(levels)))
        # where the energy sits in the spectrum
        mono = signal.mean(axis=1)
        spectrum = np.abs(np.fft.rfft(mono)) ** 2
        freqs = np.fft.rfftfreq(len(mono), 1.0 / RATE)
        bands = [(20, 80), (80, 250), (250, 1000), (1000, 4000), (4000, 10000), (10000, 20000)]
        energy = [spectrum[(freqs >= lo) & (freqs < hi)].sum() for lo, hi in bands]
        shares = ", ".join("{0}-{1}Hz {2:.0f}%".format(lo, hi, 100 * e / sum(energy))
                           for (lo, hi), e in zip(bands, energy))
        centroid = (spectrum * freqs).sum() / spectrum.sum()
        print("  spectrum: {0}; centroid {1:.0f} Hz".format(shares, centroid))
        # a loop must not click where it wraps: compare the last and first 50 ms
        edge = int(0.05 * RATE)
        end_rms = np.sqrt((signal[-edge:] ** 2).mean())
        start_rms = np.sqrt((signal[:edge] ** 2).mean())
        jump = np.abs(signal[0] - signal[-1]).max()
        print("  wrap: last 50 ms {0:.1f} dB, first 50 ms {1:.1f} dB, sample jump {2:.4f}".format(
            20 * np.log10(end_rms + 1e-9), 20 * np.log10(start_rms + 1e-9), jump))
        if plots_dir:
            os.makedirs(plots_dir, exist_ok=True)
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-lavfi",
                 "showspectrumpic=s=1200x400:legend=1:scale=log:fscale=log",
                 os.path.join(plots_dir, name + "_spectrum.png")],
                check=True,
            )
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-lavfi",
                 "showwavespic=s=1200x200:split_channels=0:colors=0x4a90d9",
                 os.path.join(plots_dir, name + "_wave.png")],
                check=True,
            )
    print("total {0:.2f} MB".format(total_bytes / 1024 / 1024))


TRACK_FILES = {
    "menu": "menu_theme",
    "calm_1": "calm_dust_and_steel",
    "calm_2": "calm_caravan_road",
    "tension": "tension_heat_haze",
    "battle": "battle_iron_storm",
    "victory": "sting_victory",
    "defeat": "sting_defeat",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", help="comma-separated pieces: " + ",".join(PIECES))
    parser.add_argument("--soundfont", help="a local GeneralUser-GS.sf2 instead of the cache")
    parser.add_argument("--check", action="store_true", help="analyse the rendered files")
    parser.add_argument("--plots", help="with --check: write spectrogram PNGs to this folder")
    args = parser.parse_args()
    names = args.only.split(",") if args.only else list(PIECES)
    if args.check:
        check([TRACK_FILES[name] for name in names], args.plots)
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    sf_data = soundfont_bytes(args.soundfont)
    ir = make_impulse_response()
    for name in names:
        score = PIECES[name]()
        print("{0}: {1:.1f} s at {2} bpm{3}".format(
            score.name, score.seconds, score.bpm, ", loops" if score.loop else ""))
        mix = master(score, sf_data, ir)
        write_ogg(os.path.join(OUT_DIR, score.name + ".ogg"), mix)


if __name__ == "__main__":
    main()
