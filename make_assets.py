"""Generate app icons and launch images for QR Scanner (iOS 6-10)."""
import os
import sys
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else "assets"
os.makedirs(OUT, exist_ok=True)

GREEN = (51, 199, 120)
DARK = (22, 26, 31)


def icon(size):
    s = 1024
    img = Image.new("RGB", (s, s), DARK)
    d = ImageDraw.Draw(img)
    for y in range(s):
        t = y / s
        c = tuple(int(DARK[i] + (48 - DARK[i]) * (1 - t) * 0.7) for i in range(3))
        d.line([(0, y), (s, y)], fill=c)
    m = 48
    n = 13
    ox = oy = (s - n * m) // 2

    def finder2(cx, cy):
        x, y = ox + cx * m, oy + cy * m
        d.rounded_rectangle([x, y, x + 5 * m - 1, y + 5 * m - 1], radius=m, fill=(255, 255, 255))
        d.rounded_rectangle([x + m, y + m, x + 4 * m - 1, y + 4 * m - 1], radius=m // 2, fill=DARK)
        d.rounded_rectangle([x + 2 * m - 8, y + 2 * m - 8, x + 3 * m + 7, y + 3 * m + 7], radius=12, fill=(255, 255, 255))

    finder2(0, 0)
    finder2(n - 5, 0)
    finder2(0, n - 5)
    pattern = [
        "0000010100000",
        "0000001100000",
        "0000010010000",
        "0000011010000",
        "0000000110000",
        "1011010101101",
        "0100111001010",
        "1101001110110",
        "0000010101011",
        "0000001011100",
        "0000011100110",
        "0000010010101",
        "0000011101011",
    ]
    for r, row in enumerate(pattern):
        for c, ch in enumerate(row):
            if ch == "1":
                x, y = ox + c * m, oy + r * m
                d.rounded_rectangle([x + 5, y + 5, x + m - 6, y + m - 6], radius=8, fill=(255, 255, 255))
    # green scan line
    ly = s // 2 + m // 2
    d.rounded_rectangle([90, ly - 14, s - 90, ly + 14], radius=14, fill=GREEN)
    return img.resize((size, size), Image.LANCZOS)


ICONS = {
    "Icon.png": 57, "Icon@2x.png": 114,
    "Icon-72.png": 72, "Icon-72@2x.png": 144,
    "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180,
    "AppIcon76x76.png": 76, "AppIcon76x76@2x~ipad.png": 152, "AppIcon76x76~ipad.png": 76,
    "AppIcon83.5x83.5@2x~ipad.png": 167,
    "Icon-Small.png": 29, "Icon-Small@2x.png": 58, "Icon-Small@3x.png": 87,
    "Icon-40.png": 40, "Icon-40@2x.png": 80, "Icon-40@3x.png": 120,
}
big = icon(1024)
for name, px in ICONS.items():
    big.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name), optimize=True)
big.save(os.path.join(OUT, "iTunesArtwork@2x.png"))


def launch(w, h):
    img = Image.new("RGB", (w, h), (0, 0, 0))
    return img


LAUNCH = {
    # iOS 6 legacy names
    "Default.png": (320, 480), "Default@2x.png": (640, 960), "Default-568h@2x.png": (640, 1136),
    "Default-Portrait~ipad.png": (768, 1024), "Default-Portrait@2x~ipad.png": (1536, 2048),
    # iOS 7+ (UILaunchImages)
    "LaunchImage-700@2x.png": (640, 960), "LaunchImage-700-568h@2x.png": (640, 1136),
    "LaunchImage-800-667h@2x.png": (750, 1334), "LaunchImage-800-Portrait-736h@3x.png": (1242, 2208),
    "LaunchImage-700-Portrait~ipad.png": (768, 1024), "LaunchImage-700-Portrait@2x~ipad.png": (1536, 2048),
}
for name, (w, h) in LAUNCH.items():
    launch(w, h).save(os.path.join(OUT, name), optimize=True)

print("assets written to", OUT)
