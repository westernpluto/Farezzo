#!/usr/bin/env python3
"""Draws Farezzo's app icon (1024×1024): a paper plane rising over a price tag on a teal-to-blue
gradient. Writes Farezzo/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
Run from the repository root: python3 scripts/make_icon.py (needs Pillow)."""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = os.path.join("Farezzo", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    top, bottom = (16, 185, 170), (37, 99, 235)
    icon = Image.new("RGB", (SIZE, SIZE))
    px = icon.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = min(1, max(0, (x * 0.35 + y * 0.65) / SIZE))
            px[x, y] = lerp(top, bottom, t)

    # Soft glow behind the plane.
    glow = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(glow).ellipse((220, 160, 900, 780), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    icon = Image.composite(Image.new("RGB", (SIZE, SIZE), (255, 255, 255)), icon, glow)

    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # Price tag (lower left), tilted.
    tag = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tdraw = ImageDraw.Draw(tag)
    tdraw.rounded_rectangle((250, 560, 640, 800), radius=46, fill=(255, 255, 255, 235))
    tdraw.polygon([(250, 590), (150, 680), (250, 770)], fill=(255, 255, 255, 235))
    tdraw.ellipse((205, 660, 245, 700), fill=(37, 99, 235, 255))
    # A downward arrow on the tag: prices going down.
    tdraw.rectangle((420, 600, 466, 700), fill=(16, 160, 150, 255))
    tdraw.polygon([(380, 690), (506, 690), (443, 765)], fill=(16, 160, 150, 255))
    tag = tag.rotate(-14, resample=Image.BICUBIC, center=(400, 680))
    layer = Image.alpha_composite(layer, tag)
    draw = ImageDraw.Draw(layer)

    # Paper plane (upper right).
    nose = (850, 210)
    tail_top = (420, 380)
    tail_bottom = (610, 560)
    fold = (600, 420)
    draw.polygon([nose, tail_top, fold], fill=(255, 255, 255, 255))
    draw.polygon([nose, fold, tail_bottom], fill=(220, 236, 255, 255))
    draw.polygon([fold, (560, 470), tail_bottom], fill=(190, 215, 250, 255))

    # Dashed flight path.
    for i in range(7):
        a = math.radians(200 + i * 9)
        cx, cy = 640 + 300 * math.cos(a), 520 + 300 * math.sin(a)
        draw.ellipse((cx - 11, cy - 11, cx + 11, cy + 11), fill=(255, 255, 255, 170))

    icon = Image.alpha_composite(icon.convert("RGBA"), layer).convert("RGB")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    icon.save(OUT, "PNG")
    print("Wrote", OUT)


if __name__ == "__main__":
    main()
