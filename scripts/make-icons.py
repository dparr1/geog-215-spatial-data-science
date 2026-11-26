"""Make the home-screen app icons in pwa/: a blue capital R with 215 below.

Run from the repo root, then commit pwa/*.png:
    python3 scripts/make-icons.py path/to/AtkinsonHyperlegibleNext-ExtraBold.ttf
Needs Pillow. The font is Atkinson Hyperlegible Next (weight 800) from
Google Fonts, the site's own font.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path("pwa")
CAROLINA = (0x4B, 0x9C, 0xD3)   # UNC Carolina Blue
NAVY = (0x13, 0x29, 0x4B)       # UNC Navy
WHITE = (255, 255, 255)
SIZE = 1024


def centered(draw, text, font, cx, cy, fill):
    box = draw.textbbox((0, 0), text, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text((cx - w / 2 - box[0], cy - h / 2 - box[1]), text, font=font, fill=fill)


def icon(font_path, scale=1.0):
    """scale < 1 keeps everything inside Android's maskable safe circle."""
    im = Image.new("RGB", (SIZE, SIZE), WHITE)
    d = ImageDraw.Draw(im)
    c = SIZE / 2
    centered(d, "R", ImageFont.truetype(font_path, int(700 * scale)), c, c - 95 * scale, CAROLINA)
    # Navy band across the bottom, "215" in white.
    band_top = c + 250 * scale
    d.rectangle([0, band_top, SIZE, SIZE], fill=NAVY) if scale == 1.0 else \
        d.rounded_rectangle([c - 260 * scale, band_top, c + 260 * scale, band_top + 200 * scale],
                            radius=40 * scale, fill=NAVY)
    band_mid = (band_top + SIZE) / 2 if scale == 1.0 else band_top + 100 * scale
    centered(d, "215", ImageFont.truetype(font_path, int(190 * scale)), c, band_mid, WHITE)
    return im


def main():
    font = sys.argv[1]
    full, safe = icon(font), icon(font, 0.78)
    for name, img, px in [("icon-192.png", full, 192), ("icon-512.png", full, 512),
                          ("apple-touch-icon.png", full, 180), ("favicon-32.png", full, 32),
                          ("icon-maskable-512.png", safe, 512)]:
        img.resize((px, px), Image.LANCZOS).save(OUT / name, optimize=True)
    print("Wrote icons to", OUT)


if __name__ == "__main__":
    main()
