"""Synthesizes the train sounds: a two-tone diesel horn for departures. Built from sine waves and noise with numpy, so the sounds
are original work released under the project's license.

    python3 tools/audio/make_train_sounds.py      # writes assets/audio/trains/*.ogg

Needs numpy and ffmpeg (with libvorbis).
"""

import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 32000
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio", "trains")
rng = np.random.default_rng(77)


def times(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def lowpass(signal, cutoff):
    freqs = np.maximum(np.fft.rfftfreq(len(signal), 1.0 / RATE), 1.0)
    return np.fft.irfft(np.fft.rfft(signal) / (1.0 + (freqs / cutoff) ** 2), len(signal))


def horn():
    """two chime notes a minor third apart, rich in odd harmonics, with a soft attack"""
    t = times(1.6)
    signal = np.zeros_like(t)
    for base in (311.0, 370.0):
        for k, amp in ((1, 1.0), (2, 0.35), (3, 0.5), (5, 0.22), (7, 0.1)):
            vibrato = 1.0 + 0.004 * np.sin(2 * np.pi * 5.5 * t)
            signal += amp * np.sin(2 * np.pi * base * k * vibrato * t)
    envelope = np.minimum(t / 0.08, 1.0) * np.clip((1.6 - t) / 0.35, 0.0, 1.0)
    signal = lowpass(signal, 2400) * envelope
    # a short echo off the hills
    echo = np.zeros_like(signal)
    delay = int(0.21 * RATE)
    echo[delay:] = signal[:-delay] * 0.25
    return signal + echo


def write(name, signal, peak=0.85):
    signal = signal / (np.abs(signal).max() + 1e-9) * peak
    data = (signal * 32767).astype(np.int16)
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, name + ".wav")
        with wave.open(wav_path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(data.tobytes())
        out = os.path.join(OUT_DIR, name + ".ogg")
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-c:a", "libvorbis",
             "-q:a", "4", out], check=True)
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    write("horn", horn())
