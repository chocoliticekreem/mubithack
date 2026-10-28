#!/usr/bin/env python3
"""Render the ROOKIE PACK developer-product icon (512x512) with code: marketing/passes/out/rookie-pack.png.

    python3 marketing/passes/render_rookie_pack.py

What's on it is exactly what the pack gives (marketing/passes/rookie-pack.json): the Rookie Star Helmet,
the Rookie Blue Truck Paint and a 2x XP badge. No "limited", no timers. Needs Pillow; uses a bold system
font when there is one (macOS Arial Rounded Bold / Arial Black), else Pillow's default.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "rookie-pack.png")
S = 1024  # drawn at 2x, downsampled to 512 for smooth edges

INK = (42, 20, 16)
CREAM = (255, 241, 214)
ORANGE = (255, 138, 31)
YELLOW = (255, 197, 49)
GOLD = (255, 241, 168)
BLUE = (47, 123, 234)
BLUE_DARK = (33, 86, 164)
GREEN = (107, 203, 90)


def font(size):
    for path in (
        "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Black.ttf",
        "/Library/Fonts/Arial Black.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def text_center(d, xy, s, f, fill, stroke=10):
    box = d.textbbox((0, 0), s, font=f, stroke_width=stroke)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text((xy[0] - w / 2 - box[0], xy[1] - h / 2 - box[1]), s, font=f, fill=fill, stroke_width=stroke, stroke_fill=INK)


def star(cx, cy, r_out, r_in, rot=-90):
    pts = []
    for i in range(10):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot + i * 36)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # background: rounded square, warm vertical gradient with sun rays
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / S
        c = tuple(int(YELLOW[i] * (1 - t) + ORANGE[i] * t) for i in range(3))
        gd.line([(0, y), (S, y)], fill=c + (255,))
    rays = ImageDraw.Draw(grad, "RGBA")
    for i in range(16):
        a0 = math.radians(i * 22.5)
        a1 = math.radians(i * 22.5 + 11)
        cx, cy, R = S / 2, S * 0.46, S
        rays.polygon([(cx, cy), (cx + R * math.cos(a0), cy + R * math.sin(a0)), (cx + R * math.cos(a1), cy + R * math.sin(a1))], fill=(255, 255, 255, 18))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=180, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([12, 12, S - 13, S - 13], radius=170, outline=INK, width=24)

    # the blue truck (Rookie Blue Truck Paint), behind the helmet, lower left
    tx, ty = 110, 600
    d.rounded_rectangle([tx, ty, tx + 520, ty + 210], radius=40, fill=BLUE, outline=INK, width=16)
    d.rounded_rectangle([tx + 360, ty - 90, tx + 520, ty + 60], radius=34, fill=BLUE, outline=INK, width=16)  # cab
    d.rounded_rectangle([tx + 395, ty - 60, tx + 490, ty + 20], radius=14, fill=(189, 244, 255), outline=INK, width=10)  # window
    d.rectangle([tx + 30, ty + 70, tx + 330, ty + 100], fill=BLUE_DARK)  # stripe
    d.rounded_rectangle([tx + 40, ty - 40, tx + 330, ty - 10], radius=10, fill=(201, 206, 214), outline=INK, width=8)  # ladder
    for k in range(5):
        x = tx + 80 + k * 55
        d.line([(x, ty - 38), (x, ty - 12)], fill=INK, width=6)
    d.ellipse([tx + 360, ty - 130, tx + 420, ty - 90], fill=(255, 75, 18), outline=INK, width=8)  # siren
    for wx in (tx + 120, tx + 410):
        d.ellipse([wx - 62, ty + 150, wx + 62, ty + 274], fill=INK)
        d.ellipse([wx - 30, ty + 182, wx + 30, ty + 242], fill=(201, 206, 214))

    # the Rookie Star Helmet, centre-right
    hx, hy, hr = 600, 470, 250
    d.pieslice([hx - hr, hy - hr, hx + hr, hy + hr], 180, 360, fill=ORANGE, outline=INK, width=18)
    d.rounded_rectangle([hx - hr - 70, hy - 12, hx + hr + 90, hy + 52], radius=30, fill=ORANGE, outline=INK, width=18)  # brim
    d.rounded_rectangle([hx - 28, hy - hr - 20, hx + 28, hy - 20], radius=24, fill=GOLD, outline=INK, width=12)  # comb
    d.ellipse([hx - 110, hy - 205, hx + 110, hy - 5], fill=GOLD, outline=INK, width=14)  # shield
    d.polygon(star(hx, hy - 105, 82, 34), fill=YELLOW, outline=INK)
    d.line(star(hx, hy - 105, 82, 34) + [star(hx, hy - 105, 82, 34)[0]], fill=INK, width=8)
    # sparkles
    for (sx, sy, r) in ((300, 230, 34), (860, 300, 26), (900, 560, 20)):
        d.polygon(star(sx, sy, r, r * 0.35, rot=-90), fill=(255, 255, 255))

    # 2x XP badge, top left
    bx, by, br = 210, 210, 150
    d.ellipse([bx - br, by - br, bx + br, by + br], fill=GREEN, outline=INK, width=18)
    text_center(d, (bx, by - 36), "2x", font(130), CREAM, stroke=10)
    text_center(d, (bx, by + 66), "XP", font(84), CREAM, stroke=8)

    # banner
    d.rounded_rectangle([140, 860, S - 140, 975], radius=50, fill=(217, 55, 42), outline=INK, width=16)
    text_center(d, (S / 2, 918), "ROOKIE", font(100), CREAM, stroke=8)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.resize((512, 512), Image.LANCZOS).save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
