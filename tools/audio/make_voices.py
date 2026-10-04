"""Builds every unit voice, the machine sounds of unmanned units and the advisor's announcements.

    python3 tools/audio/make_voices.py --kokoro-dir DIR        # everything
    python3 tools/audio/make_voices.py --only drone,structure   # machine sets need no model

Writes assets/audio/voices/<set>/<action>_<nn>.ogg and data/sounds/voice_sets/<set>.json
(the file list the game reads, with the spoken text of every line).

Speech comes from Kokoro-82M (Apache 2.0 weights) through kokoro-onnx (MIT), run locally:
    pip install kokoro-onnx soundfile numpy
    DIR = a folder with kokoro-v1.0.onnx and voices-v1.0.bin from
    https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0
The lines, speakers and radio styles are in tools/audio/voice_lines.json. Every clip is then
put through a radio filter (band-pass, saturation, hiss, squelch clicks) so it sounds like a
field radio, a tank intercom or a pilot over the rotors.

Machine sets (drone, auto_vehicle, structure) are synthesized from sine waves and noise with
numpy, like make_war_sounds.py. Needs ffmpeg with libvorbis.
"""

import argparse
import json
import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 24000  # Kokoro's output rate; the ogg files are written at OUT_RATE
OUT_RATE = 22050
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
AUDIO_DIR = os.path.join(ROOT, "assets", "audio", "voices")
DATA_DIR = os.path.join(ROOT, "data", "sounds", "voice_sets")
LINES_FILE = os.path.join(os.path.dirname(__file__), "voice_lines.json")
UNIT_ACTIONS = ["select", "move", "attack", "retreat", "build", "cannot", "under_attack", "ready"]
MACHINE_VARIANTS = 4
rng = np.random.default_rng(2610)


# ---------------------------------------------------------------- dsp helpers


