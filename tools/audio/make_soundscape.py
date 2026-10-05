"""Synthesizes the ambient soundscape (wind, rain, engine hum, city noise, trade horn).

Everything is generated from noise and sine waves with numpy, so the sounds are original
work released under the project's license. Loops are built in the frequency domain or
from whole numbers of cycles so that they repeat without a click.

    python3 tools/audio/make_soundscape.py      # writes assets/audio/ambience/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 22050
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "ambience")
rng = np.random.default_rng(1234)


def shaped_noise(seconds, shape):
    """circular noise whose spectrum follows shape(frequencies) -> loops seamlessly"""
    n = int(seconds * RATE)
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    spectrum *= shape(freqs)
    signal = np.fft.irfft(spectrum, n)
    return signal / (np.abs(signal).max() + 1e-9)


def band(freqs, low, high, slope=1.0):
    rise = 1.0 / (1.0 + (low / np.maximum(freqs, 1.0)) ** (2 * slope))
    fall = 1.0 / (1.0 + (freqs / high) ** (2 * slope))
    return rise * fall


def loop_lfo(n, seconds, cycles_and_weights, phase_seed=0):
    """slow modulation made of whole cycles per loop"""
    t = np.arange(n) / RATE
    local = np.random.default_rng(phase_seed)
    value = np.zeros(n)
    for cycles, weight in cycles_and_weights:
        value += weight * np.sin(2 * np.pi * cycles * t / seconds + local.uniform(0, 2 * np.pi))
    return value


def place_circular(target, sound, start):
    """adds 'sound' at 'start', wrapping around the end of a loop"""
    n = len(target)
    idx = (np.arange(len(sound)) + start) % n
    np.add.at(target, idx, sound)


def wind(seconds=16.0):
    n = int(seconds * RATE)
    base = shaped_noise(seconds, lambda f: band(f, 90, 700, 1.0) / np.sqrt(np.maximum(f, 20)))
    gust = 0.55 + 0.45 * np.tanh(1.5 * loop_lfo(n, seconds, [(2, 0.7), (3, 0.5), (7, 0.25)], 1))
    whistle = shaped_noise(seconds, lambda f: band(f, 520, 760, 4.0))
    whistle_level = np.clip(loop_lfo(n, seconds, [(3, 1.0), (5, 0.6)], 2), 0, None) ** 2
    return base * gust + 0.25 * whistle * whistle_level


def rain(seconds=8.0):
    n = int(seconds * RATE)
    hiss = shaped_noise(seconds, lambda f: band(f, 1200, 7000, 1.0))
    patter = np.zeros(n)
    t = np.arange(int(0.025 * RATE)) / RATE
    for _ in range(int(seconds * 90)):
        freq = rng.uniform(2500, 6000)
        drop = np.sin(2 * np.pi * freq * t) * np.exp(-t * rng.uniform(250, 500))
        place_circular(patter, drop * rng.uniform(0.1, 0.5), rng.integers(0, n))
    rumble = shaped_noise(seconds, lambda f: band(f, 60, 300, 1.0))
    return 0.6 * hiss + 0.5 * patter + 0.25 * rumble


def engine_hum(seconds=4.0):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    fundamental = 42.0  # whole cycles in 4 s
    wobble = 0.6 * np.sin(2 * np.pi * 0.5 * t)  # 2 cycles per loop
    phase = 2 * np.pi * fundamental * t + wobble
    tone = sum(np.sin(k * phase + k) / k**1.2 for k in range(1, 10))
    # diesel firing pulses at half the fundamental
    pulses = np.maximum(np.sin(phase / 2.0), 0.0) ** 6
    rumble = shaped_noise(seconds, lambda f: band(f, 30, 260, 1.5))
    hum = 0.55 * tone / np.abs(tone).max() + 0.35 * pulses + 0.35 * rumble
    return hum * (0.85 + 0.15 * np.sin(2 * np.pi * 1.0 * t))


def metal_hit(length=0.6):
    t = np.arange(int(length * RATE)) / RATE
    partials = [(820, 1.0), (1370, 0.6), (2130, 0.4), (2950, 0.25)]
    base = rng.uniform(0.8, 1.2)
    hit = sum(w * np.sin(2 * np.pi * f * base * t) for f, w in partials)
    return hit * np.exp(-t * rng.uniform(8, 14))


def city(seconds=16.0):
    n = int(seconds * RATE)
    murmur = shaped_noise(seconds, lambda f: band(f, 80, 500, 1.2))
    murmur *= 0.75 + 0.25 * loop_lfo(n, seconds, [(1, 0.6), (4, 0.4)], 3)
    traffic = shaped_noise(seconds, lambda f: band(f, 40, 140, 2.0))
    traffic *= 0.6 + 0.4 * np.clip(loop_lfo(n, seconds, [(2, 1.0), (5, 0.5)], 4), -1, 1)
    events = np.zeros(n)
    for _ in range(int(seconds * 0.8)):
        place_circular(events, metal_hit() * rng.uniform(0.15, 0.35), rng.integers(0, n))
    for _ in range(3):  # hammering somewhere
        start = rng.integers(0, n)
        for k in range(rng.integers(3, 6)):
            place_circular(events, metal_hit(0.3) * 0.25, start + int(k * 0.42 * RATE))
    # distance: dull the clanks
    events_spectrum = np.fft.rfft(events)
    events_spectrum *= band(np.fft.rfftfreq(n, 1.0 / RATE), 100, 1800, 1.0)
    events = np.fft.irfft(events_spectrum, n)
    return 0.55 * murmur + 0.45 * traffic + 1.2 * events


def horn(seconds=3.6):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    envelope = np.zeros(n)
    for start, length in [(0.05, 0.55), (0.85, 1.6)]:
        attack = np.clip((t - start) / 0.07, 0, 1)
        release = np.clip(1 - (t - start - length) / 0.35, 0, 1)
        envelope = np.maximum(envelope, attack * release)
    vibrato = 0.004 * np.sin(2 * np.pi * 5.0 * t)
    tone = np.zeros(n)
    for root in [146.8, 174.6, 220.0]:  # D minor chord, like a ship's horn
        phase = 2 * np.pi * root * t * (1 + vibrato)
        tone += sum(np.sin(k * phase) / k**1.4 for k in range(1, 14))
    signal = tone * envelope
    # small room: convolve with a short decaying noise tail
    tail_t = np.arange(int(0.9 * RATE)) / RATE
    tail = rng.standard_normal(len(tail_t)) * np.exp(-tail_t * 6.0) * 0.02
    tail[0] = 1.0
    wet = np.fft.irfft(np.fft.rfft(signal, 2 * n) * np.fft.rfft(tail, 2 * n), 2 * n)[:n]
    return wet


def write(name, signal, peak=0.8):
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
    write("wind_loop", wind())
    write("rain_loop", rain())
    write("engine_hum_loop", engine_hum())
    write("city_loop", city())
    write("trade_horn", horn())
