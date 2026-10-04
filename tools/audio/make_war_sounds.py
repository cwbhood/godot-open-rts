"""Synthesizes the combat sounds: weapon fire, impacts, explosions and vehicle engine loops.

Like make_soundscape.py, everything is built from noise and sine waves with numpy, so the
sounds are original work released under the project's license.

    python3 tools/audio/make_war_sounds.py      # writes assets/audio/war/*.ogg

Needs numpy and ffmpeg (with libvorbis). One-shots come in a few variants (_1, _2, ...) that
the game picks from at random, on top of a small random pitch shift.
"""

import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 32000
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "war")
rng = np.random.default_rng(4321)


def times(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def filtered_noise(n, low, high, slope=1.0):
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum *= 1.0 / (1.0 + (low / freqs) ** (2 * slope))
    spectrum *= 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    signal = np.fft.irfft(spectrum, n)
    return signal / (np.abs(signal).max() + 1e-9)


def lowpass(signal, cutoff, slope=1.0):
    n = len(signal)
    freqs = np.maximum(np.fft.rfftfreq(n, 1.0 / RATE), 1.0)
    spectrum = np.fft.rfft(signal) / (1.0 + (freqs / cutoff) ** (2 * slope))
    return np.fft.irfft(spectrum, n)


def outdoor_tail(signal, seconds=1.2, decay=4.0, wet=0.35):
    """open-air echo: convolve with sparse, dull, decaying reflections"""
    t = times(seconds)
    tail = filtered_noise(len(t), 60, 1800) * np.exp(-t * decay)
    tail *= rng.random(len(t)) < 0.02  # sparse reflections
    tail[0] = 1.0 / wet
    n = len(signal) + len(tail)
    out = np.fft.irfft(np.fft.rfft(signal, n) * np.fft.rfft(tail, n), n)
    return out * wet


def boom(t, freq_start, freq_end, decay):
    """falling sine thump: the body of cannon shots and explosions"""
    freq = freq_end + (freq_start - freq_end) * np.exp(-t * 18.0)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    return np.sin(phase) * np.exp(-t * decay)


def crack(t, decay=60.0):
    return filtered_noise(len(t), 900, 9000) * np.exp(-t * decay)


def cannon_fire(heavy=False):
    t = times(1.6 if heavy else 1.1)
    body = boom(t, 140 if heavy else 190, 38 if heavy else 52, 5.0 if heavy else 7.0)
    blast = filtered_noise(len(t), 50, 2400) * np.exp(-t * (7.0 if heavy else 11.0))
    snap = crack(t, 55.0)
    shot = 1.0 * body + 0.7 * blast + 0.45 * snap
    shot[: int(0.002 * RATE)] *= np.linspace(0, 1, int(0.002 * RATE))
    return outdoor_tail(shot, 1.4 if heavy else 1.0)


def rifle_burst(rounds):
    length = 0.12 * rounds + 0.6
    out = np.zeros(int(length * RATE))
    for k in range(rounds):
        start = int((k * rng.uniform(0.085, 0.11)) * RATE)
        t = times(0.25)
        shot = 0.8 * crack(t, 75.0) + 0.5 * boom(t, 600, 160, 30.0)
        shot *= rng.uniform(0.75, 1.0)
        out[start : start + len(shot)] += shot[: len(out) - start]
    return outdoor_tail(out, 0.8, 6.0, 0.25)


def rocket_launch():
    t = times(1.3)
    thump = boom(t, 220, 70, 16.0) * 0.6
    hiss = filtered_noise(len(t), 500, 6500)
    # the hiss rises in pitch and fades as the rocket flies off
    sweep = np.sin(2 * np.pi * np.cumsum(300 + 900 * t) / RATE)
    envelope = np.clip(t / 0.03, 0, 1) * np.exp(-t * 2.4)
    roar = filtered_noise(len(t), 80, 900) * np.exp(-t * 3.0)
    return outdoor_tail(thump + 0.7 * hiss * envelope * (0.8 + 0.2 * sweep) + 0.5 * roar, 0.8)


def debris(t, count, start_s, spread_s):
    out = np.zeros(len(t))
    for _ in range(count):
        start = int((start_s + rng.exponential(spread_s)) * RATE)
        if start >= len(t) - 400:
            continue
        piece_t = times(rng.uniform(0.02, 0.08))
        freq = rng.uniform(1500, 5000)
        piece = np.sin(2 * np.pi * freq * piece_t) * np.exp(-piece_t * rng.uniform(60, 140))
        piece += 0.6 * filtered_noise(len(piece_t), 1500, 8000) * np.exp(-piece_t * 90)
        end = min(start + len(piece), len(t))
        out[start:end] += piece[: end - start] * rng.uniform(0.1, 0.4)
    return out


def shell_impact():
    t = times(0.9)
    thud = boom(t, 160, 45, 12.0)
    dirt = filtered_noise(len(t), 120, 3500) * np.exp(-t * 9.0)
    clank = sum(
        w * np.sin(2 * np.pi * f * rng.uniform(0.9, 1.1) * t) for f, w in [(950, 1.0), (1580, 0.5)]
    ) * np.exp(-t * 22.0)
    return outdoor_tail(thud + 0.8 * dirt + 0.25 * clank + debris(t, 14, 0.05, 0.12), 0.9)


def explosion(size):
    """size 0 small (rocket hit, light vehicle), 1 large (tank, building)"""
    length = 1.6 + 1.6 * size
    t = times(length)
    body = boom(t, 120 - 40 * size, 32 - 6 * size, 3.5 - 1.5 * size)
    blast = filtered_noise(len(t), 30, 2600 - 900 * size) * np.exp(-t * (5.0 - 2.5 * size))
    rumble = filtered_noise(len(t), 25, 160, 2.0) * np.exp(-t * (1.6 - 0.6 * size))
    crackle = filtered_noise(len(t), 1200, 7000) * (rng.random(len(t)) < 0.004)
    crackle = lowpass(crackle, 5000) * np.exp(-t * 2.2) * 6.0
    shot = 1.0 * body + 0.9 * blast + 0.7 * rumble + 0.35 * crackle
    shot += debris(t, 30 + int(40 * size), 0.12, 0.35)
    shot[: int(0.003 * RATE)] *= np.linspace(0, 1, int(0.003 * RATE))
    return outdoor_tail(shot, 1.6, 2.5, 0.3)


def tank_engine(seconds=4.0):
    """diesel growl with track clatter; whole cycles per loop so it repeats cleanly"""
    t = times(seconds)
    fundamental = 31.0
    phase = 2 * np.pi * fundamental * t + 0.4 * np.sin(2 * np.pi * 0.75 * t)
    tone = sum(np.sin(k * phase + k * 0.7) / k**1.1 for k in range(1, 14))
    pulses = np.maximum(np.sin(phase / 2.0), 0.0) ** 8
    rumble = loop_noise(seconds, 25, 220, 1.5)
    clatter = np.zeros(len(t))
    link_rate = 9.0  # track links hitting the sprocket, per second
    for k in range(int(seconds * link_rate)):
        start = int((k / link_rate + rng.uniform(-0.006, 0.006)) * RATE) % len(t)
        piece_t = times(0.05)
        piece = np.sin(2 * np.pi * rng.uniform(1700, 2600) * piece_t) * np.exp(-piece_t * 110)
        piece += 0.8 * filtered_noise(len(piece_t), 900, 6000) * np.exp(-piece_t * 140)
        idx = (np.arange(len(piece)) + start) % len(t)
        np.add.at(clatter, idx, piece * rng.uniform(0.5, 1.0))
    squeal = loop_noise(seconds, 2400, 3200, 4.0) * 0.12
    return 0.6 * tone / np.abs(tone).max() + 0.3 * pulses + 0.45 * rumble + 0.3 * clatter + squeal


def rotor(seconds=4.0):
    t = times(seconds)
    blade_rate = 17.0  # whole number of chops per loop
    chop = (0.5 + 0.5 * np.cos(2 * np.pi * blade_rate * t)) ** 10
    wash = loop_noise(seconds, 60, 900, 1.2)
    slap = loop_noise(seconds, 150, 2200, 1.0) * chop
    turbine = sum(np.sin(2 * np.pi * f * t) * w for f, w in [(1650.0, 0.5), (3300.0, 0.2)])
    return 0.55 * wash * (0.6 + 0.4 * chop) + 0.9 * slap + 0.08 * turbine


def drone_buzz(seconds=2.0):
    t = times(seconds)
    phase = 2 * np.pi * 96.0 * t + 0.2 * np.sin(2 * np.pi * 1.5 * t)
    saw = sum(np.sin(k * phase) / k for k in range(1, 18))
    prop = loop_noise(seconds, 300, 2600, 1.0) * (0.6 + 0.4 * np.sin(2 * np.pi * 48.0 * t))
    return 0.5 * saw / np.abs(saw).max() + 0.5 * prop


def loop_noise(seconds, low, high, slope):
    """circular band noise: repeats without a click"""
    return filtered_noise(int(seconds * RATE), low, high, slope)


def write(name, signal, peak=0.89):
    os.makedirs(OUT_DIR, exist_ok=True)
    signal = signal / (np.abs(signal).max() + 1e-9) * peak
    pcm = (signal * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        wav_path = handle.name
    with wave.open(wav_path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(pcm.tobytes())
    out = os.path.join(OUT_DIR, name + ".ogg")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-c:a", "libvorbis", "-q:a", "4", out],
        check=True,
    )
    os.remove(wav_path)
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    for i in range(1, 4):
        write(f"cannon_{i}", cannon_fire())
        write(f"rifle_{i}", rifle_burst(int(rng.integers(3, 6))))
        write(f"impact_{i}", shell_impact())
    for i in range(1, 3):
        write(f"heavy_cannon_{i}", cannon_fire(heavy=True))
        write(f"rocket_{i}", rocket_launch())
        write(f"explosion_small_{i}", explosion(0.0))
        write(f"explosion_large_{i}", explosion(1.0))
    write("tank_engine_loop", tank_engine(), 0.8)
    write("rotor_loop", rotor(), 0.8)
    write("drone_loop", drone_buzz(), 0.8)
