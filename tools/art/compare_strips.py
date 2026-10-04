"""Turns the shots of tests/screenshots/UnitModelCompare.tscn into one before/after strip per
unit: play zoom on the left (real pixels), close zoom on the right, with labels. Columns in
each shot are classic blue, new blue, classic red, new red.

    python3 tools/art/compare_strips.py /tmp/compare /tmp/strips [--play 15] [--close 8]

Needs Pillow.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

LABELS = ["OLD", "NEW", "OLD", "NEW"]
SPACING_M = 3.2  # UnitModelCompare.SPACING


def font(size):
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def crop(path, camera_size, rows_m=3.0):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px_per_m = h / camera_size
    half_w = int(px_per_m * SPACING_M * 2.25)
    half_h = int(px_per_m * rows_m / 2)
    cx, cy = w // 2, h // 2
    return im.crop((max(0, cx - half_w), max(0, cy - half_h), min(w, cx + half_w),
                    min(h, cy + half_h))), px_per_m


def label(im, px_per_m, title):
    d = ImageDraw.Draw(im)
    f = font(max(14, int(im.height * 0.07)))
    cx = im.width / 2
    for i, text in enumerate(LABELS):
        x = cx + (i - 1.5) * SPACING_M * px_per_m
        d.text((x, 6), text, font=f, fill="white", stroke_width=3, stroke_fill="black",
               anchor="mt")
    d.text((8, im.height - 8), title, font=font(16), fill="white", stroke_width=2,
           stroke_fill="black", anchor="lb")
    return im


def main():
    src, out = sys.argv[1], sys.argv[2]
    args = dict(zip(sys.argv[3::2], sys.argv[4::2]))
    play, close = args.get("--play", "15"), args.get("--close", "8")
    os.makedirs(out, exist_ok=True)
    units = sorted({f.rsplit("_", 1)[0] for f in os.listdir(src) if f.endswith(".png")})
    for unit in units:
        a_path = os.path.join(src, f"{unit}_{play}.png")
        b_path = os.path.join(src, f"{unit}_{close}.png")
        if not (os.path.exists(a_path) and os.path.exists(b_path)):
            continue
        a, a_px = crop(a_path, float(play))
        b, b_px = crop(b_path, float(close))
        label(a, a_px, "play zoom, real pixels (blue | red)")
        label(b, b_px, "close zoom")
        head = 46
        sheet = Image.new("RGB", (a.width + b.width + 12, max(a.height, b.height) + head),
                          (24, 24, 28))
        ImageDraw.Draw(sheet).text((12, 10), unit.replace("_", " ").title(), font=font(26),
                                   fill="white")
        sheet.paste(a, (0, head))
        sheet.paste(b, (a.width + 12, head))
        path = os.path.join(out, f"{unit}-old-vs-new.png")
        sheet.save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()
