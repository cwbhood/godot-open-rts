"""Generates assets/textures/clouds_tile.png: a seamless (tileable) fractal noise used for the
cloud layer and the cloud shadows. Spectral synthesis (filtered white noise through an FFT) is
periodic by construction, so the image tiles without seams. Run: python3 make_cloud_texture.py"""
import os

import numpy as np
from PIL import Image

SIZE = 512
rng = np.random.default_rng(1234)
freq_x = np.fft.fftfreq(SIZE)[None, :]
freq_y = np.fft.fftfreq(SIZE)[:, None]
radius = np.sqrt(freq_x**2 + freq_y**2)
radius[0, 0] = 1.0
spectrum = np.fft.fft2(rng.standard_normal((SIZE, SIZE))) / radius**2.0
spectrum[radius < 1.5 / SIZE] = 0.0  # drop the very lowest frequencies to avoid one huge blob
noise = np.real(np.fft.ifft2(spectrum))
# histogram-equalize so that a shader threshold t covers a (1 - t) fraction of the sky
ranks = np.argsort(np.argsort(noise.ravel()))
noise = (ranks / (ranks.size - 1)).reshape(noise.shape)
out = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "clouds_tile.png")
Image.fromarray((noise * 255).astype(np.uint8), "L").save(out)
print("wrote", os.path.normpath(out))

