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
spectrum = np.fft.fft2(rng.standard_normal((SIZE, SIZE))) / radius**1.6
spectrum[radius < 1.5 / SIZE] = 0.0  # drop the very lowest frequencies to avoid one huge blob
noise = np.real(np.fft.ifft2(spectrum))
noise = (noise - noise.min()) / (noise.max() - noise.min())
out = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "clouds_tile.png")
Image.fromarray((noise * 255).astype(np.uint8), "L").save(out)
print("wrote", os.path.normpath(out))

# cloud shadow decal: dark, alpha from the same noise, tiled 2x2 so the decal can be shifted by
# one period without a visible jump (see Atmosphere.gd)
alpha = np.clip((noise - 0.5) / 0.22, 0.0, 1.0)
alpha = alpha * alpha * (3.0 - 2.0 * alpha)
rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
rgba[..., 0] = 40
rgba[..., 1] = 44
rgba[..., 2] = 60
rgba[..., 3] = (alpha * 255).astype(np.uint8)
tiled = np.tile(rgba, (2, 2, 1))
out = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "cloud_shadows_2x2.png")
Image.fromarray(tiled, "RGBA").save(out)
print("wrote", os.path.normpath(out))
