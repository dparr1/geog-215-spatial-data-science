"""Make the home-screen app's loading (splash) screens from images/cover.jpg.

iPhone and iPad show an apple-touch-startup-image while the app opens, but
only one made at exactly the device's screen size, so this makes one per
screen size and writes their <link> tags into assets/pwa-head.html.
(Android builds its own splash from the manifest icon and background_color.)

Run from the repo root after changing the cover, then commit pwa/splash/:
    python3 scripts/make-splash.py
Needs Pillow (pip install pillow).
"""
from pathlib import Path
from PIL import Image, ImageDraw

COVER = Path("images/cover.jpg")
OUT = Path("pwa/splash")
HEAD = Path("assets/pwa-head.html")   # tags go between the splash markers
BACKGROUND = (64, 146, 196)   # the cover's own blue; also the manifest background_color

# (CSS width, CSS height, pixel ratio, devices). Portrait sizes; iPads also get
# landscape. Add a row when Apple ships a new screen size.
SCREENS = [
    (440, 956, 3, "iPhone 16/17 Pro Max"),
    (402, 874, 3, "iPhone 16/17 Pro, 17"),
    (420, 912, 3, "iPhone Air"),
    (430, 932, 3, "iPhone 14 Pro Max, 15 Plus/Pro Max, 16 Plus"),
    (393, 852, 3, "iPhone 14 Pro, 15, 15 Pro, 16, 16e"),
    (428, 926, 3, "iPhone 12/13 Pro Max, 14 Plus"),
    (390, 844, 3, "iPhone 12, 13, 14, 12/13 Pro"),
    (375, 812, 3, "iPhone X, XS, 11 Pro, 12/13 mini"),
    (414, 896, 3, "iPhone XS Max, 11 Pro Max"),
    (414, 896, 2, "iPhone XR, 11"),
    (375, 667, 2, "iPhone SE (2nd/3rd gen), 8"),
    (1032, 1376, 2, "iPad Pro 13-inch (M4)"),
    (1024, 1366, 2, "iPad Pro 12.9-inch, iPad Air 13-inch"),
    (834, 1210, 2, "iPad Pro 11-inch (M4)"),
    (834, 1194, 2, "iPad Pro 11-inch, iPad Air 11-inch"),
    (820, 1180, 2, "iPad Air (4th/5th gen), iPad (10th gen+)"),
    (810, 1080, 2, "iPad (7th-9th gen)"),
    (744, 1133, 2, "iPad mini (6th gen+)"),
]


def load_cover():
    """The cover with the white page around its rounded corners recolored."""
    cover = Image.open(COVER).convert("RGB")
    w, h = cover.size
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        ImageDraw.floodfill(cover, corner, BACKGROUND, thresh=60)
    return cover


def splash(cover, width, height):
    """The whole cover, as large as fits with a margin, centered on the blue."""
    canvas = Image.new("RGB", (width, height), BACKGROUND)
    scale = min(width * 0.92 / cover.width, height * 0.86 / cover.height)
    size = (round(cover.width * scale), round(cover.height * scale))
    art = cover.resize(size, Image.LANCZOS)
    canvas.paste(art, ((width - size[0]) // 2, (height - size[1]) // 2))
    return canvas


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    cover = load_cover()
    tags = []
    for css_w, css_h, ratio, devices in SCREENS:
        is_ipad = css_w >= 700
        for orientation in ["portrait", "landscape"] if is_ipad else ["portrait"]:
            px_w, px_h = css_w * ratio, css_h * ratio
            if orientation == "landscape":
                px_w, px_h = px_h, px_w
            name = f"splash-{px_w}x{px_h}.jpg"
            splash(cover, px_w, px_h).save(OUT / name, quality=70, optimize=True, progressive=True)
            tags.append(
                f'<link rel="apple-touch-startup-image" href="/splash/{name}" media="'
                f"(device-width: {css_w}px) and (device-height: {css_h}px) and "
                f'(-webkit-device-pixel-ratio: {ratio}) and (orientation: {orientation})">'
                f"  <!-- {devices} -->"
            )
    head = HEAD.read_text()
    start, end = "<!-- splash:start -->", "<!-- splash:end -->"
    before, rest = head.split(start)
    after = rest.split(end)[1]
    HEAD.write_text(before + start + "\n" + "\n".join(tags) + "\n" + end + after)
    print(f"Wrote {len(tags)} splash screens to {OUT}/ and their tags to {HEAD}")


if __name__ == "__main__":
    main()