def times(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def band(signal, low, high, slope=1.5):
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum = np.fft.rfft(signal)
    spectrum *= 1.0 / (1.0 + (low / freqs) ** (2 * slope))
    spectrum *= 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    return np.fft.irfft(spectrum, n)


def noise(n, low=100, high=8000):
    signal = band(rng.standard_normal(n), low, high, 1.0)
    return signal / (np.abs(signal).max() + 1e-9)


def envelope(n, attack_s=0.005, release_s=0.03):
    env = np.ones(n)
    a = max(1, min(n // 2, int(attack_s * RATE)))
    r = max(1, min(n // 2, int(release_s * RATE)))
    env[:a] = np.linspace(0, 1, a)
    env[-r:] = np.linspace(1, 0, r)
    return env


def saturate(signal, drive):
    return np.tanh(signal * drive) / np.tanh(drive)


def trim(signal, threshold=0.012, pad_s=0.03):
    loud = np.where(np.abs(signal) > threshold)[0]
    if len(loud) == 0:
        return signal
    pad = int(pad_s * RATE)
    return signal[max(0, loud[0] - pad) : min(len(signal), loud[-1] + pad)]


def normalize(signal, rms_db=-17.0, peak=0.89):
    loud = signal[np.abs(signal) > 0.02 * np.abs(signal).max()]
    rms = np.sqrt(np.mean(loud**2)) if len(loud) else 1.0
    signal = signal * (10 ** (rms_db / 20) / (rms + 1e-9))
    top = np.abs(signal).max()
    if top > peak:  # soft limit instead of a hard cut
        signal = saturate(signal / top * 1.2, 1.2) * peak
    return signal


def concat(*parts, gap_s=0.0):
    gap = np.zeros(int(gap_s * RATE))
    out = []
    for index, part in enumerate(parts):
        if index:
            out.append(gap)
        out.append(part)
    return np.concatenate(out)


def mix(base, other, at_s=0.0, gain=1.0):
    start = int(at_s * RATE)
    n = max(len(base), start + len(other))
    out = np.zeros(n)
    out[: len(base)] += base
    out[start : start + len(other)] += other * gain
    return out


# ---------------------------------------------------------------- radio styles


def squelch_open():
    t = times(0.035)
    return noise(len(t), 800, 6000) * np.exp(-t * 90) * 0.25


def squelch_close():
    t = times(0.11)
    return noise(len(t), 1500, 7000) * np.exp(-t * 28) * 0.18


def chime():
    """two soft tones ahead of an advisor announcement"""
    out = []
    for freq in (660.0, 880.0):
        t = times(0.16)
        tone = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * freq * 2.01 * t)
        out.append(tone * np.exp(-t * 14) * envelope(len(t), 0.004, 0.02) * 0.22)
    return concat(*out)


def room(signal, taps=((0.023, 0.22), (0.041, 0.15), (0.067, 0.09))):
    out = signal.copy()
    for delay_s, gain in taps:
        out = mix(out, band(signal, 200, 4000), delay_s, gain)
    return out


STYLES = {
    # low/high: radio band, drive: saturation, hiss: noise level, bed: background under speech
    "field_radio": {"low": 320, "high": 3400, "drive": 2.4, "hiss": 0.020, "bed": None},
    "vehicle_radio": {"low": 260, "high": 3100, "drive": 3.0, "hiss": 0.018, "bed": "engine"},
    "command_radio": {"low": 200, "high": 4600, "drive": 1.5, "hiss": 0.010, "bed": None},
    "pilot_radio": {"low": 420, "high": 2900, "drive": 4.0, "hiss": 0.035, "bed": "rotor"},
    "work_radio": {"low": 240, "high": 4200, "drive": 1.9, "hiss": 0.012, "bed": None},
}


def bed(kind, n):
    t = np.arange(n) / RATE
    if kind == "engine":
        rumble = np.sin(2 * np.pi * 52 * t) + 0.5 * np.sin(2 * np.pi * 104 * t + 1.0)
        rumble += band(rng.standard_normal(n), 40, 260) * 2.0
        return rumble * (0.8 + 0.2 * np.sin(2 * np.pi * 3.1 * t)) * 0.05
    if kind == "rotor":
        chop = 0.5 + 0.5 * np.sin(2 * np.pi * 17.0 * t) ** 8
        return band(rng.standard_normal(n), 120, 900) * chop * 0.22
    return np.zeros(n)


def radio(speech, style_name):
    if style_name == "advisor":
        voice = room(band(speech, 110, 7500, 1.0))
        return normalize(concat(chime(), voice, gap_s=0.04), rms_db=-16.0)
    style = STYLES[style_name]
    voice = band(speech, style["low"], style["high"])
    voice = voice / (np.abs(voice).max() + 1e-9)
    voice = saturate(voice, style["drive"]) * 0.8
    n = len(voice)
    voice += noise(n, 1500, 7000) * style["hiss"]
    if style["bed"]:
        voice += band(bed(style["bed"], n), style["low"] * 0.3, style["high"])
    voice = concat(squelch_open(), voice, squelch_close())
    return normalize(voice)


# ---------------------------------------------------------------- machine voices


def tone(freq, seconds, shape="sine", attack_s=0.004, release_s=0.03):
    t = times(seconds)
    freq = np.broadcast_to(freq, t.shape) if np.ndim(freq) else np.full(t.shape, freq)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    if shape == "square":
        wave_ = np.sign(np.sin(phase)) * 0.6 + 0.4 * np.sin(phase)
    elif shape == "saw":
        wave_ = sum(np.sin(phase * k) / k for k in range(1, 7))
    else:
        wave_ = np.sin(phase) + 0.2 * np.sin(3 * phase)
    return wave_ * envelope(len(t), attack_s, release_s)


def beep(freq, seconds=0.07, shape="sine"):
    return tone(freq, seconds, shape, 0.003, 0.02) * 0.5


def sweep(f_start, f_end, seconds, shape="sine"):
    t = times(seconds)
    return tone(f_start * (f_end / f_start) ** (t / seconds), seconds, shape) * 0.5


def beeps(freqs, seconds=0.07, gap_s=0.035, shape="sine"):
    return concat(*[beep(f, seconds, shape) for f in freqs], gap_s=gap_s)


def rotor_buzz(seconds, pitch=190.0, spool=None):
    """four propellers a little out of tune: the beating whine of a quadcopter"""
    t = times(seconds)
    out = np.zeros(len(t))
    curve = np.ones(len(t)) if spool is None else spool(t / seconds)
    for detune in (0.0, 2.7, 5.9, 9.1):
        freq = (pitch + detune) * curve
        phase = 2 * np.pi * np.cumsum(freq) / RATE
        out += sum(np.sin(phase * k + detune) / k**1.3 for k in range(1, 9))
    out += noise(len(t), 2000, 9000) * 0.6
    out *= 1.0 + 0.15 * np.sin(2 * np.pi * 7.3 * t)
    return out / (np.abs(out).max() + 1e-9) * envelope(len(t), 0.08, 0.12) * 0.45


def servo(f_start, f_end, seconds):
    """a geared motor: harmonic whine sweeping, with gritty gear noise"""
    t = times(seconds)
    freq = f_start + (f_end - f_start) * (t / seconds) ** 0.7
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    whine = sum(np.sin(phase * k) / k for k in (1, 2, 3, 5))
    grit = band(rng.standard_normal(len(t)), 1500, 5000) * (0.5 + 0.5 * np.sin(phase * 0.25))
    return (whine * 0.4 + grit * 0.25) * envelope(len(t), 0.01, 0.04) * 0.6


def engine_blip(seconds=0.35, rpm_up=True):
    """a short throttle blip: low firing pulses that speed up (or slow down)"""
    t = times(seconds)
    rate = np.linspace(28, 55, len(t)) if rpm_up else np.linspace(55, 26, len(t))
    phase = 2 * np.pi * np.cumsum(rate) / RATE
    pulses = np.maximum(np.sin(phase), 0) ** 6
    body = band(pulses + 0.3 * rng.standard_normal(len(t)) * pulses, 30, 900)
    return body / (np.abs(body).max() + 1e-9) * envelope(len(t), 0.02, 0.08) * 0.55


def relay_click():
    t = times(0.05)
    return (noise(len(t), 300, 6000) * np.exp(-t * 160) + np.sin(2 * np.pi * 90 * t) * np.exp(-t * 60)) * 0.5


def hum(seconds, freq=120.0):
    t = times(seconds)
    out = np.sin(2 * np.pi * freq * t) + 0.5 * np.sin(2 * np.pi * freq * 2 * t) + 0.3 * np.sin(2 * np.pi * freq * 3 * t)
    return out * envelope(len(t), 0.03, 0.1) * 0.18


def bell(freq, seconds=0.5):
    t = times(seconds)
    out = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-t * d) for m, a, d in ((1, 1, 6), (2.76, 0.4, 10), (5.4, 0.2, 16)))
    return out * envelope(len(t), 0.002, 0.05) * 0.4


def klaxon(seconds=0.9, low=440, high=554):
    parts = []
    while sum(len(p) for p in parts) < seconds * RATE:
        parts.append(tone(high, 0.16, "saw", 0.01, 0.02) * 0.35)
        parts.append(tone(low, 0.16, "saw", 0.01, 0.02) * 0.35)
    return concat(*parts)


def j(value, spread):
    """jitter a parameter so every variant is a little different"""
    return value * (1.0 + rng.uniform(-spread, spread))


def drone_line(action):
    p = j(190, 0.08)
    if action == "select":
        patterns = [[1.0, 1.5], [1.0, 1.25, 1.5], [1.5, 1.0, 1.5], [1.33, 2.0]]
        pattern = patterns[int(rng.integers(len(patterns)))]
        return mix(rotor_buzz(0.55, p), beeps([j(900, 0.05) * f for f in pattern]), 0.12, 0.9)
    if action == "move":
        rise = j(1.35, 0.1)
        buzz = rotor_buzz(0.7, p, lambda x: 1.0 + (rise - 1.0) * np.minimum(x * 2.0, 1.0))
        return mix(buzz, sweep(j(700, 0.1), j(1500, 0.1), 0.14), 0.05, 0.8)
    if action == "attack":
        lock = beeps([j(1550, 0.03)] * int(rng.integers(3, 5)), 0.045, 0.03, "square")
        return mix(rotor_buzz(0.7, p * 1.15), concat(lock, beep(j(2100, 0.03), 0.22)), 0.05, 0.7)
    if action == "retreat":
        buzz = rotor_buzz(0.8, p * 1.3, lambda x: 1.0 - 0.3 * x)
        return mix(buzz, sweep(j(1400, 0.1), j(500, 0.1), 0.3), 0.08, 0.8)
    if action == "build":
        return mix(rotor_buzz(0.6, p), concat(beep(j(600, 0.05)), beep(j(600, 0.05)), servo(400, 900, 0.18)), 0.08, 0.8)
    if action == "cannot":
        return mix(rotor_buzz(0.55, p * 0.9), beeps([j(240, 0.05)] * 2, 0.12, 0.06, "square"), 0.06, 0.8)
    if action == "under_attack":
        warble = concat(*[beep(f, 0.09) for f in [j(950, 0.04), j(650, 0.04)] * 3])
        buzz = rotor_buzz(0.8, p, lambda x: 1.0 + 0.12 * np.sin(x * 40))
        return mix(buzz, warble, 0.04, 0.9)
    if action == "ready":
        buzz = rotor_buzz(0.9, p, lambda x: 0.35 + 0.65 * np.minimum(x * 1.6, 1.0))
        return mix(buzz, beeps([j(700, 0.04), j(930, 0.04), j(1240, 0.04)]), 0.5, 0.9)
    raise ValueError(action)


def auto_vehicle_line(action):
    chirp = lambda: beeps([j(rng.choice([1800, 2200, 2600, 3000]), 0.05) for _ in range(int(rng.integers(2, 5)))], 0.035, 0.02)
    if action == "select":
        return mix(servo(j(500, 0.1), j(900, 0.1), 0.18), chirp(), 0.14, 0.8)
    if action == "move":
        return mix(engine_blip(j(0.4, 0.1)), servo(j(400, 0.1), j(1100, 0.1), 0.2), 0.0, 0.6)
    if action == "attack":
        lock = beeps([j(2400, 0.03)] * 3, 0.04, 0.025, "square")
        return concat(servo(j(800, 0.1), j(1600, 0.1), 0.15), lock, beep(j(3000, 0.03), 0.18))
    if action == "retreat":
        return mix(engine_blip(j(0.45, 0.1), rpm_up=True), sweep(j(1800, 0.1), j(600, 0.1), 0.28), 0.05, 0.7)
    if action == "build":
        return concat(servo(j(600, 0.1), j(400, 0.1), 0.15), chirp())
    if action == "cannot":
        return concat(beeps([j(300, 0.05)] * 2, 0.1, 0.05, "square"), servo(j(500, 0.1), j(300, 0.1), 0.12))
    if action == "under_attack":
        return mix(klaxon(0.6, j(700, 0.05), j(900, 0.05)) * 0.8, engine_blip(0.5), 0.0, 0.5)
    if action == "ready":
        return concat(engine_blip(0.4), servo(j(400, 0.1), j(1200, 0.1), 0.2), chirp())
    raise ValueError(action)


def structure_line(action):
    if action == "select":
        return mix(relay_click(), hum(j(0.4, 0.15), rng.choice([100.0, 120.0, 150.0])), 0.02, 1.0)
    if action == "move":  # rally point set
        return concat(relay_click(), beeps([j(1000, 0.05), j(1300, 0.05)]))
    if action == "attack":  # turret given a target
        return concat(servo(j(300, 0.1), j(700, 0.1), 0.22), beeps([j(1700, 0.03)] * 2, 0.05, 0.03, "square"))
    if action == "retreat":
        return sweep(j(800, 0.1), j(200, 0.1), 0.4, "saw") * 0.6
    if action == "build":  # production started
        return concat(relay_click(), servo(j(250, 0.1), j(500, 0.1), 0.3))
    if action == "cannot":
        return beeps([j(200, 0.05)] * 2, 0.16, 0.06, "square")
    if action == "under_attack":
        return klaxon(j(0.8, 0.1), j(440, 0.05), j(554, 0.05))
    if action == "ready":
        root = rng.choice([523.0, 587.0, 659.0])
        return mix(bell(root, 0.6), bell(root * 1.5, 0.6), 0.14, 0.9)
    raise ValueError(action)


MACHINE_SETS = {
    "drone": ("Unmanned scout drone: rotor buzz and beeps", drone_line),
    "auto_vehicle": ("Automated vehicles: servo chirps and engine blips", auto_vehicle_line),
    "structure": ("Buildings and turrets: relay clicks, hums, chimes and alarms", structure_line),
}


# ---------------------------------------------------------------- output


def write_ogg(path, signal):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pcm = (np.clip(signal, -1, 1) * 32767).astype(np.int16)
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "line.wav")
        with wave.open(wav_path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(pcm.tobytes())
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-ar", str(OUT_RATE), "-c:a", "libvorbis", "-q:a", "2", path],
            check=True,
        )


def clear_set_dir(set_id):
    folder = os.path.join(AUDIO_DIR, set_id)
    if os.path.isdir(folder):
        for name in os.listdir(folder):
            if name.endswith(".ogg") or name.endswith(".ogg.import"):
                os.remove(os.path.join(folder, name))
    return folder


def write_set_json(set_id, kind, description, lines):
    os.makedirs(DATA_DIR, exist_ok=True)
    entry = {
        "id": set_id,
        "kind": kind,
        "description": description,
        "folder": "res://assets/audio/voices/" + set_id + "/",
        "lines": lines,
    }
    with open(os.path.join(DATA_DIR, set_id + ".json"), "w") as out:
        json.dump(entry, out, indent=2)
        out.write("\n")


def build_speech_set(kokoro, set_id, spec, kind="speech"):
    folder = clear_set_dir(set_id)
    lines = {}
    speakers = spec["speakers"]
    for action_index, (action, texts) in enumerate(spec["lines"].items()):
        lines[action] = []
        for index, text in enumerate(texts):
            speaker = speakers[(index + action_index) % len(speakers)]
            samples, rate = kokoro.create(text, voice=speaker, speed=spec["speed"], lang=_lang(speaker))
            assert rate == RATE, rate
            clip = radio(trim(np.asarray(samples, dtype=np.float64)), spec["style"])
            name = "{0}_{1:02d}.ogg".format(action, index + 1)
            write_ogg(os.path.join(folder, name), clip)
            lines[action].append({"file": name, "text": text, "speaker": speaker})
        print("  {0}/{1}: {2} lines".format(set_id, action, len(texts)))
    write_set_json(set_id, kind, spec["description"], lines)


def build_machine_set(set_id):
    description, make_line = MACHINE_SETS[set_id]
    folder = clear_set_dir(set_id)
    lines = {}
    for action in UNIT_ACTIONS:
        lines[action] = []
        for index in range(MACHINE_VARIANTS):
            name = "{0}_{1:02d}.ogg".format(action, index + 1)
            write_ogg(os.path.join(folder, name), normalize(make_line(action), rms_db=-19.0))
            lines[action].append({"file": name, "text": "(" + set_id.replace("_", " ") + " " + action.replace("_", " ") + ")"})
    write_set_json(set_id, "machine", description, lines)
    print("  {0}: {1} sounds".format(set_id, len(UNIT_ACTIONS) * MACHINE_VARIANTS))


def _lang(speaker):
    return "en-gb" if speaker.startswith("b") else "en-us"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kokoro-dir", default=os.environ.get("KOKORO_DIR", ""))
    parser.add_argument("--only", default="", help="comma separated set ids")
    args = parser.parse_args()
    script = json.load(open(LINES_FILE))
    speech = dict(script["speech_sets"])
    speech["advisor"] = script["advisor"]
    wanted = [s for s in args.only.split(",") if s] or list(speech) + list(MACHINE_SETS)

    for set_id in wanted:
        if set_id in MACHINE_SETS:
            build_machine_set(set_id)

    speech_wanted = [s for s in wanted if s in speech]
    if speech_wanted:
        from kokoro_onnx import Kokoro

        kokoro = Kokoro(
            os.path.join(args.kokoro_dir, "kokoro-v1.0.onnx"),
            os.path.join(args.kokoro_dir, "voices-v1.0.bin"),
        )
        for set_id in speech_wanted:
            build_speech_set(kokoro, set_id, speech[set_id], "advisor" if set_id == "advisor" else "speech")


if __name__ == "__main__":
    main()
